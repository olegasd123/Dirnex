import Foundation

/// Builds the `bsdtar` commands that rewrite an archive in place — the pure, tested half of
/// TC's delete-inside-an-archive (F8, PLAN.md §M4 "Archive writes: add/delete inside zip —
/// rewrite strategy, journal-safe temp file"). The app's `ArchiveWriter` runs the processes and
/// does the atomic swap; this touches no disk and spawns nothing, so it stays unit-testable,
/// mirroring how `ArchiveExtraction`/`ArchivePacking` pair with their app-side runners.
///
/// **Why a full extract-and-repack, not `bsdtar --exclude @archive`.** The obvious "re-stream the
/// archive minus some members" trick (`bsdtar -c --exclude … @old`) can't delete an *exact* path:
/// libarchive matches an exclude pattern against any trailing subpath, so deleting `docs/api/x.md`
/// would *also* silently drop `outer/docs/api/x.md`, and a bare root name like `readme.txt` would
/// hit `readme.txt` at every depth — there is no anchoring option (verified against bsdtar 3.5.3 /
/// libarchive 3.7.4). Instead the archive is extracted whole into a scratch directory, the target
/// members are removed there by their *real* filesystem paths (exact — no glob ambiguity), and the
/// surviving tree is repacked into a fresh archive that atomically replaces the original. It costs a
/// round-trip through disk, but it is correct for every format uniformly and never touches the
/// original until the rewrite has fully succeeded.
public enum ArchiveMutation {
    /// The `bsdtar` argv that extracts the *entire* archive at `archiveOnDiskPath` into
    /// `workingDirectory` — no member list, so everything comes out and can be repacked minus the
    /// deleted members. bsdtar strips a leading `/` and refuses `..`, so every entry lands safely
    /// within the working directory.
    public static func extractAllArguments(
        archiveOnDiskPath: String,
        into workingDirectory: String
    ) -> [String] {
        ["-x", "-f", archiveOnDiskPath, "-C", workingDirectory]
    }

    /// The `bsdtar` argv that repacks the whole `workingDirectory` tree into a new archive at
    /// `newArchiveOnDiskPath`. Packs `.` (not an enumerated name list) so an archive left with no
    /// members after a delete still repacks — into a valid, empty archive — rather than failing on
    /// an empty argument list. `-a` infers the format from the new archive's suffix, plus an
    /// explicit `--format` for the suffixes `-a` misreads (see `formatOverrideArguments`); the
    /// new archive carries the *same* suffix as the original, so the format is preserved.
    public static func repackAllArguments(
        newArchiveOnDiskPath: String,
        from workingDirectory: String
    ) -> [String] {
        ["-a", "-c"]
            + formatOverrideArguments(
                forArchiveNamed: (newArchiveOnDiskPath as NSString).lastPathComponent
            )
            + ["-f", newArchiveOnDiskPath, "-C", workingDirectory, "."]
    }

    /// Where an inner member sits inside the extracted working tree — the *exact* on-disk path the
    /// app removes to delete it from the archive. bsdtar reconstructs each member's full inner path
    /// minus its leading slash (`/docs/api/x.md` → `<workDir>/docs/api/x.md`), so this points at the
    /// real, unescaped file: deletion is a plain `removeItem`, with none of `--exclude`'s
    /// trailing-subpath ambiguity. A directory member's whole subtree is removed with it.
    public static func workingLocation(
        ofInnerPath innerPath: String,
        inWorkingDirectory workingDirectory: String
    ) -> String {
        let relative = String(innerPath.drop { $0 == "/" })
        return (workingDirectory as NSString).appendingPathComponent(relative)
    }

    /// A hidden sibling filename for the rewritten archive, meant to live in the *same* directory as
    /// the original so the final replace is an atomic, same-volume swap. It keeps the original's
    /// **full** suffix (`pkg.tar.gz` → `.dirnex-rewrite-<token>-pkg.tar.gz`) so `bsdtar -a` infers
    /// the same container format, and is dot-prefixed and token-tagged (a UUID) so it collides
    /// neither with a real file nor with another in-flight rewrite.
    public static func temporaryArchiveName(forArchiveNamed name: String, token: String) -> String {
        ".dirnex-rewrite-\(token)-\(name)"
    }

    /// Extra `bsdtar` creation flags for archive suffixes whose format `-a` gets wrong. `-a` infers
    /// format + compression from the suffix correctly for `.zip`, `.7z`, `.tar`, and every
    /// tar+compression alias (`.tgz`/`.tar.gz`, `.tbz`/`.tbz2`/`.tar.bz2`, `.txz`/`.tar.xz`,
    /// `.tar.zst`), but treats the zip-family aliases `.jar` and `.cbz` as *tar* — which would
    /// corrupt them on repack. Those get an explicit `--format zip` (verified against bsdtar 3.5.3).
    static func formatOverrideArguments(forArchiveNamed name: String) -> [String] {
        let lower = name.lowercased()
        if lower.hasSuffix(".jar") || lower.hasSuffix(".cbz") {
            return ["--format", "zip"]
        }
        return []
    }
}
