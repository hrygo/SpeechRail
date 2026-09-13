---
title: "SpeechRail macOS App 设计系统与 Token"
status: active
audience: "SpeechRail macOS App 设计、开发与测试人员"
version: "0.4.1"
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
| Liquid Glass | 直接使用系统 `glassEffect` 能力承载窗口/导航层和关键控制 | 不参与 GUI 渲染 | 玻璃只表达导航或交互层；内容与 Inspector 不铺玻璃 |
| 浮动工具栏与分组 | 直接使用系统 toolbar、`ToolbarSpacer`、scroll edge effect | 不参与 GUI 渲染 | 重要命令仍进入菜单栏，不能只放在 toolbar |
| 导航 | `NavigationSplitView` 使用 macOS 26 sidebar 行为 | 不参与 GUI 导航 | 不另造一套平行导航；窗口变窄时使用系统折叠 |
| 菜单栏入口 | `MenuBarExtra` 展示健康状态和高频动作 | 不参与 GUI 渲染 | 菜单栏是快速入口，不承载完整监控看板 |
| 可访问焦点 | 使用 macOS 26 的默认焦点、container、label/value 和键盘导航 | 协议层只传递状态，不渲染 UI | 不以旧系统 API 为理由移除可访问语义 |
| 动效 | 系统 Liquid Glass 和标准控件动效 | 不参与 GUI 渲染 | 尊重 Reduce Motion，不能把动效当信息唯一来源 |

App target 的 `MACOSX_DEPLOYMENT_TARGET` 必须为 `26.0`，只要是 App 页面或 App 专属
设计组件，就直接依赖 macOS 26 API。不得为了让 App target 继续编译到 macOS 14 而加入
条件分支、兼容视觉 fallback 或删除 macOS 26 行为；服务侧独立 target 的最低版本不改变
App 的 UI 实现。内容层使用标准 macOS 内容表面是信息层级决策，不是为了兼容旧系统而降级。

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
| 间距 | `Spacing` | 使用 `micro/xs/sm/md/lg/xl`，页面默认节奏为 4/8/12/16/24/32 |
| 圆角 | `Corner` | 控件、面板、窗口分别使用固定层级；内层控件不超过外层容器的圆角层级 |
| 布局 | `Layout` | sidebar、内容最大宽度、窗口最小尺寸集中管理，支持 resize/full screen |
| 控件 | `Control` | 使用系统 `controlSize`，自定义容器只引用统一的触达尺寸和图标尺寸 |
| 字体 | `Typography` | 优先语义字体，不在页面内硬编码字号；用户字体偏好由系统接管 |
| 颜色 | `Palette` | 使用 `Color.primary`、`Color.secondary`、系统 accent 和语义色，自动适配明暗与高对比 |
| 表面 | `SpeechRailSurfaceLevel`、`speechRailContentSurface()` | `window/navigation` 使用系统玻璃；`control` 使用系统 material 加细描边；`panel/inspector` 使用自适应内容表面，不铺玻璃 |
| 动效 | `Motion` | 所有自定义 transition 可关闭或降级；状态变化必须有文字/结构反馈 |

### 3.2 统一使用规则

- 页面背景和导航由系统窗口/侧边栏承载；关键控制使用 `speechRailSurface(.control)`，内容区和 Inspector 使用 `speechRailContentSurface()`，不在各页面重复实现玻璃或阴影。
- 玻璃的使用范围必须可解释：侧边栏、工具栏和需要与内容分离的关键控制可以使用系统玻璃；状态、模型制品、指标和诊断内容不得因装饰需要铺玻璃。
- 主操作每个上下文最多一个，使用系统 `Button` 与 `buttonStyle`；危险动作使用确认对话框并明确影响范围。
- 监控数字使用 tabular figures；错误不能只用颜色表达，同时显示文字、图标或状态标签。
- 图标使用 SF Symbols，并与文字共同构成按钮 label；图标按钮必须有 accessibility label。
- 每个页面的 `ScrollView`、列表和卡片在最小窗口、全屏、深色模式、增加对比度和 Reduce Motion 下验证。
- `MenuBarExtra`、toolbar 和菜单栏动作保持同一命令语义；菜单栏不能触发第二个服务实例。

## 4. 验收清单

- [x] App target 的最低系统版本为 macOS 26.0，并使用系统 Liquid Glass 结构能力（2026-09-13 Debug build 已验证）。
- [x] App 未通过自绘根背景阻断 scroll edge effect；玻璃只用于窗口/导航层，内容和 Inspector 使用统一内容表面（2026-09-13 代码审查已验证）。
- [x] 所有 App 页面主要产品间距、尺寸、颜色和字体从 `SpeechRailDesignTokens` 读取；零间距仅用于 Divider/列表拼接等结构性布局。
- [ ] Light、Dark、Increase Contrast、Dynamic Type 和 Reduce Motion 均有 UI 验证；当前只完成代码/构建检查，尚未完成桌面人工矩阵。
- [ ] VoiceOver 可按“导航 → 页面说明 → 主操作 → 状态详情”的顺序访问；图表、档位和 DisclosureGroup 语义已接入，尚未完成桌面 VoiceOver 实测。
- [x] 页面高频动作已提供 toolbar、菜单栏或键盘路径，不依赖 hover；2026-09-13 UI tests 验证控制台、设置和主要页面入口。
- [x] 音色创作、模型下载、profile 应用、服务启停的边界在 UI 文案和确认动作中可见；模型下载与档位应用使用独立按钮和确认框。

## 5. 当前实现与验证矩阵

| 范围 | 实际结果 | 验证时间 |
|---|---|---|
| App Debug 构建 | `BUILD SUCCEEDED`，目标为 `arm64-apple-macos26.0` | 2026-09-13 13:59 |
| Swift 单元测试 | 32 tests，0 failures | 2026-09-13 14:04 |
| UI 测试 | 7 tests，0 failures；覆盖导航、服务状态、模型确认/恢复/能力不匹配、监控空状态、设置 | 2026-09-13 14:04 |
| 设置单场景复核 | 1 test，0 failures | 2026-09-13 14:03 |
| Release App 安装 | `2.5.2 (1)`、`arm64`、`LSMinimumSystemVersion=26.0`，签名与嵌入 XPC 通过；已安装到 `~/Applications/SpeechRail.app` | 2026-09-13 14:15 |
| 安装后服务隔离 | `/health`、`/readyz` 通过；仍为唯一 8201 listener（PID 25912），quality profile；未重启服务 | 2026-09-13 14:16 |
| 桌面视觉矩阵 | 尚未完成；仍需人工检查最小窗口、深色、高对比度、Reduce Motion | — |
| VoiceOver 实测 | 尚未完成 | — |

## 6. 变更流程

新增组件先判断是否能由标准 SwiftUI 控件表达；确需定制时先补充 token 和可访问语义，
再实现组件。token 变更必须同时更新本文件、对应 Swift 定义、组件测试和 macOS App
视觉验收记录。不得在单页样式中创建只被一次使用的产品色、间距或圆角。
