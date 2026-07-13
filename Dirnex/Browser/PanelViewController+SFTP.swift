import AppKit
import DirnexCore

/// Connect-to-Server (PLAN.md §M5 "`SFTPBackend`: browse … through the standard queue"). Prompts
/// for a remote SFTP account and either a private key or a password, tests the connection off-main
/// by resolving the remote home, then browses it in this pane. Password auth feeds the password to
/// `sftp` via `SSH_ASKPASS` and files it in the Keychain on success. The routing lives in
/// `CompositeBackend`; this is just the entry point and the async connect.
extension PanelViewController {
    @objc func connectToServer(_ sender: Any?) {
        guard let composite = backend as? CompositeBackend,
              let form = SFTPConnectPrompt.run(over: view.window) else { return }

        // A throwaway transport probes the connection (resolving the home directory doubles as an
        // auth/host test that fails fast); on success the same config is registered so the pane's
        // backend can route subsequent listings to it.
        let transport = SFTPProcessTransport(
            location: form.location,
            authentication: form.authentication,
            password: form.password
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
                if case .password = form.authentication, let password = form.password {
                    SFTPKeychain.store(password: password, for: form.location)
                }
                composite.connectSFTP(
                    location: form.location,
                    authentication: form.authentication,
                    password: form.password
                )
                navigate(to: VFSPath(backend: .sftp(form.location), path: home))
            case let .failure(error):
                presentOperationFailure(
                    message: "Couldn’t connect to “\(form.location.host)”.",
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
}
