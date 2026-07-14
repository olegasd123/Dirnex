import AppKit
import DirnexCore

/// Connect-to-Server (PLAN.md §M5 "one place that keeps every saved remote — SFTP and SMB alike").
/// Prompts for a remote server, connects it, and — when named — saves it to the sidebar's Servers
/// section. Two protocols share one entry point:
///
/// - **SFTP** browses through a `VFSBackend`: a throwaway transport probes the connection (resolving
///   the remote home doubles as an auth/host test), then the same config is registered on the pane's
///   `CompositeBackend` so listings route to it. Password auth feeds `sftp` via `SSH_ASKPASS`.
/// - **SMB** rides the OS mounter: `SMBMounter` mounts the share into `/Volumes/…` and the pane
///   navigates onto the resulting local path, so every M2 op works unchanged.
///
/// Secrets are filed in the Keychain only after they authenticate, so a typo isn't cached.
extension PanelViewController {
    /// File ▸ Connect to Server… — open the prompt, connect what the user entered, saving it if named.
    @objc func connectToServer(_ sender: Any?) {
        guard let form = ConnectServerPrompt.run(over: view.window) else { return }
        apply(form)
    }

    /// Connect a saved server picked from the sidebar — no prompt when the secret is known. An
    /// authenticated connection whose secret isn't in the Keychain (never saved, or cleared) falls
    /// back to the prefilled prompt so the user can re-enter it, rather than failing silently.
    func connect(to server: ServerConnection) {
        switch server.endpoint {
        case let .sftp(location, authentication):
            if case .password = authentication {
                guard let stored = SFTPKeychain.password(for: location) else {
                    editServer(server)
                    return
                }
                connectSFTP(
                    location: location,
                    authentication: authentication,
                    password: stored,
                    saveName: nil
                )
            } else {
                connectSFTP(
                    location: location,
                    authentication: authentication,
                    password: nil,
                    saveName: nil
                )
            }
        case let .smb(location):
            if location.username != nil {
                guard let stored = SMBKeychain.password(for: location) else {
                    editServer(server)
                    return
                }
                mountSMB(location: location, password: stored, saveName: nil)
            } else {
                mountSMB(location: location, password: nil, saveName: nil)
            }
        }
    }

    /// Re-open the connect prompt prefilled from a saved server (the sidebar's "Edit…"). A rename in
    /// the prompt removes the old entry first, so editing updates in place rather than duplicating.
    func editServer(_ server: ServerConnection) {
        guard let form = ConnectServerPrompt.run(over: view.window, prefill: server) else { return }
        if let newName = form.saveName, newName != server.name {
            var store = ServerConnectionStore.load()
            if store.remove(name: server.name) { ServerConnectionStore.save(store) }
        }
        apply(form)
    }

    // MARK: - Dispatch

    private func apply(_ form: ConnectServerPrompt.Form) {
        switch form.endpoint {
        case let .sftp(location, authentication):
            connectSFTP(
                location: location,
                authentication: authentication,
                password: form.password,
                saveName: form.saveName
            )
        case let .smb(location):
            mountSMB(location: location, password: form.password, saveName: form.saveName)
        }
    }

    // MARK: - SFTP

    private func connectSFTP(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String?,
        saveName: String?
    ) {
        guard let composite = backend as? CompositeBackend else { return }

        let transport = SFTPProcessTransport(
            location: location,
            authentication: authentication,
            password: password
        )
        let token = loadToken
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try transport.resolveHomeDirectory()) } catch { return .failure(
                    error
                ) }
            }.value
            guard token == loadToken else { return } // the pane moved on while we probed
            switch result {
            case let .success(home):
                // Only persist a password once it actually authenticated, so a typo isn't cached.
                if case .password = authentication, let password {
                    SFTPKeychain.store(password: password, for: location)
                }
                composite.connectSFTP(
                    location: location,
                    authentication: authentication,
                    password: password
                )
                if let saveName {
                    saveServer(
                        name: saveName,
                        endpoint: .sftp(location: location, authentication: authentication)
                    )
                }
                navigate(to: VFSPath(backend: .sftp(location), path: home))
                // Hand keyboard focus to the pane so the freshly connected server is ready to
                // work with immediately — no extra click to activate it first.
                focusTable()
            case let .failure(error):
                // A changed host key isn't a dead end — offer to re-trust the new key and reconnect,
                // preserving the auth and save name so the retry behaves exactly like the first try.
                if case let .hostKeyChanged(change)? = error as? SFTPTransportError {
                    presentHostKeyChangeWarning(location: location, change: change) { [weak self] in
                        self?.repairKnownHostsAndReconnect(
                            location: location,
                            authentication: authentication,
                            password: password,
                            saveName: saveName,
                            change: change
                        )
                    }
                    return
                }
                presentOperationFailure(
                    message: "Couldn’t connect to “\(location.host)”.",
                    detail: Self.connectFailureDetail(error)
                )
            }
        }
    }

    /// A human-readable reason for a failed connect, mapped from the transport's error vocabulary.
    private static func connectFailureDetail(_ error: Error) -> String {
        guard let transportError = error as? SFTPTransportError else {
            return (error as NSError).localizedDescription
        }
        switch transportError {
        case .notFound:
            return "The remote path wasn’t found."
        case .permissionDenied:
            return "Permission denied. Check the username and that the key is authorized on the server."
        case let .hostKeyChanged(change):
            // Reached only if a host-key change surfaces outside the connect probe's re-trust flow.
            return "The server’s host key has changed (new fingerprint \(change.fingerprint))."
        case let .failure(message):
            return message
        }
    }

    // MARK: - Host key changed

    /// Warn that a host's key no longer matches the one pinned in `known_hosts`, and offer to re-trust
    /// it. Presented as a critical sheet whose default (and rightmost) button is the safe "Cancel", so
    /// re-trusting a changed key — usually a reinstalled server, but possibly a man-in-the-middle — is
    /// always a deliberate click, never the button you hit by reflex. Confirming runs `trust`.
    private func presentHostKeyChangeWarning(
        location: SFTPLocation,
        change: SFTPHostKeyChange,
        trust: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The identity of “\(location.host)” has changed"
        alert.informativeText = Self.hostKeyChangeDetail(change)
        // "Cancel" is added first so it's the default (Return / Escape) and rightmost.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust New Key & Connect")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn { trust() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private static func hostKeyChangeDetail(_ change: SFTPHostKeyChange) -> String {
        let keyLabel = change.keyType.isEmpty ? "key" : "\(change.keyType) key"
        let fingerprint = change.fingerprint.isEmpty ? "(unavailable)" : change.fingerprint
        return """
        This server is presenting a different host \(keyLabel) than the one you trusted before. \
        If you reinstalled the server or pointed a new SFTP app at this address, this is expected — \
        but it can also mean someone is intercepting the connection (a man-in-the-middle attack).

        New fingerprint:
        \(fingerprint)

        Only continue if you recognize this fingerprint. Trusting it replaces the old key so future \
        connections to this server succeed.
        """
    }

    /// Drop the stale `known_hosts` pin (via `ssh-keygen -R`) and reconnect. `StrictHostKeyChecking=
    /// accept-new` then pins the server's current key as if it were a fresh host, so the reconnect
    /// verifies cleanly — and password auth, which OpenSSH disables to a *changed*-key host, works
    /// again. Preserves the original save name so a re-trusted connect still lands in the sidebar.
    private func repairKnownHostsAndReconnect(
        location: SFTPLocation,
        authentication: SFTPAuthentication,
        password: String?,
        saveName: String?,
        change: SFTPHostKeyChange
    ) {
        let target = SFTPKnownHosts.removalTarget(host: location.host, port: location.port)
        let file = change.knownHostsFile
        Task {
            let removed = await Task.detached(priority: .userInitiated) {
                SFTPKnownHostsRepair.removeKey(target: target, knownHostsFile: file)
            }.value
            guard removed else {
                presentOperationFailure(
                    message: "Couldn’t update the known hosts for “\(location.host)”.",
                    detail: "The old host key couldn’t be removed automatically. Remove it from "
                        + "\(file.isEmpty ? "~/.ssh/known_hosts" : file) and try connecting again."
                )
                return
            }
            connectSFTP(
                location: location,
                authentication: authentication,
                password: password,
                saveName: saveName
            )
        }
    }

    // MARK: - SMB

    private func mountSMB(location: SMBLocation, password: String?, saveName: String?) {
        let token = loadToken
        Task {
            do {
                let result = try await SMBMounter.shared.mount(
                    location,
                    username: location.username,
                    password: password
                )
                guard token == loadToken else { return } // the pane moved on while we mounted
                // Persist the password only once the mount succeeded, and only for an authenticated
                // share — a guest mount has no secret to keep.
                if location.username != nil, let password {
                    SMBKeychain.store(password: password, for: location)
                }
                if let saveName { saveServer(name: saveName, endpoint: .smb(location)) }
                navigate(to: .local(result.mountPoint.path))
                // Hand keyboard focus to the pane so the freshly mounted share is ready to work
                // with immediately — no extra click to activate it first.
                focusTable()
            } catch {
                guard token == loadToken else { return }
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                presentOperationFailure(
                    message: "Couldn’t connect to “\(location.host)”.",
                    detail: detail
                )
            }
        }
    }

    // MARK: - Saving

    private func saveServer(name: String, endpoint: ServerEndpoint) {
        var store = ServerConnectionStore.load()
        store.save(ServerConnection(name: name, endpoint: endpoint))
        ServerConnectionStore.save(store)
    }
}
