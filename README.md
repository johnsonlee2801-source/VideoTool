<p align="center"><img src="design/icon/AppIcon-1024.png" width="128" alt="VideoTool icon"></p>

<h1 align="center">VideoTool</h1>

<p align="center"><b>The Mac video player that keeps up with you.</b><br>
Hold to speed up. Star the moments that matter. Free AI subtitles, made on your Mac.</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a></p>

<p align="center"><img src="docs/images/en/player.jpg" alt="VideoTool playing a video, with stars on the timeline and the speed HUD"></p>

---

## Why VideoTool

Most of us watch at 1.5× or 2× and skip the boring parts. Lectures, series, anime, screen recordings, downloads: you want to get through them quickly without missing the good bits. VideoTool is built around that.

- **🖱 Hold to speed up, drag to fine-tune.** Press and hold the picture: it plays at 2× (or faster than your usual speed). Keep holding and drag right for up to 6×, or left to slow down. Let go and you're back.
- **★ Stars on the timeline.** Press **B** at a great moment. A star appears on the progress bar with a thumbnail and an optional note. Click it to jump back (2 s early, so you catch the lead-in). Export the part between two stars as an MP4, a GIF or a set of stills.
- **🌐 Free AI subtitles and translation.** Any video in English, Japanese, Chinese, Korean and more gets subtitles while you watch: they start from where you are and appear within seconds, with a translation above the original line on a thin dark band. Everything runs **on your Mac**. Nothing is uploaded, and there's no fee. Save them as an .srt file if you like.
- **📚 A library that organizes itself.** Open a video and VideoTool offers to add its folder. It groups episodes into series, keeps a *Continue Watching* row, finds duplicates and tags what's in the picture. Nothing is ever moved or renamed.
- **🎞 Plays everything.** It's built on mpv and FFmpeg: MKV, HEVC 10-bit, HDR10, AV1, VP9, WMV, FLV, old AVIs, multiple audio and subtitle tracks. Hardware decoding keeps a 4K HDR file at about a fifth of one CPU core.
- **⏭ Less waiting.** Mark where a series' intro ends and its credits begin once; every episode then skips them and moves on to the next one. Hover over the timeline to preview a frame. Night mode lifts voices and tames the rumble of explosions.
- **🧠 Remembers each video.** Where you stopped, the audio and subtitle track you chose and your subtitle timing come back when you reopen it.
- **🔒 Private by design.** No account, no tracking, no analytics. Your library, stars and subtitles stay in `~/Library/Application Support/VideoTool`.

## How VideoTool differs

There are excellent players for the Mac. This is what VideoTool adds, and where the others are stronger.

| | VideoTool | IINA | VLC | Infuse |
|---|---|---|---|---|
| Price and source | Free, open source (MPL-2.0) | Free, open source | Free, open source | Free, Pro subscription |
| Speed while holding the picture | 2×, drag for 0.5×–6× | — | — | 2× |
| Stars on the timeline with thumbnails and notes | ✓ | — | Bookmarks (no thumbnails) | — |
| Subtitles generated on your Mac, with translation | ✓ (macOS 26) | Download only | Announced for VLC 4 | Download only |
| Export a clip, GIF or stills | ✓ | Screenshots | Via Convert / Save | — |
| Library that groups series from your folders | ✓ | — | — | ✓ (with online artwork) |
| Skip intros and credits | ✓ (you mark them once) | — | — | ✓ (from an online database) |
| Plays MKV, HEVC, AV1, HDR | ✓ | ✓ | ✓ | ✓ |

Choose **VLC** if you need Windows, Linux or phones; **Infuse** for streaming from a NAS, Plex or Jellyfin, and for the Apple TV; **IINA** for a mature mpv player with plugins and online video. VideoTool is for watching your own files quickly without missing the good parts.

<sub>Based on each app's public documentation in October 2026. Spot something wrong? Please open an issue.</sub>

## A closer look

| | |
|---|---|
| <img src="docs/images/en/ai-subtitles.jpg" alt="Bilingual AI subtitles"> | <img src="docs/images/en/stars.jpg" alt="Star list with notes"> |
| **AI subtitles** (Play › AI Subtitles…, ⌘T). Pick the spoken language and a translation, and they're ready in seconds. Reopen the video and they come back by themselves. | **Stars** with notes and thumbnails. Jump between them with ⌥← / ⌥→, or open the list with ⇧⌘B. |
| <img src="docs/images/en/library.jpg" alt="Library with Continue Watching"> | <img src="docs/images/en/series.jpg" alt="Library grouped by series"> |
| **Continue Watching** and progress bars on every cover. Finished videos get a tick. | **By Series** recognises S01E02, 1x02, EP03, 第2集, “Show - 07”… Got one wrong? Right-click › Edit Series Info. VideoTool remembers the fix, even after you rename or move the file. |

## Speed, your way

| Want | Do |
|---|---|
| A burst of speed | Hold the picture (2×, or 0.5× above your usual speed) |
| Faster / slower while holding | Drag right (up to 6×) / left (down to 0.5×) |
| A fixed speed | Click the speed label next to the timeline: 0.75× – 3× |
| Fine steps | `[` / `]` (±0.1×), `⌫` back to 1.0× |

VideoTool remembers your speed, so a lecture you watch at 1.5× opens at 1.5× next time. Speech stays clear and audible all the way up to 6×.

## Keyboard

| Key | Action | Key | Action |
|---|---|---|---|
| Space | Play / pause | B | Star this moment (press again to undo) |
| ← / → | Back / forward 5 s (⇧: 30 s) | ⌥← / ⌥→ | Previous / next star |
| ↑ / ↓ | Volume | ⇧⌘B | Star list |
| ⌘T | AI subtitles | S / A | Next subtitle / audio track |
| ⌘L | Library | F | Full screen |
| M | Mute | ⌘O | Open a file |
| Z / X | Subtitles 0.1 s earlier / later | ⌘E | Export a clip |

## Requirements

- macOS 14 Sonoma or later. Tested on Apple silicon.
- AI subtitles need **macOS 26** or later. The system downloads each speech model and translation language once, for free.

## Install

1. Download **VideoTool-x.y.z.dmg** from [Releases](https://github.com/johnsonlee2801-source/VideoTool/releases/latest) (Apple silicon and Intel), open it and drag VideoTool to Applications.
2. The first time, macOS says it can't verify the developer: VideoTool isn't notarized by Apple yet. Click **Done**, open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to VideoTool, then confirm. You only do this once.

Or build it yourself (Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```sh
brew install xcodegen
git clone https://github.com/johnsonlee2801-source/VideoTool.git
cd VideoTool
scripts/regen.sh          # generate the Xcode project
scripts/install.sh        # build Release and install to /Applications
```

To have VideoTool open all your videos, choose **File › Set as Default Video Player…**. macOS asks you to confirm each format.

## Languages

The interface is available in **English, 简体中文 and 日本語** and follows your Mac's language.

## Quality

VideoTool is developed test-first. About 450 automated tests run the real playback engine and real on-device speech recognition, plus every bundled video format. The code is checked for leaks of personal data before every push. Line coverage is above 90%. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

- Casting to Apple TV and AirPlay TVs (sound output to AirPlay speakers already works: Play › Audio Output)
- Picture enhancement (frame interpolation, anime upscaling)
- Library and stars synced across your Macs

Ideas and bug reports are welcome: **Help › Send Feedback…** in the app opens a pre-filled issue.

## Built with

[mpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org) (LGPL builds via [MPVKit](https://github.com/mpvkit/MPVKit)), Apple Vision, Speech and Translation. The full list with licences is in [THIRD_PARTY_NOTICES.md](App/Resources/THIRD_PARTY_NOTICES.md) and in the app's About window. All are LGPL or permissive; nothing GPL-only is shipped.

## License

VideoTool is open source under the [Mozilla Public License 2.0](LICENSE) (MPL-2.0). You may use, study, change and share it; changes to VideoTool's own files stay open under the same licence, and VideoTool can be combined with other code. Third-party components keep their own licences (see above).
