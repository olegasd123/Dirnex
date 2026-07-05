import AppKit
import DirnexCore

/// Drag-out support (PLAN.md §M1 "Drag out to other apps"). A file pane is a drag
/// *source* only in M1 — files can be dragged to Finder or any app that accepts file
/// URLs, but dropping onto a pane (a real copy/move) lands in M2, so no drag types are
/// registered for receiving here.
///
/// These are additional `NSTableViewDataSource` methods; the conformance is declared in
/// `PanelViewController+Table`.
extension PanelViewController {
    /// Advertise the pane as a copy-only drag source. Only `.copy` is offered so a drag
    /// to Finder can never move or delete the original — real move/delete operations are
    /// M2. Local drags (pane-to-pane, i.e. drop-in) advertise nothing for the same reason.
    func configureDragging() {
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)
    }

    /// The pasteboard item for a dragged row: the entry's file URL, or `nil` for the
    /// synthetic `..` row (which has no backing entry and must not be draggable).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row) else { return nil }
        return panel.model[index].path.localURL as NSURL
    }

    /// When the grab starts on a marked file, drag the whole marked set (Total Commander
    /// semantics: operate on the selection); a grab on an unmarked file drags just that
    /// file. The table is single-selection, so AppKit only ever offers the one cursor row
    /// — we widen the pasteboard to every marked entry here.
    ///
    /// The drag image still shows just the grabbed row; a stacked multi-file image would
    /// require driving the whole session by hand, which isn't worth it for M1.
    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        guard panel.selectionCount > 1 else { return }
        let grabbedMarkedFile = rowIndexes.contains { row in
            guard let index = entryIndex(forRow: row) else { return false }
            return panel.isMarked(panel.model[index])
        }
        guard grabbedMarkedFile else { return }
        let urls = panel.selectedEntries.map { $0.path.localURL as NSURL }
        session.draggingPasteboard.clearContents()
        session.draggingPasteboard.writeObjects(urls)
    }
}
