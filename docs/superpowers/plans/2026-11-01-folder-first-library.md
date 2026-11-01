# Folder-first Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 当前用户已授权实施，沿用本会话直接执行，不调用其他代理、不再追加计划审批。

**Goal:** 在现有播放器右侧以紧凑文件夹浏览视频，按同目录顺序手动观看下一集。

**Architecture:** 目录投影、筛选和自然排序保持纯逻辑；异步目录读取用请求代次拒绝过期结果。新增文件夹浏览内容覆盖主入口，旧 LibraryBrowser 保留为「更多整理」入口；播放器使用同目录队列，仅在用户操作时切换文件。

**Tech Stack:** Swift、AppKit、libmpv、Swift Testing，现有 SQLite 与 AppData。

**Spec:** `docs/superpowers/specs/2026-11-01-folder-first-library-design.md`

## Global Constraints

- 侧栏保持 280–560 pt，不新增窗口，不改动用户视频文件。
- 缩略图约 80×45 pt、视频行约 62 pt，使用现有 Theme。
- 自然结束和跳片尾均不自动开下一集；子目录由用户手动进入。
- 不引入依赖或网络服务；新文件经 scripts/regen.sh 纳入项目。
- 测试使用 AppData/TestTemp；提交前完整门禁，推送前秘密扫描。

## Review Focus

- 相同文件夹名和 `/A`、`/AB` 路径必须按完整路径区分。
- 播放 A 后迅速切到 B，A 的目录读取结果不能覆盖 B 的上下集。
- 未索引文件、不可用磁盘、被删除的下一集必须保持可解释的状态。
- 筛选和隐藏侧栏不改变同目录上下集目标，播放器不抢走列表输入。
- 跳片尾保持完成标记与进度清理，但绝不自动进入下一集。

### Task 1: 手动结束与同目录队列

**Files:** 新建 `App/Sources/Playback/FolderPlayback.swift`；修改 `PlayerWindowController.swift`、`SkipAndNightTests.swift`；新增 `FolderPlaybackTests.swift`。

**Interfaces:** `FolderPlayback` 提供自然排序、目录后台读取与 `previous/next`；`PlayerWindowController.previousVideo(_:)` / `nextVideo(_:)` 处理手动打开。

- [x] 将 SK4/SK6/SK7 改为断言片尾暂停、仍在本集、历史 finished，实际运行确认现有自动连播失败。
- [x] 编写自然排序、首尾不循环、目录边界、过期结果和读取失败测试，运行 red。
- [x] 实现后台同目录队列；控件使用紧凑上下集按钮及目标文件名提示；读取结果到达不自动播放。
- [x] 片尾结束时暂停并跳到本集结尾，保持 markFinished/clear；手动下一集沿用 open/resume。
- [x] 运行上述套件 green，复核关闭/切换时清理与无重复加载。

### Task 2: 文件夹层级与紧凑浏览

**Files:** 新建 `App/Sources/Library/FolderBrowserModel.swift`、`App/Sources/LibraryUI/FolderBrowserViewController.swift`、`Tests/VideoToolTests/FolderBrowserTests.swift`；修改 `LibraryBrowserViewController.swift`、`SidebarMediaItem.swift`、`LibraryTestHost.swift`。

**Interfaces:** `FolderBrowserModel` 从 roots/items 生成直接子目录和本层视频，按路径定位；`FolderBrowserViewController` 接受 LibraryController、onOpen、onShowAdvanced，从父浏览器 refresh，不覆盖共享回调。

- [x] 写层级、同名根目录、路径边界、自然排序及筛选仅影响显示的测试，确认 red。
- [x] 实现索引目录投影与同目录临时浏览；后台请求带代次，过期请求不覆盖选择。
- [x] 实现路径/上一级、搜索和筛选、62 pt 视频行、文件夹行及当前文件定位，保留选择与滚动；不常驻左右分栏。
- [x] 主入口默认文件夹浏览，旧整理界面保留可返回入口；旧界面测试明确进入次级入口。
- [x] 加实际界面行为测试：进入/返回、打开视频、过滤、失效文件和未索引目录；运行 green。

### Task 3: 集成、视觉与发布

**Files:** `PlayerSidebarView.swift`、`UISnapshotTests.swift`、本次涉及的窗口测试、i18n、README、AGENTS、CHANGELOG。

- [x] 接入当前播放文件定位和偏好，关闭时释放读取请求，三标签状态保持。
- [x] 确认新界面不误触发全屏，不抢输入；为 280/380/560 pt 与空目录写快照测试并查看图片。
- [x] 补中英日翻译，运行 i18n extract/build/check 和定向 UI/播放套件。
- [x] 当前会话 Codex Suite 审查本次完整 diff；具体发现先写失败回归再修复。
- [x] 新文件先暂存，运行完整 TDD Guardian push 门禁；通过后 Release 构建及签名校验。
- [x] 按已有授权正常退出旧版、备份、安装并重启；分别记录安装二进制与人工 UI 验收边界。
- [x] 更新日期中文 CHANGELOG 和使用说明，秘密扫描通过后提交、推送 origin，核对远端 HEAD。

## 执行说明

用户已明确批准设计并要求实施，使用本会话直接执行；每个任务完成红绿测试和复核后更新本清单，完整可用后发布。未完成的产品步骤不提前提交为完成版本。无需因内部任务划分反复请求授权。

## 验收记录（2026-11-01）

- 关键行为先失败后通过：SK4/SK6/SK7 自动连播、FP1 路径别名、真实鼠标双击、FU3 异步选中项、FU4 云文件、FU7/8/9 提示优先级与范围、FU10 成功打开清理旧提示。
- 定向验收 51 项通过，后续审查修复定向 44 项通过；最终完整门禁：core 68、unit 540 通过／2 文档素材测试跳过、integration 67、Guardian 325、prototype 全通过（应用合计 607 项通过）。
- Codex Suite 当前会话审查覆盖全部变更及直接调用路径；已处理全部明确发现，无其他代理或付费模型。
- 280/380/560 pt 侧栏及子目录／窄播放器快照已生成并检查。原生全屏切换仍以测试边界替换；安装后的实际鼠标手感不与源码回归混称。

- 最终补查 FU10 清理旧提示实际 RED→GREEN；最终源码门禁仍为 core 68、unit 540+2 skips、integration 67、Guardian 325、prototype 全通过，应用 607 通过。
- 最终 Release 已安装到 /Applications/VideoTool.app；正常退出/重启、签名、二进制一致性通过。原安装副本与收尾前候选副本均留有备份；不发布新 DMG。
