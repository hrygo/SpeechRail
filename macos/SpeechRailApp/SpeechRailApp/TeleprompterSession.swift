import Foundation
import Observation
import SpeechRailControlKit

@MainActor
@Observable
public final class TeleprompterSession {
    public enum Phase: String, Sendable, Equatable {
        case draft
        case analyzing
        case review
        case ready
        case preparing
        case following
        case paused
        case uncertain
        case manual
        case ended
    }

    public enum BlockReason: Equatable, Sendable {
        case noActiveVersion
        case microphoneDenied
        case serviceNotReady(String)
        case serviceBusy(String)
        case occupiedBy(SessionKind)
        case streamFailed(String)
        case aiUnavailable(String)
        case storeUnavailable(String)

        public var title: String {
            switch self {
            case .noActiveVersion: "还没有活动稿件版本"
            case .microphoneDenied: "麦克风未授权"
            case .serviceNotReady: "语音服务未就绪"
            case .serviceBusy: "语音服务正忙"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .streamFailed: "自动跟读已暂停"
            case .aiUnavailable: "AI 整理不可用"
            case .storeUnavailable: "提词稿保存失败"
            }
        }

        public var detail: String {
            switch self {
            case .noActiveVersion:
                "请先确认一版稿件，或使用纯文本分段。"
            case .microphoneDenied:
                "在系统设置里允许 SpeechRail 使用麦克风，然后重试；手动提词仍可用。"
            case .serviceNotReady(let message), .serviceBusy(let message), .streamFailed(let message),
                 .aiUnavailable(let message), .storeUnavailable(let message):
                message
            case .occupiedBy(let kind):
                "结束\(kind.title)后才能开始自动跟读；当前仍可手动提词。"
            }
        }
    }

    public enum ServiceReadiness: Sendable {
        case ready(profile: String?)
        case notReady(String)
    }

    public private(set) var phase: Phase = .draft
    public private(set) var blocked: BlockReason?
    public private(set) var document: TeleprompterDocument?
    public private(set) var versions: [TeleprompterVersion] = []
    public private(set) var pendingVersion: TeleprompterVersion?
    public private(set) var partialText: String?
    public private(set) var currentSegmentIndex = 0
    public private(set) var uncertainty: Double?
    public private(set) var lastFailure: String?

    public var activeVersion: TeleprompterVersion? {
        guard let activeID = document?.activeVersionID else { return nil }
        return versions.first { $0.id == activeID }
    }

    public var currentSegment: TeleprompterSegment? {
        guard let segments = activeVersion?.segments, segments.indices.contains(currentSegmentIndex) else {
            return nil
        }
        return segments[currentSegmentIndex]
    }

    public var progressText: String {
        guard let count = activeVersion?.segments.count, count > 0 else { return "未开始" }
        return "第 \(min(currentSegmentIndex + 1, count)) / \(count) 段"
    }

    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    public var aiClient: TeleprompterAIClient?

    private let coordinator: SessionCoordinator
    private let store: TeleprompterStore
    private let port: Int
    private let apiKey: String?
    private var source: AudioChunkSource?
    private var client: RealtimeASRClient?
    private var pump: Task<Void, Never>?
    private var followController = TeleprompterFollowController()
    private var isStoppingIntentionally = false

    public init(
        coordinator: SessionCoordinator,
        store: TeleprompterStore,
        port: Int = 8201,
        apiKey: String? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil
    ) {
        self.coordinator = coordinator
        self.store = store
        self.port = port
        self.apiKey = apiKey
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public func listDocuments() throws -> [TeleprompterDocument] {
        try store.listDocuments()
    }

    public func load(documentID: String) throws {
        let bundle = try store.loadBundle(documentID: documentID)
        document = bundle.document
        versions = bundle.versions
        pendingVersion = nil
        let restoredIndex = bundle.runState.flatMap { state in
            activeVersion?.segments.firstIndex { $0.id == state.currentSegmentID }
        } ?? 0
        currentSegmentIndex = restoredIndex
        followController = TeleprompterFollowController(
            currentIndex: restoredIndex,
            mode: bundle.runState?.mode ?? .manual
        )
        phase = activeVersion == nil ? .draft : .ready
        blocked = nil
    }

    public func createDocument(title: String, sourceText: String) {
        let now = Date()
        document = TeleprompterDocument(
            id: UUID().uuidString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名提词稿" : title,
            sourceText: sourceText,
            createdAt: now,
            updatedAt: now
        )
        versions = []
        pendingVersion = nil
        currentSegmentIndex = 0
        phase = .draft
        blocked = nil
        lastFailure = nil
    }

    public func deleteDocument(documentID: String) throws {
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        try store.deleteDocument(documentID: documentID)
        if document?.id == documentID {
            let remaining = try store.listDocuments()
            if let first = remaining.first {
                try load(documentID: first.id)
            } else {
                document = nil
                versions = []
                pendingVersion = nil
                currentSegmentIndex = 0
                phase = .draft
                blocked = nil
            }
        }
    }

    public func duplicateDocument(documentID: String) throws -> TeleprompterDocument {
        guard phase != .following, phase != .paused, phase != .uncertain else {
            throw TeleprompterTextError.emptySource
        }
        let newBundle = try store.duplicateDocument(documentID: documentID)
        try load(documentID: newBundle.document.id)
        return newBundle.document
    }

    public func exportMarkdown() -> String? {
        guard let document else { return nil }
        let bundle = TeleprompterDocumentBundle(
            document: document,
            versions: versions,
            runState: nil
        )
        return store.exportMarkdown(bundle)
    }

    public func updateTitle(_ title: String) {
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.title = title
        document?.updatedAt = Date()
    }

    public func updateSourceText(_ sourceText: String) {
        guard phase != .following, phase != .paused, phase != .uncertain else { return }
        document?.sourceText = sourceText
        document?.updatedAt = Date()
        pendingVersion = nil
        phase = .draft
    }

    public func useDeterministicFallback() throws {
        guard var document else { throw TeleprompterTextError.emptySource }
        let segments = try TeleprompterSegmenter.segment(sourceText: document.sourceText)
        let version = TeleprompterVersion(
            id: UUID().uuidString,
            documentID: document.id,
            sourceText: document.sourceText,
            segments: segments,
            analysisSource: .deterministic
        )
        versions.append(version)
        document.activeVersionID = version.id
        document.updatedAt = Date()
        self.document = document
        pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        phase = .ready
        blocked = nil
        try saveBundle()
    }

    public func analyzeDraft(language: String? = nil, style: String? = nil) async {
        guard let document else {
            blocked = .aiUnavailable("请先创建提词稿。")
            return
        }
        guard let aiClient else {
            blocked = .aiUnavailable("尚未配置可用的 Responses-compatible AI；可以使用纯文本分段。")
            return
        }
        phase = .analyzing
        blocked = nil
        do {
            let analysis = try await aiClient.analyze(
                TeleprompterAnalysisRequest(
                    sourceText: document.sourceText,
                    language: language,
                    style: style
                )
            )
            pendingVersion = TeleprompterVersion(
                id: UUID().uuidString,
                documentID: document.id,
                sourceText: document.sourceText,
                segments: analysis.segments,
                analysisSource: .ai
            )
            phase = .review
        } catch {
            blocked = .aiUnavailable(Self.aiFailureMessage(for: error))
            phase = .draft
        }
    }

    public func acceptPendingVersion() throws {
        guard let pendingVersion, var document else {
            throw TeleprompterTextError.invalidAnalysis
        }
        versions.append(pendingVersion)
        document.activeVersionID = pendingVersion.id
        document.updatedAt = Date()
        self.document = document
        self.pendingVersion = nil
        currentSegmentIndex = 0
        followController = TeleprompterFollowController()
        phase = .ready
        blocked = nil
        try saveBundle()
    }

    public func discardPendingVersion() {
        pendingVersion = nil
        phase = activeVersion == nil ? .draft : .ready
    }

    public func updatePendingSegment(id: String, text: String) {
        guard let pendingVersion,
              let index = pendingVersion.segments.firstIndex(where: { $0.id == id }) else { return }
        var segments = pendingVersion.segments
        segments[index].text = text
        self.pendingVersion = TeleprompterVersion(
            id: pendingVersion.id,
            documentID: pendingVersion.documentID,
            sourceText: pendingVersion.sourceText,
            segments: segments,
            analysisSource: .user,
            createdAt: pendingVersion.createdAt
        )
    }

    public func beginFollowing() async {
        guard activeVersion != nil else {
            blocked = .noActiveVersion
            phase = .manual
            return
        }
        if let occupancy = coordinator.occupancy, occupancy.kind != .teleprompter {
            blocked = .occupiedBy(occupancy.kind)
            phase = .manual
            return
        }
        blocked = nil
        await coordinator.requestStart(.teleprompter)
    }

    /// SessionCoordinator 的 starter：此时已取得 `.teleprompter` 占用，但还没有持久化记录。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        lastFailure = nil
        do {
            try await startPipeline()
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            phase = .manual
            throw Blocked(reason: reason)
        }
    }

    public func pauseFollowing() {
        guard phase == .following || phase == .uncertain else { return }
        followController.pause()
        syncFollowState()
        phase = .paused
        saveProgress()
    }

    public func resumeFollowing() {
        guard phase == .paused || phase == .manual || phase == .uncertain else { return }
        followController.resume()
        syncFollowState()
        phase = .following
        blocked = nil
        saveProgress()
    }

    public func moveToPrevious() {
        guard let count = activeVersion?.segments.count else { return }
        followController.move(to: currentSegmentIndex - 1, segmentCount: count)
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    public func moveToNext() {
        guard let count = activeVersion?.segments.count else { return }
        followController.move(to: currentSegmentIndex + 1, segmentCount: count)
        syncFollowState()
        phase = .manual
        saveProgress()
    }

    public func resetFollow() {
        followController.resetFollowWindow()
        syncFollowState()
        phase = .following
        blocked = nil
        saveProgress()
    }

    public func endFollowing() async {
        if coordinator.occupancy?.kind == .teleprompter {
            await coordinator.stopCapture(endingWith: .user)
        } else {
            await stopCapture()
        }
        phase = .ended
        saveProgress()
    }

    /// SessionCoordinator 的 stopper：停止采集、关闭 ASR、只保存段落进度。
    public func stopCapture() async {
        guard !isStoppingIntentionally else { return }
        isStoppingIntentionally = true
        source?.stop()
        source = nil
        if let client {
            do {
                try await client.drainAndClear(timeout: .seconds(8))
            } catch {
                lastFailure = error.localizedDescription
            }
            await client.close()
        }
        client = nil
        pump?.cancel()
        pump = nil
        partialText = nil
        followController.resetFollowWindow()
        syncFollowState()
        saveProgress()
        isStoppingIntentionally = false
    }

    private func startPipeline() async throws {
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .ready:
                break
            case .notReady(let message):
                throw Blocked(reason: .serviceNotReady(message))
            }
        }

        let source = audioSourceFactory()
        self.source = source
        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(reason: Self.blockReason(for: error))
        }

        let client = RealtimeASRClient(
            port: port,
            silenceDurationMilliseconds: 400,
            diarizationEnabled: false,
            apiKey: apiKey
        )
        do {
            try await client.connect()
        } catch {
            source.stop()
            self.source = nil
            throw Blocked(reason: .serviceNotReady(error.localizedDescription))
        }

        self.client = client
        isStoppingIntentionally = false
        partialText = nil
        uncertainty = nil
        coordinator.sessionDidStartRecording(id: nil)
        followController.resume()
        syncFollowState()
        phase = .following
        startPump(stream: stream, client: client)
    }

    private func startPump(stream: AsyncStream<AudioChunk>, client: RealtimeASRClient) {
        pump?.cancel()
        pump = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await chunk in stream {
                        guard let self else { return }
                        await self.upload(chunk, to: client)
                    }
                }
                group.addTask { [weak self] in
                    let events = await client.events()
                    for await envelope in events {
                        guard let self else { return }
                        await self.handle(envelope)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func upload(_ chunk: AudioChunk, to client: RealtimeASRClient) async {
        guard !isStoppingIntentionally else { return }
        do {
            try await client.append(chunk.pcm)
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>
    ) async {
        switch envelope.payload {
        case .partial(_, let delta):
            partialText = (partialText ?? "") + delta
            followController.receivePartial(partialText ?? "")
            syncFollowState()
        case .completed(_, let transcript, _):
            guard let activeVersion else { return }
            followController.receiveCompleted(
                transcript,
                segments: activeVersion.segments,
                aligner: TeleprompterAligner()
            )
            syncFollowState()
            phase = uncertainty == nil ? (followController.mode == .following ? .following : .manual) : .uncertain
        case .serverError(let code, let message, _, _, _, _):
            if code == "backend_busy" {
                await enterManual(.serviceBusy(message))
            } else {
                lastFailure = message
            }
        case .failed(_, let code, let message):
            await enterManual(.streamFailed("\(code)：\(message)"))
        case .closed:
            if !isStoppingIntentionally {
                await enterManual(.streamFailed("Realtime 连接已断开，可以手动继续或重试。"))
            }
        default:
            break
        }
    }

    private func enterManual(_ reason: BlockReason) async {
        source?.stop()
        source = nil
        await client?.close()
        client = nil
        pump?.cancel()
        pump = nil
        followController.enterManual()
        syncFollowState()
        blocked = reason
        phase = .manual
        saveProgress()
    }

    private func syncFollowState() {
        currentSegmentIndex = followController.currentIndex
        partialText = followController.partialPreview
        uncertainty = followController.uncertainty
    }

    private func saveProgress() {
        guard let document, let activeVersion else { return }
        do {
            try store.updateRunState(
                TeleprompterRunState(
                    documentID: document.id,
                    versionID: activeVersion.id,
                    currentSegmentID: currentSegment?.id,
                    mode: followController.mode
                )
            )
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func saveBundle() throws {
        guard let document else { throw TeleprompterStoreError.invalidBundle }
        try store.saveBundle(
            TeleprompterDocumentBundle(
                document: document,
                versions: versions,
                runState: nil
            )
        )
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let blocked = error as? Blocked { return blocked.reason }
        return .serviceNotReady(error.localizedDescription)
    }

    private static func aiFailureMessage(for error: Error) -> String {
        if let error = error as? LLMError,
           error == .unsupportedStructuredOutput {
            return "当前 AI 服务不支持严格结构化输出。请更换 Responses-compatible endpoint，或改用纯文本分段；原稿未改变。"
        }
        return "AI 没有返回可采用的结构化结果，原稿未改变。可以改用纯文本分段。"
    }

    private struct Blocked: Error {
        let reason: BlockReason
    }
}
