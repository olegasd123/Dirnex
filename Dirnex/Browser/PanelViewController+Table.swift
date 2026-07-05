import AppKit
import DirnexCore

/// `NSTableView` data source and delegate for a file pane: row count, cell rendering,
/// the cursor⇄selection mirror, and header-click sorting. Row⇄entry mapping accounts
/// for the synthetic `..` row via the helpers in `PanelViewController+ParentRow`.
extension PanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        panel.count + parentRowCount
    }
}

extension PanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }

        if isParentRow(row) { return parentRowCell(for: column, in: tableView) }
        guard let index = entryIndex(forRow: row) else { return nil }

        let entry = panel.model[index]
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? FileCellView
            ?? FileCellView(showsImage: column == .name, identifier: tableColumn.identifier)

        cell.marked = panel.isMarked(entry)
        switch column {
        case .name:
            cell.imageView?.image = FileIconProvider.icon(for: entry)
            cell.textField?.stringValue = entry.name
            cell.textField?.alignment = .natural
        case .size:
            cell.textField?.stringValue = FileFormatting.sizeString(
                for: entry, computedSize: panel.model.computedSize(of: entry)
            )
            cell.textField?.alignment = .right
        case .date:
            cell.textField?.stringValue = FileFormatting.dateString(for: entry)
            cell.textField?.alignment = .natural
        }
        cell.applyStyle()
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        cursorOnParentRow = isParentRow(row)
        if let index = entryIndex(forRow: row) {
            panel.moveCursor(to: index)
        }
        updateChrome()
        refreshQuickLookIfVisible()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { return }
        var sort = panel.model.sort
        if sort.key == column.sortKey {
            sort.ascending.toggle()
        } else {
            sort = FileSort(key: column.sortKey, ascending: true)
        }
        panel.setSort(sort)
        reloadEverything()
        updateSortIndicators()
        // Sort is per-tab and persisted (PLAN.md §M1).
        persistState()
    }
}
