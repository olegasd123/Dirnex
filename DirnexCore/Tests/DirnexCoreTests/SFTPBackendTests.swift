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
        // The uniform default applies to every path on a single-backend implementation.
        #expect(sut.capabilities(for: path("/home/oleg")) == .read)
        #expect(sut.capabilities(for: path("/home/oleg")).deleteStrategy == .unsupported)
    }

    @Test("lists a remote directory into FileEntry rows with child paths")
    func listsDirectory() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        total 12
        drwxr-xr-x  2 oleg staff 4096 Jul 10 16:19 .
        drwxr-xr-x 20 oleg staff 4096 Jul  9 10:00 ..
        -rw-r--r--  1 oleg staff  128 Jul 10 16:19 notes.txt
        drwxr-xr-x  2 oleg staff 4096 Jul 10 16:19 photos
        """
        let entries = try backend(transport).listDirectory(at: path("/home/oleg"))
        #expect(entries.count == 2)

        let notes = try #require(entries.first { $0.name == "notes.txt" })
        #expect(notes.kind == .file)
        #expect(notes.byteSize == 128)
        #expect(notes.path == path("/home/oleg/notes.txt"))

        let photos = try #require(entries.first { $0.name == "photos" })
        #expect(photos.isDirectory)
        #expect(photos.path == path("/home/oleg/photos"))
    }

    @Test("stat names the entry from the queried path, not the ls -ld output")
    func statUsesPathName() throws {
        let transport = FakeSFTPTransport()
        transport.items["/home/oleg/docs"] = "drwxr-xr-x 5 oleg staff 4096 Jul 10 16:19 /home/oleg/docs"
        let entry = try backend(transport).stat(at: path("/home/oleg/docs"))
        #expect(entry.name == "docs")
        #expect(entry.kind == .directory)
        #expect(entry.path == path("/home/oleg/docs"))
    }

    @Test("maps a transport not-found to VFSError.notFound with the queried path")
    func mapsNotFound() {
        let transport = FakeSFTPTransport()
        transport.listError = .notFound
        #expect(throws: VFSError.notFound(path("/missing"))) {
            try backend(transport).listDirectory(at: path("/missing"))
        }
    }

    @Test("maps a transport permission failure to VFSError.permissionDenied")
    func mapsPermissionDenied() {
        let transport = FakeSFTPTransport()
        transport.listError = .permissionDenied
        #expect(throws: VFSError.permissionDenied(path("/root"))) {
            try backend(transport).listDirectory(at: path("/root"))
        }
    }

    @Test("maps a generic transport failure to VFSError.io")
    func mapsGenericFailure() {
        let transport = FakeSFTPTransport()
        transport.listError = .failure("connection reset")
        #expect(throws: VFSError.io(path: path("/x"), code: EIO)) {
            try backend(transport).listDirectory(at: path("/x"))
        }
    }

    @Test("a stat that parses to nothing is a not-found")
    func statEmptyIsNotFound() {
        let transport = FakeSFTPTransport()
        transport.items["/gone"] = "" // empty output
        #expect(throws: VFSError.notFound(path("/gone"))) {
            try backend(transport).stat(at: path("/gone"))
        }
    }

    @Test("rejects a path that belongs to another backend")
    func rejectsForeignPath() {
        let sut = backend(FakeSFTPTransport())
        #expect(throws: (any Error).self) {
            try sut.listDirectory(at: .local("/etc"))
        }
        // A different SFTP account is also foreign.
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

/// A canned `SFTPTransport`: returns per-path listings/items, or throws a configured error, so the
/// backend is exercised without a live server (PLAN.md §2 "the app is a thin client").
private final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var items: [String: String] = [:]
    var listError: SFTPTransportError?
    var statError: SFTPTransportError?

    func listDirectory(_ remotePath: String) throws -> String {
        if let listError { throw listError }
        return listings[remotePath] ?? "total 0\n"
    }

    func statItem(_ remotePath: String) throws -> String {
        if let statError { throw statError }
        return items[remotePath] ?? ""
    }
}
