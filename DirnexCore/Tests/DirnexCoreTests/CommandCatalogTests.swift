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
