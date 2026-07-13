import AppKit
import DirnexCore

/// The modal "Connect to Server" form: host, port, username, and either a private-key file or a
/// password. Returns a validated `SFTPLocation`, the chosen `SFTPAuthentication`, and (for password
/// auth) the plaintext, or `nil` when cancelled or left incomplete. Deliberately small (an `NSAlert`
/// with a grid accessory) — a saved-connections sidebar is a later pass.
enum SFTPConnectPrompt {
    struct Form {
        let location: SFTPLocation
        let authentication: SFTPAuthentication
        /// The plaintext password for `.password` auth (the caller files it in the Keychain and
        /// hands it to the transport); `nil` for key auth.
        let password: String?
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
        let secret = secureField(placeholder: "Password")

        let method = NSSegmentedControl(
            labels: ["Private Key", "Password"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        method.selectedSegment = 0
        let toggle = AuthModeToggle(keyField: identity, passwordField: secret)
        method.target = toggle
        method.action = #selector(AuthModeToggle.methodChanged(_:))
        toggle.methodChanged(method) // set the initial enabled state

        let grid = NSGridView(views: [
            [label("Host:"), host],
            [label("Port:"), port],
            [label("User:"), user],
            [label("Auth:"), method],
            [label("Key file:"), identity],
            [label("Password:"), secret]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for control in [host, port, user, identity, secret, method] {
            control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Browse a remote SFTP account by key or password."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = grid
        alert.window.initialFirstResponder = host

        let fields = Fields(host: host, port: port, user: user, identity: identity, secret: secret)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form(fields: fields, usingKey: method.selectedSegment == 0)
    }

    // MARK: - Reading the form

    /// The editable controls of the form, grouped so reading them is one argument.
    private struct Fields {
        let host: NSTextField
        let port: NSTextField
        let user: NSTextField
        let identity: NSTextField
        let secret: NSSecureTextField
    }

    @MainActor
    private static func form(fields: Fields, usingKey: Bool) -> Form? {
        let hostValue = trimmed(fields.host)
        let userValue = trimmed(fields.user)
        // Reject empties, and anything starting with "-" so a value can't be read as an sftp option.
        guard isSafeArgument(hostValue), isSafeArgument(userValue) else { return nil }
        let portValue = Int(trimmed(fields.port)) ?? SFTPLocation.defaultPort
        let location = SFTPLocation(host: hostValue, port: portValue, username: userValue)

        if usingKey {
            let keyValue = expandingTilde(trimmed(fields.identity))
            guard !keyValue.isEmpty else { return nil }
            return Form(
                location: location,
                authentication: .key(identityFile: keyValue),
                password: nil
            )
        }
        // Passwords aren't trimmed — leading/trailing spaces can be significant — but a blank one is
        // certainly a mistake, so it's rejected rather than sent as an empty password.
        let secretValue = fields.secret.stringValue
        guard !secretValue.isEmpty else { return nil }
        return Form(location: location, authentication: .password, password: secretValue)
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

    @MainActor private static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
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

/// Enables the key-file or the password field to match the selected authentication method, so the
/// irrelevant one is visibly greyed out while both stay in the grid.
@MainActor
private final class AuthModeToggle: NSObject {
    private let keyField: NSTextField
    private let passwordField: NSTextField

    init(keyField: NSTextField, passwordField: NSTextField) {
        self.keyField = keyField
        self.passwordField = passwordField
    }

    @objc func methodChanged(_ sender: NSSegmentedControl) {
        let usingKey = sender.selectedSegment == 0
        keyField.isEnabled = usingKey
        passwordField.isEnabled = !usingKey
    }
}
