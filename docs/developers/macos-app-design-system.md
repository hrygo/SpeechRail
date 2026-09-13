---
title: "SpeechRail macOS App 设计系统与 Token"
status: active
audience: "SpeechRail macOS App 设计、开发与测试人员"
version: "0.3.0"
date: 2026-09-13
---

# SpeechRail macOS App 设计系统与 Token

## 1. 研究基线（2026-09-13）

本设计系统以 Apple 官方 macOS 26 / Xcode 26 资料为基线。`SpeechRailApp` GUI target
明确以 macOS 26.0 为最低版本，不为 App UI 编写 macOS 14 的兼容 fallback；服务协议、
ControlKit、ControlAgent 和服务侧 SwiftPM worker 是独立边界，是否保留更低最低版本由各自
运行职责决定。研究结论是：App 在 macOS 26 上完整使用系统新设计能力，不把新特性降级为
共同最低版本的视觉实现。

- Apple 的 macOS 指南要求充分利用大屏、可调整窗口、菜单栏、键盘快捷键和可定制工具栏，避免把重要内容藏在过多模态层级中。[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- macOS 26 的新设计以 Liquid Glass 作为工具栏、侧边栏和重要控制的系统层；标准 SwiftUI 结构和控件会获得系统级更新，定制玻璃只用于真正重要的产品特性，不用自绘玻璃模拟系统。[Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)、[Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- `NavigationSplitView` 适合 SpeechRail 的多根类别导航；`MenuBarExtra` 适合常用状态和动作；`Settings` 由系统负责从 App 菜单和 `Command-,` 打开。[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)、[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[Settings](https://developer.apple.com/documentation/swiftui/settings)
- macOS 工具栏中的高频命令必须同时存在于菜单栏，避免用户隐藏工具栏后失去能力；工具栏动作按逻辑分组，窄窗口交给系统 overflow 处理。[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- VoiceOver 在 macOS 上主要通过键盘操作。页面应使用合理的 accessibility container、明确的 label/value、可访问动作和快捷键；任何只依赖 hover 的动作都必须提供可见或键盘可达的替代入口。[Make your Mac app more accessible to everyone](https://developer.apple.com/videos/play/wwdc2025/229/)、[Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## 2. App 层不以兼容牺牲特性

### 2.1 平台能力矩阵

| 能力 | SpeechRailApp macOS 26+ | 独立服务/协议边界 | 设计决策 |
|---|---|---|---|
| Liquid Glass | 直接使用 `glassEffect`、`GlassEffectContainer`、`glassEffectID` 和必要的 tint | 不参与 GUI 渲染 | App 不写 Material fallback，不自绘假玻璃 |
| 浮动工具栏与分组 | 直接使用系统 toolbar、`ToolbarSpacer`、scroll edge effect | 不参与 GUI 渲染 | 重要命令仍进入菜单栏，不能只放在 toolbar |
| 导航 | `NavigationSplitView` 使用 macOS 26 sidebar 行为 | 不参与 GUI 导航 | 不另造一套平行导航；窗口变窄时使用系统折叠 |
| 菜单栏入口 | `MenuBarExtra` 展示健康状态和高频动作 | 不参与 GUI 渲染 | 菜单栏是快速入口，不承载完整监控看板 |
| 可访问焦点 | 使用 macOS 26 的默认焦点、container、label/value 和键盘导航 | 协议层只传递状态，不渲染 UI | 不以旧系统 API 为理由移除可访问语义 |
| 动效 | 系统 Liquid Glass 和标准控件动效 | 不参与 GUI 渲染 | 尊重 Reduce Motion，不能把动效当信息唯一来源 |

App target 的 `MACOSX_DEPLOYMENT_TARGET` 必须为 `26.0`，只要是 App 页面或 App 专属
设计组件，就直接依赖 macOS 26 API。不得为了让 App target 继续编译到 macOS 14 而加入
条件分支、Material 替代面板或删除 Liquid Glass 行为；服务侧独立 target 的最低版本不
改变 App 的 UI 实现。

### 2.2 SpeechRail 的产品层级

1. **创作层**：配音台、音色创作、音色库、我的作品是一级产品能力，不能被服务管理页替代。
2. **服务层**：总览、运行监控、模型管理、预检与诊断解释本机服务能否使用、为什么异常以及下一步动作。
3. **技术层**：仅在用户主动打开“开发者详情”或进入诊断细节时出现端口、profile、worker、metrics 和错误码。

每个页面都先回答“它是什么、什么时候用、下一步做什么”，再按需显示技术细节。

## 3. Token 单一事实来源

SwiftUI 代码中的颜色、间距、圆角、窗口尺寸、控件高度和字体层级统一来自：

`macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`

页面不直接散落 `Color(red:green:blue:)`、任意 `CGFloat`、自定义字号或重复的 corner radius。
Apple 的系统颜色、字体、材料和标准控件优先于自定义 token；SpeechRail token 只补足产品
语义、布局约束和跨 macOS 版本的统一映射。

### 3.1 Token 分类

| 分类 | Swift 名称 | 约束 |
|---|---|---|
| 间距 | `Spacing` | 只使用 `xxs/xs/sm/md/lg/xl/xxl`，页面默认节奏为 8/12/16/24 |
| 圆角 | `Corner` | 控件、面板、窗口分别使用固定层级；内层控件不超过外层容器的圆角层级 |
| 布局 | `Layout` | sidebar、内容最大宽度、窗口最小尺寸集中管理，支持 resize/full screen |
| 控件 | `Control` | 使用系统 `controlSize`，自定义容器只引用统一的触达尺寸和图标尺寸 |
| 字体 | `Typography` | 优先语义字体，不在页面内硬编码字号；用户字体偏好由系统接管 |
| 颜色 | `Palette` | 使用 `Color.primary`、`Color.secondary`、系统 accent 和语义色，自动适配明暗与高对比 |
| 表面 | `SpeechRailSurfaceLevel` | 统一走 macOS 26 Liquid Glass，不提供 App UI Material fallback |
| 动效 | `Motion` | 所有自定义 transition 可关闭或降级；状态变化必须有文字/结构反馈 |

### 3.2 统一使用规则

- 页面背景、导航背景、面板和弹窗按层级使用 `speechRailSurface(_:)`，不在各页面重复实现玻璃或阴影。
- 主操作每个上下文最多一个，使用系统 `Button` 与 `buttonStyle`；危险动作使用确认对话框并明确影响范围。
- 监控数字使用 tabular figures；错误不能只用颜色表达，同时显示文字、图标或状态标签。
- 图标使用 SF Symbols，并与文字共同构成按钮 label；图标按钮必须有 accessibility label。
- 每个页面的 `ScrollView`、列表和卡片在最小窗口、全屏、深色模式、增加对比度和 Reduce Motion 下验证。
- `MenuBarExtra`、toolbar 和菜单栏动作保持同一命令语义；菜单栏不能触发第二个服务实例。

## 4. 验收清单

- [x] App target 的最低系统版本为 macOS 26.0，并使用系统 Liquid Glass 结构能力（2026-09-13 Debug build 已验证）。
- [x] App 未通过自绘背景阻断 scroll edge effect，也未以 Material 替代 Liquid Glass（detail 根背景已移除，玻璃组使用 `GlassEffectContainer`）。
- [ ] 所有 App 页面只从 `SpeechRailDesignTokens` 读取产品 token。
- [ ] Light、Dark、Increase Contrast、Dynamic Type 和 Reduce Motion 均有 UI 验证；当前只完成代码/构建检查，尚未完成桌面人工矩阵。
- [ ] VoiceOver 可按“导航 → 页面说明 → 主操作 → 状态详情”的顺序访问；图表、档位和 DisclosureGroup 语义已接入，尚未完成桌面 VoiceOver 实测。
- [ ] 页面高频动作可从 toolbar、菜单栏或键盘路径到达，不依赖 hover。
- [ ] 音色创作、模型下载、profile 应用、服务启停和回退的边界在 UI 文案中清楚可见。

## 5. 变更流程

新增组件先判断是否能由标准 SwiftUI 控件表达；确需定制时先补充 token 和可访问语义，
再实现组件。token 变更必须同时更新本文件、对应 Swift 定义、组件测试和 macOS App
视觉验收记录。不得在单页样式中创建只被一次使用的产品色、间距或圆角。
