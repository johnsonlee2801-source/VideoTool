# Contributing to VideoTool

VideoTool is licensed under the [MPL-2.0](LICENSE). By contributing you agree that
your contribution is licensed under the same terms.

Thanks for helping. This page is for people who build and change VideoTool; the
[README](README.md) is for people who use it. Project rules for coding agents
are in [AGENTS.md](AGENTS.md).

## Build

Requirements: macOS 14+, Xcode 16+ (developed on Xcode 27),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```zsh
scripts/regen.sh          # App/Info.plist and VideoTool.xcodeproj from project.yml
scripts/xcb.sh build      # Debug build, ad-hoc signed
scripts/install.sh        # Release build → /Applications/VideoTool.app
```

The first build downloads MPVKit's prebuilt xcframeworks (~250 MB). `xcb.sh`
keeps all build state in `~/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex`:
inside an iCloud-synced folder Xcode's package resolver silently resolves
nothing. Never hand-edit `VideoTool.xcodeproj`; change `project.yml`.

## Tests

Work test-first: write the test, see it fail for the right reason, then change
the code. Tests use Swift Testing.

| Lane | Command | Covers |
|---|---|---|
| Core | `VideoToolCore/scripts/test-direct.sh` | speed curve, hold/drag state machine |
| Unit | see `.claude/tdd-guardian/config.json` (`unit`) | everything that needs no decoding or speech models |
| Integration | see `.claude/tdd-guardian/config.json` (`integration`) | real libmpv playback, every bundled format, AI subtitles with the on-device recogniser, audio at speed |
| Prototype | `prototype/tests/run.sh` (needs `luajit`) | the original Lua gesture |
| Everything | `scripts/xcb.sh test` | all of the above app tests (~470) |
| Coverage | `scripts/coverage.sh` | per-file line coverage; fails below 90% |

Opt-in measurement suites (they generate large clips outside the repo):

- `tools/stress_library.sh N`: index N files (time and memory).
- `tools/quality_check.sh`: 4K HEVC HDR10, 4K60 and long-GOP clips in a real
  window (hardware decoding, CPU, dropped frames, seek latency). Run it with the
  screen on and unlocked; with the display asleep, frame and seek checks are
  reported as skipped.

Tests never touch your data: under the test runner, `AppData` points the
database, thumbnails, subtitles and preferences at a per-run temp folder, the
player makes no sound, and old runs' leftovers are removed.

## Interface languages

Chinese is the source language: the lookup key *is* the Chinese text.

```zsh
# 1. wrap new interface text in L("…") (L("共 %@ 个视频", n) for arguments)
tools/i18n.py extract     # list the keys → App/Resources/i18n/keys.json
# 2. add "en" and "ja" for new keys in App/Resources/i18n/translations.json
tools/i18n.py build       # → App/Resources/{en,ja,zh-Hans}.lproj/Localizable.strings
tools/i18n.py check       # every key translated, placeholders kept
```

`LocalizationTests` fail if a string in the code has no translation.

## README screenshots

`tools/make_docs_screens.sh` renders the screenshots in `docs/images/<lang>/`
in all three languages. The footage is generated with ffmpeg (fractals,
gradients, cellular automata), so the images carry no third-party content.

## Before you push

`scripts/install-hooks.sh` installs a pre-push hook that runs
`scripts/check-secrets.sh` over the history being pushed: keys, tokens, home
paths and personal identifiers block the push. Put your own patterns in
`.git/info/secret-patterns` (never committed). Commit with your GitHub noreply
address.

## Layout

- `VideoToolCore/`: Swift package with the pure gesture logic.
- `App/Sources/Player/`: libmpv engine, OpenGL render layer, `PlaybackSession`,
  the player window and its views.
- `App/Sources/Playback/`: small pure units (keys, resume, speed, history, audio output).
- `App/Sources/Library/`, `LibraryUI/`: scanning, indexing, grouping, series, the library window.
- `App/Sources/Subtitles/`: AI subtitles (audio extraction, Apple Speech/Translation, cues, SRT).
- `Tests/`: app tests and fixtures (bundled into the test target).
- `tools/`, `scripts/`: build, install, measurement, translation and screenshot tools.
- `prototype/`: the mpv + Lua prototype used to tune the gesture.

## Feedback

In the app: **Help › Send Feedback…** opens a pre-filled GitHub issue.
