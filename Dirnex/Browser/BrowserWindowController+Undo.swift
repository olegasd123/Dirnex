import AppKit
import DirnexCore

/// The window's `PanelHost` undo surface (PLAN.md §M2 "Undo journal: Cmd+Z reverses
/// move/rename/copy/new-folder; delete-to-Trash restore; clear messaging for non-reversible
/// ops"). The panes forward their reversible operations here; Cmd+Z reverses the most recent.
/// The reversal itself lives in the tested `DirnexCore.UndoJournal`; this marshals it onto
/// the panes and surfaces anything that couldn't be put back.
extension BrowserWindowController {
    func recordUndoableAction(_ record: UndoRecord) {
        undoController.record(record)
    }

    var nextUndoLabel: String? {
        undoController.nextLabel
    }

    func undoLastOperation() {
        Task {
            guard let (record, report) = await undoController.undo() else { return }
            // Re-list both panes so the reversal (a restored source, a removed copy) shows at
            // once; the FSEvents watchers would catch up anyway, but this is immediate.
            leftPanel.refreshCurrentDirectory()
            rightPanel.refreshCurrentDirectory()
            presentUndoOutcome(record: record, report: report)
        }
    }

    /// Tell the user only when the undo was less than complete: a clean reversal is silent
    /// (the panes already reflect it). Non-reversible parts of the original operation and
    /// steps that couldn't be applied are both surfaced, never dropped silently.
    private func presentUndoOutcome(record: UndoRecord, report: UndoReport) {
        guard record.nonReversibleCount > 0 || !report.succeeded else { return }

        var lines: [String] = []
        if record.nonReversibleCount > 0 {
            let items = record.nonReversibleCount == 1 ? "1 item" : "\(record.nonReversibleCount) items"
            lines.append("\(items) overwrote existing files and can’t be restored.")
        }
        if !report.succeeded {
            let count = report.failures.count
            let items = count == 1 ? "1 item" : "\(count) items"
            lines.append(
                "\(items) couldn’t be put back: \(leftPanel.describe(report.failures[0].error))"
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Undo \(record.label) finished with issues"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
