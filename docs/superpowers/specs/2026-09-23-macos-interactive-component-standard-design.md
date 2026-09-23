# SpeechRail macOS 可交互组件规范

日期：2026-09-23
状态：静态实施完成；待构建与视觉验收
范围：SpeechRail macOS App 的控制中心、14 个路由、Settings、菜单栏、字幕带和提词器窗口

## 目标

用户在不同页面遇到同类操作时，应能从外观、文字和键盘行为判断它会做什么。视觉变化不能改变已有业务动作、数据、会话所有权或服务运行态。组件规范以当前 `SpeechRailDesignTokens` 和原生 SwiftUI/AppKit 控件为基础。

本轮静态定位得到约 370 处 `Button(...)` / `Button { ... }` 构造、约 158 处 `.speechRailButton(...)` 调用。原生按钮本身并非缺陷；逐个换成自绘组件会破坏平台语义。需要统一的是组件角色、适用状态、视觉值归属和例外记录。

## 组件家族

| 家族 | 声明点 | 用途 | 视觉与交互合同 |
|---|---|---|---|
| 页面主次动作 | `SpeechRailButtonAppearance`、`SpeechRailButton` | 开始、保存、导出、取消、危险动作 | `.primary/.secondary/.quiet/.destructive` 对应原生按钮层级；每个操作区只突出一个主动作；禁用必须有可解释的上下文 |
| 工具栏动作 | `PageActionButton`、`PageActionsMenu` | 当前页的具体动作和低频菜单 | 图标来自 SF Symbols；纯图标动作必须有明确的中文无障碍名称和提示，不能回退到符号 ID |
| 行内动作 | `RowActionGlyph` 与所属 `Button`/`Menu` | 试听、导出、改名和更多操作 | 图标框、字重和次级墨色使用现有 token；动作按钮与行选择是两个独立焦点，不用嵌套按钮 |
| 选择行与可点卡片 | 系统 `List`/`Table`，或 `SpeechRailInteractiveButtonStyle` | 选路由、选音色、选角色、展开详情 | 整个可点区域必须是 `Button`、`NavigationLink` 或系统选择控件；选中态有文字或可访问 value，颜色不是唯一线索 |
| 输入与取值 | `TextField`、`SecureField`、`TextEditor`、`Picker`、`Toggle`、`Slider`、`Stepper` | 设置和任务输入 | 保留原生控件；输入边界沿用 `.speechRailRecessedSlot()` / `.speechRailEditorCard()`；标签、帮助、错误与内容相邻，不能以占位文字替代标签 |
| 紧凑浮层 | 字幕带和提词器窗口中的控件 | 悬浮会话操作 | 可使用比主窗口更紧的既有尺寸 token；仍需键盘、VoiceOver、焦点与 Reduce Motion；不全局套主窗口按钮高度 |
| 状态与反馈 | `StatusPill`、`NoticeBar`、`SettingsConnectionStatus` 等 | 忙碌、完成、受阻、失败 | 状态由文字与图标共同表达；忙碌时操作防重复触发；失败给可执行的下一步 |

## 必备状态与适用边界

每个可交互家族记录并检查默认、hover、pressed、键盘 focus、disabled、selected、busy、error 中适用的状态。不适用的状态明确标为“不适用”，不添加装饰性动效。原生控件已有的状态由系统承担，自定义行与工具栏动作由共享样式承担。

所有纯图标按钮都须在构造时提供准确的可访问名称。`help` 可补充结果或下一步，不用 SF Symbol 名称充当名称。可选择对象的选中状态同时进入屏幕文字或 `accessibilityValue`。行内试听等次级动作与行选择保持分离，点击试听不应顺带更换选中项。

交互反馈尊重 Reduce Motion、Increase Contrast、Reduce Transparency。颜色、hover 与指针形状都不能成为唯一操作提示。保持系统强调色、系统文本样式、窗口工具栏和侧边栏行为；不套用网页设计 skill 中的字体替换、重阴影和逐项弹跳动效。

## 已确认的收敛点

1. `AssistantView.voiceRow` 当前以 `.onTapGesture` 选择音色，同行还有试听按钮。改为有独立焦点的选择按钮和试听按钮，保留原来的选中状态及不可用门禁。
2. `PageActionButton` 当前允许纯图标按钮缺少 `helpText`，并会把 `systemImage` 当作无障碍名称。将名称变成必填的接口条件，现有调用点的具体中文提示继续复用。
3. `SettingsAssistantPane` 中的 `.small` 原生按钮、`CaptionBandWindow` 的紧凑控件、`SpeakerLabelingView` 的内联编辑都属于有意的尺寸例外。规范记录这些例外；迁移时不把它们强制放大。
4. 页面内继续使用 `SpeechRailDesignTokens.swift` 作为视觉数值唯一声明点；新增产品视觉值必须先进入该文件，再同步 active 设计系统文档。

## 验收边界

- 每种交互形式可映射到一个组件家族或说明过的原生例外；没有仅靠手势点击、无法用键盘到达的主要动作。
- 工具栏纯图标动作有具体中文名称；选择行有可读选中状态；忙碌与失败不只靠颜色表达。
- 视觉调整不修改 REST、Realtime、MCP、XPC、音频采集、模型和持久化协议。
- 本轮只进行源码、Swift 语法和差异检查。构建、安装与会接管前台的 UI 自动化由对应授权单独触发；没有运行就不宣称视觉验收完成。

回退方式：代码与设计系统文档的改动可按文件差异撤回；不涉及用户数据迁移或服务运行态切换。

## 本轮静态核对

已收紧 `PageActionButton` 的说明文字接口，并逐一核对现有调用点。音色选择与试听拆为独立按钮；搜索清空、选择状态和紧凑纯图标动作补齐可访问名称、取值或指针反馈。修改过的 Swift 文件通过语法解析，`git diff --check` 无空白错误。

这些结果只证明源码层面的实施与语法、差异检查；未做类型检查、App 构建、替换安装或前台视觉验收。
