import AppKit
import DirnexCore

/// Per-pane tabs (PLAN.md §M1 "tabs per panel: new/close/reorder, restored on
/// relaunch"). A pane owns an array of `PanelTab`s and renders the active one; all of
/// the add/close/select/reorder plumbing — plus the `TabBarView` delegate and the
/// menu actions that drive it from the keyboard — lives here to keep the controller
/// proper focused on a single directory.
extension PanelViewController {
    // MARK: - Activation

    /// Show whichever tab is active. A tab that has never been listed (fresh, or just
    /// restored from disk) is loaded from scratch; a tab we're returning to renders its
    /// stored cursor/marks/filter instantly, then refreshes in the background so it is
    /// current after having been unwatched while inactive.
    func activateTab() {
        applyColumnLayout(for: tabs[activeTabIndex])
        refreshTabBar()
        if tabs[activeTabIndex].hasLoaded {
            reloadEverything()
            refreshActiveDirectory()
        } else {
            navigate(to: panel.path)
        }
    }

    /// Re-list the active tab's directory without moving the cursor or scroll position —
    /// the tab may have gone stale while inactive (nothing watches an inactive tab).
    private func refreshActiveDirectory() {
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let index = activeTabIndex
        startWatching(path)
        Task {
            guard let listing = try? await DirectoryLoader.list(backend, at: path) else { return }
            guard token == loadToken, panel.path == path, activeTabIndex == index else { return }
            reconcileCursorFromTable()
            panel.setListing(listing)
            tabs[index].hasLoaded = true
            renderRefresh()
        }
    }

    /// Rebuild the tab strip from the current tab list; the strip hides itself when a
    /// pane has a single tab so the browser looks unchanged until a second one is opened.
    func refreshTabBar() {
        tabBar.isHidden = tabs.count <= 1
        tabBar.setTabs(tabs.map(\.title), activeIndex: activeTabIndex)
        tabBar.isActivePane = isActivePanel
    }

    // MARK: - Operations

    /// Open a new tab beside the current one, showing the same directory and inheriting
    /// its sort/hidden settings (Cmd+T).
    func addTab() {
        // Snapshot the current tab's live column geometry first, so the new tab inherits
        // exactly what's on screen (matching the sort/hidden inheritance below).
        captureColumnLayout()
        let tab = PanelTab(
            path: panel.path,
            sort: panel.model.sort,
            showHidden: panel.model.showHidden,
            columns: tabs[activeTabIndex].columnLayout
        )
        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabIndex += 1
        activateTab()
        persistState()
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count, index != activeTabIndex else { return }
        activeTabIndex = index
        activateTab()
        persistState()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    /// Close the tab at `index`. The last tab is never closed here (the caller closes the
    /// window instead, matching macOS Cmd+W), so this reports whether one was removed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, index >= 0, index < tabs.count else { return false }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        activateTab()
        persistState()
        return true
    }

    /// Reorder a tab, keeping the same tab active across the move (identity, not index).
    func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < tabs.count, source != destination else { return }
        let activeTab = tabs[activeTabIndex]
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        activeTabIndex = tabs.firstIndex { $0 === activeTab } ?? activeTabIndex
        refreshTabBar()
        persistState()
    }

    // MARK: - Persistence

    /// Write this pane's tabs (paths + per-tab sort) so they survive a relaunch.
    func persistState() {
        guard let restorationKey else { return }
        let persisted = tabs.map {
            PersistedTab(path: $0.panel.path, sort: $0.panel.model.sort, columns: $0.columnLayout)
        }
        TabPersistence.save(
            PersistedPane(tabs: persisted, activeIndex: activeTabIndex),
            paneKey: restorationKey
        )
    }

    /// Rebuild tabs from a persisted pane, dropping any whose directory has since
    /// vanished so a relaunch never opens onto a dead path or an error sheet.
    static func restoredTabs(from restoration: PersistedPane?) -> [PanelTab] {
        guard let restoration else { return [] }
        // Show-hidden is a single app-wide toggle, so every restored tab adopts it — the same
        // value a fresh tab gets. An in-session ⇧⌘. re-syncs them all live.
        let showHidden = AppPreferences.shared.showHidden
        return restoration.tabs.compactMap { persisted in
            let path = persisted.vfsPath
            var isDirectory: ObjCBool = false
            guard path.backend == .local,
                  FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return PanelTab(
                path: path,
                sort: persisted.fileSort,
                showHidden: showHidden,
                columns: persisted.columns
            )
        }
    }

    // MARK: - Menu actions (dispatched to the focused pane via the responder chain)

    @objc func newTab(_ sender: Any?) {
        addTab()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // Closing the final tab closes the window, the standard macOS Cmd+W behavior.
        if !closeTab(at: activeTabIndex) {
            view.window?.performClose(sender)
        }
    }

    @objc func showNextTab(_ sender: Any?) {
        selectNextTab()
    }

    @objc func showPreviousTab(_ sender: Any?) {
        selectPreviousTab()
    }
}

// MARK: - TabBarViewDelegate

extension PanelViewController: TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
        focusTable()
    }

    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
        focusTable()
    }

    func tabBar(_ bar: TabBarView, didMoveTabFrom source: Int, to destination: Int) {
        moveTab(from: source, to: destination)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        addTab()
        focusTable()
    }
}
