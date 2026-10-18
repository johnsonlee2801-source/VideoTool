# VideoTool prototype 0: hold-and-drag speed on mpv

Purpose: settle the feel of the hold-to-speed gesture with real videos before
writing the Swift app. No app code here, only an mpv config and one Lua script.

## Run

```zsh
cd prototype
./run.sh "/path/to/some/video.mp4"
```

`run.sh` passes `--config-dir=mpv-config`, so nothing in `~/.config/mpv` is read
or written.

## Gesture

| Action | Result |
|---|---|
| Tap (release within 0.25 s) | toggle pause |
| Hold | jump to 2.0x, OSD shows speed and a bar |
| Hold + drag right | +0.1x per 20 pt up to 3.0x (200 pt), then +0.1x per 10 pt up to 6.0x (another 300 pt) |
| Hold + drag left | -0.1x per 20 pt, down to 0.5x (150 pt) |
| Release | back to the speed before the hold |
| Key press or focus loss while holding | same as release, never counts as a tap |
| Double-click | swallowed (mpv's default fullscreen toggle is off while this script runs) |
| Hold on a paused video | starts playing at hold speed; release keeps it playing |

Distances are in points (HiDPI-corrected), so the numbers carry over to the
Swift app. All numbers live in `mpv-config/script-opts/hold-drag-speed.conf`.

## What to decide while testing

Write the answers down; they become the spec and the unit tests of the Swift
version.

1. Hold threshold: does 0.25 s feel instant, or does it swallow taps?
2. Base hold speed: 2.0x like YouTube, or should a plain hold start at 1.5x?
3. Curve: 200 pt to 3.0x, then 300 pt more to 6.0x (changed 2026-10-17 from 400 pt to 3.0x after first test). Is the knee at 3.0x right?
4. Deadzone: does 8 px stop accidental speed drift when the hand trembles?
5. Range: 0.5x to 6.0x. Is 6x ever useful with audio on, or should the top end mute?
6. Release behaviour: restore the old speed, or keep the dragged speed?
7. Audio: at 2.5x and above, is pitch-corrected audio still useful or should it mute?
8. OSD: is the big speed number + bar enough feedback, or does the seek bar
   need to show the "fast region" being covered?

## Files

- `mpv-config/mpv.conf`: disables window dragging on left button, keeps last frame.
- `mpv-config/scripts/hold-drag-speed/gesture.lua`: pure gesture logic, no mpv
  calls. `speed_for_drag(dx, opts)` and the hold/drag state machine will be
  ported to Swift verbatim, together with their tests.
- `mpv-config/scripts/hold-drag-speed/main.lua`: thin mpv adapter (binding,
  60 Hz poll timer, OSD drawing). mpv loads the folder as one script.
- `mpv-config/script-opts/hold-drag-speed.conf`: tuning knobs.
- `tests/`: unit tests, run with `tests/run.sh` (needs `luajit`, which is Lua
  5.1 compatible like mpv's own interpreter). `test_gesture.lua` covers the
  mapping, option validation and the state machine; `test_adapter.lua` drives
  `main.lua` through a fake `mp` module to check the wiring.

## Tests

```zsh
tests/run.sh    # unit: luajit, fake mp, 64 cases, < 1 s
tests/live.sh   # integration: real headless mpv, drives the gesture through
                # mpv's input pipeline via tests/live/driver.lua, 13 checks
```

`live.sh` is the lane that can catch what the fake cannot: real binding
semantics (a key press cancels the held button, double-click handling,
`mouse-pos` updates). It needs `mpv` on PATH and no display.

The suite is the spec: every tuning decision from the list above should land
as a changed expected value in `tests/test_gesture.lua`, not only in the conf.
