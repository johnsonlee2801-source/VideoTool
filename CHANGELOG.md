# Changelog

## Unreleased / 待发布安装包

以下按源码提交日期记录；测试数字为对应功能更新当次的验收结果。
源码已推送不等于发布了新的 DMG，安装包发布会另行标注。

Source updates are listed by commit date. Validation belongs to that update;
installer releases are recorded separately.

### 2026-10-31 — 更新说明 / Update notes

- 文档：每次 GitHub 更新按日期说明新增或修复内容、交互变化、验证结果和安装包发布状态。
- 入口：三种语言的 README 均增加更新记录链接。
- 验证与发布：本次只更新文档，核对链接、提交记录及已有源码门禁；不发布新安装包。

### 2026-10-31 — 双击全屏 / Double-click fullscreen · [d09c761](https://github.com/johnsonlee2801-source/VideoTool/commit/d09c7619701ebdac75a98324be17fea77c1d8ad4)

- 新增：双击播放画面或空白区域进入 macOS 原生全屏，再次双击恢复原窗口尺寸。
- 交互：按钮、进度条和星标列表保留原操作。单击在系统双击间隔后播放/暂停；双击不会误暂停，按住加速不延迟。
- 当次验证：先失败、后实现的 4 个交互用例通过，并补充 3 个计时边界用例；应用回归 552 项通过，2 项文档截图测试跳过。安装版实测全屏往返及原窗口尺寸恢复通过。
- 发布状态：已推送源码，未随此提交发布新 DMG。

Double-click the picture or empty player space to toggle native fullscreen.
Controls keep their actions, and playback state is preserved.

### 2026-10-26 — 右键菜单 / Player context menu · [c43bd8a](https://github.com/johnsonlee2801-source/VideoTool/commit/c43bd8adba8f756495ad73c243fac94b3e7c9263)

- 新增：右键调播放速度、生成本机 AI 字幕，以及标记片段起止点、导出 GIF / 视频、拷贝片段和循环预览；另有播放/暂停和拷贝当前画面。
- 交互：菜单反映当前倍速和片段选择；无视频或导出进行中时，相应操作置灰。打开菜单会取消按住加速。
- 当次验证：5 个新增行为用例先失败、实现后通过，包含真实 mpv 播放及文件/剪贴板导出；应用回归 545 项通过，2 项文档截图测试跳过。安装版实际右键菜单已验证。
- 发布状态：已推送源码，未随此提交发布新 DMG。

Right-click for playback speed, on-device AI subtitles, clipping and export,
with play/pause and frame copying alongside.

### 2026-10-26 — 开发测试门禁 / Codex TDD Guardian · [a79b017](https://github.com/johnsonlee2801-source/VideoTool/commit/a79b017)

- 开发工具：接入项目内的 Codex 技能和提交/推送前门禁，保留固定上游版本及 ISC 许可。
- 检查：测试结果绑定实际源码内容；源码变化或最新测试失败后，不再沿用旧的通过记录。支持 Swift Testing 和 Node 测试数量解析。
- 当次验证：Guardian 325 项测试通过；新会话已验证原生 Hook 自动拦截。新机器或 Hook 定义变更后仍需通过 `/hooks` 审阅信任。
- 发布状态：开发工具源码更新，不发布播放器安装包。

## 0.3.8 (2026-10-20)

- Made by ChengNuo: the About window, the first screen and the copyright line
  say who makes VideoTool, with links to GitHub and blog.flowhunt.net.
- The README is English + Chinese on the main page, with feature pictures.

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
