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
- [~] Selection model: Space/Insert toggle-and-advance, Cmd+A (mark all), `*` invert done.
      **Space-on-dir in-place size** and **`+`/`-` glob select UI** not yet (glob select exists
      in `Panel`, just unwired).
- [ ] Tabs per panel: new/close/reorder, restored on relaunch
- [x] Path bar: clickable breadcrumbs, Cmd+L to edit as text with completion
- [ ] Volumes/places strip (replaces TC's drive letters); eject
- [x] FSEvents: panels refresh live, preserving cursor and selection
- [x] Quick Look on Cmd+Y (Space stays reserved for selection, per §7); previews the marked
      set or the cursor file, tracks the cursor live
- [ ] Drag out to other apps; drag in = reveal only (real drop lands in M2)
- [ ] Sort/column state per tab, persisted

Progress (2026-07-05): the headless core for this milestone is complete and tested
in `DirnexCore` (38 tests, SwiftLint/SwiftFormat clean) — see `Sources/DirnexCore/VFS/`:
- `LocalBackend` (POSIX `readdir`/`fstatat`; resolves symlink target kind and broken
  links; errno-normalized errors) + `DirectoryModel` (natural-order sort by
  name/size/date/ext, directories-first, hidden toggle, type-to-filter). ✅ first item.
- `Panel` — pure value-type state machine backing one pane: cursor movement, selection
  by identity (Space/Insert toggle-and-advance, Cmd+A, invert, `+`/`-` glob select via
  `fnmatch`), and identity-preserving same-directory refresh (cursor + marks survive a
  live reload). All I/O stays in the caller, so the model is unit-tested headless.

Update (2026-07-05, later): `DirnexCore` is now wired into the app target (local SwiftPM
package) and the dual-pane browser is runnable. `Dirnex/Browser/` holds the thin UI over
`Panel`: `BrowserWindowController` (two panes in an `NSSplitViewController`, active-pane
tracking, Tab focus routing), `PanelViewController` (`NSTableView` data source/delegate,
async directory loads via `DirectoryLoader` off the main thread, cursor⇄table-selection
mirror with loop guard + stale-load token, header-click sort, error sheets), plus
`FileTableView` (TC key model), `FileCellView` (cursor = blue selection, mark = bold red
text), and `FileFormatting`/`FileIconProvider`. Verified live: home dir lists correctly,
active/inactive highlight, sort, marks all render.

Update (2026-07-05, 3rd pass): type-to-filter and Quick Look landed. Printable keys build a
live filter (`FileTableView` → `PanelViewController.setFilter`), status shows `Filter "x"`,
Backspace trims it (then goes up when empty), Esc clears it via `cancelOperation:`, and
entering a directory resets it. Quick Look (Cmd+Y) is in `PanelViewController+QuickLook.swift`
— the pane is the QL controller, previewing the marked set or the cursor file and refreshing
as the cursor/marks move. Verified live: filter narrowing, Backspace edit, Cmd+Y preview.
(Note: Esc couldn't be exercised through the automation harness — synthetic Escape is
swallowed by the OS before reaching the app — but the keyDown path it shares is verified.)

Update (2026-07-05, 4th pass): the path bar landed. `PathBarView` renders clickable
breadcrumbs (one button per ancestor, `›` separators, current crumb bold + accent when
the pane is active) and switches to a text field on Cmd+L — prefilled and selected,
Return navigates, Esc reverts, Tab completes against the child directories of what's
typed (shell-style, cached async so the popup is Tab-triggered, not per-keystroke). Core
support is `VFSPath.ancestorsFromRoot` (root→self crumb chain) and `child(towards:)` (the
one-step-down descendant, so a multi-level crumb jump lands the cursor on the branch you
came from), both unit-tested (`VFSPathTests`, 7 tests). Verified live via computer-use:
breadcrumb rendering + active styling, Cmd+L edit, Tab completion dropdown, and
commit-navigates-and-refocuses. (Crumb *mouse-click* couldn't be exercised — a
LanguageTool overlay covered the path-bar band and the harness gates clicks onto it — but
it reuses the verified `navigate(to:focus:)` path and the unit-tested `child(towards:)`.)

Update (2026-07-05, 5th pass): live FSEvents refresh landed. New
`DirnexCore/…/VFS/DirectoryWatcher.swift` wraps an `FSEventStream` (per-directory,
coalesced by FSEvents' own latency; dispatch-queue scheduled, no run loop) and fires a
payload-free `onChange` — "re-list this directory." The stream holds an *unretained*
pointer to the watcher (a retained one would be a cycle that never stops), so `stop()`
runs from `deinit`; `FSEventStreamInvalidate` drains the queue. Integration-tested
(`DirectoryWatcherTests`, 3 tests, ~60 ms: fires on add, fires across successive
add/remove, idempotent stop). `PanelViewController` owns one watcher, replaced on every
navigation (skipped when the backend lacks `.watch`); the change hops to the main actor,
re-lists, and feeds `Panel.setListing` — which re-anchors cursor/marks by identity — then
renders via a new non-scrolling `renderRefresh()` so a background change never yanks the
user's scroll position. Error-presentation helpers were split into
`PanelViewController+Errors.swift` to keep the controller under SwiftLint's length limits.
Verified live via computer-use: creating/removing a folder in a watched directory updated
both panes instantly (19⇄20 items) and the cursor stayed on "Applications" instead of
jumping to the new top-sorted row. Core suite now 48 tests, all green; app builds; touched
files swiftformat/swiftlint-strict clean.

Remaining for M1: tabs per panel, volumes/places strip + eject, drag-out, per-tab
sort/column persistence, `+`/`-` glob-select UI, Space-on-directory in-place sizing, and a
`..` parent row.

Exit: can live in it for browsing all day; 100k-dir opens < 150 ms warm; scroll never
drops frames; unicode/symlink fixtures render correctly.

### M2 — Operation engine (L)

Goal: TC's killer feature — queued, non-blocking, undoable file operations.

- [ ] `Operation` model + `OperationQueue` actor: concurrent across volume pairs,
      serial per volume pair (no disk thrashing); F2-style "add to queue" vs run now
- [ ] Copy (F5): APFS clone fast path; chunked fallback with per-file + total progress,
      throughput, ETA; preserves xattrs, permissions, dates, Finder tags
- [ ] Move (F6): rename fast path same-volume; copy+delete across volumes
- [ ] Delete (F8): to Trash; Shift+F8 permanent with explicit confirm
- [ ] New folder (F7), inline rename (F2/Enter-on-name)
- [ ] Progress UI: queue bar (as in mockup) + expandable list; pause/resume/cancel per job
- [ ] Conflict engine: policies (ask/overwrite/skip/keep-both/newer-only), "apply to all";
      dialog shows both files' size/date, text diff preview, image thumbnails side by side
- [ ] Undo journal: Cmd+Z reverses move/rename/copy/new-folder; delete-to-Trash restore;
      journal survives relaunch; clear messaging for non-reversible ops
- [ ] Errors: per-file skip/retry/abort, summarized at end, never a modal storm
- [ ] Drop onto panel = real copy/move through the queue
- [ ] Core test suite on fixtures: cancellation mid-copy, permission errors, disk-full,
      source-changed-during-copy

Exit: 50 GB copy runs in background while browsing stays 60fps; yanking a USB drive
mid-copy produces a sane error, not a hang; Cmd+Z after a bad move actually fixes it.

### M3 — Discoverability layer (M)

Goal: fix TC's adoption problem — nobody should need the manual.

- [ ] Cmd+K command palette: fuzzy search over every action, shows shortcuts,
      recents on top; palette actions and menu bar generated from one action registry
- [ ] Directory hotlist (Ctrl+D): pin, reorder, jump
- [ ] Per-panel history (Alt+Down list; Cmd+[ / Cmd+] back/forward)
- [ ] Frecency jump: SQLite-backed visit tracking; path bar accepts fuzzy fragments
      ("dl" → ~/Downloads), zoxide-style scoring
- [ ] Workspaces: save/restore both panels with all tabs, named, switchable from palette
- [ ] Settings window (SwiftUI): general, panels, operations, shortcuts
- [ ] Rebindable shortcuts with conflict detection; TC-compatible preset and macOS preset

Exit: a new user can discover copy/move/hotlist through the palette alone; power user
can rebind everything.

### M4 — VFS payoff (L)

Goal: cash in the VFS abstraction from M0.

- [ ] `ArchiveBackend` via libarchive: browse zip/tar/tgz/7z as folders; copy out with F5;
      pack via F5-with-archive-target; nested archives read-only
- [ ] Archive writes: add/delete inside zip (rewrite strategy, journal-safe temp file)
- [ ] Multi-rename tool: pattern tokens ([N] name, [C] counter, [E] ext, date tokens),
      regex find/replace, case transforms, live preview table, applies as one undoable batch
- [ ] Search (Alt+F7 / palette): mdfind-backed name+content search with filter chips
      (kind, size, date, tag); streamed results; content grep fallback for non-indexed volumes
- [ ] Search results → virtual panel listing: normal cursor/selection/F5 on results
- [ ] Quick view panel (Cmd+Q toggle… verify: likely Cmd+Shift+Q or Ctrl+Q; Cmd+Q quits):
      inactive panel becomes live Quick Look/text preview of the file under cursor
- [ ] Saved searches as virtual folders in the places strip

Exit: open a zip, fish two files out, repack — no temp-folder dance; rename 500 photos
by date pattern and undo it; search feeds a panel.

### M5 — Network and sync (M)

- [ ] `SFTPBackend` (swift-nio-ssh or libssh2): connection manager, keychain-stored
      credentials, key auth; browse/copy through the standard queue with resume
- [ ] Capability degradation: panels grey out unsupported ops per backend (no Trash on
      SFTP → explicit delete confirm; no clone → always chunked)
- [ ] Synchronize directories: two-panel diff view (left-only / right-only / differs /
      same), by size+date or content hash; selective sync actions through the queue
- [ ] Compare by content: byte compare + FileMerge/Kaleidoscope/BBEdit handoff for diffs

Exit: mirror a local folder to a server over SFTP, verify with sync-dirs, all queued
and pausable.

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
