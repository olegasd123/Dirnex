import AppKit
import DirnexCore

/// The path bar's delegate: activating a crumb navigates the pane, and the bar's inline
/// editor asks the pane for the child directories to autocomplete. Split into its own
/// file (like `+Table`, `+Chrome`, `+ParentRow`) to keep the controller proper focused
/// on the cursor/selection plumbing.
extension PanelViewController: PathBarViewDelegate {
    func pathBar(_ bar: PathBarView, didActivate path: VFSPath) {
        // Landing on the branch we came from (when the path is an ancestor of the
        // current directory) makes a multi-level crumb jump feel like walking up.
        let focus = path.child(towards: panel.path)
        navigate(to: path, focus: focus)
        focusTable()
    }

    func pathBarDidCancel(_ bar: PathBarView) {
        focusTable()
    }

    func pathBarDidBeginEditing(_ bar: PathBarView) {
        host?.panelDidBecomeActive(self)
    }

    func pathBar(_ bar: PathBarView, childDirectoriesOf directory: VFSPath) async -> [String] {
        let showHidden = panel.model.showHidden
        do {
            let listing = try await DirectoryLoader.list(backend, at: directory)
            return listing.entries
                .filter { $0.isDirectoryLike && (showHidden || !$0.isHidden) }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            return []
        }
    }
}
