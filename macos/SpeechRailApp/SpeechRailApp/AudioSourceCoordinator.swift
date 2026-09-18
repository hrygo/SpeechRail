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

    /// 受阻的原因。**一律给可读结论 + 一个出口**（§6.4 的同一套结论条）。
    public enum BlockReason: Equatable, Sendable {
        case noSourceSelected
        case microphoneDenied
        case systemAudioUnavailable(String)
        case engineFailed(String)

        public var title: String {
            switch self {
            case .noSourceSelected: "还没有选声音从哪来"
            case .microphoneDenied: "麦克风未授权"
            case .systemAudioUnavailable: "本机音频拿不到"
            case .engineFailed: "音频没有开始"
            }
        }

        public var detail: String {
            switch self {
            case .noSourceSelected:
                "这场会要录什么？选「麦克风」（屋里的人）、或勾上一个正在放声音的 App"
                    + "（线上的会、正在播的音乐）。两个都选就会自动合到一起。"
            case .microphoneDenied:
                "在系统设置里允许 SpeechRail 使用麦克风，然后回来重试。"
            case .systemAudioUnavailable(let message):
                "\(message)系统第一次会问一次录音权限；拒绝之后就只有麦克风这一路。"
            case .engineFailed(let message):
                message
            }
        }
    }

    public struct Blocked: LocalizedError, Equatable, Sendable {
        public var reason: BlockReason
        public var errorDescription: String? { "\(reason.title)。\(reason.detail)" }
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
    private var currentSource: SessionAudioSource = .microphone
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
    public func start(selection: Selection) async throws -> AsyncStream<AudioChunk> {
        await stop()
        guard !selection.isEmpty else { throw Blocked(reason: .noSourceSelected) }
        isTearingDown = false

        var streams: [(label: String, stream: AsyncStream<AudioChunk>)] = []

        if selection.usesMicrophone {
            let capture = MicrophoneCapture()
            do {
                streams.append(("麦克风", try await capture.start()))
            } catch {
                throw Blocked(reason: Self.blockReason(forMicrophone: error))
            }
            microphone = capture
        }

        if !selection.systemApps.isEmpty {
            let capture = SystemAudioCapture(
                selection: .init(
                    bundleIDs: selection.systemApps.map(\.bundleID),
                    label: selection.systemApps.map(\.name).joined(separator: "、")
                )
            )
            do {
                streams.append(("本机音频", watch(system: try await capture.start())))
            } catch {
                // 本机音频起不来 = 受阻（**不静默降级**成只录麦克风）：用户明确勾了它，
                // 只录一半还说得像成功，比明确拒绝更糟（§9 第 4 / 19 行）。
                await release()
                throw Blocked(reason: .systemAudioUnavailable(error.localizedDescription))
            }
            system = capture
        }

        activeSelection = selection
        currentSource = selection.resolvedSource
        systemAudioStopReason = nil
        gapCount = 0
        level = 0

        // 只有**麦克风**这一条路时才直通：它不需要热插拔。
        // 一旦选了本机音频，即使只有它一路，也走混音器——因为来源 App 退出之后要能**换上新的那一路**，
        // 而直通的那条流没有换人的位置（§5.6 的"唯一自动接回"）。
        guard streams.count > 1 || !selection.systemApps.isEmpty else {
            let only = streams[0].stream
            return only
        }

        let mixer = StreamMixer(sources: streams.map(\.stream))
        self.mixer = mixer
        let mixed = await mixer.start()
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
        system?.stop()
        system = nil
        let capture = SystemAudioCapture(
            selection: .init(
                bundleIDs: selection.systemApps.map(\.bundleID),
                label: selection.systemApps.map(\.name).joined(separator: "、")
            )
        )
        do {
            let stream = watch(system: try await capture.start())
            system = capture
            systemAudioStopReason = nil
            if let mixer {
                await mixer.attach(stream)
            }
            return true
        } catch {
            systemAudioStopReason = error.localizedDescription
            return false
        }
    }

    /// 停止采集并释放**全部**设备。幂等。
    public func stop() async {
        isTearingDown = true
        if let system { systemAudioStopReason = system.stopReason }
        await release()
        level = 0
        activeSelection = nil
    }

    /// 包一层观察者：这一路**自己在没有 teardown 的情况下结束**才算断了。
    ///
    /// 不这样做的话，来源退出只表现为"混音器少了一路"——用户会安静地丢掉对方的声音，
    /// 而库里既没有中断区间也没有任何解释（§5.6 明确要求它是"查得到的事实"）。
    private func watch(system stream: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        let (out, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        Task { @MainActor [weak self] in
            for await chunk in stream { continuation.yield(chunk) }
            continuation.finish()
            guard let self, !self.isTearingDown, self.activeSelection != nil else { return }
            let reason = self.system?.stopReason ?? "来源 App 退出了。"
            self.systemAudioStopReason = reason
            self.onSystemAudioLost?(reason)
        }
        return out
    }

    private func release() async {
        await mixer?.stop()
        mixer = nil
        microphone?.stop()
        microphone = nil
        system?.stop()
        system = nil
    }

    /// 把混音器的缺口计数与电平搬回主线程状态（界面上要显示的那两个数）。
    private func observe(_ mixer: StreamMixer) {
        Task { [weak self] in
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

// MARK: - 合流

/// 把若干路 16 kHz / 单声道 / PCM16 合成**一条**同样格式的流。
///
/// 时钟由它自己定：每 40 ms 从每一路的抖动缓冲里取 640 帧，缺的补静音。于是输出
/// 严格等间隔、没有一路能把整条流拖慢；某一路上游卡住只表现为**缺口数 +1**。
///
/// 这是"混音在 host time 域完成"的可实现版本：单机场景下各路都是同一块声卡出来的，
/// 用统一的 40 ms 栅格对齐就等于按同一时基合流，而不会因为拼包把两路错开半句。
actor StreamMixer {
    struct Snapshot: Sendable {
        var level: Double
        var gaps: Int
    }

    /// 一路最多留 400 ms：再多只说明它比时钟快，丢掉比无限堆积好。
    private static let maximumBufferedBytes = 16_000 * 2 * 4 / 10
    private static let bytesPerChunk = 16_000 * 2 * 40 / 1000

    private let sources: [AsyncStream<AudioChunk>]
    private var buffers: [Data]
    private var ingestTasks: [Task<Void, Never>] = []
    private var ticker: Task<Void, Never>?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var level: Double = 0
    private var gaps = 0

    init(sources: [AsyncStream<AudioChunk>]) {
        self.sources = sources
        self.buffers = Array(repeating: Data(), count: sources.count)
    }

    /// 起飞之后**再加一路**：来源 App 退出又回来时换的是这一路，别的路不受影响。
    func attach(_ stream: AsyncStream<AudioChunk>) {
        let index = buffers.count
        buffers.append(Data())
        ingestTasks.append(
            Task { [weak self] in
                for await chunk in stream {
                    await self?.ingest(index: index, chunk: chunk)
                }
                await self?.retire(index: index)
            }
        )
    }

    func start() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        for (index, source) in sources.enumerated() {
            ingestTasks.append(
                Task { [weak self] in
                    for await chunk in source {
                        await self?.ingest(index: index, chunk: chunk)
                    }
                    // 这一路结束了：不再补静音，只把这一路从合流里摘掉。
                    await self?.retire(index: index)
                }
            )
        }
        ticker = Task { [weak self] in
            let interval = Duration.milliseconds(40)
            var next = ContinuousClock.now
            while !Task.isCancelled {
                next = next.advanced(by: interval)
                await self?.tick()
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
        return stream
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        for task in ingestTasks { task.cancel() }
        ingestTasks.removeAll()
        continuation?.finish()
        continuation = nil
        buffers = Array(repeating: Data(), count: buffers.count)
    }

    func snapshot() -> Snapshot {
        Snapshot(level: level, gaps: gaps)
    }

    private func ingest(index: Int, chunk: AudioChunk) {
        guard buffers.indices.contains(index) else { return }
        buffers[index].append(chunk.pcm)
        if buffers[index].count > Self.maximumBufferedBytes {
            buffers[index].removeFirst(buffers[index].count - Self.maximumBufferedBytes)
        }
    }

    private func retire(index: Int) {
        guard buffers.indices.contains(index) else { return }
        buffers[index].removeAll()
    }

    private func tick() {
        guard let continuation else { return }
        var mixed = [Int32](repeating: 0, count: Self.bytesPerChunk / 2)
        var served = 0
        var didGap = false

        for index in buffers.indices {
            guard buffers[index].count >= Self.bytesPerChunk else {
                if !buffers[index].isEmpty { didGap = true }
                continue
            }
            served += 1
            let chunk = buffers[index].prefix(Self.bytesPerChunk)
            buffers[index].removeFirst(Self.bytesPerChunk)
            chunk.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for position in 0..<mixed.count {
                    mixed[position] += Int32(samples[position])
                }
            }
        }

        // 一路都没出样本：这一块**不产出**（产出就等于凭空写 40 ms 静音进转录）。
        guard served > 0 else { return }
        if didGap { gaps += 1 }

        var pcm = Data(capacity: Self.bytesPerChunk)
        var peak: Int32 = 0
        for value in mixed {
            let clamped = Int32(min(max(value, -32_768), 32_767))
            if abs(clamped) > peak { peak = abs(clamped) }
            withUnsafeBytes(of: Int16(clamped).littleEndian) { pcm.append(contentsOf: $0) }
        }
        level = peak == 0 ? 0 : AudioLevel.normalized(decibels: 20 * log10(Double(peak) / 32_768))
        continuation.yield(AudioChunk(pcm: pcm, level: level))
    }
}
