# VideoTool

A macOS video player built on [libmpv](https://github.com/mpv-player/mpv)
(via [MPVKit](https://github.com/mpvkit/MPVKit)), aiming at three things
desktop players don't do well:

1. **Hold-and-drag speed** — hold the left mouse button on the video to play
   at 2×; while holding, drag right to go faster (+0.1× per 20 pt up to 3×,
   then +0.1× per 10 pt up to 6×) or left to slow down (to 0.5×). Release
   restores the previous speed. A short click still toggles pause; any key
   pressed while holding just cancels the speed-up.
2. **Starred moments** on the timeline. Press **B** to star the current
   moment (no pause, no dialog); press it again right away to undo. Stars show
   as yellow marks on the progress bar with a thumbnail on hover; ⌥← / ⌥→ and
   clicks near a star jump to **2 s before** it; ⇧⌘B opens the list to add
   notes or delete. Stars follow the file's content (OpenSubtitles hash), so
   renaming or moving a video keeps them.
3. **An auto-organised local library** (planned; indexes, never moves files).

一个基于 libmpv 的 macOS 播放器：按住画面加速、左右拖动连续调速；进度条星标节点、本地视频库自动归类在规划中。

## Status

- [x] Step 0 — gesture feel settled on an mpv Lua prototype (`prototype/`)
- [x] Step 1 — app shell: window, libmpv engine + OpenGL render layer,
      open / drag-drop / ⌘O, resume position, keyboard shortcuts, registers
      for ~50 video/audio extensions and can be set as the default player
- [x] Step 2 — hold-and-drag speed wired to the real player
- [x] Step 3 — starred moments (SQLite in `~/Library/Application Support/VideoTool/`)
- [ ] Step 4 — library

## Build

Requirements: macOS 14+, Xcode 16+ (developed on Xcode 27), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```zsh
scripts/regen.sh          # generate App/Info.plist and VideoTool.xcodeproj from project.yml
scripts/xcb.sh build      # build (ad-hoc signed, Debug)
scripts/xcb.sh test       # run the app test suite
```

The first build downloads MPVKit's prebuilt xcframeworks (~250 MB).
`xcb.sh` keeps all build state in `~/Library/Developer/Xcode/DerivedData/VideoTool-cli`:
if the checkout lives in an iCloud-synced folder (e.g. Desktop), Xcode's
package resolver silently resolves nothing when DerivedData is inside it.

The built app is at
`~/Library/Developer/Xcode/DerivedData/VideoTool-cli/Build/Products/Debug/VideoTool.app`.

## Tests

| Suite | Command | What it covers |
|---|---|---|
| Core | `VideoToolCore/scripts/test-direct.sh` (or `swift test` in `VideoToolCore/`) | speed curve, option validation, hold/drag state machine |
| App unit | `scripts/xcb.sh test -skip-testing:VideoToolTests/MPVIntegrationTests` | media types vs Info.plist, key routing, resume tracking, launch opening, gesture controller, stars (fingerprint, store, navigation, controller) |
| Integration | `scripts/xcb.sh test -only-testing:VideoToolTests/MPVIntegrationTests` | real libmpv: render context, playback, speed, pause, EOF, shutdown races, resume end-to-end |
| Prototype | `prototype/tests/run.sh` (needs `luajit`), `prototype/tests/live.sh` (needs `mpv`) | the original Lua gesture and its mpv adapter |

## Layout

- `VideoToolCore/` — Swift package with the pure gesture logic (no UI, no player).
- `App/Sources/` — AppKit shell. `Player/` holds the libmpv engine
  (`MPVEngine`), the OpenGL render layer (`MPVRenderLayer`), `PlaybackSession`
  (the only owner of their lifecycle), the gesture controller and the window.
  `Playback/` holds small pure units: key routing, resume tracking, formatting.
- `Tests/` — app tests and the `testsrc-20s.mp4` fixture (bundled into the test
  target so tests never read from the source folder).
- `prototype/` — the mpv + Lua prototype used to tune the gesture.
- `project.yml` — XcodeGen spec; never hand-edit `VideoTool.xcodeproj`.

## License

Not yet chosen. MPVKit (LGPL build) and mpv/FFmpeg carry their own licenses.
