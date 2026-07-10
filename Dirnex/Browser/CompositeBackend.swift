import DirnexCore
import Foundation

/// The pane's backend: routes each `VFSPath` to the concrete backend that owns it — the
/// real `LocalBackend` for on-disk paths, a lazily-mounted read-only `ArchiveBackend` for
/// `archive:…` paths (PLAN.md §M4 "cash in the VFS abstraction — browse zip/tar as folders").
///
/// Composing, rather than swapping, the pane's backend keeps every existing `self.backend`
/// call site — listing, stat, sizing, copy/move, the shared queue — working unchanged; only
/// the routing is new. An archive is mounted on its first list/stat by spawning `bsdtar`
/// off-main (`ArchiveMounter`, the non-hermetic I/O boundary like `SpotlightSearchRunner`)
/// and cached, so navigating within one never re-reads it. Archives are a static snapshot
/// this pass, so the cache is never invalidated.
final class CompositeBackend: VFSBackend, @unchecked Sendable {
    let local: LocalBackend
    /// Mounted archives keyed by their on-disk path. Guarded by `lock` because listing runs
    /// on detached tasks — two panes can mount the same archive concurrently.
    private let lock = NSLock()
    private var mounted: [String: ArchiveBackend] = [:]

    init(local: LocalBackend) {
        self.local = local
    }

    /// The composite presents the local backend's identity and capabilities as its primary —
    /// per-path capability degradation for a virtual location is enforced at the panel (an
    /// archive pane greys its mutations), matching the search-results pane.
    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try backend(for: path).listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        try backend(for: path).stat(at: path)
    }

    func createDirectory(at path: VFSPath) throws {
        try backend(for: path).createDirectory(at: path)
    }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try backend(for: source).moveItem(at: source, to: destination)
    }

    func removeItem(at path: VFSPath) throws {
        try backend(for: path).removeItem(at: path)
    }

    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath? {
        try backend(for: path).trashItem(at: path)
    }

    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        try backend(for: source).cloneItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try backend(for: source).copyFile(
            at: source,
            to: destination,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try backend(for: destination).createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try backend(for: source).copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? {
        // The queue calls this for every source of every job and it must stay cheap — never
        // mount an archive here. A non-local path reports "one indistinguishable volume".
        path.backend == .local ? local.volumeIdentifier(for: path) : nil
    }

    // MARK: - Routing

    private func backend(for path: VFSPath) throws -> any VFSBackend {
        if path.backend == .local { return local }
        if let archivePath = path.backend.archivePath { return try mountedArchive(at: archivePath) }
        throw VFSError.unsupported("No backend can handle \(path).")
    }

    private func mountedArchive(at archivePath: String) throws -> ArchiveBackend {
        lock.lock()
        defer { lock.unlock() }
        if let cached = mounted[archivePath] { return cached }
        let toc = try ArchiveMounter.readTableOfContents(ofArchiveAt: archivePath)
        let backend = ArchiveBackend(archiveOnDiskPath: archivePath, toc: toc)
        mounted[archivePath] = backend
        return backend
    }
}

/// Reads an archive's table of contents by spawning `bsdtar -tvf` and handing the verbose
/// listing to the pure `ArchiveTOC` parser. The non-hermetic subprocess I/O lives here in the
/// app layer, mirroring `SpotlightSearchRunner`; all parsing stays tested in `DirnexCore`.
enum ArchiveMounter {
    static func readTableOfContents(ofArchiveAt archivePath: String) throws -> ArchiveTOC {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tvf", archivePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr so a libarchive warning neither pollutes the listing nor risks a
        // second-pipe deadlock; a real failure shows up as a non-zero exit below.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported("Couldn’t run bsdtar to open the archive.")
        }
        // Read to EOF before waiting so a large table of contents can't deadlock a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            let name = (archivePath as NSString).lastPathComponent
            throw VFSError.unsupported("Couldn’t read the archive “\(name)”.")
        }
        return ArchiveTOC(verboseListing: text)
    }
}
