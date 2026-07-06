import AppKit
import DirnexCore

/// The main window: two file panes side by side with a draggable divider, exactly
/// one of them active at a time. Owns focus routing (Tab switches panes) and the
/// active-pane bookkeeping the panes themselves stay ignorant of.
@MainActor
final class BrowserWindowController: NSWindowController, PanelHost {
    let leftPanel: PanelViewController
    let rightPanel: PanelViewController
    private let sidebar = SidebarViewController()
    private let splitViewController = NSSplitViewController()
    private weak var activePanel: PanelViewController?

    /// The shared background operation engine both panes route F5/F6 through, so copies and
    /// moves queue and run without blocking browsing (PLAN.md §M2). Volume-aware scheduling
    /// keys off the same `backend` the panes use.
    let queue: FileOperationQueue
    /// The window's undo journal owner (PLAN.md §M2). Records the panes' reversible
    /// operations — New Folder / rename / Trash inline, copy/move as their queue jobs finish
    /// — and reverses the most recent one on Cmd+Z. Persists across launches.
    let undoController: UndoController
    /// The window-bottom progress readout, collapsed to zero height while the queue is idle.
    let queueBar = QueueBarView()
    private var queueBarHeight: NSLayoutConstraint!
    /// The long-lived task draining `queue.observe()` into the queue bar and pane refreshes.
    var queueObservation: Task<Void, Never>?
    /// Jobs already reacted to (panes re-listed, failures reported), so a repeat snapshot of
    /// the same finished job doesn't refresh twice. Cleared when the queue drains.
    var finalizedJobs: Set<OperationJobID> = []
    /// The last observed pause state, so the queue bar's button knows which way to toggle.
    var lastPaused = false

    init() {
        let backend = LocalBackend()
        queue = FileOperationQueue(backend: backend)
        undoController = UndoController(backend: backend)
        let home = VFSPath.local(NSHomeDirectory())
        // Each pane restores its own tabs from the last session, keyed by side.
        leftPanel = PanelViewController(
            backend: backend,
            restoration: TabPersistence.load(paneKey: "left"),
            defaultPath: home,
            restorationKey: "left"
        )
        rightPanel = PanelViewController(
            backend: backend,
            restoration: TabPersistence.load(paneKey: "right"),
            defaultPath: home,
            restorationKey: "right"
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dirnex"
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 640, height: 360)

        super.init(window: window)

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "BrowserSplit"

        // The places/volumes strip leads, then the two panes. It's a real macOS sidebar
        // (vibrant, collapsible via View ▸ Show Sidebar) that drives the active pane.
        sidebar.delegate = self
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        for panel in [leftPanel, rightPanel] {
            let item = NSSplitViewItem(viewController: panel)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            splitViewController.addSplitViewItem(item)
            panel.host = self
        }

        window.contentViewController = makeContainerViewController()
        window.center()

        queueBar.onPauseToggle = { [weak self] in self?.togglePause() }
        queueBar.onCancelAll = { [weak self] in self?.cancelAllJobs() }
        startObservingQueue()
    }

    deinit {
        queueObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Stack the two panes over the queue bar so the bar spans the full window width at the
    /// bottom. `setQueueBar(visible:)` collapses it to zero height (and hides it) while the
    /// queue is idle, giving the panes the whole window.
    private func makeContainerViewController() -> NSViewController {
        let container = NSViewController()
        container.view = NSView()
        container.addChild(splitViewController)

        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        queueBar.translatesAutoresizingMaskIntoConstraints = false
        queueBar.isHidden = true
        container.view.addSubview(splitView)
        container.view.addSubview(queueBar)

        queueBarHeight = queueBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: queueBar.topAnchor),
            queueBar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            queueBar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            queueBar.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            queueBarHeight
        ])
        return container
    }

    /// Show or collapse the queue bar. Driven by the queue observation: shown while any job
    /// is waiting/running/paused, collapsed to zero height (and hidden) once idle.
    func setQueueBar(visible: Bool) {
        guard queueBar.isHidden == visible else { return }
        queueBar.isHidden = !visible
        queueBarHeight.constant = visible ? QueueBarView.preferredHeight : 0
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        setActive(leftPanel)
        leftPanel.focusTable()
    }

    // MARK: - PanelHost

    func panelDidBecomeActive(_ panel: PanelViewController) {
        setActive(panel)
    }

    func panelRequestsFocusSwitch(_ panel: PanelViewController) {
        counterpart(of: panel).focusTable()
    }

    func panelCounterpart(of panel: PanelViewController) -> PanelViewController? {
        counterpart(of: panel)
    }

    private func counterpart(of panel: PanelViewController) -> PanelViewController {
        panel === leftPanel ? rightPanel : leftPanel
    }

    private func setActive(_ panel: PanelViewController) {
        guard activePanel !== panel else { return }
        activePanel?.isActivePanel = false
        panel.isActivePanel = true
        activePanel = panel
    }
}

// MARK: - SidebarViewControllerDelegate

extension BrowserWindowController: SidebarViewControllerDelegate {
    /// A sidebar click points the active pane at the chosen place/volume, then hands
    /// keyboard focus back to that pane so browsing continues without a mouse.
    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath) {
        let target = activePanel ?? leftPanel
        target.navigate(to: path)
        target.focusTable()
    }
}
