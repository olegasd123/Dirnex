import Foundation

/// A raw, unsorted directory snapshot straight from a backend.
public struct DirectoryListing: Sendable, Hashable {
    public let path: VFSPath
    public let entries: [FileEntry]

    public init(path: VFSPath, entries: [FileEntry]) {
        self.path = path
        self.entries = entries
    }
}

/// How a panel orders its rows. Persisted per tab (PLAN.md §M1 "sort/column state
/// per tab"), so the `Key` raw values are part of the on-disk format.
public struct FileSort: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Hashable, CaseIterable, Codable {
        case name
        case size
        case modified
        case fileExtension
    }

    public var key: Key
    public var ascending: Bool
    /// Keep directories grouped ahead of files regardless of key/direction — the
    /// Total Commander default, and what most macOS users expect.
    public var directoriesFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, directoriesFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.directoriesFirst = directoriesFirst
    }

    public static let `default` = FileSort()
}

/// The sorted, filtered view of a directory that a panel actually renders.
///
/// Purely a projection of `listing` under `sort` + `showHidden` + `filter`; it holds
/// no disk state. The materialized `visibleEntries` is recomputed whenever an input
/// changes, so the panel can treat it as a stable array to index into. Cursor
/// preservation across refreshes is done by identity via `index(ofID:)`.
public struct DirectoryModel: Sendable {
    public private(set) var listing: DirectoryListing
    public var sort: FileSort { didSet { recompute() } }
    public var showHidden: Bool { didSet { recompute() } }
    /// Type-to-filter text; case-insensitive substring match on the name.
    public var filter: String { didSet { recompute() } }

    /// Recursively-computed directory totals recorded via Space-on-dir, keyed by entry
    /// identity. Kept out of `FileEntry` (a pure stat snapshot) and layered on top of it
    /// for display, selection totals, and size-sorting. Pruned to present entries on
    /// refresh, so it never grows unbounded or resurrects a deleted folder's number.
    public private(set) var directorySizes: [VFSPath: Int64]

    public private(set) var visibleEntries: [FileEntry]

    public init(
        listing: DirectoryListing,
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = ""
    ) {
        self.listing = listing
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        directorySizes = [:]
        visibleEntries = []
        recompute()
    }

    /// Replace the underlying snapshot (e.g. after a live FSEvents refresh) while
    /// keeping the current sort/filter/hidden settings. Computed sizes for entries that
    /// vanished from the listing are dropped.
    public mutating func updateListing(_ listing: DirectoryListing) {
        self.listing = listing
        if !directorySizes.isEmpty {
            let present = Set(listing.entries.map(\.id))
            directorySizes = directorySizes.filter { present.contains($0.key) }
        }
        recompute()
    }

    public var count: Int { visibleEntries.count }

    public var isEmpty: Bool { visibleEntries.isEmpty }

    public subscript(index: Int) -> FileEntry { visibleEntries[index] }

    /// Row index of a specific entry, or `nil` if it is not currently visible.
    public func index(ofID id: VFSPath) -> Int? {
        visibleEntries.firstIndex { $0.id == id }
    }

    // MARK: - Computed directory sizes (Space-on-dir)

    /// Record a recursively-computed size for the directory identified by `id`
    /// (Space-on-dir). Re-materializes the visible list because size-sorting may move
    /// the row.
    public mutating func setDirectorySize(_ id: VFSPath, bytes: Int64) {
        directorySizes[id] = bytes
        recompute()
    }

    /// Record many recursively-computed totals at once, re-materializing the visible list **once**
    /// instead of once per entry. Existing totals for paths not mentioned are kept; a repeated path
    /// takes the new value.
    ///
    /// This exists for one measured reason: seeding a panel from `DirectorySizeCache` arrives as a
    /// burst of N totals, and `setDirectorySize` re-sorts the whole listing on every call. Measured
    /// on this machine, seeding one-by-one costs 5.7 ms at 68 rows but **284 ms at 1,000 and 2.5 s
    /// at 3,000** — on the main actor, and quadratic. That would make the cache *slower* than no
    /// cache at the one job it has, which is making bars appear the instant a directory opens.
    public mutating func setDirectorySizes(_ sizes: [VFSPath: Int64]) {
        guard !sizes.isEmpty else { return }
        directorySizes.merge(sizes) { _, new in new }
        recompute()
    }

    /// The computed recursive size recorded for `entry`, or `nil` if none — only
    /// directories ever carry one. The size column shows a dash until this is present.
    public func computedSize(of entry: FileEntry) -> Int64? {
        directorySizes[entry.id]
    }

    /// The byte weight to attribute to `entry` in selection totals and size-sorting: a
    /// computed directory total when present, a file's own size, otherwise zero — an
    /// unsized directory's inode size is noise, not content.
    public func effectiveByteSize(of entry: FileEntry) -> Int64 {
        Self.effectiveByteSize(of: entry, sizes: directorySizes)
    }

    private static func effectiveByteSize(of entry: FileEntry, sizes: [VFSPath: Int64]) -> Int64 {
        if let computed = sizes[entry.id] { return computed }
        return entry.isDirectoryLike ? 0 : entry.byteSize
    }

    private mutating func recompute() {
        visibleEntries = Self.materialize(
            listing.entries, sort: sort, showHidden: showHidden, filter: filter,
            sizes: directorySizes
        )
    }

    static func materialize(
        _ entries: [FileEntry],
        sort: FileSort,
        showHidden: Bool,
        filter: String,
        sizes: [VFSPath: Int64] = [:]
    ) -> [FileEntry] {
        var items = entries
        if !showHidden {
            items = items.filter { !$0.isHidden }
        }
        if !filter.isEmpty {
            let needle = filter.lowercased()
            items = items.filter { $0.name.lowercased().contains(needle) }
        }
        items.sort(by: comparator(for: sort, sizes: sizes))
        return items
    }

    /// Builds the row-ordering predicate for a sort. Directory grouping (when on)
    /// wins over the key; the key's direction never moves directories below files.
    /// Name is the stable tiebreaker so equal keys yield a deterministic order.
    static func comparator(
        for sort: FileSort,
        sizes: [VFSPath: Int64] = [:]
    ) -> (FileEntry, FileEntry) -> Bool {
        { lhs, rhs in
            if sort.directoriesFirst, lhs.isDirectoryLike != rhs.isDirectoryLike {
                return lhs.isDirectoryLike
            }

            var result = compare(lhs, rhs, key: sort.key, sizes: sizes)
            if result == .orderedSame, sort.key != .name {
                result = lhs.name.localizedStandardCompare(rhs.name)
            }
            if result == .orderedSame {
                return false
            }
            return sort.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare(
        _ lhs: FileEntry,
        _ rhs: FileEntry,
        key: FileSort.Key,
        sizes: [VFSPath: Int64]
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compareValues(
                effectiveByteSize(of: lhs, sizes: sizes),
                effectiveByteSize(of: rhs, sizes: sizes)
            )
        case .modified:
            return compareValues(lhs.modificationDate, rhs.modificationDate)
        case .fileExtension:
            let byExt = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
            return byExt == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : byExt
        }
    }

    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
