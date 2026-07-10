import AppKit
import DirnexCore

/// Opening entries and walking the directory tree: the small navigation actions the
/// key model, double-click, and the `..` row funnel into. Kept out of the main
/// controller so it stays under SwiftLint's file/type-body limits (like `+Table`,
/// `+Chrome`, `+ParentRow`).
extension PanelViewController {
    /// Enter the directory under the cursor, or launch the file with its default app.
    func openCurrentEntry() {
        guard let entry = panel.currentEntry else { return }
        if let target = panel.openTarget(for: entry) {
            navigate(to: target)
        } else {
            NSWorkspace.shared.open(entry.path.localURL)
        }
    }

    /// Walk up one level, landing the cursor on the directory we came from. A no-op on a
    /// virtual results pane — its synthetic parent isn't a browsable directory.
    func goToParent() {
        guard panel.path.backend == .local else { return }
        let current = panel.path
        guard let parent = panel.parentPath else { return }
        navigate(to: parent, focus: current)
    }

    /// Double-click: go up on the `..` row, otherwise open the clicked entry.
    @objc func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if isParentRow(row) {
            goToParent()
            return
        }
        guard let index = entryIndex(forRow: row) else { return }
        panel.moveCursor(to: index)
        openCurrentEntry()
    }
}
