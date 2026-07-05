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
public struct FileSort: Sendable, Hashable {
    public enum Key: String, Sendable, Hashable, CaseIterable {
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
        visibleEntries = []
        recompute()
    }

    /// Replace the underlying snapshot (e.g. after a live FSEvents refresh) while
    /// keeping the current sort/filter/hidden settings.
    public mutating func updateListing(_ listing: DirectoryListing) {
        self.listing = listing
        recompute()
    }

    public var count: Int { visibleEntries.count }

    public var isEmpty: Bool { visibleEntries.isEmpty }

    public subscript(index: Int) -> FileEntry { visibleEntries[index] }

    /// Row index of a specific entry, or `nil` if it is not currently visible.
    public func index(ofID id: VFSPath) -> Int? {
        visibleEntries.firstIndex { $0.id == id }
    }

    private mutating func recompute() {
        visibleEntries = Self.materialize(
            listing.entries, sort: sort, showHidden: showHidden, filter: filter
        )
    }

    static func materialize(
        _ entries: [FileEntry],
        sort: FileSort,
        showHidden: Bool,
        filter: String
    ) -> [FileEntry] {
        var items = entries
        if !showHidden {
            items = items.filter { !$0.isHidden }
        }
        if !filter.isEmpty {
            let needle = filter.lowercased()
            items = items.filter { $0.name.lowercased().contains(needle) }
        }
        items.sort(by: comparator(for: sort))
        return items
    }

    /// Builds the row-ordering predicate for a sort. Directory grouping (when on)
    /// wins over the key; the key's direction never moves directories below files.
    /// Name is the stable tiebreaker so equal keys yield a deterministic order.
    static func comparator(for sort: FileSort) -> (FileEntry, FileEntry) -> Bool {
        { lhs, rhs in
            if sort.directoriesFirst, lhs.isDirectoryLike != rhs.isDirectoryLike {
                return lhs.isDirectoryLike
            }

            var result = compare(lhs, rhs, key: sort.key)
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
        key: FileSort.Key
    ) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compareValues(lhs.byteSize, rhs.byteSize)
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
