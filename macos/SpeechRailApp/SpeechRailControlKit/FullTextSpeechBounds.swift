import Foundation

/// #265 §6.0 边界 2：完整文本 adapter 的有界接收与解码校验。
///
/// `ServiceAPIClient.synthesize/postAudio` 返回完整 `SpeechAudioResponse`
/// 即视为可用——无硬字节上限、无绝对 deadline、无解码/样本格式校验。
/// 本 helper 是纯 additive 的接纳屏障：调用方在拿到完整响应后、提交 player
/// 前调用 `validate`，超限/超时/坏格式一律显式失败，不播出、不截尾。
/// 现有 `synthesize/postAudio/decodeAudio` 签名零改动；`usesFullTextSpeechForTest`
/// 保持 false，门禁测试不断言启用。
public enum FullTextSpeechBounds {
    /// 硬字节上限 4 MiB：与 Realtime 下行 decoded PCM 预算同量级
    ///（`RealtimeContractTypes` 默认 `maxBufferedAudioBytes`）。
    /// 24 kHz PCM16 下约 87s 解码音频，是容量换算不是延迟目标；
    /// 超限显式失败，调用方保留文字并转显式重试。
    public static let maxAudioBytes = 4 * 1024 * 1024
    /// 绝对 deadline 60s：`ServiceAPIClient.longRunningRequestTimeout`（180s）
    /// 是传输上限，此处是助手交互的接纳上限；超时不播出、不冒充成功。
    public static let receiveDeadline: Duration = .seconds(60)
    /// 最小非空音频：空响应不进 player，走 incomplete。
    public static let minAudioBytes = 1

    public enum Failure: Error, Equatable, Sendable {
        case emptyResponse
        case byteLimitExceeded(receivedBytes: Int, maximumBytes: Int)
        case deadlineExceeded
        case unsupportedContentType(String)
        case undecodablePayload(String)
    }

    /// 校验已收到的完整音频响应。纯函数、可单元测试：
    /// deadline 由调用方在 `synthesize` 前记录 `ContinuousClock.now`、
    /// 收到后传入 `elapsed`，超时即失败——不依赖传输层计时器。
    public static func validate(
        data: Data,
        contentType: String,
        elapsed: Duration,
        maximumBytes: Int = maxAudioBytes
    ) -> Result<Void, Failure> {
        if elapsed > receiveDeadline { return .failure(.deadlineExceeded) }
        guard !data.isEmpty, data.count >= minAudioBytes else { return .failure(.emptyResponse) }
        guard data.count <= maximumBytes else {
            return .failure(.byteLimitExceeded(receivedBytes: data.count, maximumBytes: maximumBytes))
        }
        let lowered = contentType.lowercased()
        guard lowered.hasPrefix("audio/") else {
            return .failure(.unsupportedContentType(contentType))
        }
        guard looksLikeAudio(data, contentType: lowered) else {
            return .failure(.undecodablePayload(contentType))
        }
        return .success(())
    }

    /// 最小可解码性探针：只认各格式魔数/结构，不做全量解码——
    /// 全量解码是 player 的职责，此处只拦“明显不是音频”的载荷。
    /// 未知 `audio/*` 子类型按通过处理，不误杀未来格式。
    private static func looksLikeAudio(_ data: Data, contentType: String) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if contentType.hasPrefix("audio/wav") || contentType.hasPrefix("audio/x-wav")
            || contentType.hasPrefix("audio/x-pcm") {
            // RIFF....WAVE
            guard bytes.count >= 12 else { return false }
            return bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
                && bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45
        }
        if contentType.hasPrefix("audio/mpeg") || contentType.hasPrefix("audio/mp3") {
            // ID3 或 MPEG 帧同步 0xFFEx
            guard bytes.count >= 3 else { return false }
            if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return true }
            return bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
        }
        if contentType.hasPrefix("audio/mp4") || contentType.hasPrefix("audio/aac")
            || contentType.hasPrefix("audio/m4a") {
            // ftyp 或 ADTS 同步 0xFFFx
            guard bytes.count >= 4 else { return false }
            if bytes.count >= 12
                && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
                return true
            }
            return bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0
        }
        if contentType.hasPrefix("audio/ogg") || contentType.hasPrefix("audio/opus") {
            // OggS
            guard bytes.count >= 4 else { return false }
            return bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53
        }
        if contentType.hasPrefix("audio/flac") {
            // fLaC
            guard bytes.count >= 4 else { return false }
            return bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43
        }
        // 未知 audio/* 子类型：不断言格式，不误杀未来编码。
        return true
    }
}
