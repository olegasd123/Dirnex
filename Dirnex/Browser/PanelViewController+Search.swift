import AppKit
import DirnexCore

/// Spotlight file search (⌥F7 / palette "Find Files…") — PLAN.md §M4 "Search (Alt+F7 / palette):
/// mdfind-backed name+content search" and "Search results → virtual panel listing".
///
/// The pane presents the `SearchController` sheet, runs the resulting `SpotlightQuery` through
/// `SpotlightSearchRunner` off the main thread, and installs the hits as a **virtual results
/// tab**: a `PanelTab` on the synthetic `.search` backend whose entries carry their real
/// on-disk paths. The tab supports the normal cursor/selection and Copy-to-the-other-pane (F5)
/// the plan calls for; the pane recognizes it via `isSearchResults` and suppresses the
/// directory-bound behavior (watching, re-listing, the `..` row, in-place mutations).
extension PanelViewController {
    /// Whether the active tab is showing Spotlight search results rather than a real directory.
    /// Everything that assumes a listable, writable, watchable directory checks this first.
    var isSearchResults: Bool {
        panel.path.backend == .search
    }

    // MARK: - Menu / key action (dispatched to the focused pane via the responder chain)

    @objc func findFiles(_ sender: Any?) {
        let controller = SearchController(currentFolderName: searchScopeDirectory().lastComponent)
        controller.onSearch = { [weak self] query, scopeToFolder in
            self?.runSearch(query, scopeToCurrentFolder: scopeToFolder)
        }
        presentAsSheet(controller)
    }

    // MARK: - Running the search

    /// The real directory a "This Folder" search scopes to — the current directory when the pane
    /// shows one, else Home (a results pane has no real directory of its own to search within).
    private func searchScopeDirectory() -> VFSPath {
        panel.path.backend == .local ? panel.path : .local(NSHomeDirectory())
    }

    private func runSearch(_ query: SpotlightQuery, scopeToCurrentFolder: Bool) {
        let scope: VFSPath? = scopeToCurrentFolder ? searchScopeDirectory() : nil
        let backend = backend
        Task {
            let results = await SpotlightSearchRunner.run(query, scope: scope, backend: backend)
            openSearchResults(results.entries, query: query, truncated: results.truncated)
        }
    }

    // MARK: - Virtual results tab

    /// Install the hits as a new virtual tab beside the current one and switch to it, so the
    /// user's browsing tab is preserved (closing the results tab with ⌘W returns to it). Results
    /// are a snapshot: the tab is marked loaded so nothing tries to re-list the synthetic path.
    private func openSearchResults(_ entries: [FileEntry], query: SpotlightQuery, truncated: Bool) {
        captureColumnLayout()
        let listing = DirectoryListing(
            path: VFSPath(backend: .search, path: "/" + query.summary),
            entries: entries
        )
        // Show every hit, dotfiles included — a search result the user explicitly matched
        // shouldn't be hidden by the app-wide show-hidden toggle.
        let model = DirectoryModel(listing: listing, sort: panel.model.sort, showHidden: true)
        let tab = PanelTab(panel: Panel(model: model))
        tab.hasLoaded = true
        tab.columnLayout = tabs[activeTabIndex].columnLayout

        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabIndex += 1
        activateTab()
        persistState()
        focusTable()

        if truncated {
            presentOperationFailure(
                message: "Showing the first \(SpotlightSearchRunner.resultLimit) results",
                detail: "Your search matched more items. Narrow it to see the rest."
            )
        }
    }
}
