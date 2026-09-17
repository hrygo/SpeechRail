import AVFoundation
import Foundation

/// 音色克隆的录音通道。
///
/// 这是 App 第一次**采集**音频（此前只有播放与包络计算）。边界保持得和播放一样紧：
///
/// - 只在用户按下录制到停止之间录音；文件落在系统临时目录，注册成功或取消后立刻删除，
///   应用不把它写进作品库、不缓存、不上传第二次。
/// - 关闭 AEC / 降噪 / AGC（`AVAudioRecorder` 的默认采集链）：回声消除与自动增益会改变
///   用户本来的音色，而这一页要的正是「用户本来的音色」。这不是「更干净」的取舍，
///   是「不能替用户改声音」的取舍（REDESIGN-SPEC §13.2）。
/// - 电平表读的是录音器的真实 `averagePower`，不是自走的动画。
///
/// **录音器不在主线程上。** `AVAudioRecorder` 的创建与 `record()` 是同步的 CoreAudio 调用：
/// 它一直等到输入 IO 真的跑起来才返回。2026-09-16 实测（App 2.6.5 (14)，macOS 26.6.2）——
/// 首次启动麦克风采集时，coreaudiod 侧连续两次 `StartIOThread: got an error from starting
/// the IO thread, Error: 0x3C`（每次约 14 秒）后第三次才成功，`record()` 一共阻塞 36.3 秒。
/// 那一次整块界面被冻住：风火轮、计时器停在 00:00、连「正在准备」都画不出来。
/// 现在这段等待发生在 `RecorderThread` 上，主线程只负责状态与呈现。
@MainActor
@Observable
public final class VoiceRecordingController {
    public private(set) var isRecording = false
    /// 已按下录制、录音器还没就绪（`record()` 仍在等 CoreAudio）。
    ///
    /// 这是唯一一段「用户按了按钮、界面还没有反馈」的空档，所以它必须自己是一个状态：
    /// 卡片头显示「正在准备麦克风」，按钮变成取消入口，而不是让用户对着风火轮猜。
    public private(set) var isPreparing = false
    /// 准备时间已超过 `VoiceClone.preparationHintSeconds`：首次启动麦克风可能要几十秒，
    /// 这时把「还要等」说清楚，并告诉用户可以取消（REDESIGN-SPEC §13.2 的闭环）。
    public private(set) var preparationIsSlow = false
    /// 已录制时长（秒）。由真实时间差推进，不是计数器的累加；起点是录音器真正就绪的那一刻。
    public private(set) var elapsed: TimeInterval = 0
    /// 实时输入电平 0…1（由 `averagePower(forChannel:)` 的 dBFS 映射而来）。
    public private(set) var level: Double = 0
    /// 这一次录音里有没有出现过**真实**的输入信号（电平越过 `VoiceClone.signalFloorLevel`）。
    ///
    /// 2026-09-16 用户反馈「录音时声波不动、没有声音」：实测那一次的根因在系统侧（录音文件
    /// 整段样点全是 0，同一时刻 ffmpeg 走 AVCapture 也是全 0），但当时界面能说的只有
    /// 「电平条一直不亮」——用户没法判断是应用坏了、麦克风没选对，还是设备被静音了。
    /// 录制卡据此在 `VoiceClone.silenceHintSeconds` 之后直说「麦克风没有收到声音」。
    public private(set) var hasSignal = false
    /// 最后一次录音的临时文件；`stop()` 之后由调用方持有并负责 `discard()`。
    public private(set) var lastRecordingURL: URL?
    /// 麦克风权限被拒绝：界面上要给的是「去系统设置打开」，不是重试按钮。
    public private(set) var permissionDenied = false
    public private(set) var message: String?

    private let capture = RecorderBox()
    private var meterTask: Task<Void, Never>?
    private var slowHintTask: Task<Void, Never>?
    private var startedAt: Date?
    /// 本次「按下录制」的世代号：取消、丢弃、重录都会 +1，让仍在等待的那一次作废。
    private var attempt = 0
    /// 当前这一次录音的临时文件；`nil` 表示没有正在录的那一次。
    private var currentURL: URL?
    /// `stop()` 时记下的世代号：`finish()` 只收掉这一代（或更早）的录音器。
    ///
    /// 否则「停止 → 立刻重录」会有一次真正的抢跑：`finish()` 的无条件收尾可能落在
    /// 新录音器起来之后，把用户刚按下的那一次在几十毫秒内停掉（2026-09-16 实测日志：
    /// 第二次录音的 AudioQueue 只活了 55 ms）。
    private var finishingAttempt: Int?

    public init() {}

    public var hasRecording: Bool {
        lastRecordingURL != nil
    }

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 请求麦克风权限。返回 `false` 时 `permissionDenied` 会被置位，界面据此给系统设置入口。
    @discardableResult
    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionDenied = false
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            permissionDenied = !granted
            message = granted ? nil : "未获得麦克风权限，请在系统设置中允许 SpeechRail 使用麦克风。"
            return granted
        case .denied, .restricted:
            permissionDenied = true
            message = "未获得麦克风权限，请在系统设置中允许 SpeechRail 使用麦克风。"
            return false
        @unknown default:
            permissionDenied = true
            message = "无法确认麦克风权限，请在系统设置中检查。"
            return false
        }
    }

    /// 开始录制。返回 `false` 时 `message` 里是可直接展示给用户的原因。
    ///
    /// 这个方法是 `async` 的**唯一原因**是：`record()` 可能等很久（见类型注释里的实测）。
    /// 它在录音线程上等，主线程一秒钟都不占用。
    @discardableResult
    public func start() async -> Bool {
        guard !isRecording, !isPreparing else { return isRecording }
        message = nil
        discard()
        guard await requestPermission() else { return false }

        attempt += 1
        let currentAttempt = attempt
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-clone-\(UUID().uuidString).wav", isDirectory: false)

        isPreparing = true
        preparationIsSlow = false
        startSlowHint(attempt: currentAttempt)
        let outcome = await capture.start(attempt: currentAttempt, url: url)
        slowHintTask?.cancel()
        slowHintTask = nil
        isPreparing = false
        preparationIsSlow = false
        // 等待期间用户取消（或又按了一次）：这一次的录音器已经由 RecorderBox 自己收掉，
        // 这里不再报错——用户知道自己在做什么。
        guard currentAttempt == attempt else { return false }

        switch outcome {
        case .started:
            currentURL = url
            lastRecordingURL = nil
            startedAt = Date()
            elapsed = 0
            level = 0
            hasSignal = false
            isRecording = true
            startMetering()
            return true
        case .couldNotOpen:
            message = "无法开始录音，请检查麦克风与系统权限后重试。"
            return false
        case .didNotStart:
            message = "麦克风没有开始录音，请检查输入设备后重试。"
            return false
        case .superseded:
            return false
        }
    }

    /// 取消「正在准备」的那一次。
    ///
    /// 拆除不在这里做：`record()` 还阻塞在 CoreAudio 里，现在去等它会把界面又按回去。
    /// 这里只把这次作废（世代号 +1），录音器一旦起来就会被 `RecorderBox` 立刻停掉并删文件。
    public func cancelPreparation() {
        guard isPreparing else { return }
        capture.cancel(attempt: attempt)
        attempt += 1
        slowHintTask?.cancel()
        slowHintTask = nil
        isPreparing = false
        preparationIsSlow = false
    }

    /// 停止录制。
    ///
    /// 界面立刻回到「已录好」；真正的收尾（把 wav 头写完整）在录音线程上完成，由 `finish()` 等它——
    /// 读文件之前必须等稳，否则会读到一段还没封口的音频。
    public func stop() {
        guard isRecording || isPreparing else { return }
        slowHintTask?.cancel()
        slowHintTask = nil
        stopMetering()
        isRecording = false
        isPreparing = false
        preparationIsSlow = false
        level = 0
        if let url = currentURL {
            lastRecordingURL = url
            currentURL = nil
            finishingAttempt = attempt
        }
    }

    /// 等录音器真的停下来再交出临时文件；没有录音时返回 `nil`。
    ///
    /// 与 `consumeRecordingFile()` 的区别只有一个「等」字：`stop()` 之后文件还在写尾巴，
    /// 谁要读它，谁就先 await 这个方法。
    public func finish() async -> URL? {
        if let finishingAttempt {
            self.finishingAttempt = nil
            await capture.stop(upTo: finishingAttempt)
        }
        return consumeRecordingFile()
    }

    /// 丢弃这次录音（重录、离开页面、注册成功）：停掉录音器并删除临时文件，不留在磁盘上。
    public func discard() {
        let stale = lastRecordingURL
        if isPreparing {
            capture.cancel(attempt: attempt)
        }
        attempt += 1
        let generation = attempt
        slowHintTask?.cancel()
        slowHintTask = nil
        stopMetering()
        isRecording = false
        isPreparing = false
        preparationIsSlow = false
        currentURL = nil
        lastRecordingURL = nil
        elapsed = 0
        level = 0
        hasSignal = false
        finishingAttempt = nil
        Task {
            // 只收掉这一代以及更早的录音器：`discard()` 之后紧接着的 `start()` 起的是更新的
            // 世代，这条收尾不能把它停掉。
            await capture.stop(upTo: generation)
            if let stale {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    /// 交出当前录音文件的所有权（文件仍在磁盘上，仍归调用方处理）：读取字节、做本地量测，
    /// 然后由调用方删除。控制器不再持有它，因此不会出现「删过了还被当成有录音」。
    public func consumeRecordingFile() -> URL? {
        let url = lastRecordingURL
        lastRecordingURL = nil
        return url
    }

    public func clearMessage() {
        message = nil
    }

    /// 20Hz 读表：与 `AudioPlaybackController` 的进度采样同一节奏（`Waveform.progressInterval`），
    /// 人眼跟得上，也不会每秒几十次去敲录音器。
    private func startMetering() {
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                if let level = await self.capture.sample(), self.isRecording {
                    self.level = level
                    if level >= SpeechRailDesignTokens.VoiceClone.signalFloorLevel {
                        self.hasSignal = true
                    }
                }
                if let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
                // 到了服务端上限就自己停：让用户看见「已到上限」的说明，
                // 而不是提交后才收到 `audio_too_long`。
                if self.elapsed >= SpeechRailDesignTokens.VoiceClone.maximumSeconds {
                    self.stop()
                    self.message = "已到 \(Int(SpeechRailDesignTokens.VoiceClone.maximumSeconds)) 秒上限，录音已停止。"
                    return
                }
                try? await Task.sleep(for: .seconds(SpeechRailDesignTokens.Waveform.progressInterval))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        startedAt = nil
    }

    /// 准备超过 `preparationHintSeconds` 还没就绪：把「首次可能要等几十秒」说出来。
    private func startSlowHint(attempt: Int) {
        slowHintTask?.cancel()
        slowHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SpeechRailDesignTokens.VoiceClone.preparationHintSeconds))
            guard let self, self.isPreparing, self.attempt == attempt else { return }
            self.preparationIsSlow = true
        }
    }

    /// dBFS → 0…1。取 -60 dBFS 为底、0 dBFS 为顶：语音的可用动态基本落在这 60 dB 里。
    nonisolated static func normalizedLevel(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

// MARK: - 采集格式

/// 采集格式：48 kHz / 单声道 / 16-bit PCM。
///
/// 不在这里做 24 kHz 重采样：服务端会用 ffmpeg 统一转码到 24 kHz 单声道参考，
/// 应用若先重采样一次，只会给同一段声音多加一道无谓的处理。
///
/// 声明在文件作用域而不是 `@MainActor` 类里：录音器在私有线程上构造，参数要在那条线程上
/// 现取现用（`[String: Any]` 本身不是 Sendable，不做跨隔离传递）。
private enum CloneRecordingFormat {
    static let sampleRate: Double = 48_000

    static func settings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }
}

/// 一次「启动录音」的结果。分开报，是因为给用户的下一步不同：打不开文件是应用侧的问题，
/// 录不起来通常要先看输入设备。
private enum RecorderStartOutcome: Sendable {
    case started
    case couldNotOpen
    case didNotStart
    /// 等待期间被取消或替换：调用方什么都不用说，用户已经知道自己在做什么。
    case superseded
}

// MARK: - 录音线程

/// 一条自带 run loop 的私有线程。
///
/// macOS 上 `AVAudioRecorder` 是 AudioQueue 的封装，而 AudioQueue 的回调要落在**有 run loop
/// 的线程**上。主线程一直满足这个条件（这也是这一页原先能录出文件的原因），GCD 队列不保证。
/// 所以这里不是「随便找个后台线程」，而是把录音器整段搬到一条与主线程语义相同、但不挡界面的
/// 线程上：run loop 常驻，工作以 block 提交，结果用 continuation 带回调用方。
private final class RecorderThread: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var isStarting = false

    /// 在这条线程上执行一段工作。
    func perform(_ work: @escaping @Sendable () -> Void) {
        startIfNeeded()
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    private func startIfNeeded() {
        lock.lock()
        let alreadyRequested = isStarting
        isStarting = true
        lock.unlock()
        guard !alreadyRequested else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }
            // 空端口：run loop 要有活儿可等，否则 `run()` 会在第一次空转后直接返回。
            RunLoop.current.add(Port(), forMode: .default)
            self.lock.lock()
            self.runLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            self.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.speechrail.app.voice-clone.recorder"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }
}

// MARK: - 录音器

/// 录音器：所有接触 `AVAudioRecorder` 的代码都跑在 `RecorderThread` 上，因此这里
/// `@unchecked Sendable` 的前提成立——不是「大家都别管」，是「只有那条线程碰它」。
private final class RecorderBox: @unchecked Sendable {
    private let thread = RecorderThread()
    private var recorder: AVAudioRecorder?
    /// 最新的世代号：在录音线程上用它判断某一次启动是不是已经被取消或替换。
    private var latestAttempt = 0
    /// 正在跑的那一次的世代号；`0` 表示现在没有录音器在跑。只在录音线程上读写。
    private var runningAttempt = 0

    func start(attempt: Int, url: URL) async -> RecorderStartOutcome {
        await withCheckedContinuation { continuation in
            thread.perform { [self] in
                stopLocked()
                guard attempt >= latestAttempt else {
                    continuation.resume(returning: .superseded)
                    return
                }
                let recorder: AVAudioRecorder
                do {
                    recorder = try AVAudioRecorder(url: url, settings: CloneRecordingFormat.settings())
                } catch {
                    continuation.resume(returning: .couldNotOpen)
                    return
                }
                recorder.isMeteringEnabled = true
                guard recorder.record() else {
                    continuation.resume(returning: .didNotStart)
                    return
                }
                guard attempt >= latestAttempt else {
                    // 等待期间被取消或重录：刚起来的这一次没人要，立刻收干净——包括刚建的临时文件。
                    recorder.stop()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: .superseded)
                    return
                }
                self.recorder = recorder
                self.runningAttempt = attempt
                continuation.resume(returning: .started)
            }
        }
    }

    /// 把 `attempt` 这一次作废；已经在跑的录音器由正在等它的 `start` 收尾。
    func cancel(attempt: Int) {
        thread.perform { [self] in
            latestAttempt = max(latestAttempt, attempt + 1)
        }
    }

    /// 收掉**第 `generation` 代及更早**的录音器；更新的那一次（用户刚按下的重录）不动。
    ///
    /// 收尾动作（`discard()` / `finish()`）都是异步排队到录音线程上的，而排队顺序并不保证
    /// 「先收尾、后开机」：没有这个世代判断时，收尾可能落在新录音器起来之后，把刚起的
    /// 那一次停掉（2026-09-16 日志：第二次录音只活了 55 ms）。
    func stop(upTo generation: Int) async {
        await withCheckedContinuation { continuation in
            thread.perform { [self] in
                if runningAttempt <= generation {
                    stopLocked()
                }
                continuation.resume()
            }
        }
    }

    /// 读一次真实电平（dBFS → 0…1）；`nil` 表示已经没有录音器在跑。
    func sample() async -> Double? {
        await withCheckedContinuation { continuation in
            thread.perform { [self] in
                guard let recorder else {
                    continuation.resume(returning: nil)
                    return
                }
                recorder.updateMeters()
                continuation.resume(
                    returning: VoiceRecordingController.normalizedLevel(
                        decibels: Double(recorder.averagePower(forChannel: 0))
                    )
                )
            }
        }
    }

    private func stopLocked() {
        recorder?.stop()
        recorder = nil
        runningAttempt = 0
    }
}
