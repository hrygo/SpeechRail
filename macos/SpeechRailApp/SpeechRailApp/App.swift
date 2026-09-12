import SwiftUI
import SpeechRailControlKit

@main
struct SpeechRailApp: App {
    @State private var model: AppModel

    init() {
        let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
        let transport: any SpeechRailControlTransport = isUITest
            ? UITestControlTransport()
            : NSXPCControlTransport()
        let registration = isUITest ? nil : ControlAgentRegistration()
        _model = State(
            initialValue: AppModel(
                transport: transport,
                apiClient: ServiceAPIClient(),
                registration: registration
            )
        )
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
                profile: ProfileSnapshot(preset: .balanced, generation: 1, asr: "fake-asr", tts: "fake-tts")
            )
        default:
            return ControlResponse(requestID: request.requestID, command: request.command, status: .completed)
        }
    }
}
