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
}
