import AppKit
import DirnexCore

/// Joins the headless command registry (`DirnexCore.CommandCatalog`) to concrete AppKit
/// selectors. The registry owns the *what* — titles, categories, shortcuts, search keywords;
/// this table owns the *how* — the selector each command sends. Every selector is dispatched
/// to `nil` (the responder chain), exactly as the menu items always have been, so a command
/// lands on the focused pane, the key window, or the app, wherever it is implemented. The
/// menu bar and the Cmd+K palette both read from here, so neither can offer a command the
/// other can't run.
@MainActor
enum CommandBinding {
    /// The selector for `id`, or `nil` if the command has no wired action (none today).
    static func selector(for id: String) -> Selector? {
        selectors[id]
    }

    private static let selectors: [String: Selector] = [
        "file.newTab": #selector(PanelViewController.newTab(_:)),
        "file.closeTab": #selector(PanelViewController.closeCurrentTab(_:)),
        "file.copy": #selector(PanelViewController.copyToOtherPane(_:)),
        "file.move": #selector(PanelViewController.moveToOtherPane(_:)),
        "file.pack": #selector(PanelViewController.packSelection(_:)),
        "file.syncDirectories": #selector(PanelViewController.synchronizeDirectories(_:)),
        "file.compareByContents": #selector(PanelViewController.compareByContents(_:)),
        "file.rename": #selector(PanelViewController.renameSelection(_:)),
        "file.multiRename": #selector(PanelViewController.multiRenameSelection(_:)),
        "file.newFolder": #selector(PanelViewController.newFolder(_:)),
        "file.trash": #selector(PanelViewController.moveSelectionToTrash(_:)),
        "file.deletePermanently": #selector(PanelViewController.deleteSelectionPermanently(_:)),
        "edit.undo": #selector(PanelViewController.undoLastOperation(_:)),
        "edit.copy": #selector(PanelViewController.copy(_:)),
        "edit.paste": #selector(PanelViewController.paste(_:)),
        "edit.pasteMove": #selector(PanelViewController.pasteAndMoveFromClipboard(_:)),
        "select.all": #selector(NSResponder.selectAll(_:)),
        "select.invert": #selector(PanelViewController.invertSelectionFiles(_:)),
        "select.byPattern": #selector(PanelViewController.selectFilesByPattern(_:)),
        "select.unselectByPattern": #selector(PanelViewController.unselectFilesByPattern(_:)),
        "view.commandPalette": #selector(AppDelegate.showCommandPalette(_:)),
        "view.toggleSidebar": #selector(NSSplitViewController.toggleSidebar(_:)),
        "view.toggleHidden": #selector(PanelViewController.toggleShowHidden(_:)),
        "view.quickLook": #selector(PanelViewController.toggleQuickLookPreview(_:)),
        "view.quickView": #selector(PanelViewController.toggleQuickViewPanel(_:)),
        "go.editLocation": #selector(PanelViewController.editLocation(_:)),
        "go.search": #selector(PanelViewController.findFiles(_:)),
        "go.saveSearch": #selector(PanelViewController.saveCurrentSearch(_:)),
        "go.parent": #selector(PanelViewController.goToParentDirectory(_:)),
        "go.back": #selector(PanelViewController.goBack(_:)),
        "go.forward": #selector(PanelViewController.goForward(_:)),
        "go.history": #selector(PanelViewController.showHistory(_:)),
        "go.hotlist": #selector(PanelViewController.showHotlist(_:)),
        "go.addToHotlist": #selector(PanelViewController.addToHotlist(_:)),
        "workspace.list": #selector(PanelViewController.showWorkspaces(_:)),
        "workspace.save": #selector(PanelViewController.saveWorkspace(_:)),
        "window.minimize": #selector(NSWindow.performMiniaturize(_:)),
        "window.close": #selector(NSWindow.performClose(_:)),
        "window.previousTab": #selector(PanelViewController.showPreviousTab(_:)),
        "window.nextTab": #selector(PanelViewController.showNextTab(_:)),
        "app.settings": #selector(AppDelegate.showSettings(_:)),
        "app.quit": #selector(NSApplication.terminate(_:))
    ]
}
