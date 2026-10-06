import AppKit
import Foundation

// MARK: - 生产实现接线
//
// `MeetingAudioSource` 的 conformance 只能待在这个 App-only 文件里：
// `AudioSourceCoordinator` 不在 SPM 目标内，协议边界用的
// `MeetingAudioSelection` 是它的无损投影。

extension AudioSourceCoordinator: MeetingAudioSource {
    /// 把协议边界的纯值选择还原成采集层自己的 `Selection`。字段一一对应，
    /// 没有丢信息——**用户勾了什么，采集层就拿什么**。
    public func start(selection meetingSelection: MeetingAudioSelection) async throws -> AsyncStream<AudioChunk> {
        try await start(
            selection: Selection(
                usesMicrophone: meetingSelection.usesMicrophone,
                systemApps: meetingSelection.systemApps.map {
                    SystemAudioApp(bundleID: $0.bundleID, name: $0.name)
                }
            )
        )
    }
}

extension AudioSourceCoordinator.Selection {
    /// 面向协议边界的无损投影。`isEmpty` 的判定在两侧一致，
    /// 所以"没选来源"不会在翻译过程中变成"选了麦克风"。
    var meetingSelection: MeetingAudioSelection {
        MeetingAudioSelection(
            usesMicrophone: usesMicrophone,
            systemApps: systemApps.map { MeetingAudioApp(bundleID: $0.bundleID, name: $0.name) }
        )
    }
}

extension MeetingSessionDependencies {
    /// 生产依赖：真实设备、真实连接、系统时钟。
    ///
    /// 放在 App-only 文件里是因为它要碰 `AudioSourceCoordinator`；
    /// 协议与值类型留在 SPM 目标内，测试才能在无设备环境下替换实现。
    public static var production: MeetingSessionDependencies {
        MeetingSessionDependencies(
            makeAudioSource: { AudioSourceCoordinator() },
            makeRealtimeClient: { configuration in
                RealtimeASRClient(
                    port: configuration.port,
                    scenePreset: configuration.scenePreset,
                    diarizationEnabled: configuration.diarizationEnabled,
                    apiKey: configuration.apiKey,
                    expectedASRRevision: configuration.expectedASRRevision
                )
            },
            powerMonitor: SystemMeetingPowerMonitor()
        )
    }
}

extension MeetingSession {
    /// App 侧的简写写法：生产依赖（真实设备、真实连接、真系统时钟、真睡眠通知）。
    ///
    /// `MeetingSession` 本体在单测目标里，而 `.production` 要碰 AppKit 的
    /// `AudioSourceCoordinator`，只能待在这个 App-only 文件——所以默认值给不了，
    /// 改由这一支便捷构造提供。测试调主构造并显式给出自己的依赖，
    /// 生产调这一支。**少一个"忘了注入依赖就静默用真设备"的口子。**
    convenience init(coordinator: SessionCoordinator, port: Int = 8201, apiKey: String? = nil) {
        self.init(
            coordinator: coordinator,
            port: port,
            apiKey: apiKey,
            dependencies: .production
        )
    }
}

/// 真的 `NSWorkspace` 睡眠通知。留在 App-only 文件里：AppKit 进不了 SPM 目标。
@MainActor
final class SystemMeetingPowerMonitor: MeetingPowerMonitor {
    func startObservingSleep(_ onSleep: @escaping @MainActor () -> Void) -> AnyObject {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onSleep() }
        }
    }
}
