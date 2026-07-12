import Foundation

/// The non-hermetic boundary beneath an `SFTPBackend`: it performs remote operations over an
/// SSH/SFTP connection and hands back raw output for the backend to parse. Everything above it —
/// path handling, listing parsing, capability reporting, error mapping — is pure and tested in
/// `DirnexCore`; the transport is where real network I/O lives, so it is injected (PLAN.md §2 "the
/// app is a thin client").
///
/// The app supplies a `Process`-driven implementation over the system `ssh`/`sftp` tools — the
/// same move M4 made with `bsdtar` instead of linking libarchive, sidestepping a heavyweight
/// dependency (swift-nio-ssh/libssh2) and its live-server test gate. Tests supply a fake that
/// returns canned listings, so the whole backend is exercised without a server.
///
/// Methods are synchronous and may block on the network — the backend is always called off the
/// main thread by the operation engine and the panel's background list, never on it.
public protocol SFTPTransport: Sendable {
    /// The raw `ls -la`-style listing of the directory at `remotePath`, one entry per line
    /// (including the `total` header and the `.`/`..` rows, which the parser discards).
    func listDirectory(_ remotePath: String) throws -> String

    /// The raw `ls -ld`-style single line describing `remotePath` itself (not its children).
    func statItem(_ remotePath: String) throws -> String
}

/// A remote operation's failure, in the few shapes the backend needs to distinguish so it can map
/// them onto the shared `VFSError` vocabulary (a missing path, a denied path, or everything else).
/// The app's transport classifies a nonzero `ls` exit (its stderr) into one of these; the fake
/// throws them directly, so the backend's error mapping is tested without a server.
public enum SFTPTransportError: Error, Sendable, Equatable {
    /// The remote path does not exist (`ls`: "No such file or directory").
    case notFound
    /// The remote account may not read the path (`ls`: "Permission denied").
    case permissionDenied
    /// Any other failure — a dropped connection, an auth failure, an unexpected error — with a
    /// human-readable reason for logs.
    case failure(String)
}
