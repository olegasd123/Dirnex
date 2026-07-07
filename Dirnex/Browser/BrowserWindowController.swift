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
    /// Outer split: `[sidebar, panes]`. Collapsing/expanding the sidebar only ever resizes
    /// the panes group as a whole.
    private let splitViewController = NSSplitViewController()
    /// Inner split: `[leftPanel, rightPanel]`. Kept separate so the sidebar toggle can't
    /// steal width from just the adjacent pane — the two panes redistribute proportionally in
    /// both directions here, holding their ratio across any number of sidebar toggles.
    private let panesSplitViewController = NSSplitViewController()
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

    /// Autosave name for the panes split's divider geometry. A fresh install (or one still
    /// on the pre-V2 name) has no saved entry, which is our signal to open the panes 50/50
    /// rather than let AppKit squeeze the right pane to its minimum width.
    private static let panesAutosaveName = "BrowserPanesV2"
    /// Set at launch when no panes geometry is saved; consumed on first `showWindow` to
    /// center the divider once. A later user drag persists under `panesAutosaveName` and
    /// wins on subsequent launches.
    private var shouldCenterPanesDivider = false

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
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dirnex"
        window.minSize = NSSize(width: 640, height: 360)

        super.init(window: window)

        // Read this before the split view lays out (which writes its autosave): a missing
        // entry means a first launch, so the divider should open centered.
        let panesGeometryKey = "NSSplitView Subview Frames \(Self.panesAutosaveName)"
        shouldCenterPanesDivider = UserDefaults.standard.object(forKey: panesGeometryKey) == nil

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "BrowserSplit"

        // The two panes live in their own split view, so the sidebar toggle only resizes this
        // group as a whole and the panes keep their 50/50 ratio (see `panesSplitViewController`).
        panesSplitViewController.splitView.isVertical = true
        panesSplitViewController.splitView.dividerStyle = .thin
        panesSplitViewController.splitView.autosaveName = Self.panesAutosaveName
        for panel in [leftPanel, rightPanel] {
            let item = NSSplitViewItem(viewController: panel)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            panesSplitViewController.addSplitViewItem(item)
            panel.host = self
        }

        // The places/volumes strip leads, then the panes group. It's a real macOS sidebar
        // (vibrant, collapsible via View ▸ Show Sidebar) that drives the active pane.
        sidebar.delegate = self
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let panesItem = NSSplitViewItem(viewController: panesSplitViewController)
        panesItem.canCollapse = false
        splitViewController.addSplitViewItem(panesItem)

        // Assigning `contentViewController` resizes the window to the content view's
        // fitting size, discarding the initializer's `contentRect`. So set our default
        // size afterwards, then let a previously autosaved frame win if one exists.
        window.contentViewController = makeContainerViewController()
        if !window.setFrameUsingName("MainWindow") {
            window.setContentSize(NSSize(width: 1300, height: 750))
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")

        queueBar.onPauseToggle = { [weak self] in self?.togglePause() }
        queueBar.onCancelAll = { [weak self] in self?.cancelAllJobs() }
        queueBar.onCancelJob = { [weak self] id in self?.cancelJob(id) }
        queueBar.onPreferredHeightChanged = { [weak self] in self?.updateQueueBarHeight() }
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
        queueBarHeight.constant = visible ? queueBar.preferredHeight : 0
    }

    /// Follow the queue bar's height as its per-job list expands or collapses. Only adjusts
    /// while the bar is shown; `setQueueBar(visible:)` owns the collapse-to-zero when idle.
    func updateQueueBarHeight() {
        guard !queueBar.isHidden else { return }
        queueBarHeight.constant = queueBar.preferredHeight
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if shouldCenterPanesDivider {
            shouldCenterPanesDivider = false
            centerPanesDivider()
        }
        setActive(leftPanel)
        leftPanel.focusTable()
    }

    /// Split the two panes 50/50. Called once on a fresh layout (no saved divider
    /// geometry), after the window is on screen so the split view has its real width.
    private func centerPanesDivider() {
        let splitView = panesSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let available = splitView.bounds.width - splitView.dividerThickness
        guard available > 0 else { return }
        splitView.setPosition(available / 2, ofDividerAt: 0)
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
