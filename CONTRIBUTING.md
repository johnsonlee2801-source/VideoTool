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

### Codex TDD Guardian

The repo-local bundle at `tools/tdd-guardian/` is based on xiaolai's ISC-licensed
TDD Guardian, pinned in `UPSTREAM.json`. Its local adapter rejects timestamp-only
state, a failed rerun, and source/configuration changes after a pass. A dirty tree
can earn a pass, but the tested contents must stay unchanged. Swift Testing counts
are parsed separately from XCTest's `Executed 0 tests` summary.

Run from the repo root:

```zsh
node tools/tdd-guardian/local/gate.js commit  # every commit lane, real execution
node tools/tdd-guardian/local/gate.js core    # only the core lane
node tools/tdd-guardian/local/status.js       # read-only readiness
```

Codex discovers its skills through `.agents/skills/` and its project hook through
`.codex/hooks.json`, with hooks enabled by `.codex/config.toml`. No global plugin
registry or configuration is changed. In a new Codex session, use `/hooks`
to review and trust `tools/tdd-guardian/local/pretool.js`. Until that native trust
step is complete, the automatic commit/push guard is not active; the explicit
runner still works. Passing a gate does not authorize a commit or push.

This adapter enforces the existing lane gates. Coverage/mutation policy is
currently disabled in the shared config; it refuses to refresh gates if those
policies are enabled without an explicit adapter. `scripts/coverage.sh` remains
the separate 90% application coverage check.

Validate the bundled tool with `cd tools/tdd-guardian && node --test`.

### Optional YouTube acceptance

Offline regression tests cover URL validation, resolver isolation/cancellation,
mpv file options, local/network transitions, stars, resume and the input sheet.
`YouTubePlaybackTests` runs in the integration lane. A separate live test is
disabled by default and uses one public YouTube Developers example video:

```zsh
scripts/xcb.sh test -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:VideoToolTests/YouTubeLiveTests VIDEOTOOL_YOUTUBE_LIVE=1
```

This requires installed yt-dlp and Deno plus working YouTube/CDN access. It uses
isolated test preferences and muted real decoding, checks separate audio/video,
2× playback, seek and pause, and does not use browser cookies. Never print raw
resolver JSON or signed CDN URLs. A live failure is separate from offline gates;
both must be reported. This does not prove every YouTube video, live content or
installed-app manual interaction works.

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

`tools/make_docs_screens.sh` renders the README pictures in `docs/images/<lang>/`
in all three languages: real player screenshots (DocsScreenshotTests), composed
into feature cards by `tools/compose_readme_art.py`. The film is
[Tears of Steel](https://mango.blender.org) (CC BY 3.0, Blender Foundation),
downloaded once into `~/Library/Caches/VideoTool-docs`; its subtitles in
`docs/demo/` were made by VideoTool's own recogniser and translator. Keep the
credit line in every README when changing the pictures.

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
