import Foundation

/// The non-hermetic boundary beneath an `SFTPBackend`: it performs remote operations over an
/// SSH/SFTP connection and hands back raw output for the backend to parse. Everything above it —
/// path handling, listing parsing, capability reporting, error mapping — is pure and tested in
/// `DirnexCore`; the transport is where real network I/O lives, so it is injected (PLAN.md §2 "the
/// app is a thin client").
///
/// The app supplies a `Process`-driven implementation over the system `sftp` tool — the same move
/// M4 made with `bsdtar` instead of linking libarchive, sidestepping a heavyweight dependency
/// (swift-nio-ssh/libssh2). Tests supply a fake that returns canned listings, so the whole backend
/// is exercised without a server.
///
/// One method suffices for the read-only browse: `sftp`'s batch `ls -la` both lists a directory
/// (many rows) and stats a single item (one row, or — for a directory — a self `.` row whose stat
/// *is* the directory's), so `SFTPBackend` interprets one raw listing for both. The method is
/// synchronous and may block on the network — the backend is always called off the main thread by
/// the operation engine and the panel's background list, never on it.
public protocol SFTPTransport: Sendable {
    /// The raw `sftp` `ls -la` output for `remotePath` — one entry per line. For a directory this
    /// is its children (each printed as a full path, plus the `.`/`..` self/parent rows); for a
    /// file it is that single file's row. Throws `SFTPTransportError` on a remote failure.
    func listDirectory(_ remotePath: String) throws -> String
}

/// A remote operation's failure, in the few shapes the backend needs to distinguish so it can map
/// them onto the shared `VFSError` vocabulary (a missing path, a denied path, or everything else).
/// `classify(stderr:)` turns a nonzero `sftp` invocation's stderr into one of these, tested here so
/// the app transport stays a thin spawn-and-classify shell.
public enum SFTPTransportError: Error, Sendable, Equatable {
    /// The remote path does not exist (`sftp`: `Can't ls: "…" not found`).
    case notFound
    /// The remote account may not read the path (`sftp`: `remote readdir("…"): Permission denied`).
    case permissionDenied
    /// Any other failure — a dropped connection, an auth failure, an unexpected error — with a
    /// human-readable reason for logs and the UI.
    case failure(String)

    /// Classify a failed `sftp` batch invocation's stderr. The two recoverable shapes a browse
    /// hits — a vanished path and an unreadable one — get their own semantic cases so the panel
    /// reacts correctly; anything else is surfaced verbatim.
    public static func classify(stderr: String) -> SFTPTransportError {
        let text = stderr.lowercased()
        // Permission denied is checked first: a failed key-auth attempt prints both an
        // "identity file … no such file" warning *and* "Permission denied", and the latter is the
        // actionable diagnosis (check the username/key), not a vanished remote path.
        if text.contains("permission denied") {
            return .permissionDenied
        }
        if text.contains("not found") || text.contains("no such file") {
            return .notFound
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(trimmed.isEmpty ? "The SFTP server reported an error." : trimmed)
    }
}

/// Builds the `sftp` batch commands the transport feeds on stdin. Pure and tested so the escaping —
/// the one place a remote path with spaces or quotes could break the command — is verified without
/// a server. `sftp`'s batch parser splits on whitespace but honours double quotes and backslash
/// escapes, so a path is wrapped in quotes with `\` and `"` escaped.
public enum SFTPBatchCommand {
    /// The batch line that lists (or stats) `remotePath`: `ls -la "…"`.
    public static func list(_ remotePath: String) -> String {
        "ls -la \(quote(remotePath))"
    }

    /// The batch line that prints the remote working directory (`pwd`), used to discover the home
    /// directory to land in on connect.
    public static let printWorkingDirectory = "pwd"

    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
