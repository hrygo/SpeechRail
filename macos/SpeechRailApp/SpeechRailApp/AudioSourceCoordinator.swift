import AppKit
import AVFoundation
import Foundation

// 音频来源的唯一入口（`TECHNICAL-DESIGN` §5.4）：**获取 / 释放与来源选择都在这里**，
// 于是"按功能启用、功能离开即释放"（用户裁决 R4）只有一个落点，不会三页各写一遍。
//
// 它不做的事：不做 endpointing、不碰文本、不碰播放音量。那些归服务端与各自的会话。
//
// 来源模型（product spec §14.1 / §21.1）：
//   麦克风（单选） + 若干个本机 App（每个 App 各占一路）。勾选多个时**机内自动合流**——
//   「混音」是行为，不是用户要选的第三个选项。`session.audio_source` 仍然是三选一，
//   它描述的是"这一次选的采集来源"，不是流的条数。
//
// 合流的口径（§3.4）：两路各自带自己的节奏，缺一块就**补静音并记一笔缺口**，
// 而不是把两路硬拼成一条听起来连续、实际上错位的流。

/// 用 `AudioSourceCoordinator` 选一路本机音频时的描述。
public struct SystemAudioApp: Identifiable, Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public var id: String { bundleID }
}

/// 候选 App 列表：现在正在跑、且说得清名字的普通 App。
///
/// 这只是**候选**，不是"正在出声的 App"：后者系统没有公开接口。用户勾谁就抓谁，
/// 勾一个没在出声的 App 的后果是那一路全是静音——比"我们猜错了它"要好。
public enum SystemAudioAppCatalog {
    public static func runningApps(excluding ownBundleID: String?) -> [SystemAudioApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard
                    let bundleID = application.bundleIdentifier,
                    bundleID != ownBundleID,
                    !bundleID.hasPrefix("com.speechrail.")
                else { return nil }
                return SystemAudioApp(
                    bundleID: bundleID,
                    name: application.localizedName ?? bundleID
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
@Observable
public final class AudioSourceCoordinator {
    public struct Selection: Sendable, Equatable {
        public var usesMicrophone: Bool
        public var systemApps: [SystemAudioApp]

        public init(usesMicrophone: Bool = true, systemApps: [SystemAudioApp] = []) {
            self.usesMicrophone = usesMicrophone
            self.systemApps = systemApps
        }

        public var isEmpty: Bool { !usesMicrophone && systemApps.isEmpty }

        /// 落库的 `session.audio_source`：它描述"这一次选的采集来源"（§6.3 ③ 的注解）。
        public var resolvedSource: SessionAudioSource {
            switch (usesMicrophone, systemApps.isEmpty) {
            case (true, true): .microphone
            case (false, false): .system
            default: .mixed
            }
        }

        /// 界面上那句话（`麦克风` / `腾讯会议` / `麦克风 + 2 个 App`）。
        public var label: String {
            var parts: [String] = []
            if usesMicrophone { parts.append("麦克风") }
            if systemApps.count == 1, let app = systemApps.first {
                parts.append(app.name)
            } else if systemApps.count > 1 {
                parts.append("\(systemApps.count) 个 App")
            }
            return parts.isEmpty ? "没有来源" : parts.joined(separator: " + ")
        }
    }

    // MARK: 状态

    /// 真实电平（0…1）。合流时取混完之后的那一个。
    public private(set) var level: Double = 0
    /// 这一场有多少块是补的静音（来源没跟上）。它**不是错误**，是一条如实的事实。
    public private(set) var gapCount = 0
    public private(set) var activeSelection: Selection?
    /// 本机音频这一路**自己停下**的原因，没有就是 `nil`。
    public private(set) var systemAudioStopReason: String?

    private var microphone: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var mixer: StreamMixer?
    private let microphoneSlotID = UUID(), systemSlotID = UUID()
    private var observerTask: Task<Void, Never>?
    private var systemSourceGeneration = UUID()
    private var captureGeneration = UUID()
    private var currentSource: SessionAudioSource = .microphone
    /// 麦克风这一路被用户静音了没有（会中「我暂时不说」）。
    ///
    /// 它与启停**不是**同一件事：静音时设备与采集流照旧开着（`AGENTS.md` 那条"按功能启用、
    /// 离开释放"讲的是设备归属，静音的人还在会话里），所以它只影响这一路往下送什么。
    public private(set) var isMicrophoneMuted = false
    /// 正在**主动**收尾。它区分"我们让它停"与"它自己断了"——只有后者才是 `source_lost`。
    private var isTearingDown = false

    /// 本机音频那一路自己断了（来源 App 退出）。唯一的自动接回入口挂在它上面（§5.6）。
    public var onSystemAudioLost: (@MainActor (String) -> Void)?

    public init() {}

    /// 这一场选的来源（`session.audio_source` 的取值）。
    public var resolvedSource: SessionAudioSource { currentSource }

    /// 开始采集。**所有设备都在这一步拿**；任何一路失败都抛出去，调用方不提交会话、
    /// 不建记录（§3.5「宁可没开始，也不要一条空记录」）。
    ///
    /// 只有一路来源时**不经过混音器**：直接把它那条流交出去，少一层缓冲、少 40 ms 延迟。
    public func start(selection: Selection) async throws -> AudioChunkStream {
        await stop()
        guard !selection.isEmpty else { throw Blocked(reason: .noSourceSelected) }
        isTearingDown = false
        let generation = UUID(); captureGeneration = generation

        var streams: [(sourceID: UUID, stream: AudioChunkStream)] = []

        if selection.usesMicrophone {
            let capture = MicrophoneCapture()
            microphone = capture
            do {
                streams.append((microphoneSlotID, gate(microphone: try await capture.start())))
                guard generation == captureGeneration, !isTearingDown else { throw CancellationError() }
            } catch {
                await capture.stop()
                if microphone === capture { microphone = nil }
                if error is CancellationError { throw error }
                throw Blocked(reason: Self.blockReason(forMicrophone: error))
            }
        }

        if !selection.systemApps.isEmpty {
            let capture = SystemAudioCapture(
                selection: .init(
                    bundleIDs: selection.systemApps.map(\.bundleID),
                    label: selection.systemApps.map(\.name).joined(separator: "、")
                )
            )
            system = capture
            do {
                streams.append((systemSlotID, watch(system: try await capture.start())))
                guard generation == captureGeneration, !isTearingDown else { throw CancellationError() }
            } catch {
                await capture.stop()
                if error is CancellationError { throw error }
                // 本机音频起不来 = 受阻（**不静默降级**成只录麦克风）：用户明确勾了它，
                // 只录一半还说得像成功，比明确拒绝更糟（§9 第 4 / 19 行）。
                await release()
                throw Blocked(reason: .systemAudioUnavailable(error.localizedDescription))
            }
        }

        guard generation == captureGeneration, !isTearingDown else { throw CancellationError() }
        activeSelection = selection
        currentSource = selection.resolvedSource
        systemAudioStopReason = nil
        gapCount = 0
        level = 0
        // 新的一场从"能说话"开始：上一场留在闸门上的状态不跟过来（最小意外）。
        isMicrophoneMuted = false

        // 只有**麦克风**这一条路时才直通：它不需要热插拔。
        // 一旦选了本机音频，即使只有它一路，也走混音器——因为来源 App 退出之后要能**换上新的那一路**，
        // 而直通的那条流没有换人的位置（§5.6 的"唯一自动接回"）。
        guard streams.count > 1 || !selection.systemApps.isEmpty else {
            let only = streams[0].stream
            return only
        }

        let mixer = StreamMixer()
        self.mixer = mixer
        let mixed = await mixer.start()
        guard generation == captureGeneration, !isTearingDown else { await mixer.stop(); throw CancellationError() }
        for source in streams {
            try await mixer.attach(sourceID: source.sourceID, stream: source.stream)
            guard generation == captureGeneration, !isTearingDown else { await mixer.stop(); throw CancellationError() }
        }
        observe(mixer)
        return mixed
    }

    /// 来源 App 退出之后把本机音频换一路新的，**不动麦克风、不动会话**。
    ///
    /// 返回是否接上。接不上就由调用方记一条中断——那是唯一会自动接回的一类，
    /// 但"自动接回"不等于"一定接得上"（§9 第 9 行）。
    @discardableResult
    public func restartSystemAudio() async -> Bool {
        guard let selection = activeSelection, !selection.systemApps.isEmpty else { return false }
        let generation = captureGeneration
        systemSourceGeneration = UUID()
        await mixer?.retire(sourceID: systemSlotID)
        await system?.stop()
        system = nil
        let capture = SystemAudioCapture(
            selection: .init(
                bundleIDs: selection.systemApps.map(\.bundleID),
                label: selection.systemApps.map(\.name).joined(separator: "、")
            )
        )
        do {
            let stream = watch(system: try await capture.start())
            guard generation == captureGeneration, !isTearingDown else { await capture.stop(); return false }
            system = capture
            systemAudioStopReason = nil
            if let mixer {
                try await mixer.attach(sourceID: systemSlotID, stream: stream)
            }
            return true
        } catch {
            systemAudioStopReason = error.localizedDescription
            return false
        }
    }

    /// 停止采集并释放**全部**设备。幂等。
    public func stop() async {
        captureGeneration = UUID()
        isTearingDown = true
        if let system { systemAudioStopReason = system.stopReason }
        await release()
        level = 0
        activeSelection = nil
        isMicrophoneMuted = false
    }

    /// 静音 / 取消静音麦克风这一路。只有选了麦克风时才有效果（调用点负责判断）。
    public func setMicrophoneMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
    }

    /// 麦克风静音闸：静音时把每一块换成**等长静音**再往下走。
    ///
    /// 为什么不是把块丢掉：混音器按 40 ms 栅格合流，某一路这一格没有样本时它会补静音
    /// **并记一笔缺口**（`gapCount`），状态带上就会出现「N 处补过静音」——那是给真断源
    /// （来源 App 退出、设备被拔）准备的事实。用静音表达"我主动不说"才不算撒谎；
    /// 块长不变，所以下游的栅格、时间轴与分人链路都不需要知道这件事。
    ///
    /// 电平一并归零：静音时状态带上的电平柱应当落下去，而不是继续显示"房间里很吵"。
    private func gate(microphone stream: AudioChunkStream) -> AudioChunkStream {
        stream.mapChunks { [weak self] chunk in
            await self?.isMicrophoneMuted == true ? chunk.muted() : chunk
        }
    }

    private func watch(system stream: AudioChunkStream) -> AudioChunkStream {
        let generation = systemSourceGeneration
        return stream.observingCompletion { [weak self] termination in
            await self?.systemStreamEnded(termination, generation: generation)
        }
    }

    private func systemStreamEnded(_ termination: AudioStreamTermination, generation: UUID) {
        guard generation == systemSourceGeneration, termination != .cancelled,
              !isTearingDown, activeSelection != nil else { return }
        let defaultReason: String
        switch termination {
        case .staleInput: defaultReason = "音频等待时间过长。"
        case .droppedSamples: defaultReason = "音频传输有缺失。"
        default: defaultReason = "来源 App 退出了。"
        }
        let reason = system?.stopReason ?? defaultReason
        systemAudioStopReason = reason
        onSystemAudioLost?(reason)
    }

    private func release() async {
        let observer = observerTask; observerTask = nil
        observer?.cancel(); await observer?.value
        await microphone?.stop()
        microphone = nil
        await system?.stop()
        system = nil
        await mixer?.stop(drainPending: true)
        mixer = nil
    }

    /// 把混音器的缺口计数与电平搬回主线程状态（界面上要显示的那两个数）。
    private func observe(_ mixer: StreamMixer) {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard self.mixer === mixer else { return }
                let snapshot = await mixer.snapshot()
                self.level = snapshot.level
                self.gapCount = snapshot.gaps
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private static func blockReason(forMicrophone error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        return .engineFailed(error.localizedDescription)
    }
}

// 受阻原因与错误类型的嵌套别名。定义本体在 `MeetingAudioBlockReason.swift`
// （SPM 目标内），这里只保留原路径，让这个文件之外的既有调用点一行不用改。
// 别名而不是子类：这两者是**值语义**的纯数据，掺进继承只会让"同一种受阻"
// 有两个类型，`error as?` 也就不再成立。
extension AudioSourceCoordinator {
    public typealias BlockReason = MeetingAudioBlockReason
    public typealias Blocked = MeetingAudioBlocked
}
