import AppKit
import DirnexCore
import Quartz

/// Quick Look integration for a file pane (PLAN.md §M1 "Quick Look on … Cmd+Y").
///
/// The pane is the Quick Look controller while its table is first responder; it
/// previews the marked set (starting at the cursor) or, with nothing marked, the file
/// under the cursor — matching Finder. The panel is refreshed live as the cursor and
/// marks change via `refreshQuickLookIfVisible()`.
extension PanelViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ previewPanel: QLPreviewPanel!) {
        // Quick Look drives these NSResponder hooks on the main thread, but the Quartz
        // category imports them as nonisolated — assert the isolation we already have.
        MainActor.assumeIsolated {
            previewPanel.dataSource = self
            previewPanel.delegate = self
            if let current = panel.currentEntry,
               let index = quickLookItems().firstIndex(of: current) {
                previewPanel.currentPreviewItemIndex = index
            }
        }
    }

    override func endPreviewPanelControl(_ previewPanel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewPanel.dataSource = nil
            previewPanel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = quickLookItems()
        guard index >= 0, index < items.count else { return nil }
        return items[index].path.localURL as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: any QLPreviewItem) -> NSRect {
        // Zoom the preview to/from the cursor row for a native feel.
        let row = tableView.selectedRow
        guard row >= 0, let window = tableView.window else { return .zero }
        let inWindow = tableView.convert(tableView.rect(ofRow: row), to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Refresh an open preview after the cursor or marks change so it tracks the pane.
    func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let previewPanel = QLPreviewPanel.shared(),
              previewPanel.isVisible,
              (previewPanel.currentController as? PanelViewController) === self else { return }
        previewPanel.reloadData()
    }

    /// What Quick Look previews: the marked set if there is one (with the cursor as the
    /// starting item), otherwise just the file under the cursor. Non-local entries are dropped
    /// — an archive member has no on-disk URL to preview until extraction lands (a later M4 pass).
    private func quickLookItems() -> [FileEntry] {
        let marked = panel.selectedEntries.filter { $0.path.backend == .local }
        if !marked.isEmpty { return marked }
        if !cursorOnParentRow, let current = panel.currentEntry, current.path.backend == .local {
            return [current]
        }
        return []
    }
}
