import AppKit
import DirnexCore

extension PanelViewController {
    /// A file-list column. Internal (not private) so the chrome/parent-row extensions
    /// in their own files can build cells and sort indicators for it.
    enum Column: String, CaseIterable {
        case name, size, date
        /// The Git status gutter (PLAN.md §M6). Unlike the others it is *contextual*: it exists
        /// only while the pane is inside a repository — see `PanelViewController+Git`.
        case git

        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .date: return "Date Modified"
            // One letter wide, so a header title could only ever be an ellipsis; the tooltip in
            // `installGitColumn` names it instead.
            case .git: return ""
            }
        }

        /// Whether the column is only installed for certain directories rather than always present.
        /// A permanently blank "Git" column in every folder that isn't a repository — which is most
        /// of them — would be pure clutter, so this one comes and goes with the repository.
        var isContextual: Bool {
            self == .git
        }

        /// The sort this column's header applies, or `nil` when it isn't sortable.
        var sortKey: FileSort.Key? {
            switch self {
            case .name: return .name
            case .size: return .size
            case .date: return .modified
            case .git: return nil
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
            // Fixed: one centered letter. It is a gutter, not data — nothing to widen it for.
            case .git: return 20
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .name: return 120
            case .size: return 60
            case .date: return 110
            case .git: return 20
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
    /// default widths from `Column`. Contextual columns are excluded: they are not the user's to
    /// arrange, so they never appear in a stored layout (see `setGitColumnInstalled`).
    static var defaultColumnLayout: [ColumnLayout] {
        Column.allCases
            .filter { !$0.isContextual }
            .map { ColumnLayout(id: $0.rawValue, width: Double($0.defaultWidth)) }
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

    /// The table's live column geometry, in display order — recorded as it would be with **no**
    /// contextual column present, which is the only form a stored layout ever takes.
    ///
    /// Two things follow from that. The gutter itself is left out: recording it would make an
    /// otherwise identical layout differ between a repository and a plain folder, and each crossing
    /// would rewrite the tab's stored columns for no user-visible reason. And the Name column gets
    /// the gutter's footprint added back, because while the gutter is installed Name is physically
    /// that much narrower (`setGitColumnInstalled` charges it there) — storing the carved width
    /// would make Name ratchet narrower on every trip through a repository.
    private var currentColumnLayout: [ColumnLayout] {
        let reclaimed = isGitColumnInstalled ? Double(gitColumnFootprint) : 0
        return tableView.tableColumns.compactMap {
            guard let column = Column(rawValue: $0.identifier.rawValue), !column.isContextual else {
                return nil
            }
            let width = Double($0.width) + (column == .name ? reclaimed : 0)
            return ColumnLayout(id: $0.identifier.rawValue, width: width)
        }
    }

    /// Apply `tab`'s stored layout (or the defaults when it has none) to the shared table.
    /// Reorders the known columns into the stored order, then sets each width; columns not
    /// named in the layout keep their relative position at the end. Guarded so the
    /// resulting resize/move notifications aren't captured straight back.
    func applyColumnLayout(for tab: PanelTab) {
        let layout = tab.columnLayout ?? PanelViewController.defaultColumnLayout
        isApplyingColumnLayout = true
        defer {
            isApplyingColumnLayout = false
            // Re-attach the Git gutter for the tab being switched to, after the layout pass: it is
            // absent from every stored layout, so the reordering below would otherwise shuffle it
            // to the far end of the table, one column at a time.
            updateGitColumn()
        }
        setGitColumnInstalled(false)

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
