# SpeechRail macOS 26 全局交互语言与 Design Token 重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task with review checkpoints. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 SpeechRail macOS 26 控制台的 token、标题栏、工具栏、导航 icon、按钮状态、光标和点击反馈统一为一套 Native-first 交互语言，并保持所有真实业务动作接线。

**Architecture:** 以 `SpeechRailDesignTokens` 作为 Foundation/Semantic/Component/Interaction 的单一来源，在 `WorkspaceComponents` 提供共享按钮和交互表面，在 `SurfaceHeaderView` 提供不溢出的 `WorkspaceTitleLockup`，由 `ControlCenterView` 统一 App shell。页面只消费共享 primitive，不再各自复制 hover、cursor、selected 或 title 拼装逻辑。

**Tech Stack:** SwiftUI、AppKit `NSViewRepresentable`、SF Symbols、macOS 26、现有 `AppModel`/`SpeechRailControlKit` 接线。

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-global-interaction-language-design.md`

## Global Constraints

- App 只面向 macOS 26，不增加 macOS 14 兼容分支，不为兼容牺牲 macOS 26 特性。
- 不修改 REST、Realtime、XPC、worker、模型目录或服务生命周期契约。
- 保留服务状态、运行监控、模型下载、诊断、配音台、音色创作、音色库和作品的真实动作，不以静态占位替换接线。
- 页面不得新增裸颜色、裸圆角、裸间距、局部 hover/cursor 数值或重复的标题/按钮状态实现。
- 标准 `Button`、`Menu`、`NavigationLink`、`Picker`、`Slider` 和 `Toggle` 保留 macOS 系统按压、焦点和辅助功能行为；所有 enabled 操作/选择实例在真实命中区统一使用 `pointingHand`，只有静态内容保持普通箭头。
- 每个交互对象的有效命中区至少为 `44 × 44pt`；状态不能只依赖颜色。
- 用户此前暂停了自动化测试；执行本计划不运行 XCTest、XCUITest、Python 测试或安装流程，只做静态审查、编译和人工检查。
- 保留工作区现有未提交改动；每次提交只包含当前任务明确修改的文件。

## 文件与责任边界

- Modify `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`: 分层 token、组件尺寸、交互状态、动态语义色和 motion。
- Modify `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`: 共享页面引导、动作菜单、按钮外观、交互表面、状态和指标组件。
- Modify `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`: 单行 `WorkspaceTitleLockup`、服务状态辅助项、标题 accessibility。
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`: toolbar principal、侧栏选中/焦点/对比度和 route icon 消费方式。
- Modify `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`: 集中固化全部导航 route 的 SF Symbol 映射。
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`, `CreatorSurfaceViews.swift`, `ServiceOverviewView.swift`, `RuntimeMonitoringView.swift`, `ModelManagementView.swift`, `PreflightDiagnosticsView.swift`, `ServiceStatusView.swift`, `ServiceRoutePreviewView.swift`, `SettingsView.swift`, `ProfilePickerView.swift`: 仅迁移共享 token、按钮层级、可点击表面和页面间距，不改变业务调用。
- Modify `docs/developers/macos-app-design-system.md`: 记录新的 token 层级、指针边界和人工验收矩阵。

### Task 1: 扩展全局 token 层级与状态矩阵

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`

**Interfaces:**
- Produces `SpeechRailDesignTokens.Toolbar.titleMaximumWidth`, `titleCompactMaximumWidth`, `titleHeight`。
- Produces `SpeechRailDesignTokens.Interaction.minimumHitTarget`, `pressedScale`, `hoverFillOpacity`, `pressedFillOpacity`, `disabledOpacity`, `focusLineWidth`。
- Produces `SpeechRailDesignTokens.Button.standardHeight`, `prominentHeight`, `iconHitTarget` and `SpeechRailDesignTokens.Icon.navigationSize`, `navigationFrame`, `toolbarSize`。
- Produces semantic `Surface.surfaceRaised`, `Surface.border`, `Surface.borderStrong`, `Surface.interactionHover`, `Surface.interactionPressed`，保留现有别名以避免迁移时破坏编译。

- [ ] **Step 1: Add component and interaction tokens**

在现有 `Layout`、`Control`、`Surface`、`Motion` 附近增加上述命名；所有新值只引用现有 4pt 间距、连续圆角和动态语义色。`pressedScale` 固定为 `0.985`，焦点描边固定从 `focusLineWidth` 读取，禁止在组件中重新写数字。

- [ ] **Step 2: Align navigation and color aliases**

让导航选中前景、焦点环、边界和 hover/pressed 填充统一从语义色生成，并确保 Increase Contrast 使用当前 `dynamicColor` 的高对比分支；不在页面中直接使用 `Color.primary.opacity(...)` 表达新状态。

- [ ] **Step 3: Run static token audit**

运行 `rtk rg -n "pressedScale|minimumHitTarget|titleMaximumWidth|interactionHover|borderStrong" macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`，确认新接口集中存在；运行 `rtk git diff --check`，不运行自动化测试。

### Task 2: 建立共享按钮与自定义交互表面

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`

**Interfaces:**
- Produces `SpeechRailButtonLevel` with `.primary`, `.secondary`, `.quiet`, `.destructive`。
- Produces `SpeechRailButtonAppearance` (`ViewModifier`) for native `Button`/`Menu` label sizing and tint hierarchy。
- Produces `SpeechRailInteractiveButtonStyle` (`ButtonStyle`) for custom rows/cards, with `hover`、`pressed`、`focus`、`disabled` state。
- Produces `SpeechRailCursorRegion` (`NSViewRepresentable`) as a layout-backed pointing-hand surface for enabled action/selection controls；文本编辑区和静态内容不挂载。
- Keeps `WorkspaceActionsMenu` initializer source-compatible while changing its visible label to “更多操作”。

- [ ] **Step 1: Add the native button appearance modifier**

实现 `speechRailButton(_ level: SpeechRailButtonLevel)`：`.primary` 使用系统 `.borderedProminent` 和 `Color.rail`，`.secondary` 使用系统 `.bordered`，`.quiet` 使用系统 `.borderless`/`.plain` 的低干扰语义，`.destructive` 使用 `Color.critical`。统一应用 `controlSize`、`minimumHitTarget` 和 enabled-only pointing hand；不替换系统的按压与焦点反馈。

- [ ] **Step 2: Add the custom interactive style**

实现 `SpeechRailInteractiveButtonStyle`：用 `configuration.isPressed` 表达 pressed，`onHover` 仅记录 custom surface 的 hover；按压时从 `SpeechRailDesignTokens.Interaction.pressedScale` 读取缩放，背景/边界从 Surface token 读取；使用 `.focusable(true)` 与共享 focus ring；`@Environment(\.isEnabled)` 为 disabled 时关闭 hover 和 cursor。

- [ ] **Step 3: Add cursor rect bridge**

实现 `SpeechRailCursorRegion` 的 `NSView` 子类，在 `resetCursorRects()` 中对自身 bounds 添加 `NSCursor.pointingHand`；将它作为 enabled 控件的不可命中 overlay。静态 surface、TextField/TextEditor 和 disabled 控件不挂载有效 cursor rect。

- [ ] **Step 4: Migrate shared components**

将 `StatusBanner`、`OperationBar`、`WorkspaceActionsMenu` 中的按钮迁移到共享 native appearance；把 action menu label、help、accessibility label、44pt 命中区固化；更新 `PageIntroView` 和 `SectionHeading`，去除装饰性胶囊依赖，保留 Signal Loom 的 rail accent 作为小型语义标记。

### Task 3: 重做全局标题 lockup 与 toolbar 动作

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`

**Interfaces:**
- Produces `WorkspaceTitleLockup(route:service:)`。
- Keeps `WorkspaceTitleView(route:service:)` as a thin compatibility wrapper that delegates to `WorkspaceTitleLockup` until all call sites migrate。

- [ ] **Step 1: Implement title variants**

使用固定的“icon + workspace”单行结构；工作区标题使用 `lineLimit(1)`、尾部截断、适度缩放和 `Toolbar.titleMaximumWidth`，不使用 `layoutPriority` 抢占左右 toolbar item；context 与 service status 只进入辅助功能语义，不放进中心标题。

- [ ] **Step 2: Normalize title accessibility**

标题 lockup 合并为一个 accessibility element，label 使用 workspace title，value 依次包含 context 和服务状态；变体切换不产生重复子元素；identifier 保持 `workspace-title`。

- [ ] **Step 3: Rewire the shell toolbar**

在 `ControlCenterView` 的 `.principal` 使用 `WorkspaceTitleLockup`，由固定标题槽位保护中心几何；把服务状态放入辅助功能语义，toolbar 右侧只保留清晰的文字动作组和系统默认反馈。

- [ ] **Step 4: Verify title geometry statically**

检索所有 `WorkspaceTitleView`/`WorkspaceTitleLockup` 调用，确认没有页面 body 重复绘制工作区标题；检索 `.toolbar` 中的无 label icon button，逐一补齐 label/help 或移入 `WorkspaceActionsMenu`。

### Task 4: 统一 route icon、导航选中态和指针语义

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`

- [ ] **Step 1: Centralize SF Symbol mapping**

固化 route 映射：`waveform`、`wand.and.stars`、`person.wave.2`、`square.stack.3d.up`、`server.rack`、`chart.xyaxis.line`、`cube`、`stethoscope`；`RouteIconView` 只消费 `route.systemImage`，不允许页面传入临时 symbol 或改变光学尺寸。

- [ ] **Step 2: Rebuild selected navigation row**

保留原生 `NavigationLink`，统一使用 44pt row、tokenized inset、低噪声 accent fill、Ink 前景和共享 focus ring；selected、hover、keyboard focus 分开表达；enabled 导航行显示 pointing hand，disabled/静态区域不显示。

- [ ] **Step 3: Align icon rendering**

让侧栏和 toolbar icon 使用同一 weight、symbol rendering mode、frame token；未选中使用 `InkSecondary`/titanium，选中使用高对比 `Navigation.selectedForeground`，在 Dark 和 Increase Contrast 下不使用深色文字压在亮色选中背景上。

### Task 5: 迁移所有页面的操作层级与可点击表面

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift`

- [ ] **Step 1: Migrate visible primary actions**

为每个页面保留唯一主要推进按钮：模型页“下载并校验”、诊断页“重新运行诊断”、创作页“生成并试听/生成候选音色”等使用 `.speechRailButton(.primary)`；辅助动作使用 `.secondary` 或 `.quiet`；停止、删除、卸载使用真实 destructive role 和现有确认流程。

- [ ] **Step 2: Migrate custom rows and cards**

把模型 artifact 行、profile 行、诊断检查项、候选音色试听/保存行和作品审计入口统一迁移到 `SpeechRailInteractiveButtonStyle`；保留现有 selection/action/accessibility identifier；删除页面级 `.buttonStyle(.plain)` 后遗留的无反馈 hover/cursor 实现。

- [ ] **Step 3: Keep passive surfaces passive**

检查 Metric、StatusBanner、DeveloperInspector、说明卡和只读技术字段：没有 action 时不加 `contentShape`、hover background、cursor bridge 或可聚焦语义；只读内容继续使用静态 surface token。

- [ ] **Step 4: Preserve real wiring**

逐页面核对 `AppModel`、`AppNavigationState`、模型下载/校验、服务刷新、诊断刷新、运行监控刷新和音色创作 action 的调用闭包未被替换；只改变 label/style/modifier，不修改请求参数和状态流转。

### Task 6: 完成全局静态审查与文档同步

**Files:**
- Modify: `docs/developers/macos-app-design-system.md`

- [ ] **Step 1: Audit style drift**

运行 `rtk rg -n "Color\.|cornerRadius\(|padding\(|onHover|NSCursor|buttonStyle\(\.plain\)|WorkspaceTitleView|Image\(systemName:" macos/SpeechRailApp/SpeechRailApp`，逐项区分共享组件内部允许的实现与页面级违规项；页面只保留业务必要的布局 token。

- [ ] **Step 2: Audit toolbar and accessibility**

确认每个 toolbar action 有文字或明确 accessibility label/help；确认所有 icon-only controls 命中区至少 44pt；确认 disabled/loading 不是只变灰而没有状态语义；确认标题只有一个 accessibility element。

- [ ] **Step 3: Document the final rules**

在 `macos-app-design-system.md` 增加 token 分层、标准控件与 custom surface 的 cursor 边界、selected/focus 区分、单行标题策略和人工审阅矩阵，标注自动化测试仍按用户指令暂停。

### Task 7: 允许范围内的验证与交付

**Files:**
- No new product files.

- [ ] **Step 1: Compile the macOS app without tests**

运行 `scripts/macos_app_build.sh --configuration Debug`，只验证 Swift 编译和链接；不调用 `scripts/macos_app_test.sh`，不启动 XCTest/XCUITest。

- [ ] **Step 2: Review the diff and boundaries**

运行 `rtk git diff --check`、`rtk git diff --stat`，确认变更只在 macOS App token/shared UI/page migration 与 design-system 文档，服务代码、协议、模型文件和用户配置没有被修改。

- [ ] **Step 3: Record manual review cases**

人工检查最小窗口、长中文/英文标题、Light、Dark、Increase Contrast、Reduce Motion、鼠标移入/按下/离开、键盘 focus、VoiceOver label；记录未验证的真实运行态，不把编译成功当作 UX 验收。

- [ ] **Step 4: Commit the implementation as one logical change**

暂存本计划列出的实现文件，使用 `git diff --staged --check` 和 staged name-only 检查后提交：

```bash
git commit -m "refactor(macos): unify global interaction language"
```
