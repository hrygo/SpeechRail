# SpeechRail macOS 26 UI/UX 执行交付报告

> 日期：2026-09-22 · 分支：`main` · 基线提交：`4318e799`
> 跟踪：GitHub Issue [#79](https://github.com/hrygo/SpeechRail/issues/79)

## 1. 交付范围

本轮针对 SpeechRail macOS 控制面完成了导航契约、响应式窗口外壳、共享页面语义、会话状态呈现、Reduce Motion、焦点恢复、Token 分类和验收文档收口。产品面向普通 macOS 用户，不以完整辅助技术导航流程为目标：全量 VoiceOver / Full Keyboard Access 遍历不作为验收项或阻塞项；仍保留常用键盘入口、焦点反馈、正确的控件辅助语义和非颜色状态表达。没有改变 REST、Realtime、MCP、XPC、音频采集、记录持久化、模型加载或本机服务生命周期边界。

详细执行步骤见 [本地执行计划](../../superpowers/plans/2026-09-21-speechrail-macos26-uiux-audit-execution.md)，逐项证据见 [UI/UX 验收矩阵](./UIUX-AUDIT-MATRIX.md)，过程记录见仓库外层的执行账本 `.superpowers/sdd/2026-09-21-speechrail-macos26-uiux-audit-execution/progress.md`。

## 2. 已实施内容

### 导航与快捷键

- `AppRoute.allCases` 成为 14 个路由、侧栏分组、菜单、工具栏身份和文档的共同事实源。
- 14 个路由均有 `AppRouteShortcutSpec`；提词器统一使用 `⌘⇧T`。
- 增加 `scripts/check_macos_route_contract.sh`，检查路由数量、shortcut spec 覆盖和独立快捷键字典残留。

### 响应式窗口

- 增加纯值 `WindowLayoutContract`，集中描述 sidebar、Inspector 和 `minimumPrimaryContentWidth`。
- `ControlCenterView`、Assistant、Meeting、Captions 和会话库依据同一合同处理自动收起与恢复。
- Inspector toggle 增加可访问 identifier 和 `FocusState` 恢复路径；用户手动收起与宽度自动收起保持不同语义。

### 页面外壳与辅助功能

- `PageScaffold` 迁移到 `PageScaffoldLayout`：`content`、`fill(minimumHeight:)`、`scroll(minimumHeight:)`。
- 移除旧页面级布尔布局参数和固定理想高度路径；保留 Assistant 的类型安全条件布局。
- 共享组件保留 heading、label、value、hint、状态文字和不依赖颜色的表达；这些是基本 macOS 控件语义，不代表产品承诺面向辅助技术用户做完整导航优化。
- 页面壳层事务、共享控件、会话行、Assistant、Meeting、内心 OS、运行监控回执、创作结果条和音色波形均有 Reduce Motion 即时/静态分支。

### 会话状态与内容

- Assistant、Meeting、Captions、Teleprompter 均用 `SessionPageStatusPresentation` 渲染标题、状态语气和事实；真实动作仍由各页控件直接呈现，逐状态主动作/恢复动作由验收矩阵记录，避免 UI 不消费的重复字符串元数据。
- 增加长标题、空列表、部分完成、服务不可用、权限拒绝、删除确认等 lived-in preview fixture。
- 同步用户文案、Settings 语义 Token、active 设计系统和 redesign spec。
- `StatusTone` 不再直接使用裸的 `Color.green/orange/red`，统一引用设计 Token 的语义色和高对比度变体。

## 3. 验证证据

| 证据等级 | 命令/范围 | 结果 |
|---|---|---|
| Static/code | `scripts/check_macos_route_contract.sh` | 14 enum cases / 14 shortcut specs / 14 UI test entries / 14 matrix entries / one registry，退出 0 |
| Unit | `swift test --package-path macos/SpeechRailApp` | exit 0；159 XCTest + 85 Swift Testing 通过 |
| Build | `scripts/macos_app_build.sh --configuration Debug` | exit 0，`BUILD SUCCEEDED`；arm64，macOS 26.0 target |
| Automation | `testControlCenterHonorsRequestedWindowSizes` | `.xcresult` 1/1 通过；4 档窗口约束、原生侧栏和 Inspector 收起/恢复、6 个代表页面主动作均在窗口内 |
| Automation | `testWorksViewExposesSelectionAndExportActions` | `.xcresult` 1/1 通过；选中作品、行内/Inspector 导出入口与动态 File 菜单导出命令可发现 |
| Automation | `xcodebuild ... -testPlan SpeechRailApp test` | `.xcresult` 255 passed / 0 failed / 0 skipped，macOS 27.0 / arm64 |
| Static/code | 全 App 动效、旧布局名、Token/语义检查 | 旧布局名无源码残留；Reduce Motion 调用点均有即时/静态路径 |
| Static | `git diff --check` | 通过 |
| Manual | CUA 逐页打开 14 个侧栏路由与四个会话页 | 14/14 页面身份与首屏可达；只读 idle 检查，未启动录音、字幕采集、提词舞台或生成 |
| Manual | Light/Dark、高对比度、降低透明度、减少动态效果与字号代表页 | 外观偏好有代表性样本；字号放大效果和 Reduce Motion 实际过渡为 partial；系统偏好最后已恢复 |

首次通过 `scripts/macos_app_test.sh` 启动 test plan 曾遇到 automation-mode timeout（exit 65）；未更改 TCC 权限。改用直接 `xcodebuild ... -testPlan SpeechRailApp test` 后，完整 255 项均通过。构建日志中的 `appintentsmetadataprocessor` warning 是当前项目未依赖 `AppIntents.framework` 的非致命提示，不影响构建退出码。

## 4. 桌面实测与未闭合项

用户于 2026-09-22 明确授权接管前台窗口并运行 UI test plan。人工走查完成 14 个侧栏路由首屏身份核对，以及 Assistant、Meeting、Captions、Teleprompter idle 页面查看；自动化另行覆盖四档请求窗口、侧栏/Inspector 切换和六个代表路由主动作边界。未启动真实麦克风、会议、字幕、提词舞台、音频生成、模型下载或服务控制。

外观测试中，浅色与深色模式均检查 Developer Docs 页面；增强对比度、降低透明度与减少动态效果均临时打开并观察代表页面。较大系统文字从默认级别 4 调到 5（13pt）时，SpeechRail 样本未观察到明显字号变化，故字号联动为 partial。AX 树曾用于抽样核对路由名称和控件 Description/Help；完整 VoiceOver 导航不属于目标人群验收，不作为未完成项。

XCUITest 用请求尺寸启动控制台：1120×720、1280×800、1440×900 和 1920×1080。测试验证 frame 约束，逐档切换原生侧栏和 Inspector，并在 Assistant、Meeting、Captions、Teleprompter、Models、Diagnostics 六页确认主操作位于窗口范围内。1120×720 的实际 NSWindow 外框为 1120×760（标题栏额外 40pt）；1920×1080 按屏幕 `visibleFrame` 上限收敛。测试未覆盖所有路由在各尺寸下的 searchable/List 滚动细节；未更改显示器分辨率。

初次脚本入口曾在 XCTest runner 初始化时报 `XCTFuture Code=1000: Timed out while enabling automation mode`、exit 65；未授予或修改 macOS Automation、Accessibility 等 TCC 权限。随后直接运行 test plan 成功，最终 `.xcresult` 为 255/255 通过，未再需要处理 runner 初始化问题。

结束时已恢复外观 Auto、增强对比度 off、降低透明度 off、减弱动态效果 off、字号默认和 VoiceOver off；SpeechRail 回到 Assistant idle、侧栏可见、Inspector 收起。以下仍作为非阻塞项保留：

- 每个路由在每档窗口下 searchable/List 滚动和长内容的穷尽组合；
- 较大系统文字偏好对全页面的实际效果；样本未观察到明显放大；
- Full Keyboard Access、List 方向键、Space 试听的专项遍历；
- 未启动真实录音/采集条件下不能桌面复现的长时 live/恢复状态；
- 完整 VoiceOver 导航按产品目标人群明确排除；基本控件语义仍是 macOS 平台基线。

## 5. 并行改动、回退与风险

- 工作区原有未提交改动已逐文件保留；没有使用 `git reset --hard`、`git checkout --` 或整文件覆盖。
- 本轮未提交、未推送、未发布，也没有启停服务、处理模型或修改 LaunchAgent。
- 回退应按逻辑主题和文件级 diff 进行：路由契约、窗口合同、共享外壳、会话页面、Token/文档分别回退；不得回退用户原有的能力、凭据或控制面改动。
- 当前剩余风险集中在全路由 searchable/List 与文字偏好组合，以及未用真实音频采集覆盖的 live 状态；它们不影响当前四档代表页面窗口验收结论。完整 VoiceOver 导航不在目标范围。

## 6. 下一阶段

Issue #79 保持打开，用于跟踪矩阵中明确列出的非阻塞剩余项：全路由 searchable/List 在不同宽度下的细节、系统大字号效果以及需要真实采集条件的 live 恢复流程。不要把完整 VoiceOver 导航加入验收范围；若未来产品人群或目标改变，再单独评估辅助技术导航深度。
