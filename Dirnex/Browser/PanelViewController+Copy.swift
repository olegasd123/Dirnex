import AppKit
import DirnexCore

/// Copy (F5) and Move (F6) — the byte-moving operations, run through `DirnexCore`'s
/// `CopyEngine` on a background task so a large transfer never blocks the UI (PLAN.md
/// §M2). Total Commander semantics: the operation targets the marked set over the
/// cursor and lands in the *other* pane's current directory.
///
/// This file owns only the AppKit shell — resolving the source set and destination,
/// the up-front conflict prompt, the progress sheet, and the post-op refresh of both
/// panes. All the byte work (clone fast path, chunked fallback, cancellation) lives in
/// the tested engine.
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
            await runTransfer(
                kind: kind,
                sources: sources,
                destination: destination,
                destPane: destPane
            )
        }
    }

    private func runTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath,
        destPane: PanelViewController
    ) async {
        let conflicts = await detectConflicts(names: sources.map(\.name), in: destination)
        var policy: ConflictPolicy = .fail // irrelevant when there are no conflicts
        if !conflicts.isEmpty {
            guard let chosen = await promptConflictPolicy(count: conflicts.count, in: destination) else {
                focusTable()
                return // user cancelled at the conflict prompt
            }
            policy = chosen
        }
        await performTransfer(
            kind: kind, sources: sources, destination: destination, policy: policy,
            destPane: destPane
        )
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

    private static func policy(for response: NSApplication.ModalResponse) -> ConflictPolicy? {
        switch response {
        case .alertFirstButtonReturn: .overwrite
        case .alertSecondButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .skip
        default: nil // Cancel
        }
    }

    // MARK: - Run

    private func performTransfer(
        kind: FileOperation.Kind,
        sources: [FileEntry],
        destination: VFSPath,
        policy: ConflictPolicy,
        destPane: PanelViewController
    ) async {
        let operation = FileOperation(
            kind: kind,
            sources: sources,
            destinationDirectory: destination
        )
        let backend = backend
        let (stream, continuation) = AsyncStream<OperationProgress>.makeStream()

        // The engine is synchronous; run it on a detached task and stream progress back.
        // `Task.isCancelled` is what the Cancel button trips via `task.cancel()`.
        let task = Task.detached(priority: .userInitiated) { () -> OperationReport in
            let report = CopyEngine.run(
                operation,
                using: backend,
                conflictPolicy: policy,
                onProgress: { continuation.yield($0) },
                isCancelled: { Task.isCancelled }
            )
            continuation.finish()
            return report
        }

        let sheet = OperationProgressSheet(kind: kind)
        sheet.present(in: view.window) { task.cancel() }
        for await progress in stream {
            sheet.update(progress)
        }
        sheet.dismiss()
        finishTransfer(report: await task.value, kind: kind, destPane: destPane)
    }

    private func finishTransfer(
        report: OperationReport,
        kind: FileOperation.Kind,
        destPane: PanelViewController
    ) {
        // Marks are consumed by the operation, matching the delete flow; both panes
        // re-list so the source (for a move) and destination reflect the change at once.
        // The FSEvents watchers would catch up on their own, but an explicit refresh is
        // immediate and deterministic.
        panel.clearSelection()
        refreshCurrentDirectory()
        destPane.refreshCurrentDirectory()
        focusTable()

        guard !report.failures.isEmpty else { return }
        let verb = kind == .copy ? "copy" : "move"
        let message = report.failures.count == 1
            ? "Couldn’t \(verb) “\(report.failures[0].path.lastComponent)”"
            : "Couldn’t \(verb) \(report.failures.count) items"
        presentOperationFailure(message: message, detail: describe(report.failures[0].error))
    }
}
