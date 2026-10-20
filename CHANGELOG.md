# Changelog

## 0.3.7 (2026-10-20)

Fixes from a review of the clip feature:

- **Holding a key** no longer repeats toggles: holding C marks one end, holding B
  stars once, holding Space pauses once. Arrows, volume, speed and Z/X still repeat.
- Copies and clips carry the AI subtitles only while they are switched on, with
  the Z/X timing you set.
- A slow clip Copy never replaces something you copied meanwhile.
- Pressing ⌘C repeatedly copies the latest moment without piling up work.
- Copied clips live in VideoTool's own folder and are cleaned up after a day.
- Very long video names still export; quick exports never replace a file.

## 0.3.6 (2026-10-20)

- The clip bar says what Copy gives ("Copy GIF" / "Copy Video") and, for clips over
  20 s, that they export as video only.

## 0.3.5 (2026-10-20)

- **C marks a clip**: C at the start, C at the end; the stretch lights up and a
  bar offers GIF, Video, Copy (to the clipboard) and a looping preview. One
  click, no dialog; files go to Movies › VideoTool. B stays for stars.
- **⌘C copies the picture on screen**, AI subtitles included.
- An **Edit** menu: ⌘C/⌘V/⌘A now work when typing a star's note.
- Next audio / subtitle track are plain A / S (⌘A is Select All).

## 0.3.4 (2026-10-20)

Fixes from a review of the whole app (62 issues fixed, each with a test):

- **Crash** on file names with Arabic-Indic digits (e.g. "EP٢") fixed.
- Keys the player handles (arrows, space…) no longer also reach the focused control.
- AI subtitles listen to the **audio track being played**; Mandarin → Traditional
  Chinese is translated; a line followed by silence shows within seconds;
  cancelling really stops recognition; damaged subtitle files no longer crash.
- Library: a video whose details can't be read is no longer treated as deleted;
  failed thumbnails are retried; iCloud states are right; same-named folders in
  different library folders stay apart; "The Office (US)" and "(UK)" are
  different shows; a locked database fails within seconds instead of freezing.
- Stars: a failed delete keeps the star; "next star" right after a jump at high
  speed goes forward; the preview closes when its star is undone.
- Resume: closing a video before it has jumped to its resume point keeps that
  point; short clips are no longer "watched" on opening; skipping the credits
  of "Holiday 01" no longer affects an unrelated "Holiday 02" elsewhere.
- ⌘M is Minimize again (Mute is plain M); "Added to the library" only when it was;
  the series editor asks again instead of losing what you typed; season 0 is kept.

## 0.3.3 (2026-10-20)

Fixes from a code audit:

- Exporting stills never overwrites pictures already in the folder.
- Skipping the credits counts as finishing the episode: it no longer reopens in
  the credits, and it is marked watched.
- Intro and credits marks on a video without an episode number apply to that
  video only, no longer to every video in its folder.
- An export can be cancelled (Play › Cancel Clip Export); one export at a time.
- MP4 export decodes with the hardware (faster for 4K), keeps phone videos
  upright, and reports an unwritable folder as such.
- Subtitles in a folder whose name contains ":" are burned in correctly.
- The export dialog rounds the end time up, so the moment is never cut short.
- A per-app language chosen in macOS System Settings shows in VideoTool › Language.

## 0.3.2 (2026-10-20)

- **Choose the interface language** in VideoTool › Language: Follow System,
  English, 简体中文 or 日本語. VideoTool offers to reopen to switch.
- Frame grabs (GIFs, stills, previews) recover when mpv stalls under heavy
  load, and GIF export uses at most four decoders at a time.

## 0.3.1 (2026-10-20)

- **Clips and GIFs can carry the AI subtitles**: tick *Include AI subtitles* in
  Export Clip (⌘E) and the subtitles on screen are burned into the picture
  (never a subtitle track the file brings itself).
- Export shows its progress.
- The README now focuses on the three things VideoTool does differently:
  hold to speed up, AI subtitles, clips and GIFs.

## 0.3.0 (2026-10-19)

First public release.

### New

- **Export a clip** (Play › Export Clip…, ⌘E): the part between two stars as an
  MP4 (H.264 + AAC, from any format the player opens), a GIF or eight stills.
- **Skip intros and credits**: mark them once from Play › Intro & Credits; every
  episode of that series skips them and goes on to the next episode.
- **Night mode** (Play menu): clearer voices, less rumble.
- **Hover preview** on the timeline.
- **Per-video memory**: audio track, subtitle track and subtitle timing come
  back when you reopen a video.
- **AI subtitles while you watch**: they start from the current position and
  appear within seconds; the rest fills in as recognition goes on.
- AI subtitles on a thin dark band behind each line (Play › AI Subtitle
  Background), three sizes, and **export as .srt**.
- Subtitle timing: **Z** / **X** move subtitles 0.1 s earlier / later.
- Audio output menu (AirPlay speakers included), speed presets, Help › Send
  Feedback…, interface in English, 简体中文 and 日本語.

### Download

`VideoTool-0.3.0.dmg` runs on Apple silicon and Intel Macs with macOS 14 or
later (AI subtitles need macOS 26). It is not notarized yet: the first time,
use **System Settings › Privacy & Security › Open Anyway**.

## 0.2.0

Library (series, Continue Watching, duplicates, tags), stars with notes, AI
subtitles, hold-to-speed gesture, plays everything mpv plays.
