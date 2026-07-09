import AppKit
import DirnexCore
import Quartz

/// The pane's `FileTableView` input callbacks — every key/gesture the table forwards
/// (open, go-up, backspace, type-to-filter, mark, invert, Quick Look, edit-path, focus).
/// Split out of `PanelViewController` proper to keep that file under the length limit; the
/// two rendering helpers these callbacks lean on (`redrawRow`, `setFilter`) live here too,
/// since nothing else uses them.
extension PanelViewController: FileTableViewInput {
    func fileTableOpenSelection(_ tableView: FileTableView) {
        if cursorOnParentRow {
            goToParent()
        } else {
            openCurrentEntry()
        }
    }

    func fileTableGoToParent(_ tableView: FileTableView) {
        goToParent()
    }

    func fileTableBackspace(_ tableView: FileTableView) {
        if panel.model.filter.isEmpty {
            goToParent()
        } else {
            setFilter(String(panel.model.filter.dropLast()))
        }
    }

    func fileTableCancel(_ tableView: FileTableView) {
        if !panel.model.filter.isEmpty {
            setFilter("")
        } else if host?.isQuickViewEnabled == true {
            // Esc backs out of Quick View before touching the marks — it's a distinct mode the
            // user stepped into, and the inactive pane's preview is the obvious thing to dismiss.
            host?.toggleQuickView()
        } else if panel.selectionCount > 0 {
            panel.clearSelection()
            resetMouseSelectionAnchor()
            tableView.reloadData()
            updateChrome()
            refreshQuickLookIfVisible()
        }
    }

    func fileTable(_ tableView: FileTableView, didType text: String) {
        setFilter(panel.model.filter + text)
    }

    func fileTableToggleMarkAndAdvance(_ tableView: FileTableView) {
        guard !panel.isEmpty else { return }
        // Space on `..` marks nothing (it isn't a real entry) — just step onto the
        // first entry, matching the "advance" half of the gesture.
        if cursorOnParentRow {
            tableView.selectRowIndexes(
                IndexSet(integer: parentRowCount),
                byExtendingSelection: false
            )
            tableView.scrollRowToVisible(parentRowCount)
            return
        }
        // Capture the entry under the cursor before we advance past it: Space on a
        // directory also computes its size in place (TC), applied when the walk lands.
        let sizedDirectory = panel.currentEntry.flatMap { $0.isDirectoryLike ? $0 : nil }
        let markedRow = row(forEntryIndex: panel.cursor)
        panel.toggleMarkAtCursorAndAdvance()
        redrawRow(markedRow)
        syncCursorToTable()
        updateChrome()
        refreshQuickLookIfVisible()
        if let sizedDirectory {
            computeDirectorySize(for: sizedDirectory)
        }
    }

    func fileTableSwitchPanel(_ tableView: FileTableView) {
        host?.panelRequestsFocusSwitch(self)
    }

    func fileTableMarkAll(_ tableView: FileTableView) {
        panel.selectAll()
        tableView.reloadData()
        updateChrome()
        refreshQuickLookIfVisible()
    }

    func fileTableInvertMarks(_ tableView: FileTableView) {
        invertMarks()
    }

    func fileTableToggleQuickLook(_ tableView: FileTableView) {
        guard let previewPanel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), previewPanel.isVisible {
            previewPanel.orderOut(nil)
        } else {
            previewPanel.makeKeyAndOrderFront(nil)
        }
    }

    func fileTableEditPath(_ tableView: FileTableView) {
        pathBar.beginEditing(base: panel.path)
    }

    func fileTableDidBecomeFirstResponder(_ tableView: FileTableView) {
        host?.panelDidBecomeActive(self)
    }
}

// MARK: - Rendering helpers

private extension PanelViewController {
    func redrawRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }

    /// Replace the type-to-filter and re-render. `Panel`/`DirectoryModel` re-anchor the
    /// cursor by identity across the change, so the cursor stays on the same file when
    /// it survives the narrowing.
    func setFilter(_ text: String) {
        panel.setFilter(text)
        reloadEverything()
        refreshQuickLookIfVisible()
    }
}
