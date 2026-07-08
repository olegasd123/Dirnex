import Combine
import Foundation

/// The app-wide toggles the Settings window's General / Panels / Operations tabs edit
/// (PLAN.md §M3 "Settings window (SwiftUI): general, panels, operations, shortcuts"). Each is
/// backed by a `UserDefaults` key and read at its single point of use; every default preserves
/// the app's pre-Settings behavior, so an untouched install behaves exactly as before.
///
/// One shared, observable instance: the Settings UI binds to it, and the browser code reads
/// `AppPreferences.shared` when it needs a value (creating a tab, deleting to Trash, restoring
/// a session). Boring `UserDefaults` persistence, like the rest of the app's config.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private let defaults: UserDefaults

    /// General ▸ reopen the previous session's tabs at launch (default on — the existing
    /// behavior). Off starts every window fresh at Home.
    @Published var restoreSession: Bool {
        didSet { defaults.set(restoreSession, forKey: Keys.restoreSession) }
    }

    /// Panels ▸ show hidden (dot) files in newly opened tabs (default off — the existing
    /// behavior). A per-tab toggle can still override an individual tab later.
    @Published var showHiddenByDefault: Bool {
        didSet { defaults.set(showHiddenByDefault, forKey: Keys.showHiddenByDefault) }
    }

    /// Operations ▸ ask for confirmation before moving items to the Trash (default off —
    /// Trash is recoverable, matching Finder). Permanent delete always confirms regardless.
    @Published var confirmTrash: Bool {
        didSet { defaults.set(confirmTrash, forKey: Keys.confirmTrash) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSession = defaults.object(forKey: Keys.restoreSession) as? Bool ?? true
        showHiddenByDefault = defaults.bool(forKey: Keys.showHiddenByDefault)
        confirmTrash = defaults.bool(forKey: Keys.confirmTrash)
    }

    private enum Keys {
        static let restoreSession = "Dirnex.pref.restoreSession"
        static let showHiddenByDefault = "Dirnex.pref.showHiddenByDefault"
        static let confirmTrash = "Dirnex.pref.confirmTrash"
    }
}
