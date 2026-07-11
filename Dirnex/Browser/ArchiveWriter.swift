import DirnexCore
import Foundation

/// Rewrites an archive to delete members from it, by spawning `bsdtar` — the non-hermetic I/O half
/// of TC's delete-inside-an-archive (F8, PLAN.md §M4 "Archive writes: add/delete inside zip —
/// rewrite strategy, journal-safe temp file"), mirroring `ArchiveExtractor`/`ArchivePacker`. The
/// pure argv comes from `DirnexCore.ArchiveMutation`; this runs the processes off-main and performs
/// the atomic swap.
///
/// The rewrite is: extract the whole archive into a scratch directory, remove the target members
/// there by their real filesystem paths (exact — see `ArchiveMutation` for why an in-place
/// `bsdtar --exclude` can't do this safely), repack the surviving tree into a hidden sibling of the
/// original, then atomically replace the original with it (`FileManager.replaceItemAt`, a
/// same-volume swap). The original is never touched until the repack has fully succeeded, so a
/// failure or crash mid-rewrite leaves it intact — the "journal-safe temp file" the plan calls for.
enum ArchiveWriter {
    /// The shared scratch root every rewrite extracts beneath, under the user's temp directory.
    /// Purged at launch like the extractor's, since a rewrite fully finishes (or fails) before
    /// returning — nothing lingers that a later session needs.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexArchiveWrite", isDirectory: true)
    }

    /// Delete `innerPaths` (VFS inner paths like `/docs/api/x.md`, a directory removing its whole
    /// subtree) from the archive at `archiveOnDiskPath`, rewriting it in place. Throws — leaving the
    /// original untouched — when the archive can't be read, the repack fails, or the swap fails.
    /// Blocks on `bsdtar`, so call it off-main.
    static func delete(innerPaths: [String], fromArchiveAt archiveOnDiskPath: String) throws {
        let archiveURL = URL(fileURLWithPath: archiveOnDiskPath)
        let name = archiveURL.lastPathComponent

        let workingDirectory = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        try run(
            ArchiveMutation.extractAllArguments(
                archiveOnDiskPath: archiveOnDiskPath,
                into: workingDirectory.path
            ),
            failure: "Couldn’t read the archive “\(name)”."
        )

        // Remove each target by its exact extracted path. A member that isn't there (already gone,
        // or a stale selection) is not a failure — the rewrite still drops it from the result.
        for innerPath in innerPaths {
            let location = ArchiveMutation.workingLocation(
                ofInnerPath: innerPath,
                inWorkingDirectory: workingDirectory.path
            )
            try? FileManager.default.removeItem(atPath: location)
        }

        // Repack into a hidden sibling in the archive's own directory (same volume → the swap below
        // is atomic), then replace the original. Clean up the sibling on any failure so a broken
        // rewrite never litters the folder.
        let rewrittenURL = archiveURL.deletingLastPathComponent().appendingPathComponent(
            ArchiveMutation.temporaryArchiveName(forArchiveNamed: name, token: UUID().uuidString)
        )
        do {
            try run(
                ArchiveMutation.repackAllArguments(
                    newArchiveOnDiskPath: rewrittenURL.path,
                    from: workingDirectory.path
                ),
                failure: "Couldn’t rewrite the archive “\(name)”."
            )
            guard FileManager.default.fileExists(atPath: rewrittenURL.path) else {
                throw VFSError.unsupported("Couldn’t rewrite the archive “\(name)”.")
            }
            _ = try FileManager.default.replaceItemAt(archiveURL, withItemAt: rewrittenURL)
        } catch {
            try? FileManager.default.removeItem(at: rewrittenURL)
            throw error is VFSError ? error : VFSError.unsupported(
                "Couldn’t update the archive “\(name)”."
            )
        }
    }

    /// Remove every rewrite scratch directory. Called once at launch, before anything can be
    /// rewriting, so it can clear the whole root without racing an in-flight operation.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: - Process

    /// Run one `bsdtar` invocation to completion, throwing `failure` on a spawn error or non-zero
    /// exit. Both streams are discarded — nothing here reads them, and doing so avoids a full-pipe
    /// stall and keeps libarchive warnings off the console (a real problem shows as a non-zero exit).
    private static func run(_ arguments: [String], failure message: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(message)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VFSError.unsupported(message) }
    }
}
