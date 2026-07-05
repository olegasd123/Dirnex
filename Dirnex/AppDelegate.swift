import AppKit

/// Application lifecycle owner.
///
/// Brings up the dual-pane browser window (M1) and a minimal main menu so the app
/// behaves like a real macOS citizen (Cmd+Q quits, About works). The action-registry
/// driven menu replaces the hand-built one in M3.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        let controller = BrowserWindowController()
        controller.showWindow(nil)
        browserWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    /// Builds the smallest useful main menu. Replaced by the action-registry
    /// driven menu in M3 (see PLAN.md §M3), but until then this keeps the
    /// standard shortcuts alive.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        buildFileMenu(into: mainMenu)
        buildSelectMenu(into: mainMenu)
        buildViewMenu(into: mainMenu)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        // Cmd+W closes a tab (see the File menu); the window keeps Cmd+Shift+W, matching
        // Safari/Terminal's tabbed-window convention.
        let closeWindow = windowMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(.separator())
        let previousTab = windowMenu.addItem(
            withTitle: "Show Previous Tab",
            action: #selector(PanelViewController.showPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        let nextTab = windowMenu.addItem(
            withTitle: "Show Next Tab",
            action: #selector(PanelViewController.showNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// The Select menu — mark-set commands. Nil targets dispatch through the responder
    /// chain to the focused pane (see `PanelViewController+Select`). The keypad `+`/`-`
    /// gesture that drives the pattern items lives in `FileTableView`; these menu items
    /// carry no key equivalent so a bare `+`/`-` keeps reaching the type-to-filter, and
    /// give laptops without a keypad a mouse-reachable path until M3's rebindable palette.
    private func buildSelectMenu(into mainMenu: NSMenu) {
        let selectMenuItem = NSMenuItem()
        mainMenu.addItem(selectMenuItem)
        let selectMenu = NSMenu(title: "Select")
        selectMenuItem.submenu = selectMenu
        selectMenu.addItem(
            withTitle: "Invert Selection",
            action: #selector(PanelViewController.invertSelectionFiles(_:)),
            keyEquivalent: ""
        )
        selectMenu.addItem(.separator())
        selectMenu.addItem(
            withTitle: "Select by Pattern…",
            action: #selector(PanelViewController.selectFilesByPattern(_:)),
            keyEquivalent: ""
        )
        selectMenu.addItem(
            withTitle: "Unselect by Pattern…",
            action: #selector(PanelViewController.unselectFilesByPattern(_:)),
            keyEquivalent: ""
        )
    }

    /// The View menu — sidebar visibility for now. `toggleSidebar(_:)` dispatches through
    /// the responder chain to the window's `NSSplitViewController`, which owns the
    /// collapsible places/volumes sidebar.
    private func buildViewMenu(into mainMenu: NSMenu) {
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let toggleSidebar = viewMenu.addItem(
            withTitle: "Show Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
    }

    /// The File menu — just tab commands for now. Nil targets dispatch through the
    /// responder chain to whichever pane is focused (see `PanelViewController+Tabs`).
    private func buildFileMenu(into mainMenu: NSMenu) {
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(
            withTitle: "New Tab",
            action: #selector(PanelViewController.newTab(_:)),
            keyEquivalent: "t"
        )
        fileMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(PanelViewController.closeCurrentTab(_:)),
            keyEquivalent: "w"
        )
    }
}
