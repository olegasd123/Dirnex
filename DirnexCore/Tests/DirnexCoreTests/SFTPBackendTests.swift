import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPBackend")
struct SFTPBackendTests {
    private let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")

    private func backend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: remote)
    }

    @Test("reports its account as identity and is read-only")
    func identityAndCapabilities() {
        let sut = backend(FakeSFTPTransport())
        #expect(sut.id == .sftp(location))
        #expect(sut.capabilities == .read)
        #expect(sut.capabilities(for: path("/home/oleg")) == .read)
        #expect(sut.capabilities(for: path("/home/oleg")).deleteStrategy == .unsupported)
    }

    @Test("lists a remote directory into FileEntry rows, dropping . and .. with child paths")
    func listsDirectory() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/..
        -rw-r--r--    ? oleg staff  128 Jul 13 00:09 /home/oleg/notes.txt
        drwxr-xr-x    ? oleg staff   64 Jul 13 00:09 /home/oleg/photos
        """
        let entries = try backend(transport).listDirectory(at: path("/home/oleg"))
        #expect(entries.count == 2) // . and .. filtered out

        let notes = try #require(entries.first { $0.name == "notes.txt" })
        #expect(notes.kind == .file)
        #expect(notes.byteSize == 128)
        #expect(notes.path == path("/home/oleg/notes.txt"))

        let photos = try #require(entries.first { $0.name == "photos" })
        #expect(photos.isDirectory)
        #expect(photos.path == path("/home/oleg/photos"))
    }

    @Test("stats a directory from its self '.' row, named for the queried path")
    func statsDirectoryFromDotRow() throws {
        let transport = FakeSFTPTransport()
        // `ls -la <dir>` returns the directory's children plus its self `.` row.
        transport.listings["/home/oleg/docs"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/docs/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/docs/..
        -rw-r--r--    ? oleg staff   10 Jul 13 00:09 /home/oleg/docs/a.txt
        """
        let entry = try backend(transport).stat(at: path("/home/oleg/docs"))
        #expect(entry.name == "docs")
        #expect(entry.kind == .directory)
        #expect(entry.path == path("/home/oleg/docs"))
        #expect(entry.byteSize == 192) // the '.' row's own size, not a child's
    }

    @Test("stats a file from its single row")
    func statsFileFromSingleRow() throws {
        let transport = FakeSFTPTransport()
        // `ls -la <file>` returns just the file's row (no '.'/'..').
        transport.listings["/home/oleg/notes.txt"] =
            "-rw-r--r--    ? oleg staff 42 Jul 13 00:09 /home/oleg/notes.txt"
        let entry = try backend(transport).stat(at: path("/home/oleg/notes.txt"))
        #expect(entry.name == "notes.txt")
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 42)
        #expect(entry.path == path("/home/oleg/notes.txt"))
    }

    @Test("a stat that parses to nothing is a not-found")
    func statEmptyIsNotFound() {
        let transport = FakeSFTPTransport()
        transport.listings["/gone"] = ""
        #expect(throws: VFSError.notFound(path("/gone"))) {
            try backend(transport).stat(at: path("/gone"))
        }
    }

    @Test("maps a transport not-found to VFSError.notFound with the queried path")
    func mapsNotFound() {
        let transport = FakeSFTPTransport()
        transport.error = .notFound
        #expect(throws: VFSError.notFound(path("/missing"))) {
            try backend(transport).listDirectory(at: path("/missing"))
        }
    }

    @Test("maps a transport permission failure to VFSError.permissionDenied")
    func mapsPermissionDenied() {
        let transport = FakeSFTPTransport()
        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(path("/root"))) {
            try backend(transport).listDirectory(at: path("/root"))
        }
    }

    @Test("maps a generic transport failure to VFSError.io")
    func mapsGenericFailure() {
        let transport = FakeSFTPTransport()
        transport.error = .failure("connection reset")
        #expect(throws: VFSError.io(path: path("/x"), code: EIO)) {
            try backend(transport).listDirectory(at: path("/x"))
        }
    }

    @Test("rejects a path that belongs to another backend")
    func rejectsForeignPath() {
        let sut = backend(FakeSFTPTransport())
        #expect(throws: (any Error).self) {
            try sut.listDirectory(at: .local("/etc"))
        }
        let other = VFSPath(backend: .sftp(SFTPLocation(host: "other", username: "x")), path: "/")
        #expect(throws: (any Error).self) {
            try sut.stat(at: other)
        }
    }

    @Test("all jobs on one host share a volume identifier")
    func volumeIdentifierPerHost() {
        let sut = backend(FakeSFTPTransport())
        let one = sut.volumeIdentifier(for: path("/a"))
        let two = sut.volumeIdentifier(for: path("/b/c"))
        #expect(one != nil)
        #expect(one == two)
    }
}

/// A canned `SFTPTransport`: returns per-path `ls -la` text, or throws a configured error, so the
/// backend is exercised without a live server (PLAN.md §2 "the app is a thin client").
private final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var error: SFTPTransportError?

    func listDirectory(_ remotePath: String) throws -> String {
        if let error { throw error }
        return listings[remotePath] ?? ""
    }
}
