import Foundation
import SwiftUI
import SpeechRailControlKit

@main
struct SpeechRailApp: App {
    static let helpWindowID = "speechrail-help"

    @State private var model: AppModel
    @State private var navigation: AppNavigationState
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
        let registration = isUITest || usesBundledXPCService ? nil : ControlAgentRegistration()
        _model = State(
            initialValue: AppModel(
                transport: transport,
                apiClient: diagnosticsClient,
                capabilityClient: capabilityClient,
                creatorClient: creatorClient,
                registration: registration
            )
        )
        _navigation = State(initialValue: AppNavigationState())
    }

    private static var hasBundledLocalXPCService: Bool {
        let serviceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices")
            .appendingPathComponent("\(ControlConstants.localXPCServiceName).xpc")
        return FileManager.default.fileExists(atPath: serviceURL.path)
    }

    var body: some Scene {
        Window("SpeechRail 管理控制台", id: AppNavigationState.controlCenterWindowID) {
            ControlCenterView()
                .environment(model)
                .environment(navigation)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SpeechRailCommands(
                navigation: navigation,
                showDeveloperDetails: $showDeveloperDetails
            )
        }
        MenuBarExtra {
            ControlMenuView()
                .environment(model)
                .environment(navigation)
        } label: {
            MenuBarStatusLabel(isOperating: model.serviceOperation?.phase.isActive == true)
        }
        Settings {
            SettingsView()
                .environment(model)
        }
        Window("SpeechRail 帮助", id: Self.helpWindowID) {
            SpeechRailHelpView()
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar and keyboard map from REDESIGN-SPEC §6.3. Focused scene values
/// let「导出选中作品」follow the page the user is actually looking at.
struct SpeechRailCommands: Commands {
    /// ⌘1–⌘9 的显示顺序与 `AppRoute.allCases` 一致（创作五页 + 引擎五页）。
    /// 第十页「开发者文档」是 ⌘0：它排不进 1–9 的自然顺序，而给参考页一个
    /// 记不住的组合键（⌘⇧D 之类）比给最后一个序位更糟（REDESIGN-SPEC §13.3）。
    private static let routeShortcuts: [KeyEquivalent] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"
    ]

    let navigation: AppNavigationState
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
            ForEach(Array(AppRoute.allCases.enumerated()), id: \.element) { index, route in
                Button(route.title) {
                    navigation.request(route)
                }
                .keyboardShortcut(
                    Self.routeShortcuts[index % Self.routeShortcuts.count],
                    modifiers: .command
                )
            }
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
            throw ServiceAPIClientError.server(
                code: "voice_not_found",
                message: "voice not found",
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
