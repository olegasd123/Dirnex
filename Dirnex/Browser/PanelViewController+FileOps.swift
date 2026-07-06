import AppKit
import DirnexCore

/// The "instant" file operations — the ones that finish immediately and so don't need
/// the M2 progress queue: New Folder (F7) and Delete (F8 to Trash / Shift+F8 permanent).
/// Copy (F5) and Move (F6), which move bytes with progress, go through the operation
/// engine in a later pass.
///
/// Only the AppKit shell lives here (prompts, confirmation, error summaries, and the
/// post-op refresh); the byte-touching work is `DirnexCore`'s `VFSBackend` write
/// primitives, called off the main thread so a big recursive delete never blocks the UI.
extension PanelViewController {
    // MARK: - Menu / key actions (dispatched to the focused pane via the responder chain)

    @objc func newFolder(_ sender: Any?) {
        promptForNewFolder()
    }

    @objc func moveSelectionToTrash(_ sender: Any?) {
        deleteSelection(permanent: false)
    }

    @objc func deleteSelectionPermanently(_ sender: Any?) {
        deleteSelection(permanent: true)
    }

    // MARK: - FileTableViewInput (keyboard)

    func fileTableNewFolder(_ tableView: FileTableView) {
        promptForNewFolder()
    }

    func fileTableDeleteToTrash(_ tableView: FileTableView) {
        deleteSelection(permanent: false)
    }

    func fileTableDeletePermanently(_ tableView: FileTableView) {
        deleteSelection(permanent: true)
    }

    // MARK: - New Folder (F7)

    private func promptForNewFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a folder in “\(panel.path.lastComponent)”."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "untitled folder"
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.createFolder(named: name)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    private func createFolder(named name: String) {
        guard !name.isEmpty else { return } // an empty name is a silent cancel
        guard !name.contains("/") else {
            presentOperationFailure(
                message: "Can’t create the folder",
                detail: "Folder names can’t contain the “/” character."
            )
            return
        }

        let target = panel.path.appending(name)
        let backend = backend
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try backend.createDirectory(at: target)
                }.value
                refreshCurrentDirectory(selecting: target)
                focusTable()
            } catch {
                presentOperationFailure(
                    message: "Can’t create “\(name)”",
                    detail: describe(error)
                )
            }
        }
    }

    // MARK: - Delete (F8 Trash / Shift+F8 permanent)

    /// The entries a delete targets: the marked set when anything is marked (Total
    /// Commander operates on marks over the cursor), otherwise the single cursor entry.
    /// The synthetic `..` row is never a target.
    func deletionTargets() -> [FileEntry] {
        if panel.selectionCount > 0 {
            return panel.selectedEntries
        }
        if !cursorOnParentRow, let entry = panel.currentEntry {
            return [entry]
        }
        return []
    }

    private func deleteSelection(permanent: Bool) {
        let targets = deletionTargets()
        guard !targets.isEmpty else { return }
        if permanent {
            confirmPermanentDelete(of: targets) { [weak self] in
                self?.runDelete(targets, permanent: true)
            }
        } else {
            runDelete(targets, permanent: false)
        }
    }

    /// Permanent delete is irreversible, so it always asks first (PLAN.md §M2
    /// "Shift+F8 permanent with explicit confirm"). Trash needs no prompt — it's
    /// recoverable, matching Finder.
    private func confirmPermanentDelete(of targets: [FileEntry], proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? "Delete “\(targets[0].name)” permanently?"
            : "Delete \(targets.count) items permanently?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func runDelete(_ targets: [FileEntry], permanent: Bool) {
        let paths = targets.map(\.path)
        let backend = backend
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [OperationFailure] in
                var failures: [OperationFailure] = []
                for path in paths {
                    do {
                        if permanent {
                            try backend.removeItem(at: path)
                        } else {
                            try backend.trashItem(at: path)
                        }
                    } catch let error as VFSError {
                        failures.append(OperationFailure(path: path, error: error))
                    } catch {
                        failures.append(
                            OperationFailure(path: path, error: .io(path: path, code: 0))
                        )
                    }
                }
                return failures
            }.value

            panel.clearSelection()
            refreshCurrentDirectory()
            focusTable()
            if !failures.isEmpty {
                presentDeletionFailures(failures, permanent: permanent)
            }
        }
    }

    private func presentDeletionFailures(_ failures: [OperationFailure], permanent: Bool) {
        let verb = permanent ? "delete" : "move to Trash"
        let message = failures.count == 1
            ? "Couldn’t \(verb) “\(failures[0].path.lastComponent)”"
            : "Couldn’t \(verb) \(failures.count) items"
        presentOperationFailure(message: message, detail: describe(failures[0].error))
    }

    // MARK: - Shared

    /// Re-list the current directory after a mutation and, when `selecting` names a fresh
    /// entry (a just-created folder), land the cursor on it. `Panel.setListing` re-anchors
    /// the cursor/marks by identity, so this survives the new entry appearing mid-list.
    private func refreshCurrentDirectory(selecting target: VFSPath? = nil) {
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let tabIndex = activeTabIndex
        Task {
            guard let listing = try? await DirectoryLoader.list(backend, at: path) else { return }
            guard token == loadToken, panel.path == path, activeTabIndex == tabIndex else { return }
            reconcileCursorFromTable()
            panel.setListing(listing)
            if let target, let index = panel.model.index(ofID: target) {
                panel.moveCursor(to: index)
                cursorOnParentRow = false
            }
            reloadEverything()
        }
    }

    private func presentOperationFailure(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Menu validation

extension PanelViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveSelectionToTrash(_:)), #selector(deleteSelectionPermanently(_:)):
            return !deletionTargets().isEmpty
        default:
            return true
        }
    }
}

/// A single item's failure during a batch operation, in a `Sendable` shape so it can
/// cross back from the background delete task. Per-file retry/abort is a later M2 item;
/// for now failures are collected and summarized.
private struct OperationFailure: Sendable {
    let path: VFSPath
    let error: VFSError
}
