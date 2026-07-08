import AppKit
import DirnexCore

/// Builds the app's main menu from the command registry (PLAN.md §M3 "menu bar generated
/// from one action registry"). Each item's title, shortcut, and action come from
/// `CommandCatalog` + `CommandBinding` — the same source the Cmd+K palette reads — so the two
/// can never drift. Only the *layout* (which menus exist, the order, and the separators)
/// lives here, a presentation concern the registry deliberately stays out of.
///
/// The app menu keeps its standard About/Hide items hand-built (they aren't registry
/// commands a user searches for); Quit is a registry command like the rest.
@MainActor
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        for spec in layout {
            mainMenu.addItem(menu(for: spec))
        }
        return mainMenu
    }

    // MARK: - Layout

    private enum Item {
        case command(String)
        case separator
    }

    private struct MenuSpec {
        let title: String
        let items: [Item]
        var isWindow = false
    }

    /// The top-level menus after the app menu, mirroring the categories in the registry but
    /// owning the grouping/separators AppKit users expect. Cmd+W closes a *tab* (File);
    /// the window keeps Cmd+Shift+W (Window), matching Safari/Terminal.
    private static let layout: [MenuSpec] = [
        MenuSpec(title: "File", items: [
            .command("file.newTab"), .command("file.closeTab"), .separator,
            .command("file.copy"), .command("file.move"), .separator,
            .command("file.rename"), .separator,
            .command("file.newFolder"), .separator,
            .command("file.trash"), .command("file.deletePermanently")
        ]),
        MenuSpec(title: "Edit", items: [.command("edit.undo")]),
        MenuSpec(title: "Select", items: [
            .command("select.invert"), .separator,
            .command("select.byPattern"), .command("select.unselectByPattern")
        ]),
        MenuSpec(title: "View", items: [
            .command("view.commandPalette"), .separator,
            .command("view.toggleSidebar"), .command("view.quickLook")
        ]),
        MenuSpec(title: "Go", items: [
            .command("go.back"), .command("go.forward"), .command("go.history"), .separator,
            .command("go.editLocation"), .command("go.parent"), .separator,
            .command("go.hotlist"), .command("go.addToHotlist")
        ]),
        MenuSpec(title: "Workspace", items: [
            .command("workspace.list"), .command("workspace.save")
        ]),
        MenuSpec(title: "Window", items: [
            .command("window.minimize"), .command("window.close"), .separator,
            .command("window.previousTab"), .command("window.nextTab")
        ], isWindow: true)
    ]

    // MARK: - Building

    private static func menu(for spec: MenuSpec) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let submenu = NSMenu(title: spec.title)
        menuItem.submenu = submenu
        for item in spec.items {
            switch item {
            case .separator:
                submenu.addItem(.separator())
            case let .command(id):
                if let built = commandItem(for: id) { submenu.addItem(built) }
            }
        }
        if spec.isWindow {
            NSApp.windowsMenu = submenu
        }
        return menuItem
    }

    /// One menu item, fully described by the registry: title + shortcut from `CommandCatalog`,
    /// action from `CommandBinding` (dispatched through the responder chain via a nil target).
    private static func commandItem(for id: String) -> NSMenuItem? {
        guard let command = CommandCatalog.command(for: id),
              let selector = CommandBinding.selector(for: id) else { return nil }
        let item = NSMenuItem(
            title: command.title,
            action: selector,
            keyEquivalent: command.shortcut?.keyEquivalent ?? ""
        )
        item.keyEquivalentModifierMask = command.shortcut?.modifierMask ?? []
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
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
        if let quit = commandItem(for: "app.quit") { appMenu.addItem(quit) }
        return appMenuItem
    }
}
