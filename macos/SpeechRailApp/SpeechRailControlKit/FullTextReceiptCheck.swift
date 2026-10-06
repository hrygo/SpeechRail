import Foundation

/// #266 §6.0 边界 3：完整文本 adapter 的 receipt 核对与 unknown 语义。
///
/// 服务端事实（`src/speechrail/application/render_receipts.py`）：
/// receipt 只有 `pending/completed/cancelled/error` 四种终态；
/// `cancel()` 只改状态不补样本；`accept_pcm` 在非 pending 时抛错；
/// `complete()` 在零样本 pending 上记 `error/empty_audio`；
/// `audio` 段携带 `sample_count` 与 `pcm_sha256`（传输前 PCM 的摘要）。
/// header/recipe 双携带的事实（voice、制品、格式、worker revision）
/// 在 `begin()` 即做一致性校验，分叉直接拒绝。
///
/// 本 helper 是纯 additive 的核对屏障：调用方在有界接收（边界 2，
/// `FullTextSpeechBounds`）通过后、提交 player 前调用 `evaluate`，
/// 把“服务说交付了什么”收敛成一个诚实的三值结论。
/// 现有 `fetchReceipt/decodeAudio/provenance` 签名零改动；
/// `usesFullTextSpeechForTest` 保持 false，门禁测试不断言启用。
public enum FullTextReceiptCheck {
    /// 核对结论。`unknown` 不是失败：调用方保持 unknown 并停止自动新合成，
    /// 转显式重试——2xx、EOF、Task 退出、cancelled 回执均不证明资源空闲。
    public enum Verdict: Equatable, Sendable {
        /// 服务交付事实与期望一致：completed + revision 对上 + 有样本。
        /// 只证明“服务交付了这段音频”，不证明逐字读对或用户已听完；
        /// 质量与 played 门仍各自存在。
        case deliverable
        /// 证据不足：pending、cancelled、error、未知状态、
        /// revision/样本证据不一致。调用方不得播出、不得开新合成。
        case unknown(reason: String)
    }

    /// 本轮期望：与 `assistantInteractiveSpeechOptions` 的 revision pin 同源。
    /// nil 表示“无期望”（调用方 fail-closed 的上游已保证期望存在；
    /// 此处 nil 只是不做该项比对，不降级通过）。
    public struct Expectation: Equatable, Sendable {
        public let expectedVoiceRevision: String?
        public let expectedModelRevision: String?

        public init(expectedVoiceRevision: String? = nil, expectedModelRevision: String? = nil) {
            self.expectedVoiceRevision = expectedVoiceRevision
            self.expectedModelRevision = expectedModelRevision
        }
    }

    /// 核对一条已取回的 receipt。纯函数、可单元测试。
    /// - `receivedBytes`：边界 2 已接纳的音频字节数，用于与 receipt `sample_count`
    ///   交叉核对（`sample_count * 2 == receivedBytes`，PCM16 单声道）。
    ///   传 nil 表示不做交叉核对（例如调用方尚未落字节时只核状态与 revision）。
    public static func evaluate(
        receipt: RenderReceipt,
        expectation: Expectation = Expectation(),
        receivedBytes: Int? = nil
    ) -> Verdict {
        switch receipt.status {
        case .completed:
            break
        case .pending:
            return .unknown(reason: "receipt_status_pending")
        case .cancelled:
            // cancelled 只证明服务端记了取消，不证明资源已释放
            //（外层取消路径可能先记 cancelled 再执行 stream close，见 #243）。
            return .unknown(reason: "receipt_status_cancelled")
        case .error:
            return .unknown(reason: "receipt_status_error")
        case let .unknown(raw):
            return .unknown(reason: "receipt_status_\(raw)")
        }
        if let expected = expectation.expectedVoiceRevision,
           receipt.voiceRevision != expected {
            return .unknown(reason: "voice_revision_mismatch")
        }
        if let expected = expectation.expectedModelRevision,
           receipt.modelCatalogRevision != expected {
            return .unknown(reason: "model_revision_mismatch")
        }
        guard let samples = receipt.audioSampleCount, samples > 0 else {
            // 零样本 completed（服务端 `complete()` 在零样本 pending 上记
            // `error/empty_audio`，此处是 completed 却无样本——同样不能播）。
            return .unknown(reason: "receipt_empty_audio")
        }
        if let receivedBytes, receivedBytes != samples * 2 {
            return .unknown(reason: "receipt_sample_count_mismatch")
        }
        guard receipt.pcmSHA256 != nil else {
            // 有样本但无摘要：无法把手里这段音频锚定到服务端交付的那段
            //（`provenance(for:)` 同样要求 `audio_digest_missing` 时只给 partial）。
            return .unknown(reason: "audio_digest_missing")
        }
        return .deliverable
    }
}

public extension RenderReceipt {
    /// 服务端制品 revision（receipt `model.catalog_revision`）：
    /// 与 `assistantInteractiveSpeechOptions` 的 `expectedModelRevision`
    /// 同源（`begin()` 要求它等于 recipe 的 `model.artifact_revision`，
    /// 分叉直接拒绝——此处只读 header，不替服务端做二次拼接）。
    var modelCatalogRevision: String? {
        model.string("catalog_revision")
    }

    /// 服务端在 PCM 传输前累计的样本数（receipt `audio.sample_count`）。
    var audioSampleCount: Int? {
        audio.integer("sample_count")
    }
}

private extension JSONValue {
    /// 取对象里的一个整数；不是对象、字段不是整数时返回 `nil`。
    /// Double 不塌成 Int：样本数是精确计数，不做浮点截断。
    func integer(_ key: String) -> Int? {
        guard case let .object(fields) = storage,
              case let .integer(value) = fields[key]?.storage
        else { return nil }
        return Int(exactly: value)
    }
}
