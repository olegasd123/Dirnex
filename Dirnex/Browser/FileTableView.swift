import AppKit

/// Keyboard commands a file pane's table forwards to its controller. Kept as an
/// explicit protocol (rather than target/action) so the Total Commander key model —
/// where Space marks and the cursor is separate from selection — stays readable and
/// testable, and so it can be regenerated from the action registry in M3.
@MainActor
protocol FileTableViewInput: AnyObject {
    /// Return / Enter / Cmd+Down — open the directory under the cursor or launch the file.
    func fileTableOpenSelection(_ tableView: FileTableView)
    /// Cmd+Up — navigate to the parent directory (unconditional, ignores any filter).
    func fileTableGoToParent(_ tableView: FileTableView)
    /// Backspace — trim the active type-to-filter, or go to the parent when it is empty.
    func fileTableBackspace(_ tableView: FileTableView)
    /// Esc — clear the filter, then (if none) clear the marks.
    func fileTableCancel(_ tableView: FileTableView)
    /// A printable character was typed — append it to the type-to-filter.
    func fileTable(_ tableView: FileTableView, didType text: String)
    /// Space / Insert — toggle the cursor row's mark and advance (TC's mark-a-run gesture).
    func fileTableToggleMarkAndAdvance(_ tableView: FileTableView)
    /// Tab — hand keyboard focus to the other pane.
    func fileTableSwitchPanel(_ tableView: FileTableView)
    /// Cmd+A — mark every visible entry.
    func fileTableMarkAll(_ tableView: FileTableView)
    /// `*` — invert the mark set.
    func fileTableInvertMarks(_ tableView: FileTableView)
    /// Cmd+Y — toggle the Quick Look preview panel.
    func fileTableToggleQuickLook(_ tableView: FileTableView)
    /// The table became first responder — its pane should become the active one.
    func fileTableDidBecomeFirstResponder(_ tableView: FileTableView)
}

/// `NSTableView` subclass that intercepts the file-manager key model before the
/// default table behavior. Arrow keys and mouse selection fall through to `super`,
/// which moves the cursor (the table's own selection); everything else — navigation,
/// marking, and type-to-filter — is routed to the controller via `FileTableViewInput`.
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

    /// The Escape key reaches AppKit as the `cancelOperation:` action rather than a
    /// plain `keyDown:` we can switch on, so we take it here — this clears the active
    /// type-to-filter (then the marks).
    override func cancelOperation(_ sender: Any?) {
        inputDelegate?.fileTableCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command {
            if handleCommandArrow(event.keyCode) { return }
            switch event.charactersIgnoringModifiers {
            case "a": inputDelegate?.fileTableMarkAll(self); return
            case "y": inputDelegate?.fileTableToggleQuickLook(self); return
            default: break
            }
        }

        // Plain keys, plus Shift/keypad/function so uppercase typing and the arrow/
        // navigation cluster still route through here.
        let passthrough: NSEvent.ModifierFlags = [.shift, .numericPad, .function]
        if flags.subtracting(passthrough).isEmpty, handleTypingKey(event) { return }

        super.keyDown(with: event)
    }

    /// Cmd + arrow: enter directory / go up, mirroring Finder's Cmd+Down / Cmd+Up.
    private func handleCommandArrow(_ keyCode: UInt16) -> Bool {
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

    private func handleTypingKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 48: // Tab
            inputDelegate?.fileTableSwitchPanel(self)
            return true
        case 36, 76: // Return, keypad Enter
            inputDelegate?.fileTableOpenSelection(self)
            return true
        case 51: // Delete (Backspace)
            inputDelegate?.fileTableBackspace(self)
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
            break
        }

        return forwardTypedCharacter(event)
    }

    /// Route a single printable character into the type-to-filter, excluding control
    /// characters and the 0xF700–0xF8FF function-key range (arrows, F-keys) that AppKit
    /// reports as "characters" but which must reach `super` for cursor movement.
    private func forwardTypedCharacter(_ event: NSEvent) -> Bool {
        guard let chars = event.characters,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              scalar.value > 0x20,
              scalar.value != 0x7F,
              !(0xF700 ... 0xF8FF).contains(scalar.value) else {
            return false
        }
        inputDelegate?.fileTable(self, didType: chars)
        return true
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
