import AppKit
import DirnexCore

/// Non-scrolling chrome around the file list: the path bar, the status line, and the
/// column sort indicators. Read-only with respect to `Panel` — split out to keep the
/// controller proper focused on navigation and the cursor/selection plumbing.
extension PanelViewController {
    func updateChrome() {
        pathBar.setPath(panel.path, archiveAncestry: archiveBreadcrumbAncestry())
        pathBar.setBranch(gitSnapshot?.branch)
        statusLabel.stringValue = statusText()
        // If this is the active pane and Quick View is on, the file under the cursor just
        // changed — re-drive the preview showing in the inactive pane. A no-op otherwise.
        host?.panelCursorDidChange(self)
    }

    /// The status line: a selection summary when anything is marked, otherwise the item
    /// count, prefixed with the active type-to-filter. The synthetic `..` row is never
    /// counted — it isn't part of `panel`.
    private func statusText() -> String {
        let total = panel.count
        let marked = panel.selectionCount
        let counts: String
        if marked > 0 {
            // A marked directory contributes its computed recursive size once sized
            // (Space-on-dir), otherwise zero — its inode size is noise, not content.
            let bytes = panel.selectedEntries.reduce(Int64(0)) { sum, entry in
                sum + panel.model.effectiveByteSize(of: entry)
            }
            counts = "\(marked) of \(total) selected · \(FileFormatting.byteString(bytes))"
        } else {
            counts = total == 1 ? "1 item" : "\(total) items"
        }

        let filter = panel.model.filter
        return filter.isEmpty ? counts : "Filter “\(filter)” · \(counts)"
    }

    func updateSortIndicators() {
        let sort = panel.model.sort
        for tableColumn in tableView.tableColumns {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            let image: NSImage? = column.sortKey == sort.key
                ? NSImage(
                    named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                )
                : nil
            tableView.setIndicatorImage(image, in: tableColumn)
        }
    }
}
