# SpeechRail macOS 26 UI/UX 审查与优化执行计划

> For agentic workers: REQUIRED SUB-SKILL: Use the executing-plans skill to implement this plan task-by-task. Each step uses checkbox syntax and ends with an independently verifiable result.

**Goal:** 将 SpeechRail macOS 控制面收敛为一套可验证的 macOS 26 原生 UI/UX 契约，统一 14 个路由、响应式窗口、会话状态、键盘与辅助功能路径，并以证据矩阵完成交付验收。

**Architecture:** 保留现有 SwiftUI + AppKit 控制面边界，以 AppRoute 作为唯一导航事实源，以 WindowLayoutPolicy 作为纯响应式策略，以 WorkspaceComponents / SessionDesignSurface 作为共享视觉与交互组件。页面只声明业务状态和页面特有动作；窗口折叠、Inspector 行为、动效、Token、文案和可访问语义由共享契约承载。

**Tech Stack:** macOS 26.0、Apple Silicon arm64、Swift 6、SwiftUI、AppKit、Xcode project、Swift Package tests、XCTest/XCUITest（仅在用户当次明确授权后运行 UI 自动化）。

**Spec:** docs/superpowers/specs/2026-09-13-speechrail-macos26-workspace-redesign-design.md、docs/superpowers/specs/2026-09-13-speechrail-macos26-console-chrome-redesign-design.md、docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md、GitHub Issue #79（https://github.com/hrygo/SpeechRail/issues/79）。

---

## 1. 计划定位

本文件是 Issue #79 的本地执行版，负责把已经完成的 UI/UX 审查转换成可逐任务实施、测试和回查的工程步骤。它不是重新设计一套独立视觉，也不替代已有页面规格；已有规格负责说明用户体验目标，本计划负责说明改哪些文件、以什么接口收敛、用什么证据验收。

本计划覆盖：

1. 导航、路由、菜单、快捷键、工具栏身份和设计文档的一致性；
2. 1120×720 到 1920×1080 的主窗口响应式行为；
3. 创作、会话、引擎三条产品线的共享外壳与 macOS 平台语义；
4. Assistant、Meeting、实时字幕、AI 提词器的状态优先级和主动作；
5. Token、文字样式、文案、空态、错误态和预览验收；
6. 代码、静态检查、单元测试、人工桌面矩阵和可授权 UI 自动化之间的证据分层。

计划生成时本文件不直接执行产品代码修改；当前执行已按下列任务逐项落地，并以进度账本记录实际证据。执行者仍必须把与本计划无关的并行改动从写入范围中排除。

## 2. 当前基线与事实边界

审查基线为 2026-09-21，分支为 main，最近已知提交为 4318e799。当前 AppRoute 有 14 个路由：

| 分组 | 路由 |
|---|---|
| 创作 | dubbing、voiceDesign、voiceClone、voiceLibrary、works |
| 会话 | assistant、meeting、captions、teleprompter |
| 引擎 | overview、monitoring、models、diagnostics、developerDocs |

当前共享结构已经存在，执行时应延伸而非平行重造：

- 主窗口由 ControlCenterView 的 NavigationSplitView 承载；
- App.swift 提供 Window、MenuBarExtra、Settings 和 SpeechRailCommands；
- WindowLayoutPolicy.swift 与 AppNavigationState.swift 已有 WindowLayoutTier 及双阈值迟滞状态机；
- WorkspaceComponents.swift 提供 PageScaffold、PageIdentityToolbarItem、PageActionButton、PageActionsMenu 等共享构件；
- SessionDesignSurface.swift 提供会话状态条、结论条、Inspector 和会话行；
- SpeechRailDesignTokens.swift 是运行时视觉 Token 唯一声明点；
- SpeechRailAppUITests/SpeechRailAppUITests.swift 有 13 个现有流程测试；
- WindowLayoutPolicyTests.swift 已覆盖当前 tier 阈值的基本纯函数行为。

在本计划创建前已经存在、必须原样保留并在执行时逐文件核对的未提交改动：

- docs/design/voice-management-and-interaction-contract.md
- macos/SpeechRailApp/SpeechRailApp/AppModel.swift
- macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift
- macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift
- macos/SpeechRailApp/SpeechRailApp/SpeechRailAPICredentials.swift
- macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift
- macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift
- macos/SpeechRailApp/SpeechRailControlKit/ServiceHTTPTransport.swift
- macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

如果执行某一任务需要修改上表文件，先用 git diff -- 文件路径 识别已有改动，再把 UI/UX 变更与既有改动分离；无法安全分离时暂停该文件，不覆盖、不回退、不使用整文件替换。

### 2.1 与既有计划的关系

仓库中已有以下相关计划：

- docs/superpowers/plans/2026-09-13-speechrail-macos26-console-chrome-redesign.md
- docs/superpowers/plans/2026-09-13-speechrail-macos26-workspace-redesign.md
- docs/superpowers/plans/2026-09-13-speechrail-page-by-page-review-todolist.md
- docs/superpowers/plans/2026-09-13-speechrail-uiux-wiring-todolist.md

它们记录过较早一轮视觉、功能接线或逐页清单。本计划只把 Issue #79 中尚未形成交付证据的路由契约、响应式外壳、会话四页和平台验收收口；执行者必须以当前源码、当前 active 文档和当前测试为准，不把旧计划中的“完成”文字当作当前验证证据。

## 3. Global Constraints

以下约束适用于每个任务：

- 运行基线固定为 macOS 26.0+、Apple Silicon arm64；不为 macOS 25 及更早系统或 Intel 增加兼容分支。
- 不改变 REST、Realtime、MCP、XPC、音频采集、记录持久化、模型加载和本机服务生命周期边界。
- 不下载、加载、卸载或切换模型，不启停本机服务，不修改 LaunchAgent。
- 运行时颜色、间距、圆角、字体层级、布局尺寸和动效优先复用 SpeechRailDesignTokens.swift；新增产品视觉值先集中声明，再同步设计系统文档。
- 优先使用 NavigationSplitView、Window、MenuBarExtra、Settings、List、Table、系统工具栏和系统语义色；不引入第三方 UI 框架，不用大面积自绘玻璃、渐变或装饰性动效模拟系统能力。
- 普通用户路径使用“发生了什么 / 是否需要确认 / 下一步做什么”的语言；worker、profile、XPC、capability、协议等内部词只在开发者详情或必要上下文中出现。
- 产品面向普通 macOS 用户，不以完整辅助技术导航流程为目标；全量 VoiceOver 遍历不作为验收项或阻塞项。自定义可操作控件仍须保持基本键盘可达、焦点可见、正确的 accessibility label/value/hint，以及不依赖颜色的文字或图标状态表达。
- Reduce Motion 下不使用弹簧、渐变或持续脉冲；窗口折叠、Inspector 切换和状态回执使用即时或系统无动画过渡。
- 1120×720、1280×800、1440×900、1920×1080 四档窗口必须进入验收矩阵；主对象不可因固定理想高度被推出可视区。
- UI 自动化、XCUITest、录屏、点击驱动、前台窗口接管和 VoiceOver 桌面实测只在当前用户逐次明确授权后执行；没有授权时只能执行静态检查、纯函数测试、构建和不接管窗口的证据。
- 不自动提交、推送、发布或创建 PR；逻辑提交点写入计划，实际提交需另行授权。
- 每个任务开始前运行 git status --short --branch；每个任务结束后运行 git diff --check，并记录实际验证结果。

## 4. Review Focus

以下五类最容易在当前规格沉默处产生回归；每一项都由后续任务绑定到具体测试：

1. 新增或删除路由时侧栏、菜单、快捷键、工具栏身份、帮助和设计文档漏项；由 Task 2 的路由契约检查和可授权 UI 测试覆盖。
2. 窗口在迟滞阈值附近来回拖动时侧栏或 Inspector 抖动、无法恢复、主内容被裁切；由 Task 3 的 WindowLayoutPolicyTests 和四档人工矩阵覆盖。
3. Reduce Motion、Increase Contrast、系统文字偏好或“不要只靠颜色”时状态、按钮和动态反馈失去含义；由 Task 4 的静态语义检查、预览变体和人工矩阵覆盖。完整 VoiceOver 遍历不属于目标用户验收范围，但保留控件基本辅助语义。
4. 会话从 ready、blocked、live、paused、processing、review/archived 转移时主动作重复、出口消失或把内部实现词暴露给普通用户；由 Task 5 的状态清单、预览 fixture 和可授权 UI 测试覆盖。
5. 长标题、长描述、空列表、无麦克风权限、服务不可用、部分完成和破坏性删除时布局或下一步不明确；由 Task 6 的 Token/文案扫描、lived-in preview 和最终矩阵覆盖。

## 5. 文件责任地图

| 文件 | 责任 | 本计划的修改边界 |
|---|---|---|
| macos/SpeechRailApp/SpeechRailApp/AppRoute.swift | 路由、分组、标题、图标、用途句 | 增加路由契约和快捷键规格；不把业务状态放入路由 |
| macos/SpeechRailApp/SpeechRailApp/App.swift | Window、MenuBarExtra、Settings、Commands | 只消费 AppRoute 契约；不再维护独立快捷键字典 |
| macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift | NavigationSplitView、侧栏、detail 和 AppKit 桥 | 消费统一窗口契约；保留系统侧栏入口 |
| macos/SpeechRailApp/SpeechRailApp/AppNavigationState.swift | 当前路由请求和窗口 tier | 对外暴露可测试的布局契约，不承担视图绘制 |
| macos/SpeechRailApp/SpeechRailApp/WindowLayoutPolicy.swift | 纯窗口阈值和 tier 状态机 | 增加可测试的 sidebar/Inspector/toolbar 行为合同 |
| macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift | 页面外壳、标题、动作、交互反馈 | 收敛 PageScaffold 和共享无障碍/动效语义 |
| macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift | 会话状态条、结论条、Inspector、行 | 统一会话页共享结构，不写音频或记录逻辑 |
| macos/SpeechRailApp/SpeechRailApp/AssistantView.swift | 助手四态和右栏 | 只调整状态优先级、动作和布局绑定 |
| macos/SpeechRailApp/SpeechRailApp/MeetingView.swift | 会议页面状态和 Inspector | 只调整状态优先级、动作和布局绑定 |
| macos/SpeechRailApp/SpeechRailApp/SessionSurfaceViews.swift | 实时字幕和会话库页面 | 只调整状态、搜索、列表和 Inspector 语义 |
| macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift | 提词器准备、试读、舞台、回看 | 只调整页面壳和状态文案，不改跟读算法 |
| macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift | 运行时视觉 Token | 只增加经过矩阵确认的语义 Token |
| macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift | 前台 UI 流程 | 仅增补覆盖，不默认运行 |
| macos/SpeechRailApp/SpeechRailMacControlTests/WindowLayoutPolicyTests.swift | 纯窗口策略测试 | 增加 tier 合同和边界回归 |
| docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md | 证据矩阵 | 新建；区分代码证据、人工证据、自动化证据和未验证项 |
| docs/developers/macos-app-design-system.md | active 设计系统和验证矩阵 | 只同步已实施且有证据的契约 |
| docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md | 产品视觉、IA 和页面规格 | 清理过时路由数量和快捷键文字，不重写已接受的视觉原则 |

---

## Task 1: 建立可追溯的 UI/UX 验收矩阵

**Files:**

- Create: docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md
- Read: docs/developers/macos-app-design-system.md
- Read: docs/developers/macos-app-development.md
- Read: docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md
- Read: docs/superpowers/specs/2026-09-13-speechrail-macos26-workspace-redesign-design.md
- Read: docs/superpowers/specs/2026-09-13-speechrail-macos26-console-chrome-redesign-design.md

**Interfaces:**

- Consumes: 当前 AppRoute.allCases、页面状态枚举、窗口尺寸约束、active 设计系统验收清单。
- Produces: 一份可以由后续任务逐格更新的矩阵；每格必须标记 evidence 为 code、manual、automation 或 unverified，并带路径/命令/复现步骤。

- [x] **Step 1: 锁定执行基线**

运行：

~~~bash
git status --short --branch
git log -1 --oneline
~~~

把实际分支、提交、日期和已有未提交文件写入矩阵的“基线”段；如果任一文件与第 2 节列出的已有改动不一致，先停止写入该文件并记录差异。

- [x] **Step 2: 创建矩阵骨架**

在 UIUX-AUDIT-MATRIX.md 中固定以下维度，不允许用“全部页面”代替具体对象：

| 维度 | 具体值 |
|---|---|
| 窗口 | 1120×720、1280×800、1440×900、1920×1080 |
| 外观 | Light、Dark |
| 平台基线 | 键盘可达、焦点可见、label/value/hint、Increase Contrast、Reduce Motion、不要只靠颜色；全量 VoiceOver 遍历不作为验收项 |
| 页面 | 14 个 AppRoute，按创作/会话/引擎分组 |
| 会话状态 | Assistant ready/blocked/live/review；Meeting idle/preparing/recording/interrupted/processing/archived；Captions idle/preparing/running/paused/ending；Teleprompter draft/analyzing/review/ready/preparing/following/paused/uncertain/manual/ended |
| 交互 | 侧栏收起/恢复、Inspector 收起/恢复、searchable、List 键盘方向键、Space 试听、菜单快捷键、删除确认、权限拒绝、重试 |
| 证据 | 代码证据、纯函数测试、构建、人工桌面记录、授权 UI 自动化 |

- [x] **Step 3: 为每个页面建立最小状态行**

每个路由至少记录首屏任务、主动作、空态、受阻态、成功/结束态、错误/部分完成态、常用键盘入口和窗口最小可读内容。完整 VoiceOver 导航顺序不在目标范围内；对于没有该状态的页面写“not applicable — 原因”，不得留空。

- [x] **Step 4: 记录当前已知未验证项**

初始矩阵必须明确标记以下项为 unverified，而不是推断通过：

- 真机 Light/Dark 材质观感；
- Increase Contrast；
- 系统文字大小改变后的页面高度与截断；
- Reduce Motion 下全部页面的过渡；
- 所有自定义可操作控件均有基本辅助语义；完整 VoiceOver 导航顺序不作为本计划验收项；
- 1120×720 下 searchable + List、页面长内容和 Inspector 的实际桌面观感。

- [x] **Step 5: 做文档自检**

运行：

~~~bash
rg -n 'dubbing|voiceDesign|voiceClone|voiceLibrary|works|assistant|meeting|captions|teleprompter|overview|monitoring|models|diagnostics|developerDocs' docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md
git diff --check
~~~

Expected: 14 个路由标识各至少出现一次；无空白行作为未说明的验收项；diff check 无输出。

**Commit checkpoint:** 若用户之后授权提交，以 docs: add macOS UIUX audit matrix 为提交主题；本任务本身不自动提交。

## Task 2: 以 AppRoute 建立单一导航与快捷键事实源

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/AppRoute.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/App.swift:543-657
- Modify: macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift:40-55
- Modify: macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift:665 附近的页面数量说明
- Modify: macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
- Modify: docs/developers/macos-app-design-system.md
- Modify: docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md
- Test: macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift

**Interfaces:**

新增纯值契约，避免 App.swift 自己维护一份字典：

~~~swift
public struct AppRouteShortcutSpec: Hashable, Sendable {
    public enum Modifiers: String, Hashable, Sendable {
        case command
        case commandShift
    }

    public let key: String
    public let modifiers: Modifiers
}

extension AppRoute {
    public var shortcutSpec: AppRouteShortcutSpec? {
        switch self {
        case .dubbing: .init(key: "1", modifiers: .command)
        case .voiceDesign: .init(key: "2", modifiers: .command)
        case .voiceClone: .init(key: "3", modifiers: .command)
        case .voiceLibrary: .init(key: "4", modifiers: .command)
        case .works: .init(key: "5", modifiers: .command)
        case .assistant: .init(key: "6", modifiers: .command)
        case .meeting: .init(key: "7", modifiers: .command)
        case .captions: .init(key: "8", modifiers: .command)
        case .teleprompter: .init(key: "t", modifiers: .commandShift)
        case .overview: .init(key: "9", modifiers: .command)
        case .monitoring: .init(key: "0", modifiers: .command)
        case .models: .init(key: "m", modifiers: .commandShift)
        case .diagnostics: .init(key: "d", modifiers: .commandShift)
        case .developerDocs: .init(key: "h", modifiers: .commandShift)
        }
    }

    public static func routes(in group: AppRouteGroup) -> [AppRoute] {
        allCases.filter { $0.group == group }
    }
}
~~~

路由登记必须满足以下规则：

- creator、session、service 三组都由 AppRoute.allCases 的 group 派生，不再同时维护静态手写数组；
- 所有路由都有 shortcutSpec；AI 提词器使用 ⌘⇧T，避免继续存在“菜单有入口、键盘无入口”的例外；
- App.swift 只负责把 AppRouteShortcutSpec 转换为 SwiftUI KeyboardShortcut；
- ForEach(AppRoute.allCases)、侧栏分组、PageIdentityToolbarItem 和 UI 测试使用同一顺序；
- 任何路由缺少 shortcutSpec 时在 Debug 构建中通过 assertionFailure 暴露，而不是退回 ⌘1 造成快捷键冲突；
- 删除 App.swift 中“十三页”、WorkspaceComponents.swift 中“八个页面”等过时注释，并把文档页数改为“当前 14 个路由”。

- [x] **Step 1: 先写失败的导航契约测试**

在 SpeechRailAppUITests.swift 增加一个只验证可发现性的测试，沿用现有 launchSpeechRail、openControlCenter、clickWhenReady 和 identifierElement 辅助方法：

~~~swift
func testAllNavigationRoutesAreDiscoverable() {
    let app = launchSpeechRail()
    openControlCenter(in: app)

    let routeTitles = [
        "配音台", "音色创作", "音色克隆", "音色库", "我的作品",
        "语音助手", "会议助手", "实时字幕", "AI 提词器",
        "服务状态", "运行监控", "模型", "诊断", "开发者文档"
    ]

    for title in routeTitles {
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "missing route: \(title)")
    }
}
~~~

该测试属于 UI 自动化，写入测试代码可以先完成；运行它必须等当前用户逐次授权。

- [x] **Step 2: 实现 shortcutSpec 和按组派生**

在 AppRoute.swift 中为 14 个路由登记唯一快捷键，把分组数组改成 allCases.filter。不要把 KeyboardShortcut 或 EventModifiers 引入 AppRoute.swift；路由域只保存 String 和值类型修饰键枚举。

- [x] **Step 3: 让 SpeechRailCommands 消费路由契约**

删除 SpeechRailCommands.routeShortcuts 字典和 teleprompter 特判。转换函数只接受 AppRouteShortcutSpec，把 command 映射为 .command，commandShift 映射为 [.command, .shift]，并把 key 转成 KeyEquivalent。菜单项仍以 route.title 展示，动作仍调用 navigation.request(route)。

- [x] **Step 4: 让侧栏消费同一组顺序**

把 ControlCenterView 中的 AppRoute.creatorRoutes、sessionRoutes、serviceRoutes 调用分别改为 AppRoute.routes(in: .creator)、AppRoute.routes(in: .session) 和 AppRoute.routes(in: .service)，保持侧栏的三组顺序和现有系统 sidebar 样式，不添加第二套导航。

- [x] **Step 5: 更新文档中的数量和快捷键**

只修正文档中描述当前实现的旧数量和快捷键表；保留历史记录中的日期和历史判断，不把归档记录改成当前承诺。REDESIGN-SPEC 的菜单契约须包含 ⌘1–⌘0、⌘⇧T、⌘⇧M/D/H 及现有刷新、帮助和会话动作。

- [x] **Step 6: 运行不接管窗口的编译检查**

运行：

~~~bash
scripts/macos_app_build.sh --configuration Debug
swift test --package-path macos/SpeechRailApp
~~~

Expected: App Debug build succeeds；Package tests pass。UI 测试在没有当次授权时记录为 not run，不把静态构建当成 UI 可发现性通过。

- [x] **Step 7: 在获得 UI 自动化授权后运行契约测试**

运行：

~~~bash
scripts/macos_app_test.sh
~~~

2026-09-22 用户已明确授权前台 UI 自动化。最终 `SpeechRailApp` test plan 255/255 通过；`scripts/check_macos_route_contract.sh` 核对 14 个路由、快捷键、UI test entries 与矩阵 entries。

**Commit checkpoint:** 建议提交主题为 feat: centralize macOS route and shortcut contract；实际提交需用户授权。

## Task 3: 把窗口 tier 变成可测试的响应式外壳契约

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/WindowLayoutPolicy.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/AppNavigationState.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift:22-115, 402-445
- Modify: macos/SpeechRailApp/SpeechRailApp/AssistantView.swift:180-185, 3976-3998
- Modify: macos/SpeechRailApp/SpeechRailApp/MeetingView.swift:23-70, 150-165
- Modify: macos/SpeechRailApp/SpeechRailApp/SessionSurfaceViews.swift:250-330, 450-500
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/WindowLayoutPolicyTests.swift
- Test: macos/SpeechRailApp/SpeechRailMacControlTests/WindowLayoutPolicyTests.swift

**Interfaces:**

在 WindowLayoutPolicy.swift 中增加不依赖 SwiftUI/AppKit 的窗口合同：

~~~swift
public enum WindowPanelBehavior: String, Equatable, Sendable {
    case visible
    case collapsed
    case pageControlled
}

public struct WindowLayoutContract: Equatable, Sendable {
    public let sidebar: WindowPanelBehavior
    public let inspector: WindowPanelBehavior
    public let minimumPrimaryContentWidth: CGFloat
}

extension WindowLayoutPolicy {
    public static func contract(for tier: WindowLayoutTier) -> WindowLayoutContract {
        switch tier {
        case .expanded:
            WindowLayoutContract(
                sidebar: .visible,
                inspector: .pageControlled,
                minimumPrimaryContentWidth: 500
            )
        case .medium:
            WindowLayoutContract(
                sidebar: .collapsed,
                inspector: .pageControlled,
                minimumPrimaryContentWidth: 500
            )
        case .compact:
            WindowLayoutContract(
                sidebar: .collapsed,
                inspector: .collapsed,
                minimumPrimaryContentWidth: 500
            )
        }
    }
}
~~~

目标行为固定为：

| Tier | 侧栏 | Inspector | 主内容 |
|---|---|---|---|
| expanded | visible | pageControlled/默认展开 | 三列关系完整可见 |
| medium | collapsed | pageControlled | 侧栏让位给当前任务，Inspector 由页面声明是否仍有足够空间 |
| compact | collapsed | collapsed | 只保留主任务，二级面板通过明确按钮恢复 |

当前已有 1260/1340/960/1020 双阈值迟滞；执行时先保留经过代码和测试证明的阈值，只把“tier 到行为”的映射集中起来。若矩阵证明 1120×720 下仍出现裁切，先调整合同或页面最小主内容宽度，再调整阈值；不能用临时 frame 或隐藏内容掩盖问题。

- [x] **Step 1: 增加失败边界测试**

在 WindowLayoutPolicyTests.swift 增加以下边界意图：

~~~swift
func testMediumContractHidesSidebarButLeavesInspectorToPagePolicy() {
    let contract = WindowLayoutPolicy.contract(for: .medium)
    XCTAssertEqual(contract.sidebar, .collapsed)
    XCTAssertEqual(contract.inspector, .pageControlled)
}

func testCompactContractKeepsOnlyPrimaryWorkspace() {
    let contract = WindowLayoutPolicy.contract(for: .compact)
    XCTAssertEqual(contract.sidebar, .collapsed)
    XCTAssertEqual(contract.inspector, .collapsed)
}
~~~

同时补齐 1120、1260、1339、1340、960、1019、1020 等边界值，保证收窄和恢复方向一致。

- [x] **Step 2: 让 AppNavigationState 暴露合同**

保留 layoutTier 和 windowWidth，新增只读计算属性 layoutContract，其实现只能调用 WindowLayoutPolicy.contract(for: layoutTier)。AppNavigationState 不直接持有 View 或 NSWindow。

- [x] **Step 3: 让 ControlCenterView 只依据合同控制侧栏**

保留 NativeSidebarBridge 和系统 sidebar toggle；删除按 tier 重复推断行为的局部注释与分支，把收起/恢复条件改为 navigation.layoutContract.sidebar。冷启动不动画，普通调整按 Reduce Motion 决定是否动画。不要移除系统 View ▸ Hide Sidebar 的可发现路径。

- [x] **Step 4: 让会话页依据同一合同处理 Inspector**

Assistant、Meeting、SessionSurfaceViews 的自动收起逻辑分别映射到 layoutContract.inspector：

- Assistant 的 review 状态继续保持“记录列表 + 正文”两栏，不因普通 Inspector 规则被错误收起；
- Assistant ready/blocked/live 在 compact 自动收起，在 medium 由页面最小宽度决定；
- Meeting 的来源、录制和回看 Inspector 在 compact 收起，恢复按钮保留；
- 实时字幕和会话库的 Inspector 与列表键盘路径不丢失；
- 用户手动收起后，窗口拉宽不得强制恢复；只有由宽度自动收起且进入允许恢复的 tier 时才恢复。

- [x] **Step 5: 统一 Reduce Motion 行为**

在 ControlCenterView、AssistantView、MeetingView 和 SessionSurfaceViews 读取 accessibilityReduceMotion。传给 NativeSidebarBridge 的 animated 参数必须满足 !isColdStart && !reduceMotion；页面 animation、withAnimation 和 transition 在 Reduce Motion 下必须走即时分支。

- [x] **Step 6: 运行纯函数验证**

运行：

~~~bash
swift test --package-path macos/SpeechRailApp --filter WindowLayoutPolicyTests
scripts/macos_app_build.sh --configuration Debug
~~~

Expected: 纯策略测试通过，Debug 构建通过；没有运行时服务、模型或音频副作用。

- [x] **Step 7: 在授权后执行四档窗口矩阵**

启动主窗口，依次请求 1120×720、1280×800、1440×900、1920×1080；在每档进入 Assistant、Meeting、Captions、Teleprompter、Models、Diagnostics；收起/恢复侧栏和 Inspector；核对主动作 frame 在窗口范围内。测试 1/1 通过。1120×720 请求对应 1120×760 外框（标题栏额外 40pt）；1920×1080 请求按当前屏幕 visible frame 限制。searchable/List 的全路由组合另标为未覆盖。

**Commit checkpoint:** 建议提交主题为 feat: formalize responsive window contract；实际提交需用户授权。

## Task 4: 收敛共享外壳、动效与 macOS 平台语义

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift:100-230, 586-775, 1200-1340
- Modify: macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift:1-140, 330-430, 1000-1260
- Modify: macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift:70-90
- Modify: macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift
- Modify: macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
- Test: macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
- Test: scripts/macos_app_build.sh --configuration Debug

**Interfaces:**

把 PageScaffold 的多个布尔参数收敛为一个明确的布局值，避免 scrollable、minimumContentHeight、growsWithContent 组合出无法解释的高度：

~~~swift
public enum PageScaffoldLayout: Equatable, Sendable {
    case content
    case fill(minimumHeight: CGFloat)
    case scroll(minimumHeight: CGFloat)
}
~~~

PageScaffold 继续提供 route、purpose 和 trailing 动作槽；页面迁移到 layout 后，删除已无调用点的旧参数。实现必须保留 Assistant 的非 AnyView 条件分支，不能重新引入会把理想高度报成 4317pt 的类型擦除。

共享组件的可访问契约：

- PageIdentityToolbarItem 作为当前页面唯一 heading，label 包含分组和页面名；
- PageActionButton 的图标设为 accessibilityHidden，按钮 label 使用用户动作，help 说明结果；
- PageActionsMenu 的菜单项与按钮语义一致，不使用“更多操作”作为唯一名称；
- SessionPanelToggle 同时暴露 panel name、当前 expanded/collapsed value 和恢复动作；
- StatusTone、SessionStatusBar、SessionConclusionBand 的图标、文字和 accessibility value 同时表达状态，不依赖颜色；
- 自定义 hover/press/focus 样式不得吞掉系统焦点环，键盘焦点时必须有可见边界；
- 所有共享动画集中判断 Reduce Motion，页面不得再各自写不一致的弹簧参数。

- [x] **Step 1: 盘点 PageScaffold 调用点**

运行：

~~~bash
rg -n 'PageScaffold\\(|scrollable:|minimumContentHeight:|growsWithContent:' macos/SpeechRailApp/SpeechRailApp
~~~

把每个调用点归类为 content、fill 或 scroll；列表、长文稿和会话转录不得继续依靠理想高度撑开 NavigationSplitView。

- [x] **Step 2: 写出布局迁移清单并逐页替换**

先修改 WorkspaceComponents.swift 的初始化接口，再按编译错误顺序迁移 Dubbing、VoiceDesign、VoiceLibrary、Works、Assistant、Meeting、Captions、Teleprompter、Overview、Monitoring、Models、Diagnostics 和 DeveloperDocs。每次只迁移一个页面并运行 Debug build，保持类型信息，不使用 AnyView 作为迁移捷径。

- [x] **Step 3: 加入共享无障碍语义**

在共享组件中补齐 label/value/hint、heading、isButton/isHeader 等语义；页面只传入用户能理解的名称和结果，不把服务内部字段直接当 label。

- [x] **Step 4: 统一 Reduce Motion 和焦点**

将共享组件的 withAnimation、transition、symbol effect 和持续波形脉冲统一包在 Reduce Motion 分支中；增加 FocusState 或现有 FocusedValue 的明确落点，确保 Inspector 收起后焦点回到切换按钮或主内容第一个可操作元素。

- [x] **Step 5: 建立系统偏好预览变体**

为共享状态条、结论条、动作组、Inspector toggle 和页面身份增加 Debug 预览变体，至少包含：

~~~swift
#Preview("Reduce Motion") {
    PreviewSurface()
        .environment(\.accessibilityReduceMotion, true)
}

#Preview("High Contrast") {
    PreviewSurface()
        .environment(\.accessibilityContrast, .increased)
}
~~~

预览只用于语义和布局检查，不把预览渲染当成真机 VoiceOver 或桌面材质验收。

- [x] **Step 6: 编译和静态检查**

运行：

~~~bash
scripts/macos_app_build.sh --configuration Debug
rg -n 'withAnimation|\\.animation\\(|\\.transition\\(' macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift
git diff --check
~~~

Expected: 新增共享动画都有 Reduce Motion 解释；构建和 diff check 通过。

- [x] **Step 7: 验证平台语义、焦点和系统外观偏好**

按矩阵核对键盘入口、焦点可见、Inspector 恢复和基础辅助语义；抽样检查 Increase Contrast、较大文字和 Reduce Motion。完整 VoiceOver 导航顺序不属于目标用户验收，不作为阻塞项。记录具体页面和仍未验证的偏好行为。

**Commit checkpoint:** 建议提交主题为 refactor: unify macOS shared shell semantics；实际提交需用户授权。

## Task 5: 逐页收敛会话 UX 状态与主动作

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/AssistantView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/MeetingView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/SessionSurfaceViews.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift
- Read-only contract check: macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift
- Read-only contract check: macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift
- Read-only contract check: macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift
- Read-only contract check: macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift
- Modify: macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
- Test: macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationDomainTests.swift
- Test: macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPipelineTests.swift

**Interfaces:**

页面只消费已有 session domain 状态，不改变状态枚举、音频链路或记录库协议。共享状态摘要只保留 UI 实际渲染的字段；真实主动作、次要动作、恢复动作和 Inspector 行为由页面控件与验收矩阵逐状态核对，避免保存一份 UI 不消费的重复字符串：

~~~swift
struct SessionPageStatusPresentation {
    let title: String
    let tone: StatusTone
    let facts: [String]
}
~~~

动作和 Inspector 的逐状态对应关系必须在 UIUX-AUDIT-MATRIX.md 中逐项记录，并通过代表页面 UI 测试核对真实控件；不能用一个“状态正常”字符串代替状态矩阵。

目标状态和主动作：

| 页面 | 状态 | 首要用户动作 | 次要/恢复动作 |
|---|---|---|---|
| Assistant | ready | 开始对话 | 选择角色、音色、设置 |
| Assistant | blocked | 按阻断原因给唯一出口 | 去设置、重试、打开系统权限 |
| Assistant | live | 结束对话 | 静音、停止朗读、切换音色 |
| Assistant | review | 查看记录或新建对话 | 返回实时、导出、重命名、移除 |
| Meeting | idle | 开始会议 | 展开可选音频来源 |
| Meeting | preparing/recording/interrupted | 暂停/继续或结束并整理 | 静音、来源、重连 |
| Meeting | processing | 查看整理进度 | 取消或返回可解释的阻断出口 |
| Meeting | archived | 查看文字和纪要 | 导出、重命名、删除 |
| Captions | idle/preparing | 开始实时字幕 | 选择来源、打开字幕设置 |
| Captions | running/paused/ending | 暂停/继续或结束 | 打开字幕带、回到会话库 |
| Teleprompter | draft/analyzing/review | 导入/整理/审阅候选 | 新建稿、修改稿件、删除候选 |
| Teleprompter | ready/preparing/following/paused/uncertain/manual | 开始跟读或继续 | 暂停、手动提词、重新连接 |
| Teleprompter | ended | 回看或再次开始 | 导出、删除、回到稿件 |

- [x] **Step 1: 为 Assistant 固定四态主动作**

保留 ready、blocked、live、review 四态；把 statusBar、band、headerActions、inspectorTogglePanelName 和 syncInspectorWithLayoutTier 逐项对照表格。ready 不显示内部 provider 词；blocked 只给当前真正可执行的出口；review 不重复绘制已经在页头或正文出现的动作。

- [x] **Step 2: 为 Meeting 固定六个相位的可读出口**

保持 MeetingSession.Phase 的 idle、preparing、recording、interrupted、processing、archived 语义；让 statusTitle、statusFacts、blockedCard、mainArea 和 Inspector 使用同一事实来源。暂停、麦克风静音和中断必须是不同事实；处理中的“整理会议”必须有进度或明确失败出口。

- [x] **Step 3: 为 Captions 固定实时字幕动作和记录库出口**

保持 CaptionSession 的 idle、preparing、running、paused、ending；让字幕带可见性、会话记录和导出动作在页面上各有一个明确入口；列表键盘导航和当前活动会话焦点不可因 Inspector 收起丢失。

- [x] **Step 4: 为 Teleprompter 固定稿件到舞台的闭环**

沿用 TeleprompterSession 的 draft、analyzing、review、ready、preparing、following、paused、uncertain、manual、ended；把导入、候选审阅、AI 数据流确认、开始跟读、暂停、手动提词、回看和删除确认放进相同的状态优先级。不要修改 TeleprompterFollowController、TeleprompterTimingPolicy、Aligner 或音频采集协议，只调整页面表达和动作位置。

- [x] **Step 5: 统一破坏性动作和空态**

删除、移除记录、丢弃候选、重置稿件必须说明对象、后果和可取消动作；空列表必须提供一条主路径和一条安全返回路径；权限拒绝必须说明用户下一步而不是展示内部错误码。

- [x] **Step 6: 增加 lived-in preview fixture**

为四页增加最小预览数据：长标题、空列表、一条长转录、部分完成、服务不可用、麦克风拒绝、删除确认和已结束记录。fixture 只构造本地状态和文字，不读取真实音频、模型、钥匙串或服务。

- [x] **Step 7: 验证会话纯域测试和构建**

运行：

~~~bash
swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparation
scripts/macos_app_build.sh --configuration Debug
~~~

Expected: 提词器准备域测试通过；页面编译成功；不触碰 REST/Realtime/XPC/音频实现。

- [ ] **Step 8: 授权后运行会话 UI 流程**

只在当前用户授权后运行 SpeechRailAppUITests 中新旧会话流程；按 Assistant ready/blocked/review、Meeting idle/recording/archived、Captions idle/running、Teleprompter welcome/populated 四组路径记录矩阵。若真实麦克风或系统音频会改变环境，使用现有 fixture 参数，不把真实录音写入仓库。

**Commit checkpoint:** 建议按 Assistant、Meeting/Captions、Teleprompter 分成最多三个提交；建议主题分别为 feat: converge assistant session states、feat: converge meeting and caption surfaces、feat: clarify teleprompter workflow states；实际提交需用户授权。

## Task 6: 收口 Token、字体、文案和页面级散点

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/AssistantView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/MeetingView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/SettingsView.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/SettingsComponents.swift
- Modify: docs/developers/macos-app-design-system.md
- Modify: docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md
- Test: scripts/macos_app_build.sh --configuration Debug

**Interfaces:**

每个页面级视觉数值先归类为以下三种之一，再决定是否改动：

1. Token：产品会重复使用、需要跨页面一致的颜色、间距、圆角、字体、动画时长、Inspector 宽度；
2. System：交还给 macOS 的系统控件、系统文本样式、系统工具栏、List/Table 和系统焦点；
3. Structural：仅用于分隔线、波形采样、调试宿主、算法可读性的局部值，保留并在代码注释中说明。

不得为了消除一个裸值而制造一次性 Token；不得把系统默认行为复制成产品 Token。

- [x] **Step 1: 对散点值建立清单**

运行：

~~~bash
rg -n 'frame\(width:|frame\(height:|system\(size:|padding\([^)]*[0-9]|spacing: [0-9]|cornerRadius: [0-9]' macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift macos/SpeechRailApp/SpeechRailApp/AssistantView.swift macos/SpeechRailApp/SpeechRailApp/MeetingView.swift macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift macos/SpeechRailApp/SpeechRailApp/SettingsView.swift
~~~

逐项把 CreatorSurfaceViews 的 popover/sheet/列宽、Meeting 的 sheet、Settings 的窗口尺寸、Assistant 的 9pt 文字与局部 padding、SessionDesignSurface 的名称列纳入矩阵；每项在清单中标为 Token/System/Structural 和保留原因。

- [x] **Step 2: 只新增有复用价值的语义 Token**

在 SpeechRailDesignTokens.swift 中集中声明确认过的语义名称，例如 page gutter、session inspector width、editor text minimum height；页面只引用语义名，不复制裸值。当前已有未提交改动的 SpeechRailDesignTokens.swift 必须先分离 diff。

- [x] **Step 3: 统一文字样式**

面向用户的正文、说明、按钮、状态和表格数字使用现有 Typography 语义；数字使用既有等宽策略；动态字号遵循项目已记录的 macOS 事实：不假设 dynamicTypeSize 会改变系统文本墨迹，而是使用系统文本样式、合理 minHeight、按宽度截断和真机系统文字设置走查。

- [x] **Step 4: 复查用户文案**

按 PACE 逐条检查标题、按钮、空态、错误、确认框和菜单：

- Purpose：先说用户正在完成什么；
- Action：下一步按钮只表达一个动作；
- Context：状态说明给出当前事实和影响；
- Empathy：失败时说明数据是否保留、是否可重试、是否需要权限。

把内部 worker、profile、capability、source range、provider 等词移到开发者详情或必要的解释行；不要删除技术详情的可访问入口。

- [x] **Step 5: 补齐长内容和空内容预览**

预览至少覆盖 120 字标题、三行以上副标题、空音色库、空作品库、长转录、失败详情、部分完成和未授权状态。Text 使用整段保存、按可用宽度 lineLimit 和 truncation 渲染，不在数据构造阶段预截断。

- [x] **Step 6: 做 Token 和文案静态复核**

运行：

~~~bash
rg -n 'Color\.(rail|voice|canvas|field)|SpeechRailDesignTokens|Font\.custom|\.font\(\.system\(size:' macos/SpeechRailApp/SpeechRailApp
git diff --check
scripts/macos_app_build.sh --configuration Debug
~~~

Expected: 新增产品视觉值都有 Token 或 Structural 注释；用户文字没有把内部实现词作为主标题/主按钮；构建和 diff check 通过。

**Commit checkpoint:** 建议提交主题为 refactor: consolidate macOS UI tokens and copy；实际提交需用户授权。

## Task 7: 完成分层验证、文档同步和 Issue 跟踪

**Files:**

- Modify: docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md
- Create: docs/design/2026-09-15-macos-uiux-redesign/UIUX-DELIVERY-REPORT.md
- Modify: docs/developers/macos-app-design-system.md
- Modify: docs/developers/macos-app-development.md（仅在验收命令/授权边界发生实质变化时）
- Modify: docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md（仅同步当前路由/快捷键/外壳契约）
- Update externally: GitHub Issue #79
- Test: scripts/macos_app_build.sh --configuration Debug
- Test: swift test --package-path macos/SpeechRailApp
- Test: xcodebuild test plan（仅用户当次明确授权后）

**Interfaces:**

最终报告必须把每条结论归入四类之一：

- Static/code：源码、文档或结构查询直接证明；
- Unit/build：纯函数测试、Package test 或 App build 证明；
- Manual：用户在指定窗口/外观/辅助功能设置下完成桌面走查；
- Automation：用户当次授权后由 XCUITest/脚本完成。

“build 成功”“配置存在”“UI 测试启动成功”不能单独证明视觉、可访问性、模型质量、长时稳定性或服务能力。

- [x] **Step 1: 运行工作区和敏感信息检查**

运行：

~~~bash
git status --short --branch
git diff --check
git diff --name-only
~~~

确认没有覆盖第 2 节已有改动；审查 diff 不包含 API key、Authorization、原始音频、Base64、完整转写或绝对模型路径。

- [x] **Step 2: 运行非 UI 自动化验证**

运行：

~~~bash
swift test --package-path macos/SpeechRailApp
scripts/macos_app_build.sh --configuration Debug
~~~

按实际退出码填写矩阵；若构建被当前工作区已有的非本计划错误阻断，记录精确文件和错误，不修改无关文件来绕过。

- [x] **Step 3: 在用户授权后运行 App test plan**

运行：

~~~bash
xcodebuild \
  -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
  -scheme SpeechRailApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 \
  test \
  -testPlan SpeechRailApp
~~~

只在获得授权后执行；运行前说明会接管的窗口、焦点、输入和预计时长。没有授权时将 UI automation 记为未运行，不用历史绿灯代替当前证据。

2026-09-22 的首次脚本入口尝试曾在 runner 初始化阶段报 automation mode timeout（exit 65），未修改任何 TCC 权限。随后直接运行 Xcode test plan 成功：最终 `.xcresult` 记录 255 项通过、0 失败、0 跳过。一次中间全量运行暴露作品页测试仍查找旧的固定导出菜单标题；根据当前动态标题修正测试断言后，单项与全量重跑均通过。

- [x] **Step 4: 完成已授权桌面与窗口自动化矩阵**

在用户授权的桌面走查中逐项记录：

1. Light / Dark；
2. Increase Contrast；
3. Reduce Motion；
4. 系统文字大小；
5. 基本键盘与焦点语义；完整 VoiceOver 导航不在目标范围；
6. 四档窗口尺寸；
7. 14 个路由及其主流程；
8. Assistant、Meeting、Captions、Teleprompter 的状态和恢复动作；
9. 空列表、长标题、权限拒绝、服务不可用、部分完成和删除确认。

每条失败记录页面、状态、窗口、外观、动作和复现步骤；每条通过记录使用的证据类型。

2026-09-22 已完成 14 个路由首屏与四个会话 idle 页的只读走查，以及系统外观偏好代表性样本。获授权 XCUITest 后，四档请求窗口矩阵通过：验证窗口 frame、侧栏/Inspector 控件可收起恢复，并在六个代表路由核对主动作位于窗口内；1920×1080 请求按实际 visible frame 上限收敛。完整 VoiceOver 导航和 Full Keyboard Access 专项遍历不属于目标人群验收；大字号联动、全页实时状态桌面流程仍保留为非阻塞未验证项。详见 `UIUX-AUDIT-MATRIX.md`。

- [x] **Step 5: 同步 active 文档**

只把已经实施并有对应证据的内容同步到 macos-app-design-system.md 的验收清单和验证矩阵；把历史记录留在历史段，不将未验证桌面项目标记为通过。REDESIGN-SPEC 只同步 14 路由、当前快捷键和外壳行为，不把实现细节复制成第二份 Token 表。

- [x] **Step 6: 更新 GitHub Issue #79**

按阶段给 Issue 增加一个短评论，字段固定为 Scope、Completed、Verified、Remaining、Risk。评论必须使用当前阶段的真实内容；例如第一阶段完成后使用：

~~~markdown
### Phase 0 — 路由契约

- Scope: AppRoute.swift、App.swift、ControlCenterView.swift
- Completed: 14 个路由已由 AppRoute.allCases 统一驱动，快捷键和侧栏分组已核对
- Verified: code / unit / build / manual / automation
- Remaining: UI 自动化和桌面 VoiceOver 仍未运行
- Risk: 无
~~~

不在评论中粘贴密钥、原始音频、完整转写、私人路径或大段构建日志。Issue 关闭前，正文验收清单每一项都必须有矩阵证据或明确的非适用原因。

- [x] **Step 7: 形成交付报告**

报告至少包含：实际改动文件、代码证据、测试命令和退出结果、人工/自动化授权情况、未验证风险、并行改动处理、回退方式和下一阶段建议。没有证据的项写“未验证”，不写“通过”。

> 代码、Package 测试、Debug 构建、route contract、全 App Reduce Motion 静态审阅和文档同步已完成。2026-09-22 获授权 UI test plan 最终 255/255 通过；四档窗口、侧栏/Inspector 恢复和六个代表路由主动作可见性有自动化证据。全量 VoiceOver 导航按用户群体范围排除；字号联动及未执行真实采集/录音的完整 live 流程保留为非阻塞未验证项。未修改 TCC 权限；Task 7 已完成其授权范围内的验收和跟踪。

**Commit checkpoint:** 用户授权后按逻辑主题提交；不 force-push，不覆盖其他分支，不自动合并或发布。

---

## 6. 验收标准

整个优化方案只有在以下条件全部满足时才算完成：

- [ ] AppRoute 的 14 个路由在侧栏、菜单、快捷键、工具栏身份、帮助/说明、UI 测试和 active 设计文档中没有漏项或旧名称。
- [x] WindowLayoutPolicy 的 tier 合同有纯函数测试；1120×720 到 1920×1080 四档窗口矩阵验证了窗口 frame、侧栏/Inspector 收起恢复和代表页面主动作可见性；未覆盖的 searchable/List 细节单独标记。
- [x] Light、Dark、Increase Contrast、Reduce Motion、Reduce Transparency 有代码或代表性人工证据；较大系统文字偏好效果如实标为 partial。完整 VoiceOver 导航不属于目标范围。
- [ ] 创作、会话、引擎三条线至少覆盖 loading/empty/blocked/success/error/partial 的用户下一步。
- [ ] Assistant、Meeting、Captions、Teleprompter 的状态主动作和恢复动作不重复、不消失、不暴露内部实现词。
- [x] 共享组件的基本键盘入口、焦点、label/value/hint 和不依赖颜色的状态表达有代码或矩阵证据；不要求完整 VoiceOver 遍历。
- [ ] PageScaffold 不再用页面级特例叠加固定理想高度；长内容不会把 NavigationSplitView 推出可视区。
- [ ] Token、系统值和结构性常量分类完成；新增视觉值只存在于 SpeechRailDesignTokens.swift 或有明确结构性理由。
- [ ] UI 变化不触碰 REST、Realtime、MCP、XPC、音频采集、记录持久化和模型运行边界。
- [x] Swift Package tests、Debug build、route contract 和获授权 UI 自动化均有实际结果与 `.xcresult` 证据。
- [x] Issue #79 阶段评论指向本地矩阵和最终交付报告；Issue 保持打开以继续跟踪非阻塞未验证项。

## 7. 风险、回退和停止条件

### 风险

- 当前工作区已有 9 个未提交文件，且其中包含 SpeechRailDesignTokens.swift、CreatorSurfaceViews.swift 等本计划可能触及的文件；无法安全分离时必须停在文件级，不做覆盖。
- 当前代码图谱对 App.swift、AssistantView.swift 和部分会话文件存在 parse-partial，结构结论必须以源码和测试补证。
- XCUITest 会接管前台窗口、焦点和输入；没有当前用户授权时不能用它补齐证据。
- macOS 动态字号和高对比度的实际表现不能从 dynamicTypeSize 或离屏渲染直接推断，必须区分代码语义和真机走查。
- 当前最小窗口和内部页面最小宽度可能互相约束；不得仅通过提高最小窗口尺寸规避响应式问题，除非有明确产品决策和文档记录。

### 回退

- 路由契约回退：保留 AppRoute 的现有 title/group/systemImage，撤销新增 shortcutSpec 消费点；不恢复独立字典和旧数量注释。
- 响应式回退：保留已验证的 WindowLayoutPolicy 阈值和 NativeSidebarBridge，撤销新增合同映射；不删除系统 sidebar toggle。
- PageScaffold 回退：逐页回退到上一个已编译的布局调用，但不重新引入 AnyView 或固定理想高度导致的 4317pt 失败路径。
- 会话页面回退：只回退共享视觉/动作布局，不回退或改写 session domain、音频、记录和协议状态。
- 文档回退：保留静态审查结论和未验证标记，不能把旧历史文档改写为“当前通过”。

### 停止条件

遇到以下任一情况，停止当前文件写入并报告证据：

1. 发现同一文件有无法分离的并行改动；
2. 需要修改协议、XPC、音频采集、持久化或模型运行边界；
3. 需要下载模型、启停服务或处理仓库外敏感配置；
4. UI 验收需要用户未授权的前台接管；
5. 构建错误来自任务范围外且无法通过只读检查确认归属。

## 8. 执行交接

本计划已把 Issue #79 的审查结论拆成 7 个可独立验证的任务。建议执行顺序为 Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6 → Task 7；Task 1 的矩阵是后续所有“通过/未验证”判断的记录入口。

执行者开始每个任务前重新检查当前工作区，不依赖本计划生成时的未提交状态。执行过程中每完成一个阶段，就把证据类型和剩余风险同步到 UIUX-AUDIT-MATRIX.md，并在获得授权后更新 Issue #79。
