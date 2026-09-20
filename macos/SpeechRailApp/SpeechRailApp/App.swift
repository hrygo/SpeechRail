import AppKit
import Foundation
import SwiftUI
import SpeechRailControlKit

@main
struct SpeechRailApp: App {
    static let helpWindowID = "speechrail-help"

    @State private var model: AppModel
    @State private var navigation: AppNavigationState
    /// 会话层的地基：所有权状态机 + 记录库（`SESSIONS-SPEC` §12 阶段 1 / 2）。
    /// 它**不随 App 启动占用任何设备**——空闲时没有麦克风、没有系统录音 tap、没有音频引擎
    /// （§5.3.1）。库里也还没有行：记录库这个库文件是懒建的。
    @State private var session: SessionCoordinator
    /// 实时字幕的会话层与浮层（`SESSIONS-SPEC` §12 阶段 3）。浮层是 App 里唯一一个 `NSPanel`。
    /// 两者都不在启动时占设备：`⌘⇧L` 或页面上的「打开字幕带」按下去才拿麦克风。
    @State private var caption: CaptionSession
    @State private var captionBand: CaptionBandWindowController
    /// 语音助手的会话层（`SESSIONS-SPEC` §12 阶段 5）：麦克风 → ASR → Responses → TTS。
    @State private var assistant: AssistantSession
    /// 会议助手的会话层（§12 阶段 6）：多路来源 → ASR → 分人 → 纪要。
    @State private var meeting: MeetingSession
    /// 全局热键（§12 阶段 8）。Carbon 路线，**不需要辅助功能授权**。
    @State private var hotKeys = GlobalHotKeyCenter()
    /// 新会话的预填值（人设 / 音色 / 对讲模式 / 分人默认值 / 大模型地址与模型）。
    /// **密钥不在这里**：它只进钥匙串。
    @State private var preferences: SessionPreferences
    /// 走内部路由与「把管理控制台调出来」时要用它。
    /// **放在 `App` 上**：全局热键的接线在 `body` 里做（见 `wireGlobalShortcuts`），
    /// 那里拿不到任何视图的环境。
    @Environment(\.openWindow) private var openWindow
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false

    init() {
        let isUITest: Bool
#if DEBUG
        isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
#else
        // Release builds must always use the live XPC/REST path, even if an
        // old UI-test launch argument is accidentally carried over.
        isUITest = false
#endif
        let usesBundledXPCService = !isUITest && Self.hasBundledLocalXPCService
        let transport: any SpeechRailControlTransport
#if DEBUG
        if isUITest {
            transport = UITestControlTransport(
                profileApplyFails: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-profile-failure"
                ),
                modelPrepareFails: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-model-failure"
                ),
                modelRecovery: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-model-recovery"
                ),
                modelUnsupported: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-model-unsupported"
                )
            )
        } else if usesBundledXPCService {
            transport = NSXPCControlTransport(
                bundledServiceName: ControlConstants.localXPCServiceName
            )
        } else {
            transport = NSXPCControlTransport()
        }
#else
        if usesBundledXPCService {
            transport = NSXPCControlTransport(
                bundledServiceName: ControlConstants.localXPCServiceName
            )
        } else {
            transport = NSXPCControlTransport()
        }
#endif
        let diagnosticsClient: any ServiceDiagnosticsClient
        let capabilityClient: any ServiceModelCapabilityClient
        let creatorClient: (any SpeechRailCreatorClient)?
#if DEBUG
        if isUITest {
            let fixtureClient = UITestServiceDiagnosticsClient(
                metricsUnavailable: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-metrics-unavailable"
                )
            )
            diagnosticsClient = fixtureClient
            capabilityClient = fixtureClient
            creatorClient = UITestCreatorClient()
        } else {
            let liveServiceClient = ServiceAPIClient()
            diagnosticsClient = liveServiceClient
            capabilityClient = liveServiceClient
            creatorClient = liveServiceClient
        }
#else
        let liveServiceClient = ServiceAPIClient()
        diagnosticsClient = liveServiceClient
        capabilityClient = liveServiceClient
        creatorClient = liveServiceClient
#endif
        let workStore: CreativeWorkStore
#if DEBUG
        // A UI fixture must never read or mutate the user's Application Support works.
        // Both populated and empty scenarios receive their own per-launch directory.
        if isUITest {
            do {
                workStore = try Self.makeUITestWorkStore(
                    empty: ProcessInfo.processInfo.arguments.contains("--ui-test-empty-works")
                )
            } catch {
                // Fail closed instead of silently falling back to real user storage.
                fatalError("Unable to initialize isolated UI test works")
            }
        } else {
            workStore = CreativeWorkStore()
        }
#else
        workStore = CreativeWorkStore()
#endif
        let registration = isUITest || usesBundledXPCService ? nil : ControlAgentRegistration()
        let appModel = AppModel(
            transport: transport,
            apiClient: diagnosticsClient,
            capabilityClient: capabilityClient,
            creatorClient: creatorClient,
            workStore: workStore,
            registration: registration
        )
        let navigationState = AppNavigationState()

        // 会话层的三个件与它们的接线。**接线放在这里**：协调器只认"开始 / 停止采集"两个钩子，
        // 不认识字幕、会议、助手各自的采集与连接（`TECHNICAL-DESIGN` §5.2）。
        let coordinator = SessionCoordinator(store: SessionStore())
        let captionSession = CaptionSession(coordinator: coordinator)
        let sessionPreferences = SessionPreferences()
        let assistantSession = AssistantSession(coordinator: coordinator)
        assistantSession.preferences = { sessionPreferences }
        assistantSession.serviceReadiness = {
            do {
                let health = try await ServiceAPIClient().fetchHealthSnapshot()
                guard health.ready == true else {
                    return .notReady("本机语音服务还没就绪。去「服务状态」启动它，再回到这里重试。")
                }
                return .ready(profile: health.profile.map(SpeechRailProfilePresentation.shortTitle))
            } catch {
                return .notReady("连不上本机语音服务。去「服务状态」看看它起来没有。")
            }
        }
        // 字幕的分人开关：档位给不出分人时接口会回 `diarization_not_available`，
        // 所以这里先按档位挡一道——**开关置灰时要说得出原因**（§14.3 的档位门禁）。
        captionSession.diarizationPreference = { sessionPreferences.captionsDiarizationEnabled }
        captionSession.diarizationGate = {
            SessionPreferences.diarizationGateNote(for: coordinator.lastKnownProfile)
        }
        assistantSession.availableVoices = { [weak appModel] in
            (appModel?.creatorVoices ?? []).filter(\.available).map(\.name)
        }
        let band = CaptionBandWindowController(
            session: captionSession,
            onOpenActiveSession: { [weak navigationState] in
                navigationState?.request(coordinator.ownershipRoute)
            }
        )
        captionSession.presentBand = { visible in
            band.setVisible(visible)
        }
        // 「就绪」要在**按下的那一刻**判定，不是读一轮缓存的健康快照：`⌘⇧L` 是全局键，
        // 按下时很可能这一轮刷新还没跑完，拿旧结论会把可用说成不可用。loopback 上一次
        // `/health` 就是毫秒级的事。
        captionSession.serviceReadiness = {
            do {
                let health = try await ServiceAPIClient().fetchHealthSnapshot()
                guard health.ready == true else {
                    return .notReady("本机语音服务还没就绪。去「服务状态」启动它，再回到这里重试。")
                }
                return .ready(profile: health.profile.map(SpeechRailProfilePresentation.shortTitle))
            } catch {
                return .notReady("连不上本机语音服务。去「服务状态」看看它起来没有。")
            }
        }
        // 会议助手的接线（§12 阶段 6）。它与字幕共用分人那条链路，差别在来源与纪要，
        // 所以这里只接三件它自己不认识的事：服务就绪判定、新会话预填值、来源断了的出口。
        let meetingSession = MeetingSession(coordinator: coordinator)
        meetingSession.preferences = { sessionPreferences }
        meetingSession.serviceReadiness = {
            do {
                let health = try await ServiceAPIClient().fetchHealthSnapshot()
                guard health.ready == true else {
                    return .notReady("本机语音服务还没就绪。去「服务状态」启动它，再回到这里重试。")
                }
                return .ready(profile: health.profile.map(SpeechRailProfilePresentation.shortTitle))
            } catch {
                return .notReady("连不上本机语音服务。去「服务状态」看看它起来没有。")
            }
        }
        coordinator.starter = { kind in
            // 未接线的能力**必须抛**：`guard … else { return }` 会被读成"已经开始采集"，
            // 于是界面显示在录、实际什么都没拿到（`CapabilityNotWired` 的注释里写了原因）。
            switch kind {
            case .captions:
                try await captionSession.beginCapture()
            case .assistant:
                try await assistantSession.beginCapture()
            case .meeting:
                try await meetingSession.beginCapture()
            }
        }
        coordinator.stopper = { kind in
            switch kind {
            case .captions:
                await captionSession.stopCapture()
            case .assistant:
                await assistantSession.stopCapture()
            case .meeting:
                await meetingSession.stopCapture()
            }
        }
        // 「结束当前会话…」（菜单栏 `⌘⇧.` / 守卫确认之后）走会议自己的收尾。
        coordinator.finisher = { kind in
            guard kind == .meeting else { return }
            await meetingSession.finishAndSummarize()
        }

        _model = State(initialValue: appModel)
        _navigation = State(initialValue: navigationState)
        _session = State(initialValue: coordinator)
        _caption = State(initialValue: captionSession)
        _assistant = State(initialValue: assistantSession)
        _meeting = State(initialValue: meetingSession)
        _preferences = State(initialValue: sessionPreferences)
        _captionBand = State(initialValue: band)
    }

#if DEBUG
    @MainActor
    private static func makeUITestWorkStore(empty: Bool) throws -> CreativeWorkStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRailUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CreativeWorkStore(directory: directory)
        if !empty {
            let work = CreativeWork(
                id: "ui-test-work", title: "测试作品", scriptText: "测试文稿。",
                voiceID: "serena", voiceName: "测试音色",
                createdAt: Date(timeIntervalSince1970: 0), durationSeconds: 3,
                audioFileName: "ui-test-work.wav"
            )
            try store.save(work, audioData: UITestAudioFactory.silentWAV)
        }
        return store
    }
#endif

    private static var hasBundledLocalXPCService: Bool {
        let serviceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices")
            .appendingPathComponent("\(ControlConstants.localXPCServiceName).xpc")
        return FileManager.default.fileExists(atPath: serviceURL.path)
    }

    /// 全局热键的接线（`SESSIONS-SPEC` §5.2、§6.6）：四个键各接一处，都只做一件事——
    /// 把请求交给协调器。「能不能开始」由占用守卫判，热键自己不做判定，
    /// 否则同一件事会有两处实现（§5.4 的同一条理由）。
    ///
    /// **为什么在 `body` 里而不是某个视图的 `.task` 里**：2026-09-18 真机跑出过一次崩溃——
    /// 这套接线原本挂在一个零尺寸的桥 View 上，而那个 View 挂在 `MenuBarExtra` 的 label 下。
    /// label 由系统单独承载，挂在其上的 `.environment(...)` 不生效，于是桥里
    /// `@Environment(SessionCoordinator.self)` 直接 `Fatal error: No Observable object ... found`。
    /// `body` 在启动时求值，且 `openWindow` 从 App 自己的环境取，所以这里既不需要视图在场，
    /// 也不依赖窗口是否打开。
    private func wireGlobalShortcuts() {
        hotKeys.setHandler(.toggleCaptions) {
            // 会议录着的时候按它：浮层以受阻态出现，给两个出口，**不开第二条会话**（§16.3）。
            Task { await caption.toggleFromGlobalShortcut() }
            reveal(.captions)
        }
        hotKeys.setHandler(.startMeeting) {
            // 会议的第一件事是**选来源**，所以热键把人送到那一页，而不替它选。
            reveal(.meeting)
        }
        hotKeys.setHandler(.finishCurrent) {
            session.requestEndCurrentSession()
            // 「结束当前会话…」带省略号：它要问一句。会议结束永远确认（防误停，§6.4），
            // 所以这里必须把窗口调出来，否则用户会看到"按了没反应"。
            openWindow(id: AppNavigationState.controlCenterWindowID)
            NSApp.activate()
        }
        hotKeys.setHandler(.toggleInnerOS) {
            guard session.occupancy?.kind == .meeting else { return }
            meeting.innerOS.isExpanded.toggle()
            reveal(.meeting)
        }
        hotKeys.install()
    }

    private func reveal(_ route: AppRoute) {
        navigation.request(route)
        openWindow(id: AppNavigationState.controlCenterWindowID)
        NSApp.activate()
    }

    var body: some Scene {
        // `body` 在启动时求值一次；`let _ =` 是 SceneBuilder 里唯一能放语句的位置。
        let _ = wireGlobalShortcuts()
        Window("SpeechRail 管理控制台", id: AppNavigationState.controlCenterWindowID) {
            ControlCenterView()
                .environment(model)
                .environment(navigation)
                .environment(session)
                .environment(caption)
                .environment(assistant)
                .environment(meeting)
                .environment(preferences)
                .task {
                    await session.openStore()
                    // 启动时回收：① 上次没正常结束的会话已经封存（`openStore` 里做）；
                    // ② 卡在 `queued` / 租约过期的纪要在这里重新排一次（§5.8）。
                    await meeting.minutes.recoverPending(
                        configuration: preferences.minutesConfiguration
                    )
                    await model.refreshCreatorVoices()
                }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SpeechRailCommands(
                navigation: navigation,
                session: session,
                caption: caption,
                showDeveloperDetails: $showDeveloperDetails
            )
        }
        MenuBarExtra {
            ControlMenuView()
                .environment(model)
                .environment(navigation)
                .environment(session)
                .environment(caption)
                .environment(meeting)
        } label: {
            // 状态项要的四个对象**显式传进去**，不走环境：`MenuBarExtra` 的 label 由系统
            // 单独承载，挂在上面的 `.environment(...)` 不生效（2026-09-18 真机崩溃就是它）。
            MenuBarStatusLabel(
                isOperating: model.serviceOperation?.phase.isActive == true,
                session: session,
                caption: caption,
                meeting: meeting,
                assistant: assistant
            )
        }
        Settings {
            SettingsView()
                .environment(model)
                .environment(preferences)
        }
        Window("SpeechRail 帮助", id: Self.helpWindowID) {
            SpeechRailHelpView()
        }
        .windowResizability(.contentSize)
    }
}

/// 全局热键 → 动作的接线（`SESSIONS-SPEC` §5.2、§6.6）。
///
/// 它是一个**零尺寸的桥**：`App` 这个结构体里拿不到 `openWindow` 这类环境值，
/// 而热键只在按下的那一刻才用到它们。接线放在这里，四个键各接一处，
/// 而且都只做一件事——**把请求交给协调器**：「能不能开始」由占用守卫判，
/// 热键自己不做判定，否则同一件事会有两处实现（§5.4 的同一条理由）。
///
/// **接线在 `App.body` 里做，不挂在任何视图上**（`SpeechRailApp.wireGlobalShortcuts()`）：
/// `body` 在启动时就会求值，四个键因此不需要任何窗口或视图在场；反过来，挂到视图上会让
/// 「窗口被关掉」变成「热键静默失效」。`install()` 与 `setHandler` 都是幂等的。

/// The menu bar and keyboard map from REDESIGN-SPEC §6.3. Focused scene values
/// let「导出选中作品」follow the page the user is actually looking at.
struct SpeechRailCommands: Commands {
    /// 路由 → 快捷键。十三页超出 ⌘1–⌘0 的十个槽位，所以让位规则被显式写在表里
    /// （SESSIONS-SPEC §5.2，用户 2026-09-18 裁决 D2）：**创作页一个都不动**（它们频率最高，
    /// 而且已形成肌肉记忆），**会话组拿中间三格** ⌘6–⌘8，**引擎页改用助记组合**。
    private static let routeShortcuts: [AppRoute: (key: KeyEquivalent, modifiers: EventModifiers)] = [
        .dubbing: ("1", .command),
        .voiceDesign: ("2", .command),
        .voiceClone: ("3", .command),
        .voiceLibrary: ("4", .command),
        .works: ("5", .command),
        .assistant: ("6", .command),
        .meeting: ("7", .command),
        .captions: ("8", .command),
        .overview: ("9", .command),
        .monitoring: ("0", .command),
        .models: ("m", [.command, .shift]),
        .diagnostics: ("d", [.command, .shift]),
        .developerDocs: ("h", [.command, .shift])
    ]

    let navigation: AppNavigationState
    /// 会话命令要用它判「有没有正在进行的会话」（`⌘⇧.` 会话进行中才可用）。
    let session: SessionCoordinator
    /// 字幕带的全局入口（`⌘⇧L`）。它**不需要 App 在前台**——菜单命令本来就在系统这一侧。
    let caption: CaptionSession
    @Binding var showDeveloperDetails: Bool
    @FocusedValue(\.selectedWorkCommand) private var selectedWorkCommand
    @FocusedValue(\.reloadPageCommand) private var reloadPageCommand
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建配音文稿") {
                navigation.request(.dubbing)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(exportTitle) {
                selectedWorkCommand?()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(selectedWorkCommand == nil)
        }

        CommandGroup(after: .sidebar) {
            // 「重新读取当前页」由当前页面自己声明（`reloadPageCommand`），
            // 所以八个页面不再各写一条含义不同的「刷新…」菜单项（§6.2 / §6.3）。
            Button(reloadPageCommand?.title ?? "重新读取") {
                reloadPageCommand?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(reloadPageCommand == nil)

            Divider()

            Toggle("显示开发者详情", isOn: $showDeveloperDetails)
                .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandGroup(after: .toolbar) {
            Divider()
            ForEach(AppRoute.allCases, id: \.self) { route in
                Button(route.title) {
                    navigation.request(route)
                }
                .keyboardShortcut(Self.shortcut(for: route))
            }

            Divider()

            // 会话动作。**只放今天真的会生效的**：字幕带（阶段 3 已落地）与会话结束；
            // 会议的开始动作随阶段 6 落地，现在给一条按了不动的菜单项比不给更糟。
            Button(caption.phase.isLive ? "暂停实时字幕" : "开始实时字幕") {
                Task { await caption.toggleFromGlobalShortcut() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("结束当前会话") {
                session.requestEndCurrentSession()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!session.phase.isActive)
        }

        CommandGroup(replacing: .help) {
            Button("SpeechRail 帮助") {
                openWindow(id: SpeechRailApp.helpWindowID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }

    private var exportTitle: String {
        guard let selectedWorkCommand else { return "导出选中作品…" }
        return "导出“\(selectedWorkCommand.title)”…"
    }

    /// 表里必须覆盖每一条路由；缺一条就退回 ⌘1，这会与「配音台」撞键——
    /// 所以缺项要当成缺陷来修，而不是靠这里的兜底悄悄过去。
    private static func shortcut(for route: AppRoute) -> KeyboardShortcut {
        guard let entry = routeShortcuts[route] else {
            assertionFailure("路由 \(route.rawValue) 没有登记快捷键")
            return KeyboardShortcut("1", modifiers: .command)
        }
        return KeyboardShortcut(entry.key, modifiers: entry.modifiers)
    }
}

#if DEBUG
private struct UITestServiceDiagnosticsClient:
    ServiceDiagnosticsClient,
    ServiceModelCapabilityClient
{
    let metricsUnavailable: Bool

    var port: Int? { 8201 }

    /// 与下面的健康快照一致：fixture 档位是 quality，VoiceDesign 与 Base 两个
    /// capability 都在。能力结论读这里，不读音色列表。
    func fetchModelCapabilities() async throws -> ServiceModelCapabilities {
        ServiceModelCapabilities(
            supportsPreview: true,
            supportsClone: true,
            supportsInstruction: true
        )
    }

    func fetchHealthSnapshot() async throws -> HealthSnapshot {
        HealthSnapshot(
            status: "ok",
            service: "speechrail",
            version: "fixture",
            backend: "fake-asr",
            profile: .quality,
            asrReady: true,
            ttsReady: true,
            ttsWarm: true,
            diarizationReady: true,
            diarization: DiarizationStatusSnapshot(
                configured: true,
                ready: true,
                message: "fixture ready",
                profile: "quality"
            ),
            asrState: "active",
            ttsState: "active",
            ttsLifecycle: TTSCapabilityLifecycleSnapshot(
                warmCapability: "both",
                warmCapabilities: ["voice_design", "voice_clone"]
            ),
            streamingState: "active",
            realtimeVAD: RealtimeVADStatusSnapshot(
                configuredEngine: "auto",
                resolvedEngine: "fixture",
                speechAdmissionEnabled: true,
                ready: true,
                message: "fixture ready"
            ),
            ready: true,
            jobSpoolReady: false
        )
    }

    func fetchMetrics() async throws -> RuntimeMetricsSnapshot {
        if metricsUnavailable {
            throw ServiceAPIClientError.requestFailed
        }
        return RuntimeMetricsSnapshot(
            activeRequests: RuntimeRequestCounts(realtime: 1, batch: 0),
            pendingRequests: RuntimeRequestCounts(realtime: 0, batch: 1),
            workers: ["asr": "active", "tts": "warm_standby"],
            health: ["asr": true, "tts": true],
            counters: ["speechrail_http_requests_total": 12],
            histograms: [
                "speechrail_asr_inference_duration_seconds": [
                    "all": RuntimeHistogramSummary(count: 4, sum: 1.2, average: 0.3),
                ],
                "speechrail_tts_inference_duration_seconds": [
                    "all": RuntimeHistogramSummary(count: 2, sum: 0.8, average: 0.4),
                ],
            ]
        )
    }
}

/// Deterministic creator transport for UI tests. It exercises the same AppModel
/// state transitions as the live REST client while keeping tests offline and
/// free of user audio or model assets.
private struct UITestCreatorClient: SpeechRailCreatorClient {
    private let store: UITestVoiceStore

    init(store: UITestVoiceStore = UITestVoiceStore()) {
        self.store = store
    }

    func fetchVoices() async throws -> [CreatorVoice] {
        await store.list()
    }

    func fetchVoice(id: String) async throws -> CreatorVoice {
        guard let voice = await store.get(id: id) else {
            throw ServiceAPIClientError.http(
                statusCode: 404,
                code: "voice_not_found",
                message: "voice not found",
                requestID: nil,
                retryable: false
            )
        }
        return voice
    }

    func createSpeech(text: String, voiceID: String, speed: Double) async throws -> Data {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-slow-voice-preview") {
            try await Task.sleep(for: .seconds(5))
        }
        return UITestAudioFactory.silentWAV
    }

    func createVoicePreview(
        text: String,
        instruction: String,
        speed: Double,
        seed: Int?
    ) async throws -> Data {
        UITestAudioFactory.silentWAV
    }

    func registerVoiceDesign(
        id: String,
        name: String,
        instruction: String,
        referenceText: String,
        seed: Int
    ) async throws -> CreatorVoice {
        let voice = CreatorVoice(
            id: id,
            name: name,
            description: instruction,
            instruction: instruction,
            seed: seed,
            isSystem: false,
            createdAt: 0,
            available: true,
            variant: "custom_voice",
            mode: "clone",
            refText: referenceText,
            durationSeconds: 3
        )
        return await store.insert(voice)
    }

    func fetchClonePrompts() async throws -> [ClonePrompt] {
        [
            ClonePrompt(
                id: "fixture_poetry",
                category: "classic",
                title: "盛唐气象 · 经典诗韵",
                script: "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。",
                tips: "字正腔圆，声调平稳从容，注意句尾自然停顿。"
            ),
            ClonePrompt(
                id: "fixture_tech",
                category: "tech",
                title: "科技浪潮 · 现代叙述",
                script: "人工智能正在深刻改变我们的交互方式，让每一次人机对话都充满温度与智慧。",
                tips: "语速适中，吐字清脆明快，保持自然表达状态。"
            )
        ]
    }

    func validateVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?
    ) async throws -> VoiceQualityReportSnapshot {
        VoiceQualityReportSnapshot(
            policyVersion: "voice_quality_v1",
            status: .pass,
            failureCodes: [],
            reference: VoiceQualityReportSnapshot.Reference(
                durationSeconds: 11,
                sampleRate: 24_000,
                speechActiveRatio: 0.82,
                noiseFloorDecibels: -58,
                estimatedSNRDecibels: 24,
                clippingRatio: 0,
                transcriptMatch: 0.96
            )
        )
    }

    func registerVoiceClone(
        audio: Data,
        referenceText: String,
        name: String,
        voiceID: String?,
        idempotencyKey: String?
    ) async throws -> CreatorVoice {
        let voice = CreatorVoice(
            id: voiceID ?? "voice_clone_fixture",
            name: name,
            description: "参考录音注册的音色",
            isSystem: false,
            createdAt: 0,
            available: true,
            variant: "base",
            mode: "clone",
            refText: referenceText,
            durationSeconds: 11
        )
        return await store.insert(voice)
    }

    func updateVoice(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?
    ) async throws -> CreatorVoice {
        guard let voice = await store.update(
            id: id,
            name: name,
            instruction: instruction,
            seed: seed
        ) else {
            throw ServiceAPIClientError.requestFailed
        }
        return voice
    }

    func deleteVoice(id: String) async throws {
        await store.delete(id: id)
    }
}

private actor UITestVoiceStore {
    private var voices: [CreatorVoice] = [
        CreatorVoice(
            id: "fixture_voice_design",
            name: "夜航主持",
            description: "用于 UI 验收的 VoiceDesign 系统音色",
            instruction: "温暖、清晰、亲近",
            seed: 101,
            isDefault: true,
            isSystem: true,
            createdAt: 0,
            available: true,
            variant: "voice_design",
            capabilities: CreatorVoiceCapabilities(supportsInstruction: true),
            mode: "instruction"
        ),
        CreatorVoice(
            id: "fixture_custom_voice",
            name: "测试自定义音色",
            description: "用于 UI 验收的自定义音色",
            instruction: "自然、稳定",
            seed: 202,
            isSystem: false,
            createdAt: 0,
            available: true,
            variant: "custom_voice",
            mode: "instruction"
        ),
    ]

    func list() -> [CreatorVoice] {
        voices
    }

    func get(id: String) -> CreatorVoice? {
        voices.first { $0.id == id }
    }

    func insert(_ voice: CreatorVoice) -> CreatorVoice {
        voices.append(voice)
        return voice
    }

    func update(
        id: String,
        name: String?,
        instruction: String?,
        seed: Int?
    ) -> CreatorVoice? {
        guard let index = voices.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let current = voices[index]
        let updated = CreatorVoice(
            id: current.id,
            name: name ?? current.name,
            description: current.description,
            instruction: instruction ?? current.instruction,
            seed: seed ?? current.seed,
            aliases: current.aliases,
            isDefault: current.isDefault,
            isSystem: current.isSystem,
            createdAt: current.createdAt,
            available: current.available,
            variant: current.variant,
            capabilities: current.capabilities,
            mode: current.mode,
            refText: current.refText,
            durationSeconds: current.durationSeconds
        )
        voices[index] = updated
        return updated
    }

    func delete(id: String) {
        voices.removeAll { $0.id == id }
    }
}

private enum UITestAudioFactory {
    static let silentWAV: Data = {
        let sampleRate: UInt32 = 16_000
        let frameCount: UInt32 = sampleRate * 3
        let dataSize = frameCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(36 + dataSize, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(sampleRate * 2, to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }()

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private actor UITestOperationState {
    private var modelStatusPolls = 0

    func nextModelStatus(
        request: ControlRequest,
        fails: Bool
    ) -> ControlResponse {
        modelStatusPolls += 1
        let isTerminal = fails || modelStatusPolls >= 2
        let state: OperationState = if isTerminal {
            fails ? .failed : .committed
        } else {
            .running
        }
        let status: ControlResponseStatus = if isTerminal {
            fails ? .failed : .committed
        } else {
            .running
        }
        let errorCode: ControlErrorCode? = fails ? .integrityMismatch : nil
        let message = fails ? "model preparation failed" : nil
        let progress = OperationProgressSnapshot(
            artifactKey: "fake-asr",
            file: "fixture.bin",
            completedBytes: isTerminal ? 128 : 64,
            expectedBytes: 128
        )
        return ControlResponse(
            requestID: request.requestID,
            command: .operationStatus,
            status: status,
            errorCode: errorCode,
            message: message,
            operation: OperationSnapshot(
                operationID: request.operationID ?? "ui-test-model-prepare",
                command: .modelPrepare,
                state: state,
                phase: isTerminal ? (fails ? "failed" : "committed") : "download",
                progress: progress,
                errorCode: errorCode,
                message: message
            )
        )
    }
}

private struct UITestControlTransport: SpeechRailControlTransport {
    private let profileApplyFails: Bool
    private let modelPrepareFails: Bool
    private let modelRecovery: Bool
    private let modelUnsupported: Bool
    private let operationState: UITestOperationState

    init(
        profileApplyFails: Bool = false,
        modelPrepareFails: Bool = false,
        modelRecovery: Bool = false,
        modelUnsupported: Bool = false,
        operationState: UITestOperationState = UITestOperationState()
    ) {
        self.profileApplyFails = profileApplyFails
        self.modelPrepareFails = modelPrepareFails
        self.modelRecovery = modelRecovery
        self.modelUnsupported = modelUnsupported
        self.operationState = operationState
    }

    func send(_ request: ControlRequest) async throws -> ControlResponse {
        switch request.command {
        case .profileList:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .ok,
                profiles: SpeechRailProfile.allCases.map {
                    ProfileSummary(id: $0, asr: "fake-asr", tts: "fake-tts", downloadBytes: 0)
                }
            )
        case .profileStatus:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .ok,
                profile: ProfileSnapshot(preset: .quality, generation: 1, asr: "fake-asr", tts: "fake-tts")
            )
        case .modelCatalog:
            if modelUnsupported {
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .failed,
                    errorCode: .unsupported,
                    message: "模型管理暂不可用：服务组件版本不匹配"
                )
            }
            let artifact = ModelArtifactSnapshot(
                key: "fake-asr",
                modelID: "fixture/fake-asr",
                family: "qwen3_asr",
                variant: "asr",
                revision: String(repeating: "a", count: 40),
                provider: "fixture",
                repository: "fixture/fake-asr",
                quantization: ModelQuantizationSnapshot(bits: 8, groupSize: 64, format: "fixture"),
                sizeBytes: 0,
                fileCount: 1,
                requiredBy: [.quality, .balanced, .light]
            )
            let profiles = SpeechRailProfile.allCases.map {
                ProfileSummary(
                    id: $0,
                    asr: "fake-asr",
                    tts: "fake-tts",
                    diarization: $0 != .light,
                    downloadBytes: 0
                )
            }
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .ok,
                modelCatalog: ModelCatalogSnapshot(artifacts: [artifact], profiles: profiles)
            )
        case .modelStatus:
            if modelUnsupported {
                return ControlResponse(
                    requestID: request.requestID,
                    command: request.command,
                    status: .failed,
                    errorCode: .unsupported,
                    message: "模型管理暂不可用：服务组件版本不匹配"
                )
            }
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .ok,
                modelStatus: ModelStatusSnapshot(
                    artifacts: [
                        ModelArtifactStatusSnapshot(
                            key: "fake-asr",
                            state: .verified,
                            integrity: .verified,
                            verifiedFileCount: 1,
                            totalFileCount: 1
                        )
                    ],
                    disk: ModelDiskSnapshot(modelBytes: 0, freeBytes: 0),
                    activeOperation: modelRecovery
                        ? OperationSnapshot(
                            operationID: "ui-test-recovered-model",
                            command: .modelPrepare,
                            profile: .quality,
                            state: .interrupted,
                            phase: "download",
                            progress: OperationProgressSnapshot(
                                artifactKey: "fake-asr",
                                file: "fixture.bin",
                                completedBytes: 64,
                                expectedBytes: 128
                            ),
                            message: "previous model preparation was interrupted; retry is required"
                        )
                        : nil
                )
            )
        case .preflight:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .ok,
                checks: [
                    PreflightCheckSnapshot(name: "fake runtime", ok: true, message: "fixture ready")
                ]
            )
        case .modelPrepare:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .accepted,
                operation: OperationSnapshot(
                    operationID: "ui-test-model-prepare",
                    command: .modelPrepare,
                    state: .accepted,
                    phase: "accepted"
                )
            )
        case .operationStatus where request.operationID == "ui-test-model-prepare":
            return await operationState.nextModelStatus(
                request: request,
                fails: modelPrepareFails
            )
        case .profileApply where profileApplyFails:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .accepted,
                operation: OperationSnapshot(
                    operationID: "ui-test-profile-apply",
                    command: .profileApply,
                    state: .accepted,
                    phase: "accepted"
                )
            )
        case .operationStatus where profileApplyFails:
            return ControlResponse(
                requestID: request.requestID,
                command: request.command,
                status: .failed,
                errorCode: .commandFailed,
                message: "profile preparation failed",
                operation: OperationSnapshot(
                    operationID: request.operationID ?? "ui-test-profile-apply",
                    command: .profileApply,
                    state: .failed,
                    phase: "failed",
                    errorCode: .commandFailed,
                    message: "profile preparation failed"
                )
            )
        default:
            return ControlResponse(requestID: request.requestID, command: request.command, status: .completed)
        }
    }
}
#endif
