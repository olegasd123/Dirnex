import AppKit

/// Application lifecycle owner.
///
/// Brings up the dual-pane browser window (M1) and installs the registry-driven main menu
/// (M3) so the app behaves like a real macOS citizen. The Cmd+K command palette is owned
/// here too, since it floats over whichever window is key and dispatches through the
/// responder chain.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindowController: BrowserWindowController?
    private let commandPalette = CommandPaletteController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenuBuilder.build()

        // Clear any archive copy-out temp files left by a previous session (PLAN.md §M4 F5
        // copy-out). Safe here — nothing is extracting yet, so there's no in-flight transfer.
        ArchiveExtractor.purgeTemporaries()

        // Rebuild the registry-driven menu whenever the user rebinds a shortcut, so the new
        // key equivalents take effect immediately (PLAN.md §M3 "rebindable shortcuts").
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMainMenu),
            name: KeyBindingStore.didChange,
            object: nil
        )

        let controller = BrowserWindowController()
        controller.showWindow(nil)
        browserWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func rebuildMainMenu() {
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    // MARK: - Command palette

    /// ⌘K (and View ▸ Command Palette…) — open the fuzzy command palette over the key window,
    /// or close it if it is already showing. Reached through the responder chain: the app
    /// delegate is its final link, so a menu item with a nil target lands here.
    @objc func showCommandPalette(_ sender: Any?) {
        commandPalette.toggle(over: NSApp.keyWindow ?? browserWindowController?.window)
    }

    // MARK: - Settings

    /// ⌘, (and the palette's "Settings…") — open the SwiftUI settings window. Reached through
    /// the responder chain, with the app delegate as its final link.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }
}
