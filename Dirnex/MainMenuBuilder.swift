import AppKit
import DirnexCore

/// Builds the app's main menu from the command registry (PLAN.md §M3 "menu bar generated
/// from one action registry"). Each item's title, shortcut, and action come from
/// `CommandCatalog` + `CommandBinding` — the same source the Cmd+K palette reads — so the two
/// can never drift. Only the *layout* (which menus exist, the order, and the separators)
/// lives here, a presentation concern the registry deliberately stays out of.
///
/// The app menu keeps its standard About/Hide items hand-built (they aren't registry
/// commands a user searches for); Settings and Quit are registry commands like the rest.
///
/// Each item's key equivalent comes from the *effective* shortcut in `KeyBindingStore` — the
/// user's rebinding or the catalog default (PLAN.md §M3 "rebindable shortcuts") — so
/// regenerating the menu (which `AppDelegate` does whenever bindings change) is what makes a
/// new shortcut take effect.
@MainActor
enum MainMenuBuilder {
    static func build(bindings: KeyBindingStore = .shared) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(bindings: bindings))
        for spec in layout {
            mainMenu.addItem(menu(for: spec, bindings: bindings))
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
            .command("file.copy"), .command("file.move"), .command("file.pack"),
            .command("file.syncDirectories"), .command("file.compareByContents"), .separator,
            .command("file.tags"), .separator,
            .command("file.rename"), .command("file.multiRename"), .separator,
            .command("file.newFolder"), .separator,
            .command("file.trash"), .command("file.deletePermanently")
        ]),
        MenuSpec(title: "Edit", items: [
            .command("edit.undo"), .separator,
            .command("edit.copy"), .command("edit.paste"), .command("edit.pasteMove")
        ]),
        MenuSpec(title: "Select", items: [
            .command("select.all"), .command("select.invert"), .separator,
            .command("select.byPattern"), .command("select.unselectByPattern")
        ]),
        MenuSpec(title: "View", items: [
            .command("view.commandPalette"), .separator,
            .command("view.toggleSidebar"), .command("view.toggleHidden"),
            .command("view.toggleTags"), .command("view.sizeVisualization"), .separator,
            .command("view.quickLook"), .command("view.quickView"), .separator,
            .command("view.terminal")
        ]),
        MenuSpec(title: "Go", items: [
            .command("go.back"), .command("go.forward"), .command("go.history"), .separator,
            .command("go.editLocation"), .command("go.parent"), .command("go.search"),
            .command("go.saveSearch"), .separator,
            .command("go.hotlist"), .command("go.addToHotlist"), .separator,
            .command("go.connectServer"), .command("go.openInTerminal")
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

    private static func menu(for spec: MenuSpec, bindings: KeyBindingStore) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let submenu = NSMenu(title: spec.title)
        menuItem.submenu = submenu
        for item in spec.items {
            switch item {
            case .separator:
                submenu.addItem(.separator())
            case let .command(id):
                if let built = commandItem(for: id, bindings: bindings) { submenu.addItem(built) }
            }
        }
        if spec.isWindow {
            NSApp.windowsMenu = submenu
        }
        return menuItem
    }

    /// One menu item, fully described by the registry: title from `CommandCatalog`, effective
    /// shortcut from `KeyBindingStore`, action from `CommandBinding` (dispatched through the
    /// responder chain via a nil target).
    ///
    /// Internal so the pane's context menu is built from this same one place — a right-click item
    /// and its menu-bar twin must never be able to disagree about a title or a shortcut.
    static func commandItem(for id: String, bindings: KeyBindingStore = .shared) -> NSMenuItem? {
        guard let command = CommandCatalog.command(for: id),
              let selector = CommandBinding.selector(for: id) else { return nil }
        let shortcut = bindings.shortcut(for: id)
        let item = NSMenuItem(
            title: command.title,
            action: selector,
            keyEquivalent: shortcut?.keyEquivalent ?? ""
        )
        item.keyEquivalentModifierMask = shortcut?.modifierMask ?? []
        return item
    }

    private static func appMenuItem(bindings: KeyBindingStore) -> NSMenuItem {
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
        if let settings = commandItem(for: "app.settings", bindings: bindings) {
            appMenu.addItem(settings)
        }
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
        if let quit = commandItem(for: "app.quit", bindings: bindings) { appMenu.addItem(quit) }
        return appMenuItem
    }
}
