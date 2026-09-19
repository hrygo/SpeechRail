import AVFoundation
import CoreAudio
import Foundation

// 会话模块的麦克风采集（`TECHNICAL-DESIGN` §5.4 的单路来源）。
//
// 与音色克隆的录音器**不是同一个东西**，所以没有复用 `VoiceRecordingController`：
// 那一个是"录到一段文件、文件是产物"，这一个是"连续出 PCM、PCM 立刻进 WebSocket 然后丢掉"。
// 共用的是**权限口径**（`AVCaptureDevice`）与**电平曲线**（`AudioLevel`），
// 这两处正是 §2.2 说的"抽成组件而不是抄第二遍"——所以曲线在下面先被抽出来，
// 音色克隆那边也改成走它（同一个读数在三页上长得一样）。
//
// 三条硬约束：
//
//   1. **线上格式固定 16 kHz / 单声道 / PCM16**。原生层归一是结构性的：契约规定
//      "首个 PCM 之后不得改格式"，只要出口永远是这一种，客户端就不可能违反它。
//   2. **实时回调里不做阻塞、不分配、不做 I/O**（§5.13）。回调只把转换后的字节写进
//      预分配的环形缓冲；取数据由一条 drain 任务按 40 ms 拉走。
//   3. **PCM 不落盘**。这里没有任何写文件的路径——缓存只在内存里，容量上限就是 1 秒。

/// 电平的唯一一条曲线：dBFS → 0…1。取 -60 dBFS 为底、0 dBFS 为顶——
/// 语音的可用动态基本落在这 60 dB 里。
///
/// 它是**共用的那一个**（`IMPLEMENTATION-READINESS` §2.2 第 5 项：抽出来而不是抄第二遍）：
/// 音色克隆的录音器与三页会话的状态带都读同一条曲线，所以同一段声音在三处读数一致。
public enum AudioLevel {
    public static func normalized(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 60) / 60, 0), 1)
    }

    /// 16-bit 单声道 PCM 的峰值 → 0…1。
    public static func peak(_ samples: UnsafeBufferPointer<Int16>) -> Double {
        var peak: Int32 = 0
        for sample in samples {
            let value = abs(Int32(sample))
            if value > peak { peak = value }
        }
        guard peak > 0 else { return 0 }
        return normalized(decibels: 20 * log10(Double(peak) / 32_768))
    }
}

/// 一块下游要用的音频：16 kHz / 单声道 / PCM16，外加这一块的真实电平（0…1）。
public struct AudioChunk: Sendable {
    public var pcm: Data
    public var level: Double

    public init(pcm: Data, level: Double) {
        self.pcm = pcm
        self.level = level
    }
}

/// 一路音频来源。字幕与会议都只认这个接口：于是麦克风、本机音频（阶段 6 的 tap）、
/// 以及核对用的文件源，在会话层看起来是同一种东西（`TECHNICAL-DESIGN` §5.4
/// `AudioSourceCoordinator` 的形状；阶段 3 只有麦克风与验证用的文件源）。
///
/// 出口格式是接口的一部分：**永远 16 kHz / 单声道 / PCM16**。契约规定"首个 PCM 之后不得改
/// 格式"，把归一放在来源这一侧，客户端就不可能违反它。
public protocol AudioChunkSource: Sendable {
    func start() async throws -> AsyncStream<AudioChunk>
    func stop()
}

/// 麦克风采集。一个实例对应一次会话的采集期，停了就释放设备（用户裁决：按功能启用、离开释放）。
public final class MicrophoneCapture: AudioChunkSource, @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case engineFailed(String)
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "麦克风未授权。"
            case .engineFailed(let message):
                "麦克风没有开始采集：\(message)"
            case .converterUnavailable:
                "这个输入设备的格式转不成 16 kHz 单声道。"
            }
        }
    }

    /// 一块 100 ms：16 kHz × 0.1 s × 2 字节 = 3,200 字节。WebSocket 上按 100 ms 送，
    /// 端到端的延迟预算里这一项可以忽略，而事件数比 20 ms 一块少一个量级。
    public static let chunkDuration: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.speechrail.app.session.capture", qos: .userInitiated)
    /// 一秒的 16 kHz 单声道 PCM16 = 32,000 字节。**上限按字节算**，不是按采样点数：
    /// 写成 `Int(sampleRate)` 会得到半秒（一个采样两字节），与"容量上限就是 1 秒"对不上。
    private static let ringCapacityBytes = Int(sampleRate) * MemoryLayout<Int16>.size
    private let ring = PCMRing(capacity: MicrophoneCapture.ringCapacityBytes)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var drainTask: Task<Void, Never>?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    /// `start()` 等在 `engine.start()` 上时**不持有调用方的 actor**（它是个 nonisolated
    /// 异步函数），等待期间 `stop()` 完全可能从另一个上下文插进来，所以这一位用锁保护。
    private let stateLock = NSLock()
    private var stopped = false

    public init() {}

    public static let sampleRate: Double = 16_000

    /// 与音色克隆同一处口径：`authorized` 才算有权限（`.notDetermined` 也还没拿到）。
    public static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 系统当前默认输入设备的显示名（`AVAudioEngine.inputNode` 跟的就是它）。
    ///
    /// 走 CoreAudio 而不是 `AVCaptureDevice`：这里只是问"现在的默认输入是哪一个"，
    /// **不需要麦克风权限、也不打开设备**——界面上把它写出来（「麦克风 MacBook 麦克风」）
    /// 是为了让人一眼看出插着的耳机有没有被当成输入，而不是为了收样本。
    /// 读不到就返回 `nil`，界面退回「系统默认」。
    public static var defaultInputDeviceName: String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &nameAddress, 0, nil, &nameSize, &name
        ) == noErr, let name else { return nil }
        let value = name.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    /// 请求麦克风权限。`false` 表示用户没给（去过系统设置，或者拒绝了）。
    @discardableResult
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    /// 开始采集。返回的流在 `stop()` 之后自然结束。
    ///
    /// `engine.start()` 是阻塞的 CoreAudio 调用（本机实测最坏 36 秒的那一类），所以它跑在
    /// 采集队列上，调用点 `await` 的是结果而不是主线程。
    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.requestPermission() else { throw Failure.permissionDenied }
        // 一个实例只服务一次采集期（文件头第 2 条）。停过之后再开始是编程错误：拆卸已经排在
        // 这条串行队列上，就算引擎又起来了也会被拆掉——那会交出一个"看着活着、其实没有引擎"
        // 的对象。宁可在这里拒绝。
        guard !isStopped else { throw Failure.engineFailed("这个采集件已经停过了，一次会话一个实例。") }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        ring.reset()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try startEngine()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            self.continuation = nil
            continuation.finish()
            throw error
        }
        // 等引擎起来的这段时间里用户可能已经按了停（`stop()` 的拆卸排在同一条串行队列上，
        // 会在这之后跑）。这时**不能**把这一路当成活的交出去：设备已经拆了，返回一条活的流
        // 只会在下游留下一个永远不出字的会话。宁可在这里失败，让调用点如实报受阻。
        guard !isStopped else {
            self.continuation = nil
            continuation.finish()
            throw Failure.engineFailed("采集在开始的过程中被取消。")
        }
        startDraining(into: continuation)
        return stream
    }

    /// 停止采集并**立刻释放设备**（引擎与 tap 都拆掉；不是挂起）。
    public func stop() {
        markStopped(true)
        drainTask?.cancel()
        drainTask = nil
        continuation?.finish()
        continuation = nil
        queue.async { [self] in
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            converter = nil
            ring.reset()
        }
    }

    private func markStopped(_ value: Bool) {
        stateLock.lock()
        stopped = value
        stateLock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    // MARK: - 引擎（只在采集队列上碰）

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw Failure.engineFailed("输入设备没有可用的采样率")
        }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw Failure.converterUnavailable
        }
        self.converter = converter
        self.engine = engine

        // 回调在音频线程上：这里只有一次转换 + 一次环形缓冲写入。
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = Self.convert(buffer, using: converter, to: outputFormat) else { return }
            // 电平在这里不算：它由取数据的一方按块算一次（`PCMRing.drain`），
            // 音频回调里只做一次转换和一次拷贝。
            ring.write(converted)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            throw Failure.engineFailed(error.localizedDescription)
        }
    }

    /// 取数据的一方**直接拿着这条流的 continuation**，不再回头读那个会被 `stop()` 置空的
    /// 属性：一条在后台跑的 drain 任务与主线程上的 `stop()` 读同一块内存是没有意义的竞争。
    private func startDraining(into continuation: AsyncStream<AudioChunk>.Continuation) {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            let interval = Self.chunkDuration
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard let chunk = self.ring.drain() else { continue }
                continuation.yield(chunk)
            }
        }
    }

    // MARK: - 格式转换

    /// 输入格式 → 16 kHz 单声道 PCM16。转换器是有状态的，所以每个会话只建一个。
    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else {
            return nil
        }
        let count = Int(output.frameLength)
        return Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
    }
}

// MARK: - 环形缓冲

/// 预分配的字节环形缓冲：音频回调只 memcpy，取数据的一方按块拉走。
///
/// 容量上限就是 1 秒。写满时**丢最旧的字节**——丢了就是真的没录上，这一点与
/// `TECHNICAL-DESIGN` §5.2 第 3 条（断线不重放 PCM）是同一条口径：不假装音频还在，
/// 也不做"回源补全"。（不额外计数：这个数今天没有消费者，写一个没人读的计数器
/// 比不写更容易被误当成"已经有监控了"。）
private final class PCMRing: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        count = 0
        lock.unlock()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        // 音频回调里只有"一两次 memcpy"：逐字节写 3,200 个字节在实时线程上是白给的开销。
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                // 一次最多填到环形缓冲的末尾，绕回的那一段留给下一轮。
                let run = min(capacity - writeIndex, raw.count - offset)
                storage.withUnsafeMutableBytes { destination in
                    destination.baseAddress?.advanced(by: writeIndex)
                        .copyMemory(from: base.advanced(by: offset), byteCount: run)
                }
                writeIndex = (writeIndex + run) % capacity
                offset += run
                // 写满时丢掉最旧的那几个字节：读指针跟着往前推，写指针不回头。
                let overflow = count + run - capacity
                if overflow > 0 {
                    count = capacity
                    readIndex = (readIndex + overflow) % capacity
                } else {
                    count += run
                }
            }
        }
    }

    /// 取走当前全部可用字节；不足一块也照取（晚一块比多等一块好：字幕要的是及时）。
    func drain() -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(storage[readIndex])
            readIndex = (readIndex + 1) % capacity
        }
        let taken = count
        count = 0
        let data = Data(out)
        let level = taken > 0 ? Self.peakLevel(data) : 0
        return AudioChunk(pcm: data, level: level)
    }

    private static func peakLevel(_ data: Data) -> Double {
        data.withUnsafeBytes { raw in
            AudioLevel.peak(raw.bindMemory(to: Int16.self))
        }
    }
}
