import Foundation
import Observation

/// T10：有声书收听控制器（共享唯一文件播放器、跨片段真实帧时长跳转 ±15s、0.5x…2.0x 倍速、试听抢占自动存书签、返修版本更新来源恢复）。
@MainActor
@Observable
public final class AudiobookListeningController {
    public struct ActiveFragmentPlayback: Equatable, Sendable {
        public let bookID: UUID
        public let chapterID: UUID
        public let chapterRevisionID: UUID
        public let fragmentID: UUID
        public let fragmentIndex: Int
        public let totalFragments: Int
        public let sourceRange: AudiobookSourceRange
        public let fileURL: URL
        public let nextPreloadedFileURL: URL?
        public let isPreviousRevision: Bool
        public let chapterUpdatedNotice: String?

        public init(
            bookID: UUID,
            chapterID: UUID,
            chapterRevisionID: UUID,
            fragmentID: UUID,
            fragmentIndex: Int,
            totalFragments: Int,
            sourceRange: AudiobookSourceRange,
            fileURL: URL,
            nextPreloadedFileURL: URL?,
            isPreviousRevision: Bool,
            chapterUpdatedNotice: String? = nil
        ) {
            self.bookID = bookID
            self.chapterID = chapterID
            self.chapterRevisionID = chapterRevisionID
            self.fragmentID = fragmentID
            self.fragmentIndex = fragmentIndex
            self.totalFragments = totalFragments
            self.sourceRange = sourceRange
            self.fileURL = fileURL
            self.nextPreloadedFileURL = nextPreloadedFileURL
            self.isPreviousRevision = isPreviousRevision
            self.chapterUpdatedNotice = chapterUpdatedNotice
        }
    }

    private let store: AudiobookProjectStore
    private let revisionController: AudiobookRevisionController
    private let playbackOwner: SharedPlaybackOwner

    public private(set) var activePlayback: ActiveFragmentPlayback?
    public private(set) var isPlaying: Bool = false
    public private(set) var isPaused: Bool = false
    public private(set) var playbackRate: Float = 1.0
    public private(set) var currentFragmentElapsedSeconds: TimeInterval = 0
    public private(set) var chapterElapsedSeconds: TimeInterval = 0
    public private(set) var chapterTotalDurationSeconds: TimeInterval = 0
    public private(set) var chapterUpdatedBannerMessage: String? {
        didSet { chapterUpdatedNoticeID = UUID() }
    }
    public private(set) var chapterUpdatedNoticeID = UUID()

    public func dismissChapterUpdatedNotice() {
        chapterUpdatedBannerMessage = nil
    }
    public private(set) var canResumeInterruptedListening: Bool = false
    /// 最近一次书签写入时刻，供界面与测试确认自动保存确实发生。
    public private(set) var lastBookmarkSavedAt: Date?

    // 播放进度采样与书签自动保存：默认 200 ms / 5 s，测试可注入更短间隔。
    public var progressSampleInterval: Duration = .milliseconds(200)
    public var bookmarkAutosaveInterval: TimeInterval = AudiobookLimits.bookmarkAutosaveIntervalSeconds

    private var orderedItems: [(binding: AudiobookFragmentCandidateBinding, candidate: AudiobookRenderCandidate, fileURL: URL)] = []
    private var activeSessionToken: UUID?
    /// 已应用到界面/书签的片内进度比例，用来忽略 seek 后短暂回传的旧进度。
    private var lastAppliedProgressFraction: Double?
    private var progressMonitorTask: Task<Void, Never>?
    private var progressMonitorToken: UUID?

    public init(
        store: AudiobookProjectStore,
        revisionController: AudiobookRevisionController,
        playbackOwner: SharedPlaybackOwner
    ) {
        self.store = store
        self.revisionController = revisionController
        self.playbackOwner = playbackOwner
    }

    public func play(
        bookID: UUID,
        chapterID: UUID,
        fromBookmarkIfMatching: Bool = true,
        chapterRevisionID: UUID? = nil
    ) async throws {
        let currentRev = try await revisionController.currentChapter(bookID: bookID, chapterID: chapterID)
        let targetRev: AudiobookChapterRevision
        let isPrevious: Bool

        if let chapterRevisionID {
            let revisions = try await store.chapterRevisions(for: bookID, chapterID: chapterID)
            guard let selected = revisions.first(where: { $0.id == chapterRevisionID }) else {
                throw AudiobookRevisionError.expectedRevisionMismatch(expected: chapterRevisionID, actual: currentRev?.id)
            }
            targetRev = selected
            isPrevious = selected.id != currentRev?.id
        } else if let currentRev {
            targetRev = currentRev
            isPrevious = false
        } else if let prevRev = try await revisionController.previousListenableChapter(bookID: bookID, chapterID: chapterID) {
            targetRev = prevRev
            isPrevious = true
        } else {
            throw AudiobookRevisionError.incompleteChapterCoverage(chapterID: chapterID, missingFragmentIDs: [])
        }

        let candidates = try await store.candidates(for: bookID)
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        var resolvedItems: [(binding: AudiobookFragmentCandidateBinding, candidate: AudiobookRenderCandidate, fileURL: URL)] = []
        for binding in targetRev.orderedBindings {
            guard let candidate = candidatesByID[binding.candidateID] else {
                throw AudiobookRevisionError.candidateNotFound(binding.candidateID)
            }
            guard candidate.isReceiptVerified, try await store.verifyCandidateAsset(candidate) else {
                throw AudiobookRevisionError.candidateNotFound(binding.candidateID)
            }
            let url = try await store.resolveAssetFileURL(for: candidate)
            resolvedItems.append((binding, candidate, url))
        }
        guard !resolvedItems.isEmpty else { return }

        var startIndex = 0
        var startOffsetSeconds: TimeInterval = 0
        var nextRate = playbackRate
        var updatedBanner: String? = nil

        if fromBookmarkIfMatching,
           let savedBookmark = try await store.bookmark(for: bookID),
           savedBookmark.chapterID == chapterID
        {
            nextRate = min(max(savedBookmark.playbackRate, AudiobookLimits.minPlaybackRate), AudiobookLimits.maxPlaybackRate)
            if savedBookmark.chapterRevisionID == targetRev.id,
               let exactIdx = resolvedItems.firstIndex(where: { $0.binding.fragmentID == savedBookmark.fragmentID })
            {
                startIndex = exactIdx
                startOffsetSeconds = min(
                    max(0, savedBookmark.fragmentOffsetSeconds),
                    max(0, resolvedItems[exactIdx].candidate.durationSeconds - 0.01)
                )
            } else if let anchoredIdx = resolvedItems.firstIndex(where: {
                $0.binding.sourceRange.upperBound > savedBookmark.sourceAnchorRange.lowerBound
                    && $0.binding.sourceRange.lowerBound <= savedBookmark.sourceAnchorRange.lowerBound
            }) {
                startIndex = anchoredIdx
                startOffsetSeconds = 0
                updatedBanner = "章节已更新，已定位到对应正文片段开头。"
            }
        }

        orderedItems = resolvedItems
        chapterTotalDurationSeconds = resolvedItems.reduce(0) { $0 + $1.candidate.durationSeconds }
        playbackRate = nextRate
        chapterUpdatedBannerMessage = updatedBanner
        canResumeInterruptedListening = false

        try await startFragmentPlayback(
            bookID: bookID,
            chapterID: chapterID,
            chapterRevision: targetRev,
            index: startIndex,
            offsetSeconds: startOffsetSeconds,
            isPreviousRevision: isPrevious
        )
    }

    public func pause() async {
        guard activePlayback != nil else { return }
        applyPlaybackProgressIfForward()
        stopProgressMonitor()
        playbackOwner.pause()
        isPlaying = false
        isPaused = true
        await saveCurrentBookmark()
    }

    public func resume() async throws {
        if let active = activePlayback {
            let expectedTarget = PlaybackTarget.audiobook(
                bookID: active.bookID,
                chapterRevisionID: active.chapterRevisionID,
                fragmentID: active.fragmentID
            )
            if playbackOwner.target == expectedTarget {
                try playbackOwner.resume()
                isPlaying = playbackOwner.isPlaying
                isPaused = false
                restartProgressMonitor()
                return
            }
            // Another preview (such as role audition) preempted SharedPlaybackOwner — resume from saved bookmark!
            try await play(bookID: active.bookID, chapterID: active.chapterID, fromBookmarkIfMatching: true, chapterRevisionID: active.chapterRevisionID)
        }
    }

    /// 试听角色或候选片段前调用：先持久化当前听书书签，并标记可显式继续听。
    public func prepareForExternalPreview() async {
        guard activePlayback != nil else { return }
        await saveCurrentBookmark()
        isPlaying = false
        isPaused = true
        canResumeInterruptedListening = true
    }

    public func setRate(_ rate: Float) async {
        let clamped = min(max(rate, AudiobookLimits.minPlaybackRate), AudiobookLimits.maxPlaybackRate)
        playbackRate = clamped
        playbackOwner.setRate(clamped)
        await saveCurrentBookmark()
    }

    /// 基于片段真实帧数计算的时长跨片段快进/快退（例如 ±15 秒）。
    public func skip(seconds deltaSeconds: TimeInterval) async throws {
        guard let active = activePlayback, !orderedItems.isEmpty else { return }
        let targetChapterTime = min(
            max(0, chapterElapsedSeconds + deltaSeconds),
            max(0, chapterTotalDurationSeconds - 0.01)
        )

        var accumulated: TimeInterval = 0
        var targetIndex = orderedItems.count - 1
        var targetOffset: TimeInterval = 0

        for (idx, item) in orderedItems.enumerated() {
            let dur = item.candidate.durationSeconds
            if targetChapterTime < accumulated + dur || idx == orderedItems.count - 1 {
                targetIndex = idx
                targetOffset = min(max(0, targetChapterTime - accumulated), max(0, dur - 0.01))
                break
            }
            accumulated += dur
        }

        if targetIndex == active.fragmentIndex,
           playbackOwner.target == .audiobook(
               bookID: active.bookID,
               chapterRevisionID: active.chapterRevisionID,
               fragmentID: active.fragmentID
           )
        {
            currentFragmentElapsedSeconds = targetOffset
            chapterElapsedSeconds = accumulated + targetOffset
            lastAppliedProgressFraction = targetOffset / max(orderedItems[targetIndex].candidate.durationSeconds, 0.001)
            playbackOwner.seek(to: targetOffset)
            await saveCurrentBookmark()
        } else {
            let rev = AudiobookChapterRevision(
                id: active.chapterRevisionID,
                bookID: active.bookID,
                chapterID: active.chapterID,
                sourceID: UUID(),
                revisionNumber: 1,
                orderedBindings: orderedItems.map(\.binding),
                totalFrameCount: orderedItems.reduce(0) { $0 + $1.candidate.frameCount }
            )
            try await startFragmentPlayback(
                bookID: active.bookID,
                chapterID: active.chapterID,
                chapterRevision: rev,
                index: targetIndex,
                offsetSeconds: targetOffset,
                isPreviousRevision: active.isPreviousRevision
            )
        }
    }

    public func leaveWorkshop() async {
        await saveCurrentBookmark()
        stopProgressMonitor()
        activeSessionToken = nil
        if let active = activePlayback {
            playbackOwner.stop(
                ifTarget: .audiobook(
                    bookID: active.bookID,
                    chapterRevisionID: active.chapterRevisionID,
                    fragmentID: active.fragmentID
                )
            )
        }
        activePlayback = nil
        orderedItems = []
        isPlaying = false
        isPaused = false
        canResumeInterruptedListening = false
    }

    // MARK: - Internal Sequence & Bookmark Management

    private func startFragmentPlayback(
        bookID: UUID,
        chapterID: UUID,
        chapterRevision: AudiobookChapterRevision,
        index: Int,
        offsetSeconds: TimeInterval,
        isPreviousRevision: Bool
    ) async throws {
        guard orderedItems.indices.contains(index) else { return }
        let item = orderedItems[index]
        let nextURL = orderedItems.indices.contains(index + 1) ? orderedItems[index + 1].fileURL : nil
        let prefixDuration = orderedItems[0..<index].reduce(0.0) { $0 + $1.candidate.durationSeconds }

        let sessionToken = UUID()
        let previousToken = activeSessionToken
        let previousPlayback = activePlayback
        let previousFragElapsed = currentFragmentElapsedSeconds
        let previousChapElapsed = chapterElapsedSeconds
        let previousProgressFraction = lastAppliedProgressFraction

        let active = ActiveFragmentPlayback(
            bookID: bookID,
            chapterID: chapterID,
            chapterRevisionID: chapterRevision.id,
            fragmentID: item.binding.fragmentID,
            fragmentIndex: index,
            totalFragments: orderedItems.count,
            sourceRange: item.binding.sourceRange,
            fileURL: item.fileURL,
            nextPreloadedFileURL: nextURL,
            isPreviousRevision: isPreviousRevision,
            chapterUpdatedNotice: chapterUpdatedBannerMessage
        )

        let target = PlaybackTarget.audiobook(
            bookID: bookID,
            chapterRevisionID: chapterRevision.id,
            fragmentID: item.binding.fragmentID
        )

        activeSessionToken = sessionToken
        currentFragmentElapsedSeconds = offsetSeconds
        chapterElapsedSeconds = prefixDuration + offsetSeconds
        lastAppliedProgressFraction = offsetSeconds / max(item.candidate.durationSeconds, 0.001)
        activePlayback = active

        do {
            try playbackOwner.play(
            fileURL: item.fileURL,
            startAt: offsetSeconds,
            rate: playbackRate,
            target: target
        ) { [weak self] finishedSuccessfully in
            guard let self, self.activeSessionToken == sessionToken else { return }
            guard finishedSuccessfully else {
                self.isPlaying = false
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionToken == sessionToken else { return }
                let nextIndex = index + 1
                if self.orderedItems.indices.contains(nextIndex) {
                    try? await self.startFragmentPlayback(
                        bookID: bookID,
                        chapterID: chapterID,
                        chapterRevision: chapterRevision,
                        index: nextIndex,
                        offsetSeconds: 0,
                        isPreviousRevision: isPreviousRevision
                    )
                } else {
                    self.stopProgressMonitor()
                    self.currentFragmentElapsedSeconds = item.candidate.durationSeconds
                    self.chapterElapsedSeconds = self.chapterTotalDurationSeconds
                    self.lastAppliedProgressFraction = 1.0
                    self.isPlaying = false
                    self.isPaused = false
                    await self.saveCurrentBookmark()
                }
            }
        }

        } catch {
            activeSessionToken = previousToken
            activePlayback = previousPlayback
            currentFragmentElapsedSeconds = previousFragElapsed
            chapterElapsedSeconds = previousChapElapsed
            lastAppliedProgressFraction = previousProgressFraction
            throw error
        }

        isPlaying = playbackOwner.isPlaying
        isPaused = false
        startProgressMonitor(fragmentID: item.binding.fragmentID, duration: item.candidate.durationSeconds, prefixDuration: prefixDuration)
        await saveCurrentBookmark()
    }

    public func saveCurrentBookmark() async {
        guard let active = activePlayback else { return }
        let bookmark = AudiobookBookmark(
            bookID: active.bookID,
            chapterID: active.chapterID,
            chapterRevisionID: active.chapterRevisionID,
            fragmentID: active.fragmentID,
            sourceAnchorRange: active.sourceRange,
            fragmentOffsetSeconds: currentFragmentElapsedSeconds,
            playbackRate: playbackRate,
            updatedAt: Date()
        )
        try? await store.saveBookmark(bookmark)
        lastBookmarkSavedAt = Date()
    }

    // MARK: - Progress Tracking & Bookmark Autosave

    private func startProgressMonitor(
        fragmentID: UUID,
        duration: TimeInterval,
        prefixDuration: TimeInterval
    ) {
        stopProgressMonitor()
        let token = UUID()
        let interval = progressSampleInterval
        progressMonitorToken = token
        progressMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.progressMonitorToken == token,
                      self.activePlayback?.fragmentID == fragmentID
                else { return }
                if self.isPlaying {
                    self.applyPlaybackProgress(duration: duration, prefixDuration: prefixDuration)
                    await self.autosaveBookmarkIfDue()
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func stopProgressMonitor() {
        progressMonitorTask?.cancel()
        progressMonitorTask = nil
        progressMonitorToken = nil
    }

    private func restartProgressMonitor() {
        guard let active = activePlayback, orderedItems.indices.contains(active.fragmentIndex) else { return }
        let prefix = orderedItems[0..<active.fragmentIndex].reduce(0.0) { $0 + $1.candidate.durationSeconds }
        startProgressMonitor(
            fragmentID: active.fragmentID,
            duration: orderedItems[active.fragmentIndex].candidate.durationSeconds,
            prefixDuration: prefix
        )
    }

    /// 只接受向前推进的采样：seek 后旧进度回传不会把时间轴拉回去。
    private func applyPlaybackProgress(duration: TimeInterval, prefixDuration: TimeInterval) {
        let fraction = min(max(playbackOwner.progress, 0), 1)
        if let last = lastAppliedProgressFraction, fraction <= last + 0.0005 { return }
        lastAppliedProgressFraction = fraction
        currentFragmentElapsedSeconds = fraction * duration
        chapterElapsedSeconds = prefixDuration + currentFragmentElapsedSeconds
    }

    private func applyPlaybackProgressIfForward() {
        guard let active = activePlayback, orderedItems.indices.contains(active.fragmentIndex) else { return }
        let prefix = orderedItems[0..<active.fragmentIndex].reduce(0.0) { $0 + $1.candidate.durationSeconds }
        applyPlaybackProgress(
            duration: orderedItems[active.fragmentIndex].candidate.durationSeconds,
            prefixDuration: prefix
        )
    }

    private func autosaveBookmarkIfDue() async {
        let now = Date()
        guard lastBookmarkSavedAt.map({ now.timeIntervalSince($0) >= bookmarkAutosaveInterval }) ?? true else { return }
        await saveCurrentBookmark()
    }
}
