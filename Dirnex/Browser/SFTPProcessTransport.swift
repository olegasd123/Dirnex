import DirnexCore
import Foundation

/// Drives the system `sftp` tool to satisfy an `SFTPBackend`'s `listDirectory` — the non-hermetic
/// half of SFTP browse (PLAN.md §M5), mirroring `ArchiveMounter`/`SpotlightSearchRunner`. All the
/// parsing, escaping, and error classification live in `DirnexCore` (`SFTPListingParser`,
/// `SFTPBatchCommand`, `SFTPTransportError.classify`); this just spawns `sftp -b -` in batch mode
/// with a key-auth identity file and pipes one command in.
///
/// Key auth with `BatchMode=yes` is deliberate: OpenSSH reads a password only from a TTY, so a
/// spawned `sftp` could never answer a password prompt — batch mode disables the prompt entirely
/// and fails fast instead of hanging. Password/Keychain auth (which needs a pseudo-terminal) is a
/// later pass; key auth is the path the plan lists first and the one verifiable here.
struct SFTPProcessTransport: SFTPTransport {
    let location: SFTPLocation
    /// Path to the private key used for key-based auth.
    let identityFile: String
    /// Seconds to wait for the connection before giving up — a dead host must not hang the pane.
    var connectTimeout: Int = 15

    func listDirectory(_ remotePath: String) throws -> String {
        try run(batch: SFTPBatchCommand.list(remotePath))
    }

    // MARK: - Writes

    func makeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.makeDirectory(remotePath))
    }

    func rename(_ source: String, to destination: String) throws {
        _ = try run(batch: SFTPBatchCommand.rename(source, to: destination))
    }

    func removeFile(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeFile(remotePath))
    }

    func removeDirectory(_ remotePath: String) throws {
        _ = try run(batch: SFTPBatchCommand.removeDirectory(remotePath))
    }

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        _ = try run(batch: SFTPBatchCommand.createSymbolicLink(remotePath, target: target))
    }

    @discardableResult
    func download(_ remotePath: String, to localPath: String) throws -> Int64 {
        _ = try run(batch: SFTPBatchCommand.download(remotePath, to: localPath))
        // `sftp get` writes the whole file, so its final on-disk size is the bytes transferred.
        return localFileSize(localPath)
    }

    @discardableResult
    func upload(_ localPath: String, to remotePath: String) throws -> Int64 {
        _ = try run(batch: SFTPBatchCommand.upload(localPath, to: remotePath))
        // The local source's size is what `put` sent — cheaper and safer than re-statting the
        // remote (which would cost another round trip).
        return localFileSize(localPath)
    }

    private func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// The remote working (home) directory reported by `pwd`, to land in on connect. Doubles as a
    /// connection test: it fails fast (classified) when auth, the host, or the key is wrong.
    func resolveHomeDirectory() throws -> String {
        let output = try run(batch: SFTPBatchCommand.printWorkingDirectory)
        let marker = "Remote working directory: "
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: marker) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "/"
    }

    // MARK: - Process

    /// Run one `sftp` batch command and return its stdout. `sftp` prints the `sftp>` prompt echo and
    /// the `ls` rows to stdout (the parser ignores the echo) and errors to stderr, exiting non-zero
    /// on a failed command — so a non-zero status is classified from stderr. Blocks on `sftp`; call
    /// it off the main thread.
    private func run(batch command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = arguments

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SFTPTransportError.failure("Couldn’t launch sftp.")
        }

        // Feed the single batch command, then EOF so sftp runs it and exits.
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? input.fileHandleForWriting.close()

        // Drain stderr on a background queue while reading stdout here, so neither pipe can fill and
        // deadlock the other on a large listing.
        let errorQueue = DispatchQueue(label: "com.dirnex.sftp.stderr")
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        errorQueue.async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw SFTPTransportError.classify(
                stderr: String(bytes: errorData, encoding: .utf8) ?? ""
            )
        }
        return String(bytes: outputData, encoding: .utf8) ?? ""
    }

    private var arguments: [String] {
        [
            "-i", identityFile,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Trust-on-first-use for the host key: a fresh host is added to known_hosts rather than
            // aborting, but a *changed* key still fails (the MITM guard stays intact).
            "-o", "StrictHostKeyChecking=accept-new",
            "-P", String(location.port),
            "-b", "-",
            "\(location.username)@\(location.host)"
        ]
    }
}
