import Foundation
import Testing

@testable import DirnexCore

@Suite("DirectoryModel")
struct DirectoryModelTests {
    /// Builds a `FileEntry` with sensible defaults; tests override only what they assert on.
    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 1_000_000),
        hidden: Bool = false
    ) -> FileEntry {
        FileEntry(
            path: .local("/test/\(name)"),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: modified,
            creationDate: modified,
            isHidden: hidden,
            permissions: 0o644,
            inode: 0
        )
    }

    private func model(
        _ entries: [FileEntry],
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = ""
    ) -> DirectoryModel {
        DirectoryModel(
            listing: DirectoryListing(path: .local("/test"), entries: entries),
            sort: sort,
            showHidden: showHidden,
            filter: filter
        )
    }

    // MARK: - Sorting

    @Test("name sort is natural (numeric-aware), not lexicographic")
    func naturalNameSort() {
        let subject = model(
            [entry("item10.txt"), entry("item2.txt"), entry("item1.txt")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["item1.txt", "item2.txt", "item10.txt"])
    }

    @Test("descending name sort reverses order")
    func descendingNameSort() {
        let subject = model(
            [entry("a.txt"), entry("b.txt"), entry("c.txt")],
            sort: FileSort(key: .name, ascending: false, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["c.txt", "b.txt", "a.txt"])
    }

    @Test("directoriesFirst groups directories ahead of files regardless of direction")
    func directoriesFirstGrouping() {
        let entries = [
            entry("aaa.txt"),
            entry("zzz", kind: .directory),
            entry("mmm", kind: .directory)
        ]

        let asc = model(entries, sort: FileSort(key: .name, ascending: true, directoriesFirst: true))
        #expect(asc.visibleEntries.map(\.name) == ["mmm", "zzz", "aaa.txt"])

        // Even descending, directories stay on top; only the key order within a group flips.
        let desc = model(
            entries,
            sort: FileSort(key: .name, ascending: false, directoriesFirst: true)
        )
        #expect(desc.visibleEntries.map(\.name) == ["zzz", "mmm", "aaa.txt"])
    }

    @Test("size sort orders by byte size")
    func sizeSort() {
        let subject = model(
            [entry("big", size: 1000), entry("small", size: 10), entry("mid", size: 100)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["small", "mid", "big"])
    }

    @Test("modified sort orders by date")
    func dateSort() {
        let subject = model(
            [
                entry("new", modified: Date(timeIntervalSince1970: 3000)),
                entry("old", modified: Date(timeIntervalSince1970: 1000)),
                entry("mid", modified: Date(timeIntervalSince1970: 2000))
            ],
            sort: FileSort(key: .modified, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["old", "mid", "new"])
    }

    @Test("extension sort groups by extension, then name")
    func extensionSort() {
        let subject = model(
            [entry("b.zip"), entry("c.txt"), entry("a.txt")],
            sort: FileSort(key: .fileExtension, ascending: true, directoriesFirst: false)
        )
        #expect(subject.visibleEntries.map(\.name) == ["a.txt", "c.txt", "b.zip"])
    }

    // MARK: - Hidden

    @Test("hidden entries are excluded unless showHidden is on")
    func hiddenToggle() {
        let entries = [entry("visible.txt"), entry(".secret", hidden: true)]

        let hiddenOff = model(entries, showHidden: false)
        #expect(hiddenOff.visibleEntries.map(\.name) == ["visible.txt"])

        let hiddenOn = model(
            entries,
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            showHidden: true
        )
        #expect(hiddenOn.visibleEntries.map(\.name) == [".secret", "visible.txt"])
    }

    @Test("toggling showHidden recomputes the visible list")
    func toggleRecomputes() {
        var subject = model([entry("visible.txt"), entry(".secret", hidden: true)])
        #expect(subject.count == 1)
        subject.showHidden = true
        #expect(subject.count == 2)
    }

    // MARK: - Filter

    @Test("type-to-filter matches case-insensitive substrings")
    func filterMatchesSubstring() {
        let subject = model(
            [entry("Report.pdf"), entry("image.png"), entry("report-2.pdf")],
            sort: FileSort(key: .name, ascending: true, directoriesFirst: false),
            filter: "report"
        )
        #expect(subject.visibleEntries.map(\.name) == ["report-2.pdf", "Report.pdf"])
    }

    @Test("empty filter matches everything")
    func emptyFilterMatchesAll() {
        let subject = model([entry("a.txt"), entry("b.txt")], filter: "")
        #expect(subject.count == 2)
    }

    // MARK: - Identity

    @Test("index(ofID:) locates an entry by its stable path identity")
    func indexByIdentity() {
        let target = entry("mid", size: 100)
        let subject = model(
            [entry("small", size: 10), target, entry("big", size: 1000)],
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        )
        #expect(subject.index(ofID: target.id) == 1)
        #expect(subject.index(ofID: .local("/test/absent")) == nil)
    }
}
