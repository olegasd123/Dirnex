import Foundation

/// A `VFSBackend` that browses one remote SSH/SFTP account as a folder tree (PLAN.md §M5
/// "`SFTPBackend`: browse/copy through the standard queue"). This is the *browse* half — the
/// analogue of `ArchiveBackend`'s read-only first pass — so it answers `list`/`stat` and nothing
/// more; the write primitives and byte transfer arrive next.
///
/// All the logic lives here and is tested: path handling, listing parsing (`SFTPListingParser`),
/// the stat interpretation, error mapping. The only non-hermetic piece — the network — is an
/// injected `SFTPTransport`, so the backend is exercised end-to-end with a fake and needs no live
/// server (PLAN.md §2). The app supplies a `Process`-driven transport over the system `sftp` tool
/// (the `bsdtar`-style sidestep of a swift-nio-ssh/libssh2 dependency).
///
/// The backend's `id` encodes the account (`sftp://user@host:port`), so a `VFSPath` under it names
/// both which account and which remote path; the app's composite backend routes on that id.
public struct SFTPBackend: VFSBackend {
    /// The remote account this backend is connected to — its identity.
    public let location: SFTPLocation
    private let transport: any SFTPTransport

    public init(location: SFTPLocation, transport: any SFTPTransport) {
        self.location = location
        self.transport = transport
    }

    public var id: VFSBackendID { .sftp(location) }

    /// Read-only for now — browsing a remote account as folders. The write primitives
    /// (mkdir/rename/delete) and byte transfer, plus the widened `[.read, .write, .rename]`
    /// capabilities that light up the M5 "capability degradation" path (no Trash → confirmed
    /// permanent delete, no clone → chunked), arrive with the byte-transfer pass. Advertising
    /// `.write` before copy-in works end-to-end would let the UI start a paste the backend can't
    /// finish, so the honest capability today is `.read`.
    public var capabilities: VFSCapabilities { .read }

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try requireOwnBackend(path)
        let raw = try mapErrors(path) { try transport.listDirectory(path.path) }
        return SFTPListingParser.parse(raw)
            .filter { $0.name != "." && $0.name != ".." }
            .map { entry(from: $0, in: path) }
    }

    /// Stat a single remote item. `sftp` has no `ls -d`, so this reads one `ls -la <path>`: when the
    /// result carries a self `.` row, `path` is a directory and that row *is* its stat; otherwise it
    /// is a file (or symlink) whose single row we return. An empty/unmatched result is `notFound`.
    public func stat(at path: VFSPath) throws -> FileEntry {
        try requireOwnBackend(path)
        let raw = try mapErrors(path) { try transport.listDirectory(path.path) }
        let rows = SFTPListingParser.parse(raw)
        if let dot = rows.first(where: { $0.name == "." }) {
            // The `.` row is the directory itself — use its stat but our queried identity/name.
            return entry(from: dot, at: path, name: path.lastComponent, forceDirectory: true)
        }
        guard let match = rows.first(where: { $0.name == path.lastComponent }) else {
            throw VFSError.notFound(path)
        }
        return entry(from: match, at: path, name: path.lastComponent)
    }

    /// Everything on one host shares a single connection, so all its jobs serialize (cheap, no
    /// I/O — as `VFSBackend.volumeIdentifier` requires): two transfers over one SSH channel would
    /// only contend, not parallelize.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "\(SFTPLocation.scheme)\(location.host):\(location.port)"
    }

    // MARK: - Mapping

    private func requireOwnBackend(_ path: VFSPath) throws {
        guard path.backend == id else {
            throw VFSError.unsupported("Path \(path) does not belong to \(location.descriptor).")
        }
    }

    /// Normalize a transport failure onto the shared `VFSError` vocabulary, attaching the
    /// `VFSPath` the transport (which only knows a raw string) couldn't. A `VFSError` thrown from
    /// deeper is passed through unchanged.
    private func mapErrors<T>(_ path: VFSPath, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SFTPTransportError {
            switch error {
            case .notFound: throw VFSError.notFound(path)
            case .permissionDenied: throw VFSError.permissionDenied(path)
            case .failure: throw VFSError.io(path: path, code: EIO)
            }
        }
    }

    private func entry(from parsed: SFTPListingParser.Entry, in directory: VFSPath) -> FileEntry {
        entry(from: parsed, at: directory.appending(parsed.name), name: parsed.name)
    }

    private func entry(
        from parsed: SFTPListingParser.Entry,
        at path: VFSPath,
        name: String,
        forceDirectory: Bool = false
    ) -> FileEntry {
        let kind: FileEntry.Kind = forceDirectory ? .directory : parsed.kind
        return FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: parsed.byteSize,
            modificationDate: parsed.modificationDate,
            // `ls`/SFTP exposes no birth time; reuse the modification date, as `ArchiveBackend` does.
            creationDate: parsed.modificationDate,
            isHidden: name.hasPrefix("."),
            permissions: parsed.permissions,
            inode: 0,
            symlinkDestination: parsed.symlinkDestination,
            // `sftp` doesn't resolve a symlink's target; report a nominal file target so it renders
            // as a live link rather than a broken one, matching `ArchiveBackend`.
            symlinkTargetKind: kind == .symlink ? .file : nil
        )
    }
}
