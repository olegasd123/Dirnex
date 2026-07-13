import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// End-to-end SFTP browse *and write* against a real server, exercising the actual
/// `SFTPProcessTransport` (spawning `sftp`) → `SFTPBackend` → `SFTPListingParser` chain, including a
/// mkdir/upload/download/recursive-remove round trip. Gated on a config file so it never runs in CI
/// (which has no server): drop a JSON file at `/tmp/dirnex_sftp_live_test.json` with
/// `{ "host": …, "port": 22, "user": …, "identityFile": …, "remotePath": … }` for a reachable
/// key-auth account (a file, not env vars, because `xcodebuild` doesn't forward the shell
/// environment to the test runner). Without the file the suite is skipped.
@Suite("SFTP live integration", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLiveIntegrationTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            identityFile: config.identityFile
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("resolves the remote home directory (proves auth + connection)")
    func resolvesHome() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            identityFile: config.identityFile
        )
        let home = try transport.resolveHomeDirectory()
        #expect(home.hasPrefix("/"))
    }

    @Test("lists a real remote directory into FileEntry rows under the sftp backend")
    func listsRemoteDirectory() throws {
        let (backend, config) = try makeBackend()
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let entries = try backend.listDirectory(at: path)

        #expect(!entries.isEmpty)
        // The `.`/`..` self/parent rows are dropped; every child carries the sftp backend id.
        #expect(!entries.contains { $0.name == "." || $0.name == ".." })
        for entry in entries {
            #expect(entry.path.backend == .sftp(config.location))
            #expect(entry.path == path.appending(entry.name))
        }
    }

    @Test("stats the queried directory as a directory")
    func statsRemoteDirectory() throws {
        let (backend, config) = try makeBackend()
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        let entry = try backend.stat(at: path)
        #expect(entry.isDirectory)
        #expect(entry.path == path)
    }

    @Test("browses through CompositeBackend routing after connectSFTP")
    func browsesThroughCompositeBackend() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(location: config.location, identityFile: config.identityFile)
        let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        // The composite must route the sftp path to the connection registered above (not the local
        // backend) and report its writable-but-Trash-less capabilities.
        #expect(composite.capabilities(for: path) == [.read, .write, .rename])
        let entries = try composite.listDirectory(at: path)
        #expect(!entries.isEmpty)
    }

    @Test("round-trips a write end-to-end: mkdir → upload → list → download → recursive remove")
    func writeRoundTrip() throws {
        let (backend, config) = try makeBackend()
        let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
        // A unique scratch subtree under the remote path so a stray run never clobbers real data.
        let dir = base.appending("dirnex_write_test_\(UUID().uuidString)")

        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("dirnex_sftp_\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let localSource = scratch.appendingPathComponent("hello.txt")
        let payload = Data("hello over sftp \(UUID().uuidString)".utf8)
        try payload.write(to: localSource)

        // mkdir on the remote, then upload the local file into it.
        try backend.createDirectory(at: dir)
        let remoteFile = dir.appending("hello.txt")
        try backend.copyFile(
            at: .local(localSource.path),
            to: remoteFile,
            progress: { _ in },
            isCancelled: { false }
        )

        // Listing the new remote directory shows the upload with its true size.
        let listed = try backend.listDirectory(at: dir)
        let uploaded = try #require(listed.first { $0.name == "hello.txt" })
        #expect(uploaded.byteSize == Int64(payload.count))

        // Download it back and confirm the bytes survived the round trip.
        let localDest = scratch.appendingPathComponent("roundtrip.txt")
        try backend.copyFile(
            at: remoteFile,
            to: .local(localDest.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(try Data(contentsOf: localDest) == payload)

        // Recursive remove empties and deletes the subtree; the directory is gone afterwards.
        try backend.removeItem(at: dir)
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: dir)
        }
    }

    @Test("maps a missing remote path to VFSError.notFound")
    func missingPathIsNotFound() throws {
        let (backend, config) = try makeBackend()
        let missing = VFSPath(
            backend: .sftp(config.location),
            path: config.remotePath + "/dirnex_definitely_missing_xyz"
        )
        #expect(throws: VFSError.notFound(missing)) {
            try backend.listDirectory(at: missing)
        }
    }
}

/// Reads the live-SFTP test coordinates from a well-known JSON file; `nil` disables the suite.
enum SFTPLiveEnvironment {
    struct Config {
        let location: SFTPLocation
        let identityFile: String
        let remotePath: String
    }

    /// The opt-in config path. A file here turns the suite on; its absence keeps it off in CI.
    static let configPath = "/tmp/dirnex_sftp_live_test.json"

    private struct File: Decodable {
        let host: String
        let port: Int?
        let user: String
        let identityFile: String
        let remotePath: String
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Config(
            location: SFTPLocation(
                host: file.host,
                port: file.port ?? SFTPLocation.defaultPort,
                username: file.user
            ),
            identityFile: file.identityFile,
            remotePath: file.remotePath
        )
    }
}
