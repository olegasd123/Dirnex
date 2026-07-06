import Foundation

// Total Commander's universal undo (PLAN.md §M2 "Undo journal: Cmd+Z reverses
// move/rename/copy/new-folder; delete-to-Trash restore; journal survives relaunch").
//
// The journal is a bounded stack of `UndoRecord`s, newest on top; Cmd+Z pops the top and
// applies its inverse. It lives in `DirnexCore` because reversing an operation *touches
// bytes* ("if it touches bytes, it lives in DirnexCore and has tests" — §2), so the
// reversal executor and the record-building logic — the parts that can corrupt data if
// they get the inverse wrong — are here under property tests, and the app is a thin shell
// that records completed operations and drives `revert` off the main thread.
//
// A record never carries the *reason* an operation happened, only enough to undo it: the
// filesystem primitives that put things back. Anything that can't be cleanly reversed (a
// copy/move that overwrote an existing file — the replaced original is already gone) is
// counted in `nonReversibleCount` and surfaced to the user, never silently dropped.

// MARK: - Reversal primitives

/// One filesystem primitive that undoes part of an operation. Each variant is the inverse
/// of a thing an operation did; a record is a list of them, applied in order.
public enum UndoStep: Sendable, Equatable, Codable {
    /// Undo a move / rename / trash: put the item back by moving `from` (its current
    /// location) to `to` (where it lived before). Refuses to clobber a reoccupied `to`.
    case restore(from: VFSPath, to: VFSPath)
    /// Undo a copy: remove the copy that was created at `path`. A no-op if it's already
    /// gone. Removes a copied subtree wholesale, matching Finder's "Undo Copy".
    case removeCopy(VFSPath)
    /// Undo a New Folder: remove the folder at `path`, but *only while it is still empty* —
    /// never destroy files the user has since put inside it.
    case removeCreatedFolder(VFSPath)
}

// MARK: - Journal record

/// One reversible action on the undo stack: a user-facing label, the steps that invert it,
/// and how many parts of the original operation can't be reversed at all.
public struct UndoRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// The operation's name, shown in the menu as "Undo \(label)" ("Move", "Copy",
    /// "Rename", "New Folder", "Move to Trash").
    public let label: String
    public let date: Date
    /// The inverse operations, applied in order by `UndoJournal.revert`.
    public let steps: [UndoStep]
    /// Items in the original operation that overwrote an existing file and so can't be
    /// undone (the replaced original is gone). Surfaced when the record is reverted.
    public let nonReversibleCount: Int

    public init(
        id: UUID = UUID(),
        label: String,
        date: Date = Date(),
        steps: [UndoStep],
        nonReversibleCount: Int = 0
    ) {
        self.id = id
        self.label = label
        self.date = date
        self.steps = steps
        self.nonReversibleCount = nonReversibleCount
    }
}

// MARK: - Record builders

public extension UndoRecord {
    /// Build the undo record for a completed copy/move from the engine's per-item outcomes
    /// (`OperationReport.outcomes`). Returns `nil` when nothing is reversible — every item
    /// was skipped by the conflict policy, or every landing overwrote an existing file — so
    /// an un-undoable operation simply never enters the journal.
    ///
    /// - A **copy** is undone by removing each fresh copy (`removeCopy`).
    /// - A **move** is undone by moving each item back to its source (`restore`).
    /// - An item that **overwrote** an existing file is counted in `nonReversibleCount`, not
    ///   reversed: deleting the replacement wouldn't bring back the original it clobbered.
    static func transfer(
        kind: FileOperation.Kind,
        outcomes: [OperationItemOutcome],
        date: Date = Date()
    ) -> UndoRecord? {
        var steps: [UndoStep] = []
        var nonReversible = 0
        for outcome in outcomes {
            guard let landed = outcome.landedAt else { continue } // skipped: nothing happened
            if outcome.replacedExisting {
                nonReversible += 1
                continue
            }
            switch kind {
            case .copy: steps.append(.removeCopy(landed))
            case .move: steps.append(.restore(from: landed, to: outcome.source))
            }
        }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(
            label: kind == .copy ? "Copy" : "Move",
            date: date,
            steps: steps,
            nonReversibleCount: nonReversible
        )
    }

    /// Undo a New Folder by removing the folder — while it's still empty (`removeCreatedFolder`).
    static func newFolder(at path: VFSPath, date: Date = Date()) -> UndoRecord {
        UndoRecord(label: "New Folder", date: date, steps: [.removeCreatedFolder(path)])
    }

    /// Undo an inline rename by moving the new name back to the old one.
    static func rename(from old: VFSPath, to new: VFSPath, date: Date = Date()) -> UndoRecord {
        UndoRecord(label: "Rename", date: date, steps: [.restore(from: new, to: old)])
    }

    /// Undo a Move-to-Trash by restoring each item from the Trash location it landed at back
    /// to where it came from. Returns `nil` if nothing was actually trashed (e.g. the backend
    /// reported no Trash location for any item).
    static func trash(
        _ items: [(original: VFSPath, trashed: VFSPath)],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps = items.map { UndoStep.restore(from: $0.trashed, to: $0.original) }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: "Move to Trash", date: date, steps: steps)
    }
}

// MARK: - Reversal report

/// What happened when a record was reverted: the steps that couldn't be applied (an item
/// vanished, its old location is reoccupied, a permission error). An empty list means the
/// undo fully succeeded.
public struct UndoReport: Sendable, Equatable {
    public let failures: [OperationItemFailure]

    public init(failures: [OperationItemFailure]) {
        self.failures = failures
    }

    public var succeeded: Bool { failures.isEmpty }
}

// MARK: - The journal

/// A bounded, newest-on-top stack of `UndoRecord`s. Value type — the app owns one per
/// window, records completed operations into it, and persists `records` across launches.
public struct UndoJournal: Sendable, Equatable {
    /// The most that is kept; older records fall off the bottom. A stack, not a full
    /// history — undo walks back from the most recent action.
    public let capacity: Int
    public private(set) var records: [UndoRecord]

    public init(records: [UndoRecord] = [], capacity: Int = 50) {
        self.capacity = max(1, capacity)
        self.records = Array(records.suffix(self.capacity))
    }

    /// The action Cmd+Z would reverse next, or `nil` when there's nothing to undo.
    public var top: UndoRecord? { records.last }

    public var canUndo: Bool { !records.isEmpty }

    /// Push a freshly-completed operation onto the stack, trimming the oldest past capacity.
    public mutating func record(_ record: UndoRecord) {
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    /// Pop the top action so it can be reverted. Returns `nil` on an empty stack.
    @discardableResult
    public mutating func removeTop() -> UndoRecord? {
        records.popLast()
    }

    public mutating func clear() {
        records.removeAll()
    }

    // MARK: - Reversal executor

    /// Apply a record's inverse steps against `backend`, collecting per-step failures rather
    /// than aborting on the first — so undoing a five-item move that hits one reoccupied slot
    /// still restores the other four. Pure with respect to the journal; the caller pops the
    /// record and runs this off the main thread.
    public static func revert(_ record: UndoRecord, using backend: any VFSBackend) -> UndoReport {
        var failures: [OperationItemFailure] = []
        for step in record.steps {
            switch step {
            case let .restore(from, to):
                restore(from: from, to: to, using: backend, failures: &failures)
            case let .removeCopy(path):
                removeCopy(at: path, using: backend, failures: &failures)
            case let .removeCreatedFolder(path):
                removeCreatedFolder(at: path, using: backend, failures: &failures)
            }
        }
        return UndoReport(failures: failures)
    }

    /// Move `from` back to `to`. Refuses to overwrite a reoccupied `to` (undo must never
    /// destroy data the user created since), and — because a cross-volume move was undone by
    /// copy-then-delete originally — falls back to the copy engine when a plain rename can't
    /// cross the volume boundary.
    private static func restore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if (try? backend.stat(at: to)) != nil {
            failures.append(.init(path: to, error: .alreadyExists(to)))
            return
        }
        do {
            try backend.moveItem(at: from, to: to)
        } catch let VFSError.io(_, code) where code == EXDEV {
            crossVolumeRestore(from: from, to: to, using: backend, failures: &failures)
        } catch let error as VFSError {
            failures.append(.init(path: from, error: error))
        } catch {
            failures.append(.init(path: from, error: .io(path: from, code: 0)))
        }
    }

    /// The cross-volume fallback for `restore`: reverse a copy-then-delete move by moving the
    /// item back through the copy engine. Only reachable for a move (name preserved, so it
    /// lands back at exactly `to`); a rename never crosses volumes, so it never gets here.
    private static func crossVolumeRestore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard from.lastComponent == to.lastComponent, let parent = to.parent,
              let entry = try? backend.stat(at: from) else {
            failures.append(.init(path: from, error: .io(path: from, code: EXDEV)))
            return
        }
        let report = CopyEngine.run(
            FileOperation(kind: .move, sources: [entry], destinationDirectory: parent),
            using: backend,
            conflictPolicy: .fail
        )
        failures.append(contentsOf: report.failures)
    }

    /// Remove a copy the operation created. Already gone → nothing to do (treat as undone).
    private static func removeCopy(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard (try? backend.stat(at: path)) != nil else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Remove a folder New Folder created — but only if it's still an empty directory.
    /// A folder the user has since filled, or one already replaced by something else, is
    /// left untouched: undo protects existing data over completing the reversal.
    private static func removeCreatedFolder(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard let entry = try? backend.stat(at: path), entry.kind == .directory else { return }
        guard let children = try? backend.listDirectory(at: path), children.isEmpty else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }
}
