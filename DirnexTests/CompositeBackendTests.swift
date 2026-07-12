import DirnexCore
import Testing

@testable import Dirnex

/// The pane's routing backend reports capabilities *per path* so the panel greys operations
/// off the current location's real backend (PLAN.md §M5 "capability degradation"). Local paths
/// keep the full disk capability set; a virtual location (a browsed `archive:…` tree or a
/// search-results listing) degrades to read-only — its `deleteStrategy` is `.unsupported`, so
/// New Folder / rename / delete grey out. (An archive's *writes* travel a separate rewrite path
/// gated by `isWritableArchive`, not these VFS capabilities.)
@Suite("CompositeBackend capabilities")
struct CompositeBackendTests {
    private let backend = CompositeBackend(local: LocalBackend())

    @Test("a local path carries the full local capability set")
    func localPathIsFullyCapable() {
        let caps = backend.capabilities(for: .local("/Users/me"))
        #expect(caps.contains(.write))
        #expect(caps.contains(.trash))
        #expect(caps.contains(.clone))
        #expect(caps.contains(.rename))
        #expect(caps.deleteStrategy == .trash)
    }

    @Test("an archive path degrades to read-only")
    func archivePathIsReadOnly() {
        let inside = VFSPath(backend: .archive(forArchiveAt: "/Users/me/pkg.zip"), path: "/a/b.txt")
        let caps = backend.capabilities(for: inside)
        #expect(caps == .read)
        #expect(!caps.contains(.write))
        #expect(caps.deleteStrategy == .unsupported)
    }

    @Test("a search-results path degrades to read-only")
    func searchPathIsReadOnly() {
        let results = VFSPath(backend: .search, path: "/query")
        #expect(backend.capabilities(for: results) == .read)
        #expect(backend.capabilities(for: results).deleteStrategy == .unsupported)
    }
}
