import Foundation

/// A single queued file operation: move a set of source entries into a destination
/// directory, by copy or move (PLAN.md §2 "Operations"). The "instant" operations
/// (new folder, delete) don't need this shape — they finish immediately and live in
/// the `VFSBackend` write primitives; this models the byte-moving work that the
/// `CopyEngine` runs with progress, cancellation, and conflict handling.
public struct FileOperation: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Duplicate the sources into the destination, leaving the originals in place.
        case copy
        /// Relocate the sources into the destination — a same-volume rename where
        /// possible, else a copy-then-delete across volumes.
        case move
    }

    public let kind: Kind
    public let sources: [FileEntry]
    public let destinationDirectory: VFSPath

    public init(kind: Kind, sources: [FileEntry], destinationDirectory: VFSPath) {
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destinationDirectory
    }
}

/// What to do when a source's destination is already occupied. Resolved up front for
/// the whole operation in this first cut; the interactive per-file dialog (side-by-side
/// sizes/dates, thumbnails, "apply to all") arrives with the M2 conflict-engine pass.
public enum ConflictPolicy: Sendable, Equatable {
    /// Treat any existing destination as a per-item failure — the safe default, so a
    /// caller that forgets to resolve conflicts never silently clobbers data.
    case fail
    /// Leave the existing item untouched and skip the colliding source.
    case skip
    /// Replace the existing item. The new copy is written to a temporary sibling first
    /// and swapped into place, so the original survives until the replacement is
    /// complete (a half-finished copy never destroys the file it was replacing).
    case overwrite
    /// Replace the existing item only when the source is strictly newer than it (by
    /// modification date); an equal-or-older source is skipped, like the existing one is
    /// kept. This is TC's "overwrite older" — the safe way to fold newer edits into a
    /// destination without touching files that are already up to date. The comparison is
    /// on the top-level item's own modification date, so a directory is replaced wholesale
    /// when *its* mtime is newer (a per-file merge is a later pass — see PLAN.md §M2).
    case newerOnly
    /// Copy the source under a fresh, non-colliding name ("file copy.txt", "file copy 2.txt").
    case keepBoth
}

/// A live snapshot of an operation's progress, delivered to the caller's progress UI.
/// `totalBytes` is measured up front (a directory pre-scan) so the bar is determinate
/// and an ETA is possible; it is `0` only when the source set is genuinely empty.
public struct OperationProgress: Sendable, Equatable {
    public let totalBytes: Int64
    public let completedBytes: Int64
    public let totalItems: Int
    public let completedItems: Int
    /// The top-level source currently being transferred, for the "Copying X…" label.
    public let currentItem: VFSPath?

    public init(
        totalBytes: Int64,
        completedBytes: Int64,
        totalItems: Int,
        completedItems: Int,
        currentItem: VFSPath?
    ) {
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.currentItem = currentItem
    }

    /// Fraction complete in `0...1`, or `0` before any bytes are known.
    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

/// One source's failure during an operation, in a `Sendable` shape so it can cross back
/// from the background task. Per-file retry/abort is a later M2 item; for now failures
/// are collected and summarized at the end (never a modal storm — PLAN.md §M2).
public struct OperationItemFailure: Sendable, Equatable {
    public let path: VFSPath
    public let error: VFSError

    public init(path: VFSPath, error: VFSError) {
        self.path = path
        self.error = error
    }
}

/// The outcome of running an operation: what got through, what was skipped by the
/// conflict policy, what failed, and whether the user cancelled partway.
public struct OperationReport: Sendable, Equatable {
    public let completedItems: Int
    public let completedBytes: Int64
    public let skipped: [VFSPath]
    public let failures: [OperationItemFailure]
    public let wasCancelled: Bool

    public init(
        completedItems: Int,
        completedBytes: Int64,
        skipped: [VFSPath],
        failures: [OperationItemFailure],
        wasCancelled: Bool
    ) {
        self.completedItems = completedItems
        self.completedBytes = completedBytes
        self.skipped = skipped
        self.failures = failures
        self.wasCancelled = wasCancelled
    }

    public var succeeded: Bool { failures.isEmpty && !wasCancelled }
}
