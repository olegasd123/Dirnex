import AppKit
import DirnexCore

/// The right-click menu over a file pane.
///
/// Built from `CommandCatalog` through `MainMenuBuilder.commandItem`, exactly like the menu bar, so
/// the two can never drift on a title or a shortcut — the same "one action registry" rule the plan
/// sets for the menu bar and the palette (§M3). Only the *layout* is here, which is a presentation
/// choice: a right-click offers what you'd do to the thing under the pointer, not everything.
///
/// Items carry a nil target and dispatch through the responder chain, which means `validateMenuItem`
/// greys them out exactly as it does in the menu bar — a read-only location, an archive, a results
/// pane all degrade for free rather than needing a second set of rules here.
extension PanelViewController {
    /// The menu for a right-click on `row` (`-1` in the empty space below the rows).
    func contextMenu(forRow row: Int) -> NSMenu {
        // Right-click acts on the pane it points at, so take focus first. The items dispatch through
        // the responder chain, so without this a right-click in the *inactive* pane would run its
        // command against the other one — the pane you were looking at, not the one you clicked.
        focusTable()
        retargetSelection(forClickedRow: row)
        return row >= 0 && !cursorOnParentRow ? entryMenu() : backgroundMenu()
    }

    /// Make the click's target the thing the menu will act on.
    ///
    /// The rule is Finder's, and it exists because marks here outrank the cursor
    /// (`selectionTargets`): right-clicking a row *inside* the marked set acts on the whole set,
    /// while right-clicking outside it collapses the selection onto that one row. Without the
    /// collapse, right-clicking an unmarked file while three others were marked would show a menu
    /// that acts on the three — pointing at one file and operating on others.
    private func retargetSelection(forClickedRow row: Int) {
        guard let index = entryIndex(forRow: row) else {
            // The `..` row and the empty space below the list are not entries; leave the marks be.
            return
        }
        if panel.isMarked(panel.model[index]) { return }
        panel.clearSelection()
        panel.moveCursor(to: index)
        cursorOnParentRow = false
        // `renderRefresh`, not `syncCursorToTable` + `updateChrome`: dropping the marks changes what
        // every previously-marked *row* looks like, not just the cursor and the footer. Without the
        // reload the footer said "7 items" while five rows stayed bold red — a menu about to act on
        // one file, over a pane still drawing five as chosen. Found live.
        renderRefresh()
    }

    /// The menu over a file or folder. Ordered by what a right-click is usually for: open it, move
    /// it across, rename it, tag it, then the clipboard, then the destructive end — with Trash last
    /// and separated, where a mis-aimed click won't land on it.
    private func entryMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open",
            action: #selector(openContextEntry(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        add(["view.quickLook"], to: menu)
        menu.addSeparator()
        add(["file.copy", "file.move"], to: menu)
        menu.addSeparator()
        add(["file.rename"], to: menu)
        menu.addItem(tagsMenuItem())
        menu.addSeparator()
        add(["edit.copy", "edit.paste", "file.pack"], to: menu)
        menu.addSeparator()
        add(["file.trash"], to: menu)
        return menu
    }

    /// The menu over the pane's empty space: nothing is under the pointer, so this is about the
    /// *folder* — make something in it, or paste into it.
    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        add(["file.newFolder", "edit.paste"], to: menu)
        menu.addSeparator()
        add(["go.addToHotlist", "file.syncDirectories"], to: menu)
        return menu
    }

    /// Tags as a **submenu**, not an item that opens yet another popup: the whole point of the
    /// right-click is that the menu is already open, so the tags should be one hover away rather
    /// than a second click that replaces it. Rebuilt on open (`NSMenuDelegate`) so it reads the
    /// files rather than a snapshot taken when the parent menu was assembled.
    private func tagsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        item.submenu = submenu
        item.isEnabled = canEditTags
        return item
    }

    /// Add one registry command per id, skipping any that has no binding — a missing selector is a
    /// programming error, not something to crash a right-click over.
    private func add(_ ids: [String], to menu: NSMenu) {
        for id in ids {
            guard let item = MainMenuBuilder.commandItem(for: id) else { continue }
            // A context menu shouldn't advertise key equivalents *and* fire on them while open.
            // The title carries the command; the menu bar is where shortcuts are learned.
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }
    }

    /// "Open" — the double-click, as a menu item. Not a registry command because opening isn't one:
    /// it is the table's own `Return`/double-click gesture, which is why this is the one item here
    /// with a real target rather than a responder-chain dispatch.
    @objc private func openContextEntry(_ sender: Any?) {
        openCurrentEntry()
    }
}

/// Fills the Tags submenu when it opens. The pane is already `NSMenuDelegate`-shaped for this — the
/// sync sheet's diff table does the same thing for its own row menu.
extension PanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in tagMenuItems() {
            menu.addItem(item)
        }
    }
}

private extension NSMenu {
    /// A separator, unless the menu is empty or already ends in one — so a section that validation
    /// or a missing binding emptied doesn't leave a rule floating with nothing on either side.
    func addSeparator() {
        guard let last = items.last, !last.isSeparatorItem else { return }
        addItem(.separator())
    }
}
