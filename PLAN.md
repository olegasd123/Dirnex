# Dirnex — implementation plan

A dual-pane, keyboard-first file manager for macOS in the spirit of Total Commander,
built native (Swift), with macOS-only superpowers TC never had: Quick Look, Spotlight
search, APFS clones, Finder tags, a command palette, and universal undo.

Status: planning · Created: 2026-07-05

---

## 1. Product goals

**Must be true at 1.0:**

- Fully operable without a mouse. Tab switches panels, typing filters, F-keys drive
  operations, selection is independent of the cursor.
- File operations never block the UI. Everything runs through a background queue with
  progress, pause/resume, and conflict resolution.
- Feels native: Quick Look, Trash, drag-and-drop, dark mode, Finder tags, share sheet.
- Fast on ugly inputs: a 100k-entry directory opens and scrolls without jank.
- Undo works for file operations, not just text fields.

**Non-goals (for 1.0):**

- Windows/Linux ports.
- App Store distribution (sandbox is incompatible with a real file manager).
- An open binary plugin API (revisit post-1.0; automation hooks cover most needs).
- Cloud-provider integrations beyond what the filesystem already exposes
  (iCloud/Dropbox folders work as folders; no proprietary APIs).

## 2. Architecture decisions (locked unless proven wrong)

| Decision | Choice | Rationale |
|---|---|---|
| Language | Swift 6, strict concurrency | Native perf, actors fit the operation engine |
| File panes | AppKit `NSTableView` | 100k rows, total keyboard control; SwiftUI still weak here |
| Secondary UI | SwiftUI (settings, palette, dialogs, onboarding) | Velocity where perf doesn't matter |
| Core logic | `DirnexCore` — local SwiftPM package, zero AppKit imports | Testable headless; UI is a thin client |
| VFS | Protocol-based virtual filesystem from day one | Archives/SFTP become "just another backend"; retrofitting is painful |
| Watching | FSEvents (per-directory, coalesced) | Live panel refresh |
| Copy path | `copyfile()` with `COPYFILE_CLONE`, fall back to chunked copy with progress callbacks | Instant same-volume APFS copies |
| Delete | Trash via `NSWorkspace` by default; permanent delete behind a modifier | Safety first |
| Sandbox | None. Developer ID + notarization, distributed outside MAS | Needs Full Disk Access |
| Updates | Sparkle 2 | Standard for non-MAS apps |
| Min macOS | 14 (Sonoma) | Modern APIs, still covers the realistic user base |
| Persistence | JSON/plist for config; SQLite for frecency + undo journal | Boring and debuggable |

### Core abstractions

```
DirnexCore
├── VFS
│   ├── VFSBackend (protocol): list, stat, read, write, capabilities
│   ├── VFSPath: backend id + path within backend (composable: zip inside sftp)
│   ├── LocalBackend (M1) · ArchiveBackend (M4) · SFTPBackend (M5)
│   └── DirectoryModel: sorted/filtered snapshot a panel renders; FSEvents-driven
├── Operations
│   ├── Operation (copy/move/delete/rename/pack): source set → destination
│   ├── OperationQueue actor: serial-per-volume scheduling, pause/resume, ETA
│   ├── ConflictPolicy: ask / overwrite / skip / keep-both / newer-only
│   └── UndoJournal: reversible record per operation (SQLite)
└── Services
    ├── Frecency store · Hotlist · History
    ├── Search (mdfind + streamed content grep)
    └── GitStatusProvider (M6)
```

**Rule:** the app target contains no file-manipulation logic. If it touches bytes,
it lives in `DirnexCore` and has tests.

## 3. Repository layout

```
Dirnex/
├── PLAN.md
├── Dirnex.xcodeproj            (app target, thin)
├── Dirnex/                     (AppKit/SwiftUI app sources)
│   ├── Panels/                 (NSTableView pane, tabs, path bar)
│   ├── Palette/                (Cmd+K)
│   ├── Dialogs/                (conflicts, progress, multi-rename)
│   └── Settings/
├── DirnexCore/                 (SwiftPM package)
│   ├── Sources/DirnexCore/
│   └── Tests/DirnexCoreTests/
└── Tooling/                    (CI scripts, notarization, fixtures generator)
```

---

## 4. Milestones

Sizes are relative (S ≈ days, M ≈ 1–2 weeks, L ≈ 3+ weeks of focused work).
Each milestone ends in something runnable; no milestone depends on a later one.

### M0 — Scaffolding (S)

Goal: empty but real project; every later PR lands on green CI.

- [x] Xcode project + `DirnexCore` SwiftPM package, Swift 6 strict concurrency
- [x] SwiftFormat/SwiftLint config; CI (GitHub Actions: build + tests on macOS runner)
- [x] Fixture generator: script that builds test directory trees (deep nesting,
      100k files, weird names: emoji, NFD/NFC unicode, 1000-char paths, symlinks)
- [x] App icon placeholder; ad-hoc signing for local/CI (Developer ID deferred to M7)

Exit: `xcodebuild test` green in CI; app launches to an empty window. ✅ met locally
(CI configured; Developer ID signing intentionally deferred to M7 per §2 "distributed
outside MAS" — ad-hoc signing runs everywhere without a team).

Notes:
- Xcode project uses file-system-synchronized groups (objectVersion 77) so no file
  generator (XcodeGen/Tuist) is needed — `git clone && xcodebuild test` just works.
- `DirnexCore` is a standalone SwiftPM package tested via `swift test`. It is wired
  into the app target as a local package dependency in M1, when the app first needs it.

### M1 — Read-only dual-pane browser (L)

Goal: the app already feels good with zero file operations. This milestone defines
the product's feel; do not rush it.

- [x] `LocalBackend` + `DirectoryModel`: list, stat, sort (name/size/date/ext), hidden-files toggle
- [x] Panel view: `NSTableView`, virtualized (view reuse + per-extension icon cache), columns:
      name, size, date; header-click sort with direction indicator. 60fps/100k budget not yet
      measured — deferred to the M1 exit gate / M7 perf pass.
- [x] Two panels + splitter; active-panel highlight; Tab switches
- [x] Keyboard core: arrows/Home/End/PageUp/PageDown, Enter (open dir / launch file),
      Cmd+Down/Up, and type-to-filter with live narrowing. Backspace is filter-aware (trims
      the filter, else goes up); Esc clears filter then marks (via `cancelOperation:`).
- [x] Selection model: Space/Insert toggle-and-advance, Cmd+A (mark all), `*` invert,
      `+`/`-` glob select, and Space-on-directory in-place recursive sizing.
- [x] Tabs per panel: new (Cmd+T)/close (Cmd+W)/switch (Cmd+Shift+[ / ])/drag-reorder,
      restored on relaunch. Tab bar auto-hides at a single tab.
- [x] Path bar: clickable breadcrumbs, Cmd+L to edit as text with completion
- [x] Volumes/places strip (replaces TC's drive letters); eject
- [x] FSEvents: panels refresh live, preserving cursor and selection
- [x] Quick Look on Cmd+Y (Space stays reserved for selection, per §7); previews the marked
      set or the cursor file, tracks the cursor live
- [x] Drag out to other apps; drag in = reveal only (real drop lands in M2)
- [x] Sort/column state per tab, persisted. Per-tab **sort** (key + direction) and per-tab
      **column widths/order** both live in each tab and persist across launches — switching
      tabs swaps the shared table's column geometry in/out.

_Shipped over 11 passes (2026-07-05 → 07-06). Per-pass detail (files, design rationale, gotchas) lives in git history and the memory topic file._

Exit: can live in it for browsing all day; 100k-dir opens < 150 ms warm; scroll never
drops frames; unicode/symlink fixtures render correctly.

### M2 — Operation engine (L)

Goal: TC's killer feature — queued, non-blocking, undoable file operations.

- [x] `Operation` model ✅ + `OperationQueue` actor ✅: concurrent across volume pairs,
      serial per volume pair (no disk thrashing); pause/resume, cancel, aggregate
      progress + ETA — landed as `FileOperationQueue` (renamed only to dodge
      `Foundation.OperationQueue`) and now **wired into the app** (F5/F6 route through it,
      window-bottom queue bar). "Add to queue" vs "run now" as an explicit choice is a
      later nicety — everything runs through the queue today
- [x] Copy (F5): APFS clone fast path; chunked fallback with per-file + total progress;
      preserves xattrs, permissions, dates, Finder tags; throughput/ETA readout ✅ (queue bar)
- [x] Move (F6): rename fast path same-volume; copy+delete across volumes
- [x] Delete (F8): to Trash; Shift+F8 permanent with explicit confirm
- [x] New folder (F7) ✅, inline rename (F2) ✅ — Enter-on-name deferred (Enter opens
      the cursor entry in the TC key model, so F2 is the rename trigger)
- [x] Progress UI: the window-bottom **queue bar** ✅ — aggregate determinate progress +
      live throughput + ETA, current-item label, pause/resume + cancel-all buttons,
      non-blocking (replaced the modal progress sheet, now deleted) — plus an **expandable
      per-job list** ✅ (disclosure chevron → one scrollable row per queued copy/move, each
      with its own progress bar + cancel button)
- [x] Conflict engine: ask/overwrite/skip/keep-both ✅ + newer-only ✅; **rich per-file
      dialog** ✅ (side-by-side thumbnails + size + date, newer item flagged) with **"apply
      to all"** ✅ — the engine now yields per conflict (`ConflictPolicy.ask` +
      `resolveConflict` callback). Full side-by-side text diff still deferred (thumbnails
      already give images a preview and text files a content peek)
- [x] Undo journal: Cmd+Z reverses move/rename/copy/new-folder + delete-to-Trash restore ✅;
      journal survives relaunch (JSON in UserDefaults) ✅; overwrites marked non-reversible and
      surfaced ✅ — reversal logic + property tests in `DirnexCore/…/UndoJournal.swift`
- [x] Errors: failures collected + summarized ✅; **per-file skip/retry/abort** ✅ — the engine
      yields per failed source (`CopyEngine.run(onError:)` → `ErrorResolution` skip/retry/abort),
      bridged to a main-actor `ErrorDialog` by `ErrorPrompter` ("apply to all" = skip-all)
- [x] Drop onto panel = real copy/move through the queue ✅ (pane-to-pane, into a
      subfolder, or from Finder; Finder's copy-vs-move conventions; routed through the
      shared queue via the same `submitTransfer` as F5/F6)
- [x] Core test suite on fixtures: cancellation mid-copy ✅, conflicts ✅, cross-volume ✅,
      symlink ✅, permission errors ✅, disk-full ✅, source-changed-during-copy ✅

_Shipped over 12 passes (2026-07-06 → 07-07); 130+ core tests. Per-pass detail lives in git history and the memory topic file._

Exit: 50 GB copy runs in background while browsing stays 60fps; yanking a USB drive
mid-copy produces a sane error, not a hang; Cmd+Z after a bad move actually fixes it.

### M3 — Discoverability layer (M)

Goal: fix TC's adoption problem — nobody should need the manual.

- [x] Cmd+K command palette: fuzzy search over every action, shows shortcuts,
      recents on top; palette actions and menu bar generated from one action registry ✅
- [x] Directory hotlist (Ctrl+D): pin, reorder, jump ✅
- [x] Per-panel history (Alt+Down list; Cmd+[ / Cmd+] back/forward) ✅
- [x] Frecency jump: visit tracking; path bar accepts fuzzy fragments
      ("dl" → ~/Downloads), zoxide-style scoring ✅ (JSON store; SQLite deferred like undo)
- [x] Workspaces: save/restore both panels with all tabs, named, switchable from palette ✅
      (JSON store; per-workspace palette entries deferred — surfaced via the "Workspaces…" popup)
- [x] Settings window (SwiftUI): general, panels, operations, shortcuts ✅
- [x] Rebindable shortcuts with conflict detection; TC-compatible preset and macOS preset ✅

_Shipped over 6 passes (2026-07-08). Per-pass detail lives in git history and the memory topic file._

Exit: a new user can discover copy/move/hotlist through the palette alone; power user
can rebind everything. ✅ met — palette (pass 1) + a full rebind UI with conflict detection
and two presets.

### M4 — VFS payoff (L)

Goal: cash in the VFS abstraction from M0.

- [x] `ArchiveBackend`: **browse zip/tar/tgz/7z as folders ✅**, **F5 copy-out ✅**, **Quick Look /
      Quick View inside ✅**, **pack via ⌥F5 ✅**, **nested archives (browse/extract a zip inside a
      zip) ✅** (via `bsdtar`, not libarchive — the C-module gate stays deferred)
- [x] Archive writes: **delete inside zip via F8 ✅ + add-into via paste ⌘V / F5 / F6 ✅**
      (extract → edit the tree → repack → atomic swap; rewrite strategy, journal-safe temp file)
- [x] Multi-rename tool: pattern tokens ([N] name, [C] counter, [E] ext, date tokens),
      regex find/replace, case transforms, live preview table, applies as one undoable batch
- [x] Search (Alt+F7 / palette): mdfind-backed name+content search with filter chips
      (kind, size, date ✅ — tag chip + content-grep fallback for non-indexed volumes deferred)
- [x] Search results → virtual panel listing: normal cursor/selection/F5 on results
- [x] Quick view panel (⌃Q toggle — Cmd+Q quits, Cmd+Shift+Q was free but ⌃Q is the TC key):
      inactive panel becomes live Quick Look/text preview of the file under cursor
- [x] Saved searches as virtual folders in the places strip ✅ — name a results panel via
      Go ▸ Save Search… (⌘S when a results tab is active), it lands in the sidebar's
      **Searches** section (magnifier icon); click to re-run into a fresh results tab;
      right-click → Run / Rename… / Delete

Exit: open a zip, fish two files out, repack — no temp-folder dance; rename 500 photos
by date pattern and undo it; search feeds a panel.

_Shipped over 11 passes (2026-07-09 → 07-12); 341 core tests. Per-pass detail (ArchiveBackend rewrite strategy, nested-archive mapping, saved searches, recurring gotchas) lives in git history and the memory topic file._

### M5 — Network and sync (M)

- [x] `SFTPBackend`: connection manager, **key auth + password auth**; **browse + byte transfer +
      mid-file resume** all DONE and verified live (via the system `sftp` CLI, not
      swift-nio-ssh/libssh2 — the same sidestep M4 made with `bsdtar`). Copy-out (`get`) / copy-in
      (`put`), remote mkdir / rename / recursive-delete all run through the standard queue; an SFTP
      pane is writable (`[.read, .write, .rename]`) so the pass-5 grey-out + Trash-less
      confirmed-permanent-delete light up. **Password auth** (pass 9) via `SSH_ASKPASS` (no PTY
      needed) + Keychain storage. **Mid-file resume** (pass 10) — `copyFile` picks up a partial
      destination via `get -a`/`put -a` instead of restarting; verified live against a real server
- [x] **SMB shares + unified connection manager** (built + verified live 2026-07-14): browse/copy to another
      Mac / PC / NAS over SMB, and one place that keeps every saved remote — SFTP and SMB alike. SMB
      is done the OS-native way: macOS ships **no `smbclient`** CLI to shell out to, so the sidestep
      here is the **mounter**, not a client — `NetFSMountURLSync` / `mount_smbfs` mounts
      `smb://user@host/share` and the existing `LocalBackend` browses the resulting `/Volumes/…`
      tree, so every M2 op, sync-dirs, compare-by-content, and archive-over-SMB works unchanged —
      **no new `CompositeBackend` routing, no libsmb2 dependency** (the deliberate choice over a
      protocol `SMBBackend`, mirroring SFTP's system-CLI sidestep). Caps reuse the pass-5 degradation
      path (read/write/rename, no clone, Trash-varies → confirmed-permanent-delete). The **connection
      manager** unifies today's ephemeral SFTP registry with persisted saved servers: a
      `ServerConnection` / `ServerConnections` core (name-as-identity, like `SavedSearch`) + a
      `ServerConnectionStore` + a **Servers** sidebar section (mirrors **Searches**), plus a
      generalized Connect-to-Server prompt (protocol picker SFTP | SMB + Save). Subsumes the deferred
      "saved SFTP connections in the sidebar" item
- [x] Capability degradation: panels grey out unsupported ops per backend ✅ (per-path
      `capabilities(for:)`; no Trash → explicit permanent-delete confirm ✅; no clone →
      always chunked ✅) — driven off the owning backend's caps, ready for SFTP to plug into
- [x] Synchronize directories: two-panel diff view (left-only / right-only / differs /
      same ✅), by size+date or content ✅; selective sync actions through the queue ✅;
      per-row *direction override* ✅ (right-click a row → flip a copy the other way, or turn a
      copy into a delete; also resolves a bidirectional `differ` conflict by hand) — include/
      exclude per row already done
- [x] Compare by content: **byte compare ✅** (`ByteComparator`, drives sync `.content` mode) +
      **external-diff handoff ✅** (FileMerge/Kaleidoscope/BBEdit via `ExternalDiffTool` — a
      **Compare By Contents…** command plus a right-click **Compare with …** in the sync sheet)

Exit: mirror a local folder to a server over SFTP, verify with sync-dirs, all queued
and pausable; and browse/copy to an SMB share on another Mac or NAS, connected and
managed from the Servers sidebar.

Progress (2026-07-12, M5 pass 1): the **directory-synchronization comparison core** landed —
the tested, headless *comparison* half of the "Synchronize directories" item (its two-panel
diff-view UI + queue wiring is the next pass; boxes stay `[ ]` until that lands). Picked first
because it's pure Swift and slots straight into the core→app rhythm, whereas `SFTPBackend` needs
a swift-nio-ssh/libssh2 dependency + a live server to test against — the M5 infra gate, analogous
to M4's libarchive gate. Two new `DirnexCore/Services/` files, no changes to existing APIs:
- **`DirectorySync.swift`** — `DirectorySync.compare(left:right:leftBackend:rightBackend:
  comparison:tolerance:includingIdentical:isCancelled:contentsEqual:)` walks both trees in
  lock-step (iterative explicit-stack over a private `DirectoryPair{left,right,prefix}`, like
  `DirectorySizer`, so deep trees can't blow the call stack) and returns one `SyncEntry`
  (`relativePath`+`name`+`left:FileEntry?`+`right:FileEntry?`+`status`, `Identifiable` by
  relative path) per differing/one-sided item, **sorted by relativePath** (deterministic
  regardless of traversal order → stable tests + stable UI). `SyncStatus` = `leftOnly /
  rightOnly / leftNewer / rightNewer / differ / identical / typeMismatch`. Design decisions:
  (1) directories present on **both** sides are descended into but emit **no row** (rows =
  actionable file diffs + one-sided items); a directory on **only one** side is a **single**
  non-recursed subtree row (the app copies/deletes it wholesale, matching TC's collapsed
  folder row). (2) `SyncComparison.sizeAndDate` (size equal AND |Δmtime| ≤ `tolerance`,
  default **2 s** for FAT/exFAT coarseness, TC's value) vs `.content` (exact bytes; short-
  circuits on size mismatch, falls back to size+date for symlinks/specials). (3) content
  equality is an **injected** `contentsEqual` closure (default `ByteComparator.localFilesEqual`)
  so the engine needs no read-primitive on `VFSBackend` and tests drive content mode with a
  fake. (4) **SAFETY: a listing failure propagates** — an unreadable dir throws rather than
  reading as empty, because silently doing so could delete the other side's matching files in
  a mirror (contrast `DirectorySizer`, which *does* swallow — there a partial number is fine;
  here a partial listing is dangerous). `defaultAction(for:direction:)` derives the pre-checked
  per-row action for `SyncDirection.leftToRight / rightToLeft / bidirectional` → `SyncAction`
  (`none / copyToRight / copyToLeft / deleteLeft / deleteRight / conflict`): a mirror is
  authoritative (overwrites even a newer destination + prunes destination-only items),
  bidirectional unions + newer-wins + never deletes + flags `differ`/`typeMismatch` as
  `conflict`; a file-vs-dir `typeMismatch` is **always** `conflict` in every direction (the
  strict-and-safe stance from MultiRename — never auto-delete a whole dir to drop a file in).
- **`ByteComparator.swift`** — knocks out the byte-compare half of the "Compare by content"
  item: `ByteComparator.localFilesEqual(_:_:chunkSize:isCancelled:)` chunk-compares two local
  regular files (128 KB chunks, never loads whole files), short-circuits `false` on a size
  mismatch without reading, `true` on same-path/two-empties; throws `.unsupported` for a
  non-`.local` path (network read arrives with `SFTPBackend`) or a directory, and normalizes
  read failures to `VFSError` via a POSIX-errno recovery helper. (External-diff-tool handoff —
  FileMerge/Kaleidoscope/BBEdit — is the remaining slice of that item, an app-layer pass.)
+18 `DirectorySync` +9 `ByteComparator` tests → **368 core tests** (was 341). Whole thing
`swift test` green, swiftformat/swiftlint-strict clean; app target untouched (new files only,
no existing-API changes, so no rebuild needed). GOTCHA hit: swiftlint `large_tuple` (>2 members)
on the work-stack `(left,right,prefix)` triple → extracted the private `DirectoryPair` struct.
NEXT M5: the sync-dirs UI (two-panel diff view driven by `compare`, per-row action override,
apply through the M2 `FileOperationQueue`); then the SFTPBackend infra gate; capability
degradation; external-diff handoff.

Progress (2026-07-12, M5 pass 2): the **Synchronize Directories UI** landed — the diff-view +
apply half of the sync item (**that box now `[x]`**; byte-compare `[~]`). One new headless
command + three app files, wiring the pass-1 `DirectorySync` engine into a real sheet that
reconciles the two panes through the M2 queue. VERIFIED LIVE end-to-end (no overlay this
session, so fully mouse-driven). Pieces:
- **Command** (core): `CommandCatalog` gains `file.syncDirectories` ("Synchronize Directories…",
  `.file`, **no shortcut** → conflict-free; new `coversSyncDirectories` test → **369 core
  tests**). Wired app-side in `CommandBinding` (→ `synchronizeDirectories(_:)`) and
  `MainMenuBuilder` (File menu, right after Pack). GOTCHA: adding one command tipped the
  `CommandCatalog` main-enum body over swiftlint `type_body_length` 250 → moved the `workspace`
  array into the existing bottom extension (where window/application already live).
- **`SyncDirectoriesController.swift`** — the sheet (modeled on `MultiRenameController`,
  `presentAsSheet`-retained). A **Direction** segmented control (Left→Right / Both Directions /
  Right→Left) and a **Compare by** control (Size & Date / Content) over a diff `NSTableView`:
  columns *include-checkbox · Item (relativePath, "/"-suffixed for dirs) · leftFolder detail ·
  action glyph · rightFolder detail*. Action column = green →/← for a copy, red ✕ for a delete
  (which side is clear from the populated detail column), ⚠ for a conflict, each with a tooltip.
  A **direction change re-derives actions in memory** (`recomputeActions`, instant); a
  **comparison change re-runs `DirectorySync.compare` off-main** (content mode reads bytes) with
  a spinner. Footer reads "N to copy, M to delete · K conflicts skipped"; empty result →
  "The folders are already in sync." with Synchronize disabled. Conflicts render with a disabled
  checkbox (no safe action). GOTCHAS (swiftlint, both recurring): `large_tuple` on the columns
  array / `row(at:)` / `actionDisplay` → replaced with an `addColumn` helper, returning the
  `fileprivate` `Row` struct, and an `ActionStyle` struct; `type_body_length` on the class →
  moved the four `make*` view-builders into a same-file `private extension` (extensions don't
  count toward the type body). NOTE: `Row` had to be `fileprivate` (not `private`) because the
  `fileprivate row(at:)` accessor returns it.
- **`PanelViewController+Sync.swift`** — entry point + apply. `synchronizeDirectories(_:)`
  casts `host as? BrowserWindowController` to always use the **physical** left/right panes (so
  the direction controls match the on-screen layout regardless of focus), gates on two distinct
  real local folders (`canSynchronize`, also the `validateMenuItem` case), and presents the
  sheet. On commit: **copies are batched by destination directory** (multiple sources → one
  `FileOperation`) and enqueued under `.overwrite` (the user already decided in the diff — no
  per-file prompt; atomic temp-swap keeps the original safe), so the window's queue drives
  progress/undo exactly like F5; **deletes go to the Trash** off-main as one pass, journaled via
  `UndoRecord.trash`. A **delete count triggers a confirm sheet** first ("… will move N items to
  the Trash"). The relative path's parent always exists on the destination side (the engine only
  descends into both-sides dirs), so a nested copy's target directory is guaranteed present.
LIVE TEST (seeded both panes onto fixture trees via the `Dirnex.tabs.<side>` UserDefaults JSON):
the sheet listed exactly the 6 differences (identical `same.txt` correctly omitted) with
"5 to copy, 1 to delete"; Right→Left flipped every row (3 copy ←, 3 delete ✕, "3 to copy, 3 to
delete"); Content mode rescanned to the same 6; Synchronize (Left→Right) raised the delete
confirm, then on disk overwrote `changed.txt` with the newer left copy, copied `only_left.txt` +
the nested `sub/leftonly_nested.txt`, overwrote the nested `sub/nested.txt`, **recursively copied
the one-sided `leftdir/deep/x.txt` subtree**, and trashed `only_right.txt`; a re-scan then
reported "already in sync" (metadata preserved → idempotent). App `xcodebuild` + `swift test`
green, swiftformat/swiftlint-strict clean. NEXT M5: per-row direction override (flip one row);
the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server); capability degradation;
external-diff-tool handoff.

Progress (2026-07-12, M5 pass 3): **per-row direction override** — the one deferred niceness on
the sync item, **now `[x]`**. Right-click any diff row to override its action against the global
direction: flip a copy the other way, or turn a copy into a delete; a bidirectional `differ`
conflict (or a mirror row you disagree with) is resolved by hand this way. Two-part, core→app as
always:
- **Core** (pure, tested): `DirectorySync.availableActions(for status:) -> [SyncAction]` (+ a
  `SyncEntry.availableActions` convenience) — the *actionable* choices a user may assign to one
  row: a both-sides difference (`leftNewer`/`rightNewer`/`differ`) → `[.copyToRight, .copyToLeft]`
  (copy either way, never delete a file that exists on both sides); a one-sided item → propagate
  *or* delete from its side (`leftOnly`→`[.copyToRight, .deleteLeft]`, mirror for `rightOnly`);
  `identical` and `typeMismatch` → `[]` (no safe override — a file-vs-folder clash still can't be
  auto-resolved, matching the strict stance). `.none`/`.conflict` are deliberately absent (skip is
  the checkbox's job; conflict is a non-action). +5 tests → **374 core tests** (was 369).
- **App**: `SyncDirectoriesController` gains an `NSMenu` (delegate = self) on the diff table;
  `menuNeedsUpdate` rebuilds it per-click from `tableView.clickedRow` — one item per
  `availableActions`, a `.on` checkmark on the row's current action, target `setRowAction(_:)`
  (row in `tag`, `SyncAction` in `representedObject`); an empty list shows one disabled caption
  ("One side is a folder — resolve manually"). Picking an item sets the row's action + forces
  `included = true`, reloads that row, and recomputes the footer. Added a "Right-click a row to
  change its action" hint in the controls row. A direction/comparison change still re-derives
  defaults and drops overrides (documented behavior). GOTCHA (recurring, `file_length` this time,
  not `type_body_length`): the new menu tipped the controller over swiftlint's 500-line
  `file_length` → **split the diff-table + override-menu rendering into a companion file**
  `SyncDirectoriesController+DiffTable.swift` (data source + delegate + `NSMenuDelegate` +
  `ActionStyle`). That cross-file split forced widening `Row`, `rowCount`, `row(at:)`,
  `isActionable`, `toggleInclude`, `setRowAction`, `tableView`, `leftDir`, `rightDir` from
  `private`/`fileprivate` to internal (Swift `private` doesn't cross files; a `private`
  `tableView` in a `NSTableViewDelegate`-conforming type even resolves to the delegate *method* in
  the other file → "has no member 'clickedRow'" until widened). App `xcodebuild` (into `build/`
  via `-derivedDataPath build`, since the default DerivedData copy isn't the one LaunchServices
  launches) + `swift test` green, swiftformat/swiftlint-strict clean. VERIFIED LIVE end-to-end:
  seeded two fixture trees (`changed.txt` left-newer, `only_left.txt`, `only_right.txt`, identical
  `same.txt`); right-click `changed.txt` showed "✓ Copy to R / Copy to L" → picked Copy to L (glyph
  → ←); right-click `only_left.txt` showed "✓ Copy to R / Delete from L" → picked Delete from L
  (footer went "2 to copy, 1 to delete" → "1 to copy, 2 to delete"); Synchronize raised the
  **2-item** trash confirm (proving the overridden delete count drives it), and on disk `L/changed.txt`
  became the *right* copy (6 B "right", i.e. copied **leftward** per the override, NOT the L→R
  default's 34 B), `only_left.txt` was trashed from L (not copied to R), `only_right.txt` trashed
  from R — both panes refreshed to identical `changed.txt`+`same.txt`, no crash. NEXT M5: the
  `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server); capability degradation;
  external-diff-tool handoff (FileMerge/Kaleidoscope/BBEdit — the remaining `[~]` slice).

Progress (2026-07-12, M5 pass 4): **external-diff-tool handoff** — the remaining `[~]` slice of
Compare-by-content, **now `[x]`**. `ByteComparator` says *whether* two files differ; this opens them
side-by-side in a real diff tool to show *how*. Core→app as always:
- **Core** (pure, tested): `DirnexCore/Services/ExternalDiffTool.swift` — a value descriptor of a
  known diff app (`identifier`+`displayName`+`candidateExecutablePaths` most-preferred-first+
  `leadingArguments`) with `invocation(comparing:with:executableExists:)→ExternalDiffInvocation?`
  (executable + argv = `leadingArguments + [left, right]`; nil when not installed). Locating the
  launcher is an **injected** `(String)->Bool` probe, so the whole thing is testable with no real
  install. Registry `known` = `[.kaleidoscope, .bbEdit, .fileMerge]` (dedicated diff apps first,
  FileMerge/`opendiff` as the ships-with-Xcode fallback); `installed(where:)` filters, `preferred(
  identifier:where:)` honors a saved choice then falls back to the first installed. Paths: FileMerge
  `/usr/bin/opendiff`; Kaleidoscope `ksdiff` and BBEdit `bbdiff` under `/opt/homebrew/bin` then
  `/usr/local/bin`. +8 tests → **383 core tests** (was 374).
- **App**: `Dirnex/Browser/ExternalDiffLauncher.swift` — supplies the real probe
  (`FileManager.isExecutableFile`) and spawns the resolved invocation off-main via `Process`
  (`run()` then detach — never blocks on the GUI tool; streams → nullDevice), mirroring
  `ArchiveExtractor`. `preferredTool()` (cheap) titles/enables the menu; `compare(_:_:completion:)`
  reports `noToolInstalled` / `launchFailed` back on the main actor. Two entry points: (1) a
  right-click **Compare with <tool>…** item prepended to the sync sheet's row menu for any
  both-sides regular-file pair (wired via `SyncDirectoriesController.onCompare`); (2) a standalone
  **Compare By Contents…** File command (`file.compareByContents`, no shortcut → conflict-free;
  `coversCompareByContents` test) that diffs the two panes' **cursor** files (`comparableCursorPair`
  — both must be real local files and distinct; gates `validateMenuItem` via `canCompareByContents`).
  Failures surface through the existing `presentOperationFailure` alert ("No comparison tool found —
  install FileMerge/Kaleidoscope/BBEdit"). App `xcodebuild` (into `build/` via `-derivedDataPath
  build`) + `swift test` green, swiftformat/swiftlint-strict clean. VERIFIED the handoff mechanic
  live: only `/usr/bin/opendiff` is installed here → `preferred()` resolves FileMerge; spawning
  `opendiff <L> <R>` exactly as the launcher does launched FileMerge (confirmed via `pgrep`), then
  quit it. **NEXT M5:** the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 + live server);
  capability degradation. A Settings picker for the preferred diff tool (the `preferred(identifier:)`
  hook already exists) is optional polish.

Progress (2026-07-12, M5 pass 5): **capability degradation** — the second remaining M5 item,
**now `[x]`**. Panels now decide what they offer off the *owning backend's* capabilities rather
than ad-hoc `path.backend == .local` / `isVirtualDirectory` checks, and the delete key degrades to
a confirmed permanent delete on a Trash-less backend — the exact mechanism `SFTPBackend` plugs into
(SFTP has no Trash, no APFS clone). Core→app as always; no SFTP needed to prove it (a partial-
capability test double stands in). Pieces:
- **Core** (pure, tested): `VFSBackend.capabilities(for path:) -> VFSCapabilities` added to the
  protocol with a **default returning the backend-wide `capabilities`** — a single-backend
  implementation is uniform, but a *routing* backend (the app's `CompositeBackend`) overrides it to
  report the caps of whichever concrete backend owns `path`. New `DeleteStrategy` enum (`trash /
  permanent / unsupported`) + `VFSCapabilities.deleteStrategy` computed property encode the
  degradation decision: `.write` absent → `.unsupported`; writable but no `.trash` → `.permanent`
  (SFTP); has `.trash` → `.trash`. `CopyEngine` now guards its clone attempt on
  `backend.capabilities(for: entry.path).contains(.clone)` so a no-clone backend goes **straight to
  chunked** instead of a doomed clone (`.clone` present on Local → unchanged). +7 tests → **390 core
  tests** (was 383): `deleteStrategy` mapping, the `capabilities(for:)` default, a `RoutingStub`
  proving per-path degradation, and a `PartialCapabilityBackend` (a `LocalBackend` decorator with a
  configurable capability set + a clone-call counter) proving CopyEngine skips the clone when
  `.clone` is absent and still attempts it when present. GOTCHA: swiftlint `empty_count` fired on the
  counter's `.count == 0` — renamed the property to `calls`.
- **App**: `CompositeBackend.capabilities(for:)` routes per path — `local.capabilities` for `.local`,
  `.read` for any virtual location (archive/search), cheap by design (no archive mount, like
  `volumeIdentifier(for:)`). `canWriteHere`/`canRenameHere` now read `backend.capabilities(for:
  panel.path).contains(.write/.rename)` (drops the `!isVirtualDirectory` prefix — a virtual pane
  already reports `.read`, and this is correct for a future writable-non-local SFTP where
  `isVirtualDirectory` would wrongly fire). `deleteSelection`/`validateMutatingItem` now branch on
  `capabilities(for:).deleteStrategy`: `.unsupported` → no-op/greyed, `.trash` on F8 → Trash (with the
  existing optional confirm), else (Shift+F8, or F8 on a Trash-less backend) → the confirmed
  permanent-delete path. The **top-level-archive rewrite delete** (`isWritableArchive` →
  `beginArchiveDelete`) still short-circuits *first* — archive writes are the app's separate
  rewrite path, not VFS caps. Left the watch / archive-extract·pack·drop guards on their intentional
  `path.backend == .local` gates (local-only machinery; SFTP-destination is a later SFTP pass — not
  refactored speculatively). New app test `DirnexTests/CompositeBackendTests.swift` (+3 → **7 app
  tests**) asserts the crux: local path = full caps (`deleteStrategy == .trash`), archive + search
  paths = `.read` (`deleteStrategy == .unsupported`). Behavior on today's backends is **identical by
  construction** (traced each branch: local delete = Trash, archive/search delete greyed, New
  Folder/rename greyed on virtual) — the change is degradation *infrastructure* + a behavior-
  preserving refactor, so the visible payoff arrives with SFTP. `swift test` (390) + app
  `xcodebuild test` (7) green, swiftformat/swiftlint-strict clean, app launches + quits cleanly.
  **NEXT M5 (last item):** the `SFTPBackend` infra gate (swift-nio-ssh/libssh2 dependency + a live/
  dockerized SSH server to test against) — with per-path capabilities + `DeleteStrategy` now in
  place, an SFTP pane's grey-out and Trash-less delete-confirm work the moment the backend reports
  `[.read, .write, .rename]` (no `.trash`/`.clone`). Optional polish: Settings picker for the
  preferred diff tool.

Progress (2026-07-12, M5 pass 6): the **SFTPBackend read-only browse core** landed — the pure,
tested foundation of the last M5 item. Same sidestep M4 made for the libarchive gate: rather than
add a swift-nio-ssh/libssh2 dependency, the plan is to drive the **system `ssh`/`sftp` CLI** (ships
with macOS) behind an **injected transport**, so the whole backend is exercised with a fake and
needs *no live server* — the analogue of `ArchiveBackend`'s read-only first pass (browse first,
write/copy later). Box stays `[ ]` (no live transport, no writes, no app wiring, no server
verification yet); this is the browse half of "browse/copy through the standard queue". **Four new
DirnexCore files, purely additive (no existing-API changes, so the app is untouched and needs no
rebuild):**
- **`VFS/SFTPLocation.swift`** — the connection descriptor (`host`+`port`(=22)+`username`, `Codable`,
  **no secret** — the password/key passphrase is a Keychain reference the app resolves, so a location
  is safe to serialize into a tab/bookmark/id). Encodes to a `VFSBackendID` as `sftp://user@host:port`
  (the SFTP analogue of the on-disk path an archive id carries), with `init?(descriptor:)` /
  `init?(backendID:)` and `VFSBackendID.sftp(_:)`/`.sftpLocation`/`.isSFTP` extensions — kept in this
  file (not `VFSPath.swift`) so the addition is purely new-files. Username split at the **first** `@`,
  port at the **last** `:` (bracketed IPv6 literal noted as a later refinement, not a hole).
- **`VFS/SFTPTransport.swift`** — the injected boundary: `SFTPTransport` protocol (`listDirectory(_:)`
  → raw `ls -la` text, `statItem(_:)` → raw `ls -ld` line) + `SFTPTransportError{notFound /
  permissionDenied / failure(String)}` (the few shapes the backend maps onto `VFSError`). Synchronous
  (the backend is always called off-main); the app supplies a `Process`-driven impl, tests a fake.
- **`VFS/SFTPListingParser.swift`** — a **close cousin of `ArchiveTOCParser`** (same "8 fixed columns
  then a verbatim name" shape, same `nameField` column-skip so internal spaces survive, same
  `en_US_POSIX` `MMM d HH:mm`/`MMM d yyyy` date formats) but **flat** (one directory, no tree, no
  ancestor synthesis) — kept separate to avoid churning the heavily-tested archive parser. `ls -la` →
  `[Entry]` (name/kind/byteSize/mtime/**permissions**/symlinkDestination): drops the `total` header
  and the `.`/`..` rows, mode-char → kind (`d`/`l`/`-`/other), ` -> target` split for symlinks, mode
  string → POSIX bits, tolerates an ACL `+`/xattr `@` 11-char mode. `parseItem` reads the single
  `ls -ld` line.
- **`VFS/SFTPBackend.swift`** — the `VFSBackend` over the injected transport (a `struct`, like
  `ArchiveBackend`). `id == .sftp(location)`; **`capabilities == .read`** for now (advertising `.write`
  before copy-in works end-to-end would let the UI start a paste the backend can't finish — the honest
  cap today; the widened `[.read, .write, .rename]` that lights up pass-5's `DeleteStrategy`/clone
  degradation arrives with the byte-transfer pass). `listDirectory`/`stat` route through the parser;
  `stat` **names the entry from the queried path's last component** (since `ls -ld /a/b` prints the
  full arg as the name); a `mapErrors` helper attaches the `VFSPath` the transport (raw-string only)
  couldn't, turning `SFTPTransportError` → `VFSError.notFound/permissionDenied/io`. `volumeIdentifier`
  = `sftp://host:port` so **all one-host jobs serialize** (one SSH channel — parallel transfers only
  contend), cheap/no-I/O as the protocol requires. symlink target reported as nominal `.file` (not
  resolved — matches `ArchiveBackend`); no birth time → `creationDate = modificationDate`.
+8 `SFTPLocation` +11 `SFTPListingParser` +9 `SFTPBackend` tests (a private `FakeSFTPTransport` double
returning canned listings / throwing configured errors) → **418 core tests** (was 390). `swift test`
green, swiftformat/swiftlint-strict clean. GOTCHA: a year-stamped `ls` date parses at **local**
midnight (the formatter sets no zone) → the test must read `.day` in the local calendar, not forced
UTC, or the day shifts. **NEXT M5 (finishes the item):** the app-layer live transport — a
`Process`-driven `ssh`/`sftp` runner (mirroring `ArchiveMounter`/`SpotlightSearchRunner`), a
connection manager + Keychain credential storage + key auth, composite-backend routing on `isSFTP`,
and the **write pass** (mkdir/move/remove + byte `copyFile` with resume, flipping caps to
`[.read, .write, .rename]` → the pass-5 grey-out + Trash-less permanent-delete confirm go live). That
tail is the genuine infra gate: it needs a live/dockerized SSH server (or local Remote Login) +
credentials to verify against — which I can't provision here, so it awaits that setup. Optional
polish still open: Settings picker for the preferred diff tool.

Progress (2026-07-13, M5 pass 7): the **live SFTP transport + app wiring + Connect-to-Server UI** —
**SFTP browse now works end-to-end and is VERIFIED LIVE** against a real server (`oleg@mac`, local
Remote Login), so the `SFTPBackend` box goes `[ ]`→`[~]` (browse done; byte transfer + password/
Keychain auth remain). The user enabled `ssh oleg@mac`; key auth was set up (a throwaway ed25519 key
authorized for the session, all test artifacts cleaned up after). CRITICAL: driving the real `sftp`
CLI first showed its batch `ls -la` **differs from GNU `ls -l`** (captured live), so **pass 6's core
was reworked to match reality** (pass 6 was still uncommitted): (1) the link-count column is `?`;
(2) names are printed as **full paths** (`ls -la <abs>` echoes the arg) → every name reduced to its
last component; (3) symlink **targets aren't shown** (no ` -> t`); (4) `sftp` has **no `ls -d`** → a
single-item stat can't use it. Core changes (still purely additive to DirnexCore): `SFTPTransport`
slimmed to one method `listDirectory` + a tested `SFTPTransportError.classify(stderr:)` (maps `sftp`
stderr → notFound/permissionDenied/failure; permission-denied checked **first** so a bad-key
`identity file … no such file` + `Permission denied` classifies as the actionable auth failure) +
`SFTPBatchCommand.list` (quoted/escaped batch line, tested); `SFTPListingParser` now `parse`s **all**
rows basenamed **including `.`/`..`**; `SFTPBackend.stat` uses the **`.` self-row trick** (a dir
listing carries a `.` row that *is* the directory's stat → identify it, else it's a single-file
row). App layer: `SFTPProcessTransport` (spawns `sftp -i key -o BatchMode=yes -b -`, drains stderr on
a bg queue to dodge a two-pipe deadlock, `resolveHomeDirectory` via `pwd`); `CompositeBackend`
gained an `sftpConnections` registry + `connectSFTP` + `isSFTP` routing (`connectedSFTP` throws a
clear "Not connected" otherwise); `go.connectServer` command → `PanelViewController+SFTP.connectToServer`
(probes home off-main = a fail-fast connection test, then registers + navigates) + `SFTPConnectPrompt`
(NSAlert grid: host/port/user/key-file, rejects leading-`-` args). Two LIVE-found bugs fixed: (a) the
path bar rendered SFTP as **"🔍 Results for oleg"** (the search-results dead-end label) → added an
`isSFTP` branch giving **clickable breadcrumbs rooted at the account** (`oleg@mac › Users › oleg`),
since an SFTP path is re-listable; also `PanelViewController.navigate` no longer treats SFTP as
"wasVirtual" (it keeps a normal back/forward trail) and `FrecencyStore.recordVisit` now only records
`.local` paths (a remote path can't be fuzzy-jumped). (b) recent `ls` dates showed **year 2000** —
the "MMM d HH:mm" form omits the year and `DateFormatter` defaults it to a 2000 reference → set
`defaultDate = now` on the no-year formats (+ a future-date year rollback for the Dec/Jan boundary).
Tests: +`SFTPTransport`(batch/classify incl. bad-key ordering) +`connectServer` catalog cmd +current-
year date +CompositeBackend sftp routing/read-only + a **gated live integration suite**
(`DirnexTests/SFTPLiveIntegrationTests`, enabled only when `/tmp/dirnex_sftp_live_test.json` exists —
`xcodebuild` doesn't forward shell env, so a file not env vars) → **427 core tests**, **14 app tests**
(4 live: resolve-home, list, stat, composite-route — proven genuinely live by a bogus-key run that
*fails* them, not skips). GOTCHA (recurring): the connectServer command tipped `CommandCatalog` over
`type_body_length` 250 → moved the whole `navigation` array into the bottom extension. VERIFIED LIVE
end-to-end via the GUI: Go ▸ Connect to Server → filled host/user/key → the left pane browsed the
remote home (21 items, `oleg@mac › Users › oleg` breadcrumb, correct 2026 dates), then **double-clicked
into `dirnex_sftp_fixture`** — breadcrumb extended, listed `emptydir`/`photos`/`latest` (symlink)/`my
report.txt` (space preserved)/`notes.txt`, `.`/`..` dropped. App `xcodebuild` + `swift test` green,
swiftformat/swiftlint-strict clean. SPOTTED FOLLOW-UP (out of scope, pre-existing): `ArchiveTOCParser`
shares the same no-year→2000 date bug for recent archive members — worth the same `defaultDate = now`
fix. **NEXT M5 (finishes `SFTPBackend`):** the write pass — `SFTPProcessTransport` gains
mkdir/rename/remove + `copyFile` (download via `sftp get`, upload via `put`) with progress/resume,
flipping SFTP caps to `[.read, .write, .rename]` so the pass-5 grey-out + Trash-less permanent-delete
confirm light up; then password/Keychain auth (needs a PTY). Optional polish: an SSH ControlMaster so
repeated listings reuse one connection instead of re-handshaking per directory; saved connections in
the sidebar; Settings picker for the preferred diff tool.

Progress (2026-07-13, M5 pass 8): the **SFTP write pass** — remote mutation + byte transfer, so the
operation queue drives copies, moves, and deletes onto a remote exactly as on disk. **`SFTPBackend`
box stays `[~]`** (byte transfer now DONE; only keychain **password auth** + mid-file **resume**
remain). **VERIFIED LIVE** against `oleg@mac` (a throwaway key the user authorized for the session,
all artifacts cleaned up after — including the remote scratch dir, which the recursive-delete proved
it removes): the gated live suite's new **write round-trip** (mkdir → `put` upload → list-and-check-
size → `get` download → byte-compare → recursive remove) passed through the real `sftp` CLI, plus the
5 existing browse tests. Core→app as always:
- **Core** (hermetic, +14 tests → **441**): `SFTPTransport` grew the write verbs (`makeDirectory`/
  `rename`/`removeFile`/`removeDirectory`/`createSymbolicLink`/`download`/`upload`) + matching
  quoted/escaped `SFTPBatchCommand` builders (`mkdir`/`rename`/`rm`/`rmdir`/`ln -s`/`get`/`put`).
  `SFTPBackend.capabilities` flipped **`.read` → `[.read, .write, .rename]`** (no `.trash`, no
  `.clone` — the exact shape pass 5's `DeleteStrategy`/clone degradation was built for). New
  primitives: `createDirectory` (mkdir); `moveItem` = remote rename within one account, else
  **throws `EXDEV`** so `CopyEngine` falls back to copy-then-delete for a cross-backend (local⇄SFTP)
  move; **recursive `removeItem`** — `sftp` has no `rm -r`, so it empties a directory depth-first
  then `rmdir`s it, and crucially classifies the top item from its **parent listing**, not a `stat`
  of the path (`sftp`'s `ls` *follows* a symlink, so statting a link-to-dir would delete the
  *target's* contents — a parent listing shows the link as a link, so `rm` removes the link alone);
  `copyFile` = **download** (`id` source → `.local` dest, `get`) or **upload** (`.local` source →
  `id` dest, `put`), reporting the transferred bytes once for the progress bar and honouring
  `isCancelled` at the file boundary, refusing an unexpressible remote↔remote copy. The fake
  transport now records every write call so the recursion/routing is asserted without a server.
- **App**: `SFTPProcessTransport` spawns each verb as one `sftp` batch command (reusing the pass-7
  `run(batch:)`), transfers returning the local file's size for progress. `CompositeBackend` routes
  `capabilities(for:)` to a **connected** SFTP backend (`[.read, .write, .rename]`; an unconnected /
  dropped SFTP path falls back to `.read` so writes grey out rather than fail), routes `copyFile` on
  the **destination** when it is remote (so an upload reaches the SFTP `put`; a download/local-local
  still routes on the source), and throws `EXDEV` for any cross-backend move. Reconciled
  `isVirtualDirectory` → **`isArchive || isSearchResults`** (an SFTP dir is a *real* writable remote
  directory, not virtual), which — together with pass-5's capability-driven `validateMenuItem` —
  lights up New Folder (mkdir), F2/⇧F2 rename (remote rename), F8 delete (Trash-less → confirmed
  permanent), ⌘V paste-upload, and F5/F6 up/down on an SFTP pane; relaxed `beginTransfer`'s
  destination guard to allow an SFTP target (upload), made `refreshCurrentDirectory` re-list an SFTP
  pane after a mutation (no FSEvents), and gated ⌘C off SFTP (a remote entry has no *local* URL for
  the pasteboard — F5 is the copy-out route). +1 app test → **16** (`CompositeBackendTests` now
  asserts a connected SFTP path is writable/`.permanent`, an unconnected one read-only). GOTCHA
  (recurring): the new write tests tipped `SFTPBackendTests` over swiftlint `type_body_length` 250 →
  split them into a same-file `extension SFTPBackendTests`. `swift test` (441) + app `xcodebuild
  test` (16) green, swiftformat/swiftlint-strict clean. **NEXT M5 (finishes `SFTPBackend` → `[x]`):**
  password/Keychain auth (needs a PTY, so not the batch `sftp -b -` path — likely `expect`-style or
  an `SSH_ASKPASS` helper) and mid-file resume (`get -a`/`put -a`). Optional polish: SSH
  ControlMaster connection reuse, saved connections in the sidebar, Settings picker for the diff
  tool. **M6 is the next milestone** once SFTP closes out.

Progress (2026-07-13, M5 pass 9): **SFTP password auth** — the harder of the two remaining
`SFTPBackend` items, **DONE and verified live** against a real password server (user-provided
`sa@192.168.1.176`, pass `123`). The plan predicted this "needs a PTY"; it doesn't — the sidestep is
`SSH_ASKPASS`. Key facts discovered by probing OpenSSH 10.2 live before writing any Swift, all of
which shaped the design: (1) `sftp -b -` forces `-oBatchMode=yes` onto `ssh`, which **disables the
password prompt entirely** ("no more authentication methods"), so password auth **cannot use `-b`** —
it runs `sftp` *interactively* over a piped stdin, and the parser's pre-existing `sftp>`-echo skipping
(pass 6/7) already handles the interactive output. (2) With no TTY, `SSH_ASKPASS_REQUIRE=force`
(OpenSSH ≥ 8.4) makes `ssh` call the `SSH_ASKPASS` program for the password — **proven live via a
marker-file probe** that the helper actually fires. (3) **`keyboard-interactive` HANGS for ~60 s on a
*wrong* password** when askpass auto-answers it (macOS PAM), which would freeze the pane on a typo —
so only the `password` method is offered (`PreferredAuthentications=password`, plus
`PubkeyAuthentication=no` so a stray local key can't bypass the choice, `NumberOfPasswordPrompts=1` to
fail fast). Core→app as always:
- **Core** (pure, tested, +6 → **446**): `SFTPAuthentication` enum (`.key(identityFile:)` / `.password`,
  **no secret** — the password is resolved by the app and fed out-of-band); `SFTPProcessArguments.batch(
  location:authentication:connectTimeout:)` assembles the argv — **key** = the untouched verified
  `-i … -o BatchMode=yes … -b -`, **password** = interactive (no `-b`) + the password-only flags above
  — pinned by tests so the security-sensitive flag set (which auth methods, prompt on/off) is verified
  without a server, like `SFTPBatchCommand`; `SFTPTransportError.detect(stderr:)` — interactive `sftp`
  **exits zero on a failed command**, so its errors live only in stderr, and this scans for them
  (`permission denied`/`not found`/`Couldn't …`/`: Failure`) while ignoring benign banners/`Connected
  to …`/host-key warnings; `SFTPLocation.keychainService` + `keychainAccount` (`user@host:port`).
- **App**: `SFTPProcessTransport` reworked to `authentication` + `password` (was `identityFile`), builds
  argv from the core builder, and for password sets the child env (`SSH_ASKPASS` → helper,
  `SSH_ASKPASS_REQUIRE=force`, the password in `DIRNEX_SFTP_PASSWORD`) — the password rides **only** in
  the process environment, never on the argv or on disk. `SFTPAskpassHelper` writes a **secret-free**
  `#!/bin/sh; printf '%s\n' "$DIRNEX_SFTP_PASSWORD"` once to Application Support (0700). `run` now
  drains **both** pipes on a concurrent queue joined by a `DispatchGroup` so a password session can
  **bound its wait** (`passwordTimeout`, 30 s) — a server that never closes the channel can't hang the
  pane — and throws on a bad interactive command via `detect`. `resolveHomeDirectory` opts into
  `tolerateChannelHold` (the connect probe's single-line `pwd` reply is complete even if the server
  holds the channel open — the live test server does exactly that, so a real connect there takes the
  full timeout but succeeds). `SFTPKeychain` (Security framework) stores/loads/deletes the password
  keyed by `keychainAccount`; `SFTPConnectPrompt` gained a Private-Key/Password segmented control + an
  `NSSecureTextField` (irrelevant field greys out); `connectToServer` stores the password to the
  Keychain **only after** the probe authenticates (so a typo isn't cached); `CompositeBackend.connectSFTP`
  + the live/app-test call sites thread `authentication`/`password`. +1 app test (askpass helper is
  executable) + a self-gated **localhost wrong-password** live test (real transport → `.permissionDenied`
  in ~2.4 s, **no TTY hang** — the crux) + a credential-gated **live password-auth** suite
  (`/tmp/dirnex_sftp_password_test.json`) → **19 app tests**. VERIFIED LIVE end-to-end: the real
  `SFTPProcessTransport` authenticated against the user's server with `sa`/`123` through the actual
  `sftp`+`SSH_ASKPASS` path and resolved the remote home. `swift test` (446) + app `xcodebuild test`
  (19) green, swiftformat/swiftlint-strict clean. GOTCHA: the test server ("ServeSense … Brute Force
  Protection") returns an **empty root and holds the channel open** (hangs even after `quit`) — proved
  auth but not browse; `tolerateChannelHold` + `passwordTimeout` keep it from hanging the pane. Also:
  `NSSecureTextField` + a 6-field form tripped swiftlint `function_parameter_count` → grouped the
  controls into a `Fields` struct. **NEXT (finishes `SFTPBackend` → `[x]`):** mid-file **resume**
  (`get -a`/`put -a`) — optional polish, not in the M5 exit criteria; then **M6**.

Progress (2026-07-14, M5 pass 10): **mid-file resume** (`get -a`/`put -a`) — the last remaining
`SFTPBackend` item, **now `[x]`, so the whole SFTP box closes and M5 is DONE**. A copy that finds a
nonzero *proper prefix* of the source already at the destination (a partial from an interrupted
transfer) picks up where it left off instead of re-sending the whole file; `sftp` computes the byte
offset itself from the existing length. User supplied a new test appliance at **192.168.1.50** (SFTP
:22, FTP :21, FTPS :990; `sa`/`123`) — a **ServeSense "Brute Force Protection"** box, the same kind
as pass 9's password server. Chose "finish SFTP first" over adding FTP/FTPS (not in the plan). Core→
app as always:
- **Core** (pure, tested, +5 → **451**): `SFTPTransport.download`/`upload` grew a `resume: Bool`
  parameter; `SFTPBatchCommand.download`/`upload` emit `get -a`/`put -a` when set (default `false`
  keeps every existing call site). `SFTPBackend.copyFile` reworked into `downloadFile`/`uploadFile`
  helpers that **detect a resumable partial cheaply so the common fresh transfer pays nothing**: a
  **download** reads the local partial's size (free `FileManager` stat) and only then asks the server
  for the remote size — a fresh download (no local partial) skips the remote round trip entirely; an
  **upload** only asks the server for the remote destination's size when the source exceeds
  `resumeUploadThreshold` (1 MiB), since re-sending a small file costs less than the metadata round
  trip that finding its partial would need. `progress` reports only the bytes actually moved (the
  remainder when resuming), computed as `finalSize − preExistingSize`; the transport's return value
  was redefined from "bytes transferred" to "the file's final total size" so the backend can derive
  the delta. Tests: batch-command `-a` variants; `copyFile` resumes a download (local partial 120 <
  remote 300 → `get -a`, reports 180), resumes a large upload (remote partial 1 MiB < 2 MiB source →
  `put -a`, reports the 1 MiB remainder), **does not** resume a small upload (skips the stat), and
  **does not** resume a fresh download. GOTCHA (recurring): the fake transport's recorded-transfer
  tuple went to 3 members (`local`/`remote`/`resume`) → swiftlint `large_tuple` → extracted a
  `RecordedTransfer` struct.
- **App**: `SFTPProcessTransport.download`/`upload` thread `resume` through to the batch builder
  (returning the local file's final size). +1 gated live test (`resumesPartialTransfer` in
  `SFTPLiveIntegrationTests`): upload a 120-byte prefix, `put -a` the full 300, then `get -a` a local
  120-byte partial back to 300 and byte-compare — runs green on a well-behaved key-auth server (skips
  in CI / here, like the other live tests). App tests stay at **20** (the new one is gated).
- **Live verification**: the resume *mechanic* was proven end-to-end against the user's 192.168.1.50
  server via the actual `sftp` CLI the app shells out to — `put -a` grew a seeded 120-byte remote file
  to 300 ("Resuming upload", byte-compare matched), and `get -a` grew a local 120-byte partial to 300
  (byte-compare matched); mkdir/put/get/rm/rmdir were also all exercised and the remote left clean.
- **Known limitation (the ServeSense appliance, documented not fixed):** 192.168.1.50 **authenticates**
  (`sa`/`123`, verified live via the app's connect probe, which opts into `tolerateChannelHold`) but
  **holds the SSH channel open after every command** (hangs even after `quit`), so the app's
  one-shot-per-command transport **times out on browse/transfer** through it (only the single-line
  connect probe tolerates the hold today — a multi-row listing must not be read partially). This is
  the same appliance quirk pass 9 already noted; making the whole app work against channel-hold
  appliances (tolerating the hold for transfers, whose size comes from the local file rather than
  stdout) is a separate, considered enhancement, deliberately **not** bundled into this resume pass.
  Because of it, resume was verified via raw `sftp` (above), not the app transport, against this
  particular box; the app-transport path is covered by the gated live test on a normal server.
- **Scope honesty:** resume is a correct, tested `copyFile` capability that activates whenever a
  partial destination is handed in. The current in-app copy flow writes to **fresh temp destinations**
  (the M2 overwrite path uses a per-attempt UUID temp; the direct `.proceed` path writes a fresh
  target), so nothing hands `copyFile` a partial today — resume is inert in that flow by construction.
  Wiring it to fire in-app means preserving a partial across a conflict/overwrite retry (a stable temp
  name), which touches the M2 atomic-swap/undo guarantees — left as a deliberate future step, not done
  here. `swift test` (451) + app `xcodebuild test` (20) green, swiftformat/swiftlint-strict clean.
  **M5 network+sync is now fully `[x]`; M6 (Mac-native power features) is next.** Optional polish
  still open across M5: SSH ControlMaster connection reuse (would also make the resume upload-stat and
  browse cheap, and could sidestep the ServeSense per-command hang), saved SFTP connections in the
  sidebar, a Settings picker for the preferred diff tool; and the user's FTP/FTPS servers remain
  available if FTP(S) backends are ever added (a plan expansion beyond M5's SFTP-only scope).

Progress (2026-07-14, M5 — SMB + unified connection manager, SCOPED not yet built): with the four
original M5 boxes `[x]`, the milestone gains one more remote protocol (SMB, for LAN Macs / PCs / NAS)
plus the "keep every connection in one place" manager the SFTP work deferred. Two design decisions,
both taken deliberately over the tidier-looking alternative:
- **SMB rides the OS mounter, not a protocol backend.** SFTP could shell out to the system `sftp`
  CLI; macOS ships **no `smbclient`**, so the equivalent OS-native sidestep for SMB is the *mounter*.
  `NetFSMountURLSync` (or `Process` → `/sbin/mount_smbfs`) mounts `smb://user@host/share`, and the
  existing `LocalBackend` browses the `/Volumes/…` tree it produces — so copy/move/rename/delete
  (M2), synchronize-directories, compare-by-content, quick-view, and even browsing a zip *on* the
  share all work with **zero new code** and **no new `CompositeBackend` routing**. The rejected
  alternative was a real `SMBBackend` over libsmb2/AMSMB2: it keeps the clean "just another
  VFSBackend" symmetry SFTP has (`smb://…` routed like `sftp://…`, no `/Volumes`), but it's the heavy
  C dependency the plan avoided for SFTP — a module gate like the deferred libarchive one — with no
  CLI to sidestep it and every M2/sync/compare guarantee to re-prove over it. Consistent with the
  non-goals ("folders work as folders; no proprietary APIs"), the mount wins. The one genuinely new
  surface is a **mount lifecycle**: an app-layer `SMBMounter` + mount registry (the non-hermetic I/O
  boundary, like `ArchiveMounter`), mounting on connect, unmounting only what *we* mounted on
  disconnect/quit (leaving a Finder-mounted share alone), and detecting an already-mounted share. Caps
  = `[.read, .write, .rename]`, no APFS clone, Trash-varies → **reuse the pass-5 capability-degradation
  + Trash-less permanent-delete path verbatim**. Guest/anonymous mounts (blank user) supported for
  home NAS; `smbutil view //user@host` share-discovery and Bonjour `_smb._tcp` LAN auto-discovery are
  optional niceties (the latter M6-ish).
- **One connection manager for both protocols.** Today live SFTP connections are ephemeral in
  `CompositeBackend.sftpConnections` (lost on quit) and nothing persists a saved server. Rather than
  add a second, SMB-only model, unify: a pure `ServerConnection` (name = identity like `SavedSearch`;
  `kind: .sftp / .smb`; coordinates + auth *method*, never the secret — Keychain still holds those) +
  `ServerConnections` list (the `SavedSearches` save/rename/move/dedupe shape, unit-tested headless);
  an app `ServerConnectionStore` (UserDefaults JSON + `didChangeNotification`, a `SavedSearchStore`
  clone); a **Servers** sidebar section mirroring **Searches** (click → connect/mount + navigate;
  right-click → Connect / Edit… / Remove; live connected/mounted indicator); and a generalized prompt
  (rename `SFTPConnectPrompt` → `ConnectServerPrompt`, `PanelViewController+SFTP` → `+Connect`) with a
  protocol segmented control (SFTP | SMB) above the existing Auth control and a "Save connection" name
  field. **Address entry is Finder-⌘K-style**: a primary `smb://user@host/share` URL field (type or
  paste, exactly the form Finder's Connect to Server takes) that **parses into editable host / share /
  user fields shown below it**, so paste-a-URL and guided entry both work and the two stay in sync;
  a bare `smb://host` (share omitted) mounts-on-connect / offers a share picker. Under the hood this is
  the same NetFS mount as above — the URL is just what the user sees and what the sidebar stores. This
  **subsumes** the deferred "saved SFTP connections in the sidebar" polish item. The app
  stays non-sandboxed (a plan non-goal), so `mount_smbfs` / NetFS needs no special entitlement.
Nothing built yet — this is the scoped design; core-first as always (`ServerConnection(s)` + tests,
then `SMBMounter` / store / sidebar / prompt), verified live against a LAN SMB share.

Progress (2026-07-14, M5 SMB pass 1 — the pure core): the tested, headless value types landed, the
same core-first opener every M5 slice used. Two new `DirnexCore` files, no behavioural change to any
existing type (one additive conformance):
- **`VFS/SMBLocation.swift`** — the SMB analogue of `SFTPLocation`: `host` / `share?` / `username?` /
  `port` (default 445), *without* a secret. Deliberately **not** a `VFSBackendID` address — SMB rides
  the OS mounter, so this is purely the Finder-⌘K URL the user types/pastes and the sidebar stores
  plus the mount target it resolves to. `url` renders the canonical `smb://[user@]host[:port][/share]`
  (default port elided, guest omits `user@`, share-less stops at the host); `init?(url:)` parses that
  form back into editable coordinates — the "address field parses into host/share/user fields below"
  the design calls for is just this round-trip. Parse rules: username up to the first `@`, host up to
  the first `/`, a `:digits` tail split off as the port (a non-numeric colon stays in the host), the
  **first** path component as the share (deeper `…/share/sub` mounts the share; the subpath is
  navigated post-mount). Empty share/username normalize to `nil` so guest and share-less each have one
  representation. `keychainService = "com.dirnex.smb"` + `keychainAccount` = the scheme-less URL
  (unused for guest). Domain (`DOMAIN;user`) and bracketed IPv6 are noted later refinements, like
  SFTP's IPv6 note.
- **`Services/ServerConnection.swift`** — the unified saved-server model (mirrors `SavedSearch`
  name-as-identity): `ServerConnection`(name + `ServerEndpoint`) where `ServerEndpoint` is
  `.sftp(location:authentication:)` | `.smb(SMBLocation)` — one list covers both protocols rather than
  a second SMB-only model. Convenience `kind: ServerKind{.sftp,.smb}` (sidebar icon/branch) and
  `address` (the SFTP descriptor / SMB URL for the subtitle). No secret in the endpoint: SFTP carries
  its auth *method* (`.key(identityFile:)` path or the `.password` marker), SMB's guest-vs-auth is
  captured by whether `username` is set — Keychain still holds any actual password. `ServerConnections`
  is the `SavedSearches` collection verbatim (`save` replace-in-place/append, `remove`,
  `rename` with collision guard, `move`, dedupe-on-init, sanitizing `Codable`). Needed one additive
  change: **`SFTPAuthentication` gained `Hashable, Codable`** (it was `Equatable`) so the endpoint
  enum synthesizes both — purely additive, the full app still builds.
- **`SMBLocationTests` (13) + `ServerConnectionTests` (17)** → **481 core tests** (was 451; +30),
  covering URL format/parse/round-trip/malformed for SMB and the full collection contract +
  per-protocol Codable for the connection list. `swift test` green, swiftformat + swiftlint-strict
  clean, `xcodebuild` app build succeeds. **NEXT (SMB pass 2, app layer):** `SMBMounter` + mount
  registry (NetFS `NetFSMountURLSync` / `mount_smbfs`; mount on connect, unmount only our own),
  `ServerConnectionStore` (a `SavedSearchStore` clone), the **Servers** sidebar section (mirrors
  **Searches**), and the generalized `ConnectServerPrompt` (rename `SFTPConnectPrompt`; protocol picker
  SFTP | SMB + Save + the URL-expands-to-fields entry) — verified live against a LAN SMB share.

Progress (2026-07-14, M5 SMB pass 2 — the app layer, CODE-COMPLETE; live-mount check pending): all
four pass-2 surfaces built, app builds + `swift test` (481 core) + 24 app tests green, swiftformat +
swiftlint-strict clean. Nothing touched `CompositeBackend` routing — SMB never becomes a `VFSBackendID`;
it rides the OS mounter and browses `/Volumes/…` as `.local`, exactly as designed.
- **`SMBMounter.swift`** — the mount lifecycle (the one non-hermetic surface, like `ArchiveMounter`).
  `@MainActor final class` with a `shared` app-wide registry of the `/Volumes/…` paths *we* created.
  `mount(_:username:password:) async` snapshots `FileManager.mountedVolumeURLs` before mounting, runs
  the blocking `NetFSMountURLSync` on a `Task.detached` (so the four static helpers are
  `nonisolated static`), and records the mount as ours only if the path wasn't already mounted — so a
  Finder-mounted share is never adopted. Guest mount = `kNetFSUseGuestKey` + nil user (blank username);
  auth mount passes user/pass separately. **The mount URL is built user-less** (`smb://host[:port]/share`,
  default 445 elided) — the username goes to NetFS as a separate arg, never in both (the one unit-tested
  invariant). `kNAUIOptionKey = kNAUIOptionNoUI` so a bad password errors instead of blocking on a
  dialog. `disconnect(mountPoint:)`/`unmountOwnedMounts()` (called from `AppDelegate.applicationWill
  Terminate`) eject only our mounts via `NSWorkspace.unmountAndEjectDevice`. `SMBMountError:
  LocalizedError` maps `EAUTH`/`ENOENT`/`EHOSTDOWN`/… to human reasons. Needed `import NetFS` (auto-links;
  typechecked green against the SDK). `SMBKeychain` = an `SFTPKeychain` clone keyed by
  `SMBLocation.keychainService`.
- **`ServerConnectionStore.swift`** — a `SavedSearchStore` clone verbatim (UserDefaults JSON under
  `Dirnex.serverConnections` + `didChangeNotification`); no secret ever serialized.
- **Servers sidebar section** — mirrors Searches. `SidebarViewController.Row` gained `.server`, a
  **Servers** header trails the Volumes section, per-kind SF Symbol (`network` SFTP /
  `externaldrive.connected.to.line.below` SMB), click → `didActivateServer`, trailing delete +
  right-click **Connect / Edit… / Remove** (Remove also clears the Keychain secret). Split the
  saved-search **and** new server management into companion files (`SidebarViewController+Searches.swift`,
  `+Servers.swift`) to stay under file_length 500 — which forced widening `Row`/`tableView`/`rows` to
  internal (Swift `private` doesn't cross files, the recurring gotcha); `menuNeedsUpdate` stays in the
  main file as a dispatcher. Two new delegate methods (`didActivateServer`/`didEditServer`).
- **`ConnectServerPrompt` + `ConnectServerForm`** (renamed from `SFTPConnectPrompt`;
  `PanelViewController+SFTP`→`+Connect`, both via `git mv` — synchronized Xcode groups need no pbxproj
  edit). Prompt returns a `Form(endpoint: ServerEndpoint, password:, saveName:)` reusing the pass-1 core
  enum. The form is a protocol picker (SFTP | SMB) over **independent** per-protocol field sets (so no
  cross-contamination / no SFTP `NSUserName()` default leaking into SMB); accessory sized once to the
  taller (SFTP) layout so toggling rows never resizes the modal. **SMB entry is Finder-⌘K-style**: an
  `smb://user@host/share` address field two-way-synced with editable host/share/user fields via the pure
  `SMBLocation` url⇄init round-trip (`controlTextDidChange`, re-entrancy-guarded; port rides the URL).
  Prefill (Edit…) loads coordinates + the Keychain secret. `type_body_length` >250 → view/value factories
  moved to a file-scope `@MainActor private enum ConnectFormFactory`. `PanelViewController+Connect`:
  `connectToServer` (prompt→apply), `connect(to:)` (saved-server, Keychain secret or fall back to the
  prefilled prompt), `editServer` (rename removes-old-then-saves in place); SFTP path unchanged, SMB path
  mounts then `navigate(to: .local(mountPoint))`, secrets filed only after success, saved only when named.
  `CommandCatalog` `go.connectServer` keywords gained smb/share/mount/nas.
CAPS NOTE: SMB browses as `.local` so it gets full local caps — but `clonefile` returns `ENOTSUP` on SMB
→ `CopyEngine` falls back to chunked cleanly, and Trash either works (NAS `.Trashes`) or surfaces an
error; explicit mount-point cap degradation ([.read,.write,.rename]) was deliberately NOT wired (would
couple `CompositeBackend` to the mounter) — deferred. **NEXT: live-verify against a LAN SMB share**
(mount guest + auth, browse/copy/rename/delete, disconnect-unmounts-only-ours, quit-cleanup); then the
share-picker for a bare `smb://host`, Bonjour `_smb._tcp` discovery (M6-ish), and the deferred cap tweak.

Progress (2026-07-14, M5 SMB pass 2 — VERIFIED LIVE against a LAN Windows SMB box, `192.168.1.50`,
share `Temp`, user `smbtest`): drove the built app end-to-end via computer-use. Confirmed: the Connect
dialog renders both layouts; **SMB address `smb://smbtest@host/Temp` two-way-synced into host/share/user
fields**; guest is refused by the box (auth required — mapped cleanly); an authed mount lands at
`/Volumes/Temp`, appears in the sidebar's Volumes section, and browses via `LocalBackend` (`test.txt`
visible); the named connection persisted to the **Servers** section and **survived relaunch**;
right-click **Connect / Edit… / Remove** all work — Connect re-mounts from the Keychain password (no
re-prompt), **Edit… prefills every field incl. the Keychain secret**; **New Folder (createDirectory)
and Delete Immediately (permanent removeItem) both work over SMB**; a **clean quit unmounts only our
mount**, and an externally-mounted share is **left mounted** on quit (the "unmount only ours" safety
guarantee). TWO bugs found + fixed live: (1) the `NSAlert` accessory collapsed and overlapped the
message — cause was setting `translatesAutoresizingMaskIntoConstraints = false` + sizing the container
by constraints; `NSAlert` sizes an accessory by its **frame**, so the container now keeps an explicit
frame and the grid is pinned top-left inside it; (2) re-connecting an already-mounted share hit NetFS
`EEXIST` (17, empty mountpoints) → added `existingMountPoint(for:)` (matches a mounted volume's
`statfs.f_mntfromname` `//host/share`, case-insensitive) so `mount()` **detects and reuses** an existing
mount (Finder's or ours) instead of re-mounting — which also realizes the "detect already-mounted share"
design goal. CONFIRMED the deferred cap gap is real: **Move-to-Trash (F8) fails on the Windows share**
(error 3328) since SMB carries full local caps; Delete Immediately is the working path. 481 core + 24
app tests green, swiftformat/swiftlint-strict clean. The SMB item is now `[x]`; only the optional
niceties (bare-host share-picker, Bonjour discovery, F8→permanent-delete cap-degradation on SMB mounts)
remain, all deferrable to M6-ish polish.

### M6 — Mac-native power features (M)

- [x] Git awareness: branch in path bar, status column (M/A/?/ignored) via a debounced
      `git status --porcelain` provider; optional .gitignore-aware folder sizes (the one
      optional slice, still deferred)
- [x] Finder tags: column, edit from panel, filter chips in search
- [ ] Terminal drawer: bottom pane following active panel's cwd; "cd sync back" via
      shell integration snippet; open in iTerm/Terminal/WezTerm as alternative
- [ ] Size visualization mode: toggle panel to ncdu-style bars, computed async, cached
- [ ] Share sheet, "Open With" submenu, Services integration
- [ ] Automation: AppleScript/Shortcuts verbs (reveal, copy, run-op); user actions —
      shell scripts receiving selection as argv/env, surfaced in palette and F-key bar
- [ ] iCloud/provider sync-status column (NSFileManager ubiquity attrs where available)

Exit: git repo browsing shows live status; a user-defined "convert to webp" script on
selection runs from the palette.

Progress (2026-07-15, M6 pass 1 — the Git-awareness core): the pure, tested foundation of the Git
item landed, the same core-first opener every M4/M5 slice used. Box stays `[ ]` (no provider, no
column, no path-bar branch, no app wiring yet) — this is the parse/lookup half. **Four new
`DirnexCore/Services/` files, purely additive** (no existing-API changes, so the app is untouched and
needs no rebuild). Method note: `git`'s real output was **probed live before any Swift was written**
(the pass-7 lesson — `SFTPListingParser` had to be reworked because its format was assumed, not
observed), which caught three things a from-memory parser gets wrong:
- **`GitStatus.swift`** — `GitFileStatus` (`unmodified/modified/added/deleted/renamed/untracked/
  ignored/conflicted`, each with Git's own one-letter `code` — the app picks the colour, this picks
  the character) + `GitStatusEntry` (one porcelain record: `relativePath` + **both** of Git's axes,
  `indexStatus`/`worktreeStatus`, kept verbatim so a later tooltip can say "staged edit plus unstaged
  edits on top" without re-parsing) + `GitBranch` (name/upstream/ahead/behind/isDetached/
  hasNoCommits, for the path bar). `entry.status` collapses the two axes into the one value a column
  renders: untracked/ignored/unmerged are whole-entry verdicts and answer first; otherwise the
  **index column wins when set** (`AM` — staged new, then edited — reads "added", which is more use
  to someone browsing a folder than "modified"), else the worktree column (the common ` M`/` D`).
  Every unmerged shape (`UU`/`AU`/`UA`/`DU`/`UD`/`AA`/`DD`) is one `.conflicted`.
- **`GitStatusSnapshot.swift`** — the per-row lookup a panel does while rendering, so `status(for:)`
  is O(1) and all the work happens once at construction. **(1) Directory roll-up**: Git reports files,
  panels also show the folders holding them → every entry's ancestors are pre-merged by
  `rollupPrecedence` (conflict > modified > added > deleted > renamed > untracked > ignored), so a
  folder advertises the loudest thing inside it. **`.ignored` deliberately does NOT roll up** — a
  source folder holding one ignored `debug.log` is not itself ignored, and painting it `!` would say
  exactly that. **(2) Collapsed-directory inheritance**: Git emits `build/` and says *nothing* about
  the files inside, so a lookup that misses falls back to the nearest untracked/ignored ancestor and
  the contents still read as ignored once you navigate in. **(3)** The repo root itself is never
  painted (its roll-up would mark the `..` row of every dirty repo).
- **`GitStatusParser.swift`** — `-z` output → snapshot. **`-z` is the whole point**: without it Git
  *quotes* any path with a space or a non-ASCII byte (`"caf\303\251.txt"`) and the parser would have
  to reimplement C-string unquoting; with it every field is raw bytes. The cost is two traps, both
  found by probing: **(a) the rename pair** — `-z` emits `R  <new>` NUL `<old>` NUL, i.e. the *reverse*
  of the printed `old -> new`, so reading them in the printed order names every renamed row after the
  file that no longer exists; **(b) the branch header** is NUL-terminated like any entry, not a line.
  Four header shapes captured live and pinned: `main` · `main...origin/main [ahead 1, behind 1]` ·
  `HEAD (no branch)` · `No commits yet on main` (splitting on `...` is unambiguous — refname rules
  forbid `..` in a branch). Malformed fields are skipped, never thrown on: a snapshot missing one
  exotic row still renders a useful panel, whereas throwing blanks the whole column.
- **`GitRepository.swift`** — `repositoryRoot(for:exists:)` walks up for `.git`, **nearest first** (a
  submodule/nested repo wins, matching what `git` itself reports from there), with the filesystem
  reduced to an injected `exists` probe (`ExternalDiffTool`'s shape) so discovery is tested without a
  repository. The probe must be a **plain existence check**: `.git` is a regular *file* in a linked
  worktree or submodule, and a directory check would silently drop Git awareness exactly where people
  use worktrees. `GitCommand` pins the argv (like `SFTPProcessArguments`): **`--no-optional-locks`**
  (a plain `git status` opportunistically rewrites the index under `index.lock`; a poller doing that
  behind the user's back races their own git commands and can fail *their* rebase — this makes the
  read side-effect-free, the same reason editors pass it), `--porcelain=v1 --branch -z`, and
  **`--ignored=traditional`** (one collapsed row for `node_modules/` instead of a hundred thousand).
  **`/usr/bin/git` is deliberately NOT a candidate executable**: it is Apple's `xcrun` shim, and
  spawning it without the Command Line Tools installed pops a modal "install developer tools?" dialog
  — a background poller must never be able to do that to someone who just opened a folder. Candidates
  are Homebrew → CLT → Xcode; none installed ⇒ Git awareness stays off and the column stays blank
  (the same graceful degradation as no diff tool installed).
FINDING (documented, changed the code): the anticipated **unicode trap is a non-issue in Swift** —
macOS hands back decomposed names (`e`+U+0301) while Git, with `core.precomposeunicode` (on by
default), reports the precomposed form, so the two spell one file with different bytes (verified:
their UTF-8 differs). But Swift's `String` compares *and hashes* by **canonical equivalence**, so the
keys are interchangeable in the dictionary for free. The first draft normalized every key with
`precomposedStringWithCanonicalMapping` — which was not just redundant but a **fresh allocation on
every row lookup** in a 100k-row panel's hot path. Removed; a test pins the property instead, since
it is load-bearing and would break in any byte-keyed language.
+63 tests → **544 core tests** (was 481): the parser suite is anchored on a **golden fixture of the
exact bytes captured from git 2.50.1** against a scratch repo built to hold every shape at once.
`swift test` green, swiftformat + swiftlint-strict clean. **VERIFIED LIVE against real repositories**
(a throwaway harness compiled against the core, driving the real `git` binary through `GitCommand`):
the scratch repo parsed every shape incl. the rename-source pairing; the four branch shapes each
confirmed on a purpose-built repo (fresh → `noCommits`, a clone → `ahead=1 behind=1`, detached →
detached); and **Dirnex's own repo** reported branch `Dev` / upstream `origin/Dev` (matching
`git rev-parse`) with the roll-up painting the top-level `DirnexCore` row `?` from files nested four
levels deep, and `.claude`/`build` collapsed to single ignored rows. The NFD-vs-NFC match was proven
live too — the on-disk decomposed name resolved against Git's precomposed key through the real
filesystem. **NEXT (M6 pass 2, the app layer):** a `GitStatusProvider` (`Process`-driven, **debounced**,
off-main, cached per repo root, refreshed on FSEvents + directory change — mirroring
`SpotlightSearchRunner`/`ArchiveMounter`), the **status column** in the panel (per-tab, like the other
columns) and the **branch in the path bar**; then the optional `.gitignore`-aware folder sizes.

Progress (2026-07-15, M6 pass 2 — the app layer; **the Git box closes `[x]`**, only the item's own
"optional" `.gitignore`-aware folder sizes deferred). Three new app files plus one split, and no core
change at all (pass 1's 544 tests stand untouched):
- **`GitStatusProvider.swift`** — spawns `git` off-main through pass 1's `GitCommand`, parses with
  `GitStatusParser`, caches one snapshot per **repository root** (LRU, 8). Shared, not per-pane,
  because the unit of caching is the repository: two panes in one working tree must get one answer
  from one run. **Rate limiting is the whole design, not a nicety** — in a repository the FSEvents
  never stop (a build writes thousands of files, a checkout rewrites the tree), so a request is
  either coalesced into a 300 ms trailing window or, when the snapshot has already been stale for
  2 s, run immediately: a pure trailing debounce starves under a long build's continuous churn and
  would freeze the column for its duration. Runs are serialized per root (a request arriving mid-run
  is replayed once, never spawned alongside). **Pass 1's `--no-optional-locks` turns out to be what
  makes any of this terminate**: without it our own `git status` would rewrite `.git/index`, FSEvents
  would report that as a change, and the pane would ask for another refresh — a spawn loop fed by
  nothing but our own reading.
- **BUG, caught reviewing before the live run:** the "a first look runs immediately" test asked *do
  we have a snapshot*, but a repository `git` refuses to read (dubious ownership, a corrupt index)
  caches none — so every event would count as a first look and spawn `git` again, precisely the storm
  the rate limiting exists to prevent. It now asks *have we ever run this* (`lastRun`), and `forget()`
  deliberately keeps the run stamp when it drops the snapshot; only LRU eviction clears it, which
  correctly makes an aged-out repository a first look again.
- **`PanelViewController+Git.swift`** — per-*tab* root + snapshot (so a tab switch restores the Git
  view along with everything else), per-*pane* watcher. **The pane's existing directory watcher is
  blind to exactly the changes Git status turns on**: `git add` in a terminal, a branch switch, an
  edit in a sibling folder all change what these rows should say while touching nothing under the
  folder on screen — the index and `HEAD` live at the root. So the Git side watches the **root**
  instead, and every pane in that repository coalesces onto the provider's one debounced run. The
  watched root is tracked on the pane, not read back from the tab: a tab switch can leave the tab's
  root unchanged while the pane's watcher was torn down for the other tab (a nil-watcher hole the
  first draft had).
- **The gutter is a *contextual* column** (`Column.isContextual`): a permanently blank "Git" column in
  every folder that isn't a repository — most of them — is clutter, so it exists only inside one,
  sits right after Name, fixed at 20 pt, unsortable (`sortKey` became optional), header "" plus a
  `headerToolTip`. It is **paid for out of the Name column**, never added on top of the table —
  caught by the user on review of the first cut, which appended it and so shoved Size and Date
  sideways on every step into a repository, moving columns they had placed deliberately for a reason
  that has nothing to do with them. Name is the right column to charge because it is already the one
  that absorbs slack (`firstColumnOnlyAutoresizingStyle`); a filename with less room is a truncation,
  not a rearranged pane. (The alternative — drawing the status inside the name cell, VS Code-style —
  was rejected: text colour there is already taken by the mark's bold red and the hidden-file dim,
  and inline rename (F2) replaces that cell's text field with an editable box a badge would have to
  dodge. It would reserve the same 20 pt anyway.) **GOTCHA, and the reason the first fix still
  drifted ~17 pt: `intercellSpacing.width` is 17 pt at this table's `.plain` style, not the 2–3 pt
  the name suggests.** A column costs `width + intercellSpacing`, so the carve must be 37, not 20 —
  established by probing a throwaway `NSTableView` configured exactly like the pane (the same
  measure-don't-assume move as pass 1's `git` probing; the frame returned to its baseline 541.5 only
  once the spacing was included) and read live from the table rather than hardcoded. That is only
  safe because **it never enters a stored layout**: `defaultColumnLayout`
  excludes it and `currentColumnLayout` filters it out, or else every step into a repository would
  look like the user rearranging their columns — and be persisted as such. That same capture also
  **adds the footprint back onto Name**, since while the gutter is installed Name is physically that
  much narrower: storing the carved width would ratchet Name 37 pt smaller on every trip through a
  repository. `applyColumnLayout` lifts the gutter out before the reorder pass and re-installs after:
  that pass moves each stored column to its target index in turn, which drags an unlisted column to
  the far end one move at a time.
  `FileCellView.accentColor` carries the status colour — it outranks the mark's red (a marked
  modified file still shows an orange `M`) and yields to the cursor's emphasized background.
- **BUG the user caught, and the reason the pane has `renderRefresh` at all:** the snapshot-arrived
  path hand-rolled `tableView.reloadData()`, which drops the table's selection — so **crossing a
  repository boundary silently deselected the row**, `..` included. It only ever showed at a
  crossing, because that is the only time the snapshot *changes* (nil ⇄ snapshot); walking around
  inside one repository re-uses it and never reloads. The fix is to stop hand-rolling: an arriving
  snapshot is a live background change like FSEvents or a directory-size total, so it goes through
  `renderRefresh()`, which re-anchors the cursor from the model (the `..` row lives only in
  `cursorOnParentRow`, which the model cannot restore for you) and pointedly does *not* scroll.
  Sobering detail: this was **visible in the pass's own verification screenshots** — every repo pane
  had no highlighted row while the home folder did — and went unnoticed until the user pointed at it.
  A screenshot only verifies what you actually look at.
- **`GitBranchChipView.swift`** — glyph + name + `↑2 ↓1` only when drifted, with a tooltip spelling it
  out. Deliberately **inert**: a click here would be an offer to switch branches, and the only thing
  worse than no Git operations in a file manager is Git operations where a misclick rewrites the
  worktree. It rides *inside* the crumb stack (after the greedy spacer) rather than pinned to the
  bar's edge — `NSStackView` collapses a hidden arranged view, whereas a hidden pinned one keeps
  reserving its width: a branch-shaped hole in the path bar of every folder that isn't a repo.
- GOTCHAS (both recurring, both already on the list): `PathBarView` sat at 496 of the 500-line
  `file_length` limit, so the chip forced splitting the location rendering into
  `PathBarView+Location.swift` — which immediately hit **"Swift `private` doesn't cross files"**
  (`installVirtualLabel` touches the private `crumbStack`), fixed by keeping it beside `installCrumbs`
  and widening only `rebuildCrumbs` to internal. Also swiftlint's `optional_data_string_conversion`
  rejects `String(decoding:as:)` — disabled in place with the reason: the failable initializer it
  prefers answers `nil` for the *whole* output on one non-UTF-8 filename, blanking the column for
  every other row, where lossy decoding costs only that row's key.
+9 app tests → **33** (the hermetic surface: how a branch reads, and the contextual-column invariant;
the subprocess/cache half is non-hermetic and verified live, as with `SMBMounter`). 544 core + 33 app
green, swiftformat + swiftlint-strict clean. **VERIFIED LIVE** against a purpose-built repo holding
every shape at once with a real upstream: the root painted `build` `!` · `deep` `M` (rolled up from a
file **four levels down**) · `scratchdir` `?` (collapsed untracked dir) · `src` `M` (precedence:
modified beats the deleted/renamed/untracked also inside it) · `debug.log` `!`, with `..` blank and
the chip reading `main ↑1 ↓1`; inside `src/`: `added.txt` `A`, `edited.txt` `M`, **`renamed.txt` `R`**
— which proves pass 1's reversed `-z` rename pair end-to-end, since the printed order would have
painted the name that no longer exists — clean files blank, `untracked.txt` `?`. Then **live, with no
navigation**: `git add src/untracked.txt` (an index-only change, nothing under the folder on screen)
flipped `?`→`A`, which is the root watcher earning its existence, and `git checkout -b
feature/live-check` retitled the chip and dropped the arrows. Crossing to **Dirnex's own repo**
re-derived root/snapshot/branch/watcher (`Dev`; `Dirnex` `M`, `DirnexTests` `?`, `DirnexCore` blank —
matching exactly what this pass had touched); leaving for `~/Downloads` took the gutter and chip away;
the right pane never grew a column while the left had one; and the persisted layout after all of that
was still `name`/`size`/`date` alone. Incidental confirmation of a pass-1 decision: this Mac has **no
Homebrew git**, so the CLT candidate is what resolved — and `/usr/bin/git`, excluded as the `xcrun`
shim, is exactly what a naive provider would have spawned. Re-verified after the Name-carve fix: the
Size and Date headers sit at **identical** positions inside and outside a repository (only Name's
sort indicator moves), and four crossings in a row left the stored width at exactly 250.5. Re-verified
after the cursor fix, all four crossings: Cmd+L into a repo keeps the cursor on the first row, Enter
on `..` out of one lands on the folder you came from, and a snapshot landing *on top of* a cursor
parked on `..` (forced by creating an untracked file from a terminal) leaves `..` selected while the
new `?` row appears beneath it.
**NEXT (M6 pass 3):** Finder tags (column, edit from panel, filter chips in search), then the
terminal drawer / size-visualization mode.

Progress (2026-07-15, M6 pass 3 — the Finder-tags core): the pure, tested foundation of the tags
item, the same core-first opener every M4/M5/M6 slice used. Box stays `[ ]` (no column, no editor, no
chip UI — this is the value/parse/read-write half). **Two new `DirnexCore/Services/` files plus one
additive field on `SpotlightQuery`.** Method note, and it paid for itself repeatedly: **the stored
format was probed against real tagged files before any Swift was written** (the pass-1 `git` lesson,
and the pass-7 `SFTPListingParser` rework that came of *assuming* a format). Every claim below was
observed, and the first draft of nearly all of them would have been wrong:
- **`FinderTag.swift`** — `FinderTagColor` (the 8 indices) + `FinderTag` (name + colour, parse/
  serialize) + `FinderTagPayload` (the attribute's binary-plist array). The format is
  `com.apple.metadata:_kMDItemUserTags` = a **binary plist array of `name\ncolourIndex` strings**.
  Traps found by probing: **(a) the colour indices are not Finder's display order** — `FavoriteTagNames`
  reads Red, Orange, Yellow, Green, Blue, Purple, Grey, which looks like the enumeration and is not
  it; the real mapping (0 none · 1 Grey · 2 Green · 3 Purple · 4 Blue · 5 Yellow · 6 Red · 7 Orange)
  was established by letting the system assign each colour itself from a bare name. `Grey` resolves,
  `Gray` does not. **(b) A third field exists in the wild**: passing an already-suffixed `Red\n6` to
  `URLResourceValues.tagNames` makes the system treat the *whole string* as the name and append its
  own lookup, storing `Red\n6\n0` — my own first probe wrote corrupt tags this way and they looked
  right. The system reads such rows back as plain `Red`, so fields past the colour are ignored here
  too. **(c) The colour field is optional** (a bare `Plainname` round-trips), and the system always
  *emits* it, `\n0` included — so we emit what it emits. Identity is the **name, case-insensitively**,
  which is the system's own rule (writing `red` stores `red` but resolves to Red's 6), and matches the
  `SavedSearch`/`ServerConnection` name-as-identity precedent. Malformed rows are skipped and a
  nonsense colour degrades to `.none` rather than dropping the tag — the `GitStatusParser` call: one
  bad row must not blank the cell. Duplicates collapse (the system does **not** dedupe on write).
- **`FinderTagStorage.swift`** — the local xattr read/write, in core beside `ByteComparator` per §2.
  **Why it writes the attribute by hand rather than calling `URLResourceValues.tagNames`, the
  documented API — two independent reasons, either sufficient: (1) its setter is macOS 26+ and
  Dirnex targets 14** (caught by the compiler, not by me); **(2) it cannot express a colour** — it
  takes bare names and looks each up in a global database that a write of ours never registers into,
  so expressing an edit through it strips the colour off every custom tag on the file (probed: after
  storing a purple `Zebra`, `tagNames = ["Zebra"]` writes `Zebra\n0`). A data-loss bug wearing the
  documented API's clothes. The getter is available on 14 but drops colours, so it is no use for a
  column either. The one thing the API does that we then must do ourselves is **keep the legacy
  `com.apple.FinderInfo` label byte in sync** — probed: `tagNames = ["Red"]` leaves Spotlight
  reporting `kMDItemFSLabel = 6` where a raw write leaves 0, and the selection rule is **the last
  *coloured* tag wins** (`[Green, Red]`→6, `[Red, Orange]`→7, `[Zebra, Blue]`→4 skipping the
  colourless) — not first, not lowest. Read-modify-write, since the other 31 bytes are type/creator
  codes belonging to whoever wrote them.
- **`SpotlightQuery.tags`** — the chip's pure half; the file's own header comment had anticipated it
  since M4. One `kMDItemUserTags == "Name"c` clause **per tag, ANDed** (kinds OR because a second kind
  broadens; a second tag narrows — the overlap is what the user is asking for). Only names, because
  only names are indexed. **BUG caught while adding it:** `SpotlightQuery` is `Codable` and persisted,
  so a synthesized decoder would throw on the M4-era saved searches that have no `tags` key — which
  would not fail loudly, it would **empty the user's Searches sidebar on upgrade**. Hand-rolled
  `init(from:)` with `decodeIfPresent`, pinned by a test against a literal legacy payload.
MEASURED, and it decides the app pass's architecture: **one `getxattr` costs ~10 µs, tagged or not →
~1 s across a 100k-row directory**, against M1's 150 ms budget for opening one. So tags must **not**
be folded into `LocalBackend.listDirectory`; the column gets the `GitStatusProvider` treatment — off
main, cached, filled asynchronously. (Per *selection* it is nothing, so editing reads inline.)
+44 tests → **588 core tests** (was 544), the payload suite anchored on a **golden fixture of the
exact bytes macOS wrote** for a real tagged file. `swift test` green, swiftformat + swiftlint-strict
clean; app target untouched (new files + one additive field, so no rebuild needed).
**VERIFIED LIVE** — a harness compiled against the real core wrote tags into a real folder, then
**Finder itself** was the judge: the stock `Red` painted a red dot, a custom **purple `Zebra` + `Blue`
rendered as Finder's two-tone split dot**, a colourless `Work` correctly drew **no** dot and left no
FinderInfo record, an incremental add+remove (case-insensitive) preserved the custom purple, Get Info
listed the names, `kMDItemFSLabel` read **6** where a naive raw write leaves 0, and **Spotlight
indexed our tags** — the exact predicate `SpotlightQuery` builds, run verbatim through `mdfind`,
found the file (the search chip, end-to-end). All artifacts removed after.
**FINDING that shapes pass 4, and the reason to look rather than assume:** mid-verification Finder
**silently rewrote our bytes on disk**, `Zebra\n3` → `Zebra`, stripping a colour. It is not
reproducible on demand and a brand-new name (`Quokka\n7`) is adopted, honoured, and rendered orange
in both the dot and the Get Info chip. The consistent explanation: **a colour belongs to the *name*,
system-wide, not to the file** — the system's name → colour database is authoritative, and Finder
reconciles a file's stored copy against it, so `Zebra`, which my own earlier probes had registered as
colourless, got normalized back. Recorded in `FinderTag`'s doc comment: an editor may offer a colour
when *introducing* a tag, but must not present per-file colour as the user's to own — re-colouring
one file's `Work` is not a change macOS keeps. (Exact trigger not pinned down; it is Finder's
business, and the engineering conclusion holds either way.)
**NEXT (M6 pass 4, the app layer):** a `FinderTagProvider` mirroring `GitStatusProvider` (off-main,
cached, FSEvents-refreshed — the ~10 µs/row measurement is why), the **tag column** (dots, and
contextual-vs-always-on is the open question: unlike Git, tags aren't scoped to a repo, so a
permanently-blank column for people who don't tag would be the Git gutter's mistake in reverse),
**editing from the panel** (a tag menu over the selection, offering the seven stock tags + the names
already in use), and the **filter chips** in the search sheet.

Progress (2026-07-15, M6 pass 4 — the Finder-tags app layer): **the box is closed, VERIFIED LIVE.**
Four new app files, one generalized out of the Git pass, and no core change beyond two catalog
commands — the pass-3 core was already the right shape.

**The open question, answered by the user: a View toggle (`Show Tags`), defaulting on** — not the Git
gutter's contextual rule. The rule was tempting (it is right there, tested, one line to reuse) but its
*justification does not transfer*, which is the whole finding: a repository is a coarse, stable
property of a whole subtree, so the gutter appears once on the way in and stays; tagged files are
**scattered**, so the identical rule would install and remove the column — and re-truncate every
filename, since a gutter is paid for out of Name — on nearly every step between sibling folders. A
precedent is an argument, not a licence. The preference is still ANDed with "could these rows carry
tags at all" (local files, and search hits, which are local files in a virtual pane): inside an
archive or on SFTP the column could only ever be blank, which is what the preference exists to avoid.
The checkmark tracks the *preference*, never that derived state — unchecking the box inside a zip
would blame the user's setting for the filesystem's limits.
- **`PanelViewController+ContextualColumns.swift`** — the Git pass's install/footprint/carve
  machinery, lifted out and generalized, because **a second gutter would have silently broken the
  first**: `currentColumnLayout` reclaimed `gitColumnFootprint` specifically, so with two installed it
  would refund half of what it charged and Name would ratchet narrower on every capture — the exact
  bug the reclaim exists to prevent, just slower. Now sums over all installed gutters. Insertion keeps
  `Column.allCases` order among them (Name │ git │ tags │ Size │ Date) whichever arrives first, so
  installing one never reshuffles another. `Column` gained `headerToolTip` (both gutters are too
  narrow to title).
- **`FinderTagProvider.swift`** — `GitStatusProvider`'s shape (off-main, LRU 8, 300 ms debounce or
  run-now past 2 s stale, serialized per key, published by notification) for the reason the core
  *measured*: ~10 µs per `getxattr` is ~1 s across a 100k-row directory. **What differs and why:** its
  unit of caching is the *repository* because one `git status` answers for a whole tree; there is no
  such command for tags, so the unit is the **directory** and the caller passes the paths. The pane
  passes its **whole listing, not its visible rows** — two panes on one folder can have different
  hidden/filter settings, and a scan of the narrower one would evict rows the other still shows,
  leaving tagged files looking untagged. `knownTagNames` accumulates as you browse (there is no API
  for "the user's tags"; the system's list is Finder's own synced plist, not a contract) and feeds
  both the editor menu and the search completion — verified live: `Urgent`, met in one tab, was
  offered in another. **`FinderTagSnapshot.==` is hand-rolled and must be**: `FinderTag`'s own `==`
  compares names case-insensitively and **ignores colour** — correct for identity, wrong for "did the
  pixels change" — so the synthesized version would answer "equal" when Finder recoloured a tag (which
  pass 3 documented it doing *by itself*) and the column would keep painting the old dot.
- **`PanelViewController+Tags.swift`** — per-tab snapshot, install, row lookup. **No watcher of its
  own, unlike Git**: the Git side had to watch the *repository root* because `git add` in a terminal
  changes what rows say while touching nothing under the visible folder; a tag has no elsewhere — it
  is an attribute **on the file** — so the pane's existing directory watcher already fires for it.
  Verified live (a new file appeared and rescanned with the rest).
- **`TagCellView.swift`** — custom-drawn dots; the content *is* the colour, so it borrows neither
  `FileCellView`'s text field nor the Git letter's `accentColor`. Two judgement calls: a **colourless
  tag draws a hollow ring** where Finder draws nothing — Finder can afford that because its dots sit
  beside the name, so absence reads as "no colour", whereas in a column of its own it would read
  "untagged", a lie about a file the user did tag; and on the cursor's emphasized row every dot is
  **ringed in the selection's text colour**, or a blue tag vanishes into blue.
- **`PanelViewController+TagEditing.swift`** — ⌃T (free; ⌘T is New Tab, and ⌃D/⌃Q are where this app's
  popups already live) drops a menu over the cursor row: stock seven + names in use, `.on`/`.mixed`
  per how many targets carry each, toggle across the selection, New Tag…, Remove All Tags. Targets are
  filtered **per entry** (`.local`), not per pane — which is what lets tagging work from a search
  results tab, and makes a mixed selection tag what it can. **The menu offers a colour only when
  *introducing* a name**, per pass 3's finding that colour belongs to the name system-wide: offering
  per-file colour would be offering an edit macOS silently reverts.
- **Search chips** — an `NSTokenField` (a tag *is* a token; it rounds each name into a deletable chip
  and completes against `knownTagNames`). Read via **`stringValue`, not `objectValue`**: the latter
  holds only *tokenized* chips, so a tag typed without a trailing comma would not merely be dropped
  from the search — with a tag as the only term, `isEmpty` would leave **Find disabled** and the
  search unrunnable. Flagged as a risk while writing, then confirmed live both ways.

**BUG FOUND LIVE, and it is the Git pass's own lesson repeating:** ⌘A-then-⌃T dropped the menu at the
*bottom* of the pane, clipped and scrolling. I had anchored on `tableView.selectedRow` — but marks are
independent of the cursor here, so marking everything leaves the table with **no selected row**,
`selectedRow` answers -1, and the `visibleRect` fallback resolves to the pane's lowest edge (the table
is flipped, so `maxY` is the bottom). Fixed to anchor on the **model's** cursor, which always exists
and is the only source that knows about the `..` row. Same root as pass 2's `reloadData` bug: *the
table is a renderer; the model is the truth.*

**VERIFIED LIVE** end-to-end, with macOS itself as the independent judge on both ends — the fixtures
were tagged by **Apple's own writer** (`URLResourceValues.tagNames`, available on this macOS 26 box
though not on Dirnex's 14 floor) and our writes were read back through **Apple's own getter**, which
saw exactly what we wrote. Confirmed: every dot case (stock, multi, 3-dot cap from five, hollow ring
for a colourless `Quokka`, nothing for untagged, white ring on the cursor row); a tag added from the
menu landing on disk as `Green\n2` with **`kMDItemFSLabel = 2`** — the last-*coloured*-tag-wins rule
pass 3 documented, maintained by our hand-written label; a purple `Milestone` across a 6-file marked
set **preserving the existing `Quokka\n0` verbatim** (the exact data loss `tagNames` would have
caused, which is why the core writes by hand); the mixed `−` state; completion offering a custom name
learned by browsing; the chip narrowing `mdfind` to the one file carrying `Urgent`; **dots in the
results panel and ⌃T working there**; the column vanishing inside a zip with ⌃T greyed out; the
toggle taking both panes live; and **both gutters coexisting in the Dirnex repo itself** (Name │ `M`/`!`
│ dots │ Size │ Date). The layout invariant was checked in the persisted store, not by eye: after
repeated toggles and tab switches Name stayed **exactly 279.5** and no `tags` entry ever entered a
stored layout. 588 core + 33 app tests green, swiftformat + swiftlint-strict clean. Test artifacts
removed. Gotcha, recurring: the 4-line hookup tipped `PanelViewController.swift` to **501/500 lines**
(`file_length`) — paid for by tightening my own comment rather than widening a `private` across a
file split, which is the trap that costs more than it saves.

Progress (2026-07-15, M6 pass 5 — tags in the name cell, and the missing right-click menu): user
review of pass 4 killed the tag *column* outright and asked for Finder's actual arrangement, plus the
context menu the app had never had. Both done, VERIFIED LIVE.

**The column is gone; the dots ride at the right edge of the name.** This is the better design and the
user was right to ask for it, but note what it retires: the whole preference question pass 4 agonized
over (contextual vs always-on vs a toggle) was an artefact of the dots *being a column* — a column
must be present or absent for the whole pane, so it had to be blank for non-taggers or jitter. Inside
the name cell the question dissolves: an untagged row draws nothing and gives its name the full width,
so tags cost exactly the rows that have them. `showTags` survives as a plain on/off (the dots are
still someone's clutter to refuse) and `areTagsVisible` still ANDs in "could these rows carry tags",
but the elaborate justification is gone with the column. **Pass 4's generalization of the contextual-
column machinery went with it** — it existed only to host a second gutter, so `+ContextualColumns` was
deleted and `+Git`/`+Columns` restored verbatim from 42e88f2. A generalization with one client is just
a longer way to write the client. **The Git gutter keeps its column and should**: it is *text*,
competing for the name field's colour with the mark's red and the hidden-file dim, and F2 swaps that
field for an editor — none of which applies to a view that draws its own dots.
- **`TagDotsView`** (was `TagCellView`) — an `NSView` inside `FileCellView`, right-aligned, sized by
  `intrinsicContentSize` so Auto Layout hands the name whatever the dots don't need. The name's
  compression resistance is lowered so a long filename truncates *before* the cluster instead of
  running under it. F2 clears `tags` for the row being renamed (a *hidden* view still holds its
  width, so hiding is not enough) — nothing to restore, since the next render sets them like every
  other recycled-cell property.
- **The layout is Finder's, measured not guessed** — a file tagged `Red, Green, Blue, Yellow` was
  written by the system, opened in Finder and zoomed into, and both findings contradict the obvious
  draft: **the dots run in reverse** (the *last* tag is leftmost and whole, each earlier one peeking
  out behind it to the right — the same last-wins precedence the core found in the legacy label byte),
  and they **overlap by ~two thirds**, so five tags stay a compact cluster. The thin gap between dots
  is punched with `.destinationOut` on the view's **own layer** (hence `wantsLayer`): it erases only
  our dots, so the row's real background shows through — a stroke in a fixed colour cannot work,
  because the background is alternating-or-blue and not ours to know.
- **The context menu** (`PanelViewController+ContextMenu`) — the app had none at all. Built from
  `CommandCatalog` via `MainMenuBuilder.commandItem` (made internal), so a right-click item and its
  menu-bar twin cannot drift; nil targets mean `validateMenuItem` greys them out for free (Paste with
  an empty clipboard, everything mutating inside an archive). Two menus: one over an entry, one over
  the empty space (folder-scoped: New Folder, Paste, Add to Hotlist, Synchronize). **Tags is a
  submenu**, rebuilt on open via `NSMenuDelegate` and sharing ⌃T's item builder (`tagMenuItems`) so
  there is one definition of what the tag menu contains. Right-click **takes focus first** — items
  dispatch through the responder chain, so without it a right-click in the inactive pane would run
  against the other one.
- **Retargeting, and the bug in it (found live).** Marks outrank the cursor here, so right-clicking a
  row *inside* the marked set acts on the set, while right-clicking *outside* it collapses onto that
  one row — else you point at one file and operate on others. My first cut called `syncCursorToTable`
  + `updateChrome`, which updated the footer and the cursor but **not the rows**: the footer said
  "7 items" while five rows still rendered bold red, a menu about to act on one file over a pane
  drawing five as chosen. `renderRefresh` fixes it. Third time this pass has been the same lesson —
  *the model changed, and the table is only a renderer.*

**VERIFIED LIVE:** dots identical to Finder's for 1/2/5-tag files (`report.pdf` [Red, Blue] → whole
blue leading, red sliver behind, exactly like the probe's `two.txt`); a long name truncating with an
ellipsis before its dots; untagged rows drawing nothing; the hollow ring for colourless `Quokka`;
adding Green from the right-click **submenu** and watching it become the new lead dot; the entry menu,
the background menu, Paste correctly greyed; right-click inside the marked set keeping all 7; and
right-click outside it collapsing to the clicked row with **every red mark cleared**. 588 core + 33
app tests, swiftformat + swiftlint-strict clean, artifacts removed.
**NEXT (M6 pass 6):** the terminal drawer, or size-visualization mode — the next two `[ ]` items.

### M7 — Release readiness (M)

- [ ] Sparkle 2 updates + appcast infrastructure; notarized DMG pipeline in CI
- [ ] Full Disk Access onboarding flow (detect, explain, deep-link to System Settings)
- [ ] First-run tour: palette-centric, 5 screens max
- [ ] Performance pass: instruments audit of M1 budgets on real dirty data
      (huge Downloads, node_modules, network volumes, iCloud placeholder files)
- [ ] Crash reporting (opt-in) + anonymized op-failure telemetry decision
- [ ] Docs site: keyboard reference generated from the action registry
- [ ] Private beta → public beta → 1.0

Exit: a stranger can download, pass FDA onboarding, and move files in under 3 minutes.

---

## 5. Cross-cutting: testing strategy

| Layer | Approach |
|---|---|
| DirnexCore | Unit tests against generated fixtures; every operation tested for: success, cancel mid-flight, permission denied, disk full, source mutated during op |
| VFS backends | One shared conformance test suite run against every backend (Local, Archive, SFTP-against-docker) |
| Undo journal | Property tests: op + undo == original tree (compare via content hash) |
| Panels/keyboard | XCUITest smoke for the keyboard core; snapshot tests for panel rendering states |
| Performance | XCTest metrics gated in CI: 100k-dir list < 150 ms, filter keystroke < 16 ms, memory ceiling on huge dirs |

## 6. Risks

| Risk | Mitigation |
|---|---|
| SwiftUI temptation for panels degrades perf later | Decision locked in §2; perf budgets in CI make regressions loud |
| Undo journal correctness (the scariest feature) | Property tests from M2 day one; non-reversible ops explicitly marked in UI, never silently dropped |
| FSEvents refresh fighting the cursor/selection | DirectoryModel diffs snapshots and reapplies cursor by identity, not row index; test with high-churn fixture |
| Archive writes corrupting user data | Always rewrite to temp + atomic swap; never in-place |
| Full Disk Access friction kills onboarding | Dedicated flow in M7; app degrades gracefully (browse home dir) before grant |
| Scope creep before the feel is right | M1 exit criteria are the gate; nothing from M3+ starts until M1 feels great |

## 7. Open questions (decide by end of M1)

- Space key: TC uses it for select+dir-size, macOS muscle memory says Quick Look.
  Current plan: Space = select/size (TC), Cmd+Y and a palette action = Quick Look.
  Validate with real use in M1.
- Quick view panel shortcut (Ctrl+Q vs Cmd+Shift+Q) — Cmd+Q is untouchable.
- Tabs UI: native-style segmented tabs vs compact TC-style. Prototype both in M1.
- Name/brand check for "Dirnex" before public beta (M7).
