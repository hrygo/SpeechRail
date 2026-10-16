import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// 本机音频采集：macOS 的**按进程 tap**（`TECHNICAL-DESIGN` §3.2，product spec §14.1）。
//
// 这个文件**同时编进 App 与 `SpeechRailCaptureHelper` 两个 target**（见 `Package.swift`
// 与 `project.pbxproj` 的 Sources）：它是唯一一份 tap 实现，helper 只是它的宿主进程。
// 它只引用 App/helper 共享的音频 DTO；不依赖会话或 UI owner。
//
// 四条硬约束（与 `MicrophoneCapture` 同源）：
//
//   1. **线上格式固定 24 kHz / 单声道 / PCM16**：契约规定"首个 PCM 之后不得改格式"，
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
// bundleIDs 按实际音频进程精确匹配；浏览器等 App 的声音可能来自内嵌 helper。
// 来源 App 重启后的 `isProcessRestoreEnabled` 行为仍只有 SDK 标注语义。
// 这里把"接回"如实实现成**尽力而为**：tap 建立时就打开该开关，之后不再假装知道它生效了。

/// 单生产者 / 单消费者环形缓冲：实时回调写、drain 线程读。容量按完整帧对齐。
///
/// 它的存在就是为了让 §5.13 那条约束可执行：回调里没有锁、没有分配、没有 ObjC 消息。
final class InterleavedFloatRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// M3/V08:累计丢样数（tap 回调侧 ring 满时容纳不下的 samples）。
    /// 与 `AudioSampleRing.droppedSampleCount` 同一语义：无锁累加，上报离开回调。
    private let droppedSamples = Atomic<Int>(0)
    private let timeline = AudioCaptureTimeline()

    init(capacity: Int, channels: Int = 1) {
        precondition(channels > 0)
        // Align the physical wrap with complete frames, including 3/6 channels.
        var size = 1
        while size < max(capacity, 1024) { size <<= 1 }
        self.capacity = ((size + channels - 1) / channels) * channels
        self.storage = .allocate(capacity: self.capacity)
        self.storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    @inline(__always) func beginCapture(uptime: UInt64) -> Bool {
        timeline.begin(position: writeIndex.load(ordering: .relaxed), uptime: uptime)
    }
    func oldestCaptureUptime(samplesPerSecond: Double) -> UInt64? {
        timeline.uptime(at: readIndex.load(ordering: .relaxed), samplesPerSecond: samplesPerSecond)
    }

    /// 可供写入的**连续**空间（回绕处截断）。返回 `nil` 表示已满。
    @inline(__always)
    func writableSpan() -> (pointer: UnsafeMutablePointer<Float>, count: Int)? {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacity - (write &- read) - 1
        guard free > 0 else { return nil }
        let offset = write % capacity
        let contiguous = min(free, capacity - offset)
        return (storage + offset, contiguous)
    }

    @inline(__always)
    func commitWrite(_ count: Int) {
        guard count > 0 else { return }
        let write = writeIndex.load(ordering: .relaxed)
        writeIndex.store(write &+ count, ordering: .releasing)
    }

    /// M3/V08:累计丢样数（供诊断/观测读取；单调递增，饱和不再增长）。
    var droppedSampleCount: Int {
        droppedSamples.load(ordering: .relaxed)
    }

    /// M3/V08:记录因 ring 满而未能写入的剩余样本，避免静默吞掉。
    @inline(__always)
    func recordDroppedSamples(_ count: Int) {
        guard count > 0 else { return }
        let current = droppedSamples.load(ordering: .relaxed)
        guard current < 1_000_000_000 else { return }
        droppedSamples.add(count, ordering: .relaxed)
    }

    var availableSampleCount: Int { writeIndex.load(ordering: .acquiring) &- readIndex.load(ordering: .relaxed) }

    /// 可供读取的**连续**区间（回绕处截断）。返回 `nil` 表示已空。
    @inline(__always)
    func readableSpan() -> (pointer: UnsafePointer<Float>, count: Int)? {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = write &- read
        guard available > 0 else { return nil }
        let offset = read % capacity
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
        timeline.reset()
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
                "这台设备的音频格式转不成 24 kHz 单声道。"
            case .noBundleIdentifiers:
                "没有选择要采集的 App。"
            }
        }
    }

    /// 出口格式由这里定死：24 kHz / 单声道 / PCM16。
    public static let sampleRate: Double = 24_000
    /// 一次交付的时长（40 ms = 960 帧）。与麦克风那一条路同一个节奏。
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
    private var tapSampleRate = 48_000.0
    private var onChunk: (@Sendable (AudioChunk) -> Void)?
    private var onStopped: (@Sendable (AudioStreamError) -> Void)?
    private let captureEpoch: UUID, sourceID: UUID
    private var sequence: UInt64 = 0
    private var pendingUptime: UInt64?


    public init(configuration: Configuration, captureEpoch: UUID = UUID(), sourceID: UUID = UUID()) {
        self.configuration = configuration; self.captureEpoch = captureEpoch; self.sourceID = sourceID
    }

    /// 建立 tap、aggregate device 与 IOProc，并开始交付 PCM。
    ///
    /// **这是一个阻塞调用**：里面全是 CoreAudio 的同步接口，必须离开主线程等
    /// （`TECHNICAL-DESIGN` §5.13；本机音色克隆那条路冷启动实测最坏阻塞 36.3 秒）。
    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void,
                      onStopped: (@Sendable (AudioStreamError) -> Void)? = nil) throws {
        guard !configuration.bundleIDs.isEmpty else { throw Failure.noBundleIdentifiers }

        let description = CATapDescription()
        description.bundleIDs = Self.bundleIDsIncludingHelpers(configuration.bundleIDs)
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
            guard Self.supportsTapFormat(format) else { throw Failure.formatUnavailable }
            guard
                let input = Self.makeInputFormat(format),
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
            tapSampleRate = input.sampleRate

            // 环里最多留 1 秒：再多只说明下游卡住，丢掉比堆积好。
            ring = InterleavedFloatRing(
                capacity: Int(format.mSampleRate) * tapChannels, channels: tapChannels
            )
            try createAggregateDevice(tapUID: try Self.readTapUID(tapID: createdTap))
            try startIOProc()
        } catch {
            stop()
            throw error
        }

        self.onChunk = onChunk
        self.onStopped = onStopped
        sequence = 0; pendingUptime = nil
        pending.removeAll(keepingCapacity: true)
        scratch = [Float](repeating: 0, count: 4096)
        stateLock.withLock { isRunning = true }
        startDrainTimer()
    }

    /// 停采集并释放全部设备。**幂等**：没起来过、已经停过都能再调一次。
    public func stop(drainPending: Bool = false) {
        drainQueue.sync { [self] in
            drainTimer?.setEventHandler {}; drainTimer?.cancel(); drainTimer = nil
            if aggregateDeviceID != 0, let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if drainPending, isRunningCapture {
                while let ring, ring.availableSampleCount > 0, isRunningCapture {
                    let previous = ring.availableSampleCount
                    drain()
                    if ring.availableSampleCount >= previous { break }
                }
                if isRunningCapture { flushChunks(level: 0, flushPartial: true) }
            }
            stateLock.withLock { isRunning = false }
            if aggregateDeviceID != 0 { AudioHardwareDestroyAggregateDevice(aggregateDeviceID) }
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        }
        ioProcID = nil; aggregateDeviceID = 0; tapID = 0
        ring?.reset(); ring = nil; converter = nil; inputFormat = nil; outputFormat = nil
        onChunk = nil; onStopped = nil; pendingUptime = nil
        pending.removeAll(keepingCapacity: false); scratch.removeAll(keepingCapacity: false)
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
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let bytes = buffers.reduce(0) { $0 + Int($1.mDataByteSize) }
        let samples = bytes / MemoryLayout<Float>.size
        let duration = UInt64(Double(samples) / Double(tapChannels) / tapSampleRate * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        guard ring.beginCapture(uptime: now > duration ? now - duration : 0) else {
            ring.recordDroppedSamples(bytes / MemoryLayout<Float>.size)
            return
        }
        Self.copyInputToRing(bufferList, into: ring, channels: tapChannels)
    }

    static func makeInputFormat(_ format: AudioStreamBasicDescription) -> AVAudioFormat? {
        guard supportsTapFormat(format) else { return nil }
        let tag: AudioChannelLayoutTag
        switch format.mChannelsPerFrame {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        default: tag = kAudioChannelLayoutTag_DiscreteInOrder | format.mChannelsPerFrame
        }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate,
                             interleaved: true, channelLayout: layout)
    }

    static func supportsTapFormat(_ format: AudioStreamBasicDescription) -> Bool {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = format.mChannelsPerFrame
        let bytes = UInt64(nonInterleaved ? 1 : channels) * 4
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && format.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger) == 0
            && format.mBitsPerChannel == 32 && channels > 0
            && format.mSampleRate.isFinite && format.mSampleRate > 0
            && format.mSampleRate < Double(Int.max / max(Int(channels), 1))
            && format.mFramesPerPacket == 1
            && UInt64(format.mBytesPerFrame) == bytes
            && UInt64(format.mBytesPerPacket) == bytes
    }

    /// Validate complete Float32 frames before touching any source samples.
    static func copyInputToRing(
        _ bufferList: UnsafePointer<AudioBufferList>,
        into ring: InterleavedFloatRing,
        channels: Int
    ) {
        guard channels > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard !buffers.isEmpty, buffers.count == 1 || buffers.count == channels else { return }
        var frames = Int.max
        for buffer in buffers {
            let expectedChannels = buffers.count == 1 ? channels : 1
            guard Int(buffer.mNumberChannels) == expectedChannels else { return }
            let bytesPerFrame = MemoryLayout<Float>.size * expectedChannels
            let bytes = Int(buffer.mDataByteSize)
            guard bytes.isMultiple(of: bytesPerFrame) else { return }
            frames = min(frames, bytes / bytesPerFrame)
        }
        guard frames > 0 else { return }

        var remaining = frames
        var consumed = 0
        while remaining > 0 {
            // M3/V08:ring 满时剩余帧是丢弃的样本——计数后退出，不静默吞掉。
            guard let span = ring.writableSpan() else {
                ring.recordDroppedSamples(remaining * channels)
                return
            }
            let writableFrames = min(remaining, span.count / channels)
            guard writableFrames > 0 else {
                ring.recordDroppedSamples(remaining * channels)
                return
            }
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

    /// 把环里能读到的样本转成 24 kHz 单声道 PCM16，按 40 ms 一块交付。
    private func drain() {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running, let ring, let converter, let inputFormat, let outputFormat else { return }

        let channels = Int(inputFormat.channelCount)
        guard ring.droppedSampleCount == 0 else { failOnDrain(.droppedSamples); return }
        var peak: Float = 0
        let oldest = ring.oldestCaptureUptime(samplesPerSecond: inputFormat.sampleRate * Double(channels))
        if pending.isEmpty { pendingUptime = oldest }
        var remaining = max(1, Int(inputFormat.sampleRate / 10)) * channels

        // 输入：把这一轮能读到的连续区间全部吃进转换器（可能回绕几次）。
        while remaining > 0, let span = ring.readableSpan() {
            let frames = min(span.count, remaining) / channels
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
            remaining -= needed
            appendToConverter(frames: frames, channels: channels, converter: converter, inputFormat: inputFormat)
            guard isRunningCapture else { return }
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
        if conversionError != nil { failOnDrain(.sourceLost); return }
        guard output.frameLength > 0, let int16 = output.int16ChannelData else { return }
        let byteCount = Int(output.frameLength) * 2
        guard byteCount <= 24_000 - pending.count else { failOnDrain(.overflow); return }
        pending.append(UnsafeBufferPointer(start: int16[0], count: Int(output.frameLength)))
    }

    private func flushChunks(level: Double, flushPartial: Bool = false) {
        let bytesPerChunk = 1_920
        var offset = 0
        while pending.count - offset >= bytesPerChunk || (flushPartial && pending.count > offset) {
            let take = min(bytesPerChunk, pending.count - offset)
            guard let pendingUptime else { failOnDrain(.sourceLost); return }
            sequence &+= 1
            let uptime = pendingUptime + UInt64(offset / 2) * 1_000_000_000 / 24_000
            let stamp = AudioCaptureStamp(captureEpoch: captureEpoch, sourceID: sourceID,
                sourceSequence: sequence, capturedUptimeNanoseconds: uptime)
            onChunk?(.init(pcm: Data(pending[offset..<(offset + take)]), level: level, capturedAt: stamp.capturedInstant,
                sequenceNumber: Int(exactly: sequence), droppedSamplesBefore: ring?.droppedSampleCount,
                captureStamp: stamp))
            offset += take
        }
        if offset > 0 {
            pending.removeFirst(offset)
            pendingUptime = pendingUptime.map { $0 + UInt64(offset / 2) * 1_000_000_000 / 24_000 }
        }
    }

    private func failOnDrain(_ reason: AudioStreamTermination) {
        let first = stateLock.withLock { () -> Bool in
            guard isRunning else { return false }; isRunning = false; return true
        }
        guard first else { return }
        drainTimer?.setEventHandler {}; drainTimer?.cancel(); drainTimer = nil
        pending.removeAll(keepingCapacity: false)
        onStopped?(AudioStreamError(reason: reason, captureEpoch: captureEpoch, sourceID: sourceID,
            droppedSamples: reason == .droppedSamples ? UInt64(max(0, ring?.droppedSampleCount ?? 0)) : nil))
    }

    static func bundleIDsIncludingHelpers(
        _ selected: [String], applicationURLs: [URL]? = nil
    ) -> [String] {
        var identifiers = Set(selected)
        let roots = applicationURLs ?? selected.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).compactMap(\.bundleURL)
        }
        for candidate in roots {
            let root = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard let identifier = Bundle(url: root)?.bundleIdentifier,
                  selected.contains(identifier) else { continue }
            let contents = root.appendingPathComponent("Contents", isDirectory: true)
            guard let entries = FileManager.default.enumerator(
                at: contents, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let entry as URL in entries {
                // Only bundles physically inside the selected App belong to this source.
                // Do not infer ownership from a bundle-ID prefix or follow external links.
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else {
                    entries.skipDescendants()
                    continue
                }
                guard ["app", "xpc", "appex"].contains(entry.pathExtension),
                      let helperID = Bundle(url: resolved)?.bundleIdentifier,
                      !helperID.isEmpty else { continue }
                identifiers.insert(helperID)
            }
        }
        return identifiers.sorted()
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
