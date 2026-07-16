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
        // Right-clicking `..` parks the cursor on it, exactly as a left-click would: drop the marks
        // and move the highlight onto the parent row. Without this the cursor stays on whatever file
        // it was on, `cursorOnParentRow` stays false, and `contextMenu` hands back the *entry* menu —
        // a menu about `..` that instead acts on the previously-selected file. Found live.
        if isParentRow(row) {
            panel.clearSelection()
            cursorOnParentRow = true
            renderRefresh()
            return
        }
        guard let index = entryIndex(forRow: row) else {
            // The empty space below the list is not an entry; leave the marks be.
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
        menu.addItem(openWithMenuItem())
        add(["view.quickLook"], to: menu)
        menu.addSeparator()
        addShareItem(to: menu)
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
        submenu.identifier = .tagsSubmenu
        submenu.delegate = self
        item.submenu = submenu
        item.isEnabled = canEditTags
        return item
    }

    /// Open With as a submenu, for the same reason Tags is one — and, like Tags, filled when it
    /// opens rather than when the parent menu is built. Here that is not only about freshness: the
    /// list costs a round trip to LaunchServices per distinct type in the selection, and a
    /// right-click that never hovers Open With should not pay for it.
    private func openWithMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.identifier = .openWithSubmenu
        submenu.delegate = self
        item.submenu = submenu
        item.isEnabled = canHandOff
        return item
    }

    /// The system's Share item, which brings its own submenu of services and its own icons.
    /// Skipped entirely for rows that have no local URL to share (an archive member, an SFTP file)
    /// rather than shown disabled — a "Share…" that can never light up is just noise in the menu.
    private func addShareItem(to menu: NSMenu) {
        let targets = handoffTargets()
        guard !targets.isEmpty else { return }
        menu.addItem(shareMenuItem(for: targets))
        menu.addSeparator()
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

/// Fills a lazily-built submenu when it opens. The pane is already `NSMenuDelegate`-shaped for this
/// — the sync sheet's diff table does the same thing for its own row menu.
///
/// The pane is the delegate of **two** submenus now, and `menuNeedsUpdate` is handed the menu
/// rather than being asked per item, so each one is identified: without that, opening Open With
/// would fill it with the tag list.
extension PanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = menu.identifier == .openWithSubmenu ? openWithMenuItems() : tagMenuItems()
        for item in items {
            menu.addItem(item)
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let tagsSubmenu = NSUserInterfaceItemIdentifier("dirnex.submenu.tags")
    static let openWithSubmenu = NSUserInterfaceItemIdentifier("dirnex.submenu.openWith")
}

private extension NSMenu {
    /// A separator, unless the menu is empty or already ends in one — so a section that validation
    /// or a missing binding emptied doesn't leave a rule floating with nothing on either side.
    func addSeparator() {
        guard let last = items.last, !last.isSeparatorItem else { return }
        addItem(.separator())
    }
}
