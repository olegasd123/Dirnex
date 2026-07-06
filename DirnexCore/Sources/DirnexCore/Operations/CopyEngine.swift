import Foundation

/// Executes a `FileOperation` (copy or move) against a backend, reporting progress and
/// honouring cancellation — TC's queued, non-blocking file operations (PLAN.md §M2).
///
/// It lives in `DirnexCore` because it touches bytes ("if it touches bytes, it lives in
/// DirnexCore and has tests" — §2) and is a plain synchronous entry point: the caller
/// decides where it runs (the app hands it a detached background task and marshals the
/// progress callbacks to the main actor). Each source is transferred with the fastest
/// path the backend offers — an APFS clone of the whole subtree same-volume, a chunked
/// recursive copy across volumes — so a same-disk copy is instant and a cross-disk copy
/// still streams with progress.
public enum CopyEngine {
    /// Run `operation`, returning a report of what completed, was skipped, or failed.
    ///
    /// - `conflictPolicy` is applied to every top-level source whose destination already
    ///   exists; non-colliding sources ignore it.
    /// - `onProgress` is called periodically (throttled by byte volume and at each item
    ///   boundary) — never per chunk, so a 50 GB copy doesn't flood the caller.
    /// - `isCancelled` is polled between chunks and items; cancelling leaves a report with
    ///   `wasCancelled == true` and cleans up any half-written file (a partially copied
    ///   directory tree is left in place for the user to remove).
    public static func run(
        _ operation: FileOperation,
        using backend: any VFSBackend,
        conflictPolicy: ConflictPolicy = .fail,
        onProgress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> OperationReport {
        CopyRun(
            operation: operation,
            backend: backend,
            policy: conflictPolicy,
            onProgress: onProgress,
            isCancelled: isCancelled
        ).execute()
    }
}

/// One execution of a `FileOperation`. A short-lived class (never shared across tasks)
/// so the recursive copy and its helpers can share a running byte/item tally without
/// threading `inout` accumulators through every call.
private final class CopyRun {
    private let operation: FileOperation
    private let backend: any VFSBackend
    private let policy: ConflictPolicy
    private let onProgress: @Sendable (OperationProgress) -> Void
    private let isCancelled: @Sendable () -> Bool

    /// Emit a progress update at most this often by byte volume, so a large file reports
    /// smoothly without a main-actor hop per 1 MiB chunk.
    private static let emitThreshold: Int64 = 8 << 20

    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var completedItems = 0
    private var lastEmitted: Int64 = -1
    private var skipped: [VFSPath] = []
    private var failures: [OperationItemFailure] = []

    init(
        operation: FileOperation,
        backend: any VFSBackend,
        policy: ConflictPolicy,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.operation = operation
        self.backend = backend
        self.policy = policy
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    func execute() -> OperationReport {
        let sized = preScan()
        totalBytes = sized.reduce(0) { $0 + $1.bytes }
        emit(current: nil, force: true)

        for item in sized {
            if isCancelled() { return report(cancelled: true) }
            if !transfer(item.entry, bytes: item.bytes) {
                return report(cancelled: true) // cancelled mid-item
            }
        }
        return report(cancelled: false)
    }

    // MARK: - Pre-scan

    /// Measure each source's byte weight up front for the progress denominator, reusing
    /// the directory sizer for subtrees. A source we can't size counts as 0 rather than
    /// aborting the whole operation.
    private func preScan() -> [(entry: FileEntry, bytes: Int64)] {
        operation.sources.map { entry in
            let bytes: Int64
            if entry.kind == .directory {
                bytes = (
                    try? DirectorySizer.size(
                        of: entry.path,
                        using: backend,
                        isCancelled: isCancelled
                    )
                ) ?? 0
            } else {
                bytes = entry.byteSize
            }
            return (entry, bytes)
        }
    }

    // MARK: - Per-item transfer

    /// Transfer one top-level source, applying the conflict policy. Returns `false` only
    /// when the user cancelled; item-level failures are recorded and reported as `true`
    /// so the operation carries on to the remaining sources.
    private func transfer(_ entry: FileEntry, bytes: Int64) -> Bool {
        let destination = operation.destinationDirectory.appending(entry.name)
        emit(current: entry.path, force: true)
        do {
            switch try resolveConflict(for: entry, at: destination) {
            case .skip:
                skipped.append(entry.path)
                account(bytes: bytes)
            case let .proceed(target):
                try perform(entry, to: target, bytes: bytes)
                account(bytes: 0) // bytes were tallied inside `perform`
            case let .overwrite(temp, existing, final):
                try replace(entry, via: temp, removing: existing, landingAt: final, bytes: bytes)
            }
            return true
        } catch is CancellationError {
            return false
        } catch let error as VFSError {
            failures.append(OperationItemFailure(path: entry.path, error: error))
            return true
        } catch {
            failures.append(
                OperationItemFailure(path: entry.path, error: .io(path: entry.path, code: 0))
            )
            return true
        }
    }

    /// The overwrite path: copy the source to a temporary sibling, remove the existing
    /// item, then swap the temporary into place — and, for a move, delete the source
    /// afterwards. The original is never removed until its replacement is fully written.
    private func replace(
        _ entry: FileEntry,
        via temp: VFSPath,
        removing existing: VFSPath,
        landingAt final: VFSPath,
        bytes: Int64
    ) throws {
        try copyManual(entry, to: temp)
        try backend.removeItem(at: existing)
        try backend.moveItem(at: temp, to: final)
        if operation.kind == .move { try backend.removeItem(at: entry.path) }
        account(bytes: 0)
    }

    /// Copy or move `entry` onto a `target` that is guaranteed free. Move takes the
    /// same-volume rename fast path and falls back to copy-then-delete across volumes.
    private func perform(_ entry: FileEntry, to target: VFSPath, bytes: Int64) throws {
        if operation.kind == .move {
            do {
                try backend.moveItem(at: entry.path, to: target)
                completedBytes += bytes
                return
            } catch let VFSError.io(_, code) where code == EXDEV {
                // Cross-volume: fall through to copy the bytes, then remove the source.
            }
            try copyManual(entry, to: target)
            try backend.removeItem(at: entry.path)
            return
        }

        // Copy: try a copy-on-write clone of the whole item first (instant same-volume).
        if entry.kind != .symlink, try backend.cloneItem(at: entry.path, to: target) {
            completedBytes += bytes
            return
        }
        try copyManual(entry, to: target)
    }

    // MARK: - Manual recursive copy (the cross-volume / no-clone fallback)

    private func copyManual(_ entry: FileEntry, to target: VFSPath) throws {
        if isCancelled() { throw CancellationError() }
        switch entry.kind {
        case .symlink:
            // Duplicate the link itself, never its target — preserved even when dangling.
            try backend.createSymbolicLink(
                at: target,
                withDestination: entry.symlinkDestination ?? ""
            )
            completedBytes += entry.byteSize
        case .directory:
            try backend.createDirectory(at: target)
            let children = (try? backend.listDirectory(at: entry.path)) ?? []
            for child in children {
                try copyManual(child, to: target.appending(child.name))
            }
            try? backend.copyMetadata(at: entry.path, to: target)
        case .file, .other:
            try backend.copyFile(
                at: entry.path,
                to: target,
                progress: { [self] delta in
                    completedBytes += delta
                    emit(current: entry.path, force: false)
                },
                isCancelled: isCancelled
            )
        }
    }

    // MARK: - Conflict resolution

    private enum Plan {
        case proceed(VFSPath)
        case overwrite(temp: VFSPath, existing: VFSPath, final: VFSPath)
        case skip
    }

    private func resolveConflict(for entry: FileEntry, at destination: VFSPath) throws -> Plan {
        guard (try? backend.stat(at: destination)) != nil else { return .proceed(destination) }
        switch policy {
        case .fail:
            throw VFSError.alreadyExists(destination)
        case .skip:
            return .skip
        case .overwrite:
            let temp = operation.destinationDirectory
                .appending(".dirnex-copy-\(UUID().uuidString)-\(entry.name)")
            return .overwrite(temp: temp, existing: destination, final: destination)
        case .keepBoth:
            let name = firstAvailableName(basedOn: entry.name)
            return .proceed(operation.destinationDirectory.appending(name))
        }
    }

    /// Generate the first "<name> copy[.ext]" / "<name> copy N[.ext]" that doesn't yet
    /// exist in the destination — Finder's keep-both naming.
    private func firstAvailableName(basedOn name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var counter = 1
        while true {
            let candidate = counter == 1 ? "\(stem) copy\(suffix)" : "\(stem) copy \(counter)\(suffix)"
            let path = operation.destinationDirectory.appending(candidate)
            if (try? backend.stat(at: path)) == nil { return candidate }
            counter += 1
        }
    }

    // MARK: - Progress accounting

    private func account(bytes: Int64) {
        completedBytes += bytes
        completedItems += 1
        emit(current: nil, force: true)
    }

    private func emit(current: VFSPath?, force: Bool) {
        guard force || completedBytes - lastEmitted >= Self.emitThreshold else { return }
        lastEmitted = completedBytes
        onProgress(OperationProgress(
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            totalItems: operation.sources.count,
            completedItems: completedItems,
            currentItem: current
        ))
    }

    private func report(cancelled: Bool) -> OperationReport {
        OperationReport(
            completedItems: completedItems,
            completedBytes: completedBytes,
            skipped: skipped,
            failures: failures,
            wasCancelled: cancelled
        )
    }
}
