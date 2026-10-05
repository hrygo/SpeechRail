import AVFoundation
import Foundation

// MARK: - TTS 播放

/// 24 kHz / 单声道 / PCM16 的流式播放（契约里 TTS 的输出格式）。
///
/// 为什么不用 `AVAudioPlayer`：它要一个完整的文件，而这里的音频是一块块到的；
/// 打断要求"立刻静音"，缓冲队列必须能一次丢掉。所以用 `AVAudioEngine` + `AVAudioPlayerNode`。
///
/// 阻塞式 CoreAudio 调用（`engine.start()`）**不在主线程**上做（§5.13 的实测教训：
/// 最坏 36 秒）。
public final class PCMStreamPlayer: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case unsupportedFormat
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "这个输出格式没法播放。"
            case .engineFailed(let message): message
            }
        }
    }

    /// 契约：TTS 输出 24 kHz PCM16。
    public static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.speechrail.app.assistant.player", qos: .userInitiated)
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var stopped = false

    /// 队列播完（真正静音）时回调一次。界面用它把相位从"正在说话"退回"正在聆听"。
    public var onDrained: (@MainActor () -> Void)?
    /// 每一块设备播放完成时回调一次（入队时的 epoch、帧数、chunkID）。
    /// M0d 用 `.dataPlayedBack`（计入下游处理与设备延迟）记 played；
    /// 增量 TTS 用它逐块归还播放预算。epoch 让迟到的回调无法改动新一轮的账本，
    /// chunkID 让重复回调只归还一次。单次 schedule 只选一种 completion 类型。
    public var onBufferRendered: (@MainActor (Int, Int, UUID) -> Void)?

    public init() {}

    public func start() async throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
            )
        else { throw Failure.unsupportedFormat }
        self.format = format
        let engine = self.engine
        let player = self.player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.prepare()
                do {
                    try engine.start()
                    player.play()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: Failure.engineFailed(error.localizedDescription))
                }
            }
        }
    }

    /// 入队一块音频。空块与停止之后到的块都被丢掉（不假装播了），返回 `false`。
    /// `chunkID` 是该块的唯一身份，原样在 played 回调里带回。
    @discardableResult
    public func enqueue(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool {
        guard !pcm.isEmpty else { return false }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let format else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let destination = buffer.int16ChannelData?[0] {
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.update(from: base.assumingMemoryBound(to: Int16.self), count: frames)
            }
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            pendingBuffers += 1
            return true
        }
        guard shouldSchedule else { return false }
        // M0d：`.dataPlayedBack` = 设备播出去了（含下游处理与设备延迟）；
        // `.dataConsumed` 只表示播放器把数据拿走了，在欠载或大缓冲下会明显早到，
        // 不能拿来当"用户听完了"。单次 schedule 只选一种类型，不假设双回调。
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let state = self.lock.withLock {
                () -> (isLast: Bool, rendered: (@MainActor (Int, Int, UUID) -> Void)?) in
                // 停播之后到的 `dataRendered` 一律丢掉：它属于上一代，不许动新一轮的账本。
                guard !self.stopped else { return (false, nil) }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                return (self.pendingBuffers == 0, self.onBufferRendered)
            }
            if let rendered = state.rendered {
                Task { @MainActor in rendered(epoch, frames, chunkID) }
            }
            if state.isLast {
                Task { @MainActor in self.onDrained?() }
            }
        }
        return true
    }

    /// 立刻静音并丢掉还没播的部分（插话打断 / 结束会话）。
    public func stop() async {
        lock.withLock {
            pendingBuffers = 0
            stopped = true
        }
        let player = self.player
        let engine = self.engine
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                player.stop()
                player.reset()
                engine.stop()
                continuation.resume()
            }
        }
    }
}
