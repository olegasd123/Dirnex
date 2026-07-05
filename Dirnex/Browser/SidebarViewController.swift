import AppKit
import DirnexCore

/// Receives a sidebar row click so the window can point the active pane at it.
@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath)
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

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }

        var path: VFSPath? {
            switch self {
            case .header: return nil
            case let .place(place): return place.path
            case let .volume(volume): return volume.path
            }
        }
    }

    weak var delegate: SidebarViewControllerDelegate?

    private let tableView = NSTableView()
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

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeVolumeChanges()
        rebuild()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Data

    /// Re-enumerate favorites and volumes and reload, keeping the visual selection on the
    /// same path if that row still exists (a drive unmounting shouldn't jump the highlight).
    private func rebuild() {
        let selectedPath = selectedRow()?.path

        var rows: [Row] = []
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

    // MARK: - Actions

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index), let path = rows[index].path else { return }
        delegate?.sidebar(self, didActivate: path)
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
            return itemCell(name: place.name, path: place.path, volume: nil)
        case let .volume(volume):
            return itemCell(name: volume.name, path: volume.path, volume: volume)
        }
    }

    /// Build (or reuse) an item cell. A `volume` argument that can eject gets the eject
    /// button wired; places and non-ejectable volumes don't.
    private func itemCell(name: String, path: VFSPath, volume: MountedVolume?) -> NSView {
        let cell = reuse(SidebarCellView.identifier) as? SidebarCellView ?? SidebarCellView()
        let icon = NSWorkspace.shared.icon(forFile: path.path)
        let canEject = volume?.canEject ?? false
        cell.configure(name: name, image: icon, canEject: canEject, tooltip: capacityTooltip(volume))
        cell.onEject = canEject ? { [weak self] in volume.map { self?.eject($0) } } : nil
        return cell
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
