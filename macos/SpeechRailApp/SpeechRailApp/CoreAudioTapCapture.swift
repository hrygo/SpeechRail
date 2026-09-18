import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// 本机音频采集：macOS 的**按进程 tap**（`TECHNICAL-DESIGN` §3.2，product spec §14.1）。
//
// 这个文件**同时编进 App 与 `SpeechRailCaptureHelper` 两个 target**（见 `Package.swift`
// 与 `project.pbxproj` 的 Sources）：它是唯一一份 tap 实现，helper 只是它的宿主进程。
// 因此它**不能引用 App 侧的任何类型**（`AudioChunkSource`、`AudioChunk` 都不在这里出现），
// 出口只有一条很窄的约定：16 kHz / 单声道 / PCM16 的 `Data` + 0…1 的电平。
//
// 四条硬约束（与 `MicrophoneCapture` 同源）：
//
//   1. **线上格式固定 16 kHz / 单声道 / PCM16**：契约规定"首个 PCM 之后不得改格式"，
//      归一放在来源这一侧，客户端就不可能违反它（§3.4）。
//   2. **实时回调里不分配、不加锁、不做 I/O**（§5.13）：回调只把交错后的 Float 写进
//      预分配环形缓冲（原子读写下标 + 裸指针），格式转换与电平计算都由 drain 线程做。
//   3. **PCM 不落盘**：这里没有任何写文件的路径。
//   4. **不改变用户听感**：`muteBehavior` 保持默认 `CATapUnmuted`——抓取不该让本机静音。
//
// 采集路径（Apple「Capturing system audio with Core Audio taps」的做法）：
//   `CATapDescription.bundleIDs` → `AudioHardwareCreateProcessTap`
//   → 私有 aggregate device（tap 作为它的输入流）→ `AudioDeviceCreateIOProcID` → start。
//
// **未验证**（`TECHNICAL-DESIGN` §12 第 1、2 条）：本机没有真机跑过这一条路径。
// 授权弹窗的实际触发点、`bundleIDs` 的限定是否真按 App 生效、以及
// `isProcessRestoreEnabled`（来源 App 重启后自动接回）都只是 SDK 标注语义。
// 这里把"接回"如实实现成**尽力而为**：tap 建立时就打开该开关，之后不再假装知道它生效了。

/// 单生产者 / 单消费者环形缓冲：实时回调写、drain 线程读。容量取 2 的幂。
///
/// 它的存在就是为了让 §5.13 那条约束可执行：回调里没有锁、没有分配、没有 ObjC 消息。
final class InterleavedFloatRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(capacity: Int) {
        // 2 的幂：环形回绕时不需要取模，掩码就够。
        var size = 1
        while size < max(capacity, 1024) { size <<= 1 }
        self.capacity = size
        self.storage = .allocate(capacity: size)
        self.storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// 可供写入的**连续**空间（回绕处截断）。返回 `nil` 表示已满。
    @inline(__always)
    func writableSpan() -> (pointer: UnsafeMutablePointer<Float>, count: Int)? {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacity - (write &- read) - 1
        guard free > 0 else { return nil }
        let offset = write & (capacity - 1)
        let contiguous = min(free, capacity - offset)
        return (storage + offset, contiguous)
    }

    @inline(__always)
    func commitWrite(_ count: Int) {
        guard count > 0 else { return }
        let write = writeIndex.load(ordering: .relaxed)
        writeIndex.store(write &+ count, ordering: .releasing)
    }

    /// 可供读取的**连续**区间（回绕处截断）。返回 `nil` 表示已空。
    @inline(__always)
    func readableSpan() -> (pointer: UnsafePointer<Float>, count: Int)? {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = write &- read
        guard available > 0 else { return nil }
        let offset = read & (capacity - 1)
        let contiguous = min(available, capacity - offset)
        return (UnsafePointer(storage + offset), contiguous)
    }

    @inline(__always)
    func commitRead(_ count: Int) {
        guard count > 0 else { return }
        let read = readIndex.load(ordering: .relaxed)
        readIndex.store(read &+ count, ordering: .releasing)
    }

    /// 清空。只在停止采集之后调用（那时生产者已经不在跑）。
    func reset() {
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
    }
}

/// 按进程 tap 的本机音频采集。一个实例对应一次会话的采集期，`stop()` 释放设备
/// （用户裁决：按功能启用、功能离开即释放）。
///
/// 它**不做会话决策、不解析文本、不落盘、不联网、不持有播放**——这正是它可以被放进
/// 一个独立 XPC 服务（崩溃隔离）的前提。
public final class CoreAudioTapCapture: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// 要抓的 App（bundle identifier）。空数组没有意义：调用方必须至少给一个。
        public var bundleIDs: [String]
        /// 目标输出设备（tap 绑定在输出设备的流上）。`nil` = 系统默认输出。
        public var outputDeviceUID: String?
        /// 仅用于诊断的可读名字。
        public var name: String

        public init(bundleIDs: [String], outputDeviceUID: String? = nil, name: String = "本机音频") {
            self.bundleIDs = bundleIDs
            self.outputDeviceUID = outputDeviceUID
            self.name = name
        }
    }

    public enum Failure: LocalizedError, Equatable {
        /// 系统版本 / 权限 / 设备不支持这条路径。
        case tapFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case formatUnavailable
        case converterUnavailable
        case noBundleIdentifiers

        public var errorDescription: String? {
            switch self {
            case .tapFailed(let status):
                "系统没有允许建立本机音频的采集通道（\(status)）。"
            case .aggregateDeviceFailed(let status):
                "本机音频的采集设备没建起来（\(status)）。"
            case .deviceStartFailed(let status):
                "本机音频的采集设备没有开始出声音（\(status)）。"
            case .formatUnavailable:
                "读不出这台设备的音频格式。"
            case .converterUnavailable:
                "这台设备的音频格式转不成 16 kHz 单声道。"
            case .noBundleIdentifiers:
                "没有选择要采集的 App。"
            }
        }
    }

    /// 出口格式由这里定死：16 kHz / 单声道 / PCM16。
    public static let sampleRate: Double = 16_000
    /// 一次交付的时长（40 ms = 640 帧）。与麦克风那一条路同一个节奏。
    private static let chunkDuration: TimeInterval = 0.04

    private let configuration: Configuration
    private var tapID = AudioObjectID(0)
    private var aggregateDeviceID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var ring: InterleavedFloatRing?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var scratch: [Float] = []
    private var pending: Data = Data()
    private var drainTimer: DispatchSourceTimer?
    private let drainQueue = DispatchQueue(label: "com.speechrail.capture.tap.drain", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isRunning = false
    private var tapChannels = 2
    private var onChunk: (@Sendable (Data, Double) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// 建立 tap、aggregate device 与 IOProc，并开始交付 PCM。
    ///
    /// **这是一个阻塞调用**：里面全是 CoreAudio 的同步接口，必须离开主线程等
    /// （`TECHNICAL-DESIGN` §5.13；本机音色克隆那条路冷启动实测最坏阻塞 36.3 秒）。
    public func start(onChunk: @escaping @Sendable (Data, Double) -> Void) throws {
        guard !configuration.bundleIDs.isEmpty else { throw Failure.noBundleIdentifiers }

        let description = CATapDescription()
        description.bundleIDs = configuration.bundleIDs
        description.isMono = false
        description.isMixdown = true
        description.isExclusive = false
        description.isPrivate = true
        // 抓取不该改变用户听感：保持默认的 unmuted（`CATapDescription.h` 的默认值）。
        description.muteBehavior = .unmuted
        // 来源 App 重启后按 bundle id 自动接回。**SDK 语义，非实测行为**（§12 第 2 条）。
        description.isProcessRestoreEnabled = true
        description.name = "SpeechRail · \(configuration.name)"
        if let deviceUID = configuration.outputDeviceUID {
            description.deviceUID = deviceUID
        }

        var createdTap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != 0 else { throw Failure.tapFailed(tapStatus) }
        tapID = createdTap

        do {
            let format = try Self.readTapFormat(tapID: createdTap)
            guard
                let input = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: format.mSampleRate,
                    channels: AVAudioChannelCount(max(format.mChannelsPerFrame, 1)),
                    interleaved: true
                ),
                let output = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Self.sampleRate,
                    channels: 1,
                    interleaved: true
                ),
                let createdConverter = AVAudioConverter(from: input, to: output)
            else { throw Failure.converterUnavailable }
            inputFormat = input
            outputFormat = output
            converter = createdConverter
            tapChannels = Int(input.channelCount)

            // 环里最多留 1 秒：再多只说明下游卡住，丢掉比堆积好。
            ring = InterleavedFloatRing(capacity: Int(format.mSampleRate) * max(tapChannels, 1))
            try createAggregateDevice(tapUID: try Self.readTapUID(tapID: createdTap))
            try startIOProc()
        } catch {
            stop()
            throw error
        }

        self.onChunk = onChunk
        pending.removeAll(keepingCapacity: true)
        scratch = [Float](repeating: 0, count: 4096)
        isRunning = true
        startDrainTimer()
    }

    /// 停采集并释放全部设备。**幂等**：没起来过、已经停过都能再调一次。
    public func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()

        drainTimer?.cancel()
        drainTimer = nil
        drainQueue.sync { [self] in
            if aggregateDeviceID != 0 {
                if let ioProcID {
                    AudioDeviceStop(aggregateDeviceID, ioProcID)
                    AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                }
                // 设备先停、IOProc 先销毁，再拆 aggregate device：顺序反了会拿到半路的回调。
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            if tapID != 0 {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
        ioProcID = nil
        aggregateDeviceID = 0
        tapID = 0
        ring?.reset()
        ring = nil
        converter = nil
        inputFormat = nil
        outputFormat = nil
        onChunk = nil
        pending.removeAll(keepingCapacity: true)
    }

    /// 采集是否真的在出样本。会话提交前用它判"宁可没开始，也不要一条空记录"（§3.5）。
    public var isRunningCapture: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    // MARK: - Core Audio 装配

    private func createAggregateDevice(tapUID: String) throws {
        let aggregateUID = "com.speechrail.capture.\(UUID().uuidString)"
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeechRail · \(configuration.name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // tap 是它的输入流：不自动起，由我们显式 start，免得设备在没人听的时候也在跑。
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]
        if let deviceUID = configuration.outputDeviceUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = deviceUID
        }
        var deviceID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != 0 else { throw Failure.aggregateDeviceFailed(status) }
        aggregateDeviceID = deviceID
    }

    private func startIOProc() throws {
        let deviceID = aggregateDeviceID
        var proc: AudioDeviceIOProcID?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let created = AudioDeviceCreateIOProcID(deviceID, Self.ioProc, context, &proc)
        guard created == noErr, let proc else { throw Failure.deviceStartFailed(created) }
        ioProcID = proc
        let started = AudioDeviceStart(deviceID, proc)
        guard started == noErr else { throw Failure.deviceStartFailed(started) }
    }

    /// 实时回调。**这里只有算术与裸内存写**：没有锁、没有分配、没有 ObjC 消息（§5.13）。
    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, context in
        guard let context else { return noErr }
        let capture = Unmanaged<CoreAudioTapCapture>.fromOpaque(context).takeUnretainedValue()
        capture.receive(inputData)
        return noErr
    }

    private func receive(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let ring else { return }
        let channels = max(tapChannels, 1)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard !buffers.isEmpty else { return }
        // 帧数按第一个缓冲算：tap 的各通道在同一个 buffer list 里长度一致。
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        var remaining = frames
        var consumed = 0
        while remaining > 0 {
            guard let span = ring.writableSpan() else { return }
            let writableFrames = min(remaining, span.count / channels)
            guard writableFrames > 0 else { return }
            for frame in 0..<writableFrames {
                let frameIndex = consumed + frame
                for channel in 0..<channels {
                    // 交错写入：非交错的多缓冲与单缓冲在这里被拉平成同一种内存布局，
                    // 下游的转换器因此只认一种输入。
                    var value: Float = 0
                    if buffers.count == 1 {
                        if let data = buffers[0].mData {
                            let plane = data.assumingMemoryBound(to: Float.self)
                            value = plane[frameIndex * channels + channel]
                        }
                    } else if channel < buffers.count, let data = buffers[channel].mData {
                        let plane = data.assumingMemoryBound(to: Float.self)
                        value = plane[frameIndex]
                    }
                    span.pointer[frame * channels + channel] = value
                }
            }
            ring.commitWrite(writableFrames * channels)
            consumed += writableFrames
            remaining -= writableFrames
        }
    }

    // MARK: - 转换与交付

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + Self.chunkDuration, repeating: Self.chunkDuration, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()
    }

    /// 把环里能读到的样本转成 16 kHz 单声道 PCM16，按 40 ms 一块交付。
    private func drain() {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running, let ring, let converter, let inputFormat, let outputFormat else { return }

        let channels = Int(inputFormat.channelCount)
        var peak: Float = 0

        // 输入：把这一轮能读到的连续区间全部吃进转换器（可能回绕几次）。
        while let span = ring.readableSpan() {
            let frames = span.count / channels
            guard frames > 0 else { ring.commitRead(span.count); continue }
            let needed = frames * channels
            if scratch.count < needed { scratch = [Float](repeating: 0, count: needed) }
            for index in 0..<needed {
                let value = span.pointer[index]
                scratch[index] = value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
            ring.commitRead(needed)
            appendToConverter(frames: frames, channels: channels, converter: converter, inputFormat: inputFormat)
        }

        _ = outputFormat
        flushChunks(level: AudioLevelScale.normalized(peak: peak))
    }

    private func appendToConverter(
        frames: Int,
        channels: Int,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat
    ) {
        guard
            frames > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ),
            let destination = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        // `interleaved: true` 的 Float32 缓冲在 `floatChannelData` 里只有一路指针，
        // 里面是**交错**的 `frames × channels` 个样本。
        destination[0].update(from: scratch, count: frames * channels)

        let ratio = Self.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if conversionError != nil { return }
        guard output.frameLength > 0, let int16 = output.int16ChannelData else { return }
        pending.append(UnsafeBufferPointer(start: int16[0], count: Int(output.frameLength)))
    }

    private func flushChunks(level: Double) {
        let bytesPerChunk = Int(Self.sampleRate * Self.chunkDuration) * MemoryLayout<Int16>.size
        let emit = onChunk
        while pending.count >= bytesPerChunk {
            let chunk = pending.prefix(bytesPerChunk)
            pending.removeFirst(bytesPerChunk)
            emit?(Data(chunk), level)
        }
    }

    // MARK: - 读属性

    private static func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw Failure.formatUnavailable }
        return format
    }

    private static func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw Failure.formatUnavailable }
        return uid as String
    }
}

/// dBFS → 0…1。与 App 侧 `AudioLevel` 是**同一条曲线**（-60 dBFS 为底、0 dBFS 为顶）：
/// 这一份是给它自己用的，因为 helper 进程里没有 App 的类型。
enum AudioLevelScale {
    static func normalized(peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return normalized(decibels: 20 * log10(Double(peak)))
    }

    static func normalized(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 60) / 60, 0), 1)
    }
}
