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

## Pitfalls already paid for

- Run `xcodebuild`/`xcodegen` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (`xcode-select` points at CommandLineTools). `scripts/xcb.sh` sets it.
- DerivedData must live outside iCloud-synced folders; `xcb.sh` uses
  `~/Library/Developer/Xcode/DerivedData/VideoTool-cli`.
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
- The prototype's mpv writes `prototype/mpv-config/watch_later/` (local video
  paths) and `prototype/last-run.log`; both are gitignored, keep it that way.
