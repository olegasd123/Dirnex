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
    /// This tab's back/forward navigation trail (PLAN.md §M3 "Per-panel history"). Seeded at
    /// the tab's starting directory and grown as navigation records visits; session-scoped,
    /// so a relaunched tab starts a fresh trail at its restored path.
    var history: NavigationHistory
    /// The visible cursor is parked on the `..` row (UI-only; see `PanelViewController`).
    var cursorOnParentRow = false
    /// Set once this tab's directory has been listed. A tab restored from disk starts
    /// `false` so switching to it triggers a fresh load rather than showing an empty list.
    var hasLoaded = false
    /// This tab's column widths/order, in display order (UI-only, like `cursorOnParentRow`;
    /// see `PanelViewController+Columns`). `nil` until the tab has been given an explicit
    /// layout — restored from disk or inherited from the tab it was spawned from — in which
    /// case the pane falls back to the default columns.
    var columnLayout: [ColumnLayout]?

    init(panel: Panel) {
        self.panel = panel
        history = NavigationHistory(initialPath: panel.path)
    }

    /// A new tab rooted at `path`, inheriting the sort/hidden settings — and, when given,
    /// the column layout — of the tab it was spawned from so a fresh tab matches the pane
    /// you opened it from.
    convenience init(
        path: VFSPath,
        sort: FileSort = .default,
        showHidden: Bool = false,
        columns: [ColumnLayout]? = nil
    ) {
        self.init(panel: Panel(path: path, sort: sort, showHidden: showHidden))
        columnLayout = columns
    }

    /// The short label shown on the tab chip — the directory name, or the volume name at
    /// the backend root (matching the path bar's root crumb).
    var title: String {
        panel.path.isRoot ? "Macintosh HD" : panel.path.lastComponent
    }
}
