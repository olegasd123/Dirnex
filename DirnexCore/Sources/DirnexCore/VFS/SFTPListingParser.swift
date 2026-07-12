import Foundation

/// Parses the `ls -l`-style table an SFTP/SSH server prints into flat directory entries. It is a
/// close cousin of `ArchiveTOCParser` — same "8 fixed columns, then a verbatim name" shape — but
/// simpler: a listing is one flat directory, so there is no tree to assemble and no ancestor
/// synthesis. Kept separate (rather than sharing internals with the archive parser) to avoid
/// churning a heavily-tested file; the small overlap in date/column handling is deliberate.
///
/// A `ls -la` block looks like (columns: mode, links, owner, group, size, month, day,
/// time-or-year, then the name — which may contain spaces, or ` -> target` for a symlink):
///
///     total 24
///     drwxr-xr-x  2 user group 4096 Jul 10 16:19 .
///     drwxr-xr-x 20 user group 4096 Jul  9 10:00 ..
///     -rw-r--r--  1 user group  128 Jul 10 16:19 notes.txt
///     drwxr-xr-x  2 user group 4096 Jul 10 16:19 photos
///     lrwxrwxrwx  1 user group    7 Jul 10 16:19 latest -> notes.txt
///
/// The `total` header, and the `.`/`..` self/parent rows, are dropped (the panel supplies
/// navigation; those aren't data). Old entries carry a year instead of a `HH:mm` time.
enum SFTPListingParser {
    /// One parsed row: everything the backend needs to build a `FileEntry` for a remote item.
    struct Entry: Equatable {
        let name: String
        let kind: FileEntry.Kind
        let byteSize: Int64
        let modificationDate: Date
        let permissions: UInt16
        let symlinkDestination: String?
    }

    /// Parse a full directory listing (`ls -la`), dropping the `total` header and the `.`/`..`
    /// rows, preserving the server's order.
    static func parseDirectory(_ text: String) -> [Entry] {
        parseLines(text).filter { $0.name != "." && $0.name != ".." }
    }

    /// Parse a single `ls -ld` line describing one item; `nil` when nothing parses. (The backend
    /// overrides the name with the queried path's last component, since `ls -ld /a/b` prints the
    /// full argument as the name.)
    static func parseItem(_ text: String) -> Entry? {
        parseLines(text).first
    }

    // MARK: - Line scanning

    private static func parseLines(_ text: String) -> [Entry] {
        let formatters = dateFormatters()
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = parseLine(line, formatters: formatters) { entries.append(entry) }
        }
        return entries
    }

    private static func parseLine(_ line: Substring, formatters: [DateFormatter]) -> Entry? {
        // The leading columns never contain spaces, so a collapsing split reads them; the name is
        // taken verbatim after the 8th column to keep internal spaces (`my report.txt`). The
        // `total 24` header has too few columns and is skipped by the count guard.
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, isModeField(columns[0]),
              let modeChar = columns[0].first,
              var name = nameField(in: line, afterColumns: 8) else { return nil }

        let byteSize = Int64(columns[4]) ?? 0
        let date = parseDate(columns[5], columns[6], columns[7], formatters: formatters)
        let permissions = parsePermissions(columns[0])

        var symlinkDestination: String?
        let kind: FileEntry.Kind
        switch modeChar {
        case "d":
            kind = .directory
        case "l":
            kind = .symlink
            if let range = name.range(of: " -> ") {
                symlinkDestination = String(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
        case "-":
            kind = .file
        default:
            kind = .other // block/char device, socket, FIFO — shown but not navigable
        }

        return Entry(
            name: name,
            kind: kind,
            byteSize: byteSize,
            modificationDate: date,
            permissions: permissions,
            symlinkDestination: symlinkDestination
        )
    }

    /// Whether a first column looks like a `ls` mode string — 10 permission characters, or 11 when
    /// the server appends an ACL `+` or an xattr `@`. Rejects the `total` header and stray lines.
    private static func isModeField(_ field: Substring) -> Bool {
        guard field.count == 10 || field.count == 11, let first = field.first else { return false }
        return "-dlbcsp".contains(first)
    }

    /// The substring of `line` after skipping `count` whitespace-delimited columns — the entry
    /// name, kept verbatim so internal spaces survive. Mirrors `ArchiveTOCParser.nameField`.
    private static func nameField(in line: Substring, afterColumns count: Int) -> String? {
        var index = line.startIndex
        var seen = 0
        while seen < count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            seen += 1
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex else { return nil }
        return String(line[index...])
    }

    /// Map the 9 permission characters (`rwxr-xr-x`) to POSIX mode bits. `s`/`S`/`t`/`T` (setuid,
    /// setgid, sticky) are treated as a set bit — permissions here are cosmetic (row display),
    /// not enforced, so the approximation is harmless.
    private static func parsePermissions(_ modeField: Substring) -> UInt16 {
        let characters = Array(modeField)
        guard characters.count >= 10 else { return 0 }
        let weights: [UInt16] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var bits: UInt16 = 0
        for (offset, weight) in weights.enumerated() where characters[offset + 1] != "-" {
            bits |= weight
        }
        return bits
    }

    // MARK: - Dates

    private static func dateFormatters() -> [DateFormatter] {
        ["MMM d HH:mm", "MMM d yyyy", "MMM d HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func parseDate(
        _ month: Substring,
        _ day: Substring,
        _ timeOrYear: Substring,
        formatters: [DateFormatter]
    ) -> Date {
        let string = "\(month) \(day) \(timeOrYear)"
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        return .distantPast
    }
}
