import Foundation

/// 试听音频缓存的资源上限。
public enum VoicePreviewCacheLimits {
    /// 24 MB 足够缓存几十段短试听，又不会让长时间使用把内存吃满；超出后按
    /// 写入顺序淘汰最旧条目。
    public static let byteLimit = 24 * 1024 * 1024
}

/// 一次试听请求在**发出当时**可知的身份。
///
/// 键必须覆盖音色与模型的版本：只用 `voiceID + speed + text` 时，音色被撤销、
/// 重新生成或服务换用另一份模型之后，旧音频仍会命中并播放——用户听到的是一
/// 段已经没有来源的录音。
///
/// `planID` / receipt 是生成**之后**才拿到的，只能用于结果校验与追溯，不能
/// 参与前置缓存键。
public struct VoicePreviewCacheKey: Hashable, Sendable {
    public let canonicalVoiceID: String
    /// 声学音色 revision。系统 / legacy 音色没有 revision 时用目录或能力 epoch
    /// 隔离，**不制造假 revision**。
    public let voiceRevision: String?
    public let catalogEpoch: String?
    public let runtimeEpoch: String?
    public let input: String
    /// `nil` 表示交给后端 `auto`。
    public let languageOverride: String?
    public let speed: Double
    public let responseFormat: String

    public init(
        canonicalVoiceID: String,
        voiceRevision: String? = nil,
        catalogEpoch: String? = nil,
        runtimeEpoch: String? = nil,
        input: String,
        languageOverride: String? = nil,
        speed: Double,
        responseFormat: String = "wav"
    ) {
        self.canonicalVoiceID = canonicalVoiceID
        self.voiceRevision = voiceRevision
        self.catalogEpoch = catalogEpoch
        self.runtimeEpoch = runtimeEpoch
        self.input = input
        self.languageOverride = languageOverride
        self.speed = speed
        self.responseFormat = responseFormat
    }
}

/// 有内存上限的试听音频缓存，按写入顺序淘汰最旧条目。
///
/// 只接受解码通过、非空的完整结果：空音频、失败回包和已取消请求都不进缓存。
public struct VoicePreviewAudioCache: Sendable {
    public let byteLimit: Int
    private var entries: [VoicePreviewCacheKey: Data] = [:]
    private var insertionOrder: [VoicePreviewCacheKey] = []
    private var bytes = 0

    public init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    public var count: Int { entries.count }
    public var totalBytes: Int { bytes }

    public func data(for key: VoicePreviewCacheKey) -> Data? {
        entries[key]
    }

    /// 返回是否真的写入。空数据、超大条目一律拒绝。
    @discardableResult
    public mutating func insert(_ data: Data, for key: VoicePreviewCacheKey) -> Bool {
        guard !data.isEmpty else { return false }
        if let existing = entries[key] {
            guard existing != data else { return true }
            bytes -= existing.count
            insertionOrder.removeAll { $0 == key }
        }
        guard data.count <= byteLimit else { return false }
        entries[key] = data
        insertionOrder.append(key)
        bytes += data.count
        evictIfNeeded()
        return true
    }

    public mutating func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        bytes = 0
    }

    private mutating func evictIfNeeded() {
        while bytes > byteLimit, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                bytes -= removed.count
            }
        }
    }
}
