import AppKit
import DirnexCore

/// Opening entries and walking the directory tree: the small navigation actions the
/// key model, double-click, and the `..` row funnel into. Kept out of the main
/// controller so it stays under SwiftLint's file/type-body limits (like `+Table`,
/// `+Chrome`, `+ParentRow`).
extension PanelViewController {
    /// Enter the directory under the cursor, browse into an archive file, or launch a plain
    /// file with its default app.
    func openCurrentEntry() {
        guard let entry = panel.currentEntry else { return }
        if let target = panel.openTarget(for: entry) {
            navigate(to: target)
        } else if entry.path.backend == .local, ArchiveType.isBrowsable(entry.name) {
            // A local archive file — browse into its virtual folder tree instead of launching.
            navigate(to: archiveRoot(for: entry))
        } else if entry.path.backend.isArchive, ArchiveType.isBrowsable(entry.name) {
            // A nested archive — extract this member to disk and browse into it (PLAN.md §M4).
            beginNestedArchiveEntry(for: entry)
        } else if entry.path.backend == .local {
            NSWorkspace.shared.open(entry.path.localURL)
        }
        // Any other non-directory entry inside an archive (a plain file member) can't be launched
        // in place, so it's a no-op rather than opening a meaningless local URL.
    }

    /// Walk up one level, landing the cursor on the directory we came from. Inside an archive
    /// this walks the inner tree and, at the archive root, exits to the containing folder. A
    /// no-op on a virtual results pane — its synthetic parent isn't a browsable directory.
    func goToParent() {
        if isArchive {
            _ = goUpWithinArchive()
            return
        }
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
