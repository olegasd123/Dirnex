import Foundation
import Testing

@testable import DirnexCore

@Suite("Panel")
struct PanelTests {
    private func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: name.hasPrefix("."),
            permissions: 0o644,
            inode: 0
        )
    }

    private func listing(_ names: [String], at path: String = "/dir") -> DirectoryListing {
        DirectoryListing(path: .local(path), entries: names.map { entry($0) })
    }

    private func panel(_ names: [String], sort: FileSort = .default) -> Panel {
        Panel(model: DirectoryModel(listing: listing(names), sort: sort))
    }

    private let flatSort = FileSort(key: .name, ascending: true, directoriesFirst: false)

    // MARK: - Cursor

    @Test("cursor clamps within bounds")
    func cursorClamps() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 99)
        #expect(subject.cursor == 2)
        subject.moveCursor(to: -5)
        #expect(subject.cursor == 0)
        subject.moveCursor(by: 1)
        #expect(subject.cursor == 1)
        subject.moveCursorToEnd()
        #expect(subject.cursor == 2)
        subject.moveCursorToStart()
        #expect(subject.cursor == 0)
    }

    @Test("currentEntry follows the cursor")
    func currentEntryFollowsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1)
        #expect(subject.currentEntry?.name == "b")
    }

    @Test("empty panel has no current entry and cursor stays at 0")
    func emptyPanel() {
        var subject = panel([])
        #expect(subject.currentEntry == nil)
        subject.moveCursor(to: 5)
        #expect(subject.cursor == 0)
    }

    // MARK: - Selection independent of cursor

    @Test("marking does not move the cursor")
    func markingKeepsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1)
        subject.toggleMark(at: 2)
        #expect(subject.cursor == 1)
        #expect(subject.isMarked(subject.model[2]))
    }

    @Test("toggle at cursor then advance marks a run")
    func markRun() {
        var subject = panel(["a", "b", "c", "d"], sort: flatSort)
        subject.toggleMarkAtCursorAndAdvance() // marks a, cursor -> b
        subject.toggleMarkAtCursorAndAdvance() // marks b, cursor -> c
        #expect(subject.cursor == 2)
        #expect(subject.selectedEntries.map(\.name) == ["a", "b"])
    }

    @Test("toggle removes an existing mark")
    func toggleRemoves() {
        var subject = panel(["a", "b"], sort: flatSort)
        subject.toggleMark(at: 0)
        subject.toggleMark(at: 0)
        #expect(subject.selectionCount == 0)
    }

    @Test("select all, invert, and clear")
    func selectAllInvertClear() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectAll()
        #expect(subject.selectionCount == 3)
        subject.invertSelection()
        #expect(subject.selectionCount == 0)
        subject.toggleMark(at: 1)
        subject.invertSelection()
        #expect(subject.selectedEntries.map(\.name) == ["a", "c"])
        subject.clearSelection()
        #expect(subject.selectionCount == 0)
    }

    // MARK: - Pattern (glob) selection

    @Test("selectMatching adds glob matches, deselectMatching removes them")
    func patternSelect() {
        var subject = panel(["a.txt", "b.txt", "c.jpg", "photo.JPG"], sort: flatSort)
        subject.selectMatching("*.txt")
        #expect(subject.selectedEntries.map(\.name) == ["a.txt", "b.txt"])

        subject.selectMatching("*.jpg") // case-insensitive: matches both .jpg and .JPG
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a.txt", "b.txt", "c.jpg", "photo.JPG"])

        subject.deselectMatching("*.txt")
        #expect(Set(subject.selectedEntries.map(\.name)) == ["c.jpg", "photo.JPG"])
    }

    // MARK: - Computed directory sizes (Space-on-dir)

    @Test("recording a directory size preserves the cursor by identity across the re-sort")
    func directorySizePreservesCursor() throws {
        func sizedFile(_ name: String, _ size: Int64) -> FileEntry {
            FileEntry(
                path: .local("/dir/\(name)"),
                name: name,
                kind: .file,
                byteSize: size,
                modificationDate: Date(timeIntervalSince1970: 0),
                creationDate: Date(timeIntervalSince1970: 0),
                isHidden: false,
                permissions: 0o644,
                inode: 0
            )
        }
        let entries = [entry("folder", kind: .directory), sizedFile("file.bin", 500)]
        var subject = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/dir"), entries: entries),
            sort: FileSort(key: .size, ascending: true, directoriesFirst: false)
        ))
        // Unsized directory (0) sorts before the 500-byte file.
        #expect(subject.model.visibleEntries.map(\.name) == ["folder", "file.bin"])
        subject.moveCursor(to: 1)
        #expect(subject.currentEntry?.name == "file.bin")

        let folder = try #require(subject.model.visibleEntries.first { $0.name == "folder" })
        subject.setDirectorySize(folder.id, bytes: 1000) // folder now heaviest → moves last
        #expect(subject.model.visibleEntries.map(\.name) == ["file.bin", "folder"])
        // The cursor followed file.bin by identity, not by its old row index.
        #expect(subject.currentEntry?.name == "file.bin")
        #expect(subject.cursor == 0)
    }

    // MARK: - Navigation & refresh

    @Test("navigating to a new directory resets cursor and clears selection")
    func navigationResets() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 2)
        subject.selectAll()

        subject.setListing(listing(["x", "y"], at: "/other"))
        #expect(subject.path == .local("/other"))
        #expect(subject.cursor == 0)
        #expect(subject.selectionCount == 0)
    }

    @Test("same-directory refresh keeps the cursor on the same entry by identity")
    func refreshPreservesCursorByIdentity() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 1) // on "b"
        #expect(subject.currentEntry?.name == "b")

        // A file appears before "b"; row index would shift, identity must not.
        subject.setListing(listing(["a", "aa", "b", "c"], at: "/dir"))
        #expect(subject.currentEntry?.name == "b")
        #expect(subject.cursor == 2)
    }

    @Test("refresh prunes marks for vanished entries but keeps the rest")
    func refreshPrunesSelection() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.selectAll() // a, b, c

        subject.setListing(listing(["a", "c"], at: "/dir")) // b deleted
        #expect(Set(subject.selectedEntries.map(\.name)) == ["a", "c"])
    }

    @Test("refresh clamps cursor when the current entry disappears")
    func refreshClampsCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 2) // on "c"
        subject.setListing(listing(["a", "b"], at: "/dir")) // c deleted
        #expect(subject.cursor == 1)
    }

    // MARK: - View settings preserve cursor

    @Test("changing sort keeps the cursor on the same entry")
    func sortPreservesCursor() {
        var subject = panel(["a", "b", "c"], sort: flatSort)
        subject.moveCursor(to: 0) // on "a"
        subject.setSort(FileSort(key: .name, ascending: false, directoriesFirst: false))
        #expect(subject.currentEntry?.name == "a") // now last row
        #expect(subject.cursor == 2)
    }

    @Test("filtering out the current entry clamps the cursor")
    func filterClampsCursor() {
        var subject = panel(["apple", "banana", "cherry"], sort: flatSort)
        subject.moveCursor(to: 1) // on "banana"
        subject.setFilter("a") // matches apple, banana
        #expect(subject.currentEntry?.name == "banana")
        subject.setFilter("cherry") // banana gone; only cherry remains
        #expect(subject.currentEntry?.name == "cherry")
        #expect(subject.cursor == 0)
    }

    // MARK: - Open targets

    @Test("openTarget navigates into directories but not files")
    func openTargets() throws {
        let entries = [entry("file.txt"), entry("folder", kind: .directory)]
        let subject = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/dir"), entries: entries),
            sort: flatSort
        ))
        let file = try #require(subject.model.visibleEntries.first { $0.name == "file.txt" })
        let folder = try #require(subject.model.visibleEntries.first { $0.name == "folder" })
        #expect(subject.openTarget(for: file) == nil)
        #expect(subject.openTarget(for: folder) == .local("/dir/folder"))
    }

    @Test("parentPath is the containing directory")
    func parentPath() {
        let subject = panel(["a"], sort: flatSort)
        #expect(subject.parentPath == .local("/"))
    }
}
