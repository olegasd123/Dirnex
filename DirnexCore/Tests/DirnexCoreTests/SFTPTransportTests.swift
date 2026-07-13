import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPTransport helpers")
struct SFTPTransportTests {
    // MARK: - SFTPBatchCommand

    @Test("list wraps the path in quotes")
    func listQuotesPath() {
        #expect(SFTPBatchCommand.list("/home/oleg/docs") == "ls -la \"/home/oleg/docs\"")
    }

    @Test("list escapes embedded quotes and backslashes so the batch parser can't be confused")
    func listEscapesSpecials() {
        #expect(SFTPBatchCommand.list("/a b/c") == "ls -la \"/a b/c\"")
        #expect(SFTPBatchCommand.list("/weird\"name") == "ls -la \"/weird\\\"name\"")
        #expect(SFTPBatchCommand.list("/back\\slash") == "ls -la \"/back\\\\slash\"")
    }

    @Test("the write verbs quote each path argument")
    func writeVerbsQuotePaths() {
        #expect(
            SFTPBatchCommand.makeDirectory("/home/oleg/new dir") == "mkdir \"/home/oleg/new dir\""
        )
        #expect(SFTPBatchCommand.removeFile("/home/oleg/a.txt") == "rm \"/home/oleg/a.txt\"")
        #expect(SFTPBatchCommand.removeDirectory("/home/oleg/sub") == "rmdir \"/home/oleg/sub\"")
    }

    @Test("the two-argument verbs quote both paths in order")
    func twoArgumentVerbsQuoteBothPaths() {
        #expect(SFTPBatchCommand.rename("/a b", to: "/c d") == "rename \"/a b\" \"/c d\"")
        // ln takes the existing target first, the new link path second (like ln(1)).
        #expect(
            SFTPBatchCommand.createSymbolicLink("/link", target: "rel/target") == "ln -s \"rel/target\" \"/link\""
        )
        // get pulls remote→local; put pushes local→remote.
        #expect(
            SFTPBatchCommand.download("/remote/f", to: "/tmp/f") == "get \"/remote/f\" \"/tmp/f\""
        )
        #expect(SFTPBatchCommand.upload("/tmp/f", to: "/remote/f") == "put \"/tmp/f\" \"/remote/f\"")
    }

    // MARK: - SFTPTransportError.classify

    @Test("a not-found stderr classifies as notFound")
    func classifyNotFound() {
        #expect(SFTPTransportError.classify(stderr: "Can't ls: \"/x\" not found") == .notFound)
        #expect(SFTPTransportError.classify(stderr: "No such file or directory") == .notFound)
    }

    @Test("a permission-denied stderr classifies as permissionDenied")
    func classifyPermissionDenied() {
        let stderr = "remote readdir(\"/var/db/sudo/\"): Permission denied"
        #expect(SFTPTransportError.classify(stderr: stderr) == .permissionDenied)
    }

    @Test(
        "a failed key auth (both 'no such file' warning and 'Permission denied') is permissionDenied"
    )
    func classifyBadKeyPrefersPermissionDenied() {
        // A missing/rejected identity file prints a key warning *and* the auth failure; the auth
        // failure is the actionable one, so it must win over the stray "no such file".
        let stderr = """
        Warning: Identity file /tmp/bad_key not accessible: No such file or directory.
        oleg@mac: Permission denied (publickey,password).
        """
        #expect(SFTPTransportError.classify(stderr: stderr) == .permissionDenied)
    }

    @Test("any other stderr is surfaced verbatim as a failure")
    func classifyFailure() {
        #expect(
            SFTPTransportError.classify(stderr: "  kex_exchange failed\n") == .failure(
                "kex_exchange failed"
            )
        )
        // An empty stderr still yields a usable message.
        if case let .failure(message) = SFTPTransportError.classify(stderr: "   ") {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected a .failure for empty stderr")
        }
    }
}
