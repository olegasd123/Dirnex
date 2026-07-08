import AppKit
import DirnexCore
import Quartz

/// The pane's owner (the window controller) — receives focus changes so it can track
/// which of the two panes is active and route Tab between them.
@MainActor
protocol PanelHost: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelRequestsFocusSwitch(_ panel: PanelViewController)
    /// The opposite pane — the default destination for a copy/move (F5/F6), whose
    /// current directory receives the operation. `nil` if there is no counterpart.
    func panelCounterpart(of panel: PanelViewController) -> PanelViewController?
    /// Enqueue a byte-moving operation (copy/move) on the window's shared background
    /// queue (PLAN.md §M2 `FileOperationQueue`). Fire-and-forget from the pane's view:
    /// the window's queue bar shows progress and both panes re-list as jobs finish.
    /// When `conflictPolicy` is `.ask`, `resolveConflict` fields each collision (TC's per-file
    /// conflict dialog) and `onError` fields each failure (skip/retry/abort); both run on the
    /// background copy thread, bridged to main-actor prompts (`ConflictPrompter`/`ErrorPrompter`).
    func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    )

    /// Record a completed, reversible operation (New Folder, rename, Move-to-Trash) on the
    /// window's shared undo journal so Cmd+Z can reverse it (PLAN.md §M2 "Undo journal").
    /// Copy/move are recorded by the window as their queue jobs finish, not here.
    func recordUndoableAction(_ record: UndoRecord)

    /// Reverse the most recent operation on the window's undo journal (Cmd+Z). Refreshes
    /// both panes and reports anything that couldn't be put back.
    func undoLastOperation()

    /// The label of the action Cmd+Z would reverse next, for the menu title, or `nil` when
    /// the journal is empty.
    var nextUndoLabel: String? { get }
}

/// One file pane: a path bar, an `NSTableView` of the current directory, and a status
/// line. A thin renderer over a `DirnexCore.Panel` value (PLAN.md §2 "UI is a thin
/// client") — every navigation/selection decision lives in `Panel`; this class only
/// mirrors that state into AppKit and pushes user input back into it.
@MainActor
final class PanelViewController: NSViewController {
    // Internal so the tab-management extension in its own file can list directories.
    let backend: any VFSBackend
    /// This pane's open tabs and which one is showing. Only the tab code in
    /// `PanelViewController+Tabs` mutates these directly; everything else goes through
    /// `panel`, which forwards to the active tab.
    var tabs: [PanelTab]
    var activeTabIndex: Int
    /// The active tab's pane state. A computed forward, so every existing `panel.…`
    /// read and mutation transparently targets the current tab.
    var panel: Panel {
        get { tabs[activeTabIndex].panel }
        set { tabs[activeTabIndex].panel = newValue }
    }

    /// Stable identifier ("left"/"right") under which this pane's tabs are persisted
    /// across launches; `nil` disables persistence.
    var restorationKey: String?
    weak var host: PanelHost?

    var isActivePanel = false {
        didSet { updateActiveAppearance() }
    }

    /// Internal (not private) so the Quick Look extension in its own file can map the
    /// cursor row to a source frame for the zoom animation.
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    // Internal so `PanelViewController+Chrome` can update them from its own file.
    let pathBar = PathBarView()
    let statusLabel = NSTextField(labelWithString: "")
    // The tab strip above the path bar; hidden until the pane has more than one tab.
    let tabBar = TabBarView()

    /// Guards the cursor⇄table-selection mirror against feedback loops: when we push
    /// `panel.cursor` into the table, the resulting selection-changed callback must
    /// not write it straight back. Internal for the table delegate in its own file.
    var isSyncingSelection = false
    /// Finder-style mouse-selection bookkeeping (see `PanelViewController+MouseSelect`).
    /// `mouseSelectionAnchor` is the entry a Shift-click range extends from;
    /// `mouseSelectionBase` is the mark set that predates the current range sweep, so a
    /// Shift-click keeps earlier Cmd-clicked marks. Both are view-only — `Panel` stays
    /// unaware — and identity-keyed so they survive a re-sort or refresh and self-heal
    /// when the anchor entry disappears. Reset on navigation and when the marks are cleared.
    var mouseSelectionAnchor: VFSPath?
    var mouseSelectionBase: Set<VFSPath> = []
    /// Guards the column-layout capture against feedback: applying a tab's stored widths
    /// and order itself posts resize/move notifications, which must not be recorded back
    /// as if the user had dragged them. Internal for `PanelViewController+Columns`.
    var isApplyingColumnLayout = false
    /// Identity of the entry currently being renamed inline (`nil` = not renaming). The
    /// name cell for this entry is built as an editable text field; everything else in
    /// `PanelViewController+Rename` drives the edit lifecycle. Internal so the table
    /// delegate in its own file can read it while building cells.
    var renamingEntryID: VFSPath?
    /// Set when the inline rename ends via Esc, so the shared end-editing handler reverts
    /// the field instead of committing the typed name. Internal for `+Rename`.
    var renameWasCancelled = false
    /// Bumped on every navigation so a slow listing that resolves after the user has
    /// already moved on is discarded instead of clobbering the current directory.
    /// Internal so `PanelViewController+Tabs` can discard a stale load on tab switch.
    var loadToken = 0
    /// FSEvents watcher for the directory on screen — live-refreshes the pane when the
    /// folder changes underneath us. Replaced on every navigation; `nil` for backends
    /// without the `.watch` capability.
    private var watcher: DirectoryWatcher?
    /// The visible cursor sits on the synthetic `..` row (which has no backing entry).
    /// Tracked in the UI only — `Panel` stays unaware of the parent row. Internal so the
    /// Quick Look extension can suppress previews while the cursor is on `..`; forwards
    /// to the active tab so each tab remembers whether it was parked on `..`.
    var cursorOnParentRow: Bool {
        get { tabs[activeTabIndex].cursorOnParentRow }
        set { tabs[activeTabIndex].cursorOnParentRow = newValue }
    }

    init(
        backend: any VFSBackend,
        restoration: PersistedPane?,
        defaultPath: VFSPath,
        restorationKey: String?
    ) {
        self.backend = backend
        self.restorationKey = restorationKey
        let restored = PanelViewController.restoredTabs(from: restoration)
        tabs = restored.isEmpty ? [PanelTab(path: defaultPath)] : restored
        activeTabIndex = restored.isEmpty
            ? 0
            : min(max(restoration?.activeIndex ?? 0, 0), restored.count - 1)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        configureTable()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        pathBar.delegate = self
        tabBar.delegate = self

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [tabBar, pathBar, scrollView, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        tabBar.setContentHuggingPriority(.required, for: .vertical)
        pathBar.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The pane fills the window to the top (the title bar is transparent and content
        // runs edge-to-edge). Pin the chrome stack's top to the safe-area guide so the tab
        // strip / path bar clear the traffic-light zone when the sidebar is collapsed and
        // this pane slides under the buttons; the sides and bottom stay flush.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configureTable() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue)
            )
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableView.addTableColumn(tableColumn)
        }

        tableView.style = .plain
        // Only the Name column absorbs slack as the pane resizes; Size and Date keep their
        // set widths so they never scroll off-screen when a pane is narrow.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The cell centers its 16pt icon/text vertically; the system default height leaves
        // it cramped, so give each row a little vertical breathing room above and below.
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.inputDelegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        configureDragging()
        observeColumnLayoutChanges()
        updateSortIndicators()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        activateTab()
    }

    // MARK: - Focus

    func focusTable() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(tableView)
    }

    private func updateActiveAppearance() {
        pathBar.isActive = isActivePanel
        tabBar.isActivePane = isActivePanel
    }

    // MARK: - Navigation

    /// Load `path` and install it in the active tab. When `focus` names a child that
    /// still exists (used when walking up), the cursor lands on it — the expected "go up,
    /// land on where I came from" behavior. A successful load records the visit in the tab's
    /// back/forward history (PLAN.md §M3) unless `recordHistory` is `false` — the flag
    /// back/forward/jump navigation passes so walking the trail doesn't append to it.
    /// Internal so `PanelViewController+Tabs` can load a freshly opened tab.
    func navigate(to path: VFSPath, focus child: VFSPath? = nil, recordHistory: Bool = true) {
        loadToken += 1
        let token = loadToken
        let tabIndex = activeTabIndex
        Task {
            do {
                let listing = try await DirectoryLoader.list(backend, at: path)
                guard token == loadToken else { return }
                panel.setListing(listing)
                resetMouseSelectionAnchor()
                // Entering a directory starts fresh — a quick-filter from the folder we
                // just left shouldn't silently hide the new folder's contents.
                if !panel.model.filter.isEmpty {
                    panel.setFilter("")
                }
                if let child, let index = panel.model.index(ofID: child) {
                    panel.moveCursor(to: index)
                }
                // Land on a real entry; only an empty directory parks the cursor on `..`.
                cursorOnParentRow = panel.isEmpty && panel.parentPath != nil
                tabs[tabIndex].hasLoaded = true
                if recordHistory { tabs[tabIndex].history.visit(path) }
                reloadEverything()
                refreshTabBar()
                startWatching(path)
                persistState()
            } catch {
                guard token == loadToken else { return }
                presentLoadFailure(error, path: path)
            }
        }
    }

    // MARK: - Live refresh (FSEvents)

    /// Watch `path` for changes, tearing down the previous watcher. The onChange closure
    /// runs on a background queue, so it hops to the main actor before touching the pane.
    /// Internal so a tab switch can re-establish the watcher for the newly active tab.
    func startWatching(_ path: VFSPath) {
        guard backend.capabilities.contains(.watch) else {
            watcher = nil
            return
        }
        watcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.directoryDidChange(path) }
        }
    }

    /// A watched directory changed on disk. Re-list it and hand the fresh snapshot to
    /// `Panel`, which preserves the cursor and marks by identity. Guarded so a late
    /// event from a directory we've since navigated away from is ignored.
    private func directoryDidChange(_ watchedPath: VFSPath) {
        guard panel.path == watchedPath else { return }
        let token = loadToken
        Task {
            guard let listing = try? await DirectoryLoader.list(backend, at: watchedPath) else { return }
            guard token == loadToken, panel.path == watchedPath else { return }
            reconcileCursorFromTable()
            panel.setListing(listing)
            renderRefresh()
        }
    }

    // MARK: - Rendering

    func reloadEverything() {
        tableView.reloadData()
        syncCursorToTable()
        updateChrome()
    }

    /// Re-render after a live FSEvents refresh. Unlike a navigation, this must not yank
    /// the view: the cursor is re-applied but not scrolled to, so a background change
    /// leaves the user's scroll position (and reading spot) where it was. Internal so a
    /// tab switch can re-render the newly active tab without disturbing its scroll.
    func renderRefresh() {
        tableView.reloadData()
        syncCursorToTable(scroll: false)
        updateChrome()
        refreshQuickLookIfVisible()
    }

    /// Mirror the table's live selection into the model cursor (the view→model half of
    /// the cursor mirror), reporting whether a real row was selected. Runs both from the
    /// user's own selection change and — crucially — just before a background refresh
    /// re-anchors the cursor.
    ///
    /// `NSTableView` posts its selection-changed notification on a later runloop pass, so
    /// there is a brief window after the user clicks or arrows to a new row where the
    /// table already shows it but `panel.cursor` still points at the row they left. A
    /// live FSEvents refresh, a directory-size completion, or a tab-activation re-list
    /// landing in that window would otherwise anchor on the stale cursor and snap the
    /// visible selection back to the previous file. Reconciling first makes the user's
    /// current selection the anchor, so the refresh preserves it. Internal so the
    /// background-refresh sites in the Tabs and Sizing extensions can call it.
    @discardableResult
    func reconcileCursorFromTable() -> Bool {
        let row = tableView.selectedRow
        guard row >= 0 else { return false }
        cursorOnParentRow = isParentRow(row)
        if let index = entryIndex(forRow: row) {
            panel.moveCursor(to: index)
        }
        return true
    }

    /// Push the cursor into the table's selection (the visible cursor). Navigation
    /// scrolls the cursor into view; a live refresh (`scroll: false`) does not. The
    /// `..` position is honored via `cursorOnParentRow` so a refresh doesn't bump the
    /// user off it, and an empty directory parks the cursor on `..` when one exists.
    private func syncCursorToTable(scroll: Bool = true) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let targetRow: Int
        if cursorOnParentRow, parentRowCount == 1 {
            targetRow = 0
        } else if panel.isEmpty {
            targetRow = parentRowCount == 1 ? 0 : -1
        } else {
            targetRow = row(forEntryIndex: panel.cursor)
        }
        // Keep the flag consistent with where the selection actually landed — e.g. a
        // filter that hides every entry parks the cursor on `..`, and Enter must then
        // go up rather than treating a nonexistent entry as the target.
        cursorOnParentRow = targetRow == 0 && parentRowCount == 1
        guard targetRow >= 0 else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        if scroll {
            tableView.scrollRowToVisible(targetRow)
        }
    }

    private func redrawRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }

    /// Replace the type-to-filter and re-render. `Panel`/`DirectoryModel` re-anchor the
    /// cursor by identity across the change, so the cursor stays on the same file when
    /// it survives the narrowing.
    private func setFilter(_ text: String) {
        panel.setFilter(text)
        reloadEverything()
        refreshQuickLookIfVisible()
    }
}

// MARK: - FileTableViewInput

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
