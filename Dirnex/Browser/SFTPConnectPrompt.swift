import AppKit
import DirnexCore

/// The modal "Connect to Server" form: host, port, username, and a private-key file. Returns a
/// validated `SFTPLocation` plus the identity-file path, or `nil` when cancelled or left empty.
/// Deliberately small (an `NSAlert` with a grid accessory, like the pattern-select prompt) — a
/// saved-connections sidebar and Keychain password auth are later passes.
enum SFTPConnectPrompt {
    struct Form {
        let location: SFTPLocation
        let identityFile: String
    }

    @MainActor
    static func run(over window: NSWindow?) -> Form? {
        let host = textField(placeholder: "example.com")
        let port = textField(placeholder: "22")
        port.stringValue = String(SFTPLocation.defaultPort)
        let user = textField(placeholder: NSUserName())
        user.stringValue = NSUserName()
        let identity = textField(placeholder: "~/.ssh/id_ed25519")
        if let known = defaultIdentityFile() { identity.stringValue = known }

        let grid = NSGridView(views: [
            [label("Host:"), host],
            [label("Port:"), port],
            [label("User:"), user],
            [label("Key file:"), identity]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for column in [host, port, user, identity] {
            column.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Browse a remote SFTP account. Key-based authentication only."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = grid
        alert.window.initialFirstResponder = host

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form(host: host, port: port, user: user, identity: identity)
    }

    // MARK: - Reading the form

    @MainActor
    private static func form(
        host: NSTextField,
        port: NSTextField,
        user: NSTextField,
        identity: NSTextField
    ) -> Form? {
        let hostValue = trimmed(host)
        let userValue = trimmed(user)
        let keyValue = expandingTilde(trimmed(identity))
        // Reject empties, and anything starting with "-" so a value can't be read as an sftp option.
        guard isSafeArgument(hostValue), isSafeArgument(userValue), !keyValue.isEmpty else { return nil }
        let portValue = Int(trimmed(port)) ?? SFTPLocation.defaultPort
        let location = SFTPLocation(host: hostValue, port: portValue, username: userValue)
        return Form(location: location, identityFile: keyValue)
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
    }

    private static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    private static func defaultIdentityFile() -> String? {
        let candidates = ["id_ed25519", "id_rsa"].map {
            NSHomeDirectory() + "/.ssh/" + $0
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    // MARK: - Views

    @MainActor private static func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private static func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    @MainActor private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
