import AppKit
import DirnexCore

extension PanelViewController {
    /// A file-list column. Internal (not private) so the chrome/parent-row extensions
    /// in their own files can build cells and sort indicators for it.
    enum Column: String, CaseIterable {
        case name, size, date

        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .date: return "Date Modified"
            }
        }

        var sortKey: FileSort.Key {
            switch self {
            case .name: return .name
            case .size: return .size
            case .date: return .modified
            }
        }

        /// The width a fresh column opens at, and the narrowest the user can drag it —
        /// also the fallback layout for a tab that has no persisted columns.
        var defaultWidth: CGFloat {
            switch self {
            // Name flexes to fill the pane (`.firstColumnOnly` autoresizing), so this is
            // only its floor at first show; Size/Date are fixed and sized to their content.
            case .name: return 240
            case .size: return 90
            case .date: return 150
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .name: return 120
            case .size: return 60
            case .date: return 110
            }
        }
    }
}

/// Per-tab column widths and order (PLAN.md §M1 "column width/order per tab, persisted").
/// A pane has one `NSTableView` shared across its tabs, so switching tabs swaps the
/// table's column geometry in and out: the active tab's layout is applied on activation,
/// and the user's drags (resize/reorder) are captured back into it and persisted.
extension PanelViewController {
    /// The columns a tab with no stored layout falls back to — the declared order and
    /// default widths from `Column`.
    static var defaultColumnLayout: [ColumnLayout] {
        Column.allCases.map { ColumnLayout(id: $0.rawValue, width: Double($0.defaultWidth)) }
    }

    /// Start recording header drags. `NSTableView` posts these on the main thread as the
    /// user resizes or reorders a column; the guard skips the notifications our own
    /// `applyColumnLayout` provokes while it sets widths/order programmatically.
    func observeColumnLayoutChanges() {
        let center = NotificationCenter.default
        for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            center.addObserver(
                self,
                selector: #selector(columnLayoutChanged),
                name: name,
                object: tableView
            )
        }
    }

    @objc func columnLayoutChanged(_ notification: Notification) {
        guard isViewLoaded, !isApplyingColumnLayout else { return }
        let layout = currentColumnLayout
        // Window autoresizing can post a resize with no real change; only touch storage
        // (and disk) when the geometry actually moved.
        guard layout != tabs[activeTabIndex].columnLayout else { return }
        tabs[activeTabIndex].columnLayout = layout
        persistState()
    }

    /// Record the table's current column geometry into the active tab, so a later switch
    /// back to it — or a relaunch — restores exactly what the user last saw.
    func captureColumnLayout() {
        tabs[activeTabIndex].columnLayout = currentColumnLayout
    }

    /// The table's live column geometry, in display order.
    private var currentColumnLayout: [ColumnLayout] {
        tableView.tableColumns.map {
            ColumnLayout(id: $0.identifier.rawValue, width: Double($0.width))
        }
    }

    /// Apply `tab`'s stored layout (or the defaults when it has none) to the shared table.
    /// Reorders the known columns into the stored order, then sets each width; columns not
    /// named in the layout keep their relative position at the end. Guarded so the
    /// resulting resize/move notifications aren't captured straight back.
    func applyColumnLayout(for tab: PanelTab) {
        let layout = tab.columnLayout ?? PanelViewController.defaultColumnLayout
        isApplyingColumnLayout = true
        defer { isApplyingColumnLayout = false }

        var targetIndex = 0
        for item in layout {
            let identifier = NSUserInterfaceItemIdentifier(item.id)
            let current = tableView.column(withIdentifier: identifier)
            // A column that no longer exists (e.g. a layout from a future build) is skipped.
            guard current >= 0 else { continue }
            if current != targetIndex {
                tableView.moveColumn(current, toColumn: targetIndex)
            }
            tableView.tableColumns[targetIndex].width = CGFloat(item.width)
            targetIndex += 1
        }
    }
}
