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
    /// The target already exists — a directory create or a move/rename onto an
    /// occupied path (the conflict engine in M2 decides what to do about it).
    case alreadyExists(VFSPath)
    /// Any other POSIX/backend failure, carrying the raw errno for diagnostics.
    case io(path: VFSPath, code: Int32)
    case unsupported(String)

    /// Map a POSIX `errno` to the closest semantic case.
    static func fromErrno(_ code: Int32, path: VFSPath) -> VFSError {
        switch code {
        case ENOENT: .notFound(path)
        case ENOTDIR: .notADirectory(path)
        case EACCES, EPERM: .permissionDenied(path)
        case EEXIST, ENOTEMPTY: .alreadyExists(path)
        default: .io(path: path, code: code)
        }
    }
}

/// The protocol every filesystem backend implements. M1 needed only read access;
/// M2 grows it with the write primitives below.
///
/// Backends are `Sendable` and their methods are safe to call off the main thread —
/// neither listing nor a file operation may block the UI (PLAN.md §1). The write
/// primitives are the "instant" operations (create/rename/delete); byte-moving
/// copy/move with progress is layered on top by the M2 operation engine, not here.
///
/// A backend that lacks a capability need not implement its write methods: the
/// default implementations throw `.unsupported`, and the panel greys the operation
/// out via `capabilities` (PLAN.md §M5 "capability degradation").
public protocol VFSBackend: Sendable {
    var id: VFSBackendID { get }
    var capabilities: VFSCapabilities { get }

    /// List the immediate children of `path` (excluding `.` and `..`), unsorted.
    /// Throws `VFSError.notADirectory` if `path` is a file.
    func listDirectory(at path: VFSPath) throws -> [FileEntry]

    /// Stat a single entry (does not follow the entry itself if it is a symlink).
    func stat(at path: VFSPath) throws -> FileEntry

    /// Create a single directory at `path`. Throws `.alreadyExists` if something is
    /// already there and `.notFound` if the parent does not exist (no intermediate
    /// directories are created — mirrors `mkdir(2)`).
    func createDirectory(at path: VFSPath) throws

    /// Move or rename `source` to `destination` within this backend. Same-volume moves
    /// are an atomic rename; a cross-volume move throws (the operation engine falls back
    /// to copy-then-delete). Throws `.alreadyExists` if `destination` is occupied.
    func moveItem(at source: VFSPath, to destination: VFSPath) throws

    /// Permanently remove `path`, recursively for directories. This is not reversible;
    /// prefer `trashItem` where the backend supports a Trash.
    func removeItem(at path: VFSPath) throws

    /// Move `path` to the Trash, returning its resulting location when the backend
    /// reports one (undo restores from there). Backends without a Trash throw
    /// `.unsupported`; check `capabilities.contains(.trash)` first.
    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath?
}

public extension VFSBackend {
    func createDirectory(at path: VFSPath) throws {
        throw VFSError.unsupported("This location doesn’t support creating folders.")
    }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.unsupported("This location doesn’t support moving items.")
    }

    func removeItem(at path: VFSPath) throws {
        throw VFSError.unsupported("This location doesn’t support deleting items.")
    }

    @discardableResult
    func trashItem(at path: VFSPath) throws -> VFSPath? {
        throw VFSError.unsupported("This location doesn’t have a Trash.")
    }
}
