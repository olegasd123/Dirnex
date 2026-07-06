import Foundation
import Testing

@testable import DirnexCore

/// End-to-end tests for the copy/move operation engine (PLAN.md §M2): the clone-backed
/// happy paths, the conflict policies, cancellation, progress accounting, and — via test
/// backends that suppress cloning or force a cross-volume error — the chunked recursive
/// fallback and the move's copy-then-delete path.
@Suite("CopyEngine")
struct CopyEngineTests {
    let backend = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    // MARK: - Copy

    @Test("copies a file, leaving the original in place")
    func copiesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "hello")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend)

        #expect(report.succeeded)
        #expect(report.completedItems == 1)
        #expect(try contents(tree, "dest/a.txt") == "hello")
        #expect(try contents(tree, "a.txt") == "hello") // original untouched
    }

    @Test("copies a directory subtree")
    func copiesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
    }

    // MARK: - Move

    @Test("moves a file: original gone, destination present")
    func movesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "x")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        #expect(try contents(tree, "dest/a.txt") == "x")
        #expect(throws: VFSError.notFound(tree.vfsPath("a.txt"))) { try stat(tree, "a.txt") }
    }

    @Test("moves a directory subtree")
    func movesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .move,
            sources: [try stat(tree, "top")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
        #expect(throws: VFSError.notFound(tree.vfsPath("top"))) { try stat(tree, "top") }
    }

    @Test("a cross-volume move copies the bytes then deletes the source")
    func movesAcrossVolumes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "ferry me")
        try tree.makeDir("dest")

        let backend = CrossVolumeBackend()
        let op = FileOperation(
            kind: .move,
            sources: [try backend.stat(at: tree.vfsPath("a.txt"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        #expect(try contents(tree, "dest/a.txt") == "ferry me")
        #expect(throws: VFSError.notFound(tree.vfsPath("a.txt"))) { try backend.stat(
            at: tree.vfsPath("a.txt")
        ) }
    }

    // MARK: - Conflicts

    @Test("the default fail policy records a failure and leaves the existing item")
    func conflictFailRecordsFailure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend) // .fail default

        #expect(report.failures.count == 1)
        #expect(report.failures.first?.error == .alreadyExists(tree.vfsPath("dest/a.txt")))
        #expect(try contents(tree, "dest/a.txt") == "old") // untouched
    }

    @Test("skip leaves the existing item and records the source as skipped")
    func conflictSkip() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend, conflictPolicy: .skip)

        #expect(report.skipped == [tree.vfsPath("a.txt")])
        #expect(try contents(tree, "dest/a.txt") == "old")
    }

    @Test("overwrite replaces the existing item's contents")
    func conflictOverwrite() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend, conflictPolicy: .overwrite).succeeded)
        #expect(try contents(tree, "dest/a.txt") == "new")
        // No temporary detritus left behind.
        #expect(try backend.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["a.txt"])
    }

    @Test("keepBoth copies under a fresh name, leaving the original")
    func conflictKeepBoth() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "new")
        try tree.makeDir("dest")
        try tree.writeFile("dest/a.txt", contents: "old")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend, conflictPolicy: .keepBoth).succeeded)
        #expect(try contents(tree, "dest/a.txt") == "old")
        #expect(try contents(tree, "dest/a copy.txt") == "new")
    }

    // MARK: - Cancellation & progress

    @Test("cancelling before any work leaves a cancelled report and copies nothing")
    func cancelledCopiesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "x")
        try tree.makeDir("dest")

        let op = FileOperation(
            kind: .copy,
            sources: [try stat(tree, "a.txt")],
            destinationDirectory: tree.vfsPath("dest")
        )
        let report = CopyEngine.run(op, using: backend, isCancelled: { true })

        #expect(report.wasCancelled)
        #expect(report.completedItems == 0)
        #expect(throws: VFSError.notFound(tree.vfsPath("dest/a.txt"))) { try stat(tree, "dest/a.txt") }
    }

    @Test("progress runs from zero to the full byte total")
    func reportsProgress() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.bin", bytes: 4096)
        try tree.writeFile("b.bin", bytes: 2048)
        try tree.makeDir("dest")

        let sources = [try stat(tree, "a.bin"), try stat(tree, "b.bin")]
        let op = FileOperation(
            kind: .copy,
            sources: sources,
            destinationDirectory: tree.vfsPath("dest")
        )

        final class Box: @unchecked Sendable { var last: OperationProgress? }
        let box = Box()
        let report = CopyEngine.run(op, using: backend, onProgress: { box.last = $0 })

        #expect(report.completedBytes == 6144)
        let final = try #require(box.last)
        #expect(final.totalBytes == 6144)
        #expect(final.completedBytes == 6144)
        #expect(final.completedItems == 2)
    }

    // MARK: - Chunked fallback (no-clone backend)

    @Test("without cloning, a subtree copies by hand identically")
    func manualFallbackCopiesTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.makeDir("dest")

        let backend = NoCloneBackend()
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("top"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)
        #expect(try contents(tree, "dest/top/a.txt") == "a")
        #expect(try contents(tree, "dest/top/mid/b.txt") == "b")
    }

    @Test("without cloning, a nested symlink is duplicated as a symlink")
    func manualFallbackPreservesSymlink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top")
        try tree.symlink("top/link", to: "/some/target")
        try tree.makeDir("dest")

        let backend = NoCloneBackend()
        let op = FileOperation(
            kind: .copy,
            sources: [try backend.stat(at: tree.vfsPath("top"))],
            destinationDirectory: tree.vfsPath("dest")
        )
        #expect(CopyEngine.run(op, using: backend).succeeded)

        let link = try backend.stat(at: tree.vfsPath("dest/top/link"))
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "/some/target")
    }
}

// MARK: - Test backends

/// Wraps `LocalBackend` but always reports "no clone", forcing the engine down its
/// chunked recursive-copy fallback so that path is covered without needing two volumes.
private struct NoCloneBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws { try inner.moveItem(
        at: source,
        to: destination
    ) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}

/// Wraps `LocalBackend` but reports every rename as a cross-device error, exercising the
/// move engine's copy-then-delete fallback path.
private struct CrossVolumeBackend: VFSBackend {
    private let inner = LocalBackend()
    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV) // pretend every move crosses a volume
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }
}
