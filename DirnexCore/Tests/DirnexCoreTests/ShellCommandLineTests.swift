import Foundation
import Testing

@testable import DirnexCore

@Suite("ShellCommandLine")
struct ShellCommandLineTests {
    /// A directory name is attacker-controlled data (unzip something from the internet and you can
    /// be browsing it), and it lands on the command line of an interactive shell. This exact name
    /// was verified against real `zsh` and `bash`: both entered the directory, neither substitution
    /// fired.
    private let hostileName = #"it's a "test" $(touch /tmp/pwned) `touch /tmp/pwned2` ;rm -rf boom; & |x"#

    @Test("POSIX quoting neutralizes every metacharacter, closing and reopening for a quote")
    func posixQuotingIsInert() {
        let quoted = ShellQuoting.quoted(hostileName, for: .zsh)
        // Single quotes have no escapes, so the only thing to handle is the quote itself.
        #expect(
            quoted == #"'it'\''s a "test" $(touch /tmp/pwned) `touch /tmp/pwned2` ;rm -rf boom; & |x'"#
        )
        // Every dangerous construct survives as literal text rather than syntax.
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
    }

    @Test("a quote is the only POSIX escape, and it does not leave the string open")
    func posixQuoteBalances() {
        // Balance check: outside the '\'' bridges, quoting must open and close cleanly.
        #expect(ShellQuoting.quoted("a'b", for: .bash) == #"'a'\''b'"#)
        #expect(ShellQuoting.quoted("plain", for: .bash) == "'plain'")
        #expect(ShellQuoting.quoted("", for: .bash) == "''")
    }

    @Test("fish escapes inside single quotes instead, where POSIX's bridge would corrupt the path")
    func fishQuotingUsesBackslashes() {
        // fish honours \ and ' escapes inside single quotes, so the POSIX '\'' would leave a stray
        // backslash in the directory name.
        #expect(ShellQuoting.quoted("a'b", for: .fish) == #"'a\'b'"#)
        #expect(ShellQuoting.quoted(#"back\slash"#, for: .fish) == #"'back\\slash'"#)
        // A dollar or backtick still needs nothing: single quotes suppress expansion in fish too.
        #expect(ShellQuoting.quoted("$(boom)", for: .fish) == "'$(boom)'")
    }

    @Test("unknown shells are quoted as POSIX")
    func otherQuotesAsPOSIX() {
        #expect(ShellQuoting.quoted("a'b", for: .other) == ShellQuoting.quoted("a'b", for: .zsh))
    }

    @Test("changeDirectory clears the line first, so a half-typed command cannot be executed")
    func changeDirectoryClearsTypedText() {
        let command = ShellCommandLine.changeDirectory(to: "/Users/me", kind: .zsh)
        // ^U kills to the line start, ^K to the end: bash's ^U alone leaves the tail of a line
        // abandoned with the cursor in the middle, which would then run with our cd appended.
        #expect(command.hasPrefix("\u{15}\u{0B}"))
        #expect(command == "\u{15}\u{0B} cd -- '/Users/me'\n")
    }

    @Test("changeDirectory offers history the leading space and ends the line")
    func changeDirectoryShape() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: .bash)
        #expect(command.contains(" cd -- "))
        #expect(command.hasSuffix("\n"))
    }

    @Test("changeDirectory ends option parsing so a directory named like a flag stays a path")
    func changeDirectoryEndsOptions() {
        #expect(
            ShellCommandLine.changeDirectory(to: "/tmp/-p", kind: .zsh).contains("cd -- '/tmp/-p'")
        )
    }

    @Test("fish gets a plain cd, whose -- handling is not the shell's to promise")
    func fishOmitsOptionTerminator() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: .fish)
        #expect(command == "\u{15}\u{0B} cd '/tmp'\n")
        #expect(!command.contains("--"))
    }

    @Test("a hostile directory name produces one cd command and no second command")
    func hostileNameStaysOneCommand() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp/" + hostileName, kind: .zsh)
        // Exactly one line: the newline we add is the only one, so nothing can run on its own.
        #expect(command.filter { $0 == "\n" }.count == 1)
        #expect(command.hasSuffix("\n"))
    }
}
