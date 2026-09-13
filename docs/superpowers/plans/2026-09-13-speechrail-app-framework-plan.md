# SpeechRail macOS App 整体框架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 SpeechRail macOS App 上建立原生管理控制中心的整体窗口、导航、菜单栏入口和音色创作一级框架，让普通用户和开发者在同一套信息架构中获得清晰的功能定位、当前状态与下一步动作。

**Architecture:** App scene 层负责 `WindowGroup(id: "control-center")`、`MenuBarExtra` 和独立 `Settings` 的职责分离；控制中心使用 `NavigationSplitView`，把“创作”和“服务”作为两个一级分组。创作页面先提供保留原设计语义的可用框架，服务路由在本计划中建立可导航的功能定位与状态承载层，真实 health、metrics、模型和 operation 数据由服务模块计划接入。

**Tech Stack:** Swift 6、SwiftUI、Observation、macOS 14.0 SDK、XCTest/XCUITest、现有 `SpeechRailControlKit`、现有 `AppModel` 与 Xcode project。

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md`

## Global Constraints

- 原生控制面 deployment target 为 macOS 14.0，运行目标为单人 Apple Silicon Mac。
- SpeechRail App 是控制面，不采集麦克风、不播放音频、不加载模型、不直接执行 `launchctl`；运行态动作继续经受约束的 XPC control agent 委托现有 managed Python CLI。
- 使用独立管理控制中心、保留音色创作一级区域和独立 `Settings`；`Settings` 只承载应用偏好，不承载运行监控或模型下载。
- 控制中心使用 `NavigationSplitView`；一级导航固定包含“配音台”“音色创作”“音色库”“我的作品”“总览”“运行监控”“模型管理”“预检与诊断”。
- 默认显示面向普通用户的解释层，开发者证据通过“技术详情”渐进式展开，不设置割裂的普通用户/开发者模式。
- 使用系统窗口背景、`systemBlue` 强调色、原生控件、动态字体、深色模式、VoiceOver 标签和减少动态效果；状态不能只依赖颜色。
- 不显示 API key、`Authorization`、绝对模型路径、完整日志、原始音频、完整转写、prompt、Base64 或实名 speaker。
- 真实服务、真实模型、真实音频和网络下载不进入普通 UI test；UI test 使用 fake transport 和 fake diagnostics。
- 保留当前工作树中不属于本计划的用户改动；实现前先核对 `git status --short`，只修改本计划列出的文件和必要的 Xcode target membership。

---

## 1. 交付边界与依赖

本计划只负责 App 的整体框架、创作区骨架、窗口/菜单栏/Settings 分工和可访问导航。服务控制命令、模型状态与下载、health/metrics 解码、运行监控数据采样、真实服务页面由 `2026-09-13-speechrail-service-module-plan.md` 负责。

本计划消费现有 `AppModel` 的兼容入口：`service`、`profiles`、`profile`、`operation`、`message`、`isBusy`、`refresh()` 和 `execute(_:profile:)`。服务模块计划会在不破坏这些入口的前提下增加详细状态。

## 2. 文件地图

### 新增文件

- `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`：固定的创作/服务路由、标题、图标和功能分组元数据。
- `macos/SpeechRailApp/SpeechRailApp/AppNavigationState.swift`：跨 scene 的安全路由请求状态，用于菜单栏跳转到控制中心或音色创作。
- `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`：页面统一的功能定位、用途和下一步说明组件。
- `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`：`NavigationSplitView` 控制中心窗口和路由分发。
- `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`：配音台、音色创作、音色库和我的作品的保留框架。
- `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`：服务模块真实数据接入前的诚实状态承载视图，不伪造运行数据。

### 修改文件

- `macos/SpeechRailApp/SpeechRailApp/App.swift`：注册控制中心 scene，并向所有相关 scene 注入导航状态。
- `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`：增加打开控制中心、跳转音色创作和回到 Settings 的菜单入口。
- `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`：改为只包含应用偏好，不再承载服务 mutation 或 profile 切换。
- `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`：将新增 Swift 文件加入 App target 和对应测试 target 的 source phase。
- `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`：验证 scene、侧栏、创作入口、服务入口和菜单栏跳转。
- `docs/developers/macos-app-development.md`：补充控制中心 scene、导航路由和测试入口的开发说明。

服务模块计划后续会修改 `ControlCenterView.swift`、`SurfaceHeaderView.swift`、`ControlMenuView.swift` 和 UI tests，因此执行顺序应为先完成本计划，再执行服务模块计划。

## 3. 实施任务

### Task 1: 建立固定路由与跨 scene 导航状态

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/AppNavigationState.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- Produces `AppRoute`, `AppRouteGroup` 和 `AppNavigationState`，供控制中心、菜单栏和 UI test 使用。
- `AppRoute` 的 raw value 固定为 `dubbing-desk`、`voice-design`、`voice-library`、`works`、`overview`、`monitoring`、`models`、`diagnostics`。
- `AppNavigationState` 暴露 `public private(set) var requestedRoute: AppRoute` 和 `public func request(_ route: AppRoute)`；初始路由为 `.overview`。

- [ ] **Step 1: 先写路由元数据的 UI 失败测试**

在现有 UI test 中增加控制中心导航断言，测试依赖后续 scene 的 accessibility identifier：

```swift
func testControlCenterContainsCreatorAndServiceRoutes() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test"]
    app.launch()
    app.activate()

    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    let openControlCenter = statusItem.menus.firstMatch.menuItems["打开管理控制台"]
    XCTAssertTrue(openControlCenter.waitForExistence(timeout: 2))
    openControlCenter.click()

    XCTAssertTrue(app.otherElements["control-center-window"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["创作"].exists)
    XCTAssertTrue(app.staticTexts["服务"].exists)
    XCTAssertTrue(app.buttons["app-route-voice-design"].exists)
    XCTAssertTrue(app.buttons["app-route-monitoring"].exists)
}
```

- [ ] **Step 2: 运行失败测试确认缺失点**

运行：

```bash
scripts/macos_app_test.sh
```

预期：失败在菜单项 `打开管理控制台` 或 `control-center-window` 不存在；这是 scene 和路由尚未建立的预期红灯。

- [ ] **Step 3: 写入路由和导航状态的最小实现**

`AppRoute.swift` 使用下面的稳定接口，不在 View 中散落字符串：

```swift
import Foundation

public enum AppRouteGroup: String, CaseIterable, Hashable, Sendable {
    case creator
    case service

    public var title: String {
        switch self {
        case .creator: "创作"
        case .service: "服务"
        }
    }
}

public enum AppRoute: String, CaseIterable, Hashable, Sendable {
    case dubbingDesk = "dubbing-desk"
    case voiceDesign = "voice-design"
    case voiceLibrary = "voice-library"
    case works
    case overview
    case monitoring
    case models
    case diagnostics

    public var group: AppRouteGroup {
        switch self {
        case .dubbingDesk, .voiceDesign, .voiceLibrary, .works: .creator
        case .overview, .monitoring, .models, .diagnostics: .service
        }
    }

    public var title: String {
        switch self {
        case .dubbingDesk: "配音台"
        case .voiceDesign: "音色创作"
        case .voiceLibrary: "音色库"
        case .works: "我的作品"
        case .overview: "总览"
        case .monitoring: "运行监控"
        case .models: "模型管理"
        case .diagnostics: "预检与诊断"
        }
    }

    public var systemImage: String {
        switch self {
        case .dubbingDesk: "text.quote"
        case .voiceDesign: "waveform.badge.plus"
        case .voiceLibrary: "music.note.list"
        case .works: "folder"
        case .overview: "gauge.with.dots.needle.67percent"
        case .monitoring: "chart.xyaxis.line"
        case .models: "shippingbox"
        case .diagnostics: "stethoscope"
        }
    }

    public var purpose: String {
        switch self {
        case .dubbingDesk: "用文本、角色和音色组织配音任务。"
        case .voiceDesign: "用描述生成、试听和保存音色候选。"
        case .voiceLibrary: "管理已保存、已绑定和可复用的音色。"
        case .works: "查看生成结果、版本和导出记录。"
        case .overview: "让 SpeechRail 在这台 Mac 上准备好。"
        case .monitoring: "确认本机语音服务最近是否稳定。"
        case .models: "准备本地语音能力所需的模型制品。"
        case .diagnostics: "定位服务、runtime 和能力准备问题。"
        }
    }
}
```

`AppNavigationState.swift` 只负责路由请求，不持有窗口、XPC 或 URLSession：

```swift
import Observation

@MainActor
@Observable
public final class AppNavigationState {
    public static let controlCenterWindowID = "control-center"
    public private(set) var requestedRoute: AppRoute = .overview

    public init() {}

    public func request(_ route: AppRoute) {
        requestedRoute = route
    }
}
```

- [ ] **Step 4: 编译并确认路由类型可被 App target 使用**

运行：

```bash
scripts/macos_app_build.sh --configuration Debug
```

预期：若 Xcode project 尚未加入新文件，先得到明确的 target membership 错误；下一任务会补齐 project 引用。不要通过把文件复制到 build 目录来绕过 target membership。

- [ ] **Step 5: 提交路由基础**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AppRoute.swift macos/SpeechRailApp/SpeechRailApp/AppNavigationState.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat: add SpeechRail app route model"
```

### Task 2: 建立控制中心窗口、统一页面说明和音色创作框架

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift:3-29`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift:1-100`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- Produces `SurfaceHeaderView(title:purpose:nextAction:)`，所有一级页面都先说明定位、用途和下一步。
- Produces `ControlCenterView`，读取 `AppModel`、`AppNavigationState`，不直接持有 `URLSession`、`Process`、文件句柄或 XPC 连接。
- Produces `CreatorRouteView(route:)`，完整覆盖四个创作路由；创作框架使用本地临时输入状态，不宣称已经完成真实生成、保存或导出。
- `ServiceRoutePreviewView(route:)` 只展示功能定位和“正在读取服务能力”类诚实状态；服务数据接入后由服务模块计划替换对应分支。

- [ ] **Step 1: 增加页面说明和路由选择失败测试**

在 UI test 中加入以下断言，确保每个页面不是只有标题：

```swift
func testEachTopLevelRouteExplainsItsPurpose() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test"]
    app.launch()
    app.activate()

    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    statusItem.menus.firstMatch.menuItems["打开管理控制台"].click()
    XCTAssertTrue(app.otherElements["control-center-window"].waitForExistence(timeout: 5))

    let routes = [
        ("app-route-dubbing-desk", "配音台"),
        ("app-route-voice-design", "音色创作"),
        ("app-route-voice-library", "音色库"),
        ("app-route-works", "我的作品"),
        ("app-route-overview", "总览"),
        ("app-route-monitoring", "运行监控"),
        ("app-route-models", "模型管理"),
        ("app-route-diagnostics", "预检与诊断"),
    ]
    for (identifier, title) in routes {
        let route = app.buttons[identifier]
        XCTAssertTrue(route.waitForExistence(timeout: 2), "missing route \(title)")
        route.click()
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertTrue(app.staticTexts["功能定位"].exists)
        XCTAssertTrue(app.staticTexts["下一步"].exists)
    }
}
```

- [ ] **Step 2: 运行测试确认控制中心和页面尚不存在**

运行：

```bash
scripts/macos_app_test.sh
```

预期：失败在控制中心 scene、侧栏 route identifier 或“功能定位”文本不存在。

- [ ] **Step 3: 实现统一页面说明组件**

`SurfaceHeaderView.swift` 使用固定的可访问层级和说明文案：

```swift
import SwiftUI
import SpeechRailControlKit

public struct SurfaceHeaderView: View {
    public let title: String
    public let purpose: String
    public let nextAction: String

    public init(title: String, purpose: String, nextAction: String) {
        self.title = title
        self.purpose = purpose
        self.nextAction = nextAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text("功能定位").font(.headline)
            Text(purpose).foregroundStyle(.secondary)
            Text("下一步").font(.headline)
            Text(nextAction).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

public struct ServiceStatusFooterView: View {
    public let snapshot: ServiceSnapshot

    public init(snapshot: ServiceSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        Label(
            snapshot.ready == true ? "语音服务可用" : "语音服务状态未知",
            systemImage: snapshot.ready == true ? "checkmark.circle.fill" : "questionmark.circle"
        )
        .font(.caption)
        .foregroundStyle(snapshot.ready == true ? .green : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel("语音服务：\(snapshot.serviceState)")
    }
}
```

- [ ] **Step 4: 实现控制中心导航和创作页面**

`ControlCenterView.swift` 的核心结构固定为：

```swift
import SwiftUI

public struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var selection: AppRoute?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("创作") {
                    routeButton(.dubbingDesk)
                    routeButton(.voiceDesign)
                    routeButton(.voiceLibrary)
                    routeButton(.works)
                }
                Section("服务") {
                    routeButton(.overview)
                    routeButton(.monitoring)
                    routeButton(.models)
                    routeButton(.diagnostics)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                ServiceStatusFooterView(snapshot: model.service)
            }
        } detail: {
            detailView(for: selection ?? .overview)
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            selection = navigation.requestedRoute
        }
        .onChange(of: navigation.requestedRoute) { _, route in
            selection = route
        }
        .task {
            await model.refresh()
        }
        .accessibilityIdentifier("control-center-window")
    }

    @ViewBuilder
    private func routeButton(_ route: AppRoute) -> some View {
        Button {
            selection = route
            navigation.request(route)
        } label: {
            Label(route.title, systemImage: route.systemImage)
        }
        .buttonStyle(.plain)
            .accessibilityIdentifier("app-route-\(route.rawValue)")
    }

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route.group {
        case .creator:
            CreatorRouteView(route: route)
        case .service:
            if route == .overview {
                VStack(alignment: .leading, spacing: 20) {
                    SurfaceHeaderView(
                        title: route.title,
                        purpose: route.purpose,
                        nextAction: "查看服务脉冲，确认语音能力是否可用。"
                    )
                    ServiceStatusView()
                    ProfilePickerView()
                }
                .padding(32)
            } else {
                ServiceRoutePreviewView(route: route)
            }
        }
    }
}
```

`CreatorSurfaceViews.swift` 必须保留四个一级语义：

- `dubbingDesk`：文本编辑区、角色/音色选择区、生成前依赖说明；没有服务就绪时禁用生成动作并说明原因。
- `voiceDesign`：音色描述输入、候选列表、试听和保存/绑定的框架；试听和保存按钮只有在真实能力接入后才启用，不用 fake 音频冒充成功。
- `voiceLibrary`：已保存音色、绑定状态和空状态入口；不读取模型目录替代音色库。
- `works`：作品列表、版本和导出入口；不把 operation 日志当成作品。

`CreatorRouteView` 使用明确的 route switch，确保新增 route 不会静默落到错误页面：

```swift
public struct CreatorRouteView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        Group {
            switch route {
            case .dubbingDesk: DubbingDeskView()
            case .voiceDesign: VoiceDesignView()
            case .voiceLibrary: VoiceLibraryView()
            case .works: WorksView()
            case .overview, .monitoring, .models, .diagnostics:
                ContentUnavailableView("请选择创作页面", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .accessibilityIdentifier("creator-\(route.rawValue)")
    }
}
```

四个创作页面在本计划中使用以下最小可用框架；它们不保存文件、不播放音频，也不伪造生成成功：

```swift
public struct DubbingDeskView: View {
    @State private var script = ""
    @State private var role = "旁白"
    @State private var voice = "默认音色"

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceHeaderView(
                title: "配音台",
                purpose: "用文本、角色和音色组织配音任务。",
                nextAction: "输入一段文本，选择角色和音色后检查服务状态。"
            )
            TextEditor(text: $script)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("配音文本")
            HStack {
                Picker("角色", selection: $role) {
                    Text("旁白").tag("旁白")
                    Text("角色 A").tag("角色 A")
                }
                Picker("音色", selection: $voice) {
                    Text("默认音色").tag("默认音色")
                    Text("我的音色").tag("我的音色")
                }
            }
            Button("生成配音") {}
                .disabled(true)
            Text("语音服务连接完成后，这里会显示生成和导出操作。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

public struct VoiceDesignView: View {
    @State private var description = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceHeaderView(
                title: "音色创作",
                purpose: "用描述生成、试听和保存音色候选。",
                nextAction: "写下希望的音色特征，再检查 VoiceDesign 模型是否已准备。"
            )
            TextField("例如：温暖、清晰、适合纪录片旁白", text: $description)
            GroupBox("音色候选") {
                ContentUnavailableView(
                    "还没有候选",
                    systemImage: "waveform.badge.plus",
                    description: Text("服务可用后，生成的候选会出现在这里。")
                )
            }
            HStack {
                Button("生成音色候选") {}
                    .disabled(true)
                Button("保存并绑定") {}
                    .disabled(true)
            }
        }
        .padding(32)
    }
}

public struct VoiceLibraryView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceHeaderView(
                title: "音色库",
                purpose: "管理已保存、已绑定和可复用的音色。",
                nextAction: "选择一个音色查看绑定关系；已有音色不受服务状态变化影响。"
            )
            ContentUnavailableView(
                "还没有保存的音色",
                systemImage: "music.note.list",
                description: Text("完成一次音色创作后，保存的音色会显示在这里。")
            )
        }
        .padding(32)
    }
}

public struct WorksView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceHeaderView(
                title: "我的作品",
                purpose: "查看生成结果、版本和导出记录。",
                nextAction: "完成一次配音后，在这里查看作品版本和导出状态。"
            )
            ContentUnavailableView(
                "还没有作品",
                systemImage: "folder",
                description: Text("服务 operation 和运行日志不会被当作作品。")
            )
        }
        .padding(32)
    }
}
```

每个具体创作页面顶部使用 `SurfaceHeaderView`；所有“尚未接入真实生成”“服务依赖未就绪”等状态都写在解释层，技术细节放在 `DisclosureGroup("技术详情")` 中。

`ServiceRoutePreviewView` 使用相同的说明结构，明确告诉用户服务数据尚未读取：

```swift
public struct ServiceRoutePreviewView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SurfaceHeaderView(
                title: route.title,
                purpose: route.purpose,
                nextAction: "等待服务模块数据连接后查看详细状态。"
            )
            ContentUnavailableView(
                "服务数据尚未读取",
                systemImage: route.systemImage,
                description: Text("此页面不会虚构请求、模型容量或健康结果。")
            )
        }
        .padding(32)
        .accessibilityIdentifier("service-\(route.rawValue)")
    }
}
```

`ServiceRoutePreviewView.swift` 对 `.monitoring`、`.models`、`.diagnostics` 展示对应定位、用途、下一步和“服务数据尚未读取”的状态，不展示 0 请求、虚构百分比或虚假的模型容量。服务模块计划完成后删除这个阶段性分支并由真实页面接管。

- [ ] **Step 5: 将现有服务状态组件接入新页面框架**

保留 `ServiceStatusView`、`ProfilePickerView` 的现有 `AppModel` 调用方式，给服务按钮和 profile 控件增加稳定 accessibility identifier；本任务不改变 XPC command 或模型下载协议。状态文本同时包含图标、文字和可访问标签，服务 mutation 的最终确认文案由服务模块计划统一收口。

- [ ] **Step 6: 运行 UI 测试确认导航和创作框架通过**

运行：

```bash
scripts/macos_app_test.sh
```

预期：控制中心可打开，八个 route 均可选择；每个页面都出现“功能定位”和“下一步”；创作区不触发真实网络、音频或模型加载。

- [ ] **Step 7: 提交控制中心和创作框架**

```bash
git add macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat: add SpeechRail control center shell"
```

### Task 3: 分离 App scene、菜单栏高频入口与 Settings 偏好

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift:5-57`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift:1-31`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift:1-18`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `SpeechRailApp` 注入同一个 `AppModel` 和同一个 `AppNavigationState` 到 `MenuBarExtra`、`WindowGroup` 和需要服务状态的页面。
- `AppNavigationState.controlCenterWindowID` 是唯一窗口 ID；菜单栏不创建第二个服务实例。
- `SettingsView` 不再调用 `model.refresh()`、`model.execute()` 或 profile API，只使用 `@AppStorage` 保存本地 UI 偏好。

- [ ] **Step 1: 先写 Settings 和菜单栏职责失败测试**

```swift
func testSettingsDoesNotOwnRuntimeMutations() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test"]
    app.launch()
    app.activate()

    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    statusItem.menus.firstMatch.menuItems["打开设置"].click()

    XCTAssertTrue(app.staticTexts["应用偏好"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["启动服务"].exists)
    XCTAssertFalse(app.buttons["停止服务"].exists)
    XCTAssertFalse(app.buttons["应用档位"].exists)
}
```

- [ ] **Step 2: 运行测试确认当前 Settings 仍包含服务操作**

运行：

```bash
scripts/macos_app_test.sh
```

预期：新断言失败，因为当前 `SettingsView` 仍展示 `ServiceStatusView` 和 `ProfilePickerView`。

- [ ] **Step 3: 注册控制中心 scene 和共享导航状态**

在 `App.swift` 中保持现有 XPC/UITest transport 初始化逻辑，仅扩展 scene：

```swift
@main
struct SpeechRailApp: App {
    @State private var model: AppModel
    @State private var navigation = AppNavigationState()

    var body: some Scene {
        MenuBarExtra("SpeechRail", systemImage: "waveform") {
            ControlMenuView()
                .environment(model)
                .environment(navigation)
        }
        WindowGroup("SpeechRail 管理控制台", id: AppNavigationState.controlCenterWindowID) {
            ControlCenterView()
                .environment(model)
                .environment(navigation)
        }
        Settings {
            SettingsView()
        }
    }
}
```

不要在 `WindowGroup` 内新建 `AppModel`、`ServiceAPIClient`、XPC transport 或 managed service；窗口关闭只影响 UI，不停止运行中的服务。

- [ ] **Step 4: 更新菜单栏和 Settings**

`ControlMenuView` 增加 `@Environment(\.openWindow)` 和 `@Environment(AppNavigationState.self)`，保留服务状态快照与启动/停止入口，并提供以下菜单项：

```swift
Button("打开管理控制台") {
    navigation.request(.overview)
    openWindow(id: AppNavigationState.controlCenterWindowID)
}

Button("打开音色创作") {
    navigation.request(.voiceDesign)
    openWindow(id: AppNavigationState.controlCenterWindowID)
}

Button("打开设置") {
    openSettings()
}
```

`SettingsView` 改为 `Form`，至少提供“应用偏好”“菜单栏显示服务状态”“打开控制中心时默认显示总览”两个本地偏好；不出现服务启停、重启、profile 应用或模型下载按钮。偏好只影响界面，不修改 `SPEECHRAIL_*` 配置和服务运行态。

- [ ] **Step 5: 运行菜单栏、scene 和 Settings 测试**

运行：

```bash
scripts/macos_app_test.sh
```

预期：菜单栏能够打开独立控制中心、跳转到“音色创作”，Settings 只显示偏好；打开或关闭控制中心不会改变 fake service 的运行态。

- [ ] **Step 6: 提交 scene 职责分离**

```bash
git add macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift macos/SpeechRailApp/SpeechRailApp/SettingsView.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat: separate SpeechRail app scenes"
```

### Task 4: 接入 Xcode target、无障碍校验和开发文档

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj:9-224`
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`
- Modify: `docs/developers/macos-app-development.md`

**Interfaces:**
- App target 的 source phase 必须包含 `AppRoute.swift`、`AppNavigationState.swift`、`SurfaceHeaderView.swift`、`ControlCenterView.swift`、`CreatorSurfaceViews.swift` 和 `ServiceRoutePreviewView.swift`。
- UI test target 继续以 `SpeechRailApp` 为 host，不嵌入真实 runtime、模型或音频。
- 文档描述当前 scene、XPC 边界、路由 ID、UI test fake 和构建命令，不写入本机绝对 runtime 路径或凭据。

- [ ] **Step 1: 先检查 project 中 source phase 和 target membership**

运行：

```bash
rtk rg -n "App Sources|UI Test Sources|ControlCenterView.swift|CreatorSurfaceViews.swift" macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj
```

预期：新文件尚未出现在 project；确认现有内嵌 local XPC service 的 Debug/Release 与 Distribution 条件不被改动。

- [ ] **Step 2: 写入 file reference、build file 和 source phase**

为每个新 Swift 文件增加一个 `PBXFileReference`、一个 `PBXBuildFile`，将 file reference 放入 `SpeechRailApp` group，将 build file 放入 `App Sources`。不要把 App UI 文件加入 `SpeechRailControlKit`、`SpeechRailControlAgentCore` 或 Agent target，也不要修改现有 XPC embed shell phase。

- [ ] **Step 3: 增加 UI test 的可访问性回归覆盖**

在现有 `SpeechRailAppUITests.swift` 保留 profile apply 失败测试的服务语义，并新增以下测试集合：

```swift
private func launchSpeechRail(arguments: [String] = ["--ui-test"]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    app.activate()
    return app
}

private func openControlCenter(_ app: XCUIApplication) {
    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    let item = statusItem.menus.firstMatch.menuItems["打开管理控制台"]
    XCTAssertTrue(item.waitForExistence(timeout: 2))
    item.click()
    XCTAssertTrue(app.otherElements["control-center-window"].waitForExistence(timeout: 5))
}

func testMenuBarCanJumpToVoiceDesign() {
    let app = launchSpeechRail()
    let statusItem = app.menuBars.statusItems.firstMatch
    statusItem.click()
    statusItem.menus.firstMatch.menuItems["打开音色创作"].click()
    XCTAssertTrue(app.otherElements["creator-voice-design"].waitForExistence(timeout: 5))
}

func testControlCenterShowsAllServiceEntries() {
    let app = launchSpeechRail()
    openControlCenter(app)
    for identifier in ["app-route-overview", "app-route-monitoring", "app-route-models", "app-route-diagnostics"] {
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 2))
    }
}

func testSettingsOnlyShowsPreferences() {
    let app = launchSpeechRail()
    let statusItem = app.menuBars.statusItems.firstMatch
    statusItem.click()
    statusItem.menus.firstMatch.menuItems["打开设置"].click()
    XCTAssertTrue(app.staticTexts["应用偏好"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["启动服务"].exists)
    XCTAssertFalse(app.buttons["停止服务"].exists)
    XCTAssertFalse(app.buttons["应用档位"].exists)
}
```

实现时用真实的 XCTest 断言和现有 `waitForExistence(timeout:)`，不使用固定坐标、合成键盘快捷键或真实网络。

- [ ] **Step 4: 运行构建、UI test 和 plist 检查**

运行：

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

预期：Debug App 构建通过，UI test 全部通过，LaunchAgent plist 输出 `OK`。若失败涉及当前并行的 XPC 改动，只记录具体文件和错误，不回退或覆盖并行改动。

- [ ] **Step 5: 更新开发文档**

在 `docs/developers/macos-app-development.md` 增加“控制中心与 scene 职责”小节，明确：

1. `WindowGroup(id: "control-center")` 承载创作区和服务区；
2. `MenuBarExtra` 只承载状态快照和高频入口；
3. `Settings` 只承载 UI 偏好；
4. App 不直接加载模型、读取模型目录、采集音频或执行 `launchctl`；
5. 服务模块计划负责将阶段性服务 route 接到 health、metrics、XPC operation 和模型命令。

- [ ] **Step 6: 提交整体框架**

```bash
git add macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift docs/developers/macos-app-development.md
git commit -m "docs: document SpeechRail app framework"
```

## 4. 计划完成验收

完成本计划后，未接入服务数据的页面也必须是诚实、可导航和可访问的：

- 菜单栏可以打开控制中心并跳转到音色创作；
- 控制中心侧栏同时显示创作和服务两个一级分组；
- 四个创作路由均保留原产品语义，未用服务管理页面替换音色创作；
- Settings 不再承载服务运行态 mutation；
- 每个页面都能回答“这是做什么的”和“下一步是什么”；
- 没有虚构模型容量、运行指标、质量分数或音频生成成功状态；
- Debug 构建、UI test 和 plist 检查通过。

最终的管理控制台、运行监控、模型管理和预检真实功能验收必须在服务模块计划完成后执行，不能把本计划的阶段性服务 route 视为服务模块已经完成。

## 5. 回退与交接

- 回退只需按任务 commit 顺序恢复 App UI commit；不触碰 Python managed runtime、模型目录、profile selection、LaunchAgent 或 XPC 服务文件。
- 服务模块计划使用本计划产出的 `AppRoute`、`AppNavigationState`、`SurfaceHeaderView` 和 `ControlCenterView`，将 `ServiceRoutePreviewView` 的对应分支替换为真实页面。
- 若服务模块命令或 Agent 版本不兼容，控制中心保留导航并显示 `unsupported` 的解释层，不把不完整响应解释成“正常”。
