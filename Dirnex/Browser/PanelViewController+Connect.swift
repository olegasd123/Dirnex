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
        case let .failure(message):
            return message
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
