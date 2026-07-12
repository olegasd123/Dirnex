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

    /// Panels ▸ show hidden (dot) files (default off — Finder's behavior). This is a single
    /// app-wide toggle, not a per-tab one: every pane and tab reflects it. Changing it posts
    /// `showHiddenDidChange` so the open panes re-filter live, and the Settings toggle, the
    /// header button, and ⇧⌘. all drive this one value.
    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            defaults.set(showHidden, forKey: Keys.showHidden)
            NotificationCenter.default.post(name: Self.showHiddenDidChange, object: self)
        }
    }

    /// Posted (on the main actor) whenever `showHidden` flips, so every open pane can apply the
    /// new value to its tabs and re-render. `object` is the `AppPreferences` that changed.
    static let showHiddenDidChange = Notification.Name("Dirnex.showHiddenDidChange")

    /// Flip the app-wide show-hidden state. The shared entry point for the header button, the
    /// ⇧⌘. shortcut, and the palette/menu command — all of which want the same one-line effect.
    func toggleShowHidden() {
        showHidden.toggle()
    }

    /// Operations ▸ ask for confirmation before moving items to the Trash (default off —
    /// Trash is recoverable, matching Finder). Permanent delete always confirms regardless.
    @Published var confirmTrash: Bool {
        didSet { defaults.set(confirmTrash, forKey: Keys.confirmTrash) }
    }

    /// Panels ▸ move focus to a folder opened from search results (default off — stay on the
    /// results so you can keep opening hits). Opening a folder from a `.search` results tab never
    /// replaces the results in place: it lands as a new tab in the other pane (or, when there's no
    /// other pane, a new tab beside the results here). When off, that new tab opens without
    /// stealing focus/selection from the results; when on, focus follows into the opened folder.
    @Published var focusOpenedSearchDirectory: Bool {
        didSet { defaults.set(focusOpenedSearchDirectory, forKey: Keys.focusOpenedSearchDirectory) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreSession = defaults.object(forKey: Keys.restoreSession) as? Bool ?? true
        showHidden = defaults.bool(forKey: Keys.showHidden)
        confirmTrash = defaults.bool(forKey: Keys.confirmTrash)
        focusOpenedSearchDirectory = defaults.bool(forKey: Keys.focusOpenedSearchDirectory)
    }

    private enum Keys {
        static let restoreSession = "Dirnex.pref.restoreSession"
        static let showHidden = "Dirnex.pref.showHidden"
        static let confirmTrash = "Dirnex.pref.confirmTrash"
        static let focusOpenedSearchDirectory = "Dirnex.pref.focusOpenedSearchDirectory"
    }
}
