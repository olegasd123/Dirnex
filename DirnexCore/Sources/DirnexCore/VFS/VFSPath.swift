import Foundation

/// Identifies a virtual filesystem backend (see PLAN.md §2 "VFS").
///
/// M1 ships only `.local`; archive and SFTP backends (M4/M5) register their own
/// identifiers. Keeping this a distinct type — rather than a bare string — lets
/// `VFSPath` stay backend-agnostic while remaining `Hashable`/`Sendable`.
public struct VFSBackendID: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The local, on-disk filesystem.
    public static let local = VFSBackendID("local")

    public var description: String { rawValue }
}

/// A location within a backend: which backend, plus an absolute POSIX-style path
/// inside it.
///
/// Paths are normalized on construction (duplicate slashes collapsed, trailing
/// slash removed, leading slash enforced) so equal locations compare equal — this
/// matters because `VFSPath` is the identity used to re-anchor the cursor after a
/// live FSEvents refresh (PLAN.md §6 "reapplies cursor by identity, not row index").
///
/// This purposely does not resolve `.`/`..` or follow symlinks: that is lexical vs.
/// physical, and the backend owns physical resolution.
public struct VFSPath: Sendable, Hashable, CustomStringConvertible {
    public let backend: VFSBackendID
    /// Absolute, POSIX-style, normalized path within the backend.
    public let path: String

    public init(backend: VFSBackendID, path: String) {
        self.backend = backend
        self.path = VFSPath.normalize(path)
    }

    /// Convenience for the local filesystem: `VFSPath.local("/Users/me")`.
    public static func local(_ path: String) -> VFSPath {
        VFSPath(backend: .local, path: path)
    }

    public var isRoot: Bool { path == "/" }

    /// The final path component, or "/" for the root.
    public var lastComponent: String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "/"
    }

    /// The containing directory, or `nil` at the backend root.
    public var parent: VFSPath? {
        guard !isRoot else { return nil }
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        components.removeLast()
        return VFSPath(backend: backend, path: "/" + components.joined(separator: "/"))
    }

    /// A child path formed by appending a single name component.
    public func appending(_ component: String) -> VFSPath {
        let base = isRoot ? "" : path
        return VFSPath(backend: backend, path: base + "/" + component)
    }

    public var description: String { "\(backend):\(path)" }

    /// Collapse duplicate slashes, drop a trailing slash, and force an absolute
    /// leading slash. `.`/`..` are left intact — resolving them is the backend's job.
    static func normalize(_ raw: String) -> String {
        let components = raw.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }
}
