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

    /// Cmd+Z — reverse the last operation on the window's undo journal (PLAN.md §M2). The
    /// pane forwards to the window, which owns the (window-global) journal. Validation below
    /// steps aside for an active inline-rename/path-bar field editor so text undo still works.
    @objc func undoLastOperation(_ sender: Any?) {
        host?.undoLastOperation()
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
        guard !isVirtualDirectory else { return } // no real directory to create into here
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
                host?.recordUndoableAction(.newFolder(at: target))
            } catch {
                presentOperationFailure(
                    message: "Can’t create “\(name)”",
                    detail: describe(error)
                )
            }
        }
    }

    // MARK: - Delete (F8 Trash / Shift+F8 permanent)

    /// The entries an operation (delete, copy, move) targets: the marked set when
    /// anything is marked (Total Commander operates on marks over the cursor), otherwise
    /// the single cursor entry. The synthetic `..` row is never a target.
    func selectionTargets() -> [FileEntry] {
        if panel.selectionCount > 0 {
            return panel.selectedEntries
        }
        if !cursorOnParentRow, let entry = panel.currentEntry {
            return [entry]
        }
        return []
    }

    private func deleteSelection(permanent: Bool) {
        guard !isVirtualDirectory else { return } // a virtual listing is a read-only view
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }
        if permanent {
            confirmPermanentDelete(of: targets) { [weak self] in
                self?.runDelete(targets, permanent: true)
            }
        } else if AppPreferences.shared.confirmTrash {
            confirmTrash(of: targets) { [weak self] in
                self?.runDelete(targets, permanent: false)
            }
        } else {
            runDelete(targets, permanent: false)
        }
    }

    /// Move-to-Trash normally skips confirmation (it's recoverable, matching Finder), but the
    /// user can opt into a prompt via Operations settings ("Ask before moving items to Trash").
    private func confirmTrash(of targets: [FileEntry], proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "Move “\(targets[0].name)” to the Trash?"
            : "Move \(targets.count) items to the Trash?"
        alert.informativeText = "You can restore items from the Trash later."
        alert.addButton(withTitle: "Move to Trash")
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
            let result = await Task.detached(priority: .userInitiated) { () -> DeleteResult in
                var failures: [OperationFailure] = []
                var restorations: [TrashRestoration] = []
                for path in paths {
                    do {
                        if permanent {
                            try backend.removeItem(at: path)
                        } else if let trashed = try backend.trashItem(at: path) {
                            // Capture where it landed so Cmd+Z can restore it from the Trash.
                            restorations.append(TrashRestoration(original: path, trashed: trashed))
                        }
                    } catch let error as VFSError {
                        failures.append(OperationFailure(path: path, error: error))
                    } catch {
                        failures.append(
                            OperationFailure(path: path, error: .io(path: path, code: 0))
                        )
                    }
                }
                return DeleteResult(failures: failures, restorations: restorations)
            }.value

            panel.clearSelection()
            refreshCurrentDirectory()
            focusTable()
            // Permanent delete is irreversible and never journaled; Trash is restorable.
            if !permanent,
               let record = UndoRecord.trash(result.restorations.map { ($0.original, $0.trashed) }) {
                host?.recordUndoableAction(record)
            }
            if !result.failures.isEmpty {
                presentDeletionFailures(result.failures, permanent: permanent)
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
    /// Internal so `PanelViewController+Copy` can refresh both panes after a transfer.
    func refreshCurrentDirectory(selecting target: VFSPath? = nil) {
        // A virtual results pane has no directory to re-list — skip so a both-panes refresh
        // after a file operation leaves the search results snapshot untouched.
        guard panel.path.backend == .local else { return }
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

    func presentOperationFailure(message: String, detail: String) {
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
        // Boolean view toggles (checkmark items) and the directory-mutating ops are validated in
        // their own helpers so this switch stays under the cyclomatic-complexity limit.
        if let toggle = validateToggleItem(menuItem) { return toggle }
        if let mutating = validateMutatingItem(menuItem) { return mutating }
        switch menuItem.action {
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            // Copy/Move to the other pane is the point of a results panel (TC's F5 on results):
            // each target carries its real on-disk path, so it works from there. An archive's
            // entries have no local path yet — extracting them (F5 copy-out) is a later M4 pass.
            return !isArchive && !selectionTargets().isEmpty && host?.panelCounterpart(of: self) != nil
        case #selector(copy(_:)):
            // `copy:` only reaches the pane when the file table is first responder — a name/
            // path field editor intercepts ⌘C for text copy — so this validates the file case.
            // An archive entry has no on-disk URL to place on the pasteboard yet.
            return !isArchive && !selectionTargets().isEmpty
        case #selector(undoLastOperation(_:)):
            return validateUndoItem(menuItem)
        case #selector(goToParentDirectory(_:)):
            // "Go Up" walks out of an archive too, but is meaningless at a backend root or on a
            // virtual search-results pane.
            return isArchive || (panel.path.backend == .local && panel.parentPath != nil)
        case #selector(goBack(_:)):
            return tabs[activeTabIndex].history.canGoBack
        case #selector(goForward(_:)):
            return tabs[activeTabIndex].history.canGoForward
        case #selector(showHistory(_:)):
            // Like ⌃D, let ⌥↓ reach a field editor while a name/path field is being edited
            // instead of stealing it to open the history popup.
            return !(view.window?.firstResponder is NSText)
        case #selector(showHotlist(_:)):
            // While a name/path field is being edited, let ⌃D fall through to the field
            // editor's delete-forward instead of stealing it to open the hotlist.
            return !(view.window?.firstResponder is NSText)
        default:
            return true
        }
    }

    /// Validate the directory-mutating operations — the ones that need a real, writable
    /// directory and so are all disabled on a virtual search-results pane (`isSearchResults`).
    /// Returns `nil` for any other selector so the main switch handles it. Split out to keep
    /// `validateMenuItem` under SwiftLint's cyclomatic-complexity limit (a recurring gotcha).
    private func validateMutatingItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(newFolder(_:)):
            return canWriteHere
        case #selector(moveSelectionToTrash(_:)), #selector(deleteSelectionPermanently(_:)):
            // A virtual listing is read-only; deleting from it would leave stale rows behind.
            return !isVirtualDirectory && !selectionTargets().isEmpty
        case #selector(paste(_:)):
            return canWriteHere && clipboardHasFiles()
        case #selector(pasteAndMoveFromClipboard(_:)):
            // ⌥⌘V has no standard selector, so it reaches the pane even mid text-edit — step it
            // aside for a field editor, else gate it like Paste.
            return canWriteHere && clipboardHasFiles() && !(view.window?.firstResponder is NSText)
        case #selector(renameSelection(_:)):
            // Rename is single-item on the cursor (not the marked set) and never `..`.
            return canRenameHere && !cursorOnParentRow && panel.currentEntry != nil
        case #selector(multiRenameSelection(_:)):
            // The batch tool operates on the marked set (else the cursor entry).
            return canRenameHere && !selectionTargets().isEmpty
        default:
            return nil
        }
    }

    /// This pane can create/paste into its directory — a real, writable location (never a
    /// virtual pane: search results or a read-only archive).
    private var canWriteHere: Bool {
        !isVirtualDirectory && backend.capabilities.contains(.write)
    }

    /// This pane can rename an item in place — a real, rename-capable location.
    private var canRenameHere: Bool {
        !isVirtualDirectory && backend.capabilities.contains(.rename)
    }

    /// Boolean view toggles that carry a checkmark tracking their state and are always
    /// enabled (the standard macOS convention). Returns `nil` for any other selector so the
    /// main enable/disable switch handles it.
    private func validateToggleItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleShowHidden(_:)):
            // "Show Hidden Files" checkmark tracks the app-wide state.
            menuItem.state = AppPreferences.shared.showHidden ? .on : .off
            return true
        case #selector(toggleQuickViewPanel(_:)):
            // "Quick View Panel" checkmark tracks the window-wide Quick View state.
            menuItem.state = (host?.isQuickViewEnabled ?? false) ? .on : .off
            return true
        default:
            return nil
        }
    }

    /// Enable Cmd+Z only when the journal has something to reverse *and* no text field is
    /// being edited — while an inline rename / path-bar field editor is first responder, a
    /// disabled item lets `performKeyEquivalent` fall through so Cmd+Z undoes typing instead.
    /// The title tracks the next action ("Undo Move"), collapsing to plain "Undo" when idle.
    private func validateUndoItem(_ menuItem: NSMenuItem) -> Bool {
        if view.window?.firstResponder is NSText {
            menuItem.title = "Undo"
            return false
        }
        guard let label = host?.nextUndoLabel else {
            menuItem.title = "Undo"
            return false
        }
        menuItem.title = "Undo \(label)"
        return true
    }
}

/// A single item's failure during a batch operation, in a `Sendable` shape so it can
/// cross back from the background delete task. Per-file retry/abort is a later M2 item;
/// for now failures are collected and summarized.
private struct OperationFailure: Sendable {
    let path: VFSPath
    let error: VFSError
}

/// One trashed item's before/after locations, captured so Cmd+Z can restore it from the
/// Trash (PLAN.md §M2 "delete-to-Trash restore").
private struct TrashRestoration: Sendable {
    let original: VFSPath
    let trashed: VFSPath
}

/// What a delete pass produced: the items it couldn't remove, and (for Trash) where the
/// removed items landed so the operation can be journaled for undo.
private struct DeleteResult: Sendable {
    let failures: [OperationFailure]
    let restorations: [TrashRestoration]
}
