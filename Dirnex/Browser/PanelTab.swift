import DirnexCore
import Foundation

/// One tab within a file pane: everything needed to restore its exact view when the
/// user switches back to it. A `PanelViewController` owns an array of these and renders
/// whichever is active (PLAN.md §M1 "tabs per panel … restored on relaunch").
///
/// The full pane state lives in the value-type `Panel` (directory, cursor, marks, sort,
/// filter) — so a tab is essentially a `Panel` plus the two bits of view state the
/// controller keeps outside it: whether the cursor sits on the synthetic `..` row, and
/// whether this tab's directory has been listed yet (an inactive restored tab loads
/// lazily the first time it becomes active).
@MainActor
final class PanelTab {
    var panel: Panel
    /// The visible cursor is parked on the `..` row (UI-only; see `PanelViewController`).
    var cursorOnParentRow = false
    /// Set once this tab's directory has been listed. A tab restored from disk starts
    /// `false` so switching to it triggers a fresh load rather than showing an empty list.
    var hasLoaded = false

    init(panel: Panel) {
        self.panel = panel
    }

    /// A new tab rooted at `path`, inheriting the sort/hidden settings of the tab it was
    /// spawned from so a fresh tab matches the pane you opened it from.
    convenience init(path: VFSPath, sort: FileSort = .default, showHidden: Bool = false) {
        self.init(panel: Panel(path: path, sort: sort, showHidden: showHidden))
    }

    /// The short label shown on the tab chip — the directory name, or the volume name at
    /// the backend root (matching the path bar's root crumb).
    var title: String {
        panel.path.isRoot ? "Macintosh HD" : panel.path.lastComponent
    }
}
