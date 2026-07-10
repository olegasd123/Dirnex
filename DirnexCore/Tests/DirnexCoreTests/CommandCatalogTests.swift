import Foundation
import Testing

@testable import DirnexCore

@Suite("CommandCatalog")
struct CommandCatalogTests {
    @Test("every command has a unique, non-empty id and title")
    func idsAndTitlesAreWellFormed() {
        let commands = CommandCatalog.all
        #expect(!commands.isEmpty)
        for command in commands {
            #expect(!command.id.isEmpty)
            #expect(!command.title.isEmpty)
        }
        let ids = commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("the catalog carries the M2 file operations and the palette entry itself")
    func coversKnownCommands() {
        let ids = Set(CommandCatalog.all.map(\.id))
        for expected in ["file.copy", "file.move", "file.trash", "edit.undo", "view.commandPalette"] {
            #expect(ids.contains(expected))
        }
    }

    @Test("every category is represented so no menu builds empty")
    func everyCategoryHasCommands() {
        for category in CommandCategory.allCases {
            let count = CommandCatalog.all.filter { $0.category == category }.count
            #expect(count > 0, "category \(category) has no commands")
        }
    }

    @Test("the catalog carries the M3 per-panel history commands")
    func coversHistoryCommands() {
        let ids = Set(CommandCatalog.all.map(\.id))
        for expected in ["go.back", "go.forward", "go.history"] {
            #expect(ids.contains(expected))
        }
    }

    @Test("the catalog carries the M3 workspace commands")
    func coversWorkspaceCommands() {
        let workspace = CommandCatalog.all.filter { $0.category == .workspace }
        #expect(Set(workspace.map(\.id)) == ["workspace.list", "workspace.save"])
    }

    @Test("the catalog carries the clipboard copy/paste commands on ⌘C/⌘V/⌥⌘V")
    func coversClipboardCommands() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        #expect(byID["edit.copy"]?.shortcut == CommandShortcut(key: "c", modifiers: .command))
        #expect(byID["edit.paste"]?.shortcut == CommandShortcut(key: "v", modifiers: .command))
        #expect(
            byID["edit.pasteMove"]?.shortcut
                == CommandShortcut(key: "v", modifiers: [.command, .option])
        )
    }

    @Test("the clipboard shortcuts don't collide with any other command")
    func clipboardShortcutsAreConflictFree() {
        let bindings = KeyBindings()
        for id in ["edit.copy", "edit.paste", "edit.pasteMove"] {
            #expect(bindings.conflicts(for: id).isEmpty)
        }
    }

    @Test("the M4 multi-rename tool is a conflict-free File command on ⇧F2")
    func coversMultiRename() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let multiRename = byID["file.multiRename"]
        #expect(multiRename?.category == .file)
        #expect(multiRename?.shortcut == CommandShortcut(key: "F2", modifiers: [.function, .shift]))
        #expect(KeyBindings().conflicts(for: "file.multiRename").isEmpty)
    }

    @Test("the show-hidden toggle is a conflict-free View command on ⇧⌘.")
    func coversShowHiddenToggle() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let toggle = byID["view.toggleHidden"]
        #expect(toggle?.category == .view)
        #expect(toggle?.shortcut == CommandShortcut(key: ".", modifiers: [.command, .shift]))
        #expect(KeyBindings().conflicts(for: "view.toggleHidden").isEmpty)
    }

    @Test("the M4 quick-view panel is a conflict-free View command on ⌃Q")
    func coversQuickViewPanel() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let quickView = byID["view.quickView"]
        #expect(quickView?.category == .view)
        #expect(quickView?.shortcut == CommandShortcut(key: "q", modifiers: .control))
        #expect(KeyBindings().conflicts(for: "view.quickView").isEmpty)
    }

    @Test("the M4 file search is a conflict-free Go command on ⌥F7")
    func coversFindFiles() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let search = byID["go.search"]
        #expect(search?.category == .navigation)
        #expect(search?.shortcut == CommandShortcut(key: "F7", modifiers: [.function, .option]))
        // ⌥F7 must not collide with plain F7 (New Folder) — the modifier set differs.
        #expect(KeyBindings().conflicts(for: "go.search").isEmpty)
    }
}

@Suite("CommandShortcut display")
struct CommandShortcutTests {
    @Test("modifiers render in canonical ⌃⌥⇧⌘ order with an upper-cased letter")
    func canonicalOrder() {
        let shortcut = CommandShortcut(key: "s", modifiers: [.command, .control])
        #expect(shortcut.display == "⌃⌘S")
    }

    @Test("a function key keeps its name and never shows a fn glyph")
    func functionKeyDisplay() {
        #expect(CommandShortcut(key: "F5", modifiers: .function).display == "F5")
        #expect(CommandShortcut(key: "F8", modifiers: [.function, .shift]).display == "⇧F8")
    }

    @Test("the command arrow renders the glyph, not the fn layer")
    func arrowDisplay() {
        #expect(CommandShortcut(key: "↑", modifiers: [.command, .function]).display == "⌘↑")
    }

    @Test("literal punctuation keys pass through unchanged")
    func punctuationDisplay() {
        #expect(CommandShortcut(key: "[", modifiers: [.command, .shift]).display == "⇧⌘[")
    }

    @Test("the back/forward and history shortcuts render as expected")
    func historyShortcutDisplay() {
        #expect(CommandShortcut(key: "[", modifiers: .command).display == "⌘[")
        #expect(CommandShortcut(key: "]", modifiers: .command).display == "⌘]")
        #expect(CommandShortcut(key: "↓", modifiers: [.option, .function]).display == "⌥↓")
    }
}
