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
    /// The pane commands and the titlebar Back/Forward buttons act on: the focused one, falling
    /// back to the left pane before either has taken focus.
    var focusedPanel: PanelViewController { activePanel ?? leftPanel }

    /// Quick View (⌃Q) on/off for this window. When on, the inactive pane shows a live Quick
    /// Look preview of the file under the active pane's cursor (PLAN.md §M4). Owned here
    /// because the mode spans both panes and follows whichever is active.
    private var isQuickViewOn = false

    /// Archive members extracted for preview (Quick Look ⌘Y / Quick View ⌃Q inside a browsed
    /// archive), shared across both panes and both surfaces (PLAN.md §M4 "Quick Look inside").
    let archivePreviewCache = ArchivePreviewCache()

    /// Local key monitor that lets Esc close Quick View no matter where focus sits in this
    /// window (e.g. after the user clicked into the preview). A raw-event monitor rather than a
    /// `cancelOperation:` override because a focused `PDFView` may never translate the Esc key
    /// into that action, so the message would never bubble. `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can hand the token to `NSEvent.removeMonitor` — it's only ever
    /// touched on the main actor. See `installEscapeMonitor()`.
    nonisolated(unsafe) private var escapeMonitor: Any?

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

    /// The trailing titlebar button that toggles hidden files app-wide (the ⇧⌘. command in
    /// button form). Held so `showHiddenDidChange` can restyle it to track the current state.
    let hiddenToggleButton = NSButton()

    /// The leading titlebar back/forward control beside the sidebar toggle — the ⌘[ / ⌘] history
    /// commands (View ▸ Go) as a two-segment pill, the same control Finder/Safari use. Held so a
    /// navigation, tab switch, or focus change can re-validate each segment's enabled state
    /// against the active pane's trail (`updateNavigationButtons`).
    let navigationControl = NSSegmentedControl()

    init() {
        // A composite backend so a pane can browse into an archive (`archive:…` paths route
        // to a lazily-mounted read-only `ArchiveBackend`) while every local path still runs
        // through `LocalBackend` unchanged — including the shared queue and undo journal.
        let backend = CompositeBackend(local: LocalBackend())
        queue = FileOperationQueue(backend: backend)
        undoController = UndoController(backend: backend)
        let home = VFSPath.local(NSHomeDirectory())
        // Each pane restores its own tabs from the last session, keyed by side — unless the
        // user has turned session restore off (General settings), in which case both panes
        // open fresh at Home. The panes still persist their tabs so the setting can be
        // toggled back on without losing them.
        let restoreSession = AppPreferences.shared.restoreSession
        leftPanel = PanelViewController(
            backend: backend,
            restoration: restoreSession ? TabPersistence.load(paneKey: "left") : nil,
            defaultPath: home,
            restorationKey: "left"
        )
        rightPanel = PanelViewController(
            backend: backend,
            restoration: restoreSession ? TabPersistence.load(paneKey: "right") : nil,
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

        // Modern chrome (like Notes/Xcode/Claude): no visible title bar. The content —
        // the vibrant sidebar and the two panes — runs edge-to-edge to the top of the
        // window, with the traffic lights floating over the sidebar. The title bar space
        // becomes usable window height instead of a dead strip. A leading titlebar
        // accessory (installed below) puts a sidebar show/hide button beside the traffic
        // lights; pane and sidebar content inset themselves below this zone via the safe
        // area, so nothing hides under the buttons.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

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
        // A `HairlineSplitView` tints the inter-pane divider to match the column-header borders;
        // it must replace the default split view before any items are added (the setter clears
        // them). Setting it also re-adopts the controller as the split view's delegate.
        panesSplitViewController.splitView = HairlineSplitView()
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

        installSidebarToggle()
        installNavigationButtons()
        installHiddenToggle()

        queueBar.onPauseToggle = { [weak self] in self?.togglePause() }
        queueBar.onCancelAll = { [weak self] in self?.cancelAllJobs() }
        queueBar.onCancelJob = { [weak self] id in self?.cancelJob(id) }
        queueBar.onPreferredHeightChanged = { [weak self] in self?.updateQueueBarHeight() }
        startObservingQueue()
        installEscapeMonitor()
    }

    /// Esc closes Quick View from anywhere in this window. A window-scoped local monitor sees the
    /// raw key event ahead of responder dispatch, so it works even when the focused view (the
    /// preview `PDFView`) would otherwise swallow the key. It deliberately stands aside for the
    /// responders that own Esc themselves: a focused file table runs its progressive Esc (clear
    /// filter → close Quick View → clear marks) via `fileTableCancel`, and a text field editor
    /// cancels the edit. Only fires while this window is key, so a sheet, the ⌘K palette, or the
    /// Settings window keep their own Esc.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53, // Esc
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                  window?.isKeyWindow == true,
                  isQuickViewOn
            else { return event }
            let responder = window?.firstResponder
            // A file table or a text edit owns Esc for its own purpose — let the event through.
            if responder is FileTableView || responder is NSText { return event }
            toggleQuickView()
            return nil
        }
    }

    /// Put a sidebar show/hide button immediately to the right of the traffic lights, in
    /// the otherwise-empty transparent title bar. A `.leading` titlebar accessory is the
    /// standard slot for it; the button drives the split controller's `toggleSidebar`, the
    /// same action as View ▸ Show Sidebar (⌃⌘S).
    private func installSidebarToggle() {
        let button = NSButton()
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: "Toggle Sidebar"
        )
        button.image?.isTemplate = true
        button.toolTip = "Hide or show the sidebar"
        button.target = splitViewController
        button.action = #selector(NSSplitViewController.toggleSidebar(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window?.addTitlebarAccessoryViewController(accessory)
    }

    deinit {
        queueObservation?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
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

    var isQuickViewEnabled: Bool { isQuickViewOn }

    func toggleQuickView() {
        isQuickViewOn.toggle()
        updateQuickView()
        // Keep focus on a real pane. Matters most when closing: Esc may arrive while the preview
        // (a `PDFView` the user clicked into) is first responder, and that view is about to hide.
        (activePanel ?? leftPanel).focusTable()
    }

    func panelCursorDidChange(_ panel: PanelViewController) {
        guard isQuickViewOn, panel === (activePanel ?? leftPanel) else { return }
        showActivePreview(from: panel)
    }

    func panelDidNavigate(_ panel: PanelViewController) {
        updateNavigationButtons()
    }

    /// Reconcile both panes with the current Quick View state: the active pane shows its file
    /// list, the inactive pane previews the file under the active cursor. With the mode off,
    /// both panes drop any preview. Run on every toggle and whenever the active pane changes,
    /// so the preview always sits opposite the focused pane.
    private func updateQuickView() {
        guard isQuickViewOn else {
            leftPanel.hideQuickViewPreview()
            rightPanel.hideQuickViewPreview()
            return
        }
        let active = activePanel ?? leftPanel
        active.hideQuickViewPreview()
        showActivePreview(from: active)
    }

    /// Point the inactive pane's preview at the file under `active`'s cursor. A local file (or an
    /// already-extracted archive member) shows at once; an archive member not yet on disk is
    /// extracted on demand and shown when it lands — provided Quick View is still on and the
    /// cursor hasn't moved on in the meantime.
    private func showActivePreview(from active: PanelViewController) {
        counterpart(of: active).showQuickViewPreview(of: active.quickViewSourceURL)
        active.prepareArchivePreview { [weak self, weak active] in
            guard let self, let active, isQuickViewOn,
                  active === (activePanel ?? leftPanel) else { return }
            counterpart(of: active).showQuickViewPreview(of: active.quickViewSourceURL)
        }
    }

    private func counterpart(of panel: PanelViewController) -> PanelViewController {
        panel === leftPanel ? rightPanel : leftPanel
    }

    private func setActive(_ panel: PanelViewController) {
        guard activePanel !== panel else { return }
        activePanel?.isActivePanel = false
        panel.isActivePanel = true
        activePanel = panel
        // The titlebar Back/Forward buttons follow whichever pane is focused (⌘[ / ⌘] do too).
        updateNavigationButtons()
        // The preview always sits opposite the active pane, so a focus switch swaps which pane
        // shows its list and which shows the preview.
        if isQuickViewOn { updateQuickView() }
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
