import AppKit
import DirnexCore

/// Non-scrolling chrome around the file list: the path bar, the status line, and the
/// column sort indicators. Read-only with respect to `Panel` — split out to keep the
/// controller proper focused on navigation and the cursor/selection plumbing.
extension PanelViewController {
    func updateChrome() {
        pathBar.setPath(panel.path)
        statusLabel.stringValue = statusText()
    }

    /// The status line: a selection summary when anything is marked, otherwise the item
    /// count, prefixed with the active type-to-filter. The synthetic `..` row is never
    /// counted — it isn't part of `panel`.
    private func statusText() -> String {
        let total = panel.count
        let marked = panel.selectionCount
        let counts: String
        if marked > 0 {
            let bytes = panel.selectedEntries.reduce(Int64(0)) { sum, entry in
                sum + (entry.isDirectoryLike ? 0 : entry.byteSize)
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
