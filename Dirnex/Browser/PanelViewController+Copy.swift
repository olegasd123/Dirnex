import AppKit
import DirnexCore

/// Copy (F5) and Move (F6) — the byte-moving operations, run through the window's shared
/// `FileOperationQueue` so large transfers run in the background while browsing continues
/// (PLAN.md §M2). Total Commander semantics: the operation targets the marked set over the
/// cursor and lands in the *other* pane's current directory.
///
/// This file owns only the AppKit shell — resolving the source set and destination, then
/// handing the operation to the queue under the `.ask` conflict policy with a
/// `ConflictPrompter` that raises the rich per-file dialog on collisions. Progress (the
/// window's queue bar), the per-file conflict dialogs, and the post-op re-list of both panes
/// all happen as the queued job runs; the byte work lives in the tested engine.
extension PanelViewController {
    // MARK: - Menu actions (dispatched to the focused pane via the responder chain)

    @objc func copyToOtherPane(_ sender: Any?) {
        beginTransfer(kind: .copy)
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        beginTransfer(kind: .move)
    }

    // MARK: - Flow

    private func beginTransfer(kind: FileOperation.Kind) {
        // F5/F6 reach here via the key model, which bypasses menu validation — so re-check that
        // this isn't an archive pane, whose entries can't be extracted yet (a later M4 pass).
        guard !isArchive else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }
        let destination = destPane.panel.path
        // Copying/moving a selection onto the folder it already lives in would collide
        // with every item; point the user at a real destination instead.
        guard destination != panel.path else {
            presentOperationFailure(
                message: kind == .copy ? "Can’t copy into the same folder" : "Can’t move into the same folder",
                detail: "Open a different folder in the other panel first."
            )
            return
        }
        submitTransfer(kind: kind, sources: sources, destination: destination)
        // Marks are consumed the moment the operation is queued, matching the delete flow;
        // the source rows themselves stay until the job runs and the window controller
        // re-lists both panes on completion.
        panel.clearSelection()
        reloadEverything()
        focusTable()
    }

    /// Hand a copy/move to the window's shared queue under the `.ask` conflict policy: the
    /// engine copies non-colliding items straight through and, for each collision, calls back
    /// into a fresh `ConflictPrompter` that raises the rich per-file dialog (and remembers an
    /// "apply to all" choice for the rest of this operation). A sibling `ErrorPrompter` fields
    /// per-file *failures* the same way — TC's Skip / Retry / Abort. Shared by F5/F6 (destination
    /// = the other pane) and drag-drop (`PanelViewController+Drop`, destination = the drop target).
    func submitTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath
    ) {
        let conflictPrompter = ConflictPrompter(window: view.window)
        let errorPrompter = ErrorPrompter(window: view.window)
        let operation = FileOperation(
            kind: kind,
            sources: sources,
            destinationDirectory: destination
        )
        host?.enqueue(
            operation,
            conflictPolicy: .ask,
            resolveConflict: { context in
                // A source landing exactly on itself — Cmd+C then Cmd+V into its own folder —
                // is a duplicate, not a collision: rename it "<name> copy" without a prompt,
                // matching Finder. This only arises for a copy paste; F5/F6 target the other
                // pane and drop rejects a same-folder drop, so neither reaches this branch, and
                // a same-folder *move* is filtered out before it is ever enqueued.
                if context.source.path == context.existing.path { return .keepBoth }
                return conflictPrompter.resolve(context)
            },
            onError: { errorPrompter.resolve($0) }
        )
    }
}
