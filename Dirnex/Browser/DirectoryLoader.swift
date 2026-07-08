import DirnexCore
import Foundation

/// Bridges the synchronous, pure `VFSBackend` listing API into the async world of
/// the UI without ever blocking the main thread (PLAN.md §1 "listing must never
/// block the UI").
///
/// The backend's read methods are documented as safe off the main thread, so the
/// blocking `readdir` walk runs on a detached task; only the resulting `Sendable`
/// `DirectoryListing` crosses back to the caller's actor.
enum DirectoryLoader {
    static func list(_ backend: any VFSBackend, at path: VFSPath) async throws -> DirectoryListing {
        try await Task.detached(priority: .userInitiated) {
            let entries = try backend.listDirectory(at: path)
            return DirectoryListing(path: path, entries: entries)
        }.value
    }

    /// Stat a single path off the main thread — used to check whether a typed location is a
    /// real directory before deciding to fall back to a frecency fuzzy match. Returns `nil`
    /// on any failure (not found, permission, …), so the caller treats a missing path the
    /// same as an un-stattable one.
    static func stat(_ backend: any VFSBackend, at path: VFSPath) async -> FileEntry? {
        await Task.detached(priority: .userInitiated) {
            try? backend.stat(at: path)
        }.value
    }

    /// Recursively total a directory's size off the main thread (Space-on-dir sizing).
    /// Returns `nil` only if the top-level walk fails outright; unreadable subtrees are
    /// skipped inside `DirectorySizer`, not fatal. Runs at `.utility` — sizing is a
    /// background nicety and must never contend with an interactive listing.
    static func size(_ backend: any VFSBackend, of path: VFSPath) async -> Int64? {
        await Task.detached(priority: .utility) {
            try? DirectorySizer.size(of: path, using: backend)
        }.value
    }
}
