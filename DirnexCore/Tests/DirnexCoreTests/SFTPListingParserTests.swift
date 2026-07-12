import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPListingParser")
struct SFTPListingParserTests {
    /// A representative Linux `ls -la` block: the `total` header, `.`/`..`, a file, a dir, a
    /// symlink, a name with spaces, and an old (year-stamped) entry.
    private let sampleListing = """
    total 28
    drwxr-xr-x  4 user group 4096 Jul 10 16:19 .
    drwxr-xr-x 20 user group 4096 Jul  9 10:00 ..
    -rw-r--r--  1 user group  128 Jul 10 16:19 notes.txt
    drwxr-xr-x  2 user group 4096 Jul 10 16:19 photos
    lrwxrwxrwx  1 user group    7 Jul 10 16:19 latest -> notes.txt
    -rw-r--r--  1 user group   42 Jul 10 16:19 my report.txt
    -rw-r--r--  1 user group  512 Jan  3  2021 archive.log
    """

    @Test("drops the total header and the . and .. rows")
    func dropsHeaderAndDots() {
        let entries = SFTPListingParser.parseDirectory(sampleListing)
        #expect(!entries.contains { $0.name == "." })
        #expect(!entries.contains { $0.name == ".." })
        #expect(entries.count == 5)
    }

    @Test("classifies files, directories, and symlinks by mode")
    func classifiesKinds() {
        let byName = Dictionary(
            uniqueKeysWithValues: SFTPListingParser.parseDirectory(sampleListing).map { ($0.name, $0) }
        )
        #expect(byName["notes.txt"]?.kind == .file)
        #expect(byName["photos"]?.kind == .directory)
        #expect(byName["latest"]?.kind == .symlink)
    }

    @Test("captures a symlink's target and strips it from the name")
    func symlinkTarget() {
        let link = SFTPListingParser.parseDirectory(sampleListing).first { $0.name == "latest" }
        #expect(link?.name == "latest")
        #expect(link?.symlinkDestination == "notes.txt")
    }

    @Test("preserves internal spaces in a name")
    func nameWithSpaces() {
        let entries = SFTPListingParser.parseDirectory(sampleListing)
        #expect(entries.contains { $0.name == "my report.txt" && $0.byteSize == 42 })
    }

    @Test("reads the byte size column")
    func byteSize() {
        let notes = SFTPListingParser.parseDirectory(sampleListing).first { $0.name == "notes.txt" }
        #expect(notes?.byteSize == 128)
    }

    @Test("parses a recent HH:mm date and an old year-stamped date")
    func dates() {
        let entries = SFTPListingParser.parseDirectory(sampleListing)
        let notes = entries.first { $0.name == "notes.txt" }
        let old = entries.first { $0.name == "archive.log" }
        // Both parse to a real date, not the .distantPast fallback.
        #expect(notes?.modificationDate != .distantPast)
        #expect(old?.modificationDate != .distantPast)

        // Read components in the local zone — the parser formats with no explicit time zone, so a
        // year-stamped entry lands at local midnight; forcing UTC here would shift the day.
        let calendar = Calendar(identifier: .gregorian)
        if let date = old?.modificationDate {
            #expect(calendar.component(.year, from: date) == 2021)
            #expect(calendar.component(.month, from: date) == 1)
            #expect(calendar.component(.day, from: date) == 3)
        }
    }

    @Test("parses permission bits from the mode string")
    func permissions() {
        let entries = SFTPListingParser.parseDirectory(sampleListing)
        // -rw-r--r-- -> 0o644
        #expect(entries.first { $0.name == "notes.txt" }?.permissions == 0o644)
        // drwxr-xr-x -> 0o755
        #expect(entries.first { $0.name == "photos" }?.permissions == 0o755)
    }

    @Test("classifies non-regular entries as other")
    func otherKinds() {
        let listing = """
        total 0
        srwxr-xr-x 1 user group 0 Jul 10 16:19 daemon.sock
        prw-r--r-- 1 user group 0 Jul 10 16:19 pipe
        """
        let entries = SFTPListingParser.parseDirectory(listing)
        #expect(entries.first { $0.name == "daemon.sock" }?.kind == .other)
        #expect(entries.first { $0.name == "pipe" }?.kind == .other)
    }

    @Test("tolerates an ACL '+' or xattr '@' mode suffix")
    func modeSuffix() {
        let listing = """
        total 8
        -rw-r--r--@ 1 user group 10 Jul 10 16:19 tagged.txt
        drwxr-xr-x+ 2 user group  4 Jul 10 16:19 acldir
        """
        let entries = SFTPListingParser.parseDirectory(listing)
        #expect(entries.first { $0.name == "tagged.txt" }?.kind == .file)
        #expect(entries.first { $0.name == "acldir" }?.kind == .directory)
    }

    @Test("parseItem reads a single ls -ld line")
    func singleItem() {
        let entry = SFTPListingParser.parseItem(
            "drwxr-xr-x 5 user group 4096 Jul 10 16:19 /home/user/docs"
        )
        #expect(entry?.kind == .directory)
        // The parser reports the printed name verbatim; the backend overrides it with the
        // queried path's last component.
        #expect(entry?.name == "/home/user/docs")
    }

    @Test("ignores lines that aren't entries")
    func ignoresJunk() {
        #expect(SFTPListingParser.parseDirectory("").isEmpty)
        #expect(SFTPListingParser.parseDirectory("total 0\n").isEmpty)
        #expect(
            SFTPListingParser.parseDirectory("ls: cannot open directory: Permission denied").isEmpty
        )
    }
}
