# Changelog

## Unreleased / 待发布安装包

以下按源码提交日期记录；测试数字为对应功能更新当次的验收结果。
源码已推送不等于发布了新的 DMG，安装包发布会另行标注。

Source updates are listed by commit date. Validation belongs to that update;
installer releases are recorded separately.

### 2026-11-01 — 修复界面忙碌时双击后的播放状态 / Queued double-click restoration

- 修复：关闭复查发现的 F001。界面忙碌、第二次点击延后处理时，按事件发生时间匹配双击，避免切换全屏后仍停留在第一下点击的播放／暂停状态。
- 兼容：单击仍在松开鼠标时立即响应，双击仍恢复这一对点击前的状态；真正超时或时间顺序异常的点击不撤销单击，长按调速和控件操作保持原行为。
- 验证：新增真实视图与 mpv 回归用例，播放／暂停两种初态均先失败、修复后通过；定向 26 项通过。完整 TDD 门禁：应用 587 项通过、2 项文档截图测试按配置跳过，核心 68 项、Guardian 325 项及原型测试通过。Codex Suite 当前会话对 F001 的修复复核为 verified，未发现新增相关问题；非独立代理审查。
- 本机与发布：Release 构建通过，已正常退出旧版、保留备份、更新并重启本机 `/Applications/VideoTool.app`；安装签名与构建二进制一致性核对通过。源码同步 GitHub，未发布新 DMG，版本仍为 0.3.8。自动化替换原生全屏切换边界，本次未新增安装后的人工鼠标验收。

### 2026-11-01 — 修复画面单击暂停延迟 / Immediate picture-click pause

- 修复：单击播放画面后，松开鼠标即发出暂停／继续指令，取消原先等待系统双击间隔的延迟。
- 交互：按用户选择，双击画面的第一下立即切换播放状态，第二下恢复这一对点击前的状态并切换全屏；两下之间可能短暂停顿或播放。长按调速、键盘取消、按钮、进度条和侧栏保留原操作。
- 验证：延迟回归用例实际先失败、修复后通过；定向 23 项通过，覆盖播放／暂停初态、快速双击、超时／取消、连续单击和长按。完整 TDD 门禁：应用 584 项通过、2 项文档截图测试按配置跳过；核心 68 项、Guardian 325 项及原型测试通过。Codex Suite 当前会话审查未发现遗留明确问题，非独立代理审查。
- 本机与发布：Release 构建通过，已正常退出旧版、保留备份、更新并重启本机 `/Applications/VideoTool.app`；签名有效、安装二进制与构建产物一致，仅有一个新版进程。自动化交互测试替换原生全屏切换边界，安装后的实际鼠标手感仍待用户验收。源码同步 GitHub，未发布新 DMG，版本仍为 0.3.8。

### 2026-11-01 — 本机版本更新与重启 / Local app update

- 安装：经用户确认，正常退出旧版后，将已验证的右侧栏 Release 更新到本机 `/Applications/VideoTool.app`，旧版保留备份，再重新启动新版。
- 核对：安装后签名与构建产物哈希一致；旧进程已结束，仅有一个新版进程，主线程采样处于正常事件循环。界面自动化仍报 `cgWindowNotFound`，AppleEvent 窗口读取也超时，因此未宣称完成安装后的完整界面验收。
- 验证与发布：本次仅记录安装状态，没有修改程序代码，也未重跑上一条功能更新的测试；未发布新 DMG，版本仍为 0.3.8。

### 2026-11-01 — 播放器右侧统一侧栏 / Unified player sidebar

- 新增：视频库直接放进播放器右侧，提供「视频库／最近播放／星标」三个标签；分类、搜索、观看进度和选片都在同一个窗口内完成。
- 界面：紧凑的 16:9 缩略图卡片、粉色选中标签和播放进度；侧栏可收起、拖动调宽，并记住展开状态、标签和宽度。原视频文件不移动、不改名。
- 操作：`⌘L` 或播放栏视频库按钮展开侧栏，`⇧⌘B` 切到星标或收起；双击卡片直接在左侧播放。最近播放包含未加入视频库的视频，并显示播放时间及进度。
- 兼容：保留现有分类、文件夹管理、剧集修正、星标备注与跳转。搜索/列表导航保留自己的键盘操作；侧栏所有标签及空白处都不触发画面全屏。收起侧栏不会取消用户已启动的索引。
- 验证：单窗口入口、状态/最近记录模型和刷新/缩放边界均有实际先失败、后通过的测试；最终定向验收 42 项通过，真实播放器接线 12 项通过。完整 TDD 门禁：应用 580 项通过、2 项文档截图测试跳过；核心 68 项、Guardian 325 项及原型测试通过。CC Suite 当前会话审查已核对并处理状态刷新、选中项保持、宽度变化和数据库重试路径，未遗留明确问题。
- 发布状态：源码更新到 GitHub；Release 构建与签名校验通过，未发布新 DMG，版本号仍为 0.3.8。界面自动化返回 `cgWindowNotFound`，用户选择先完成 GitHub，本机旧应用本次尚未替换；安装后的原生界面验收留待本机更新时进行。

### 2026-10-31 — 修复星标面板双击边界 / Sidebar double-click boundary

- 修复：双击星标列表顶部等空白区域，不再沿响应链误触发播放器全屏；画面和控制栏空白处仍可双击切换全屏。
- 验证：新增实际命中视图及响应链的回归用例，修复前失败、修复后通过；双击、右键菜单与按住调速相关 21 项测试通过，测试断言在修复过程中保持不变。完整门禁：应用 553 项通过、2 项文档截图测试跳过，核心 68 项和 Guardian 325 项通过，原型测试通过。
- 验证边界：自动化替换原生全屏切换边界；本机安装版另行核对星标标题双击不切换全屏、播放区域双击全屏往返。
- 发布状态：源码修复已同步 GitHub，本机 `/Applications/VideoTool.app` 已更新并保留旧版备份；未发布新 DMG，版本仍为 0.3.8。

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
