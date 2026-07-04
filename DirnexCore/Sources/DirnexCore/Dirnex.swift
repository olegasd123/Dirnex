/// Top-level namespace for the Dirnex core.
///
/// This package will grow into the architecture described in `PLAN.md` §2:
///
/// - `VFS` — protocol-based virtual filesystem (`LocalBackend` first, then
///   archives and SFTP), plus the `DirectoryModel` a panel renders.
/// - `Operations` — the copy/move/delete engine, its scheduling actor, the
///   conflict policy, and the undo journal.
/// - `Services` — frecency, hotlist, history, search, git status.
///
/// For milestone M0 this is intentionally almost empty: the point of M0 is a
/// real, green-CI skeleton that later milestones land on. Real functionality
/// arrives in M1 (`LocalBackend` + `DirectoryModel`).
public enum Dirnex {
    /// Semantic version of the core package. Bumped alongside app releases.
    public static let version = "0.0.1"
}
