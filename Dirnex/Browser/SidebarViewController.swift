import AppKit
import DirnexCore

/// Receives a sidebar row click so the window can point the active pane at it.
@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath)
    /// A saved-search row was picked — re-run its query in the active pane and show the hits in
    /// a virtual results panel (PLAN.md §M4 "Saved searches … in the places strip").
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch)
    /// A click landed on the sidebar's empty space or a non-selectable header. Keep keyboard
    /// focus on the active file pane rather than letting the source list steal it — the pane's
    /// file commands (F5/F6/F8) are dispatched through the responder chain and go dead the moment
    /// no pane is first responder.
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController)
}

/// The places/volumes strip (PLAN.md §M1 "Volumes/places strip … replaces TC's drive
/// letters"). A source-list `NSTableView` of standard folders and mounted volumes;
/// clicking a row navigates the window's active pane, and ejectable volumes carry an
/// eject button. The list rebuilds itself on mount/unmount so a plugged-in drive shows
/// up live.
///
/// It holds no pane state — enumeration lives in `DirnexCore.SidebarLocations` and the
/// actual navigation is delegated to the window controller, keeping this a thin view.
@MainActor
final class SidebarViewController: NSViewController {
    /// A rendered sidebar row: a section header or a navigable destination.
    private enum Row {
        case header(String)
        case place(FavoritePlace)
        case volume(MountedVolume)
        case savedSearch(SavedSearch)

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }

        /// The path a click navigates to, when the row is a real location. `nil` for headers and
        /// saved searches — a saved search runs a query rather than pointing at a directory, so
        /// it's dispatched through its own delegate call instead.
        var path: VFSPath? {
            switch self {
            case .header, .savedSearch: return nil
            case let .place(place): return place.path
            case let .volume(volume): return volume.path
            }
        }

        var savedSearch: SavedSearch? {
            if case let .savedSearch(search) = self { return search }
            return nil
        }
    }

    weak var delegate: SidebarViewControllerDelegate?

    // A focus-preserving subclass: empty-space / header clicks don't steal keyboard focus from
    // the active file pane (which would disable the responder-chain file commands).
    private let tableView = SidebarTableView()
    private let scrollView = NSScrollView()
    private var rows: [Row] = []

    // MARK: - View setup

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        // Right-click on a saved-search row offers Run / Rename / Delete; the menu builds its
        // items lazily from the clicked row, so it stays empty (and doesn't appear) elsewhere.
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        // An empty-space or header click (on the table, or in the clip area below the rows) must
        // not pull keyboard focus off the active file pane — re-focus it instead. See
        // `SidebarTableView` / `SidebarClipView`.
        let refocusActivePane: () -> Void = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebarDidClickEmptyArea(self)
        }
        tableView.onEmptyClick = refocusActivePane
        let clipView = SidebarClipView()
        clipView.onBackgroundClick = refocusActivePane
        scrollView.contentView = clipView

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The sidebar's vibrant material runs full-height behind the transparent title bar,
        // so its rows must start below the traffic lights. Tracking the window's safe area
        // insets the first "Favorites" header clear of them automatically, with no extra
        // padding on top of that — the material is flush to the window's left/top/bottom.
        scrollView.automaticallyAdjustsContentInsets = true

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeVolumeChanges()
        observeSavedSearchChanges()
        rebuild()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data

    /// Re-enumerate favorites and volumes and reload, keeping the visual selection on the
    /// same path if that row still exists (a drive unmounting shouldn't jump the highlight).
    private func rebuild() {
        let selectedPath = selectedRow()?.path

        var rows: [Row] = []
        // Saved searches lead the sidebar, above the standard Favorites/Volumes sections.
        let savedSearches = SavedSearchStore.load().searches
        if !savedSearches.isEmpty {
            rows.append(.header("Searches"))
            rows.append(contentsOf: savedSearches.map(Row.savedSearch))
        }
        let favorites = SidebarLocations.favorites()
        if !favorites.isEmpty {
            rows.append(.header("Favorites"))
            rows.append(contentsOf: favorites.map(Row.place))
        }
        let volumes = SidebarLocations.volumes()
        if !volumes.isEmpty {
            rows.append(.header("Volumes"))
            rows.append(contentsOf: volumes.map(Row.volume))
        }
        self.rows = rows
        tableView.reloadData()

        if let selectedPath, let index = rows.firstIndex(where: { $0.path == selectedPath }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func selectedRow() -> Row? {
        let index = tableView.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        // Workspace volume notifications are delivered on the main thread, so the
        // main-actor selector is safe; teardown is a single removeObserver in deinit.
        for name in names {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    @objc private func volumesChanged() {
        rebuild()
    }

    /// Rebuild when the shared saved-search list changes — a Save/Rename/Delete here or in
    /// another window shows up live in the Searches section.
    private func observeSavedSearchChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savedSearchesChanged),
            name: SavedSearchStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func savedSearchesChanged() {
        rebuild()
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else { return }
        if let savedSearch = rows[index].savedSearch {
            delegate?.sidebar(self, didActivateSavedSearch: savedSearch)
        } else if let path = rows[index].path {
            delegate?.sidebar(self, didActivate: path)
        }
    }

    /// Eject (or unmount) a removable volume via the workspace, surfacing any failure —
    /// a drive that's busy or in use should say so, not fail silently.
    private func eject(_ volume: MountedVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.path.localURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t eject “\(volume.name)”"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

// MARK: - NSTableViewDelegate

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let cell = reuse(SidebarHeaderView.identifier) as? SidebarHeaderView
            let header = cell ?? SidebarHeaderView()
            header.configure(title: title)
            return header
        case let .place(place):
            return itemCell(name: place.name, path: place.path, kind: place.kind, volume: nil)
        case let .volume(volume):
            return itemCell(name: volume.name, path: volume.path, kind: nil, volume: volume)
        case let .savedSearch(search):
            let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
            cell.configure(
                name: search.name,
                image: Self.savedSearchIcon,
                canEject: false,
                tooltip: savedSearchTooltip(search)
            )
            cell.onEject = nil
            cell.onDelete = { [weak self] in self?.confirmDeleteSavedSearch(named: search.name) }
            return cell
        }
    }

    /// A magnifying-glass SF Symbol so a saved search reads as a query, not a folder. Template
    /// so the source list tints it with the row's text color like the favorite glyphs.
    private static let savedSearchIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Saved search"
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }()

    /// A tooltip describing where a saved search runs — the scope folder, or "Everywhere".
    private func savedSearchTooltip(_ search: SavedSearch) -> String {
        guard let scope = search.scope else { return "Search everywhere" }
        return "Search in “\(scope.lastComponent)”"
    }

    /// Build (or reuse) an item cell. Favorites get a per-kind SF Symbol so Documents,
    /// Downloads, Music, etc. read at a glance instead of all sharing the generic folder
    /// icon; volumes keep their real Finder drive glyph. A `volume` that can eject also
    /// gets the eject button wired.
    private func itemCell(
        name: String,
        path: VFSPath,
        kind: FavoritePlace.Kind?,
        volume: MountedVolume?
    ) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let icon: NSImage
        if let kind {
            icon = Self.icon(for: kind)
        } else {
            icon = NSWorkspace.shared.icon(forFile: path.path)
            icon.size = NSSize(width: 18, height: 18)
        }
        let canEject = volume?.canEject ?? false
        cell.configure(name: name, image: icon, canEject: canEject, tooltip: capacityTooltip(volume))
        cell.onEject = canEject ? { [weak self] in volume.map { self?.eject($0) } } : nil
        cell.onDelete = nil // places/volumes aren't deletable (reset in case the cell was reused)
        return cell
    }

    /// A monochrome SF Symbol standing in for each favorite folder. Returned as a template
    /// image so the source-list cell tints it with the row's text color (and white when the
    /// row is selected), matching the label.
    private static func icon(for kind: FavoritePlace.Kind) -> NSImage {
        let symbol: String
        switch kind {
        case .home: symbol = "house"
        case .desktop: symbol = "menubar.dock.rectangle"
        case .documents: symbol = "doc"
        case .downloads: symbol = "arrow.down.circle"
        case .pictures: symbol = "photo"
        case .music: symbol = "music.note"
        case .movies: symbol = "film"
        case .applications: symbol = "square.grid.3x3.fill"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }

    private func reuse(_ identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        tableView.makeView(withIdentifier: identifier, owner: self)
    }

    /// A "123 GB available of 456 GB" tooltip for volumes that report capacity.
    private func capacityTooltip(_ volume: MountedVolume?) -> String? {
        guard let volume, let total = volume.totalCapacity, let available = volume.availableCapacity else {
            return volume?.name
        }
        return "\(FileFormatting.byteString(available)) available of \(FileFormatting.byteString(total))"
    }
}

// MARK: - Saved-search context menu

extension SidebarViewController: NSMenuDelegate {
    /// Build the right-click menu lazily from the clicked row. A right-click on any row that
    /// isn't a saved search leaves the menu empty, so AppKit shows nothing — the menu is
    /// exclusively the saved-search management surface (Run / Rename / Delete).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row), let search = rows[row].savedSearch else { return }

        menu.addItem(
            savedSearchMenuItem("Run Search", #selector(runSavedSearchItem(_:)), search.name)
        )
        menu.addItem(.separator())
        menu.addItem(
            savedSearchMenuItem("Rename…", #selector(renameSavedSearchItem(_:)), search.name)
        )
        menu.addItem(
            savedSearchMenuItem("Delete", #selector(deleteSavedSearchItem(_:)), search.name)
        )
    }

    /// One management item, carrying the search's *name* so a mid-open store change can't act
    /// on the wrong (index-shifted) search — mirroring the hotlist/workspace popups.
    private func savedSearchMenuItem(_ title: String, _ action: Selector, _ name: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    @objc private func runSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let search = SavedSearchStore.load().search(named: name) else { return }
        delegate?.sidebar(self, didActivateSavedSearch: search)
    }

    @objc private func renameSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let newName = promptForSavedSearchRename(current: name), newName != name else { return }
        var store = SavedSearchStore.load()
        if store.rename(name: name, to: newName) {
            SavedSearchStore.save(store)
        } else {
            presentSavedSearchRenameCollision(newName)
        }
    }

    @objc private func deleteSavedSearchItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        confirmDeleteSavedSearch(named: name)
    }

    /// Confirm before removing a saved search — the shared path for both the row's trailing delete
    /// button and the context-menu Delete. Presented as a window sheet when possible.
    func confirmDeleteSavedSearch(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "This removes the saved search from the sidebar. No files are deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let commit = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            var store = SavedSearchStore.load()
            if store.remove(name: name) { SavedSearchStore.save(store) }
            _ = self
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: commit)
        } else {
            commit(alert.runModal())
        }
    }

    /// Ask for a new name, prefilled with the current one; `nil` on cancel or an empty name.
    private func promptForSavedSearchRename(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Saved Search"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A rename that collides with a *different* saved search is refused by the model; tell the
    /// user rather than silently dropping it.
    private func presentSavedSearchRenameCollision(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” is already taken"
        alert.informativeText = "Another saved search already uses that name. Pick a different one."
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
