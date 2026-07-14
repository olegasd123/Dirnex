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
/// `sftp`'s batch `ls -la` both lists a directory (many rows) and stats a single item (one row,
/// or — for a directory — a self `.` row whose stat *is* the directory's), so `SFTPBackend`
/// interprets one raw listing for both. The write primitives each map onto one `sftp` batch verb
/// (`mkdir`/`rename`/`rm`/`rmdir`/`ln`/`get`/`put`); the backend composes them (e.g. it empties a
/// directory before `rmdir`, since `sftp` has no recursive remove). Every method is synchronous and
/// may block on the network — the backend is always called off the main thread by the operation
/// engine and the panel's background list, never on it.
public protocol SFTPTransport: Sendable {
    /// The raw `sftp` `ls -la` output for `remotePath` — one entry per line. For a directory this
    /// is its children (each printed as a full path, plus the `.`/`..` self/parent rows); for a
    /// file it is that single file's row. Throws `SFTPTransportError` on a remote failure.
    func listDirectory(_ remotePath: String) throws -> String

    /// Create a single remote directory (`mkdir`). Throws on any failure (the parent is missing,
    /// something already occupies the path, permission denied) — the backend never relies on
    /// intermediate directories being created, mirroring `mkdir(2)`.
    func makeDirectory(_ remotePath: String) throws

    /// Rename or move a remote item within the account (`rename`). Only valid within one
    /// connection; a cross-backend move is copy-then-delete, decided above the transport.
    func rename(_ source: String, to destination: String) throws

    /// Remove a remote regular file or symbolic link (`rm`) — the link itself, never its target.
    /// Directories are emptied and removed with `removeDirectory` by the backend.
    func removeFile(_ remotePath: String) throws

    /// Remove an *empty* remote directory (`rmdir`); the backend deletes the contents first, since
    /// `sftp` has no recursive remove.
    func removeDirectory(_ remotePath: String) throws

    /// Create a remote symbolic link at `remotePath` pointing at the raw (unresolved) `target`
    /// (`ln -s`) — used when a copied/mirrored tree contains a symlink.
    func createSymbolicLink(_ remotePath: String, target: String) throws

    /// Download the remote file at `remotePath` to a local path (`get`, or `get -a` to **resume**),
    /// returning the local file's total size once the transfer finishes. When `resume` is true the
    /// download picks up from the local file's current length instead of restarting, so `sftp`
    /// fetches only the bytes past that offset — the caller computes the transferred delta from the
    /// pre-existing size (see `SFTPBackend.copyFile`).
    @discardableResult
    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64

    /// Upload the local file at `localPath` to a remote path (`put`, or `put -a` to **resume**),
    /// returning the local source's size (which is the remote file's total size once the transfer
    /// finishes). When `resume` is true the upload picks up from the remote file's current length,
    /// so `sftp` sends only the bytes past that offset.
    @discardableResult
    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64
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

    /// An error found in the stderr of an interactive (password-auth) session that *exited zero*, or
    /// `nil` if the stderr shows no failure. `sftp` in interactive mode doesn't abort on a bad
    /// command — it prints one error line and carries on — so the transport can't rely on the exit
    /// code there and scans for `sftp`'s error lines instead. Benign lines (`Connected to …`, a
    /// server banner, a `Warning: Permanently added …` host-key note) match none of these and yield
    /// `nil`, so a successful command isn't mistaken for a failure.
    public static func detect(stderr: String) -> SFTPTransportError? {
        let lowered = stderr.lowercased()
        if lowered.contains("permission denied") { return .permissionDenied }
        if lowered.contains("not found") || lowered.contains("no such file") { return .notFound }
        // `sftp` prints one failed-command line per error; these forms cover the write verbs
        // (mkdir/rename/rm/get/put) whose failure text ends in ": Failure" or starts "Couldn't …".
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces).lowercased()
            if text.hasPrefix("can't ") || text.hasPrefix("couldn't ") || text.hasPrefix("cannot ")
                || text.hasPrefix("remote ") || text.hasSuffix(": failure") {
                return .failure(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
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

    /// The batch line that creates a remote directory: `mkdir "…"`.
    public static func makeDirectory(_ remotePath: String) -> String {
        "mkdir \(quote(remotePath))"
    }

    /// The batch line that renames/moves a remote item: `rename "src" "dst"`.
    public static func rename(_ source: String, to destination: String) -> String {
        "rename \(quote(source)) \(quote(destination))"
    }

    /// The batch line that removes a remote file or symlink: `rm "…"`.
    public static func removeFile(_ remotePath: String) -> String {
        "rm \(quote(remotePath))"
    }

    /// The batch line that removes an empty remote directory: `rmdir "…"`.
    public static func removeDirectory(_ remotePath: String) -> String {
        "rmdir \(quote(remotePath))"
    }

    /// The batch line that creates a remote symbolic link: `ln -s "target" "link"` (`sftp`'s `ln`
    /// takes the existing target first, the new link path second, like `ln(1)`).
    public static func createSymbolicLink(_ remotePath: String, target: String) -> String {
        "ln -s \(quote(target)) \(quote(remotePath))"
    }

    /// The batch line that downloads a remote file to a local path: `get "remote" "local"`, or
    /// `get -a "remote" "local"` to **resume** — `sftp` seeks to the local file's current length and
    /// fetches only the remainder, instead of restarting from zero.
    public static func download(_ remotePath: String, to localPath: String, resume: Bool = false) -> String {
        "get \(resume ? "-a " : "")\(quote(remotePath)) \(quote(localPath))"
    }

    /// The batch line that uploads a local file to a remote path: `put "local" "remote"`, or
    /// `put -a "local" "remote"` to **resume** — `sftp` seeks past the remote file's current length
    /// and sends only the remainder.
    public static func upload(_ localPath: String, to remotePath: String, resume: Bool = false) -> String {
        "put \(resume ? "-a " : "")\(quote(localPath)) \(quote(remotePath))"
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

/// How the CLI-driven transport authenticates against a server. Carries no secret for `.password`:
/// the password is resolved from the Keychain by the app and fed to `sftp` out-of-band via an
/// `SSH_ASKPASS` helper (never on the command line, never in this value, never on disk), so an auth
/// *method* is safe to describe and thread around like an `SFTPLocation`.
public enum SFTPAuthentication: Sendable, Hashable, Codable {
    /// Public-key auth with the private key at `identityFile` — `sftp`'s native non-interactive path.
    case key(identityFile: String)
    /// Password auth; the password is supplied out-of-band, never held here.
    case password
}

/// Builds the `sftp` process arguments (after the executable path) for a one-command session. Pure
/// and tested so the security-sensitive flag assembly — which auth methods are offered, and crucially
/// whether the interactive password prompt is enabled — is verified without spawning `sftp`, the
/// same reason `SFTPBatchCommand` is pure.
///
/// The two modes differ fundamentally, verified live against OpenSSH 10:
/// - **Key auth uses `-b -`**: quiet, fail-fast batch semantics (no `sftp>` echo, a non-zero exit on
///   a failed command). `-b` also forces `-oBatchMode=yes` onto `ssh`, which is what makes key auth
///   fully non-interactive. This is the shipped, verified browse/transfer path — left untouched.
/// - **Password auth cannot use `-b`**: it forces `BatchMode=yes`, which disables the password prompt
///   entirely (`ssh` would report "no more authentication methods"). So password auth runs `sftp`
///   *interactively* over a piped stdin — the prompt is answered out-of-band by `SSH_ASKPASS` — which
///   means stdout carries `sftp>` echo lines (`SFTPListingParser` skips them) and a failed command
///   exits zero (so the transport must scan stderr with `detect(stderr:)`, not just the exit code).
///   Only the `password` method is offered: `keyboard-interactive` stalls for a minute on a *wrong*
///   password when `SSH_ASKPASS` auto-answers it (macOS PAM), which would hang the pane on a typo;
///   and `PubkeyAuthentication=no` stops a machine's stray authorized key from bypassing the choice.
public enum SFTPProcessArguments {
    public static func batch(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        connectTimeout: Int
    ) -> [String] {
        let common = [
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Trust-on-first-use: a fresh host is added to known_hosts, a *changed* key still fails.
            "-o", "StrictHostKeyChecking=accept-new",
            "-P", String(location.port)
        ]
        let target = "\(location.username)@\(location.host)"
        switch authentication {
        case let .key(identityFile):
            return ["-i", identityFile, "-o", "BatchMode=yes"] + common + ["-b", "-", target]
        case .password:
            // No `-b`: it would disable the prompt. Interactive over piped stdin; `SSH_ASKPASS`
            // answers the prompt (wired by the transport's environment).
            return [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                // One attempt, so a wrong password fails fast instead of re-prompting three times.
                "-o", "NumberOfPasswordPrompts=1"
            ] + common + [target]
        }
    }
}
