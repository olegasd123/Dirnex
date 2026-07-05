import Foundation
import Testing

@testable import DirnexCore

@Suite("VFSPath")
struct VFSPathTests {
    // MARK: - Normalization

    @Test("normalizes duplicate and trailing slashes")
    func normalizes() {
        #expect(VFSPath.local("/Users//oleg/").path == "/Users/oleg")
        #expect(VFSPath.local("Users/oleg").path == "/Users/oleg")
        #expect(VFSPath.local("/").path == "/")
        #expect(VFSPath.local("").path == "/")
    }

    @Test("root and lastComponent")
    func rootAndLast() {
        #expect(VFSPath.local("/").isRoot)
        #expect(VFSPath.local("/").lastComponent == "/")
        #expect(!VFSPath.local("/Users/oleg").isRoot)
        #expect(VFSPath.local("/Users/oleg").lastComponent == "oleg")
    }

    @Test("parent walks up to the root then stops")
    func parent() {
        #expect(VFSPath.local("/Users/oleg").parent == .local("/Users"))
        #expect(VFSPath.local("/Users").parent == .local("/"))
        #expect(VFSPath.local("/").parent == nil)
    }

    // MARK: - Breadcrumbs

    @Test("ancestorsFromRoot lists every crumb from root to self")
    func ancestorsFromRoot() {
        #expect(VFSPath.local("/Users/oleg/Dev").ancestorsFromRoot == [
            .local("/"),
            .local("/Users"),
            .local("/Users/oleg"),
            .local("/Users/oleg/Dev")
        ])
    }

    @Test("ancestorsFromRoot at the root is just the root")
    func ancestorsAtRoot() {
        #expect(VFSPath.local("/").ancestorsFromRoot == [.local("/")])
    }

    // MARK: - child(towards:)

    @Test("child(towards:) steps one level down toward a descendant")
    func childTowardsDescendant() {
        let deep = VFSPath.local("/Users/oleg/Dev")
        #expect(VFSPath.local("/Users").child(towards: deep) == .local("/Users/oleg"))
        #expect(VFSPath.local("/").child(towards: deep) == .local("/Users"))
        // The immediate parent's child toward the descendant is the descendant itself.
        #expect(VFSPath.local("/Users/oleg").child(towards: deep) == deep)
    }

    @Test("child(towards:) returns nil when not an ancestor")
    func childTowardsUnrelated() {
        let deep = VFSPath.local("/Users/oleg/Dev")
        // Self is the descendant: no step remains.
        #expect(deep.child(towards: deep) == nil)
        // A sibling branch is not on the way.
        #expect(VFSPath.local("/Applications").child(towards: deep) == nil)
        // Different backend never matches.
        #expect(VFSPath(backend: VFSBackendID("zip"), path: "/Users").child(towards: deep) == nil)
    }
}
