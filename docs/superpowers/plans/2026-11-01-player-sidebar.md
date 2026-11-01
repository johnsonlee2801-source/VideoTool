# Player Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Run inline in the current session; no delegation or nested model calls.

**Goal:** Replace the separate library window with a resizable player sidebar containing 视频库、最近播放、星标.

**Architecture:** Keep existing indexing, grouping, history and bookmark stores. Extract library presentation from its window lifecycle; a unified sidebar owns presentation and focus while PlayerWindowController owns playback and layout.

**Tech Stack:** Swift, AppKit, MPVKit/libmpv, SQLite, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-01-player-sidebar-design.md`

## Global Constraints

- Work only in VideoTool; preserve the existing untracked `.codex-suite/` audit record.
- All Git commands use `--no-optional-locks`; do not inspect secrets or account files.
- Reuse AppData for preferences and test isolation. Indexing never moves user files.
- Sidebar width 380 pt by default, adjustable 280–560 pt, player keeps at least 240 pt.
- Keep three tabs, existing speed gestures, native fullscreen, clipping, stars and Chinese/English/Japanese localization.
- Do not hand-edit xcodeproj: regenerate with scripts/regen.sh.
- User authorized continuous implementation, verification, local app update and the project's ordinary GitHub sync; no additional plan confirmation needed.

## Review Focus

1. Search/list focus must not route arrows or Space into player seek/pause: test real first-responder paths in Task 3.
2. Recent videos outside the library and missing files must preserve records: test distinct paths, dates and missing-file opening in Task 2/3.
3. A narrow window or invalid stored width must not collapse the video or generate impossible constraints: test 520/900/1280 pt and NaN in Task 2/3.
4. Closing/switching tabs must not cancel a requested index pass or lose search/scroll state: test indexing lifecycle and restored views in Task 3.
5. Database open failure must retry on next expansion, while shutdown removes observers/timers: test provider failure/recovery and callback lifecycle in Task 3.

### Task 1: Single-window entry and reusable library presentation

**Files:** Modify AppDelegate.swift, LibraryUI/LibraryWindowController.swift (replace window controller with reusable browser), LibraryWindowTests.swift and affected snapshot/action tests.

**Interfaces:** `AppDelegate.showLibrary(_:)` routes to `PlayerWindowController.showLibrary(_:)`; `LibraryBrowserViewController(controller:onOpen:)` is embeddable and creates no NSWindow. AppDelegate supplies a lazy `() -> LibraryController?` provider so database failures can retry.

- [ ] Add a failing existing-API test: calling showLibrary creates/uses the player's one window and does not create a window titled 视频库.
- [ ] Run the test via `scripts/xcb.sh test -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -only-testing:VideoToolTests/PlayerSidebarTests`; verify real assertion failure.
- [ ] Extract browser content/lifecycle and route the entry to the player sidebar; update existing tests to host embedded content explicitly.
- [ ] Run browser and entry tests; require actual discovered tests and exit 0.

### Task 2: Sidebar state and recent-playback data

**Files:** Create Player/PlayerSidebarState.swift and LibraryUI/RecentPlaybackViewController.swift; modify Playback/WatchHistory.swift and relevant tests.

**Interfaces:** `PlayerSidebarTab` (.library/.recent/.stars); `PlayerSidebarState` stores open/tab/preferredWidth with `show(_:)`, `toggleStars()`, `close()` and `fittedWidth(available:)`. `PlayerSidebarPreferences(defaults:)` persists state via AppData.defaults. `RecentPlaybackItem` merges `WatchHistoryStore.all` with indexed LibraryItem rows and sorts by date, then path. History publishes change events after successful writes and supports recording successful file opens without resetting finished/progress metadata.

- [ ] Write behavior tests for default/restore, tab transitions, finite width clamping, deterministic recent ordering and unindexed/missing entries; run red before implementing each behavior.
- [ ] Implement state, preferences, recent rows and history signals with weak observer lifetimes; keep old storage schema compatible.
- [ ] Run state/history/recent tests and existing watch-history regressions; require exit 0.

### Task 3: Unified sidebar, compact library UI and playback integration

**Files:** Create Player/PlayerSidebarView.swift; modify PlayerWindowController.swift, library browser, tests and project.yml (source discovery), then regenerate.

**Interfaces:** PlayerSidebarView owns three retained tab views and `state`, emits layout changes/open requests, and exposes focus containment. Library browser uses compact horizontal thumbnail rows, search, mode/folder controls and existing menu actions. PlayerWindowController embeds the sidebar beside the video and retains listPanel as the bookmark view for compatibility with current behavior tests.

- [ ] Write failing tests for three labels, width/restore, switching without pause, Ctrl/Command shortcuts and list/search first-responder behavior.
- [ ] Add failing tests for actual hit-test fullscreen exclusions, missing-file error, provider retry and closing during indexing.
- [ ] Implement shared sidebar region, drag divider, persistence, button/shortcut routing and event-driven/throttled data refresh.
- [ ] Record successful local file load immediately in history; keep playback progress updates and star changes reflected without focus-switch refresh.
- [ ] Keep indexing alive on tab switches/collapse, cancel it on player shutdown; remove observers and pending work on shutdown.
- [ ] Run sidebar, browser, bookmark, event glue, history and player wiring regressions; require exit 0.

### Task 4: Visual/localization review, complete verification and delivery

**Files:** Tests/VideoToolTests/UISnapshotTests.swift, i18n resources, README languages, AGENTS.md settled behavior, CHANGELOG.md, this plan/progress ledger.

- [ ] Add snapshots for populated library/recent/stars, empty state and narrow player; inspect generated images and address layout defects.
- [ ] Extract/build translations; localization tests must discover and pass every UI string.
- [ ] Run `node tools/tdd-guardian/local/gate.js push` and both required secret scans, retaining real results/source fingerprints.
- [ ] Run CC Suite full scoped audit of this feature against baseline 0f073a2, separate from implementation; reproduce/fix actionable findings with tests and rerun affected checks.
- [ ] Build Release using cached resolved dependencies, preserve previous installed app, install and verify native single-window/sidebar playback behavior where UI automation is available; disclose limitations.
- [ ] Commit only feature files and dated Chinese update notes, push origin main, verify remote HEAD. No new DMG/Release without a separate release request.

## Execution ledger

- Baseline: 0f073a2b501cf8531afc1534b18e74e84d4c006b; tracked tree clean; pre-existing untracked audit record and approved design document.
- Ruling: execute in the user-designated current project, without a new worktree or additional agents; the user requested completion in this session and existing main-branch publication workflow. Preserve all unrelated files.
- Pre-flight: Task 1 browser/provider feed Task 3; Task 2 state/history feed Task 3; Task 4 verifies all three. One cohesive feature commit follows the final gate, so partial UI transitions are not published as finished steps.
- Plan self-review: design sections map to Tasks 1–4; test focus cases above have explicit owners.
- Task 1: single-window entry assertion failed twice against the baseline, then passed after extraction/routing. LibraryWindowController is replaced by LibraryBrowserViewController; all old UI tests now use an explicit test-only host window.
- Task 2: state/recent/history tests ran with real assertions red (7 tests, 19 issues), then green (7/7); logs `/private/tmp/videotool-sidebar-model-{red,green}.log`.
- Task 3: first integrated regression passed 55 tests across 9 suites, including actual mpv load, history, sidebar, event glue, localization and snapshots; `/private/tmp/videotool-sidebar-regression.log`.
- Validation follow-up: SB9/SB10 reproduced hidden-progress staleness and selection loss, then passed after store refresh on reopen and path-based selection restoration; `/private/tmp/videotool-sidebar-refresh-{red,green}.log`.
- Validation follow-up: W6 reproduced using a fixed compact inset during a width transition; W7 proved native flow invalidation did not re-query delegate metrics; W8 reproduced the new-clip/old-collection width transition. Row sizing now fits both live viewport and bounds with actual insets, with delegate metric invalidation. Final layout logs contain zero constraint or item-width diagnostics; temporary numeric probes were removed.
- Validation follow-up: SB4 reproduced implicit database retry on divider drag. Width changes now persist/layout only, without presenting or reloading content.
- Ruling: render compact rows for the sidebar and retain the browser's responsive wide layout for explicit test/documentation hosts; there is no production standalone library window or hidden window dependency.
- Task 3: complete. Final acceptance passed 42 tests in 6 suites; actual library tab button, folder/search combination, state/history, every fullscreen exclusion and UI snapshots were verified. `/private/tmp/videotool-sidebar-acceptance.log`.
- Real playback integration: PlayerWiringTests passed 12 tests, including SBP1 immediate history on file load, SBP2 compact card double-click and SBP3 unindexed recent row opening in the same player. `/private/tmp/videotool-sidebar-player-integration.log`.
- Task 4 / CC Suite: current-session full scoped review completed across all new/changed application files, event/data callers, test hosts, localization and generated project references. No remaining actionable findings after the reproduced fixes above. This is author self-review, not an independent-agent review. UI snapshots for library/recent/stars/empty/narrow were inspected; native picker/Finder and real device casting are not automated by these checks.
- Ruling: the history-notification test helper reads the just-written isolated UserDefaults row directly to avoid a new Sendable capture warning; its assertions and behavioral contract were preserved. No passing gate state or red receipt was written by hand.
- Task 4 / full gate: actual source-bound push gate passed: core 68, unit 514 with 2 documentation screenshot skips, integration 66, prototype pass, Guardian 325. Combined app count 580. `/private/tmp/videotool-sidebar-full-gate.log`.
- Task 4 / Release: cached-dependency Release build and deep strict signature verification passed; executable SHA256 `1501202e15ca7f78caf1752231785a011248e6b969aab2f70fd8180994ea8df7`. `/private/tmp/videotool-sidebar-release.log`.
- Task 4 / installation: deferred by the user's explicit reply “先完成 GitHub，本机稍后更新”. CUA returned cgWindowNotFound and the old installed process remained active; no installed app files were replaced or process forcibly stopped. Native installed UI acceptance is not claimed. The design and core requested implementation/verification are complete; GitHub publication is the final current-scope step.
