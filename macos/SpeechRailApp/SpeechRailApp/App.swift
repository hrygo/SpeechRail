import SwiftUI
import SpeechRailControlKit

@main
struct SpeechRailApp: App {
    @State private var model: AppModel

    init() {
        let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
        let usesBundledXPCService = !isUITest && Self.hasBundledLocalXPCService
        let transport: any SpeechRailControlTransport = isUITest
            ? UITestControlTransport(
                profileApplyFails: ProcessInfo.processInfo.arguments.contains(
                    "--ui-test-profile-failure"
                )
            )
            : usesBundledXPCService
                ? NSXPCControlTransport(
                    bundledServiceName: ControlConstants.localXPCServiceName
                )
                : NSXPCControlTransport()
        let registration = isUITest || usesBundledXPCService ? nil : ControlAgentRegistration()
        if usesBundledXPCService {
            // A previous ad-hoc build may have left a failed SMAppService job
            // behind. Local XPC service mode owns control for this build.
            try? ControlAgentRegistration().unregister()
        }
        if let registration {
            // Refresh SMAppService only when the embedded helper changed.
            try? registration.ensureRegisteredForCurrentBundle()
        }
        _model = State(
            initialValue: AppModel(
                transport: transport,
                apiClient: ServiceAPIClient(),
                registration: registration
            )
        )
    }

    private static var hasBundledLocalXPCService: Bool {
        let serviceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices")
            .appendingPathComponent("\(ControlConstants.localXPCServiceName).xpc")
        return FileManager.default.fileExists(atPath: serviceURL.path)
    }

    var body: some Scene {
        MenuBarExtra("SpeechRail", systemImage: "waveform") {
            ControlMenuView()
                .environment(model)
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

private struct UITestControlTransport: SpeechRailControlTransport {
    private let profileApplyFails: Bool

    init(profileApplyFails: Bool = false) {
        self.profileApplyFails = profileApplyFails
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
