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

Update (2026-07-05, 6th pass): the `..` parent row landed. Every non-root directory now
shows a synthetic `..` at the top (folder icon, Enter/double-click goes up landing on the
directory you came from). It lives entirely in the UI — `Panel` never sees it — so item
counts, marks, sizing and glob-select stay clean; the table simply has one extra row at
non-root paths and all row⇄entry mapping goes through helpers in
`PanelViewController+ParentRow.swift` (`parentRowCount`, `entryIndex(forRow:)`,
`row(forEntryIndex:)`). The `..` is never counted, never markable (Space on it just
advances), and stays visible under any type-to-filter — so a filter that hides every entry
leaves `..` as the one row and Enter still walks up. To stay under SwiftLint's file/type
length limits the controller was decomposed further: `+Table` (data source/delegate),
`+Chrome` (path bar/status/sort indicators), `+ParentRow`, joining the existing `+Errors`
and `+QuickLook` (the main file is now 443 lines; `panel`/`isSyncingSelection`/
`reloadEverything` widened to internal so those same-type extensions compile). Verified
live via computer-use: `..` at the top of non-root dirs, absent at `/`, Enter-up lands on
the child you came from, count excludes it, and the filter-empty→Enter-up case works.

Update (2026-07-05, 7th pass): tabs per panel landed. Each pane now owns an array of
`PanelTab`s (a `PanelTab` = the value-type `Panel` — directory/cursor/marks/sort/filter —
plus the two UI bits kept outside it: `cursorOnParentRow` and a lazy-load flag) and renders
whichever is active; `PanelViewController.panel`/`cursorOnParentRow` became computed forwards
to the active tab, so every existing `panel.…` call transparently targets it. A new
`TabBarView` (chips with an accent-filled active tab, per-chip close ✕, a `+`, click-select
and drag-reorder) sits above the path bar and auto-hides at a single tab. Keyboard/menu:
Cmd+T new, Cmd+W close (closing the last tab closes the window), Cmd+Shift+[ / ] switch —
driven by a new File menu + Window-menu items whose nil-target actions dispatch through the
responder chain to the focused pane (`PanelViewController+Tabs`); Window ▸ Close Window moved
to Cmd+Shift+W. Tabs restore on relaunch via `TabPersistence` (boring JSON in UserDefaults,
per §2), including **per-tab sort** (`FileSort.Key` raw values were already documented as the
on-disk format); a restored tab whose directory has vanished is dropped so launch never lands
on a dead path. Switching to a tab renders its stored state instantly, then background-refreshes
(it went unwatched while inactive); a never-loaded (freshly restored) tab loads from scratch.
Files: new `PanelTab`, `TabBarView`, `TabPersistence`, `PanelViewController+Tabs`; edits to
the controller (multi-tab storage + init restoration + tab-bar layout), `+Table` (sort now
persists), `BrowserWindowController` (per-side restoration keys), `AppDelegate` (File/Window
menus). App builds clean (no warnings); DirnexCore untouched (still 48 tests green); touched
files swiftformat/swiftlint-strict clean. Verified live via computer-use (keyboard-driven):
Cmd+T reveals the bar with a second tab of the same dir, each tab holds its own directory,
Cmd+Shift+[ / ] switch both ways preserving per-tab state, Cmd+W closes and re-hides the bar,
the active chip accents only in the focused pane, and a relaunch restored both panes (left
`[oleg, Downloads]` active-index 1, right `[oleg]`) with per-tab sort. GOTCHA (unchanged): the
LanguageTool-for-Desktop overlay still gates every mouse click on the Dirnex window onto
itself, so chip click-select, the `+`/✕ buttons, and drag-reorder are unverified-live — but
they route through the same `selectTab`/`addTab`/`closeTab`/`moveTab` exercised via keyboard.
Also: the harness didn't deliver the Command modifier with arrow keys (`Cmd+Up` acted as plain
Up), unrelated to tabs.

Update (2026-07-05, 8th pass): the volumes/places sidebar landed. A native source-list
sidebar (`NSSplitViewItem(sidebarWithViewController:)`, vibrant + collapsible) leads the two
panes and drives whichever is active. Its two sections come from new headless core
`DirnexCore/…/VFS/Places.swift` (`SidebarLocations.favorites()` / `.volumes()`, Foundation
only, no AppKit): **Favorites** = the standard home folders that actually exist on disk (Home
always first, then Desktop/Documents/Downloads/Pictures/Music/Movies + /Applications, in
Finder order), **Volumes** = browsable mounted volumes via `mountedVolumeURLs` (root
filesystem pinned first, then by name; `canEject` = removable/ejectable and never root).
Unit-tested (`PlacesTests`, 6 tests: favorites lead with Home, skip missing subfolders,
keep declared order; volumes always include a browsable root that sorts first and can't
eject; `canEject` follows the media flags). The app layer is a thin renderer:
`SidebarViewController` (a `.sourceList` `NSTableView` of header/place/volume rows, real
`NSWorkspace` folder/drive icons, group-row headers, capacity tooltips) + `SidebarCellView`/
`SidebarHeaderView`; a row click routes through `SidebarViewControllerDelegate` to
`BrowserWindowController`, which navigates the active pane and hands focus back to it.
Ejectable volumes carry an eject button (`NSWorkspace.unmountAndEjectDevice`, errors surfaced
in a sheet); the list live-rebuilds on `NSWorkspace` mount/unmount/rename notifications,
keeping the selection on the same path. Added View ▸ Show Sidebar (Cmd+Ctrl+S) via
`NSSplitViewController.toggleSidebar` through the responder chain. Core now 54 tests green;
app builds clean; touched files swiftformat/swiftlint-strict clean. Verified live via
computer-use: Favorites render with native icons; clicking Downloads navigated the active
(left) pane while the right pane stayed put; Tab-then-click retargeted the right pane to
Desktop; the Volumes section listed Macintosh HD (drive icon, no eject on root); clicking it
navigated to `/`; the hover tooltip read "456,51 GB available of 2 TB"; and Cmd+Ctrl+S
collapsed then re-showed the sidebar. (Eject itself is unexercised — no removable media was
mounted — but the `canEject` gating is unit-tested and the workspace eject call is a
one-liner.)

Update (2026-07-05, 9th pass): the `+`/`-` glob-select UI landed, wiring the already-tested
core (`Panel.selectMatching`/`deselectMatching` over `Glob`/`fnmatch`) into the pane. New
`Dirnex/Browser/PanelViewController+Select.swift` owns the AppKit shell: a wildcard prompt
(`NSAlert` + text field) that *adds* to (`+`) or *removes* from (`-`) the marks, prefilled
with the cursor file's extension so "mark every JPEG" is `*.jpg` + Return. The gesture binds
to the **numeric keypad's** `+`/`-` (`FileTableView` keyCodes 69/78) rather than the main-row
keys, so a bare `-`/`+` keeps reaching the type-to-filter (both are common filename
characters); the character-typing path is untouched. A new **Select** menu (Invert Selection,
Select by Pattern…, Unselect by Pattern…) gives the same commands a mouse/laptop path — its
nil-target actions dispatch through the responder chain to the focused pane, like the tab
menus; no key equivalents, so nothing steals `+`/`-` from the filter. `fileTableInvertMarks`
was refactored to share the menu's `invertMarks()` helper. App builds clean (no warnings);
DirnexCore untouched (still 54 tests green); touched files swiftformat/swiftlint-strict clean.
Verified live via computer-use (keyboard-driven, since the LanguageTool-for-Desktop overlay
still gates every mouse click on the window — menus were driven via Ctrl+F2 menu-bar focus):
in a fixture dir, Select ▸ Select by Pattern opened prefilled `*.jpg` and marked both JPEGs
("2 of 7 selected"); a second `*.txt` select was additive (4 of 7), proving select never
clears; Unselect ▸ `*.jpg` removed only the JPEGs, leaving the two `.txt` marks (2 of 7). All
three menu items validated enabled through the responder chain; the Unselect dialog showed the
right title/button. GOTCHA: the keypad `+`/`-` keys themselves are unexercised-live (no numpad
on this machine / the harness has no keypad token), but they call the identical
`promptForPatternSelection(deselect:)` the menu items do.

Update (2026-07-05, 10th pass): Space-on-directory in-place sizing landed, completing the
**Selection model**. New headless core `DirnexCore/…/VFS/DirectorySizer.swift` recursively
totals a subtree by walking a `VFSBackend` — iterative (explicit stack, no recursion depth
limit), symlinks counted by their own size and never followed (a cycle can't wedge it),
unreadable subdirectories skipped rather than fatal, and cancellable. Computed totals live in
`DirectoryModel.directorySizes` (keyed by entry identity, pruned to present entries on refresh)
and layer on top of the pure-stat `FileEntry`: `computedSize(of:)` drives the size column
(dash → byte total) and `effectiveByteSize(of:)` feeds both the selection total and size-sort
(an unsized directory counts as 0; a file as its own size). `Panel.setDirectorySize` forwards
cursor-preserving, since a size can reorder rows when sorting by size. In the app, Space on a
directory now (besides the existing mark-and-advance) kicks off a background walk via a new
`DirectoryLoader.size` bridge (`.utility`, off-main); `PanelViewController+Sizing` applies the
result — guarded by `loadToken` + path so a total that resolves after the user navigated away or
switched tabs is discarded — and re-renders without scrolling. Files: new `DirectorySizer`,
`PanelViewController+Sizing`; edits to `DirectoryModel`, `Panel`, `DirectoryLoader`,
`FileFormatting`, `PanelViewController` (+Table/+Chrome and the Space handler). Core now 66
tests green (+12: `DirectorySizerTests` flat/nested/empty/symlink-cycle/cancel/missing, plus
model computed-size + Panel cursor-preservation); app builds clean; touched files
swiftformat/swiftlint-strict clean. Verified live via computer-use (keyboard-driven, since the
LanguageTool-for-Desktop overlay still gates every mouse click on the window): in a fixture dir
whose `bigdir` holds 3,145,728 bytes across two files, Space on it marked it (bold red) and the
status line jumped to "1 of 3 selected · 3,1 MB"; Space on the empty `emptydir` added 0, holding
the total at "2 of 3 selected · 3,1 MB". (The size *column* value itself is unverified-live —
the pane was too narrow to show it and the overlay gates every widen/scroll — but it renders
through the same unit-tested `computedSize(of:)` the status total does.)

**Drag-out**. A file pane is now a drag *source* (PLAN.md §M1 "drag out to other apps"):
`PanelViewController+Drag.swift` adds `pasteboardWriterForRow:` (each row → its file URL as an
`NSURL`; `nil` for the synthetic `..` row so it can't be dragged) and advertises a copy-only
source mask (`setDraggingSourceOperationMask(.copy, forLocal: false)` — external drags copy and
can never move/delete the original; local pane-to-pane drops advertise nothing since real
drop-in lands in M2, so no drag types are registered for receiving). Total Commander semantics:
`draggingSession:willBeginAt:forRowIndexes:` widens the drag to the whole **marked set** when the
grab starts on a marked file (the table is single-selection, so AppKit only offers the one cursor
row) — a grab on an unmarked file drags just that file. Files: new `PanelViewController+Drag`;
one-line hook in `PanelViewController.configureTable`. To keep the controller under SwiftLint's
`--strict` file/type-body limits (it had drifted 12 lines over `file_length` and 4 over
`type_body_length`), the three navigation helpers (`openCurrentEntry`/`goToParent`/
`handleDoubleClick`) moved to a new `PanelViewController+Navigation.swift` (main file 512 → 486);
whole repo is `swiftformat --lint` + `swiftlint --strict` clean again. App builds clean. Verified
live via computer-use (LanguageTool overlay quit for the session so window mouse events land):
dragging the unmarked `alpha.txt` from a pane to a Finder window copied just it; marking `beta`+
`gamma` (status "2 of 3 selected · 29 bytes") then dragging the single `beta` row copied **both**
into Finder — confirmed on disk.

Update (2026-07-06, 11th pass): per-tab **column** width/order persistence landed — the
last M1 feature item. A pane keeps one `NSTableView` shared across its tabs, so switching
tabs now swaps the table's column geometry in and out: `PanelTab` gains a `columnLayout`
(`[ColumnLayout]`, display-order + width, UI-only like `cursorOnParentRow`), `PersistedTab`
gains an optional `columns` (missing key → `nil` → default columns, so state written before
this field decodes untouched), and a new `PanelViewController+Columns.swift` owns the shell:
`applyColumnLayout(for:)` (reorders the known columns into the stored order via
`moveColumn`, then sets each width; guarded by `isApplyingColumnLayout` so its own
resize/move notifications aren't recaptured), `captureColumnLayout()`, and a
`columnDidResize`/`columnDidMove` observer that records the active tab's geometry and
`persistState`s it — skipping no-op posts via `ColumnLayout: Equatable` so window
autoresizing doesn't churn the disk. `activateTab` applies the active tab's layout;
`addTab` inherits the current one; `restoredTabs` threads `columns` through. To stay under
SwiftLint's `file_length`, the `Column` enum (now also carrying `defaultWidth`/`minWidth`,
the single source for `configureTable` and the fallback layout) moved into the new file.
App builds clean (no warnings); DirnexCore untouched; touched files
swiftformat/swiftlint-strict clean; app test target green. Verified live via computer-use:
an injected left-pane layout `[date, name, size]` rendered with **Date Modified** first on
launch while an old-format right pane (no `columns` key) rendered the default **Name**-first
order (decode + reorder + backward-compat in one shot); dragging the left pane's **Name**
header to the front then quitting persisted `[name, date, size]` to disk with widths intact,
while the untouched right pane stayed `columns: nil` (capture→persist + per-pane
independence). GOTCHA (unchanged): the LanguageTool-for-Desktop overlay again gated every
window click until quit for the session.

**M1 feature checklist is now complete.** The only outstanding M1 work is the exit *gate*
itself — the perf measurements (100k-dir < 150 ms warm, no dropped frames), deliberately
deferred to the M1 exit gate / M7 perf pass per the M1 panel-view note above.

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
- [ ] Conflict engine: up-front ask/overwrite/skip/keep-both ✅ + newer-only ✅; "apply to
      all" and the rich dialog (size/date, text diff, image thumbnails) still pending
- [x] Undo journal: Cmd+Z reverses move/rename/copy/new-folder + delete-to-Trash restore ✅;
      journal survives relaunch (JSON in UserDefaults) ✅; overwrites marked non-reversible and
      surfaced ✅ — reversal logic + property tests in `DirnexCore/…/UndoJournal.swift`
- [ ] Errors: failures collected + summarized ✅; per-file skip/retry/abort still pending
- [x] Drop onto panel = real copy/move through the queue ✅ (pane-to-pane, into a
      subfolder, or from Finder; Finder's copy-vs-move conventions; routed through the
      shared queue via the same `submitTransfer` as F5/F6)
- [x] Core test suite on fixtures: cancellation mid-copy ✅, conflicts ✅, cross-volume ✅,
      symlink ✅, permission errors ✅, disk-full ✅, source-changed-during-copy ✅

Progress (2026-07-06, M2 pass 1): the write layer + the "instant" operations landed —
New Folder and Delete, the ops that finish immediately and so don't need the (still to
come) progress queue. Copy/Move/queue/progress/conflict/undo are the next passes.

- **Core write primitives.** `VFSBackend` grew four write methods —
  `createDirectory` / `moveItem` / `removeItem` / `trashItem` — with default
  implementations that throw `.unsupported`, so a read-only or future backend compiles
  untouched and the panel greys the op out via `capabilities` (§M5). `LocalBackend`
  implements them on POSIX where the errno matters (`mkdir`, `rename`) and `FileManager`
  where it's the right tool (recursive `removeItem`, `trashItem` returning the resulting
  Trash location for a future undo-restore); a `mapCocoaError` helper recovers the POSIX
  errno Cocoa tucks under `NSUnderlyingErrorKey`. New `VFSError.alreadyExists` (EEXIST/
  ENOTEMPTY) feeds the M2 conflict engine later. `DirnexCore/…/Tests/LocalBackendWriteTests`
  adds 13 tests (create over-existing / missing-parent, rename, cross-dir move, recursive
  tree delete, trash-and-return-location, and the read-only-backend `.unsupported`
  contract) — core suite now **79 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring** (`Dirnex/Browser/PanelViewController+FileOps.swift`, new). New Folder
  prompts for a name (prefilled, `/`-rejected), creates off-main, refreshes, and lands the
  cursor on the new folder by identity. Delete targets the **marked set over the cursor**
  (TC), runs off-main collecting per-item failures in a `Sendable` shape, then clears
  marks and re-lists: F8/Cmd+Delete → Trash (no prompt, recoverable, Finder-parity);
  Shift+F8/Cmd+Shift+Delete → permanent with an explicit critical confirm. Both carry
  Total Commander's F-keys in a new File-menu section *and* answer to Finder's Cmd combos
  in `FileTableView` (Cmd+Shift+N / Cmd+Delete / Cmd+Shift+Delete); `validateMenuItem`
  disables the delete items when nothing is deletable. `+Errors.describe` was generalized
  (now internal, handles `.alreadyExists`) and reused for op-failure sheets. App builds
  clean (no warnings); app smoke test green.
- **Verified live via computer-use** (menu-driven — the automation harness still doesn't
  deliver the Command modifier, confirmed via a no-op Cmd+T, so shortcuts were exercised
  through the File menu, which dispatches the same responder-chain actions): New Folder
  created `zzz-created-folder`, cursor landed on it, count 4→5, present on disk; Move to
  Trash removed it (recoverable — confirmed by `stat`-ing the returned `~/.Trash` path,
  since a non-FDA shell can't *list* `~/.Trash`); a marked pair (status "2 of 4 selected ·
  14 bytes") trashed leaving the unmarked cursor file; Delete Immediately showed the
  "can't be undone" confirm then permanently removed a file (absent from Trash) and,
  separately, a non-empty subtree (recursive), parking the cursor on `..` at 0 items.

Progress (2026-07-06, M2 pass 2): the copy/move engine landed — F5 Copy and F6 Move,
the byte-moving heart of M2. The headless engine is fully tested; the app is a thin
progress shell over it.

- **Core engine** (`DirnexCore/…/Operations/`, new group per §2's architecture).
  `FileOperation` (kind = copy/move, a source set → a destination directory) +
  `ConflictPolicy` (fail/skip/overwrite/keepBoth) + `OperationProgress`/`OperationReport`
  value types. `CopyEngine.run(…)` is a synchronous entry point (like `DirectorySizer` —
  the caller picks the thread) that transfers each source by the fastest path the backend
  offers: an **APFS clone** of the whole subtree same-volume (`clonefile`, instant, metadata
  preserved), falling back to a **chunked recursive copy** across volumes (1 MiB `read`/
  `write` loop with per-chunk progress + cancellation, symlinks recreated not followed,
  directory metadata carried over via `copyfile(COPYFILE_METADATA)`). Move takes the
  same-volume `rename` fast path and falls back to copy-then-delete on `EXDEV`. Overwrite
  writes to a temp sibling then swaps, so a half-finished copy never destroys the file it
  replaces; keepBoth generates "name copy.ext". Progress is throttled (≥ 8 MiB or an item
  boundary) so a 50 GB copy doesn't flood the caller. New `VFSBackend` primitives —
  `cloneItem` (returns `false`, not throwing, when CoW isn't possible so the engine falls
  back), `copyFile`, `createSymbolicLink`, `copyMetadata` — all defaulted (unsupported /
  no-op) so other backends compile untouched; `LocalBackend` implements them on POSIX.
  Tests: `CopyEngineTests` (14) + `LocalBackendCopyTests` (6) cover clone/tree/file copy,
  same- and cross-volume move (via a `CrossVolumeBackend` that forces `EXDEV`), all four
  conflict policies, cancel-mid-stream (partial file unlinked), progress reaching the full
  total, and the no-clone chunked fallback + symlink duplication (via a `NoCloneBackend`).
  Core suite now **99 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring** (`Dirnex/Browser/PanelViewController+Copy.swift` + `OperationProgressSheet.swift`,
  new). F5/F6 target the marked set over the cursor (TC) and land in the *other* pane's
  directory (new `PanelHost.panelCounterpart(of:)`). Colliding names are detected off-main
  and resolved once, up front, via a four-way prompt (Overwrite / Keep Both / Skip / Cancel)
  whose choice becomes the whole operation's `ConflictPolicy`. The engine runs on a detached
  task; progress streams back over an `AsyncStream` to a cancellable sheet (Cancel trips
  `Task.cancel()`, which the engine polls via `Task.isCancelled`). Both panes re-list after,
  and marks clear (matching the delete flow). New File-menu items carry TC's F5/F6 with the
  `.function` mask, dispatched through the responder chain like the other pane actions;
  `deletionTargets()` was generalized to `selectionTargets()` and shared. App builds clean
  (no warnings). **Verified live via computer-use** (pre-seeded both panes at a fixture via
  the tab-persistence defaults, then drove the File menu): copying the `subdir` directory
  cloned it recursively into the other pane (`subdir/nested.txt` on disk) with the source
  untouched; moving `alpha.txt` removed it from the source and landed it in the destination,
  the cursor advancing to the next row; re-copying `subdir` raised the conflict prompt, and
  **Keep Both** produced a full recursive `subdir copy`. GOTCHA: this pass resolves conflicts
  once up front (a single policy for the whole op) — the per-file interactive dialog with
  side-by-side sizes/dates and thumbnails, plus the multi-operation queue actor and undo,
  are the next M2 passes.

Progress (2026-07-06, M2 pass 3): inline rename (F2) landed — the last "instant"
operation, editing the name in place rather than moving bytes (app-target only;
`DirnexCore` untouched, still 99 tests). Total Commander semantics: rename acts on the
single cursor entry (never the marked set — that's M4's multi-rename tool — never `..`).

- **App wiring** (`Dirnex/Browser/PanelViewController+Rename.swift`, new). The name cell
  becomes a real editable `NSTextField` in place: `FileCellView.beginNameEditing`/
  `endNameEditing` flip the label between edit and label appearance, and the table's
  `viewFor` (in `+Table`) builds the cell editable when its entry matches the new
  `renamingEntryID`. `beginRename` reloads that one row, makes the field first responder,
  and preselects the **base name** Finder-style so typing keeps the extension. KEY GOTCHA:
  the base-name selection must be set right after `makeFirstResponder`, NOT in
  `controlTextDidBeginEditing` — that notification fires on the first *edit*, not on focus,
  so a selection set there lands a keystroke too late (verified live: it consumed the
  `.txt`). CORRECTNESS: same-dir rename goes through `moveItem` → `rename(2)`, which
  silently *overwrites* an existing file (unlike New Folder, which `mkdir` guards with
  EEXIST), so the flow pre-checks the destination off-main and throws `.alreadyExists`
  rather than clobber — while allowing a case-only change ("foo" → "Foo", same inode on
  case-insensitive APFS). Commit lands the cursor on the renamed entry by its new
  identity via `refreshCurrentDirectory(selecting:)`; an empty/unchanged name is a silent
  no-op; Esc aborts (`control(_:doCommandBy:)` → `cancelOperation:` → `renameWasCancelled`
  → revert). File-menu **Rename…** carries F2 with the `.function` mask, responder-chain
  dispatched like F5–F8, and `validateMenuItem` disables it on `..`/empty/no-rename
  backends. App builds clean, swiftformat/swiftlint-strict clean, app smoke test green.
- **Verified live via computer-use** (no LanguageTool overlay this session, so mouse +
  keyboard both worked; seeded the left pane at a fixture via the tab-persistence
  data-blob): the File ▸ Rename… item and the F2 key both opened the inline editor;
  `alpha.txt` + typing `renamed` produced `renamed.txt` on disk (extension preserved,
  content intact); the cursor landed on the renamed row; renaming onto an existing
  `taken.txt` was **refused** with "already exists here" and the target file was NOT
  clobbered (content + source both intact — the `rename(2)` guard); commit-on-Return and
  the unchanged-name no-op both behaved. GOTCHA (unchanged from prior passes): the
  harness's synthetic Escape is swallowed by the OS before reaching the app, so the
  Esc-cancel path is correct by inspection but unverified-live.

Progress (2026-07-06, M2 pass 4): the operation-queue actor landed — the scheduler
that sits above the single-shot `CopyEngine` and turns it into TC's queued, non-blocking
background engine. Core-only (`DirnexCore`); the app isn't wired to it yet (that's the
queue-bar / drop-through-queue pass), so it's tested-but-dormant, matching how the engine
landed before its app shell.

- **Core scheduler** (`DirnexCore/…/Operations/FileOperationQueue.swift` +
  `QueueSnapshot.swift`, new). A `public actor` — named `FileOperationQueue` only to dodge
  `Foundation.OperationQueue` — that owns a FIFO of jobs (`FileOperation` + `ConflictPolicy`)
  and runs each through `CopyEngine.run` on a detached task, so the actor itself only
  bookkeeps and never blocks on I/O.
  - **Volume-aware scheduling.** Each job's volume set = every source's volume ∪ the
    destination's, resolved via a new `VFSBackend.volumeIdentifier(for:)` (defaulted `nil`
    = "one volume, serialize"; `LocalBackend` returns the `st_dev` of the nearest existing
    ancestor, following symlinks). `pump()` greedily launches the first waiting job whose
    volumes are disjoint from every running job's — so same-disk jobs serialize (no head
    thrashing) while independent disks run concurrently, FIFO within a volume. A
    `maxConcurrent` cap (default 8) backstops many-volume machines.
  - **Pause/resume that actually parks running transfers.** A per-job `JobControl`
    (`NSCondition`-backed, `@unchecked Sendable`) is handed to the engine as its
    `isCancelled` hook via `checkpoint()`: it reports cancellation *and*, while the queue is
    paused, blocks the copy thread between chunks until resume or cancel. So pause halts new
    dispatch *and* freezes in-flight copies — with zero changes to `CopyEngine`, which
    already polls `isCancelled` between chunks/items.
  - **Cancel** one job (waiting → dropped pre-start; running → engine unwinds through its
    normal cancel, partial file cleaned up, reports `wasCancelled`) or `cancelAll()`.
  - **Live progress.** `observe()` fans out an `AsyncStream<QueueSnapshot>` (current state
    immediately, then on every change); `snapshot()` is the one-shot read; `waitUntilIdle()`
    suspends until drained. `AggregateProgress` rolls up bytes across jobs and derives
    throughput + ETA from the average rate since the batch started moving (clock injected
    for testability); still-waiting jobs count 0 bytes, so the total is an estimate early
    and exact once nothing's waiting.
- **Tests** (`FileOperationQueueTests`, +7 → core suite **106**, all green;
  swiftformat/swiftlint-strict clean; app still builds). Scheduling is made deterministic by
  a `GatedBackend` whose clone blocks in a test-controlled rendezvous (not a sleep-race):
  serial-per-volume (only one of two same-volume jobs runs, the second starts only once the
  first is released), concurrent-across-volumes (two disjoint-volume jobs reach the gate at
  once), pause-halts-dispatch (+ a running job flips to `.paused`, and a newly-enqueued
  independent-volume job stays put until resume), cancel-waiting (never enters the gate, no
  report), cancel-running (via a `BlockingCopyBackend` that spins on the cancel hook →
  `wasCancelled`), single-job happy path, and the `observe()` stream. GOTCHA for the next
  pass: the queue is headless and unused by the app — F5/F6 still run the standalone
  `CopyEngine` behind the single-op sheet; routing them (and drag-drop) through this queue,
  plus the queue-bar UI, is the wiring pass.

Progress (2026-07-06, M2 pass 5): the `newer-only` conflict policy landed — TC's
"overwrite older", closing one of the two named conflict-engine gaps ("apply to all" +
the rich dialog remain). Core-only decision site: `ConflictPolicy.newerOnly` (new case)
resolves in `CopyEngine.resolveConflict`, which now captures the existing destination's
`stat` and replaces it only when `source.modificationDate > existing.modificationDate`,
else skips (equal counts as not-newer → skip). It reuses the existing temp-sibling
overwrite plan (factored into a shared `overwritePlan(at:name:)`), so the atomic-swap
safety is unchanged; the comparison is on the top-level item's own mtime, so a directory
is replaced wholesale when *its* mtime is newer (a per-file merge is a later pass). The
app's F5/F6 conflict prompt gains an **Overwrite If Newer** button (appended before Cancel
so the existing overwrite/keep-both/skip response mappings are untouched; the 4th button's
response code is derived from `.alertThirdButtonReturn + 1`). Tests: the conflict-policy
matrix moved out of `CopyEngineTests` into a focused `CopyEngineConflictTests` suite (kept
the growing file under SwiftLint's `type_body_length`), which adds 3 `newerOnly` cases
(replaces-older / keeps-newer / skips-equal) on top of the existing four; a new
`TempTree.setModificationDate` helper stamps mtimes deterministically. Core suite now
**109 tests**, all green; app builds clean; touched files swiftformat/swiftlint-strict
clean. Not yet verified live (headless + a menu-button wiring; the engine path is fully
unit-covered). GOTCHA for the next pass: newer-only is exposed only through the up-front
single-policy prompt — it'll want re-surfacing per-file once the rich "apply to all"
dialog lands.

Progress (2026-07-06, M2 pass 6): the app is now **wired to the operation queue** — the
dormant `FileOperationQueue` from pass 4 is live, and F5/F6 run through it behind a
non-blocking, window-bottom queue bar instead of the old modal progress sheet (which is
deleted). This is the pass that makes copies TC-style background work.

- **Core** (`FileOperationQueue`): one small addition, `clearFinished()` — drops terminal
  (finished/cancelled) jobs, leaving waiting/running/paused ones. The aggregate rolls up
  *all* known jobs, so without this a later batch would inherit the bytes of jobs already
  done and its bar would start part-full; the app calls it once the queue drains. To stay
  under SwiftLint's `type_body_length` (the addition pushed the actor body to 252 > 250 —
  recurring gotcha), the snapshots/observation/aggregate methods moved to an
  `extension FileOperationQueue` in the same file (still actor-isolated). Tests +2 →
  **111 core** (clearFinished resets the aggregate; keeps a still-running job).
- **App.** One shared `FileOperationQueue` lives on `BrowserWindowController`, keyed off
  the same `LocalBackend` both panes use (so volume-aware scheduling works). New
  `PanelHost.enqueue(_:conflictPolicy:)` is fire-and-forget; `PanelViewController+Copy`
  keeps the up-front conflict prompt (Overwrite / Keep Both / Skip / Overwrite If Newer /
  Cancel) then hands the operation to the queue and clears its own marks. The window
  controller drains `queue.observe()` for the window's lifetime (task cancelled in `deinit`;
  `[weak self]` + per-iteration re-bind avoids pinning the window alive) and, per snapshot:
  shows/collapses the bar, re-lists **both** panes as each job reaches a terminal state
  (dedup'd via a `finalizedJobs` set), surfaces failures, and `clearFinished()`s on drain.
  New `QueueBarView` (own file) renders from a `QueueSnapshot` and knows nothing of the
  actor: "Copying X" + determinate bar + "done of total · rate/s · ETA left", a pause/resume
  toggle (SF Symbol flips play↔pause; drops rate/ETA while paused), and cancel-all. Layout:
  a container VC stacks the split view over the bar; the bar collapses to zero height and
  hides when idle. `OperationProgressSheet.swift` deleted. App builds clean, whole repo
  `swiftformat --lint` + `swiftlint --strict` clean.
- **Verified live via computer-use** (no LanguageTool overlay this session — mouse worked;
  seeded both panes at a fixture via the tab-persistence data-blob, and mounted a 6 GB APFS
  disk image as a *second volume* so cross-volume copies take the chunked byte-path and the
  bar lingers): a same-volume clone of `big.bin` was instant (bar flashed, dest refreshed);
  a 3.67 GB cross-volume copy of `huge.bin` showed the bar live — "Copying huge.bin",
  determinate bar, "1.84 GB of 3.67 GB · 1.27 GB/s · 1s left" — with browsing fully
  responsive, then dest auto-refreshed and the bar collapsed; the file was byte-exact on
  disk. **Pause** froze the transfer at 1.74 GB (identical across a 2 s gap — genuinely
  parked, not just relabelled), flipped the button to play, and dropped rate/ETA;
  **resume** finished it, byte-exact (pause/resume didn't corrupt). The conflict prompt
  also surfaced correctly on a re-copy, showing all five options incl. "Overwrite If Newer".
  (Cancel-all button is core-unit-tested — cancel-waiting/cancel-running — and renders; not
  clicked live. Move/F6 uses the identical enqueue path and was verified live in pass 2.)
  GOTCHA (tooling): a same-volume APFS clone is O(1), so the bar flashes too fast to catch
  across model round-trips — to observe it you need a real cross-volume (chunked) transfer,
  and to land an interactive pause/cancel click you must do it *inside one computer_batch*
  (server-side, no round-trip latency) or the sub-3 s transfer finishes first.

Progress (2026-07-06, M2 pass 7): drop *in* landed — dragging files onto a pane is now a
real copy/move through the shared queue, the receiving half of pass 11's drag-*out*
(app-target only; `DirnexCore` untouched, still 111 tests). Files can arrive from the
other pane, from the same pane onto a subfolder, or from an external app (Finder).

- **App wiring.** `configureDragging` (`PanelViewController+Drag`) now also
  `registerForDraggedTypes([.fileURL])` and widens the *local* drag-source mask from `[]`
  to `[.copy, .move]` (external stays `.copy`-only, so a drag out can never move/delete the
  original). New `PanelViewController+Drop.swift` implements the receiving
  `NSTableViewDataSource` drop methods. A single `dropPlan(_:row:dropOperation:)` — computed
  identically in `validateDrop` (for the cursor badge + row highlight) and `acceptDrop`
  (for the real work) — resolves: the **destination** (a directory row released *on* → into
  that folder, incl. the `..` row → move up a level; else the pane's current dir, with the
  whole pane highlighted via `setDropRow(-1, .on)`); the **kind** (Finder conventions:
  Option forces copy, Command forces move, else move within a volume / copy across volumes,
  read from `NSDragOperation` + `NSEvent.modifierFlags` since a *local* drag's source mask
  ignores modifiers; same-volume decided cheaply via `volumeIdentifier` on the first
  source); and two **guards** — reject a no-op (every dropped item already lives in the
  destination, e.g. a pane's own files onto its own background) and reject a folder dropped
  onto itself or into its own subtree (would recurse). `acceptDrop` returns `true`
  immediately, then off-main `stat`s the dropped URLs into `[FileEntry]` and hands them to
  the **shared** `submitTransfer(kind:sources:destination:)` — factored out of
  `PanelViewController+Copy`'s F5/F6 flow (which now calls it and only clears its own marks
  when it returns `true`, preserving the exact cancel-at-prompt behavior). So conflict
  handling, progress (queue bar), and the both-panes refresh are identical to F5/F6; a drop
  also makes the target pane active (focus-follows-drop). App builds clean; whole repo
  swiftformat/swiftlint-strict clean; app smoke test green.
- **Verified live via computer-use** (no LanguageTool overlay this session — mouse worked;
  seeded both panes at a `~/dropfix-verify/{left,right}` fixture via the tab-persistence
  data-blob; manual drags = `left_mouse_down` → several `mouse_move`s → dwell →
  `left_mouse_up`, all in one `computer_batch`): dragging `alpha.txt` left→right defaulted
  to a **move** (gone from left, present in right, byte-exact); dragging the `subdir` folder
  onto the right pane's `target` **folder row** highlighted that row green mid-drag and moved
  `subdir/nested.txt` recursively *into* `right/target/`; dropping a colliding `beta.txt`
  raised the shared **conflict prompt** (all five buttons incl. Overwrite If Newer), and
  **Keep Both** produced `beta copy.txt` while preserving the destination's original
  `beta.txt` — all confirmed on disk. GOTCHA: Option=copy and the cross-volume copy default
  are correct by inspection but unverified-live — this harness can't hold a modifier across a
  synthetic manual drag, and the machine has only one browsable volume (would need a mounted
  disk image, as in pass 6). NEXT M2: rich per-file conflict dialog ("apply to all"), undo
  journal, expandable per-job queue-bar list.

Progress (2026-07-06, M2 pass 8): copy/move engine test hardening — closed the three
failure-mode gaps PLAN §5 mandates for every operation but the happy-path/conflict suites
never reached: **permission denied**, **disk full** (`ENOSPC`), and **source mutated
during the op**. Core-only (`DirnexCore`); no production code changed. New
`CopyEngineFailureTests` (7 tests → core suite **118**, all green;
swiftformat/swiftlint-strict clean). The safety theme: a failed item is *collected* and
the op carries on, a failed copy never deletes the source it was moving or the destination
it was overwriting, and a half-written file is never left behind.

- **Test double.** One `FaultBackend` wrapper generalizes the `NoCloneBackend`/
  `CrossVolumeBackend` pattern (block clone → force the chunked path; report `EXDEV`;
  fail `copyFile` for chosen sources; run a side effect just before a copy to mutate the
  source under the engine), so out-of-space and permission conditions are injected
  deterministically rather than needing a real full/locked volume — the same call the
  existing suites make for `EXDEV`.
- **Coverage.** permission-denied on one source is collected while the others still copy
  (+ a real `chmod 000` source, `getuid`-guarded, so the POSIX `EACCES → .permissionDenied`
  mapping is covered end to end); a disk-full copy during a **cross-volume move keeps the
  source**; a disk-full **overwrite keeps the existing destination and leaves no temp
  sibling** (the atomic-swap guarantee); a **mid-file cancel unlinks the partial**
  destination (the real `LocalBackend.copyFile` close+unlink path, which the prior
  cancel-before-work test never reached); a **vanished source** is recorded as `.notFound`
  and the op continues; a source **appended-to mid-copy is copied in full** (the engine
  streams to EOF, not to the pre-scanned length).
- GOTCHA surfaced (not fixed — production behavior left untouched): on the **clone** fast
  path `LocalBackend.cloneItem` maps *every* `clonefile` errno to `path: destination`, so a
  vanished/unreadable **source** surfaces as an error about the **destination** path
  (`.notFound(dest/x)` not `.notFound(src/x)`). The `.alreadyExists` (EEXIST) attribution is
  correctly destination-side and the app relies on it, so the test asserts the failure
  *case*, not the incidental path. A minor diagnostic-message inaccuracy worth revisiting
  when the rich conflict/error dialog lands.

Progress (2026-07-07, M2 pass 9): the undo journal landed — Cmd+Z reverses the five
reversible operations and delete-to-Trash restore, and the journal survives relaunch. Undo
is "the scariest feature" (§5), so the byte-touching reversal lives in `DirnexCore` under
property tests; the app is the thin shell that records completed ops and drives `revert`.

- **Core** (`DirnexCore/…/Operations/UndoJournal.swift`, new). An `UndoRecord` is a
  user-facing label + a list of inverse `UndoStep`s (`restore(from:to:)` /
  `removeCopy` / `removeCreatedFolder`) + a `nonReversibleCount`. `UndoJournal` is a bounded
  newest-on-top stack (`record`/`removeTop`, capacity 50); `UndoJournal.revert(_:using:)` is
  the executor — it refuses to clobber a reoccupied original, protects a New-Folder undo when
  the user has since filled the folder, and (for a cross-volume move) reverses copy-then-delete
  through `CopyEngine`. The copy/move builder reads the **engine's new per-item outcomes**:
  `CopyEngine` now records each top-level source's landing path + whether it overwrote, added
  as `OperationReport.outcomes` (`OperationItemOutcome`); `UndoRecord.transfer` turns a copy
  into `removeCopy`s, a move into `restore`s, and an **overwrite into a counted, non-reversible
  item never silently deleted**. `VFSPath`/`VFSBackendID` gained `Codable` (routing decode
  through the normalizing init) so records persist. New `UndoJournalTests` (13) prove the
  headline property `op + undo == original tree` for copy/move (incl. cross-volume)/rename/
  New-Folder/Trash-restore, plus the overwrite/skip/clobber/capacity/JSON-round-trip edges —
  **core suite 131 tests**, all green; swiftformat/swiftlint-strict clean.
- **App wiring.** New `UndoController` (per window on `BrowserWindowController`) owns the
  journal, persists `records` as JSON in `UserDefaults` (matching `TabPersistence`; the plan's
  SQLite earns its keep once undo shares the M3 frecency DB), and runs `revert` off-main.
  New Folder / rename / Trash record through a new `PanelHost.recordUndoableAction`; copy/move
  record in `BrowserWindowController+Queue` as their queue jobs finish (so drag-drop is covered
  for free). A new **Edit ▸ Undo (Cmd+Z)** dispatches through the responder chain to the focused
  pane's `undoLastOperation` → the window's controller; `validateMenuItem` sets the live title
  ("Undo Move") and **steps aside for an active field editor** so inline-rename/path-bar typing
  keeps its own undo (a disabled item lets `performKeyEquivalent` fall through). A less-than-clean
  undo (non-reversible parts, or a step that couldn't apply) raises a summary sheet; a clean one
  is silent. App builds clean; app smoke test green.
- **Verified live via computer-use** (menu- and Cmd+Z-driven; the Command modifier came through
  this session): seeded a two-file fixture into both panes. **Move** alpha→right then Edit ▸
  Undo (menu showed "Undo Move") restored it byte-exact; **New Folder** then **Cmd+Z** removed
  the empty folder; **Move to Trash** then **Cmd+Z** restored alpha from the Trash; and — the
  relaunch test — a move, graceful quit, relaunch (journal reloaded, menu still read "Undo
  Move"), Cmd+Z reversed it. Every step confirmed on disk. NEXT M2: rich per-file conflict
  dialog ("apply to all"), expandable per-job queue-bar list, per-file skip/retry/abort.

Progress (2026-07-07, M2 pass 10): the queue bar's **expandable per-job list** landed —
the last open piece of §M2's Progress-UI line (app-target only; `DirnexCore` untouched,
still 131 tests). The compact aggregate row gained a disclosure chevron; expanding it
reveals a scrollable list of one row per in-flight/waiting job — verb + item name, its own
determinate progress bar, a byte readout, and a per-job cancel button — all rendered from
the `QueueSnapshot.jobs` the window already receives, so there was **no core change**
(the per-item data was published back in pass 4).

- **App wiring.** New `QueueJobRowView` (own file) renders a single `JobSnapshot`.
  `QueueBarView` grew a disclosure header over a bottom `NSScrollView` + vertical
  `NSStackView` list; it reconciles rows against each snapshot (a fast path updates the
  existing rows in place when the job set/order is unchanged, else it rebuilds) and reports
  a dynamic `preferredHeight` (collapsed 42 → header + up to 5 rows, more scroll) through a
  new `onPreferredHeightChanged` callback so `BrowserWindowController` grows/shrinks the
  window-bottom band. A per-row cancel routes through a new `onCancelJob` → the window's
  `cancelJob(id)` → `queue.cancel(id)` (the actor's existing per-job cancel from pass 4).
  The job-list-height constraint drives the internal layout — the header fills the fixed
  top band above the scroll area — so the collapsed/hidden case is identical to the prior
  bar. App builds clean; touched files swiftformat/swiftlint-strict clean; app test target
  green; launching the built binary showed **no Auto Layout conflicts** (collapsed layout
  verified). NOT yet driven live in the UI: expanding the list *during* an in-flight
  transfer needs the pass-6/7 cross-volume disk-image setup to keep the bar on screen long
  enough — the collapsed-layout launch check passed and the per-job data path is the one
  pass 6 already verified live. NEXT M2: rich per-file conflict dialog ("apply to all") and
  per-file skip/retry/abort (both need the engine to yield control mid-operation).

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
