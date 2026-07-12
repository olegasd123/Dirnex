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

Progress (2026-07-07, M2 pass 11): the **rich per-file conflict dialog with "apply to
all"** landed — the last open piece of §M2's conflict engine. The engine now *yields
control mid-operation* (the recurring blocker the prior passes flagged): instead of a
single up-front policy, F5/F6/drop enqueue under a new `ConflictPolicy.ask` and the engine
calls back into the app per colliding item, so the user resolves each conflict against a
side-by-side comparison.

- **Core** (`DirnexCore`, +7 tests → **138**). `ConflictPolicy` gained `.ask`; new value
  types `ConflictContext` (the operation kind + the incoming `source` and the `existing`
  destination `FileEntry`) and `ConflictResolution` (overwrite / overwriteIfNewer / skip /
  keepBoth / **cancel** = abort the whole op). `CopyEngine.run` takes an optional
  `resolveConflict: @Sendable (ConflictContext) -> ConflictResolution`; when the policy is
  `.ask` and a destination is occupied, it calls the resolver **synchronously on the copy
  thread** (never for a non-colliding source) and maps the answer onto the existing
  temp-swap / keep-both / newer-only plans — `.cancel` throws `CancellationError`, unwinding
  through the same path as a mid-copy cancel (`wasCancelled`, already-done items kept). A
  missing resolver degrades to `.fail` (never clobbers). `FileOperationQueue.enqueue`
  threads the resolver into the job and on to `CopyEngine.run`. New `CopyEngineAskTests`
  cover each resolution, "only colliding sources ask", cancel-aborts-the-batch, and the
  no-resolver fallback. The engine's serial top-level processing means the resolver is
  called one conflict at a time, so "apply to all" is a pure caller concern (see below).
- **App** (`Dirnex/Dialogs/`, new group per §3). `ConflictPrompter` (`@unchecked Sendable`,
  one per enqueued op) is the bridge: the engine's copy-thread callback blocks on a
  `DispatchSemaphore` while a `Task { @MainActor }` runs `ConflictDialog.present`, then reads
  the answer back across the semaphore — the same background-parks-on-a-primitive shape the
  queue already uses for pause (`JobControl.checkpoint`), so no `CopyEngine` change was
  needed. A ticked **"Apply to all remaining conflicts"** stores a sticky `ConflictResolution`
  (touched only on the single copy thread) that answers every later conflict without a
  prompt — scoped to that one operation, like TC's "Overwrite all". `ConflictDialog` is an
  `NSAlert` sheet with a `ConflictComparisonView` accessory: two cards (New vs. Already here)
  each showing a **Quick Look thumbnail** (`QLThumbnailGenerator`, images preview / text a
  content peek; falls back to the workspace icon), name, size-or-"Folder", and modification
  date with the **newer item's date tinted**; buttons Replace / Keep Both / Skip / Replace If
  Newer / Cancel + the suppression checkbox. `PanelViewController+Copy.submitTransfer` was
  rewritten to build a prompter and enqueue with `.ask` (dropping the old up-front
  detect-then-single-prompt); `PanelHost.enqueue` / `BrowserWindowController+Queue` grew the
  resolver parameter; drag-drop is covered for free (it already routes through
  `submitTransfer`). App builds clean; whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (seeded both panes at a `~/conflict-verify/{left,right}`
  fixture where every name collides, left files newer): copying `report.txt` raised the rich
  dialog — both cards with thumbnails (the QL previews even showed the file text), "19 bytes
  · 01.07.2026 · newer" tinted vs. "5 bytes · 01.01.2026", the queue bar parked at "Copying
  re…" behind it — and **Replace** overwrote it byte-exact leaving `notes.txt` untouched, no
  temp detritus; marking **both** files then **Apply to all + Replace** overwrote both from a
  **single** dialog (no second prompt); **Keep Both** produced `report copy.txt` while keeping
  the original. Backgrounding the app mid-dialog left the copy thread parked (no crash, no
  deadlock) and the sheet resumed on refocus. GOTCHA: full side-by-side text *diff* is still
  deferred — the thumbnails cover the common visual case; per-file skip/retry/abort remains
  the last conflict-adjacent M2 item.

Progress (2026-07-07, M2 pass 12): **per-file skip/retry/abort on errors** landed — the last
open item of §M2's Errors line. The engine now *yields on failure* the same way pass 11 made it
yield on conflict: instead of always collecting a failed source and moving on, it hands the
error to a resolver that can Retry the item, Skip it, or Abort the whole op.

- **Core** (`DirnexCore`, +6 tests → **144**). New value types `OperationErrorContext` (op kind +
  failing `path` + `VFSError`) and `ErrorResolution` (retry / skip / abort). `CopyEngine.run` gained
  an optional `onError: @Sendable (OperationErrorContext) -> ErrorResolution`; `transfer` was
  refactored into an `attempt`-and-retry loop that, on a caught `VFSError`, rolls back the failed
  attempt's partial bytes (so a retried copy never double-counts) and consults `onError`: `.retry`
  re-runs the source, `.skip` collects the failure and continues (**the default when no resolver**,
  so every existing failure test and unattended run is unchanged), `.abort` unwinds like a mid-copy
  cancel (`wasCancelled`, no failure appended — the user already saw it). `FileOperationQueue.enqueue`
  threads `onError` into the job and on to the engine. The conflict-resolution helpers moved to a
  `private extension CopyRun` to keep the class under `type_body_length`. New `CopyEngineErrorTests`
  cover skip-collects-and-continues, retry-after-transient-fault (asserting bytes tallied once),
  retry-N-times-then-skip, abort-unwinds, abort-keeps-earlier-work, and the no-resolver default,
  driven by a `MutableFaultBackend` that fails `copyFile` for a chosen name a fixed number of times.
- **App** (`Dirnex/Dialogs/`). New `ErrorPrompter` (sibling of `ConflictPrompter`: same
  copy-thread-parks-on-a-`DispatchSemaphore` bridge, an "apply to all" that is sticky **only for
  Skip** — a sticky Retry would spin forever, Abort ends the op) and `ErrorDialog` (`NSAlert` sheet,
  Retry [default] / Skip / Abort + a suppression checkbox, message from a shared `VFSErrorText`
  extracted out of `PanelViewController.describe`). `PanelHost.enqueue` /
  `BrowserWindowController+Queue.enqueue` / `submitTransfer` gained the `onError` parameter, so F5/F6
  **and** drag-drop all raise it. The window's end-of-op `reportFailures` summary still fires for the
  Skip case; Abort stays silent (empty failures). Whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (a `~/dirnex-err-verify/{src,dst}` fixture with `dst` chmod
  `0555` so a copy into it hits EACCES): F5 of `payload.txt` raised "Couldn't copy 'payload.txt'"
  with the permission text, the apply-to-all checkbox, Retry/Skip/Abort, and the queue bar parked at
  "Copying payload.txt · Zero KB of 13 bytes" behind it. **Retry** after `chmod 0755`-ing `dst`
  mid-sheet (the copy thread was parked) completed byte-exact (`cmp` IDENTICAL). **Abort** on a
  re-locked `dst` was silent — no summary, queue bar gone, nothing copied. **Skip** collected the
  failure and surfaced the end-of-op "Couldn't copy 'other.txt'" summary. **§M2's Errors line is now
  `[x]`.** Deferred: sub-item granularity (an error deep in a recursive directory copy still fails the
  whole top-level source, not the individual child) and a full text diff in the conflict dialog.

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

Progress (2026-07-08, M3 pass 1): the **action registry + Cmd+K command palette** landed —
M3's headline, and the piece the rest of M3 leans on. The registry is one headless source
of truth; both the menu bar and the palette are generated from it, so they can't drift.

- **Core** (`DirnexCore/…/Services/`, new group per §2). `Command` (stable dotted `id` +
  title + `CommandCategory` + search `keywords` + optional `CommandShortcut`) is a pure value
  type — no AppKit. `CommandShortcut` carries a display token + a modifier `OptionSet` and
  renders a macOS glyph string (`⌘Z`, `⇧F8`, `⌘↑`; the `fn` layer is never drawn).
  `CommandCatalog.all` is the ordered registry of ~22 commands (the whole current menu surface
  incl. F5/F6/F2/F7/F8, tabs, undo, select-by-pattern, sidebar, Quick Look, Go-to-Location,
  Go-Up, window/app). `CommandMatcher.search` fuzzy-ranks for the palette: fzf-lite subsequence
  scoring (word-boundary + consecutive-run + prefix bonuses, gap penalty), title preferred over
  a keyword-only hit, empty query → registry order with **recents floated on top**, recency as
  the tie-break; returns matched title offsets for highlighting. New `CommandCatalogTests` /
  `CommandMatcherTests` / shortcut-display tests (+16 → **core suite 164**), all green,
  swiftformat/swiftlint-strict clean.
- **App.** `Dirnex/Palette/` = `CommandBinding` (the join table: command `id` → AppKit
  `Selector`, every one dispatched to `nil` so it rides the responder chain to the focused
  pane / key window / app exactly as a menu item does), `CommandShortcut+AppKit` (token →
  key-equivalent scalar incl. F-keys/arrows + modifier mask), `CommandRecents` (newest-first
  ids in `UserDefaults`, capped, registry-filtered), and the palette itself:
  `CommandPaletteController` (a floating `NSPanel`; a large search field stays first responder
  and drives the result `NSTableView` from `control(_:doCommandBy:)` — ↑/↓ move, ⏎ runs, ⎋
  closes; picking a command records it recent, dismisses, re-keys the browser window, then
  `NSApp.sendAction(_:to:nil)` on the next tick so the action lands on the pane, not the closed
  palette) + `CommandPaletteRowView` (category tag · title with matched chars bold · shortcut).
  New `MainMenuBuilder` rebuilds the whole menu bar from `CommandCatalog` + `CommandBinding`
  (app owns only the per-menu layout/separators; titles/shortcuts/actions all come from the
  registry) — the hand-built menu in `AppDelegate` is gone; a new **Go** menu (Go to Location,
  Go Up) joins File/Edit/Select/View/Window. Three thin `@objc` wrappers
  (`PanelViewController+Commands`: Quick Look / edit-location / go-parent) expose the previously
  keyboard-only actions to the registry; `validateMenuItem` disables Go Up at a backend root.
  ⌘K is owned by `AppDelegate.showCommandPalette` (toggles). App builds clean; whole repo
  swiftlint-strict clean; app smoke target green.
- **Verified live via computer-use**: ⌘K opened the palette (empty resting state, correct
  ⌘T/F5/F2/⇧F8/⌘Z glyphs + category tags); "gotoloc" fuzzy-narrowed to **Go to Location…**
  with "Go to Loc" bold; ↓↓ moved the highlight; ⏎ dispatched to the **focused** pane (Go to
  Location opened its path-bar editor; a separate "newtab" run added a 2nd tab to the left
  pane) — proving the close→re-key→responder-chain path; reopening floated the just-run
  commands to the top (**recents persist across relaunch**); the reused field clears on reopen
  (fixed a stale-query bug caught live); ⌘K toggles the palette closed and a click into the
  window dismisses it; the File menu is fully registry-generated (right separators + F-keys)
  and ⌘T/⌘W still fire. GOTCHA (unchanged from M1/M2): synthetic ⎋ is swallowed by the OS
  before reaching the app, so ⎋-to-close is correct-by-implementation but unverified-live —
  the ⌘K-toggle and click-away dismissals cover it. NEXT M3: hotlist (Ctrl+D), per-panel
  history, frecency jump, workspaces, Settings, rebindable shortcuts (the registry's
  `CommandShortcut` is already the data those last two will edit).

Progress (2026-07-08, M3 pass 2): the **directory hotlist (Ctrl+D)** landed — TC's pinned-
folder popup, the second M3 item. Pin / jump / reorder all work, and the whole thing hangs
off the same command registry as pass 1.

- **Core** (`DirnexCore/…/Services/Hotlist.swift`, new). A pure value type: `HotlistEntry`
  (user-editable `name` + `VFSPath`, `Codable`, identity = path) and `Hotlist` (ordered,
  de-duplicated-by-path list) with `add` (append unless already pinned → no-op, returns
  whether added), `remove(path:)`/`remove(at:)`, `rename(path:to:)`, `move(from:to:)`
  (Array-semantics reorder), and `contains`. Decoding routes through the de-duping init so a
  legacy/corrupt store is sanitized on load. No AppKit, no persistence — the app owns those,
  matching `Panel`/`SidebarLocations`/the command registry. `CommandCatalog` gains two
  navigation commands: `go.hotlist` ("Directory Hotlist…", ⌃D) and `go.addToHotlist` ("Add
  to Hotlist", palette-only). New `HotlistTests` (+10 → **core suite 174**), all green;
  swiftformat/swiftlint-strict clean. GOTCHA (recurring): a `mutating` call can't live inside
  `#expect(...)` — the macro captures the receiver as immutable — so `add`/`remove` results
  are hoisted into a `let` first ([[swift-testing-expect-optional-arithmetic]]-adjacent).
- **App.** `HotlistStore` (UserDefaults JSON, one app-wide list, read fresh each menu open —
  no live-observation plumbing, like `TabPersistence`/`CommandRecents`).
  `PanelViewController+Hotlist` owns the pane-relative actions dispatched through the
  responder chain: `showHotlist` pops an `NSMenu` from the path bar's bottom edge (one item
  per pin with a Finder folder icon + a bare 1–9 accelerator, then Add/Remove-Current-Folder
  toggle + Organize…); `addToHotlist` pins the current dir; a jump reads the target off the
  item's `representedObject` (index-shift-proof) and, for a vanished `.local` pin, offers to
  unpin it instead of dropping onto a load-failure sheet. `HotlistOrganizerController` (new)
  is the reorder editor — an `NSViewController` sheet (`presentAsSheet`, self-retaining) with
  a drag-reorderable, inline-renameable, `−`-removable `NSTableView`; every edit saves to the
  store immediately. `CommandBinding`/`MainMenuBuilder` wire the two commands into the Go
  menu; `validateMenuItem` disables ⌃D while a text field is first responder so it falls
  through to the field editor's delete-forward. App builds clean; touched + new files
  swiftformat/swiftlint-strict clean (pre-existing repo-wide `op`/`st` `identifier_name`
  strict failures in UNTOUCHED `UndoJournalTests`/`LocalBackend` flagged as a separate task,
  not this pass's).
- **Verified live via computer-use** (no overlay this session — mouse + keyboard worked;
  drove the Go menu since it's the registry surface): the Go menu shows "Directory Hotlist…
  ⌃D" + "Add to Hotlist"; Add pinned `/Users/oleg` then `/Users/oleg/Downloads`; the ⌃D
  popup dropped under the path bar showing both with folder icons + 1/2 accelerators and the
  toggle correctly reading "Remove Current Folder" (current dir pinned); picking **oleg**
  jumped the active pane there; the organizer inline-renamed `oleg`→"Home Folder" (persisted,
  confirmed in UserDefaults), drag-reordered Downloads above Home Folder (persisted), and the
  `−` button removed the selected entry; the list survived an app relaunch. GOTCHA (caught +
  fixed live): the first organizer drag no-op'd and left a collapsed row — `.gap` feedback
  plus a too-strict `validateDrop` (source-identity check + `.above`-only) rejected the drop;
  switching to a pasteboard-type check, retargeting `.on`→`.above`, and dropping `.gap` made
  reorder land first try. Test pins cleared after (defaults delete) so no test state left in
  the user's app. Deferred to later M3: per-panel history, frecency jump, workspaces,
  Settings, rebindable shortcuts.

Progress (2026-07-08, M3 pass 3): **per-panel history** landed — the third M3 item and
the browser-style back/forward trail each tab keeps. Cmd+[ / Cmd+] walk it, Alt+Down pops
the visited-directory list; all three hang off the same command registry as passes 1–2.

- **Core** (`DirnexCore/…/Services/NavigationHistory.swift`, new). A pure value type — the
  browser tab-history model: `entries: [VFSPath]` oldest→newest + a `currentIndex`, seeded
  with the tab's starting path so it's never empty. `visit(path)` records a fresh navigation
  (drops the forward entries, appends, points current at the tip) but **no-ops when the path
  equals the current one** (a refresh, or the initial load landing on the seed, never bloats
  the trail); `back()`/`forward()` only move the cursor and return where to go (`nil` at an
  edge); `jump(to:)` lands on an arbitrary entry (the Alt+Down popup) without truncating;
  `canGoBack`/`canGoForward` drive menu enablement. Bounded (default 100), trimming the oldest
  while shifting `currentIndex` so it keeps pointing at the same path. No AppKit/persistence —
  session-scoped, the app owns the tab that stores it (frecency's *persistent* visit tracking
  is the next M3 item). `CommandCatalog` gains three nav commands: `go.back` (⌘[), `go.forward`
  (⌘]), `go.history` ("Directory History…", ⌥↓). New `NavigationHistoryTests` (+9) + catalog
  presence/shortcut-display cases (+2) → **core suite 185**, all green; swiftformat/
  swiftlint-strict clean.
- **App.** `PanelTab` gains a `NavigationHistory` seeded at its path. `navigate(to:…)` grew a
  `recordHistory: Bool = true` flag and records the visit on *successful* load (a vanished dir
  never pollutes the trail); back/forward/jump navigate with `recordHistory: false` so walking
  the trail doesn't rewrite it. New `PanelViewController+History` owns the pane-relative
  actions dispatched through the responder chain: `goBack`/`goForward` step the active tab's
  trail, `showHistory` pops an `NSMenu` from the path-bar edge (matching the ⌃D hotlist popup)
  listing the entries **newest-first, current check-marked, folder icon + tooltip path**, a
  pick → `jump`. `CommandBinding`/`MainMenuBuilder` wire all three into the Go menu (a new
  Back/Forward/History group above Go-to-Location); `validateMenuItem` disables Back/Forward
  at the trail edges and steps ⌥↓ aside for a first-responder text field (like ⌃D). Cmd+[ /
  Cmd+] / ⌥↓ ride the menu key-equivalent path, so no `FileTableView` key-model change was
  needed (plain ↑/↓ still move the cursor — the modifiers don't collide). App builds clean;
  app test target green; whole repo swiftformat/swiftlint-strict clean. (`PanelViewController.swift`
  is now exactly at SwiftLint's 500-line `file_length` limit — a further edit there wants a
  decomposition pass, like `+Table`/`+Chrome` before it.)
- **Verified live via computer-use** (no overlay this session — mouse + keyboard both worked;
  navigated the real tree through a `~/history-verify/alpha/x` fixture): the Go menu showed
  Back ⌘[ / Forward ⌘] **greyed at a fresh single-entry history** and Directory History… ⌥↓
  enabled; navigating oleg→history-verify→alpha→x then **⌘[** stepped x→alpha→history-verify
  and **⌘]** returned →alpha (keyboard equivalents fire through the responder chain); **⌥↓**
  dropped the popup listing x / ✓alpha / history-verify / oleg (newest-first, current
  check-marked, home-folder icon on oleg); clicking **oleg** jumped straight there and left
  **Back disabled / Forward enabled** — proving the jump preserved the full trail; then a fresh
  navigate to Downloads **truncated the forward entries** (the popup collapsed to ✓Downloads /
  oleg). Deferred to later M3: frecency jump, workspaces, Settings, rebindable shortcuts.

Progress (2026-07-08, M3 pass 4): **frecency jump** landed — the fourth M3 item, TC has no
equivalent; it's the zoxide-style "type a fragment, land in the right folder" the path bar
gains. Persistent visit tracking + fuzzy resolution, hanging off the same `navigate` and
Cmd+L path bar the earlier passes built.

- **Core** (`DirnexCore/…/Services/Frecency.swift`, new). Pure value types: `FrecencyEntry`
  (path + `rank` + `lastAccess`, `Codable`, identity = path) and `Frecency` (the index,
  de-duplicated by path). `visit(_:now:)` bumps a directory's rank (or inserts at 1) and
  stamps the time, then **ages** — zoxide's algorithm: once the summed rank exceeds `maxAge`
  (default 10,000) scale every rank by `0.9·maxAge/total` and drop entries below 1, so the
  index is self-bounding no matter how long the app runs. `score(for:now:)` is rank × a
  recency multiplier (within the hour 4×, day 2×, week ½×, older ¼×; a future/skewed stamp
  falls into the most-recent bucket). `matches(for:now:)`/`bestMatch` filter to entries whose
  **last path component** is a case-insensitive subsequence of the query ("dl" ⊆ "downloads")
  then sort by score, most-recent, then path — so a folder opened twice this morning beats one
  opened ten times last month. Decoding routes through the de-duping init (legacy/corrupt
  store sanitized; a pre-`maxAge` blob gets the default). New `FrecencyTests` (+13 → **core
  suite 198**): insert/bump, the four recency buckets incl. clock-skew, recency-beats-raw-
  frequency, `dl→Downloads`, last-component-only matching, case-insensitivity, aging-drops-
  below-1, de-dup, and JSON round-trip incl. the legacy-without-`maxAge` case. All green;
  swiftformat/swiftlint-strict clean. GOTCHA per §2: the plan pencils **SQLite** for frecency;
  landed as JSON in `UserDefaults` like the undo journal did (the index is self-bounded by
  aging, so JSON's rewrite-per-visit cost is a non-issue) — SQLite still deferred to when undo
  shares the DB. `CommandCatalog` `go.editLocation` gained keywords (jump/frecency/fuzzy/
  recent) so the palette surfaces it.
- **App.** New `FrecencyStore` (`@MainActor`, one app-wide `.shared` instance held in memory —
  unlike `HotlistStore`'s read-per-open, because visits stream in continuously from every
  navigation and separate per-window copies would clobber each other): loads the index once,
  `recordVisit` bumps + persists (JSON in `UserDefaults` `Dirnex.frecency`), `rankedMatches`
  reads. Visit recording hooks the **one** place a load succeeds — `navigate`'s success path —
  via a new `PanelViewController+Visits.recordVisit(_:tab:recordHistory:)` that records history
  (conditionally) *and* frecency (always: a back-button jump is still a visit); folded into the
  existing history line as a 1-for-1 replacement so `PanelViewController.swift` stays exactly at
  the 500-line `file_length` limit (its decomposition is still pending, just not forced here).
  So the index learns from crumb clicks, the sidebar, hotlist jumps, and back/forward alike.
  The path bar's Return now routes through a new `PathBarViewDelegate.didCommit(rawText:resolved:)`
  (crumb clicks still use `didActivate`); `PanelViewController+PathBar` resolves it: an explicit
  path that `stat`s to a real directory wins, else a **slash-free** fragment falls back to
  `firstExistingFrecencyMatch` (walks the ranked candidates, `stat`-verifying each so a since-
  deleted top hit is skipped, capped at 10), else the typed path navigates so the normal
  not-found sheet still shows. A path *with* a slash is always taken literally, so a mistyped
  explicit path never silently leaps elsewhere. New `DirectoryLoader.stat` bridges the off-main
  existence check. App builds clean (no warnings); whole repo swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (no overlay this session — mouse worked; drove the Go menu
  since Cmd delivery is unreliable): seeded the index by navigating the active pane oleg →
  Downloads → Documents via the sidebar; Go ▸ Go to Location… prefilled+selected the current
  path, typing **`dl`** replaced it, and **Return jumped the pane straight to ~/Downloads**
  (breadcrump Downloads, 31 items — from Documents' 27) purely through the fuzzy index. The
  persisted `Dirnex.frecency` then read `/Users/oleg` rank 4 / Downloads rank 2 / Documents
  rank 2 — proving visit recording from the sidebar, rank accumulation on revisit, and
  **persistence across relaunch** (the home rank carried over from earlier launches). (Also
  confirmed earlier-in-session by decoding the blob the app-test run left: `/Users/oleg` rank 2,
  both panes' launch-into-home recorded through the same hook.) Test frecency default deleted
  after so no test state remains in the user's app. NEXT M3: workspaces, Settings (SwiftUI),
  rebindable shortcuts (the registry's `CommandShortcut` is the data those edit).

Progress (2026-07-08, M3 pass 5): **workspaces** landed — the fifth M3 item, a named snapshot
of the *whole window* (both panes + all their tabs) the user can save and switch back to. It
follows the same recipe as passes 2–4: a pure headless value type + tests, a `UserDefaults`
JSON store, and wiring into the command registry.

- **Core** (`DirnexCore/…/Services/Workspaces.swift`, new). Pure value types: `WorkspaceTab`
  (a tab's `VFSPath` + `FileSort` — column geometry is deliberately left out, a per-tab view
  nicety not part of a named layout's identity), `WorkspacePane` (`tabs` + a `activeTabIndex`
  that's **clamped into range** on init *and* on decode so a hand-edited/truncated store can't
  point past the end), and `Workspace` (name + left/right panes, identity = name). `Workspaces`
  is the ordered, **name-de-duplicated** collection: `save` overwrites an existing name *in
  place* (keeping its position) else appends and reports which; `remove(name:)`/`remove(at:)`;
  `rename` that **rejects an empty or already-used name** so two entries never collapse into
  one; `move` (Array-semantics reorder); `contains`/`workspace(named:)`. Decoding routes
  through the de-duping init (matching `Hotlist`). Made `FileSort` (+ its `Key`) `Codable` — a
  small, purely-additive core change so `WorkspaceTab` serializes cleanly (the app's
  `PersistedTab` still uses its own hand-rolled key/ascending encoding, untouched).
  `CommandCatalog` gains a new **`.workspace` category** ("Workspace" menu) with `workspace.list`
  ("Workspaces…") + `workspace.save` ("Save Workspace…"). New `WorkspacesTests` (+12) + catalog
  coverage (+1) → **core suite 211**, all green; swiftformat/swiftlint-strict clean. GOTCHA (hit
  yet again, per [[swift-testing-expect-optional-arithmetic]]-adjacent): a `mutating` call can't
  sit inside `#expect(...)` — `save`/`remove`/`rename` results were hoisted into a `let`.
- **App.** New `WorkspaceStore` (UserDefaults JSON `Dirnex.workspaces`, read-fresh-per-open like
  `HotlistStore` — no live-observation plumbing). A workspace spans both panes, which no single
  pane can see, so capture/restore lives on the **window controller**
  (`BrowserWindowController+Workspaces`: `captureWorkspace(named:)` snapshots both panes,
  `applyWorkspace` restores them + focuses left), reached through two new `PanelHost` methods —
  the same pane→host forwarding the undo surface uses. `PanelViewController+Workspaces` owns the
  per-pane `workspaceSnapshot()`/`restore(workspacePane:)` (restore drops vanished dirs like
  relaunch does, and keeps the current dir rather than ending up tab-less if all vanish) plus the
  responder-chain actions: `showWorkspaces` pops an `NSMenu` from the path-bar edge (one switch
  item per workspace carrying its *name* + a 1–9 accelerator + a `square.split.2x1` glyph, then
  Save/Manage), `saveWorkspace` prompts for a name (NSAlert + field) and **confirms before
  replacing** an existing one. `WorkspaceOrganizerController` (new) mirrors the hotlist organizer
  — a drag-reorder / inline-rename / `−`-remove sheet, every edit saved immediately; rename that's
  rejected snaps the field back. `CommandBinding`/`MainMenuBuilder` wire both commands into the
  new Workspace menu; the palette's category tag widened 62→72pt (+ truncation) to fit
  "WORKSPACE" (68.5pt overflowed). **Forced the decomposition the pass-3/4 notes predicted**: the
  new `PanelHost` methods pushed `PanelViewController.swift` past its 500-line `file_length`
  limit, so the whole `FileTableViewInput` extension (+ its `redrawRow`/`setFilter` helpers) moved
  to a new `PanelViewController+TableInput.swift` (dropping the file to ~410 lines;
  `syncCursorToTable` went `private`→internal for the cross-file call). App builds clean; whole
  repo swiftformat/swiftlint-strict clean (**110 files**, 0 violations).
- **Verified live via computer-use** (mouse-driven; no overlay): the Workspace menu shows
  "Workspaces…"/"Save Workspace…"; Save prompted, typed **"Work"**, saved with left=Downloads /
  right=~/oleg; changed both panes (left→Documents, right→Movies); Workspaces… ▸ **Work** restored
  *both* panes at once (Downloads 31 / oleg 18). The persisted `Dirnex.workspaces` blob decoded
  to exactly that layout incl. the now-`Codable` `FileSort`. Saved a 2nd ("Browsing"), opened the
  organizer: **drag-reorder landed first try** (the hotlist drag fix carried over), inline-rename
  Work→"Projects" persisted, `−` deleted it leaving one; every edit survived a **quit+relaunch**
  (store read `['Browsing']` off disk, popup re-rendered it). Test workspaces deleted after so no
  test state remains in the user's app. Noted UX quirk (shared with the hotlist organizer, not new):
  Return in a rename field also fires the Done button (its `\r` key-equivalent), committing +
  closing in one press. NEXT M3: Settings (SwiftUI) + rebindable shortcuts — best done together
  (Settings is the container, the rebind UI its "shortcuts" tab; both edit the registry's
  `CommandShortcut` data), the last two M3 items.

Progress (2026-07-08, M3 pass 6): **Settings window + rebindable shortcuts** landed — the
final two M3 items, done together as planned (Settings is the SwiftUI container; the rebind
UI is its Shortcuts tab). **M3 is now complete.** This is the app's first SwiftUI surface
(§2 "SwiftUI for settings"); the file panes stay AppKit.

- **Core** (`DirnexCore/…/Services/KeyBindings.swift`, new). Made `CommandShortcut` (+ its
  `Modifiers` option-set, via a single-value `Int` container) **`Codable`** so rebindings
  persist as boring JSON. New pure value type `KeyBindings` layered over `CommandCatalog`'s
  defaults: `overrides: [String: Binding]` where `Binding = .shortcut(_)|.unbound` (so a
  default can be *removed*, not just replaced), keyed by command id. `shortcut(for:)` resolves
  the effective binding (override else catalog default); `setShortcut`/`reset`/`resetAll` keep
  the override map minimal (a rebind equal to the default drops the override, so it always
  reads "not customized"); `conflicts(for:)`/`allConflicts()`/`hasConflicts` detect two
  commands sharing an effective shortcut (registry-primary only — the table's secondary
  Finder gestures like ⌘⌫ stay an app concern); `preset(.macOS|.totalCommander)` produces a
  whole scheme (macOS = plain defaults; TC = F3-previews + ⇧F6-rename over the already-TC F5/
  F6/F7/F8) and `matchingPreset` reflects it back (nil = "Custom"). `CommandCatalog` gains
  `app.settings` ("Settings…" ⌘,). New `KeyBindingsTests` (+18 → **core suite 229**): resolve/
  set/unbind/reset, conflict detection, both presets + conflict-freeness, `matchingPreset`,
  and JSON round-trips incl. the Codable-shortcut check. All green; swiftformat/swiftlint clean.
- **App** (`Dirnex/Settings/`, new group per §3). `KeyBindingStore` (`ObservableObject`
  singleton, UserDefaults JSON `Dirnex.keyBindings`, posts `didChange`) + `AppPreferences`
  (`ObservableObject` singleton for the non-shortcut tabs' toggles). `MainMenuBuilder` now
  reads each item's key equivalent from the store's **effective** shortcut (not `Command.shortcut`);
  `AppDelegate` observes `didChange` and **rebuilds the whole menu bar** so a rebind takes
  effect immediately (menu key-equivalents are the firing mechanism — the panel key model was
  untouched). The Cmd+K palette resolves effective shortcuts the same way (`CommandPaletteRowView.configure`
  gained a `shortcut:` param). `app.settings` → `AppDelegate.showSettings` opens
  `SettingsWindowController` (a shared `NSWindowController` hosting the SwiftUI `SettingsView`
  — the AppKit-hosted app can't use SwiftUI's `Settings` scene). The **Shortcuts tab**
  (`ShortcutsSettingsView`) lists every command grouped by category with an inline
  `ShortcutRecorder` (an `NSViewRepresentable` over an AppKit key-capture view that becomes
  first responder and — crucially — overrides `performKeyEquivalent` while recording so ⌘-combos
  are captured, not dispatched to a menu; Esc cancels, Delete unbinds; `CommandShortcut(event:)`
  in `CommandShortcut+AppKit` does the NSEvent→token translation), a preset picker (macOS/TC/
  Custom), a filter field, per-row conflict warnings (red glyph + ⚠︎ + "also assigned to …"),
  a per-command reset, and Restore-Defaults. General/Panels/Operations tabs wire three real,
  behavior-preserving-default `AppPreferences` toggles read at a single point each: **reopen
  last session** (gates the panes' `TabPersistence` restore in `BrowserWindowController`),
  **show hidden files in new tabs** (threaded into the default + restored `PanelTab`s), and
  **confirm before Trash** (a prompt in the F8 flow; permanent delete always confirms). App
  builds clean; whole repo swiftformat/swiftlint-strict clean (121 files, 0 violations).
- **Verified live via computer-use** (mouse + keyboard both worked; no overlay): Dirnex ▸
  Settings… ⌘, opened the window; all four tabs render (General's session toggle shown). The
  Shortcuts tab listed the File commands with correct glyph pills; clicking Rename's pill →
  "Type shortcut…" (accent border) → **⌘R was captured** (proving `performKeyEquivalent`
  intercept — it did *not* fire any menu) → pill showed ⌘R + a reset button + preset flipped
  to **Custom**; the **File menu rebuilt live** to "Rename… ⌘R" (proving the didChange→menu
  rebuild). Binding **New Folder to the same ⌘R** flagged **both** rows red with ⚠︎ and lit the
  header warning (conflict detection). **Restore Defaults** cleared everything (F2/F7 back, no
  warnings); the **Total Commander preset** rebound Rename→⇧F6; the **filter** narrowed to
  "Move to Trash" on "trash". Header polished mid-verification (cramped conflict text →
  icon-only warning + wider 600pt window). Left pristine: persisted blob is `{"overrides":{}}`
  (= defaults), all prefs unset. GOTCHA (recurring): a `mutating` call can't sit in
  `#expect(...)` — results hoisted into a `let`. Deferred: per-workspace palette entries
  (noted in pass 5); the recorder records a *shifted-punctuation* combo as its shifted glyph
  (letters/F-keys/⌘-combos/arrows record exactly) — documented in `CommandShortcut(event:)`.

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

Progress (2026-07-09, M4 pass 1): the **multi-rename tool** landed — TC's Multi-Rename Tool
(⇧F2), a headline M4 item and the batch-rename power feature (**M4 line 3 now `[x]`**; started
here rather than ArchiveBackend because it's pure-Swift and slots straight into the tested
core→app rhythm, whereas libarchive needs a C-module + vendored-headers infra pass first). Core
`DirnexCore/Services/MultiRename.swift` = a pure planner: `RenameSpec` (name mask + extension
mask + literal/regex find-replace + `RenameCase` fold + `RenameCounter` start/step/zero-pad) →
`MultiRename.plan(for:spec:existingNames:)` → one `RenameProposal` per item (old→new +
`RenameStatus`). Token substitution is a single left-to-right scan (`[N]` base, `[E]` ext,
`[C]` counter, `[Y][M][D]` date + `[h][n][s]` time read off the mtime in the local calendar) so
a filename that literally contains "[C]" is never re-expanded, and unknown/malformed brackets
pass through verbatim. Collision model is deliberately strict-and-safe: a new name may only equal
its own item's original (a pure case change on case-insensitive APFS) — a target that collides
with any *other* existing name, incl. another batch member's original (a swap/chain), is a
blocking `.collision`, and two rows producing the same name are `.duplicate`; that keeps every
applied rename order-independent AND cleanly undoable with plain `moveItem` (no temp-name
juggling). +20 `MultiRenameTests` +1 catalog +2 undo-builder → **254 core tests**; `CommandCatalog`
gains `file.multiRename` (⇧F2, conflict-free); NEW `UndoRecord.multiRename` builder folds the
batch into ONE record of `.restore` steps, so a single Cmd+Z reverses the whole rename. App =
`MultiRenameController` (a `presentAsSheet` NSViewController — NSGridView of controls + tokens
legend + a live two-column preview NSTableView that re-plans on every keystroke via
`controlTextDidChange`; red new-name cells, an "N name conflicts" footer, and a disabled/enabled
"Rename N Items" default button) + `PanelViewController+MultiRename` (gathers `selectionTargets()`
+ the directory's full name set, presents the sheet, and on commit performs the moves off-main
through `moveItem` then journals `UndoRecord.multiRename`); `CommandBinding`/`MainMenuBuilder` wire
it into the File menu right after Rename; `validateMenuItem` enables it on a non-empty selection +
`.rename` capability. Whole repo swiftformat/swiftlint-strict clean. Verified live (mouse-driven,
no overlay; had to fully quit a stale running instance first — `open` re-focuses the old process,
so the new menu item only appeared after a clean relaunch): marked 2 of 4 files, ⇧F2 opened the
tool with an identity preview; typed `photo_[C]` + Digits 2 → live preview
IMG_three.jpg→photo_01.jpg / IMG_two.jpg→photo_02.jpg (counter + zero-pad + `.jpg` preserved),
Rename applied byte-exact on disk (contents intact, IMG_one/notes.txt untouched), and Edit▸**Undo
Rename** reversed the entire batch in one Cmd+Z (both original names + contents back on disk); a
constant `same` mask flagged both rows red with a "2 name conflicts" footer and a disabled Rename
button. GOTCHA (recurring, hit again): `#expect(coll.allSatisfy(\.x))` trips the Testing macro's
throwing analysis — hoist the result into a `let` first. Left the app on Home; test fixtures
deleted. Groundwork note for the ArchiveBackend pass: the macOS SDK ships `libarchive.tbd`
(so `-larchive` links) but has NO `archive.h`/`archive_entry.h` — a C-module target with vendored
headers (or shelling out to `bsdtar`/`ditto`) is the gate. NEXT M4: ArchiveBackend (libarchive),
mdfind search (Alt+F7) → virtual panel, quick-view panel.

Progress (2026-07-09, M4 pass 2): the **quick-view panel** landed — TC's ⌃Q, the smallest
unblocked M4 item (**that M4 line now `[x]`**; picked over ArchiveBackend/search because it's
pure app-layer AppKit with no core changes and no C-module infra). It's a window-wide mode: the
*inactive* pane stops showing its list and becomes a live embedded Quick Look of the file under
the *active* pane's cursor — distinct from the ⌘Y Quick Look, which floats a separate window
over the active pane. NEW `Dirnex/Browser/PanelViewController+QuickView.swift`: each pane lazily
builds a `QLPreviewView(style: .compact)` overlay pinned over its scroll view and toggles it via
`showQuickViewPreview(of:)` / `hideQuickViewPreview()`; `quickViewSourceURL` reports the file
under this pane's cursor (nil on `..`/empty). `BrowserWindowController` owns the on/off flag and
orchestrates: `toggleQuickView` flips it; `updateQuickView` puts the preview opposite the active
pane (active shows its list, inactive previews the active cursor); `panelCursorDidChange` (called
from `updateChrome`, the one hook every cursor move / navigation / mark change / refresh already
funnels through) re-drives the preview; and `setActive` re-runs `updateQuickView` so a Tab focus
switch swaps which pane lists and which previews. Wiring is registry-driven per the M3 rhythm:
`CommandCatalog` gains `view.quickView` (⌃Q, conflict-free — verified by a new `CommandCatalog`
test → **255 core tests**), `CommandBinding` maps it to `toggleQuickViewPanel`, `MainMenuBuilder`
adds it to View after Quick Look, and `validateMenuItem` shows a checkmark tracking the state
(the two checkmark toggles were hoisted into a `validateToggleItem` helper so `validateMenuItem`
stayed under SwiftLint's cyclomatic-complexity 15). Repo swiftformat/swiftlint-strict clean;
app `xcodebuild build` + `swift test` green. VERIFIED LIVE (mouse+keyboard, no overlay; fully
quit the stale instance first per the recurring gotcha): ⌃Q on a fixture folder turned the right
pane into a text preview of `notes.txt`, ↓ tracked the cursor to `readme.md` live; Tab swapped
roles (right pane went active+listing, left pane previewed the right cursor's folder icon), a
real 95 KB PNG rendered its image, and the View menu showed **Quick View Panel ⌃Q** checked;
⌃Q / the menu item toggled it back off, both lists restored. Left the app on Home; fixtures
deleted. GOTCHA 1 (design, cost one rebuild): `QLPreviewView` is NOT opaque — a preview that
doesn't fill the view (a 1×1 PNG, a failed preview) let the covered table bleed through the
margins. Fix: back the preview with an opaque `NSBox` (custom, borderless, `fillColor =
.textBackgroundColor` so it re-resolves on a light/dark switch, unlike a captured `cgColor`) as
its content view. GOTCHA 2 (AppKit API): `QLPreviewView.init(frame:style:)` imports as a genuine
failable `init?` (returns `QLPreviewView?`), not an IUO — so it needs a `guard let`, and the
build errors if you treat the result as non-optional. GOTCHA 3 (test-only): setting `previewItem`
twice in rapid succession (a fast synthetic key batch) races Quick Look's async load and can
leave the *first* item showing — stepping the cursor one key at a time previews correctly, so
this is a synthetic-input artifact, not a user-facing bug. NEXT M4: ArchiveBackend (libarchive),
mdfind search (Alt+F7) → virtual panel.

Progress (2026-07-10, M4 pass 3): **Spotlight search → virtual results panel** landed — TC's
Alt+F7 file search, cashing in the VFS abstraction for the first time as a *virtual* listing
(**both M4 search lines now `[x]`**; picked over ArchiveBackend because it's pure Swift + app
AppKit with no C-module infra — libarchive is still gated on the vendored-headers pass). Core
`DirnexCore/Services/SpotlightQuery.swift` = a pure query builder mirroring `MultiRename`'s
planner: a `SpotlightQuery` value (name substring, content substring, `SearchKind` chips
folder/image/audio/movie/document/archive, min-size, `SearchAge` today/week/month/year) →
`metadataPredicate()` renders the raw `kMDItem…` query mdfind speaks (name/content as
`== "*term*"cd`, kinds as a parenthesized `kMDItemContentTypeTree` OR in CaseIterable order,
size as `kMDItemFSSize >=`, date as a **relative** `kMDItemFSContentChangeDate >= $time.now(-N)`
so the string stays deterministic/testable), and `mdfindArguments(scopePath:)` prepends `-onlyin`.
Quotes/backslashes in a term are escaped so they can't break the literal. +15 `SpotlightQueryTests`
+1 catalog test → **271 core tests**; every predicate form was also validated against the real
`/usr/bin/mdfind` from the shell before wiring the UI. `CommandCatalog` gains `go.search` (⌥F7,
conflict-free — distinct from plain-F7 New Folder by its modifier set); NEW `VFSBackendID.search`
tags a virtual listing. App: `SpotlightSearchRunner` (the non-hermetic I/O boundary, like
`DirectoryLoader` — spawns `mdfind` off-main via `Process`, reads-to-EOF then stats each hit into
`FileEntry`, caps at 5 000 with a truncation flag) + `SearchController` (the ⌥F7 sheet — name/
content fields, kind/size/date popups, a This-Folder/Everywhere scope, Find disabled until the
query asks for something) + `PanelViewController+Search` (runs the search, then installs the hits
as a **new virtual tab**: a `DirectoryListing` on the `.search` backend whose entries carry their
real `.local` paths, `hasLoaded=true`, `showHidden=true` so no dotfile hit is silently filtered).
`CommandBinding`/`MainMenuBuilder` wire `findFiles` into the Go menu after Go Up. The virtual pane
is recognized by a one-line `isSearchResults` (`panel.path.backend == .search`) and every
directory-bound behavior guards on it: no FSEvents watch, no re-list on tab-activate/both-panes-
refresh, no `..` row (`parentRowCount` requires `.local`), and New Folder/rename/multi-rename/
trash/delete/paste/Go-Up all disabled (in `validateMenuItem` *and* their action entry points, since
the keyboard paths bypass menu validation) — while **Copy/Move to the other pane stay enabled** (TC's
F5 on results: each target's real path copies fine). The path bar renders a non-clickable
"🔍 Results for …" for a `.search` path; Cmd+L bases at Home; and opening a *real* folder from a
result resets the tab's back/forward trail (`navigate` captures `wasVirtual` up front) so the
un-listable synthetic path never lands in history. Two SwiftLint limits tripped and were fixed the
usual way (extract a helper): `validateMenuItem` cyclomatic-complexity split a `validateMutatingItem`
helper out, `CommandCatalog` enum body moved Window+Application to an extension, `PathBarView` body
moved the virtual-label builder to an extension. Repo swiftformat/swiftlint-strict clean (one
pre-existing `redundantSelf` nit in the untouched `BrowserWindowController`); app `xcodebuild build`
+ `swift test` + app smoke test green. VERIFIED LIVE (mouse+menu-driven, no overlay; fully quit the
stale instance first per the recurring gotcha, and confirmed the fresh debug dylib carried the new
strings): Go ▸ **Find Files… ⌥F7** opened the sheet (Find greyed until "network-usage-2026-05" was
typed, then blue); Find opened a new left-pane tab **"network-usage-2026-05"** with path bar
**🔍 Results for "network-usage-2026-05"**, the **3** matching JSONs (byte-exact against the 3 in
the right Downloads pane), **3 items** status, and **no `..` row**; the File menu showed **Copy/Move
to Other Panel enabled** while **Rename/Multi-Rename/New Folder/Trash/Delete were all greyed**; and
closing the results tab (its ✕) restored the browsing `oleg` tab (breadcrumbs + `..` + 18 items, tab
bar re-hidden). Left the app on Home. GOTCHA (design): a virtual panel is the cleanest place the VFS
`.search` backend id + a per-site `isSearchResults` guard pays off — the alternative (a per-tab
`backend`) would have been a much larger refactor. NEXT M4: ArchiveBackend (libarchive — the
C-module/vendored-headers gate), saved searches in the places strip, the deferred search niceties
(tag chip, content-grep fallback for non-indexed volumes).

Progress (2026-07-10, M4 pass 4): the **ArchiveBackend — read-only archive browsing** landed —
TC's "open a zip and browse it like a folder", the headline "cash in the VFS abstraction" M4 item
and the first backend beyond `.local` that serves a *navigable* virtual tree (the `.search` pane
was a static snapshot). Taken **via `bsdtar`, not the libarchive C-API** (user's call): the macOS
SDK ships `libarchive.tbd` but no `archive.h`, so the C-module/vendored-headers gate stays deferred
— shelling out to `/usr/bin/bsdtar` (which *is* libarchive) needs zero infra and matches the app's
`Process`-spawning rhythm (`SpotlightSearchRunner`, `DirectoryLoader`). This pass is **browse-only**;
extraction (Quick Look inside, F5 copy-out) and packing are the next pass, because `CopyEngine.run`
takes one backend for source *and* dest — a cross-backend archive→local copy is its own chunk.

- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveTOC.swift` + `ArchiveTOCParser.swift` = a hermetic
  parser turning the `ls -l`-style table `bsdtar -tvf` prints into a navigable tree: `children(inDirectory:)`
  / `isDirectory(atInnerPath:)` / `entry(atInnerPath:)`. It handles every real-output quirk (validated
  against `/usr/bin/bsdtar` before wiring, like the mdfind predicates): the 8 fixed leading columns
  then a **verbatim** name (so "a file with spaces.txt" survives a would-be whitespace split), `d`/`l`/`-`
  mode → kind, `link -> target` symlink split, tar's leading `./` stripped (and the bare `./` root line
  dropped), and **intermediate directories synthesized** when the archive lists only `docs/api/readme.md`.
  Dates parse best-effort in `en_US_POSIX` (`MMM d HH:mm` / `MMM d yyyy`) — deterministic, not
  system-locale-dependent. `ArchiveBackend.swift` = a read-only `VFSBackend` answering `list`/`stat`
  purely from an in-memory TOC (`capabilities == .read`; writes stay at their `.unsupported` defaults);
  its `id` encodes the archive's on-disk path (`VFSBackendID.archive(forArchiveAt:)` → `archive:/…/pkg.zip`)
  so a `VFSPath` identifies both *which* archive and *which* inner entry. `ArchiveType.isBrowsable`
  (pure suffix match: zip/jar/cbz/7z/tar/tgz/tar.gz/tbz/tar.bz2/txz/tar.xz/tar.zst) decides Enter = browse
  vs. launch. +25 tests (`ArchiveTOCTests` 12, `ArchiveBackendTests` 9, `ArchiveTypeTests` 2, +2 in
  those covering the id round-trip) → **294 core tests**, all green, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/CompositeBackend.swift` — a `VFSBackend` that routes
  each `VFSPath` by `path.backend`: `.local` → the real `LocalBackend`, an `archive:…` id → a lazily
  mounted `ArchiveBackend` (spawns `bsdtar -tvf` off-main via the co-located `ArchiveMounter`, parses,
  caches under an `NSLock`). **Composing** rather than swapping the pane's backend keeps *every* existing
  `self.backend` call site — listing, stat, sizing, copy/move, the shared queue and undo — working
  unchanged; only the routing is new. `BrowserWindowController` now builds `CompositeBackend(local:
  LocalBackend())` and hands it to both panes + the queue + undo. `volumeIdentifier` never mounts (the
  queue calls it per-source and it must stay cheap). Navigation: `openCurrentEntry` enters a browsable
  local archive file (→ `archive:…` root) instead of launching it; a new `PanelViewController+Archive.swift`
  adds `isArchive` / `isVirtualDirectory` and `goUpWithinArchive` (walk the inner tree, and at the archive
  root **exit to the containing folder landing the cursor on the archive file**); the `..` row now shows at
  every archive level; the path bar renders a non-clickable **"📦  pkg.zip  ▸  docs  ▸  api"** trail
  (`rebuildArchiveLabel`, factored beside the search label). **Capability degradation** reuses the
  search-pane pattern, generalized: `!isSearchResults` mutation guards became `!isVirtualDirectory`
  (covers search *and* archive) at both `validateMenuItem` *and* every action entry point (New Folder /
  rename / multi-rename / trash / delete / paste), while F5/F6 copy-out and ⌘C are gated on `!isArchive`
  (search still allows them; an archive member has no local URL yet); Quick Look, the ⌃Q Quick View, drag-out,
  and drop-target all guard on `entry.path.backend == .local`. One SwiftLint `type_body_length` on
  `PathBarView` (the recurring gotcha) fixed by moving the location-dispatch into the existing extension.
  Whole repo swiftformat/swiftlint-strict clean; app `xcodebuild build` + `swift test` green.
- **Verified live via computer-use** (mouse-driven, no overlay; fresh build confirmed in the debug
  **dylib** — `bsdtar`/`CompositeBackend`/"read the archive" strings present — since a stale `open`
  wouldn't carry it): double-clicking `pkg.zip` turned the pane into **📦 pkg.zip** listing `docs`/`images`
  (folders, dash size) + `alpha.txt` 14 B + `release notes.txt` 13 B (**space preserved**), a `..` row, and
  "4 items" (`..` excluded); into `docs` → `api` + `readme.md` 16 B; into `docs/api` → `reference.md` 17 B,
  path bar **📦 pkg.zip ▸ docs ▸ api**; the File menu there showed **Copy/Move to Other Panel, Rename,
  Multi-Rename, New Folder, Move to Trash, Delete Immediately ALL greyed** (only New Tab/Close Tab live);
  `..` walked `api → docs → root` each landing the cursor on the branch we came from, and one more `..` at
  the root **exited to `~/DirnexArchiveTest` with clickable local breadcrumbs restored and the cursor on
  `pkg.zip`**; `bundle.tgz` browsed identically (tar's `./` prefix stripped, no phantom root entry). GOTCHA
  (cosmetic, expected): `bsdtar`'s recent-file column has no year (`Jul 10 16:39`), so the `MMM d HH:mm`
  parse yields year **2000** — the time is right, the year is a placeholder; a real fix would infer the
  year, deferred. GOTCHA (architecture): a `CompositeBackend` that dispatches on `path.backend` is the
  clean way to browse a second backend without touching every `self.backend` site — the alternative
  (a per-tab backend) is a much larger refactor. NEXT M4: archive **extraction** (Quick Look inside + F5
  copy-out via a temp-extract-then-normal-copy path, since `CopyEngine` is single-backend) and **packing**;
  then archive **writes** (add/delete), saved searches in the places strip, deferred search niceties.

Progress (2026-07-10, M4 pass 5): **archive F5 copy-out** landed — TC's "open a zip and fish two files
out" (the M4 exit criterion), the first half of the extraction pass. The archive backend stays read-only;
this cashes the browse-only pass in for real *extraction*. The clean insight: `CopyEngine` takes one
backend for source *and* dest, so an archive→local copy can't go straight through it — instead the marked
members are **extracted to a temp directory with `bsdtar`, then handed to the normal copy queue** as real
local files, reusing every bit of its conflict / progress / undo machinery for free.

- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveExtraction.swift` = the pure argv half, mirroring
  `SpotlightQuery`/`ArchiveExtraction` split: `extractionArguments(archiveOnDiskPath:innerPaths:destinationDirectory:)`
  builds `bsdtar -x -f <archive> -C <dest> <member>…` where each member is the VFS inner path with its
  leading slash dropped, and `extractedLocation(ofInnerPath:inDirectory:)` reports where each member lands
  (`bsdtar` rebuilds the *full* inner path, so `/docs/api/x.md` → `<dest>/docs/api/x.md`). Members are
  **glob-escaped** (`\ * ? [`) because `bsdtar` treats each member as a shell-glob pattern — a name like
  `weird[1].txt` would otherwise read as a char-class and go unmatched (escaping the opening `[` alone is
  enough — validated live against bsdtar 3.5.3 / libarchive 3.7.4, along with: nested-file / dir-recursive /
  space-in-name / `./`-prefixed-tar / multi-member / missing-member extraction). +7 `ArchiveExtractionTests`
  → **301 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchiveExtractor.swift` (mirrors `ArchiveMounter`) spawns
  `bsdtar` off-main into a fresh UUID temp dir under `NSTemporaryDirectory()/DirnexExtract/`, best-effort
  (a missing member exits non-zero but the rest still land; throws only when *nothing* landed).
  `PanelViewController+ArchiveExtract.swift`'s `beginArchiveExtraction()` extracts the marked/cursor members,
  `stat`s each extracted file back into a **local** `FileEntry` (dropping any that didn't land), then calls
  the existing `submitTransfer(kind:.copy…)` to the other pane. `CopyEngine` names the dest by `entry.name`
  (its own last component), so a deep temp source `<tmp>/docs/api/x.md` lands **flat** as `x.md` — no
  strip-components needed. F5 routes here (`copyToOtherPane` → `if isArchive { beginArchiveExtraction() }`);
  `validateMenuItem` splits the old joint Copy/Move case so **Copy is enabled from an archive but Move stays
  gated** (`!isArchive`) — a read-only archive has no source to remove, so there's no move-out. Temp dirs are
  purged at launch (`ArchiveExtractor.purgeTemporaries()` in `AppDelegate` — race-free, nothing's extracting
  yet; the copy queue *copies* the temps so they're dead weight once queued, and the current session's are
  reclaimed next launch or by the OS). ⌘C-to-clipboard and drag-out from an archive stay gated this pass.
- **Verified live via computer-use** (fresh build, `DirnexExtract`/`beginArchiveExtraction` strings confirmed
  in the debug **dylib**; fully quit the stale instance first): inside `pkg.zip`, marked `docs` (a dir) +
  `a file with spaces.txt`, F5 → both landed in the other pane; on disk the tree was byte-exact and recursive
  (`docs/readme.md`=readme, `docs/api/reference.md`=reference, the space preserved, `images` correctly NOT
  extracted). Re-F5 of `a file with spaces.txt` raised the **rich per-file conflict dialog** (Replace / Keep
  Both / Skip / Replace-If-Newer, "apply to all", queue bar) — proving it flows through the normal queue —
  and Keep Both produced `a file with spaces copy.txt`. A nested `docs/api/reference.md` F5'd from inside the
  subfolder landed **flat** as `reference.md` (the `entry.name` behavior). The File menu inside the archive
  showed **Copy to Other Panel enabled, Move + all mutations greyed**. Launch-purge confirmed: 3 temp dirs
  accumulated, survived quit, and were gone after relaunch. GOTCHA (bsdtar): members are glob *patterns*, not
  literals — must escape `\ * ? [`, and `extractedLocation` uses the *raw* (unescaped) name since the on-disk
  file keeps its real name. GOTCHA (architecture): temp-extract-then-normal-copy is the clean cross-backend
  path — the source `FileEntry`s just point at the extracted temp files, and `CopyEngine`'s name-by-last-
  component does the rest, so no `CopyEngine` refactor was needed. NEXT M4: archive **Quick Look inside** (the
  extraction pass's other half — extract-on-demand + cache the single cursor member, then relax the
  `.local`-only guards in `+QuickLook`/`+QuickView`) and **packing** (F5-with-archive-target via `ditto`/
  `bsdtar`); then archive **writes**, saved searches in the places strip, deferred search niceties.

Progress (2026-07-10, M4 pass 6): **archive Quick Look / Quick View inside** landed — the extraction
pass's other half. Both preview surfaces (⌘Y floating Quick Look and ⌃Q embedded Quick View) now show
the file under the cursor when it's an archive *member*, by extracting that single member on demand and
pointing the preview at the extracted temp file. Pure app-layer wiring on top of pass 5's plumbing — no
new core logic (the `bsdtar` argv is already `ArchiveExtraction`, already tested), so **core stays at 301
tests** and this pass adds none.
- **The cache.** NEW `Dirnex/Browser/ArchivePreviewCache.swift` (`@MainActor final class`, one per window,
  owned by `BrowserWindowController`, reached through the `PanelHost.archivePreviewCache` protocol getter):
  a `[ArchiveMember: URL]` dict keyed by `(archiveOnDiskPath, innerPath)`. `cachedURL(for:)` is the
  synchronous lookup the preview surfaces read; `extractedURL(for:)` extracts off-main via the *existing*
  `ArchiveExtractor.extract(innerPaths:[one])` (single member → one landed file) and memoizes. Chose a dict
  over a literal single slot (the plan sketch said "single cursor member") because it kills the
  async-completion race — a slow extraction that finishes *after* the cursor has moved on writes its own
  key instead of evicting the member now under the cursor, so no preview ever blanks from a stale result;
  arrowing back is also instant. The cache never deletes: extracted files pile up under `ArchiveExtractor`'s
  `DirnexExtract/<uuid>/` root (nested members keep their full inner path, e.g. `<uuid>/docs/api.md`) and
  are purged at launch exactly like F5's, so nothing races an in-flight preview.
- **On-demand trigger.** NEW `Dirnex/Browser/PanelViewController+ArchivePreview.swift`: `previewableArchiveMember`
  (nil unless browsing an archive AND the cursor is on a *file* member — not `..`, not a directory) and
  `prepareArchivePreview(onReady:)` — a no-op that never calls back when the member is absent OR already
  cached (so a caller can invoke it after every refresh without looping), else it extracts and calls
  `onReady` on the main actor *only if the cursor is still on that same member*. That "still-current" guard
  is what makes the single async path safe under rapid arrowing.
- **Relaxed guards.** `+QuickView.quickViewSourceURL` and `+QuickLook`'s new `quickLookURL(for:)` now resolve
  a `.local` entry to its real URL AND an archive member to `cachedURL(for:)` (nil until extraction lands).
  `quickLookItems()` gained an `isArchive` branch: inside an archive it previews just the cursor member once
  cached (the marked-set preview stays a local-files feature). Drivers: `refreshQuickLookIfVisible()` and the
  ⌘Y-open path (`fileTableToggleQuickLook`) both call `prepareArchivePreview { refreshQuickLookIfVisible() }`;
  `BrowserWindowController` folds `panelCursorDidChange`/`updateQuickView` into one `showActivePreview(from:)`
  that shows the (possibly-nil) cached URL at once then `prepareArchivePreview { … showQuickViewPreview … }`
  re-drives the inactive pane when the member lands (guarded on Quick View still on + same active pane). QL/QV
  menu items were already always-enabled (`default: return true`), so nothing to ungate.
- **Verified live via computer-use** (fresh Debug build after a full quit; `ArchivePreviewCache` confirmed in
  the dylib): entered `bundle.zip`, ⌘Y on `readme.txt` → floating Quick Look showed its text; ⌘Y on the
  6.6 MB `photo.heic` → showed the full image ("Open with Preview"); ⌃Q → inactive pane live-previewed the
  cursor member and *tracked the cursor* (arrow onto `photo.heic` swapped the preview to the image); cursor on
  the `docs` directory → blank preview (correctly unpreviewable); entered `docs`, `api.md` previewed its
  markdown (nested inner path). The three `DirnexExtract/<uuid>/` temps on disk afterwards were exactly
  `readme.txt`, `photo.heic`, and `docs/api.md` — proving per-member on-demand extraction + the full-inner-path
  rebuild. GOTCHA (minor): with the shared Quick Look panel key, arrow keys navigate *preview items* (only 1
  for an archive), not the underlying table — so changing the previewed member with ⌘Y open means closing +
  reselecting; ⌃Q (table stays first responder) tracks the cursor live as expected. NEXT M4: archive **packing**
  (F5-with-archive-target via `ditto`/`bsdtar`), then archive **writes**, saved searches in the places strip,
  deferred search niceties.

Progress (2026-07-10, M4 pass 7): **archive packing** landed — TC's Pack (⌥F5), the inverse of F5 copy-out
and the last half of the "open a zip, fish two files out, repack" exit criterion. Select real local files in
one pane, ⌥F5, pick a name + container format, and a new archive is created in the *other* pane — the same
default destination as F5. Taken via `bsdtar -a -c` (not `ditto`), which handles zip/tar.gz/tar.bz2/7z/tar
**uniformly** with the format inferred from the archive's own suffix, matching the browse/extract passes'
`bsdtar` rhythm.
- **Core (pure, tested).** `DirnexCore/…/VFS/ArchivePacking.swift` = the pure argv half, mirroring
  `ArchiveExtraction`: `packingArguments(archiveOnDiskPath:sourceDirectory:sourceNames:)` builds
  `bsdtar -a -c -f <archive> -C <sourceDir> <name>…` — `-a` infers the format from the suffix, `-c` creates
  (overwriting; the app resolves that collision first), and `-C` + bare names make the entries archive-relative
  (so the archive holds `docs/…`, not an absolute path). Every selected item shares one parent — the pane's
  current directory — so a single `-C` covers them all. Unlike extraction, create-side arguments are **literal
  file paths, not glob patterns** (validated live against bsdtar 3.5.3), so **no member escaping** is needed —
  a name like `weird[1].txt` is passed verbatim. A `Format` enum (`.zip/.tarGz/.tarBz2/.sevenZip/.tar`, each
  with `suffix` + `displayName`, `.zip` first) drives the dialog's popup and guarantees every packable format
  round-trips back into a browsable one (`ArchiveType.isBrowsable`). `defaultBaseName(forSourceNames:
  sourceDirectoryName:)` = a single source's name minus its extension (`report.pdf`→`report`, the folder
  `docs`→`docs`), else the source directory's own name (multi-item→`<folder>`), falling back to `Archive` at a
  volume root; `archiveFileName(baseName:format:)` appends the suffix without doubling an already-present one
  (`docs.zip`+Zip→`docs.zip`, not `docs.zip.zip`). +11 `ArchivePackingTests` + 1 `CommandCatalogTests` →
  **313 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchivePacker.swift` (mirrors `ArchiveExtractor`/
  `ArchiveMounter`) spawns `bsdtar` off-main; unlike extraction it writes **directly to the destination** (the
  result *is* a user file, nothing to temp/purge) and cleans up a partial archive on a non-zero exit or missing
  output. `PanelViewController+ArchivePack.swift`'s `beginArchivePacking()` guards `canPackFromHere`
  (`.local && !isVirtualDirectory` — can't pack *from* an archive or a search-results pane, and every item must
  share one parent), requires the other pane be a real writable folder, then raises a small sheet (NSAlert
  accessory: a name field over a format popup) pre-filled from the core default. `confirmAndPack` `stat`s the
  target first — `bsdtar -c` would silently overwrite — and raises a Replace/Cancel confirmation on a collision;
  `runPack` spawns off-main then `refreshCurrentDirectory(selecting:)` re-lists the destination pane with the
  new archive landed under the cursor. Registry wiring: `file.pack` command (title "Pack…", ⌥F5, keywords
  compress/archive/zip/tar) in `CommandCatalog`, selector in `CommandBinding`, `.command("file.pack")` in
  `MainMenuBuilder`'s File layout (grouped with Copy/Move), and a `validateArchiveItem` helper split out of
  `validateMenuItem` (the recurring cyclomatic-complexity gotcha) enabling it only from a real local selection
  with a counterpart pane. App `xcodebuild build` + full `swift test` green.
- **Verified live via computer-use** (fresh Debug build after a full quit; `ArchivePacker`/`beginArchivePacking`/
  `file.pack` confirmed in the debug **dylib**): File menu showed **Pack… ⌥F5** enabled, grouped after Copy/Move.
  Marked 4 items (a dir + a spaced name + `weird[1].txt` + a plain file) → Pack sheet titled "Pack 4 items",
  name pre-filled **"left"** (source dir name), format popup listing all five with Zip first. Zip → `left.zip`
  landed **selected** in the other pane; on disk byte-exact and recursive (`photos/` + both jpgs, `alpha.txt`,
  `release notes.txt` space preserved, `weird[1].txt` glob-metachar preserved literally). Double-clicking it
  browsed straight back in (**📦 left.zip** breadcrumb, 4 items) — the full pack↔browse round-trip. Re-packing
  "left" raised the **"left.zip" already exists** Replace/Cancel confirmation; Replace re-created a valid
  archive. A single-file pack of `alpha.txt` titled "Pack "alpha.txt"", defaulted the name to **"alpha"**
  (extension stripped), and Tarball (gzip) produced a real gzip `alpha.tar.gz` containing `alpha.txt` — proving
  `bsdtar -a`'s suffix-driven format inference through the app path. GOTCHA (bsdtar): create-side arguments are
  **literal paths, not globs** (the opposite of extract/list members), so packing needs no escaping while
  extraction does. GOTCHA (architecture): packing is *not* a `CopyEngine` job (that's one backend for src+dest);
  it writes the archive directly, so it's its own `ArchivePacker` path with its own overwrite guard, mirroring
  how extraction went temp-extract-then-copy. NEXT M4: archive **writes** (add/delete inside a zip via
  rewrite-to-temp), nested archives, saved searches in the places strip, deferred search niceties.

Progress (2026-07-11, M4 pass 8): **archive delete inside (F8)** landed — the first half of "Archive
writes: add/delete inside zip", the last big ArchiveBackend gesture. Mark members inside a browsed
archive, F8 (or Shift+F8, or ⌘⌦), confirm, and they're removed from the archive on disk — a whole
directory drops its subtree, a glob-metachar name (`weird[1].txt`) or a spaced name (`release
notes.txt`) deletes exactly, and the pane re-lists the rewritten archive in place. The archive stays
`bsdtar`-driven (no libarchive C-module).
- **Why extract-and-repack, not `bsdtar --exclude @archive` (the design crux, validated live against
  bsdtar 3.5.3 / libarchive 3.7.4).** The obvious "re-stream the archive minus some members" trick
  can't delete an *exact* path: libarchive matches an exclude pattern against any **trailing subpath**
  and offers no anchoring — deleting `docs/api/x.md` *also* silently drops `outer/docs/api/x.md`, and a
  bare root `readme.txt` hits `readme.txt` at every depth (a leading `./` or `/` doesn't anchor; a
  leading `/` matches nothing). So the archive is instead **extracted whole** into a scratch dir, the
  targets removed there by their **real filesystem paths** (exact — a plain `removeItem`, zero glob
  ambiguity), and the surviving tree **repacked** into a fresh archive that **atomically replaces** the
  original. Costs a disk round-trip, but it's correct for every format uniformly and — the plan's
  "journal-safe temp file" — never touches the original until the repack fully succeeds.
- **Core (pure, tested).** `DirnexCore/…/VFS/ArchiveMutation.swift` = the pure argv half, mirroring
  `ArchiveExtraction`/`ArchivePacking`: `extractAllArguments` (`-x -f <arc> -C <work>`, no member list →
  everything out), `repackAllArguments` (`-a -c … -f <new> -C <work> .` — packs `.` so a delete-all
  still repacks a valid *empty* archive rather than failing on an empty arg list), `workingLocation`
  (the exact extracted on-disk path of an inner member — unescaped, since deletion is by literal path),
  and `temporaryArchiveName(forArchiveNamed:token:)` (a hidden `.dirnex-rewrite-<uuid>-<name>` sibling
  that keeps the original's **full** suffix so `bsdtar -a` re-infers the same container). GOTCHA
  (bsdtar `-a` format inference): `-a` reads `.zip`/`.7z`/`.tar`/`.tgz`/`.tar.*`/`.tbz*`/`.txz`/
  `.tar.zst` right but treats the zip-family aliases **`.jar`/`.cbz` as tar** — which would corrupt
  them on repack — so `formatOverrideArguments` adds an explicit `--format zip` for those (verified
  live). +5 `ArchiveMutationTests` → **318 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O boundary + wiring).** `Dirnex/Browser/ArchiveWriter.swift` (mirrors `ArchivePacker`/
  `ArchiveExtractor`) spawns the two `bsdtar` runs off-main into a `DirnexArchiveWrite/<uuid>/` scratch
  dir (`defer`-cleaned), repacks into the hidden sibling **in the archive's own directory** (same volume
  → the swap is atomic), then `FileManager.replaceItemAt` swaps it over the original and cleans a partial
  on any failure — the original is untouched unless the whole rewrite succeeds. `PanelViewController+
  ArchiveWrite.swift`'s `beginArchiveDelete()` gathers the marked/cursor members, raises a **critical**
  confirm ("Delete N items from “pkg.zip”? This rewrites the archive and can’t be undone."), runs the
  rewrite, then `(backend as? CompositeBackend)?.invalidateMountedArchive(at:)` drops the stale TOC and
  `refreshArchiveDirectory()` re-lists the current inner dir in place (its own archive-aware re-list,
  since the local-only `refreshCurrentDirectory` skips virtual panes; retreats to the archive root if the
  inner dir itself was deleted). Wiring: `CompositeBackend.invalidateMountedArchive(at:)` (new); F8/⇧F8/
  ⌘⌦ route via `deleteSelection` → `if isArchive { beginArchiveDelete() }` (before the `!isVirtualDirectory`
  guard); `validateMutatingItem` enables both delete items inside an archive (`isArchive` → non-empty
  selection); `AppDelegate` adds `ArchiveWriter.purgeTemporaries()` beside the extractor's. Archive delete
  is **not undoable** (a rewrite, like a permanent delete) — the confirm says so; nothing is journaled.
  App `xcodebuild build` green, new methods confirmed in the debug **dylib**.
- **Verified live via computer-use** (fresh Debug build after a full quit): File menu inside an archive
  showed **Move to Trash / Delete Immediately… enabled** with Move/Pack/Rename/Multi-Rename/New Folder
  still greyed. In `pkg.zip` marked a dir (`docs`) + a spaced name + `weird[1].txt` → "Delete 3 items
  from “pkg.zip”?" → on-disk the three gone, `images`/`alpha.txt`/`readme.txt` byte-exact, archive VALID,
  **zero `.dirnex-rewrite-*` litter**, scratch dir cleaned. The **over-match safety case** (`dup.zip` with
  `a/notes.txt` AND `b/notes.txt`): deleting `a/notes.txt` (⌘⌦, single-item confirm) left `b/notes.txt`
  intact with content "B" — the exact case `--exclude` would have corrupted. Delete-all (mark `a`+`b` at
  root) → a valid **empty** archive that still browses (0 items + `..`). NEXT M4: archive **add-into**
  (paste / F5 / F6 *into* an archive pane — the extract-repack engine is symmetric), nested archives,
  saved searches in the places strip, deferred search niceties.

Progress (2026-07-11, M4 pass 9): **archive add-into (paste ⌘V / F5 / F6)** landed — the *second*
half of "Archive writes: add/delete inside zip" (**that M4 line now `[x]`**), the symmetric inverse
of pass 8's delete. Drop local files/folders onto a browsed archive pane and they're written into the
archive on disk, at whatever inner directory the pane is showing; a same-named member is a *replace*
(confirmed first); F6 additionally trashes the local originals. The archive stays `bsdtar`-driven (no
libarchive C-module).
- **Symmetric with delete — one rewrite, two edits.** Add and delete are the *same* extract-whole →
  edit-the-scratch-tree → repack → atomic-swap flow (see pass 8 for why an in-place `bsdtar`
  streaming edit can't target an exact path); only the edit differs. `ArchiveWriter` was refactored so
  both go through one private `rewrite(archiveOnDiskPath:edit:)` that owns the scratch dir, the
  extract-all, the repack into a hidden `.dirnex-rewrite-<uuid>-<name>` sibling, and the
  `FileManager.replaceItemAt` swap (journal-safe: the original is untouched until the repack fully
  succeeds). `delete`'s edit `removeItem`s members by `workingLocation`; the new `add`'s edit
  `copyItem`s each source into `additionDirectory` (the inner dir mapped into the scratch tree),
  replacing a same-named member first (so `copyItem` never fails on an existing dest).
- **Core (pure, tested).** Two helpers added to `DirnexCore/…/VFS/ArchiveMutation.swift` (whose doc now
  covers add *and* delete): `additionDirectory(forInnerDirectory:inWorkingDirectory:)` (`/docs` →
  `<workDir>/docs`, archive root `/` → `<workDir>` itself — leading slash stripped like
  `workingLocation`, but the root case handled explicitly so it never appends an empty component) and
  `collidingNames(addingNames:existingNames:)` (the added names that already exist, matched
  **case-insensitively** — the archive extracts onto case-insensitive APFS, so `README`/`readme`
  collide on disk regardless of the archive's own case sensitivity — preserving the added spelling +
  order so the confirm can list them). The extract/repack argv is reused verbatim from delete. +2
  `ArchiveMutationTests` → **320 core tests**, swiftformat/swiftlint-strict clean.
- **App (I/O + wiring).** `ArchiveWriter.add(localPaths:toInnerDirectory:ofArchiveAt:)` runs the shared
  rewrite off-main. NEW `PanelViewController+ArchiveAdd.swift`: `beginArchiveAdd(localSources:kind:
  from:)` (on the *destination* archive pane) lists the dest inner dir off-main for its real member
  names, computes collisions, raises a **Replace/Cancel** warning only if any exist (a clean add needs
  no confirm — matching how a local paste "just works"; the pack flow's precedent), then `runArchiveAdd`
  invalidates the stale mount (`CompositeBackend.invalidateMountedArchive`) + `refreshArchiveDirectory`
  re-lists in place. `pasteIntoArchive()` stats the pasteboard URLs into local sources and funnels in;
  `removeArchiveMoveOriginals(_:)` (on the *source* pane) trashes the F6 originals afterward + journals
  `UndoRecord.trash` — so the move's local half is undoable even though the archive rewrite isn't.
  Entry points route in `PanelViewController+Copy` (F5/F6 → `archiveDestinationPane()` when the
  counterpart `isArchive`, `.copy`/`.move`), `PanelViewController+Clipboard` (⌘V → `pasteIntoArchive`
  when `isArchive`; ⌥⌘V move-paste into an archive is left out this pass), and `validateMenuItem`
  (Paste enabled via `canWriteHere || isArchive`; Copy/Move-to-other-pane already allowed a local
  source + any counterpart). App `xcodebuild build` green, new methods confirmed in the debug **dylib**.
- **Verified live via computer-use** (fresh Debug build after a full quit; left pane = local `incoming/`,
  right pane browsing `box.zip`). **F5 clean multi-add** (`pics/`+`alpha.txt`+`beta.dat`, no collision,
  no confirm) → all three written byte-exact incl. the recursive `pics/one.png`, original `docs/guide.md`
  + `readme.txt` intact, re-listed in place, **zero `.dirnex-rewrite-*` litter**. **F5 collision**
  (`readme.txt`) → "Replace “readme.txt” in “box.zip”?" → Replace → archive `readme.txt` flipped to the
  new content, still one copy (no dup), `docs` intact. **⌘V paste** (`gamma.txt`) → added byte-exact.
  **F6 move** (`delta.txt`) → written into the archive AND the local original gone from `incoming/`
  (Trash), Edit menu showed **"Undo Move to Trash ⌘Z"**, and the undo restored `incoming/delta.txt`
  ("DELTA moved") while the archive kept its copy (rewrite not undoable, local trash half is). Scratch
  dir empty after each op. Fixtures deleted. NEXT M4: nested archives (browse/extract a zip inside a
  zip), saved searches as places-strip virtual folders, deferred search niceties (tag chip,
  content-grep fallback); archive drag-drop-in and ⌥⌘V move-paste-in are small follow-ons on this engine.

Progress (2026-07-12, M4 pass 10): **nested archives — browse/extract a zip inside a zip** landed —
the last open ArchiveBackend gesture (**that M4 line is now `[x]`**, so `ArchiveBackend` is complete).
Entering a browsable archive *member* while already inside an archive extracts that member to a temp
file (with `bsdtar`, via `ArchiveExtractor` — the same path as Quick Look inside and F5 copy-out) and
browses *that* file's virtual contents; "go up" walks back out to the enclosing archive's inner
directory (landing on the member), the breadcrumb spans the whole chain, and F5 copy-out works from
any depth. A nested mount is the extracted temp copy, so it's **read-only** this pass (writing back
through nesting is a later item), matching the app's capability-degradation pattern.
- **The crux — provenance, not a new backend id.** An inner archive has no on-disk path of its own,
  and the `archive:…` backend id encodes an *on-disk* path, so entering one first extracts the member
  to a temp file and mounts *that* path (the existing `CompositeBackend` lazily mounts it like any
  archive — no routing change). What's new is remembering where each temp mount came from, so "go up"
  returns to the *outer* archive's inner directory (onto the member) instead of dumping the user into
  the temp extraction dir, and the breadcrumb reads `outer.zip ▸ sub ▸ inner.zip ▸ …` rather than a
  bare temp name. A temp→origin(`VFSPath`) map chains for arbitrary depth (each step moves to a
  strictly-outer archive).
- **Core (pure, tested).** NEW `DirnexCore/…/VFS/NestedArchiveMap.swift` = a `Sendable` value type:
  `record(mount,origin)`, `origin(ofMountOnDiskPath:)` (the up-nav anchor + the nested-vs-top-level
  test), `mountOnDiskPath(forOrigin:)` (reuse a prior extraction instead of re-spawning `bsdtar`), and
  `ancestry(ofMountOnDiskPath:)` (the enclosing members outermost-first for the breadcrumb — walks the
  temp→origin→enclosing-archive chain and reverses). +5 `NestedArchiveMapTests` → **325 core tests**,
  swiftformat/swiftlint-strict clean.
- **App (I/O + wiring).** NEW `NestedArchiveRegistry.swift` (`@MainActor` wrapper: the pure map + the
  FileManager side — recording, and confirming a reused temp still exists), owned by
  `BrowserWindowController` and shared across both panes via `PanelHost` (mirroring `ArchivePreviewCache`).
  NEW `PanelViewController+NestedArchive.swift`: `beginNestedArchiveEntry(for:)` extracts the member
  off-main and navigates in (reusing an extant extraction); `isNestedArchive`/`isWritableArchive` (the
  read-only gate); `archiveBreadcrumbAncestry()`. Wiring: `openCurrentEntry` routes a browsable-archive
  member *inside* an archive into the nested entry; `goUpWithinArchive` returns to the origin's parent
  focused on the origin when the mount has one; `PathBarView.rebuildArchiveLabel` takes the ancestry and
  renders the full chain; the write gates (F8 delete, F5/F6 add-into, ⌘V paste-into) switch from
  `isArchive` to `isWritableArchive`, and `beginTransfer` now guards a *local* destination so an F5
  toward a read-only nested archive (or a search pane) reports "can't copy here" instead of erroring
  deep in the queue. App `xcodebuild build` green.
- **Verified live via computer-use** (fresh Debug build after a full quit): browsed `outer.zip` →
  entered its `inner.zip` (breadcrumb `📦 outer.zip ▸ inner.zip`, inner `docs`/`hello.txt` shown); `..`
  returned to `outer.zip` root with the cursor **on `inner.zip`**. The **doubly-nested**
  `outer2.zip ▸ sub ▸ mid.zip ▸ inner.zip` browsed all four levels (full breadcrumb) and `..` from
  `inner.zip` landed at `mid.zip` root onto `inner.zip`. The File menu inside a nested archive showed
  **Copy to Other Panel enabled** but **Move to Trash / Delete Immediately / Pack / Rename / New Folder
  greyed** (read-only). **F5 copy-out** of `mid-note.txt` from the doubly-nested `mid.zip` landed
  byte-exact ("MID level") on real disk. Zero `.dirnex-rewrite-*` litter (reads never rewrite); the
  only temp is `DirnexExtract/` (purged at launch, like previews and F5). Fixtures deleted; app left on
  Home. NEXT M4: saved searches as places-strip virtual folders, deferred search niceties (tag chip,
  content-grep fallback); archive drag-drop-in and ⌥⌘V move-paste-in remain small follow-ons, and
  writing back through nesting (edit an inner archive, re-embed it) is the natural next archive-write item.

Progress (2026-07-12, M4 pass 11): **saved searches as places-strip virtual folders** landed —
the last open M4 checklist item (**that line is now `[x]`**), macOS's answer to Finder's Smart
Folders. Name the query behind a live results panel via **Go ▸ Save Search…**, and it lands in a
new **Searches** section of the sidebar (magnifier icon); clicking it re-runs the query into a
fresh virtual results tab; right-click → **Run Search / Rename… / Delete**. Reuses the whole
existing search stack (⌥F7 `SpotlightQuery` → `SpotlightSearchRunner` → virtual `.search` panel) —
a saved search is just that query + a name + a scope, persisted.
- **Core (pure, tested).** NEW `DirnexCore/…/Services/SavedSearch.swift` mirrors `Workspaces`
  *exactly* (name-as-identity): `SavedSearch` (name + `SpotlightQuery` + optional `scope: VFSPath?`,
  `id == name`) and `SavedSearches` (ordered, name-de-duped list: `save` overwrites-in-place-else-
  appends, `remove`, `rename` rejecting empty/collision, `move`, custom Codable that re-sanitizes on
  decode). To persist a query, `SpotlightQuery` gained `Codable` (synthesized — every field already
  was) plus `summaryPlainName` (the `summary` precedence without the display quotes, so the Save
  prompt prefills an editable default). New command `go.saveSearch` ("Save Search…", no shortcut —
  sidebar-driven, conflict-free). +15 tests (`SavedSearchTests` 13, a `SpotlightQuery` Codable +
  plain-name pair, a `CommandCatalog` saveSearch case) → **341 core tests**, swiftformat/swiftlint-
  strict clean. GOTCHA (recurring, hit again): the Testing `#expect` macro captures its argument
  immutably, so a `mutating` call (`list.save`/`rename`/`remove`) must be hoisted into a `let` first
  — see [[swift-testing-expect-optional-arithmetic]]'s sibling gotcha.
- **App (persistence + sidebar + save flow).** NEW `SavedSearchStore.swift` (UserDefaults JSON like
  `HotlistStore`/`WorkspaceStore`, plus a `didChangeNotification` posted on every save so open
  sidebars — even in another window — rebuild live). `PanelTab` gained `searchQuery`/`searchScope`
  (session-only, never encoded), set when `openSearchResults` installs a results tab, so
  `saveCurrentSearch` can recover exactly what produced them; `runSavedSearch` re-runs a stored query
  against its *absolute* scope (not the pane's current dir). `SidebarViewController` grew a
  `.savedSearch` row + a **Searches** section (rebuilt on `didChangeNotification`), a magnifier
  template icon, a `NSMenuDelegate` context menu built lazily from `clickedRow` (empty ⇒ no menu on
  non-search rows), and Rename/Delete that mutate the store directly; Run + row-click route through a
  new `didActivateSavedSearch` delegate call the window controller runs on the active pane.
  `validateMenuItem` enables Save Search… only on a results pane carrying a query (`canSaveCurrentSearch`).
  Wiring: `go.saveSearch` in `CommandBinding` + `MainMenuBuilder` (Go menu, after Find Files…).
  App `xcodebuild build` green; new code confirmed in `Dirnex.debug.dylib`; touched files
  swiftformat/swiftlint-strict clean.
- **Verified live via computer-use** (fresh Debug build after a full quit; no overlay this session):
  Go ▸ **Save Search…** was greyed on a normal pane, enabled after a ⌥F7 "jmeter" search (3 hits) —
  the prompt prefilled the unquoted default **"jmeter"**, saved as "JMeter Stuff" → appeared under a
  new **Searches** header with a magnifier icon (sidebar rebuilt live). Clicking it re-ran into a
  fresh `*jmeter*` results tab (same 3 hits). Right-click → **Run / Rename… / Delete**: Rename →
  "Perf Tests" updated the row live; Delete removed the whole section live. Re-saved as "jmeter",
  **quit + relaunched** → the Searches section persisted with "jmeter" (while the virtual results
  tabs correctly did *not* restore); deleted it to leave the app clean on Home. NEXT M4: deferred
  search niceties (tag chip, content-grep fallback for non-indexed volumes); archive drag-drop-in and
  ⌥⌘V move-paste-in remain small follow-ons, and writing back through nesting (edit an inner archive,
  re-embed it) is the natural next archive-write item. **The M4 checklist is now fully `[x]`.**
- **Follow-on (same day): ⌘S saves the active search.** `go.saveSearch` gained a **⌘S** shortcut
  (distinct from ⌃⌘S Show Sidebar — the conflict checker compares key *and* modifiers, so they
  don't collide). Because `validateMenuItem` already gates it on `canSaveCurrentSearch`, AppKit
  only fires the key equivalent when a search-results tab carrying a query is active — on any
  other pane ⌘S is an inert no-op, not a mis-save. Verified live: the Go menu reads **Save
  Search… ⌘S**; ⌘S on the `*jmeter*` results tab opened the Save sheet; ⌘S on the normal `oleg`
  tab did nothing. `coversSaveSearch` updated to assert the shortcut + conflict-freedom (still
  **341 core tests**).

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
