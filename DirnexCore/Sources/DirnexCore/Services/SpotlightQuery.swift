import Foundation

// Spotlight-backed file search (PLAN.md §M4 "Search (Alt+F7 / palette): mdfind-backed
// name+content search with filter chips (kind, size, date, tag)").
//
// This is the pure *query-building* half: a `SpotlightQuery` value describes what the user is
// looking for and renders it into the raw `kMDItem…` metadata predicate `mdfind` understands,
// plus the full argument vector for the `mdfind` CLI. It touches no disk and runs no process
// (so it stays unit-testable without a Spotlight index or a subprocess); the app runs `mdfind`
// with these arguments off the main thread and stats the resulting paths into a virtual panel.
//
// Mirrors `MultiRename`: the tested planning logic lives here; the non-hermetic I/O (spawning
// `mdfind`, statting results) lives in the app layer, like `DirectoryLoader`.

// MARK: - Filter chips

/// The kind-of-file filter chip. Each maps to a Uniform Type Identifier that `mdfind` matches
/// against `kMDItemContentTypeTree`, so a file conforming to that type (a PNG under
/// `public.image`, a folder under `public.folder`) matches.
public enum SearchKind: String, Sendable, Equatable, CaseIterable, Codable {
    case folder
    case image
    case audio
    case movie
    case document
    case archive

    /// The UTI a `kMDItemContentTypeTree` comparison tests conformance to.
    public var contentType: String {
        switch self {
        case .folder: return "public.folder"
        case .image: return "public.image"
        case .audio: return "public.audio"
        case .movie: return "public.movie"
        case .document: return "public.content"
        case .archive: return "public.archive"
        }
    }

    /// The user-facing label for the chip / popup.
    public var title: String {
        switch self {
        case .folder: return "Folders"
        case .image: return "Images"
        case .audio: return "Audio"
        case .movie: return "Movies"
        case .document: return "Documents"
        case .archive: return "Archives"
        }
    }
}

/// The "modified within" date chip — a rolling window ending now, expressed to `mdfind` as a
/// relative offset from `$time.now` so the predicate stays deterministic (no wall-clock literal
/// baked into the query string).
public enum SearchAge: String, Sendable, Equatable, CaseIterable, Codable {
    case today
    case week
    case month
    case year

    /// Seconds in the window — the negative offset applied to `$time.now`. A month is 30 days
    /// and a year 365; the exactness doesn't matter for a "recently changed" filter.
    public var seconds: Int {
        switch self {
        case .today: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000
        case .year: return 31_536_000
        }
    }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Past week"
        case .month: return "Past month"
        case .year: return "Past year"
        }
    }
}

// MARK: - Query

/// A file search described as data. Any combination of the fields narrows the result set (they
/// AND together); an all-empty query is `isEmpty` and produces no predicate, so the search UI
/// disables "Find" until the user asks for something.
public struct SpotlightQuery: Sendable, Equatable {
    /// Substring matched (case- and diacritic-insensitively) against the file *name*.
    public var nameContains: String
    /// Substring matched against the indexed text *content* of the file.
    public var contentContains: String
    /// Kind chips; an item matches when it conforms to *any* selected kind (they OR together,
    /// then AND with the rest of the query). Empty = any kind.
    public var kinds: Set<SearchKind>
    /// Only items at least this many bytes. `nil` = any size.
    public var minSizeBytes: Int64?
    /// Only items changed within this rolling window. `nil` = any date.
    public var modifiedWithin: SearchAge?

    public init(
        nameContains: String = "",
        contentContains: String = "",
        kinds: Set<SearchKind> = [],
        minSizeBytes: Int64? = nil,
        modifiedWithin: SearchAge? = nil
    ) {
        self.nameContains = nameContains
        self.contentContains = contentContains
        self.kinds = kinds
        self.minSizeBytes = minSizeBytes
        self.modifiedWithin = modifiedWithin
    }

    /// Nothing to search for — every field is at its neutral default. The search UI treats this
    /// as "Find" disabled, and `metadataPredicate()` returns `nil`.
    public var isEmpty: Bool {
        trimmedName.isEmpty && trimmedContent.isEmpty
            && kinds.isEmpty && minSizeBytes == nil && modifiedWithin == nil
    }

    private var trimmedName: String {
        nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedContent: String {
        contentContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Predicate

    /// The raw `mdfind` metadata query, or `nil` when the query is empty. Clauses are ANDed in a
    /// fixed order so the output is deterministic and testable: name, content, kind, size, date.
    public func metadataPredicate() -> String? {
        var clauses: [String] = []

        let name = trimmedName
        if !name.isEmpty {
            clauses.append(#"kMDItemFSName == "*\#(Self.escape(name))*"cd"#)
        }
        let content = trimmedContent
        if !content.isEmpty {
            clauses.append(#"kMDItemTextContent == "*\#(Self.escape(content))*"cd"#)
        }
        if let kindClause = kindClause() {
            clauses.append(kindClause)
        }
        if let minSizeBytes {
            clauses.append("kMDItemFSSize >= \(minSizeBytes)")
        }
        if let modifiedWithin {
            clauses.append("kMDItemFSContentChangeDate >= $time.now(-\(modifiedWithin.seconds))")
        }

        return clauses.isEmpty ? nil : clauses.joined(separator: " && ")
    }

    /// A parenthesized OR over the selected kinds' UTIs (in `SearchKind.allCases` order so it is
    /// deterministic), or `nil` when no kind chip is set.
    private func kindClause() -> String? {
        let selected = SearchKind.allCases.filter { kinds.contains($0) }
        guard !selected.isEmpty else { return nil }
        let terms = selected.map { #"kMDItemContentTypeTree == "\#($0.contentType)"c"# }
        return "(" + terms.joined(separator: " || ") + ")"
    }

    /// The full argument vector for `/usr/bin/mdfind`. `scopePath`, when given, limits the search
    /// to that directory subtree via `-onlyin`; `nil` searches every indexed volume. Returns an
    /// empty array for an empty query (the caller guards on `isEmpty` and never runs it).
    public func mdfindArguments(scopePath: String? = nil) -> [String] {
        guard let predicate = metadataPredicate() else { return [] }
        var arguments: [String] = []
        if let scopePath, !scopePath.isEmpty {
            arguments += ["-onlyin", scopePath]
        }
        arguments.append(predicate)
        return arguments
    }

    // MARK: - Presentation

    /// A short, human label for the results — used as the virtual panel's title and path-bar
    /// crumb. Prefers the most specific term the user gave.
    public var summary: String {
        let name = trimmedName
        if !name.isEmpty { return "“\(name)”" }
        let content = trimmedContent
        if !content.isEmpty { return "“\(content)”" }
        if kinds.count == 1, let only = kinds.first { return only.title }
        return "Search results"
    }

    /// Escape the characters that are special inside an `mdfind` double-quoted string literal —
    /// a backslash and a double quote — so a search term containing them can't break out of the
    /// literal or corrupt the predicate.
    private static func escape(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
