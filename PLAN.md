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

- [~] `SFTPBackend`: connection manager, key auth; **browse DONE and verified live** (via the
      system `sftp` CLI, not swift-nio-ssh/libssh2 — the same sidestep M4 made with `bsdtar`).
      Remaining: byte transfer (copy-out/-in through the standard queue with resume),
      keychain-stored password auth
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
and pausable.

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

### M6 — Mac-native power features (M)

- [ ] Git awareness: branch in path bar, status column (M/A/?/ignored) via a debounced
      `git status --porcelain` provider; optional .gitignore-aware folder sizes
- [ ] Finder tags: column, edit from panel, filter chips in search
- [ ] Terminal drawer: bottom pane following active panel's cwd; "cd sync back" via
      shell integration snippet; open in iTerm/Terminal/WezTerm as alternative
- [ ] Size visualization mode: toggle panel to ncdu-style bars, computed async, cached
- [ ] Share sheet, "Open With" submenu, Services integration
- [ ] Automation: AppleScript/Shortcuts verbs (reveal, copy, run-op); user actions —
      shell scripts receiving selection as argv/env, surfaced in palette and F-key bar
- [ ] iCloud/provider sync-status column (NSFileManager ubiquity attrs where available)

Exit: git repo browsing shows live status; a user-defined "convert to webp" script on
selection runs from the palette.

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
