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

    // MARK: - SFTPProcessArguments

    private let location = SFTPLocation(host: "mac", port: 2222, username: "oleg")

    @Test("key auth passes the identity file and forces BatchMode=yes with -b -")
    func keyAuthArguments() {
        let arguments = SFTPProcessArguments.batch(
            location: location,
            authentication: .key(identityFile: "/keys/id_ed25519"),
            connectTimeout: 15
        )
        #expect(arguments == [
            "-i", "/keys/id_ed25519",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "-P", "2222",
            "-b", "-",
            "oleg@mac"
        ])
    }

    @Test("password auth drops the key and -b, offering only the password method, interactive")
    func passwordAuthArguments() {
        let arguments = SFTPProcessArguments.batch(
            location: location,
            authentication: .password,
            connectTimeout: 20
        )
        #expect(!arguments.contains("-i"))
        // No `-b`: it forces BatchMode=yes, which disables the prompt SSH_ASKPASS must answer.
        #expect(!arguments.contains("-b"))
        #expect(!arguments.contains("BatchMode=yes"))
        // Only `password` — keyboard-interactive stalls on a wrong password under askpass.
        #expect(arguments.contains("PreferredAuthentications=password"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(arguments.contains("ConnectTimeout=20"))
        #expect(arguments.last == "oleg@mac")
    }

    // MARK: - SFTPTransportError.detect (interactive-mode command errors)

    @Test("detect returns nil for benign interactive stderr")
    func detectIgnoresBenignStderr() {
        #expect(SFTPTransportError.detect(stderr: "") == nil)
        #expect(SFTPTransportError.detect(stderr: "Connected to example.com.") == nil)
        #expect(SFTPTransportError.detect(stderr: "Welcome to the SFTP service") == nil)
        let hostKeyNote = "Warning: Permanently added 'host' (ED25519) to the list of known hosts."
        #expect(SFTPTransportError.detect(stderr: hostKeyNote) == nil)
    }

    @Test("detect maps interactive command failures that exited zero")
    func detectMapsCommandFailures() {
        #expect(SFTPTransportError.detect(stderr: "Can't ls: \"/x\" not found") == .notFound)
        #expect(
            SFTPTransportError.detect(stderr: "remote readdir(\"/root\"): Permission denied") == .permissionDenied
        )
        // A write verb's failure has no "not found"/"denied" marker — the prefix/suffix catches it.
        #expect(SFTPTransportError.detect(stderr: "remote mkdir \"/x\": Failure") != nil)
        #expect(SFTPTransportError.detect(stderr: "Couldn't rename file \"/a\" to \"/b\"") != nil)
    }
}
