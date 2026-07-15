import AppKit
import DirnexCore

/// Git awareness in a file pane: the status gutter beside the file names and the branch in the path
/// bar (PLAN.md §M6 "Git awareness: branch in path bar, status column"). The pane owns *when* to
/// look; `GitStatusProvider` owns the looking, and `DirnexCore`'s `GitStatusSnapshot` owns what the
/// answer means — so all this file does is keep three things in step with the directory on screen:
/// which repository (if any) it belongs to, the snapshot to render it from, and a watcher.
///
/// **Why a second watcher.** The pane already watches its own directory to re-list it, but that is
/// blind to exactly the changes Git status turns on. Someone running `git add .` in a terminal, or
/// switching branch, or editing a file in a sibling folder, changes what this pane's rows should
/// say while touching nothing underneath the folder on screen — the index and `HEAD` live at the
/// repository root. So the Git side watches the root instead, and every pane in the same repository
/// coalesces onto the provider's one debounced run.
extension PanelViewController {
    // MARK: - Per-tab state

    /// The working tree the active tab's directory belongs to, or `nil` when it is not in one (or
    /// is an archive / SFTP / results pane). Per tab, so switching tabs restores the Git view along
    /// with everything else rather than re-deriving it.
    var gitRepositoryRoot: VFSPath? {
        get { tabs[activeTabIndex].gitRepositoryRoot }
        set { tabs[activeTabIndex].gitRepositoryRoot = newValue }
    }

    /// The snapshot the active tab's rows are rendered from — a copy of the provider's cache, held
    /// here so a row lookup is a plain read rather than a dictionary hit on the shared cache for
    /// every one of a hundred thousand rows.
    var gitSnapshot: GitStatusSnapshot? {
        get { tabs[activeTabIndex].gitSnapshot }
        set { tabs[activeTabIndex].gitSnapshot = newValue }
    }

    /// Whether the pane is showing a repository at all — the condition for the status gutter
    /// existing and for the branch chip being visible.
    var isInGitRepository: Bool {
        gitRepositoryRoot != nil
    }

    // MARK: - Keeping up to date

    func observeGitStatusChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gitStatusDidChange),
            name: GitStatusProvider.didChangeNotification,
            object: nil
        )
    }

    /// A repository this pane may be showing was re-read. Ignore every other repository — with two
    /// panes and several tabs, most notifications are somebody else's.
    @objc private func gitStatusDidChange(_ notification: Notification) {
        guard let root = notification.userInfo?[GitStatusProvider.repositoryRootKey] as? VFSPath,
              root == gitRepositoryRoot else { return }
        applyGitSnapshot(GitStatusProvider.shared.cachedSnapshot(for: root))
    }

    /// Re-derive the active tab's Git state for the directory now on screen. Called on navigation,
    /// on a tab switch, and on every live refresh — the last of which is why the repository lookup
    /// is deliberately re-run rather than remembered: a `git init` (or an `rm -rf .git`) in the
    /// folder being watched shows up on the very next event.
    func updateGitStatus() {
        // Only the real filesystem has repositories; an archive's innards, an SFTP pane and a
        // results snapshot never do.
        guard panel.path.backend == .local else {
            clearGitStatus()
            return
        }
        let path = panel.path
        let tabIndex = activeTabIndex
        Task {
            let root = await GitStatusProvider.shared.repositoryRoot(for: path)
            // The user moved on while we were looking — whatever we found describes a directory
            // that is no longer on screen.
            guard activeTabIndex == tabIndex, panel.path == path else { return }
            guard let root else {
                clearGitStatus()
                return
            }
            gitRepositoryRoot = root
            startWatchingRepository(root)
            GitStatusProvider.shared.requestRefresh(for: root)
            // Whatever is already cached renders now; the refresh above republishes if it changed.
            // Revisiting a repository therefore paints its column with the folder, not after it.
            applyGitSnapshot(GitStatusProvider.shared.cachedSnapshot(for: root))
        }
    }

    /// Adopt `snapshot` as what the active tab renders, and reconcile the chrome it drives. A no-op
    /// when nothing changed, so the FSEvents-driven republish of an unchanged repository (someone
    /// saved a file that was already modified) costs no reload.
    private func applyGitSnapshot(_ snapshot: GitStatusSnapshot?) {
        guard snapshot != gitSnapshot else { return }
        gitSnapshot = snapshot
        // A rename in progress owns the table; the end-editing handler replays what it skipped.
        if deferRefreshIfRenaming() { return }
        updateGitColumn()
        // `renderRefresh`, never a bare `reloadData`: a reload drops the table's selection, and the
        // cursor has to be re-applied from the model afterwards — including the `..` row, which the
        // model doesn't know about and only `cursorOnParentRow` remembers. This is a live background
        // change like any other (FSEvents, a directory-size total), so it re-anchors the cursor
        // without scrolling: arriving Git status must not yank the user's reading position.
        renderRefresh()
    }

    /// Drop everything Git — leaving a repository (or a directory that stopped being one) must take
    /// the gutter, the branch and the watcher with it, not leave the last repo's state painted on.
    private func clearGitStatus() {
        gitWatcher = nil
        gitWatchedRoot = nil
        guard gitRepositoryRoot != nil || gitSnapshot != nil else { return }
        gitRepositoryRoot = nil
        gitSnapshot = nil
        if deferRefreshIfRenaming() { return }
        updateGitColumn()
        // Re-anchors the cursor after the reload, as in `applyGitSnapshot` — leaving a repository
        // must not cost the user their place any more than entering one does.
        renderRefresh()
    }

    /// Watch the working tree so the column follows the user's own `git` commands. Replaced only
    /// when the repository actually changes — walking around inside one must not tear down and
    /// rebuild the stream on every folder. The root is tracked on the pane rather than read back
    /// from the active tab, because a tab switch can leave the tab's root unchanged while the
    /// pane's watcher was torn down for the other tab.
    private func startWatchingRepository(_ root: VFSPath) {
        guard gitWatchedRoot != root || gitWatcher == nil else { return }
        gitWatchedRoot = root
        gitWatcher = DirectoryWatcher(path: root) { [weak self] in
            Task { @MainActor in
                guard let self, self.gitRepositoryRoot == root else { return }
                GitStatusProvider.shared.requestRefresh(for: root)
            }
        }
    }

    // MARK: - The status gutter

    /// Install or remove the gutter to match the pane's repository state. The mechanics of a
    /// contextual column — the width it costs Name, where it sits — are shared with the tags
    /// gutter and live in `PanelViewController+ContextualColumns`; all this decides is *whether*.
    func updateGitColumn() {
        setContextualColumn(.git, installed: isInGitRepository)
    }

    // MARK: - Rendering

    /// The status of one row, or `nil` when there is nothing to paint. Both the majority answer
    /// (`.unmodified` in a repository) and the no-repository case collapse to an empty cell.
    func gitStatus(for entry: FileEntry) -> GitFileStatus? {
        guard let gitSnapshot else { return nil }
        let status = gitSnapshot.status(for: entry.path)
        return status == .unmodified ? nil : status
    }
}

/// How a status is painted. The letters are Git's own (`GitFileStatus.code` in the core); the
/// colours are the app's, and follow the convention every Git client has converged on — green for
/// what is new, orange for what changed, red for what is gone or broken, grey for what Git is
/// deliberately not looking at.
enum GitStatusStyle {
    static func color(for status: GitFileStatus) -> NSColor {
        switch status {
        case .unmodified: .labelColor
        case .modified: .systemOrange
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemBlue
        // Ignored is the one status that means "pay no attention" — it must recede, not announce.
        case .ignored: .tertiaryLabelColor
        // A conflict is the only status that is *blocking* something; it gets the loudest colour
        // the palette has.
        case .conflicted: .systemRed
        }
    }
}
