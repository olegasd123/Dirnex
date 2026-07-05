import Foundation

/// What a backend can do. Panels grey out operations a backend lacks
/// (PLAN.md §M5 "capability degradation"), so this is descriptive, not aspirational.
public struct VFSCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let read = VFSCapabilities(rawValue: 1 << 0)
    public static let write = VFSCapabilities(rawValue: 1 << 1)
    /// Move-to-Trash is available (vs. only permanent delete).
    public static let trash = VFSCapabilities(rawValue: 1 << 2)
    /// Copy-on-write clones (APFS `COPYFILE_CLONE`).
    public static let clone = VFSCapabilities(rawValue: 1 << 3)
    /// In-place rename without a copy.
    public static let rename = VFSCapabilities(rawValue: 1 << 4)
    /// Live change notifications (FSEvents and friends).
    public static let watch = VFSCapabilities(rawValue: 1 << 5)
}

/// Errors a backend raises, normalized across backends so the UI can react without
/// knowing which backend produced them.
public enum VFSError: Error, Sendable, Equatable {
    case notFound(VFSPath)
    case notADirectory(VFSPath)
    case permissionDenied(VFSPath)
    /// Any other POSIX/backend failure, carrying the raw errno for diagnostics.
    case io(path: VFSPath, code: Int32)
    case unsupported(String)

    /// Map a POSIX `errno` to the closest semantic case.
    static func fromErrno(_ code: Int32, path: VFSPath) -> VFSError {
        switch code {
        case ENOENT: .notFound(path)
        case ENOTDIR: .notADirectory(path)
        case EACCES, EPERM: .permissionDenied(path)
        default: .io(path: path, code: code)
        }
    }
}

/// The protocol every filesystem backend implements. M1 needs only read access;
/// write/copy/move land in M2 and grow this protocol then.
///
/// Backends are `Sendable` and their read methods are safe to call off the main
/// thread — directory listing must never block the UI (PLAN.md §1).
public protocol VFSBackend: Sendable {
    var id: VFSBackendID { get }
    var capabilities: VFSCapabilities { get }

    /// List the immediate children of `path` (excluding `.` and `..`), unsorted.
    /// Throws `VFSError.notADirectory` if `path` is a file.
    func listDirectory(at path: VFSPath) throws -> [FileEntry]

    /// Stat a single entry (does not follow the entry itself if it is a symlink).
    func stat(at path: VFSPath) throws -> FileEntry
}
