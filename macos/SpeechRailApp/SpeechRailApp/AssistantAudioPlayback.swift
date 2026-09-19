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
final class PCMStreamPlayer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unsupportedFormat
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "这个输出格式没法播放。"
            case .engineFailed(let message): message
            }
        }
    }

    /// 契约：TTS 输出 24 kHz PCM16。
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.speechrail.app.assistant.player", qos: .userInitiated)
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var pendingBuffers = 0
    private var stopped = false

    /// 队列播完（真正静音）时回调一次。界面用它把相位从"正在说话"退回"正在聆听"。
    var onDrained: (@MainActor () -> Void)?

    func start() async throws {
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

    /// 入队一块音频。空块与停止之后到的块都被丢掉（不假装播了）。
    func enqueue(_ pcm: Data) async {
        guard !pcm.isEmpty else { return }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
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
        guard shouldSchedule else { return }
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            let isLast = self.lock.withLock { () -> Bool in
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                return self.pendingBuffers == 0
            }
            if isLast {
                Task { @MainActor in self.onDrained?() }
            }
        }
    }

    /// 立刻静音并丢掉还没播的部分（插话打断 / 结束会话）。
    func stop() async {
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
