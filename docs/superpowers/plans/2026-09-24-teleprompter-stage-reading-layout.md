# 提词器舞台紧凑阅读布局实施计划

> **For agentic workers:** 按任务顺序执行，先写失败测试，再实现最小改动并重跑相关验证。未经明确要求不提交或推送。

**Goal:** 修复提词器舞台的透明度、空间利用、横向缩放、快捷键和 1／2／3 条实际视觉行配置，使三条模式按“已读行／当前行／下一行”稳定呈现。

**Architecture:** 保留现有 `TeleprompterSession` 的段落索引、句内偏移和手动接管语义；按可用宽度和字体生成带 UTF-16 来源范围的显示行；将舞台显示数量扩展到 1–3 行，三行时以当前阅读行为中心且首尾保留空槽。用 AppKit 窗口标准缩放回调控制横向展开与高度上限，SwiftUI 阅读焦点处理局部键盘命令。透明度仍沿用现有 UserDefaults 键，零不透明度时不绘制阅读区装饰背景。

**Tech Stack:** Swift 6.2、SwiftUI、AppKit、Swift Testing；macOS 26。

**Spec:** `docs/superpowers/specs/2026-09-24-teleprompter-manual-first-design.md`（按本计划更新显示设置契约）。

## Global Constraints

- 默认手动阅读；任何手动定位继续复用现有语音接管、generation 失效及资源清理行为。
- 不改稿件、AI、ASR、持久化稿件结构或公开服务 API。
- 透明度只控制舞台背景，不降低正文与可访问控件的不透明度。
- 新增视觉尺寸只放入 `SpeechRailDesignTokens.Teleprompter`。
- 不运行会接管窗口、焦点、输入或屏幕的 UI 自动化；本次以确定性 Swift Testing 和 App 编译验收，桌面观感列为未验证风险。
- 不提交、不推送、不安装或发布。

## Review Focus

- 首尾三条模式中当前条仍稳定居中，缺失上下文不改变导航位置：纯展示策略边界测试。
- 超长段落仍完整可读，滚动/选择不被新布局静默截断：舞台代码检查及现有段落显示回归。
- 100% 透光移除所有阅读区背景叠层，但正文与控制仍清晰：透明度端点测试、代码审查及构建。
- 最大化只扩宽、不超过高度上限，恢复窗口不丢普通宽度：纯几何策略测试和委托实现检查。
- 控件/Popover 焦点期间箭头键不误翻段，普通阅读焦点能翻段：键盘策略测试及 App 编译；桌面行为须人工验收。

---

### Task 1: 锁定设置与可见阅读条策略

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageSettingsTests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageSettings.swift`

**Interfaces:** 现有舞台设置持久化项（内部改为 `visibleLineCount`）；新增 `TeleprompterStageLineLayout` 和 `visibleLineSlots`。

- [x] 先补测试：设置值可持久化为 1、2、3，超界夹紧为 1／3；保留基线默认值 3。
- [x] 先补行布局测试：窄宽度确实换行、UTF-16 范围连续且不拆 Unicode grapheme；另测 1／2／3 行槽、三行当前居中、首尾空槽。
- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter TeleprompterStageSettingsTests` 确认新增断言先失败。
- [x] 实现 1–3 范围与固定槽策略，再运行同一测试确认通过。

### Task 2: 放开透明度端点并去除正文最大宽度

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageSettings.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageSettingsTests.swift`

- [x] 补 0%／100% 透光与旧 `opacity` 键重载测试，确认 100% 不再被夹到 65%。
- [x] 将不透明度范围扩至 0–1；百分比展示取整数；保留默认值与已存用户偏好。
- [x] 移除 720pt 正文宽度封顶，改为填满阅读区可用宽度。
- [x] 背景不透明度为零时不绘制正文背景材质、底色、边框和当前行底板；语音错误提示和底部操作仍保持可读。
- [x] 定向测试通过后检查暗/亮语义色和 Reduce Transparency 路径未被硬编码色覆盖。

### Task 3: 实际视觉行布局与 1／2／3 行选择

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageSettings.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageSettingsTests.swift`

- [x] 设置 Popover 提供可键盘操作的 1／2／3 行选择，标签与持久化值一致。
- [x] 新增 `TeleprompterStageLineLayout`：依 SwiftUI 字号与可用宽度计算视觉行，逐行保存段落索引、稳定 ID 和 UTF-16 起止位置；不改写稿件或 segmenter。
- [x] 普通阅读模式以当前 UTF-16 阅读位置定位视觉行；三行时显示上一已读行／当前行／下一行，当前固定在中间；首尾空槽不造成跳动。
- [x] 键盘与按钮移动到前/后一视觉行的 UTF-16 起点；全稿浏览继续按完整段落显示并可滚动选择。
- [x] 行布局重算只由稿件、字号或可用宽度变化触发；单次翻行不重排全文；超长行不得截断朗读文本。

### Task 4: 横向展开和高度上限

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageWindow.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageSettings.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageSettingsTests.swift`

- [x] 先为最大化 frame 策略写纯测试：宽度等于目标屏幕 `visibleFrame` 宽度、顶部对齐、高度不超过舞台 Token 上限。
- [x] 通过 `NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:)` 提供“横向填满、纵向限高”的标准缩放 frame；不进入真正全屏空间。
- [x] 调整窗口宽度上限，支持当前屏幕宽度；最大化期间不覆盖用户普通宽度偏好。
- [x] `show()` 不再重复设置现有窗口尺寸；设置入口前置窗口时保留尺寸与位置。
- [x] 处理副屏、屏幕可用区域、初始位置与最小/最大内容尺寸冲突；所有窗口尺寸 Token 单一声明。

### Task 5: 可靠翻段快捷键与焦点闭环

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageWindow.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageInteractionPolicy.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageInteractionPolicyTests.swift`

- [x] 补策略测试：阅读焦点接受翻视觉行；按钮／滑杆／Popover 焦点与弹层打开时不接管按键。
- [x] 舞台首次显示后获得阅读焦点；失焦到别的应用时不得反复抢焦点；关闭 Popover 后恢复阅读焦点。
- [x] 空格、方向键、PageUp/PageDown、Home/End 以视觉行起点更新 Session 的段落索引和 UTF-16 偏移，并确保每个事件只调用一次手动接管动作。
- [x] App 菜单可通过可见快捷键调用相同的上一条／下一条动作，不新增全局热键、不改变编辑控件按键语义。
- [x] 不更改语音接管、句内位置、边界 clamp 或 VoiceOver 行为。

### Task 6: 同步正式设计与行为文档

**Files:**
- Modify: `docs/developers/macos-app-design-system.md`
- Modify: `docs/developers/macos-app-teleprompter.md`
- Modify: `docs/superpowers/specs/2026-09-24-teleprompter-manual-first-design.md`

- [x] 把原“只显示当前段和下一段”更新为 1／2／3 实际视觉行，说明三行当前行居中和原稿 UTF-16 映射。
- [x] 记录 100% 透明度端点、最大化横向铺满与高度上限、快捷键/焦点规则。
- [x] 只在正文实质变化时更新正式文档版本或日期；历史记录不改写为当前承诺。

### Task 7: 定向验证和交付审查

**Files:**
- Review all changed files and test/build output; no additional product files by default.

- [x] 执行提词器相关 Swift Testing；所有新增策略测试应通过。
- [x] 执行 `scripts/macos_app_build.sh --configuration Debug`，验证 AppKit/SwiftUI 集成编译。
- [x] 检查 `git diff --check`、暂存状态（不暂存本次改动）和最终 diff，确认无敏感内容及计划外文件。
- [x] 不运行 UI 自动化、录屏、窗口断言、安装或发布；在交付中明确说明真实桌面观感仍待人工验收。
- [x] 不提交、不推送。
