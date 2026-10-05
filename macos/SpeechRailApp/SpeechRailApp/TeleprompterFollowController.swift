import Foundation
import SpeechRailControlKit

/// Bounded, in-memory latency evidence for one teleprompter run.
///
/// It deliberately stores only timings and counts: no item IDs, transcript text,
/// audio, or text-derived identifiers are retained.
public struct TeleprompterLatencyDiagnostics: Sendable, Equatable {
    public private(set) var alignmentSampleCount = 0
    public private(set) var captureSampleCount = 0

    private let maxSamples: Int
    private var queueAgeSamples: [Double] = []
    private var matchSamples: [Double] = []
    private var captureToSendSamples: [Double] = []

    public init(maxSamples: Int = 128) {
        self.maxSamples = max(1, maxSamples)
    }

    public var queueAgeP95Milliseconds: Double? {
        percentile(queueAgeSamples)
    }

    public var matchP95Milliseconds: Double? {
        percentile(matchSamples)
    }

    public var captureToSendP95Milliseconds: Double? {
        percentile(captureToSendSamples)
    }

    public mutating func recordAlignment(
        queueAgeMilliseconds: Double,
        matchMilliseconds: Double
    ) {
        guard valid(queueAgeMilliseconds), valid(matchMilliseconds) else { return }
        append(queueAgeMilliseconds, to: &queueAgeSamples)
        append(matchMilliseconds, to: &matchSamples)
        alignmentSampleCount = queueAgeSamples.count
    }

    public mutating func recordCaptureToSend(milliseconds: Double) {
        guard valid(milliseconds) else { return }
        append(milliseconds, to: &captureToSendSamples)
        captureSampleCount = captureToSendSamples.count
    }

    private func valid(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private func append(_ value: Double, to samples: inout [Double]) {
        samples.append(value)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    private func percentile(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }
}

public enum TeleprompterFollowState: Equatable, Sendable {
    case waitingForSpeech
    case listening
    case tracking
    case catchingUp
    case freePlaying
    case paused
    case manual
}

public enum TeleprompterFollowPresentation {
    public static func statusText(for state: TeleprompterFollowState) -> String {
        switch state {
        case .waitingForSpeech: "等待声音请开讲…"
        case .listening: "听见你了，正在跟上稿件…"
        case .tracking: "跟读咬合"
        case .catchingUp: "正在跟上稿件"
        case .freePlaying: "自由发挥中"
        case .paused: "已暂停"
        case .manual: "手动浏览中"
        }
    }
}

/// Injectable evidence thresholds for provisional movement and recovery.
public struct TeleprompterFollowPolicy: Equatable, Sendable {
    public let provisionalMinimumConfidence: Double
    public let provisionalMinimumMatches: Int
    public let freePlayAfterMisses: Int
    public let reanchorMargin: Double
    public let localAdvanceTokenRadius: Int
    public let relocalizationMinimumMatches: Int

    public init(
        provisionalMinimumConfidence: Double = 0.72,
        provisionalMinimumMatches: Int = 2,
        freePlayAfterMisses: Int = 2,
        reanchorMargin: Double = 0.12,
        localAdvanceTokenRadius: Int = 24,
        relocalizationMinimumMatches: Int = 4
    ) {
        self.provisionalMinimumConfidence = provisionalMinimumConfidence.isFinite
            ? min(1, max(0, provisionalMinimumConfidence)) : 0.72
        self.provisionalMinimumMatches = max(1, provisionalMinimumMatches)
        self.freePlayAfterMisses = max(1, freePlayAfterMisses)
        self.reanchorMargin = reanchorMargin.isFinite ? min(1, max(0, reanchorMargin)) : 0.12
        self.localAdvanceTokenRadius = max(0, min(320, localAdvanceTokenRadius))
        self.relocalizationMinimumMatches = max(1, relocalizationMinimumMatches)
    }
}

/// Pure event reducer. ASR text is bounded, in-memory only, and scoped to item IDs.
public struct TeleprompterFollowController: Sendable {
    public private(set) var committedPosition: TeleprompterAligner.Position
    public private(set) var viewportAnchor: TeleprompterAligner.Position
    public var position: TeleprompterAligner.Position { viewportAnchor }
    public var currentIndex: Int { viewportAnchor.segmentIndex }
    public private(set) var candidatePosition: TeleprompterAligner.Position?
    public var hypothesisPosition: TeleprompterAligner.Position? { candidatePosition }
    public private(set) var mode: TeleprompterRunMode
    public private(set) var uncertainty: Double?
    public private(set) var partialPreview: String?
    public private(set) var followState: TeleprompterFollowState
    public private(set) var lastMatchConfidence: Double?
    public private(set) var lastMatchedCount = 0
    /// 最近一次 snapshot 实际用于稳定对齐的 Unicode scalar 数（测试可见）。
    /// `nil` 表示最近一次 snapshot 未使用稳定前缀路径。
    public private(set) var lastStableAlignedScalarCount: Int?
    /// F-15 要求稳定前缀的契约异常**可见**。修复前越界被折成 nil，异常从外面
    /// 完全看不出来——报告、回放与界面都以为那只是一段没有稳定前缀的话。
    public private(set) var stablePrefixContractAnomalies = 0

    private struct Item: Sendable {
        var text: String
        let anchor: TeleprompterAligner.Position
        let sequence: Int
        var snapshotRevision = 0
        var stablePrefixCodepoints: Int?
        var sampleSpan: RealtimeASRClient.RealtimeSampleSpan?
        /// 最近一次有效试探位置（E3 同位确认用）。只在 snapshot 实际推进
        /// 视口或确认同位时更新；final 消费后由调用方清理。
        var lastPreviewedPosition: TeleprompterAligner.Position?
    }
    private var items: [String: Item] = [:]
    private var retired: [String] = []
    private var eventIDs: [String] = []
    private var history: [String] = []
    private var script: TeleprompterAligner.Script?
    private var scriptSegments: [TeleprompterSegment] = []
    private let policy: TeleprompterFollowPolicy
    private let aligner: TeleprompterAligner
    private var lowConfidenceStreak = 0
    private var nextSequence = 0
    private var finalizedSequence = -1
    private var provisionalItemID: String?

    public init(
        currentIndex: Int = 0,
        mode: TeleprompterRunMode = .following,
        policy: TeleprompterFollowPolicy = .init()
    ) {
        let initialPosition = TeleprompterAligner.Position(segmentIndex: max(0, currentIndex), utf16Offset: 0)
        committedPosition = initialPosition
        viewportAnchor = initialPosition
        self.mode = mode
        self.policy = policy
        aligner = TeleprompterAligner(configuration: .init(advanceMargin: policy.reanchorMargin))
        switch mode {
        case .following: followState = .waitingForSpeech
        case .paused: followState = .paused
        case .manual: followState = .manual
        }
    }

    public mutating func noteSpeechStarted() {
        guard mode == .following, followState == .waitingForSpeech else { return }
        followState = .listening
    }

    public mutating func receivePartial(
        itemID: String,
        delta: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        var item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        item.text = String((item.text + delta).suffix(2048))
        partialPreview = item.text
        if followState == .waitingForSpeech { followState = .listening }
        let match = locate(TeleprompterCanonicalizer.values(item.text), script: script, anchor: position)
        let viewportBeforePreview = viewportAnchor
        applyPreviewMatch(match, itemID: itemID)
        // 试探推进（前进或同位确认）记到即将写回的 item 上，供 final 同位
        // 确认核对“同 item 且试探位置仍有效”。apply 内部不碰 items。
        // 条件用“试探后视口位置有有效候选”：前进时 viewport 已变；
        // 同位试探时 viewport 不变但 candidate 落在当前位置。
        if viewportAnchor != viewportBeforePreview
            || (candidatePosition == viewportAnchor
                && match.position == viewportAnchor) {
            item.lastPreviewedPosition = viewportAnchor
        }
        items[itemID] = item
        if items.count > 8, let oldest = items.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            retire(oldest)
        }
    }

    public mutating func receiveSnapshot(
        itemID: String,
        revision: Int,
        text: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil,
        stablePrefixCodepoints: Int? = nil,
        sampleSpan: RealtimeASRClient.RealtimeSampleSpan? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard revision > 0, !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        var item = item(for: itemID)
        guard item.sequence > finalizedSequence, revision > item.snapshotRevision else { return }
        item.snapshotRevision = revision
        // 稳定前缀是**当前原始 ASR 文本**的 Unicode scalar 数（方案 §3.6），
        // 所以契约校验对着进来的原文做，而不是 `suffix(2048)` 之后存下来的文本。
        //
        // 这里要把话说准：改这一处**本身不改变任何匹配结果**。前缀只要不小于存
        // 下来的长度，取稳定前缀与直接对齐整段存文本得到的是同一段字符串；小于
        // 时两种写法取的也是同一个数。真正改变行为的只有下面那个 guard——**越界**。
        let rawScalarCount = text.unicodeScalars.count
        item.text = String(text.suffix(2048))
        // 这两行放在守卫之前：契约异常也要**能指到是哪段音频**，否则「可见」只剩
        // 一个计数器, 复核的人拿不到对应的 sample span.
        item.sampleSpan = sampleSpan
        partialPreview = item.text
        if let stablePrefixCodepoints {
            // F-15：「稳定前缀越界或改写 → 契约异常可见，暂停推进而非伪造稳定性」。
            // 修复前把越界一律折成 nil，于是 else 分支拿**全文**对齐——比「不推进」
            // 更宽松，方向正好相反。
            guard stablePrefixCodepoints >= 0, stablePrefixCodepoints <= rawScalarCount else {
                item.stablePrefixCodepoints = nil
                stablePrefixContractAnomalies += 1
                uncertainty = 1
                if followState != .freePlaying { followState = .catchingUp }
                items[itemID] = item
                return
            }
            // 越过契约校验之后做截断坐标换算：存下来的是原文的后缀，
            // 原前缀落在它里面的部分 = 原前缀 − 丢弃数，再夹到保留区范围内。
            // 旧公式 min(stable, retainedCount) 漏减丢弃数（E2/F03）。
            let rawScalarCountForMapping = rawScalarCount
            let retainedScalarCount = item.text.unicodeScalars.count
            let droppedScalarCount = rawScalarCountForMapping - retainedScalarCount
            item.stablePrefixCodepoints = min(
                max(0, stablePrefixCodepoints - droppedScalarCount),
                retainedScalarCount
            )
        } else {
            item.stablePrefixCodepoints = nil
        }
        if followState == .waitingForSpeech { followState = .listening }
        let match: TeleprompterAligner.Match
        if let stablePrefixCodepoints = item.stablePrefixCodepoints,
           stablePrefixCodepoints > 0 {
            lastStableAlignedScalarCount = stablePrefixCodepoints
            let stableScalars = item.text.unicodeScalars.prefix(stablePrefixCodepoints)
            let stableText = String(stableScalars)
            match = locate(
                TeleprompterCanonicalizer.values(stableText),
                script: script,
                anchor: position
            )
        } else {
            lastStableAlignedScalarCount = nil
            match = locate(
                TeleprompterCanonicalizer.values(item.text),
                script: script,
                anchor: position
            )
        }
        let viewportBeforePreview = viewportAnchor
        applyPreviewMatch(match, itemID: itemID)
        // 与 receivePartial 同规则：试探推进（前进或同位）记到即将写回的
        // item 上，供 final 同位确认核对“同 item 且试探位置仍有效”。
        // apply 内部不碰 items，试探位置由调用方在写回前记录。
        if viewportAnchor != viewportBeforePreview
            || (candidatePosition == viewportAnchor
                && match.position == viewportAnchor) {
            item.lastPreviewedPosition = viewportAnchor
        }
        items[itemID] = item
        if items.count > 8, let oldest = items.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            retire(oldest)
        }
    }

    public mutating func receiveCompleted(
        itemID: String,
        transcript: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        let item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        finalizedSequence = item.sequence
        let anchor = item.anchor
        let tokens = TeleprompterCanonicalizer.values(transcript)
        partialPreview = nil
        if followState == .waitingForSpeech { followState = .listening }

        guard !tokens.isEmpty else {
            // E3/F05 空 final：保位、不提交。若该 item 此前有非空假设
            // （snapshot 文本或试探位置），给出可观察的未确认状态，
            // 不再沿用 tracking；无先前内容则不虚构“用户说过话”。
            let hadPriorEvidence = !item.text.isEmpty || item.lastPreviewedPosition != nil
            provisionalItemID = nil
            candidatePosition = nil
            if hadPriorEvidence {
                uncertainty = 1
                if followState != .freePlaying { followState = .catchingUp }
            }
            retire(itemID)
            return
        }

        var match = locate(tokens, script: script, anchor: position)
        if match.position == nil, anchor != position {
            let anchoredMatch = locate(tokens, script: script, anchor: anchor)
            if anchoredMatch.position != nil { match = anchoredMatch }
        }
        candidatePosition = match.position
        lastMatchConfidence = match.confidence
        lastMatchedCount = match.matchedCount

        if let candidate = match.position,
           mayConfirm(match, candidate: candidate, finalItemID: itemID, previewed: item.lastPreviewedPosition) {
            let movesViewportForward = isForward(candidate, from: viewportAnchor)
            let isControlledReread = !movesViewportForward
            committedPosition = candidate
            if movesViewportForward || isControlledReread {
                viewportAnchor = candidate
            }
            provisionalItemID = nil
            uncertainty = nil
            lowConfidenceStreak = 0
            followState = .tracking
            history = Array((history + tokens).suffix(48))
        } else if match.position != nil {
            uncertainty = match.confidence
            provisionalItemID = nil
            if followState != .freePlaying { followState = .catchingUp }
        } else if tokens.count + history.count < 3 {
            history = Array((history + tokens).suffix(24))
            provisionalItemID = nil
            candidatePosition = nil
            uncertainty = nil
            if followState != .freePlaying { followState = .listening }
        } else {
            recordFinalMiss(match)
        }
        retire(itemID)
    }

    private func locate(
        _ tokens: [String],
        script: TeleprompterAligner.Script,
        anchor: TeleprompterAligner.Position
    ) -> TeleprompterAligner.Match {
        let current = aligner.locate(tokens: tokens, script: script, anchor: anchor)
        if current.position != nil { return current }
        guard !history.isEmpty, tokens.count < 3 || current.confidence > 0 else { return current }
        return aligner.locate(tokens: Array(history.suffix(24)) + tokens, script: script, anchor: anchor)
    }

    private mutating func applyPreviewMatch(
        _ match: TeleprompterAligner.Match,
        itemID: String
    ) {
        candidatePosition = match.position
        lastMatchConfidence = match.confidence
        lastMatchedCount = match.matchedCount

        guard let candidate = match.position else {
            uncertainty = match.confidence
            if followState != .freePlaying { followState = .catchingUp }
            return
        }

        guard mayAdvance(match) else {
            uncertainty = match.confidence
            if followState != .freePlaying { followState = .catchingUp }
            return
        }

        uncertainty = nil
        if isForward(candidate, from: position) {
            viewportAnchor = candidate
            provisionalItemID = itemID
            // 注意：snapshot 调用方在 apply 之后才写回 items，此处直接读写
            // items 会拿到旧拷贝。试探位置由调用方在写回前记到局部 item 上。
            if followState != .freePlaying { followState = .tracking }
        } else if candidate == position {
            if followState != .freePlaying { followState = .tracking }
        } else if followState != .freePlaying {
            followState = .catchingUp
        }
    }

    private func mayAdvance(_ match: TeleprompterAligner.Match) -> Bool {
        guard match.position != nil else { return false }
        if match.isUniqueNearAnchor || match.isUniqueExactContinuation { return true }
        let strongMatch = match.confidence >= policy.provisionalMinimumConfidence
            && match.matchedCount >= policy.provisionalMinimumMatches
        guard strongMatch else { return false }
        if match.tokenDistanceFromAnchor <= policy.localAdvanceTokenRadius { return true }
        return followState == .freePlaying
            && match.matchedCount >= policy.relocalizationMinimumMatches
    }

    private func mayConfirm(
        _ match: TeleprompterAligner.Match,
        candidate: TeleprompterAligner.Position,
        finalItemID: String? = nil,
        previewed: TeleprompterAligner.Position? = nil
    ) -> Bool {
        if isForward(candidate, from: viewportAnchor) {
            return mayAdvance(match)
        }
        // E3/F04 同位确认：final 落在当前视口同一位置，且同 item 此前已有
        // 有效试探推进到该位置——这是确认，不是重读。fresh final 自身仍需
        // 满足有界试探门槛（mayAdvance），不把弱匹配无条件提交。
        if candidate == viewportAnchor,
           let finalItemID, let previewed, previewed == viewportAnchor,
           provisionalItemID == finalItemID {
            return mayAdvance(match)
        }
        return match.confidence >= 0.95
            && match.matchedCount >= 6
            && match.tokenDistanceFromAnchor <= policy.localAdvanceTokenRadius
    }

    private mutating func recordFinalMiss(_ match: TeleprompterAligner.Match) {
        provisionalItemID = nil
        candidatePosition = nil
        history = []
        uncertainty = match.confidence
        lowConfidenceStreak += 1
        followState = lowConfidenceStreak >= policy.freePlayAfterMisses ? .freePlaying : .catchingUp
    }

    private func isForward(
        _ candidate: TeleprompterAligner.Position,
        from current: TeleprompterAligner.Position
    ) -> Bool {
        candidate.segmentIndex > current.segmentIndex
            || (candidate.segmentIndex == current.segmentIndex
                && candidate.utf16Offset > current.utf16Offset)
    }

    private mutating func item(for id: String) -> Item {
        if let item = items[id] { return item }
        let item = Item(text: "", anchor: position, sequence: nextSequence)
        nextSequence += 1
        return item
    }

    private mutating func prepare(_ segments: [TeleprompterSegment]) {
        guard script == nil || scriptSegments != segments else { return }
        scriptSegments = segments
        script = .init(segments: segments)
        history = []
    }

    private mutating func retire(_ id: String) {
        items.removeValue(forKey: id)
        if !retired.contains(id) { retired.append(id) }
        if retired.count > 128 { retired.removeFirst(retired.count - 128) }
    }

    private mutating func acceptEvent(_ id: String?) -> Bool {
        guard let id else { return true }
        guard !eventIDs.contains(id) else { return false }
        eventIDs.append(id)
        if eventIDs.count > 128 { eventIDs.removeFirst(eventIDs.count - 128) }
        return true
    }

    private mutating func invalidatePending() {
        for id in Array(items.keys) { retire(id) }
        history = []
        partialPreview = nil
        candidatePosition = nil
        provisionalItemID = nil
        uncertainty = nil
        committedPosition = viewportAnchor
        lastMatchConfidence = nil
        lastMatchedCount = 0
        lastStableAlignedScalarCount = nil
        lowConfidenceStreak = 0
    }

    public mutating func pause() {
        invalidatePending()
        mode = .paused
        followState = .paused
    }

    public mutating func resume() {
        invalidatePending()
        mode = .following
        followState = .waitingForSpeech
    }

    public mutating func move(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        invalidatePending()
        let target = TeleprompterAligner.Position(
            segmentIndex: min(max(0, index), segmentCount - 1),
            utf16Offset: 0
        )
        viewportAnchor = target
        committedPosition = target
        mode = .manual
        followState = .manual
    }

    /// Manual movement requested by a reader. Moving within the same paragraph
    /// is a takeover, not a jump to its beginning; the current reading offset
    /// must survive boundary commands such as previous-at-first-segment.
    public mutating func manualMove(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        let target = min(max(0, index), segmentCount - 1)
        if target == position.segmentIndex {
            enterManual()
            return
        }
        move(to: target, segmentCount: segmentCount)
    }

    /// Moves to an exact source offset chosen by the reader. Offsets are UTF-16
    /// based to match `TeleprompterAligner.Position` and are clamped to the
    /// corresponding displayed segment.
    public mutating func manualMove(
        to target: TeleprompterAligner.Position,
        segmentCount: Int,
        segmentUTF16Lengths: [Int]
    ) {
        guard segmentCount > 0, segmentUTF16Lengths.count >= segmentCount else { return }
        let index = min(max(target.segmentIndex, 0), segmentCount - 1)
        let offset = min(max(target.utf16Offset, 0), max(0, segmentUTF16Lengths[index]))
        let clamped = TeleprompterAligner.Position(segmentIndex: index, utf16Offset: offset)

        if clamped == position {
            enterManual()
            return
        }

        invalidatePending()
        viewportAnchor = clamped
        committedPosition = clamped
        mode = .manual
        followState = .manual
    }

    public mutating func enterManual() {
        invalidatePending()
        mode = .manual
        followState = .manual
    }

    public mutating func resetFollowWindow() { resume() }
}


public enum TeleprompterRealtimeFollowOutcome: Equatable, Sendable {
    case aligned
    case previewed
    /// 同位确认：committed 已提交但视口未移动。调用方不得再用
    /// “视口动了”推导定位成功，必须消费实际决策结果。
    case confirmed
    /// 空 final 未确认：保位、不提交，且此前有非空假设。
    /// 无先前证据的空 final（ignored）与此不同，不虚构“用户说过话”。
    case unconfirmed
    case ignored
    case terminalFailure
}

/// Maps Realtime ASR events into the same deterministic follow reducer used by tests.
/// Event IDs are bounded and retained only in memory for duplicate suppression.
public struct TeleprompterRealtimeFollowAdapter: Sendable {
    public init() {}

    public func apply(
        _ event: RealtimeASRClient.Event,
        metadata: RealtimeEventMetadata,
        segments: [TeleprompterSegment],
        to controller: inout TeleprompterFollowController
    ) -> TeleprompterRealtimeFollowOutcome {
        switch event {
        case .partial(let itemID, let delta):
            // 当前 wire 没有 `speech_started`：第一次收到识别结果就是"开始说话了"。
            controller.noteSpeechStarted()
            let previousPosition = controller.position
            let previousPreview = controller.partialPreview
            controller.receivePartial(
                itemID: itemID,
                delta: delta,
                segments: segments,
                eventID: metadata.eventID
            )
            return controller.position != previousPosition || controller.partialPreview != previousPreview
                ? .previewed : .ignored

        case .partialSnapshot(let itemID, let revision, let text, let evidence):
            controller.noteSpeechStarted()
            let previousPosition = controller.position
            let previousPreview = controller.partialPreview
            controller.receiveSnapshot(
                itemID: itemID,
                revision: revision,
                text: text,
                segments: segments,
                eventID: metadata.eventID,
                stablePrefixCodepoints: evidence.stablePrefixCodepoints,
                sampleSpan: evidence.sampleSpan
            )
            return controller.position != previousPosition || controller.partialPreview != previousPreview
                ? .previewed : .ignored

        case .completed(let itemID, let transcript):
            let committedBefore = controller.committedPosition
            let previousPosition = controller.position
            let previousState = controller.followState
            let previousConfidence = controller.lastMatchConfidence
            let previousMatchedCount = controller.lastMatchedCount
            controller.receiveCompleted(
                itemID: itemID,
                transcript: transcript,
                segments: segments,
                eventID: metadata.eventID
            )
            // 同位确认不移动视口：committed 推进即实际确认，不能再用
            // “视口/状态/分数变化”推导，否则 committed 同位确认会被判 ignored。
            // 前进确认仍走 .aligned（视口移动即对齐）；只有“视口未动但
            // committed 已提交”才走 .confirmed，避免改变既有前进语义。
            if controller.committedPosition != committedBefore,
               controller.position == previousPosition {
                return .confirmed
            }
            // 有假设后的空 final：保位、不提交，但给出可观察未确认。
            // 用状态变化表达，不展示或落盘全文 ASR。
            if transcript.isEmpty,
               controller.followState == .catchingUp,
               previousState != .catchingUp {
                return .unconfirmed
            }
            let didAlign = controller.position != previousPosition
                || (controller.followState == .tracking
                    && (previousState != .tracking
                        || controller.lastMatchConfidence != previousConfidence
                        || controller.lastMatchedCount != previousMatchedCount))
            return didAlign ? .aligned : .ignored

        case .failed(_, _, _), .closed(_):
            return .terminalFailure

        default:
            return .ignored
        }
    }

}
