# VideoTool — agent instructions

macOS video player: Swift + AppKit shell on libmpv (MPVKit). See README.md for
goals, layout, build and test commands. `CLAUDE.md` only imports this file.

## Workflow

- Test first. Write the failing test, run it red, implement, run green, then a
  review pass. Every user decision about behaviour lands as a test.
- Keep logic in small pure units (VideoToolCore, `App/Sources/Playback/*`) and
  keep AppKit/libmpv glue thin; the glue gets integration tests against real mpv.
- Never hand-edit `VideoTool.xcodeproj`: change `project.yml`, then
  `scripts/regen.sh` (it also writes `App/Info.plist` from `x-info-properties`).
- Push to `origin` (private GitHub repo) after each finished step.

## Settled behaviour (user decisions)

- Hold left mouse on video → 2.0×. Drag right: +0.1× per 20 pt up to 3.0×,
  then +0.1× per 10 pt up to 6.0×. Drag left: −0.1× per 20 pt down to 0.5×.
  Release restores the previous speed. Short click toggles pause.
- A key pressed while the gesture is active (button down, before or during the
  hold) only cancels it; Space does not also pause (`KeyRouter.plainKeyCancelsOnly`).
- The library feature will index and classify, never move user files.
- Starred moments (step 3, decided 2026-10-18): press **B** to star the current
  time without pausing or prompting. B while the speed gesture is active follows
  the general rule: it only cancels the speed-up and does NOT star. Jumping to a
  star lands **2 s before** it. Built as proposed: yellow star markers with
  hover time/note/thumbnail, click snapping, ⌥←/⌥→ for prev/next, double-B at
  the same spot undoes (distance scales with playback speed), identity by
  OSHash, SQLite storage, `endTime` reserved for clipping.
- Thumbnails come from a separate software-rendering libmpv instance
  (`MPVThumbnailMaker`): the main player's frames are VideoToolbox and MPVKit's
  FFmpeg has no image encoders.

## Visual design (2026-10-18, user asked for "sharper, younger")

- All colours, radii and fonts come from `App/Sources/Theme.swift`: near-black
  surfaces, hot-pink accent `#FF2E63` with cyan `#08D9D6`, pink→violet progress,
  yellow stars `#FFD60A`, heavy type, 5–8 pt radii, dark appearance everywhere.
  `ThemeTests` pin WCAG contrast; add a test before adding a new text colour.
- Review UI changes with `scripts/xcb.sh test -only-testing:VideoToolTests/UISnapshotTests`;
  PNGs land in `~/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex/snapshots/current/`.
- `scripts/coverage.sh` runs every test with coverage and lists files weakest first;
  it fails below 90% lines (2026-10-19: 92.2%). Code that only opens system UI
  (open panel, browser, default-app prompts, pop-up menu tracking) and real
  translation with an installed language pack stay manual checks. AppKit glue is tested by feeding
  synthesized events to `PlayerWindowController.handleKeyDown` and `PlayerView`
  (`PlayerEventGlueTests`); keep new event handling reachable that way.
- `tools/stress_library.sh N` measures indexing N files (2026-10-18: 1000 in 31 s,
  2000 in 63 s, memory flat at ~470 MB). Rerun it after touching `LibraryIndexer`.
- `tools/quality_check.sh` plays 4K HEVC HDR10, 4K60 H.264 and long-GOP clips in a
  real window (hardware decoding, CPU, dropped frames, seek latency, HDR). Run it with
  the screen on and unlocked: with the display asleep, frame/seek numbers are invalid
  and the results say `"screenLive": false`.
- Tests never touch the user's data: `AppData` switches the database, thumbnails,
  subtitles and preferences to a per-run temp location under the test runner. New
  stores must take their location/defaults from `AppData`.
- AI subtitles (macOS 26+): `tools/make_speech_fixture.sh` rebuilds the spoken test
  clip; the recognition test uses the real on-device recogniser.
- Casting step 2 (picture to Apple TV) is planned in `docs/plans/casting-step2.md`
  and must be verified on a real device before it ships.
- Library cards follow video-site habits: 16:9 cover, duration badge bottom-right,
  4K/HD top-left, star count top-right, tag chips; columns adapt to window width.

## Pitfalls already paid for

- Run `xcodebuild`/`xcodegen` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (`xcode-select` points at CommandLineTools). `scripts/xcb.sh` sets it.
- DerivedData must live outside iCloud-synced folders; `xcb.sh` uses
  `~/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex`.
- In the Claude agent sandbox, SwiftPM, xcodegen and package resolution do not
  run (nested sandbox, system temp dir). Use `VideoToolCore/scripts/test-direct.sh`
  for core tests; run `xcb.sh` and `regen.sh` outside the sandbox.
- MPVKit's FFmpeg has no lavfi device: integration tests use the bundled
  `Tests/Fixtures/testsrc-20s.mp4`, read from the test bundle, never the source
  tree (ad-hoc re-signing re-triggers macOS folder-access prompts that block `open()`).
- `MPVRenderLayer` must create its render context in `init`, or a file opened at
  launch renders nothing ("No render context set").
- Teardown only through `PlaybackSession.shutdown()` (render context before mpv).
- Swift Testing: xcodebuild's "Executed 0 tests" is the XCTest counter; the real
  result is the `Test run with N tests` line. Exit code 65 = test failure.
- `/opt/homebrew/bin/sample` shadows the system profiler; use `/usr/bin/sample`.
- Default apps: on current macOS only NSWorkspace.setDefaultApplication works and it
  asks the user to confirm each type. LSSetDefaultRoleHandlerForContentType returns
  success but changes nothing. Never try to switch defaults unattended.
- Before any push: `scripts/check-secrets.sh && scripts/check-secrets.sh --history`
  (the pre-push hook from `scripts/install-hooks.sh` runs both). Personal patterns
  live in `.git/info/secret-patterns`, never in the repo.
- The prototype's mpv writes `prototype/mpv-config/watch_later/` (local video
  paths) and `prototype/last-run.log`; both are gitignored, keep it that way.
