import AppKit
import DirnexCore

/// Finder tags in a file pane: the dots beside the file names (PLAN.md §M6 "Finder tags: column,
/// edit from panel…"; the editing half is `PanelViewController+TagEditing`). The pane owns *when*
/// to look, `FinderTagProvider` owns the looking, and `DirnexCore`'s `FinderTag` owns what the
/// bytes mean — so all this file does is keep the snapshot in step with the directory on screen.
///
/// **Why there is no second watcher here, unlike Git.** The Git side had to watch the *repository
/// root*, because `git add` in a terminal changes what a pane's rows should say while touching
/// nothing underneath the folder on screen — the index and `HEAD` live elsewhere. A tag has no
/// elsewhere: it is an extended attribute **on the file itself**, so the pane's own directory
/// watcher already fires for it, and `directoryDidChange` re-derives tags along with the listing.
extension PanelViewController {
    // MARK: - Per-tab state

    /// The tags the active tab's rows are painted from — a copy of the provider's cache, held here
    /// so a row lookup is a plain read rather than a hit on the shared cache for every one of a
    /// hundred thousand rows. Per tab, so switching tabs restores the dots with everything else.
    var tagSnapshot: FinderTagSnapshot? {
        get { tabs[activeTabIndex].tagSnapshot }
        set { tabs[activeTabIndex].tagSnapshot = newValue }
    }

    /// Whether the tags gutter belongs on screen: the user wants it, **and** these rows could carry
    /// tags at all.
    ///
    /// The second half is not the preference being second-guessed — it is that only local files
    /// have extended attributes. Inside an archive or on an SFTP volume the column could never be
    /// anything but blank, and a blank column is exactly what the preference exists to avoid.
    /// Search results *do* qualify: the pane is virtual but every row in it is a real local file,
    /// so its dots are as real as any folder's.
    var isTagColumnVisible: Bool {
        guard AppPreferences.shared.showTags else { return false }
        return panel.path.backend == .local || isSearchResults
    }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Show Tags. App-wide, like ⇧⌘. — every pane and tab reflects it, via the preference's
    /// own notification rather than by reaching across to the other panes from here.
    @objc func toggleShowTags(_ sender: Any?) {
        AppPreferences.shared.toggleShowTags()
    }

    // MARK: - Keeping up to date

    func observeFinderTagChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(finderTagsDidChange),
            name: FinderTagProvider.didChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(showTagsPreferenceDidChange),
            name: AppPreferences.showTagsDidChange,
            object: nil
        )
    }

    /// A directory this pane may be showing was re-scanned. Ignore every other one — with two panes
    /// and several tabs, most notifications are somebody else's.
    @objc private func finderTagsDidChange(_ notification: Notification) {
        guard let directory = notification.userInfo?[FinderTagProvider.directoryKey] as? VFSPath,
              directory == panel.path else { return }
        applyTagSnapshot(FinderTagProvider.shared.cachedSnapshot(for: directory))
    }

    /// The View-menu toggle flipped. Every pane installs or drops the column live, without waiting
    /// for a navigation — a toggle you have to walk somewhere to see the effect of reads as broken.
    @objc private func showTagsPreferenceDidChange(_ notification: Notification) {
        updateTagStatus()
    }

    /// Re-derive the active tab's tags for the directory now on screen. Called on navigation, on a
    /// tab switch, on every live refresh, and when the preference flips.
    func updateTagStatus() {
        guard isTagColumnVisible else {
            clearTagStatus()
            return
        }
        // The column goes up *now*, before the scan lands, so the folder arrives at its final
        // geometry: filling an existing column a few milliseconds later is invisible, whereas
        // installing one afterwards would re-truncate every name the user is already reading.
        updateTagColumn()
        let directory = panel.path
        // The whole listing, not the visible rows: `requestRefresh` explains why a filtered pane
        // must not narrow what the shared cache holds.
        FinderTagProvider.shared.requestRefresh(
            for: directory,
            entries: panel.model.listing.entries.map(\.path)
        )
        // Whatever is already cached renders now; the scan republishes if it changed. Revisiting a
        // folder therefore paints its dots with the folder, not after it.
        applyTagSnapshot(FinderTagProvider.shared.cachedSnapshot(for: directory))
    }

    /// Ask for a re-scan of the directory on screen — what the tag editor calls after writing, so
    /// the dots follow the edit without waiting for FSEvents to come back around.
    func refreshTagsAfterEdit() {
        guard isTagColumnVisible else { return }
        FinderTagProvider.shared.requestRefresh(
            for: panel.path,
            entries: panel.model.listing.entries.map(\.path)
        )
    }

    /// Adopt `snapshot` as what the active tab renders. A no-op when nothing changed, so the
    /// FSEvents-driven republish of an untouched directory (someone saved a file in it) costs no
    /// reload — see `FinderTagSnapshot.==`, which had to be hand-rolled to make that check honest.
    private func applyTagSnapshot(_ snapshot: FinderTagSnapshot?) {
        guard snapshot != tagSnapshot else { return }
        tagSnapshot = snapshot
        // A rename in progress owns the table; the end-editing handler replays what it skipped.
        if deferRefreshIfRenaming() { return }
        // `renderRefresh`, never a bare `reloadData`: a reload drops the table's selection, and the
        // cursor has to be re-applied from the model afterwards — including the `..` row, which the
        // model doesn't know about and only `cursorOnParentRow` remembers. This is a live
        // background change like any other, so it re-anchors without scrolling: arriving dots must
        // not yank the user's reading position.
        renderRefresh()
    }

    /// Drop the tags — leaving for an archive, or switching the column off, must take the gutter
    /// with it rather than leave the last folder's dots painted on.
    private func clearTagStatus() {
        updateTagColumn()
        guard tagSnapshot != nil else { return }
        tagSnapshot = nil
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }

    // MARK: - The gutter

    /// Install or remove the gutter to match the pane's state. The mechanics of a contextual column
    /// are shared with the Git gutter — see `PanelViewController+ContextualColumns`.
    func updateTagColumn() {
        setContextualColumn(.tags, installed: isTagColumnVisible)
    }

    // MARK: - Rendering

    /// The tags on one row, `[]` when it has none or the scan hasn't landed yet.
    func tags(for entry: FileEntry) -> [FinderTag] {
        tagSnapshot?.tags(for: entry.path) ?? []
    }

    /// The gutter cell for one row. A `nil` entry is the synthetic `..` row — a way out rather than
    /// a file, so it draws nothing, but it must still come from this cell type (see the reuse-queue
    /// note in `PanelViewController+Table`).
    func tagCell(for entry: FileEntry?, in tableView: NSTableView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(Column.tags.rawValue)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TagCellView
            ?? TagCellView(frame: .zero)
        cell.identifier = identifier
        cell.dimmed = entry?.isHidden ?? false
        cell.tags = entry.map { tags(for: $0) } ?? []
        return cell
    }
}
