import DirnexCore
import Foundation

/// The window's undo owner: it holds the `DirnexCore.UndoJournal`, persists it across
/// launches, and runs the reversal off the main thread (PLAN.md §M2 "Undo journal … journal
/// survives relaunch"). All the byte-touching reversal logic lives in the tested core
/// `UndoJournal`; this is the thin AppKit shell that records completed operations and drives
/// Cmd+Z.
///
/// Deliberately boring JSON in `UserDefaults`, matching `TabPersistence` (PLAN.md §2
/// "JSON/plist for config"). The plan pencils in SQLite for the journal, which will earn its
/// keep once undo shares a database with the M3 frecency store; a bounded stack of recent
/// operations doesn't need it yet.
@MainActor
final class UndoController {
    private static let persistenceKey = "Dirnex.undoJournal"

    private var journal: UndoJournal
    private let backend: any VFSBackend

    init(backend: any VFSBackend) {
        self.backend = backend
        journal = Self.load()
    }

    /// Whether Cmd+Z has anything to reverse right now.
    var canUndo: Bool { journal.canUndo }

    /// The label of the action Cmd+Z would reverse next ("Move", "Copy", "Rename", …), for
    /// the menu title — or `nil` when there's nothing to undo.
    var nextLabel: String? { journal.top?.label }

    /// Push a freshly-completed, reversible operation onto the stack and persist it.
    func record(_ record: UndoRecord) {
        journal.record(record)
        persist()
    }

    /// Pop the top action and reverse it on a background thread. Returns the record and the
    /// reversal report so the caller can refresh the panes and message any items that
    /// couldn't be put back; `nil` when there was nothing to undo.
    func undo() async -> (record: UndoRecord, report: UndoReport)? {
        guard let record = journal.removeTop() else { return nil }
        persist()
        let backend = backend
        let report = await Task.detached(priority: .userInitiated) {
            UndoJournal.revert(record, using: backend)
        }.value
        return (record, report)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(journal.records) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    }

    private static func load() -> UndoJournal {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let records = try? JSONDecoder().decode([UndoRecord].self, from: data)
        else { return UndoJournal() }
        return UndoJournal(records: records)
    }
}
