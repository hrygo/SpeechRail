import Foundation

/// #267 §6.0 边界 4：完整文本 adapter 的取消/设备/结束屏障。
///
/// 生产链纪律（增量路径 M0c/M0d 已有，本 helper 为完整文本路径复用同一语义）：
/// 取消先撤 epoch、停播，再按共同期限清理；设备恢复须确认旧远端收尾；
/// 两条播放器唯一记账，拒绝旧回调；played 覆盖全部提交样本才完成，
/// 取消/失效/未知均为 incomplete。
///
/// 本 helper 是纯 additive 的结束屏障：调用方在边界 2（有界接收）与边界 3
///（receipt 核对）通过后、向播放层提交前登记 `commit(samples:)`，
/// 播放回调到达时调用 `notePlayed(samples:chunkID:)`（chunkID 去重，
/// 重复回调只记一次）；取消/设备失效时调用 `invalidate()`，
/// 此后一切回调作废、一切新合成禁止，直到调用方显式重试。
/// 现有 `AssistantTTSStreamCoordinator/AssistantSession` 签名零改动；
/// `usesFullTextSpeechForTest` 保持 false，门禁测试不断言启用。
public final class FullTextPlaybackGate: @unchecked Sendable {
    /// 结束结论：只有全部提交样本 played 才完成，其余一律 incomplete。
    public enum Completion: Equatable, Sendable {
        /// 全部提交样本已 played，可以宣布完成。
        case completed
        /// 尚未完成（进行中、已取消、已失效、证据未知）——调用方按 incomplete 处理。
        case incomplete(reason: String)
    }

    private let lock = NSLock()
    private var committedSamples = 0
    private var playedSamples = 0
    private var seenChunkIDs = Set<UUID>()
    private var invalidated = false
    private var invalidateReason: String?

    public init() {}

    /// 提交一批待播样本。invalidate 之后提交无效（返回 false），
    /// 调用方不得开新合成，转显式重试。
    @discardableResult
    public func commit(samples: Int) -> Bool {
        guard samples > 0 else { return false }
        return lock.withLock {
            guard !invalidated else { return false }
            committedSamples += samples
            return true
        }
    }

    /// 播放层 played 回调。旧 epoch/重复 chunkID/超量一律拒绝记账：
    /// 无效回调返回 false，已知账本不动。
    @discardableResult
    public func notePlayed(samples: Int, chunkID: UUID) -> Bool {
        guard samples > 0 else { return false }
        return lock.withLock {
            guard !invalidated else { return false }
            guard !seenChunkIDs.contains(chunkID) else { return false }
            guard playedSamples + samples <= committedSamples else { return false }
            seenChunkIDs.insert(chunkID)
            playedSamples += samples
            return true
        }
    }

    /// 本地先撤 epoch 并 stop 对应的逻辑点：调用方执行完实际撤权/停播后
    /// 调用此法标记旧请求死亡。此后一切回调作废、一切提交拒绝。
    public func invalidate(reason: String = "cancelled") {
        lock.withLock {
            invalidated = true
            invalidateReason = reason
        }
    }

    /// 当前完成结论：played 覆盖全部提交样本才 completed，
    /// 否则一律 incomplete（取消/失效/未知/进行中不区分完成度，只给原因）。
    public func completion() -> Completion {
        lock.withLock {
            if invalidated {
                return .incomplete(reason: invalidateReason ?? "cancelled")
            }
            guard committedSamples > 0, playedSamples >= committedSamples else {
                return .incomplete(reason: "awaiting_played")
            }
            return .completed
        }
    }

    /// 调试/断言用：已提交、已 played 样本数。
    public func snapshot() -> (committed: Int, played: Int, invalidated: Bool) {
        lock.withLock { (committedSamples, playedSamples, invalidated) }
    }
}
