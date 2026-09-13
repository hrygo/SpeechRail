import SwiftUI
import SpeechRailControlKit

@main
struct SpeechRailApp: App {
    @State private var model: AppModel
    @State private var navigation: AppNavigationState

    init() {
        let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
        let usesBundledXPCService = !isUITest && Self.hasBundledLocalXPCService
        let transport: any SpeechRailControlTransport = isUITest
            ? UITestControlTransport(
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
            : usesBundledXPCService
                ? NSXPCControlTransport(
                    bundledServiceName: ControlConstants.localXPCServiceName
                )
                : NSXPCControlTransport()
        let diagnosticsClient: any ServiceDiagnosticsClient = isUITest
            ? UITestServiceDiagnosticsClient(
                metricsUnavailable: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-metrics-unavailable"
                )
            )
            : ServiceAPIClient()
        let registration = isUITest || usesBundledXPCService ? nil : ControlAgentRegistration()
        _model = State(
            initialValue: AppModel(
                transport: transport,
                apiClient: diagnosticsClient,
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
        MenuBarExtra("SpeechRail", systemImage: "waveform") {
            ControlMenuView()
                .environment(model)
                .environment(navigation)
        }
        Settings {
            SettingsView()
        }
    }
}

private struct UITestServiceDiagnosticsClient: ServiceDiagnosticsClient {
    let metricsUnavailable: Bool

    var port: Int? { 8201 }

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
