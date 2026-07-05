import AppKit
import DirnexCore
import Quartz

/// The pane's owner (the window controller) — receives focus changes so it can track
/// which of the two panes is active and route Tab between them.
@MainActor
protocol PanelHost: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelRequestsFocusSwitch(_ panel: PanelViewController)
}

/// One file pane: a path bar, an `NSTableView` of the current directory, and a status
/// line. A thin renderer over a `DirnexCore.Panel` value (PLAN.md §2 "UI is a thin
/// client") — every navigation/selection decision lives in `Panel`; this class only
/// mirrors that state into AppKit and pushes user input back into it.
@MainActor
final class PanelViewController: NSViewController {
    private enum Column: String, CaseIterable {
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
    }

    private let backend: any VFSBackend
    private(set) var panel: Panel
    weak var host: PanelHost?

    var isActivePanel = false {
        didSet { updateActiveAppearance() }
    }

    /// Internal (not private) so the Quick Look extension in its own file can map the
    /// cursor row to a source frame for the zoom animation.
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let pathBar = PathBarView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Guards the cursor⇄table-selection mirror against feedback loops: when we push
    /// `panel.cursor` into the table, the resulting selection-changed callback must
    /// not write it straight back.
    private var isSyncingSelection = false
    /// Bumped on every navigation so a slow listing that resolves after the user has
    /// already moved on is discarded instead of clobbering the current directory.
    private var loadToken = 0
    /// FSEvents watcher for the directory on screen — live-refreshes the pane when the
    /// folder changes underneath us. Replaced on every navigation; `nil` for backends
    /// without the `.watch` capability.
    private var watcher: DirectoryWatcher?

    init(backend: any VFSBackend, path: VFSPath) {
        self.backend = backend
        panel = Panel(path: path)
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

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [pathBar, scrollView, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        pathBar.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        view = stack
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
            switch column {
            case .name:
                tableColumn.width = 320
                tableColumn.minWidth = 140
            case .size:
                tableColumn.width = 90
                tableColumn.minWidth = 60
            case .date:
                tableColumn.width = 150
                tableColumn.minWidth = 100
            }
            tableView.addTableColumn(tableColumn)
        }

        tableView.style = .plain
        tableView.rowSizeStyle = .default
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.inputDelegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        updateSortIndicators()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigate(to: panel.path)
    }

    // MARK: - Focus

    func focusTable() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(tableView)
    }

    private func updateActiveAppearance() {
        pathBar.isActive = isActivePanel
    }

    // MARK: - Navigation

    /// Load `path` and install it. When `focus` names a child that still exists (used
    /// when walking up), the cursor lands on it — the expected "go up, land on where I
    /// came from" behavior.
    private func navigate(to path: VFSPath, focus child: VFSPath? = nil) {
        loadToken += 1
        let token = loadToken
        Task {
            do {
                let listing = try await DirectoryLoader.list(backend, at: path)
                guard token == loadToken else { return }
                panel.setListing(listing)
                // Entering a directory starts fresh — a quick-filter from the folder we
                // just left shouldn't silently hide the new folder's contents.
                if !panel.model.filter.isEmpty {
                    panel.setFilter("")
                }
                if let child, let index = panel.model.index(ofID: child) {
                    panel.moveCursor(to: index)
                }
                reloadEverything()
                startWatching(path)
            } catch {
                guard token == loadToken else { return }
                presentLoadFailure(error, path: path)
            }
        }
    }

    // MARK: - Live refresh (FSEvents)

    /// Watch `path` for changes, tearing down the previous watcher. The onChange closure
    /// runs on a background queue, so it hops to the main actor before touching the pane.
    private func startWatching(_ path: VFSPath) {
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
            panel.setListing(listing)
            renderRefresh()
        }
    }

    private func openCurrentEntry() {
        guard let entry = panel.currentEntry else { return }
        if let target = panel.openTarget(for: entry) {
            navigate(to: target)
        } else {
            NSWorkspace.shared.open(entry.path.localURL)
        }
    }

    private func goToParent() {
        let current = panel.path
        guard let parent = panel.parentPath else { return }
        navigate(to: parent, focus: current)
    }

    // MARK: - Rendering

    private func reloadEverything() {
        tableView.reloadData()
        syncCursorToTable()
        updateChrome()
    }

    /// Re-render after a live FSEvents refresh. Unlike a navigation, this must not yank
    /// the view: the cursor is re-applied but not scrolled to, so a background change
    /// leaves the user's scroll position (and reading spot) where it was.
    private func renderRefresh() {
        tableView.reloadData()
        syncCursorToTable(scroll: false)
        updateChrome()
        refreshQuickLookIfVisible()
    }

    /// Push `panel.cursor` into the table's selection (the visible cursor). Navigation
    /// scrolls the cursor into view; a live refresh (`scroll: false`) does not.
    private func syncCursorToTable(scroll: Bool = true) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        guard !panel.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let row = panel.cursor
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll {
            tableView.scrollRowToVisible(row)
        }
    }

    private func redrawRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }

    private func updateChrome() {
        pathBar.setPath(panel.path)
        statusLabel.stringValue = statusText()
    }

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

    /// Replace the type-to-filter and re-render. `Panel`/`DirectoryModel` re-anchor the
    /// cursor by identity across the change, so the cursor stays on the same file when
    /// it survives the narrowing.
    private func setFilter(_ text: String) {
        panel.setFilter(text)
        reloadEverything()
        refreshQuickLookIfVisible()
    }

    private func updateSortIndicators() {
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

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        panel.moveCursor(to: row)
        openCurrentEntry()
    }
}

// MARK: - NSTableViewDataSource

extension PanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        panel.count
    }
}

// MARK: - NSTableViewDelegate

extension PanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue),
              row < panel.count else { return nil }

        let entry = panel.model[row]
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? FileCellView
            ?? FileCellView(showsImage: column == .name, identifier: tableColumn.identifier)

        cell.marked = panel.isMarked(entry)
        switch column {
        case .name:
            cell.imageView?.image = FileIconProvider.icon(for: entry)
            cell.textField?.stringValue = entry.name
            cell.textField?.alignment = .natural
        case .size:
            cell.textField?.stringValue = FileFormatting.sizeString(for: entry)
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
        panel.moveCursor(to: row)
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
    }
}

// MARK: - FileTableViewInput

extension PanelViewController: FileTableViewInput {
    func fileTableOpenSelection(_ tableView: FileTableView) {
        openCurrentEntry()
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
        let row = panel.cursor
        panel.toggleMarkAtCursorAndAdvance()
        redrawRow(row)
        syncCursorToTable()
        updateChrome()
        refreshQuickLookIfVisible()
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
        panel.invertSelection()
        tableView.reloadData()
        updateChrome()
        refreshQuickLookIfVisible()
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

// MARK: - PathBarViewDelegate

extension PanelViewController: PathBarViewDelegate {
    func pathBar(_ bar: PathBarView, didActivate path: VFSPath) {
        // Landing on the branch we came from (when the path is an ancestor of the
        // current directory) makes a multi-level crumb jump feel like walking up.
        let focus = path.child(towards: panel.path)
        navigate(to: path, focus: focus)
        focusTable()
    }

    func pathBarDidCancel(_ bar: PathBarView) {
        focusTable()
    }

    func pathBarDidBeginEditing(_ bar: PathBarView) {
        host?.panelDidBecomeActive(self)
    }

    func pathBar(_ bar: PathBarView, childDirectoriesOf directory: VFSPath) async -> [String] {
        let showHidden = panel.model.showHidden
        do {
            let listing = try await DirectoryLoader.list(backend, at: directory)
            return listing.entries
                .filter { $0.isDirectoryLike && (showHidden || !$0.isHidden) }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            return []
        }
    }
}
