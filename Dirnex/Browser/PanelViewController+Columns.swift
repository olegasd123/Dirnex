import AppKit
import DirnexCore

extension PanelViewController {
    /// A file-list column. Internal (not private) so the chrome/parent-row extensions
    /// in their own files can build cells and sort indicators for it.
    enum Column: String, CaseIterable {
        case name, size, date
        /// The Git status gutter (PLAN.md §M6). Unlike name/size/date it is *contextual*: it exists
        /// only while the pane is inside a repository — see `PanelViewController+Git`.
        case git
        /// The Finder-tags dots (PLAN.md §M6). Contextual for a different reason than `git`: it is
        /// gated on the `showTags` preference and on the pane's rows being able to carry tags at
        /// all — see `PanelViewController+Tags`.
        case tags

        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .date: return "Date Modified"
            // Both gutters are too narrow for a header title to be anything but an ellipsis, so
            // they carry a `headerToolTip` instead.
            case .git, .tags: return ""
            }
        }

        /// The tooltip naming a column whose header is too narrow to title, `nil` when the title
        /// already says it.
        var headerToolTip: String? {
            switch self {
            case .git: return "Git status"
            case .tags: return "Finder tags"
            case .name, .size, .date: return nil
            }
        }

        /// Whether the column comes and goes rather than being a fixture the user arranges. Both
        /// gutters are: a "Git" column in every folder that isn't a repository, or a tags column
        /// for someone who doesn't tag, would be pure clutter. Contextual columns are never stored
        /// in a tab's layout and are paid for out of Name — see `PanelViewController+ContextualColumns`.
        var isContextual: Bool {
            self == .git || self == .tags
        }

        /// The sort this column's header applies, or `nil` when it isn't sortable.
        var sortKey: FileSort.Key? {
            switch self {
            case .name: return .name
            case .size: return .size
            case .date: return .modified
            case .git, .tags: return nil
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
            // Three 8 pt dots and the gaps between them, plus a little breathing room — the most
            // `TagCellView` ever draws.
            case .tags: return 36
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .name: return 120
            case .size: return 60
            case .date: return 110
            case .git: return 20
            case .tags: return 36
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
    /// Two things follow from that. The gutters themselves are left out: recording one would make
    /// an otherwise identical layout differ between a repository and a plain folder, and each
    /// crossing would rewrite the tab's stored columns for no user-visible reason. And the Name
    /// column gets **every installed gutter's** footprint added back, because while a gutter is
    /// installed Name is physically that much narrower (`setContextualColumn` charges it there) —
    /// storing the carved width would make Name ratchet narrower on every trip through a repository.
    private var currentColumnLayout: [ColumnLayout] {
        let reclaimed = Double(installedContextualFootprint)
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
            // Re-attach the gutters for the tab being switched to, after the layout pass: they are
            // absent from every stored layout, so the reordering below would otherwise shuffle them
            // to the far end of the table, one column at a time.
            updateGitColumn()
            updateTagColumn()
        }
        removeContextualColumns()

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
