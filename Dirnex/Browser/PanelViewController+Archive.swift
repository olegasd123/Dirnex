import AppKit
import DirnexCore

/// Browsing archives as folders (PLAN.md §M4 ArchiveBackend). Entering an archive file
/// navigates into its virtual `archive:…` listing (served by the pane's `CompositeBackend`);
/// walking up inside walks the inner tree and, at the archive root, exits back to the folder
/// that contains the archive.
///
/// A browsed archive is read-only this pass, so the pane recognizes it via `isArchive` and —
/// like the search-results pane (`isSearchResults`) — suppresses every directory-bound
/// mutation. `isVirtualDirectory` is the union both share: anything that needs a real,
/// writable, on-disk directory checks it.
extension PanelViewController {
    /// The active tab is browsing inside an archive's virtual contents.
    var isArchive: Bool {
        panel.path.backend.isArchive
    }

    /// The active tab shows a virtual listing (search results or an archive) rather than a
    /// real on-disk directory — the gate for New Folder / rename / delete / paste and friends.
    var isVirtualDirectory: Bool {
        panel.path.backend != .local
    }

    /// The archive-root location for a local archive file — the target Enter navigates to.
    func archiveRoot(for entry: FileEntry) -> VFSPath {
        VFSPath(backend: .archive(forArchiveAt: entry.path.path), path: "/")
    }

    /// Walk up one level from inside an archive: to the parent inner directory, or — at the
    /// archive root — out to the on-disk folder containing the archive, landing the cursor on
    /// the archive file we came from. Returns `false` if this isn't an archive path.
    func goUpWithinArchive() -> Bool {
        guard let archivePath = panel.path.backend.archivePath else { return false }
        if let parent = panel.parentPath, !panel.path.isRoot {
            navigate(to: parent, focus: panel.path)
        } else {
            // At the archive root — exit to the containing local directory.
            let archiveFile = VFSPath.local(archivePath)
            guard let container = archiveFile.parent else { return true }
            navigate(to: container, focus: archiveFile)
        }
        return true
    }
}
