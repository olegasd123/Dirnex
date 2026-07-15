import Foundation

/// The shell a terminal drawer runs, and the environment it runs in (PLAN.md §M6 "Terminal drawer:
/// bottom pane following active panel's cwd").
///
/// Pure: this assembles the executable, `argv[0]` and the environment, and launches nothing — the
/// app hands the result to a pseudo-terminal, the same division `ExternalDiffTool` and `GitCommand`
/// already use. The environment is the part that earns its tests: it decides which of the user's
/// dotfiles run, and one wrong value makes the drawer scribble in files that belong to Terminal.app.
public enum ShellKind: String, Sendable, Hashable, CaseIterable {
    case zsh
    case bash
    case fish
    /// Anything else — ksh, dash, nushell, a hand-built shell. Treated as POSIX-compatible, which
    /// is right for everything except `fish` (the one popular shell that quotes differently, and
    /// therefore the one that gets its own case).
    case other

    /// The shell an executable path names, by basename: `/opt/homebrew/bin/zsh` is `zsh`.
    public init(executablePath: String) {
        let name = executablePath.split(separator: "/").last.map(String.init) ?? executablePath
        self = ShellKind(rawValue: name) ?? .other
    }
}

/// A resolved shell launch: what to exec, under which `argv[0]`, with which arguments.
public struct TerminalShell: Sendable, Hashable {
    public let executablePath: String
    public let kind: ShellKind

    public init(executablePath: String) {
        self.executablePath = executablePath
        kind = ShellKind(executablePath: executablePath)
    }

    /// The shell to run for `shellPath` (the user's `$SHELL`), falling back to `defaultShellPath`
    /// when it is missing, empty, or not an absolute path.
    public static func login(shellPath: String?) -> TerminalShell {
        guard let shellPath, shellPath.hasPrefix("/") else {
            return TerminalShell(executablePath: defaultShellPath)
        }
        return TerminalShell(executablePath: shellPath)
    }

    /// macOS's default login shell since Catalina, and the fallback when `$SHELL` says nothing
    /// usable. Note this is only a *fallback*: the user's real shell is whatever `$SHELL` holds,
    /// and on an account created before Catalina that is still `/bin/bash`.
    public static let defaultShellPath = "/bin/zsh"

    /// `argv[0]`. **The leading dash is the whole login-shell mechanism**: a shell inspects its own
    /// `argv[0]` and, on finding a dash, reads the login files (`~/.zprofile`, `~/.bash_profile`)
    /// as well as the interactive ones. Terminal.app launches `-zsh` for exactly this reason, and
    /// matching it is what makes the drawer's `PATH` the same `PATH` the user's terminal has —
    /// Homebrew's `shellenv` lives in `~/.zprofile` on a stock setup, so an interactive-only shell
    /// would leave the drawer unable to find half the user's tools.
    ///
    /// No arguments accompany it: the dash asks for login, and the pseudo-terminal is what makes
    /// the shell interactive, so neither `-l` nor `-i` is needed.
    public var execName: String {
        let name = executablePath.split(separator: "/").last.map(String.init) ?? executablePath
        return "-" + name
    }

    /// Arguments after `argv[0]` — none, per `execName`.
    public var arguments: [String] { [] }

    /// The child's environment: `base` (the app's own, normally) with the terminal identity
    /// replaced by ours.
    ///
    /// **`TERM_PROGRAM` is load-bearing, and naming ourselves honestly is what keeps us out of the
    /// user's files.** `/etc/zshrc` ends with `[ -r "/etc/zshrc_$TERM_PROGRAM" ] && .
    /// "/etc/zshrc_$TERM_PROGRAM"`, and `/etc/bashrc` does the same — so this variable chooses a
    /// system dotfile to source. Apple ships `/etc/zshrc_Apple_Terminal`, and claiming that name
    /// would buy an OSC 7 emitter (which is how a drawer might learn the shell's directory) at the
    /// price of everything else in that file: with `TERM_SESSION_ID` set it creates
    /// `~/.zsh_sessions/$TERM_SESSION_ID.session`, repoints `HISTFILE` at a per-session file, and
    /// restores-then-deletes saved session state. The drawer would be quietly taking over
    /// Terminal.app's session bookkeeping and splitting the user's shell history. `Dirnex` names us
    /// for what we are, and `/etc/zshrc_Dirnex` does not exist, so nothing extra is sourced. (We
    /// need no OSC 7 anyway — see `ShellWorkingDirectory`, which asks the kernel instead.)
    ///
    /// The inherited identity is *stripped* rather than left alone because Dirnex may well have
    /// been launched **from** a terminal (`open`, `xcodebuild`, a shell), in which case the app's
    /// own environment carries that terminal's `TERM_SESSION_ID`/`ITERM_SESSION_ID`, and passing
    /// them down would have our child claiming to be a session of somebody else's window.
    public func environment(
        inheriting base: [String: String],
        appVersion: String,
        localeIdentifier: String? = nil
    ) -> [String: String] {
        var environment = base
        for key in Self.strippedVariables { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Dirnex"
        environment["TERM_PROGRAM_VERSION"] = appVersion
        // Only when the app was given nothing: a GUI process inherits no `LANG`, and without one
        // the shell's tools fall back to the C locale and mangle every non-ASCII filename — the
        // same reason Terminal.app offers "Set locale environment variables on startup".
        if environment["LANG"]?.isEmpty ?? true, let localeIdentifier {
            environment["LANG"] = "\(localeIdentifier).UTF-8"
        }
        return environment
    }

    /// The identity of whichever terminal launched *us*, which must not be handed to our child.
    private static let strippedVariables = [
        "TERM_SESSION_ID",
        "ITERM_SESSION_ID",
        "ITERM_PROFILE",
        "LC_TERMINAL",
        "LC_TERMINAL_VERSION"
    ]
}
