import AVFoundation
import Foundation

/// 参考录音的**本地**检查结论。
///
/// 判定权在服务端：`POST /v1/voices/clone/validate` 与 `POST /v1/voices/clone` 用同一套
/// 质量门（时长、静音、噪声底、削波、内容匹配），本地这一层只回答一个问题——
/// 「现在要不要让用户先重录」，好把一次几秒起步的上传与转码省掉
/// （REDESIGN-SPEC §13.2）。
public enum VoiceReferenceVerdict: Equatable, Sendable {
    case ready
    case tooShort
    case short
    case tooLong
    case silent
    case clipping

    public var tone: StatusTone {
        switch self {
        case .ready: .healthy
        case .short: .attention
        case .tooShort, .tooLong, .silent, .clipping: .critical
        }
    }

    public var title: String {
        switch self {
        case .ready: "本地检查通过"
        case .short: "时长偏短"
        case .tooShort: "太短了"
        case .tooLong: "太长了"
        case .silent: "几乎没有声音"
        case .clipping: "有削波"
        }
    }

    public var guidance: String {
        switch self {
        case .ready:
            "这段录音可以用来注册；服务端还会再核对一次内容。"
        case .short:
            "再读一会儿会更稳，建议 \(Int(SpeechRailDesignTokens.VoiceClone.minimumSeconds))–\(Int(SpeechRailDesignTokens.VoiceClone.targetSeconds)) 秒。"
        case .tooShort:
            "服务端要求参考音频至少 \(Int(SpeechRailDesignTokens.VoiceClone.Contract.minimumSeconds)) 秒，请重录。"
        case .tooLong:
            "服务端接受最长 \(Int(SpeechRailDesignTokens.VoiceClone.Contract.maximumSeconds)) 秒，请缩短后重录。"
        case .silent:
            "这段录音的电平太低或没有说话，请靠近麦克风、正常音量重录。"
        case .clipping:
            "音量顶到上限了，请离麦克风远一点或放低音量重录。"
        }
    }
}

/// 一段参考录音的本地量测结果。全部是**当前实测**，不是估计：峰值、有效电平、削波比例、
/// 语音活动比例与首尾静音都从解码后的样点算出来（`analysisWindowSeconds` 一窗）。
public struct AudioReferenceAnalysis: Equatable, Sendable {
    public let duration: TimeInterval
    /// 整段峰值电平（dBFS）。
    public let peakDecibels: Double
    /// 只统计有声窗的有效电平（dBFS）。
    public let activeDecibels: Double
    /// |样点| ≥ 0.99 的占比。
    public let clippingRatio: Double
    /// 有声窗占总窗数的比例。
    public let speechActiveRatio: Double
    public let leadingSilence: TimeInterval
    public let trailingSilence: TimeInterval
    public let verdict: VoiceReferenceVerdict
    /// 波形条的高度来源（0…1，`Waveform.envelopeBuckets` 个）。
    public let envelope: [CGFloat]

    public var durationText: String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 本地 DSP：解码临时录音 → 逐窗统计 → 结论 + 波形包络。
///
/// 纯函数、`nonisolated`：解码 + 遍历一段 45 秒的 48 kHz 单声道录音是本机毫秒级的工作，
/// 但它是 I/O 与解码，调用方负责放到主线程之外（与 `AudioEnvelope` 同一约定）。
enum AudioReferenceCheck {
    nonisolated static func analyze(fileAt url: URL) -> AudioReferenceAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }

        let windowFrames = max(
            1,
            Int((sampleRate * SpeechRailDesignTokens.VoiceClone.analysisWindowSeconds).rounded())
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(windowFrames)
        ) else { return nil }

        var windowPowers: [Double] = []
        var clippedSamples = 0
        var totalSamples = 0
        var peak: Double = 0
        var decodedFrames: AVAudioFramePosition = 0

        while decodedFrames < file.length {
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(windowFrames))
            } catch {
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let samples = channels[0]
            var sumSquares: Double = 0
            for index in 0..<frames {
                let magnitude = abs(Double(samples[index]))
                if magnitude > peak { peak = magnitude }
                if magnitude >= 0.99 { clippedSamples += 1 }
                sumSquares += Double(samples[index]) * Double(samples[index])
            }
            windowPowers.append(sumSquares / Double(frames))
            totalSamples += frames
            decodedFrames += AVAudioFramePosition(frames)
        }

        guard totalSamples > 0 else { return nil }
        let duration = Double(totalSamples) / sampleRate
        let peakDecibels = decibels(fromAmplitude: peak)
        // 「有声窗」按相对峰值判：本段录音里比峰值低 45 dB 以上的窗算静音。
        // 绝对阈值会误判安静但正常的录音，相对判据只回答「有没有明显没说话的段」。
        let activeThreshold = peakDecibels + SpeechRailDesignTokens.VoiceClone.speechActivityThresholdDBFS
        var activeCount = 0
        var activePowerSum: Double = 0
        var leadingSilenceWindows = 0
        var sawActiveWindow = false
        var trailingSilenceWindows = 0
        for power in windowPowers {
            let windowDecibels = decibels(fromAmplitude: power.squareRoot())
            if windowDecibels >= activeThreshold {
                activeCount += 1
                activePowerSum += power
                sawActiveWindow = true
                trailingSilenceWindows = 0
            } else if !sawActiveWindow {
                leadingSilenceWindows += 1
            } else {
                trailingSilenceWindows += 1
            }
        }
        let activeDecibels = activeCount > 0
            ? decibels(fromAmplitude: (activePowerSum / Double(activeCount)).squareRoot())
            : peakDecibels
        let speechActiveRatio = Double(activeCount) / Double(windowPowers.count)
        let clippingRatio = Double(clippedSamples) / Double(totalSamples)
        let windowSeconds = Double(windowFrames) / sampleRate

        let verdict = verdict(
            duration: duration,
            peakDecibels: peakDecibels,
            speechActiveRatio: speechActiveRatio,
            clippingRatio: clippingRatio
        )
        return AudioReferenceAnalysis(
            duration: duration,
            peakDecibels: peakDecibels,
            activeDecibels: activeDecibels,
            clippingRatio: clippingRatio,
            speechActiveRatio: speechActiveRatio,
            leadingSilence: Double(leadingSilenceWindows) * windowSeconds,
            trailingSilence: Double(trailingSilenceWindows) * windowSeconds,
            verdict: verdict,
            envelope: AudioEnvelope.levels(
                forAudioFileAt: url,
                buckets: SpeechRailDesignTokens.Waveform.envelopeBuckets
            ) ?? []
        )
    }

    nonisolated static func verdict(
        duration: TimeInterval,
        peakDecibels: Double,
        speechActiveRatio: Double,
        clippingRatio: Double
    ) -> VoiceReferenceVerdict {
        if duration < SpeechRailDesignTokens.VoiceClone.Contract.minimumSeconds { return .tooShort }
        if duration > SpeechRailDesignTokens.VoiceClone.Contract.maximumSeconds { return .tooLong }
        if peakDecibels < -40 || speechActiveRatio < 0.15 { return .silent }
        if clippingRatio > SpeechRailDesignTokens.VoiceClone.clippingRatioThreshold { return .clipping }
        if duration < SpeechRailDesignTokens.VoiceClone.minimumSeconds { return .short }
        return .ready
    }

    /// 20·log10(幅度)；0 幅度按 -120 dBFS 兜底，避免 -inf 传进界面。
    nonisolated static func decibels(fromAmplitude amplitude: Double) -> Double {
        guard amplitude > 0 else { return -120 }
        return max(-120, 20 * log10(amplitude))
    }
}
