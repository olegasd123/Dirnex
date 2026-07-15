import AppKit
import DirnexCore

/// The gutters that come and go: the Git status letter and the Finder-tags dots (PLAN.md §M6).
/// Both are `Column.isContextual`, and everything that makes them *contextual* rather than ordinary
/// columns is here — installation, the width they cost, and where they sit — so the two callers
/// (`PanelViewController+Git`, `PanelViewController+Tags`) only have to decide *whether* their
/// gutter should be on screen.
///
/// **A gutter is paid for out of the Name column, never added on top of the table.** Appending its
/// width to the total would push Size and Date sideways every time one appeared — moving columns the
/// user had placed deliberately, for a reason that has nothing to do with them. Name is the right
/// column to charge because it is already the one that absorbs slack
/// (`firstColumnOnlyAutoresizingStyle`): it is the flexible one by design, and a filename with 20 pt
/// less room is a truncation, not a rearranged pane.
///
/// The other half of that bargain is in `PanelViewController+Columns`: a gutter never enters a
/// stored layout, and `currentColumnLayout` adds its footprint back onto Name when capturing one.
/// Without that, Name would ratchet narrower on every trip through a repository.
extension PanelViewController {
    /// Whether `column` is on the table right now — which is also the question "is the Name column
    /// currently that much narrower than the layout says", so `currentColumnLayout` can give it back.
    func isColumnInstalled(_ column: Column) -> Bool {
        tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) >= 0
    }

    /// What installing `column` actually costs the table: its own width **plus one intercell
    /// spacing**, which `NSTableView` adds per column. The spacing is the whole trap here — it is
    /// **17 pt** at this table's `.plain` style, not the 2–3 pt the name suggests (measured against
    /// a real table, after charging Name the column width alone visibly failed to hold Size and
    /// Date still). Read live rather than hardcoded, so a style change can't quietly reintroduce
    /// the drift.
    func columnFootprint(_ column: Column) -> CGFloat {
        column.defaultWidth + tableView.intercellSpacing.width
    }

    /// The total width every installed gutter is currently costing Name. Summed rather than asked
    /// of one column, because with two gutters a capture that reclaims only one would still make
    /// Name ratchet — the exact bug the reclaim exists to prevent, just slower.
    var installedContextualFootprint: CGFloat {
        Column.allCases
            .filter { $0.isContextual && isColumnInstalled($0) }
            .reduce(0) { $0 + columnFootprint($1) }
    }

    /// Add or remove a contextual column, charging (or refunding) Name for the space.
    func setContextualColumn(_ column: Column, installed: Bool) {
        let identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        let existing = tableView.column(withIdentifier: identifier)
        guard installed != (existing >= 0) else { return }
        // Adding or removing a column posts the same resize/move notifications a user's header drag
        // does. Without this guard, walking into a repository would be recorded as the user having
        // rearranged their columns — and persisted.
        let wasApplyingLayout = isApplyingColumnLayout
        isApplyingColumnLayout = true
        defer { isApplyingColumnLayout = wasApplyingLayout }

        guard installed else {
            tableView.removeTableColumn(tableView.tableColumns[existing])
            // Hand the space back, so leaving is the exact inverse of arriving.
            resizeNameColumn(by: columnFootprint(column))
            return
        }
        resizeNameColumn(by: -columnFootprint(column))
        tableView.addTableColumn(makeContextualColumn(column, identifier: identifier))
        guard let target = contextualInsertionIndex(for: column) else { return }
        tableView.moveColumn(tableView.tableColumns.count - 1, toColumn: target)
    }

    /// Lift every gutter off the table — what `applyColumnLayout` does before reordering the user's
    /// real columns into their stored order, since a column absent from that order would otherwise
    /// be dragged to the far end one step at a time.
    func removeContextualColumns() {
        for column in Column.allCases where column.isContextual {
            setContextualColumn(column, installed: false)
        }
    }

    private func makeContextualColumn(
        _ column: Column,
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: identifier)
        tableColumn.title = column.title
        tableColumn.headerToolTip = column.headerToolTip
        tableColumn.width = column.defaultWidth
        tableColumn.minWidth = column.minWidth
        // Fixed width: a gutter is a badge, not data, so there is nothing to widen it for — and it
        // must cost Name exactly `columnFootprint` or the reclaim above would refund the wrong
        // amount and Name would drift.
        tableColumn.maxWidth = column.defaultWidth
        tableColumn.resizingMask = []
        return tableColumn
    }

    /// Where `column` belongs: immediately after the name, where it reads as a badge on the file.
    /// Stranded past the date it would be a column of marks with nothing to do with what the eye is
    /// scanning. Several gutters keep their `Column.allCases` order among themselves, so installing
    /// one never reshuffles another (Name │ git │ tags │ Size │ Date, whichever arrives first).
    private func contextualInsertionIndex(for column: Column) -> Int? {
        let nameIndex = tableView.column(
            withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue)
        )
        guard nameIndex >= 0 else { return nil }
        var offset = 1
        for other in Column.allCases {
            if other == column { break }
            if other.isContextual, isColumnInstalled(other) { offset += 1 }
        }
        return nameIndex + offset
    }

    /// Widen or narrow the Name column by `delta`, to make room for a gutter or reclaim it.
    /// `NSTableColumn` clamps to its own `minWidth`, so a pane already squeezed to the floor keeps
    /// a legible name and lets the Size/Date pair shift instead — the lesser of the two evils, and
    /// only at widths where nothing readable was on offer anyway.
    private func resizeNameColumn(by delta: CGFloat) {
        let identifier = NSUserInterfaceItemIdentifier(Column.name.rawValue)
        let index = tableView.column(withIdentifier: identifier)
        guard index >= 0 else { return }
        tableView.tableColumns[index].width += delta
    }
}
