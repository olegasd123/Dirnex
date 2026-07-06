import AppKit
import DirnexCore

/// Copy (F5) and Move (F6) — the byte-moving operations, run through the window's shared
/// `FileOperationQueue` so large transfers run in the background while browsing continues
/// (PLAN.md §M2). Total Commander semantics: the operation targets the marked set over the
/// cursor and lands in the *other* pane's current directory.
///
/// This file owns only the AppKit shell — resolving the source set and destination and the
/// up-front conflict prompt, then handing the operation to the queue. Progress (the
/// window's queue bar) and the post-op re-list of both panes are the window controller's
/// job; all the byte work (clone fast path, chunked fallback, cancellation) lives in the
/// tested engine the queue drives.
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
        Task {
            await runTransfer(kind: kind, sources: sources, destination: destination)
        }
    }

    private func runTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath
    ) async {
        let enqueued = await submitTransfer(kind: kind, sources: sources, destination: destination)
        // Marks are consumed the moment the operation is queued, matching the delete flow;
        // the source rows themselves stay until the job runs and the window controller
        // re-lists both panes on completion. A cancel at the conflict prompt leaves them.
        if enqueued {
            panel.clearSelection()
            reloadEverything()
        }
        focusTable()
    }

    /// Detect name collisions in `destination`, ask the user how to resolve them if there
    /// are any, then hand the operation to the window's shared queue. Shared by F5/F6
    /// (destination = the other pane) and drag-drop (`PanelViewController+Drop`, destination
    /// = the drop target). Returns `false` when the user cancels at the conflict prompt, so
    /// the caller can leave any source marks in place.
    func submitTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath
    ) async -> Bool {
        let conflicts = await detectConflicts(names: sources.map(\.name), in: destination)
        var policy: ConflictPolicy = .fail // irrelevant when there are no conflicts
        if !conflicts.isEmpty {
            guard let chosen = await promptConflictPolicy(count: conflicts.count, in: destination) else {
                return false // user cancelled at the conflict prompt
            }
            policy = chosen
        }
        let operation = FileOperation(
            kind: kind,
            sources: sources,
            destinationDirectory: destination
        )
        host?.enqueue(operation, conflictPolicy: policy)
        return true
    }

    /// Which of the top-level source names already exist in the destination — computed
    /// off-main so a slow volume doesn't stutter the UI.
    private func detectConflicts(names: [String], in directory: VFSPath) async -> [String] {
        let backend = backend
        return await Task.detached(priority: .userInitiated) {
            names.filter { (try? backend.stat(at: directory.appending($0))) != nil }
        }.value
    }

    // MARK: - Conflict prompt

    /// Ask once, up front, how to resolve every colliding item. The rich per-file dialog
    /// (side-by-side sizes/dates, thumbnails, "apply to all") is the next M2 pass; this
    /// covers the common case with a single choice applied to the whole operation.
    private func promptConflictPolicy(count: Int, in destination: VFSPath) async -> ConflictPolicy? {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = count == 1
                ? "An item already exists in “\(destination.lastComponent)”"
                : "\(count) items already exist in “\(destination.lastComponent)”"
            alert.informativeText = "Choose how to resolve the conflict."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Overwrite If Newer")
            alert.addButton(withTitle: "Cancel")

            let handler: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: Self.policy(for: response))
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
        }
    }

    /// The response code of the fourth `NSAlert` button ("Overwrite If Newer"); AppKit
    /// only names the first three, and the rest count up from `.alertThirdButtonReturn`.
    private static let fourthButtonReturn = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
    )

    private static func policy(for response: NSApplication.ModalResponse) -> ConflictPolicy? {
        switch response {
        case .alertFirstButtonReturn: .overwrite
        case .alertSecondButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .skip
        case fourthButtonReturn: .newerOnly
        default: nil // Cancel (fifth button) or dismissal
        }
    }
}
