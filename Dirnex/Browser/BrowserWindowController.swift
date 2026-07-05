import AppKit
import DirnexCore

/// The main window: two file panes side by side with a draggable divider, exactly
/// one of them active at a time. Owns focus routing (Tab switches panes) and the
/// active-pane bookkeeping the panes themselves stay ignorant of.
@MainActor
final class BrowserWindowController: NSWindowController, PanelHost {
    private let leftPanel: PanelViewController
    private let rightPanel: PanelViewController
    private let splitViewController = NSSplitViewController()
    private weak var activePanel: PanelViewController?

    init() {
        let backend = LocalBackend()
        let home = VFSPath.local(NSHomeDirectory())
        leftPanel = PanelViewController(backend: backend, path: home)
        rightPanel = PanelViewController(backend: backend, path: home)

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
        splitViewController.splitView.autosaveName = "MainSplit"
        for panel in [leftPanel, rightPanel] {
            let item = NSSplitViewItem(viewController: panel)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            splitViewController.addSplitViewItem(item)
            panel.host = self
        }

        window.contentViewController = splitViewController
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        let other = (panel === leftPanel) ? rightPanel : leftPanel
        other.focusTable()
    }

    private func setActive(_ panel: PanelViewController) {
        guard activePanel !== panel else { return }
        activePanel?.isActivePanel = false
        panel.isActivePanel = true
        activePanel = panel
    }
}
