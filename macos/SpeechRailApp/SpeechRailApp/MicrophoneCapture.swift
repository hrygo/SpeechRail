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
//   1. **线上格式固定 24 kHz / 单声道 / PCM16**。原生层归一是结构性的：契约规定
//      "首个 PCM 之后不得改格式"，只要出口永远是这一种，客户端就不可能违反它。
//   2. **实时回调里不做阻塞、不分配、不做 I/O**（§5.13）。回调只把 native Float 样本写进
//      预分配环形缓冲；格式转换由独立 serial drain 完成。
//   3. **PCM 不落盘**。这里没有任何写文件的路径——缓存只在内存里，各层容量固定且有独立上限。

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

/// 一路音频来源。字幕与会议都只认这个接口：于是麦克风、本机音频（阶段 6 的 tap）、
/// 以及核对用的文件源，在会话层看起来是同一种东西（`TECHNICAL-DESIGN` §5.4
/// `AudioSourceCoordinator` 的形状；阶段 3 只有麦克风与验证用的文件源）。
///
/// 出口格式是接口的一部分：**永远 24 kHz / 单声道 / PCM16**。契约规定"首个 PCM 之后不得改
/// 格式"，把归一放在来源这一侧，客户端就不可能违反它。
public protocol AudioChunkSource: Sendable {
    func start() async throws -> AudioChunkStream
    func stop() async
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
                "这个输入设备的格式转不成 24 kHz 单声道。"
            }
        }
    }

    /// 一块 100 ms：24 kHz × 0.1 s × 2 字节 = 4,800 字节。WebSocket 上按 100 ms 送，
    /// 端到端的延迟预算里这一项可以忽略，而事件数比 20 ms 一块少一个量级。
    public static let chunkDuration: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.speechrail.app.session.capture", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var drain: AudioCaptureDrain?
    private let stateLock = NSLock()
    private var stopTask: Task<Void, Never>?
    private var stopped = false
    private var continuation: AudioChunkStream.Continuation?
    private let captureEpoch = UUID(), sourceID = UUID()

    public init() {}

    /// 归一化出口就是 wire 的唯一采样率（`contracts/realtime-openai.md` §2）。
    public static let sampleRate: Double = 24_000

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

    /// CoreAudio startup and teardown stay on the owned serial queue.
    public func start() async throws -> AudioChunkStream {
        guard await Self.requestPermission() else { throw Failure.permissionDenied }
        guard !isStopped else { throw Failure.engineFailed("这个采集件已经停过了，一次会话一个实例。") }
        let pair = AudioChunkStream.makeStream(epoch: captureEpoch, sourceID: sourceID,
            onTermination: { [weak self] _ in self?.requestStop() })
        stateLock.withLock { continuation = pair.continuation }
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do { try startEngine(into: pair.continuation); done.resume() }
                    catch { tearDownEngine(); done.resume(throwing: error) }
                }
            }
            guard !isStopped else { throw CancellationError() }
            return pair.stream
        } catch {
            await stop()
            throw error
        }
    }

    deinit { requestStop() }

    /// Synchronous fail-safe only. Normal owners await stop to observe actual device/drain teardown.
    public func requestStop() {
        let change = stateLock.withLock { () -> (Bool, AudioChunkStream.Continuation?) in
            guard !stopped else { return (false, nil) }
            stopped = true
            return (true, continuation)
        }
        guard change.0 else { return }
        change.1?.finish(.cancelled)
        queue.async { [weak self] in self?.tearDownEngine() }
    }

    public func stop() async {
        let task = stateLock.withLock { () -> Task<Void, Never> in
            if let stopTask { return stopTask }
            stopped = true
            let task = Task { [self] in await performStop() }
            stopTask = task
            return task
        }
        await task.value
    }

    private func performStop() async {
        let oldDrain: AudioCaptureDrain? = await withCheckedContinuation { done in
            queue.async { [self] in
                tearDownEngine(cancelDrain: false)
                let old = drain; drain = nil
                done.resume(returning: old)
            }
        }
        await oldDrain?.stop(drainPending: true)
        stateLock.withLock { continuation }?.finish(.completed)
        stateLock.withLock { continuation = nil }
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    private func tearDownEngine(cancelDrain: Bool = true) {
        if cancelDrain { drain?.requestStop() }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
    }

    private func startEngine(into continuation: AudioChunkStream.Continuation) throws {
        guard !isStopped else { throw CancellationError() }
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Failure.engineFailed("输入设备没有可用的采样率") }
        let drain = try AudioCaptureDrain(inputSampleRate: format.sampleRate, epoch: captureEpoch, sourceID: sourceID,
            continuation: continuation, onFailure: { [weak self] _ in self?.requestStop() })
        self.engine = engine; self.drain = drain
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            drain.copyInput(buffer)
        }
        engine.prepare()
        do { try engine.start() }
        catch { throw Failure.engineFailed(error.localizedDescription) }
    }
}
