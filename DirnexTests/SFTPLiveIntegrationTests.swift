import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// End-to-end SFTP browse against a real server, exercising the actual `SFTPProcessTransport`
/// (spawning `sftp`) → `SFTPBackend` → `SFTPListingParser` chain. Gated on a config file so it never
/// runs in CI (which has no server): drop a JSON file at `/tmp/dirnex_sftp_live_test.json` with
/// `{ "host": …, "port": 22, "user": …, "identityFile": …, "remotePath": … }` for a reachable
/// key-auth account (a file, not env vars, because `xcodebuild` doesn't forward the shell
/// environment to the test runner). Without the file the suite is skipped.
@Suite("SFTP live integration", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLiveIntegrationTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(location: config.location, identityFile: config.identityFile)
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("resolves the remote home directory (proves auth + connection)")
    func resolvesHome() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(location: config.location, identityFile: config.identityFile)
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
        // backend) and degrade its capabilities to read-only.
        #expect(composite.capabilities(for: path) == .read)
        let entries = try composite.listDirectory(at: path)
        #expect(!entries.isEmpty)
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
