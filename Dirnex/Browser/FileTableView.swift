import AppKit

/// Keyboard commands a file pane's table forwards to its controller. Kept as an
/// explicit protocol (rather than target/action) so the Total Commander key model —
/// where Space marks and the cursor is separate from selection — stays readable and
/// testable, and so it can be regenerated from the action registry in M3.
@MainActor
protocol FileTableViewInput: AnyObject {
    /// Return / Enter / Cmd+Down — open the directory under the cursor or launch the file.
    func fileTableOpenSelection(_ tableView: FileTableView)
    /// Backspace / Cmd+Up — navigate to the parent directory.
    func fileTableGoToParent(_ tableView: FileTableView)
    /// Space / Insert — toggle the cursor row's mark and advance (TC's mark-a-run gesture).
    func fileTableToggleMarkAndAdvance(_ tableView: FileTableView)
    /// Tab — hand keyboard focus to the other pane.
    func fileTableSwitchPanel(_ tableView: FileTableView)
    /// Cmd+A — mark every visible entry.
    func fileTableMarkAll(_ tableView: FileTableView)
    /// `*` — invert the mark set.
    func fileTableInvertMarks(_ tableView: FileTableView)
    /// The table became first responder — its pane should become the active one.
    func fileTableDidBecomeFirstResponder(_ tableView: FileTableView)
}

/// `NSTableView` subclass that intercepts the file-manager key model before the
/// default table behavior. Arrow keys, page keys and mouse selection fall through to
/// `super`, which moves the cursor (the table's own selection); everything else is
/// routed to the controller via `FileTableViewInput`.
final class FileTableView: NSTableView {
    weak var inputDelegate: FileTableViewInput?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            inputDelegate?.fileTableDidBecomeFirstResponder(self)
        }
        return didBecome
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command, handleCommandKey(event.keyCode) { return }
        if flags.isEmpty || flags == .numericPad, handlePlainKey(event) { return }

        // Cmd+A arrives as a key event here (no menu binding yet in M1).
        if flags == .command, event.charactersIgnoringModifiers == "a" {
            inputDelegate?.fileTableMarkAll(self)
            return
        }

        super.keyDown(with: event)
    }

    /// Cmd + arrow: enter directory / go up, mirroring Finder's Cmd+Down / Cmd+Up.
    private func handleCommandKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125: // Down
            inputDelegate?.fileTableOpenSelection(self)
            return true
        case 126: // Up
            inputDelegate?.fileTableGoToParent(self)
            return true
        default:
            return false
        }
    }

    private func handlePlainKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 48: // Tab
            inputDelegate?.fileTableSwitchPanel(self)
            return true
        case 36, 76: // Return, keypad Enter
            inputDelegate?.fileTableOpenSelection(self)
            return true
        case 51, 117: // Delete (Backspace), forward Delete
            inputDelegate?.fileTableGoToParent(self)
            return true
        case 115: // Home
            moveCursor(to: 0)
            return true
        case 119: // End
            moveCursor(to: numberOfRows - 1)
            return true
        case 116: // Page Up
            moveCursor(by: -visibleRowCount())
            return true
        case 121: // Page Down
            moveCursor(by: visibleRowCount())
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case " ":
            inputDelegate?.fileTableToggleMarkAndAdvance(self)
            return true
        case "*":
            inputDelegate?.fileTableInvertMarks(self)
            return true
        default:
            return false
        }
    }

    // MARK: - Cursor movement

    private func moveCursor(by delta: Int) {
        moveCursor(to: selectedRow + delta)
    }

    private func moveCursor(to row: Int) {
        guard numberOfRows > 0 else { return }
        let clamped = min(max(row, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        scrollRowToVisible(clamped)
    }

    private func visibleRowCount() -> Int {
        let rows = rows(in: visibleRect)
        return max(rows.length - 1, 1)
    }
}
