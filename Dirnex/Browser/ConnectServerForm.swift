import AppKit
import DirnexCore

/// The editable body of the Connect-to-Server dialog: a protocol picker (SFTP | SMB) over two
/// per-protocol field sets, with the SMB set's `smb://user@host/share` address field parsing
/// live into editable host / share / user fields and back (PLAN.md §M5 "Address entry is
/// Finder-⌘K-style … parses into editable host / share / user fields shown below it … kept in
/// sync"). `ConnectServerPrompt` wraps this in an `NSAlert`; this owns the controls, the toggles,
/// the two-way URL sync, and reading a validated `Form` back out.
///
/// The two protocols keep independent field sets (rather than sharing host/user) so switching
/// protocols never carries one's values — or one's defaults, like SFTP's `NSUserName()` — into the
/// other. Only the rows for the selected protocol are shown; the accessory is sized once to the
/// taller layout so toggling never resizes the modal.
@MainActor
final class ConnectServerForm: NSObject, NSTextFieldDelegate {
    /// The view to hand `NSAlert.accessoryView` — a fixed-size container holding the grid.
    let accessoryView: NSView
    /// The field the dialog should focus first, per the initially-selected protocol.
    private(set) var initialFirstResponder: NSView

    // Protocol picker.
    private let protocolControl: NSSegmentedControl

    // SMB fields.
    private let address = ConnectFormFactory.textField(placeholder: "smb://host/share")
    private let smbHost = ConnectFormFactory.textField(placeholder: "nas.local")
    private let smbShare = ConnectFormFactory.textField(placeholder: "Media")
    private let smbUser = ConnectFormFactory.textField(placeholder: "guest (leave blank)")
    private let smbPassword = ConnectFormFactory.secureField(
        placeholder: "Password (blank for guest)"
    )

    // SFTP fields.
    private let sftpHost = ConnectFormFactory.textField(placeholder: "example.com")
    private let sftpPort = ConnectFormFactory.textField(placeholder: "22")
    private let sftpUser = ConnectFormFactory.textField(placeholder: NSUserName())
    private let keyFile = ConnectFormFactory.textField(placeholder: "~/.ssh/id_ed25519")
    private let sftpSecret = ConnectFormFactory.secureField(placeholder: "Password")
    private let authControl: NSSegmentedControl

    // Shared.
    private let saveName = ConnectFormFactory.textField(placeholder: "Optional — save in sidebar")

    // Rows toggled per protocol.
    private var smbRows: [NSGridRow] = []
    private var sftpRows: [NSGridRow] = []

    /// The SMB port isn't a visible field — it rides the address URL (default 445 elided). Parsed
    /// out of the URL and folded back in when rebuilding it, so a non-default port round-trips.
    private var smbPort = SMBLocation.defaultPort
    /// Guards the two-way sync from re-entrancy while it writes the paired field.
    private var isSyncing = false

    init(prefill: ServerConnection?) {
        protocolControl = NSSegmentedControl(
            labels: ["SFTP", "SMB"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        authControl = NSSegmentedControl(
            labels: ["Private Key", "Password"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        let grid = NSGridView(views: [[ConnectFormFactory.label("Protocol:"), protocolControl]])
        accessoryView = NSView()
        initialFirstResponder = sftpHost
        super.init()

        buildRows(in: grid)
        wireControls()
        applyPrefill(prefill)
        layout(grid: grid)
        updateVisibility()
    }

    // MARK: - Building

    private func buildRows(in grid: NSGridView) {
        smbRows = [
            grid.addRow(with: [ConnectFormFactory.label("Address:"), address]),
            grid.addRow(with: [ConnectFormFactory.label("Host:"), smbHost]),
            grid.addRow(with: [ConnectFormFactory.label("Share:"), smbShare]),
            grid.addRow(with: [ConnectFormFactory.label("User:"), smbUser]),
            grid.addRow(with: [ConnectFormFactory.label("Password:"), smbPassword])
        ]
        sftpRows = [
            grid.addRow(with: [ConnectFormFactory.label("Host:"), sftpHost]),
            grid.addRow(with: [ConnectFormFactory.label("Port:"), sftpPort]),
            grid.addRow(with: [ConnectFormFactory.label("User:"), sftpUser]),
            grid.addRow(with: [ConnectFormFactory.label("Auth:"), authControl]),
            grid.addRow(with: [ConnectFormFactory.label("Key file:"), keyFile]),
            grid.addRow(with: [ConnectFormFactory.label("Password:"), sftpSecret])
        ]
        grid.addRow(with: [ConnectFormFactory.label("Save as:"), saveName])

        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let controls: [NSView] = [
            protocolControl, address, smbHost, smbShare, smbUser, smbPassword,
            sftpHost, sftpPort, sftpUser, authControl, keyFile, sftpSecret, saveName
        ]
        for control in controls {
            control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
    }

    private func wireControls() {
        protocolControl.selectedSegment = 0
        protocolControl.target = self
        protocolControl.action = #selector(protocolChanged)

        authControl.selectedSegment = 0
        authControl.target = self
        authControl.action = #selector(authChanged)

        sftpPort.stringValue = String(SFTPLocation.defaultPort)
        sftpUser.stringValue = NSUserName()
        if let known = ConnectFormFactory.defaultIdentityFile() { keyFile.stringValue = known }

        // Only the SMB set needs live field⇄URL syncing.
        for field in [address, smbHost, smbShare, smbUser] { field.delegate = self }
    }

    /// Wrap the grid in a fixed-size container sized to the *taller* of the two protocol layouts, so
    /// switching protocols (which hides/shows rows) never resizes the modal mid-flight — the slack
    /// just sits below the shorter layout. Pins the grid to the top so both layouts read from there.
    private func layout(grid: NSGridView) {
        let reserved = reservedSize(of: grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(grid)
        NSLayoutConstraint.activate([
            accessoryView.widthAnchor.constraint(equalToConstant: reserved.width),
            accessoryView.heightAnchor.constraint(equalToConstant: reserved.height),
            grid.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: accessoryView.bottomAnchor)
        ])
    }

    /// The size to reserve for the accessory: the larger fitting size across both protocol layouts,
    /// measured by toggling visibility. The final visibility is restored by `updateVisibility()`.
    private func reservedSize(of grid: NSGridView) -> CGSize {
        setRows(sftpRows, hidden: false)
        setRows(smbRows, hidden: true)
        grid.layoutSubtreeIfNeeded()
        let sftpSize = grid.fittingSize

        setRows(sftpRows, hidden: true)
        setRows(smbRows, hidden: false)
        grid.layoutSubtreeIfNeeded()
        let smbSize = grid.fittingSize

        return CGSize(
            width: max(sftpSize.width, smbSize.width),
            height: max(sftpSize.height, smbSize.height)
        )
    }

    // MARK: - Toggles & sync

    private var isSMB: Bool { protocolControl.selectedSegment == 1 }

    @objc private func protocolChanged() {
        updateVisibility()
    }

    @objc private func authChanged() {
        updateAuthEnabled()
    }

    private func updateVisibility() {
        setRows(smbRows, hidden: !isSMB)
        setRows(sftpRows, hidden: isSMB)
        if isSMB {
            smbPassword.isEnabled = true
        } else {
            updateAuthEnabled()
        }
        initialFirstResponder = isSMB ? address : sftpHost
    }

    private func setRows(_ rows: [NSGridRow], hidden: Bool) {
        for row in rows { row.isHidden = hidden }
    }

    /// Enable the SFTP key-file or password field to match the selected auth method, so the
    /// irrelevant one is visibly greyed out while both stay in the grid.
    private func updateAuthEnabled() {
        let usingKey = authControl.selectedSegment == 0
        keyFile.isEnabled = usingKey
        sftpSecret.isEnabled = !usingKey
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isSMB, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let object = notification.object as AnyObject
        if object === address {
            syncFieldsFromURL()
        } else if object === smbHost || object === smbShare || object === smbUser {
            syncURLFromFields()
        }
    }

    /// Parse the address field into the host / share / user fields. A malformed, mid-typed URL just
    /// leaves the fields at their last good values rather than clearing them.
    private func syncFieldsFromURL() {
        guard let location = SMBLocation(url: address.stringValue) else { return }
        smbHost.stringValue = location.host
        smbShare.stringValue = location.share ?? ""
        smbUser.stringValue = location.username ?? ""
        smbPort = location.port
    }

    /// Rebuild the address field from the host / share / user fields (folding the remembered port
    /// back in). Skipped while the host is empty — there's no URL to form yet.
    private func syncURLFromFields() {
        let host = smbHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let location = SMBLocation(
            host: host,
            share: smbShare.stringValue,
            username: smbUser.stringValue,
            port: smbPort
        )
        address.stringValue = location.url
    }

    // MARK: - Prefill

    private func applyPrefill(_ prefill: ServerConnection?) {
        guard let prefill else { return }
        saveName.stringValue = prefill.name
        switch prefill.endpoint {
        case let .sftp(location, authentication):
            protocolControl.selectedSegment = 0
            sftpHost.stringValue = location.host
            sftpPort.stringValue = String(location.port)
            sftpUser.stringValue = location.username
            switch authentication {
            case let .key(identityFile):
                authControl.selectedSegment = 0
                keyFile.stringValue = identityFile
            case .password:
                authControl.selectedSegment = 1
                sftpSecret.stringValue = SFTPKeychain.password(for: location) ?? ""
            }
        case let .smb(location):
            protocolControl.selectedSegment = 1
            address.stringValue = location.url
            smbHost.stringValue = location.host
            smbShare.stringValue = location.share ?? ""
            smbUser.stringValue = location.username ?? ""
            smbPort = location.port
            if location.username != nil {
                smbPassword.stringValue = SMBKeychain.password(for: location) ?? ""
            }
        }
    }

    // MARK: - Reading

    /// The validated form, or `nil` when a required field is empty/unsafe — the same "reject rather
    /// than send a broken value" contract the SFTP-only prompt had, now branched per protocol.
    func readForm() -> ConnectServerPrompt.Form? {
        let trimmedName = saveName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? nil : trimmedName
        return isSMB ? readSMBForm(saveName: name) : readSFTPForm(saveName: name)
    }

    private func readSMBForm(saveName: String?) -> ConnectServerPrompt.Form? {
        // The fields are authoritative (the address URL may be mid-edit); they stay in sync with it.
        let host = smbHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let location = SMBLocation(
            host: host,
            share: smbShare.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            username: smbUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            port: smbPort
        )
        // A guest mount (no username) carries no password; an authenticated one takes the field as
        // typed (an empty password is legitimate for some servers, so it isn't rejected).
        let password = location.username == nil ? nil : smbPassword.stringValue
        return ConnectServerPrompt.Form(
            endpoint: .smb(location),
            password: password,
            saveName: saveName
        )
    }

    private func readSFTPForm(saveName: String?) -> ConnectServerPrompt.Form? {
        let hostValue = ConnectFormFactory.trimmed(sftpHost)
        let userValue = ConnectFormFactory.trimmed(sftpUser)
        // Reject empties, and anything starting with "-" so a value can't be read as an sftp option.
        guard ConnectFormFactory.isSafeArgument(hostValue),
              ConnectFormFactory.isSafeArgument(userValue) else { return nil }
        let portValue = Int(ConnectFormFactory.trimmed(sftpPort)) ?? SFTPLocation.defaultPort
        let location = SFTPLocation(host: hostValue, port: portValue, username: userValue)

        if authControl.selectedSegment == 0 {
            let keyValue = ConnectFormFactory.expandingTilde(ConnectFormFactory.trimmed(keyFile))
            guard !keyValue.isEmpty else { return nil }
            return ConnectServerPrompt.Form(
                endpoint: .sftp(location: location, authentication: .key(identityFile: keyValue)),
                password: nil,
                saveName: saveName
            )
        }
        // Passwords aren't trimmed — leading/trailing spaces can be significant — but a blank one is
        // certainly a mistake, so it's rejected rather than sent as an empty password.
        let secretValue = sftpSecret.stringValue
        guard !secretValue.isEmpty else { return nil }
        return ConnectServerPrompt.Form(
            endpoint: .sftp(location: location, authentication: .password),
            password: secretValue,
            saveName: saveName
        )
    }
}

/// The small view factories and value helpers the form is built from — split out of
/// `ConnectServerForm` so its class body stays within the length limit while everything stays in
/// one file. `@MainActor` because it vends AppKit controls.
@MainActor
private enum ConnectFormFactory {
    static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
    }

    static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    static func defaultIdentityFile() -> String? {
        let candidates = ["id_ed25519", "id_rsa"].map {
            NSHomeDirectory() + "/.ssh/" + $0
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func secureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
