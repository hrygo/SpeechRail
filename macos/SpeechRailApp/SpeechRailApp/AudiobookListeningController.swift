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
    public private(set) var chapterUpdatedBannerMessage: String?
    public private(set) var canResumeInterruptedListening: Bool = false

    private var orderedItems: [(binding: AudiobookFragmentCandidateBinding, candidate: AudiobookRenderCandidate, fileURL: URL)] = []
    private var activeSessionToken: UUID?

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
        fromBookmarkIfMatching: Bool = true
    ) async throws {
        let currentRev = try await revisionController.currentChapter(bookID: bookID, chapterID: chapterID)
        let targetRev: AudiobookChapterRevision
        let isPrevious: Bool

        if let currentRev {
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
                return
            }
            // Another preview (such as role audition) preempted SharedPlaybackOwner — resume from saved bookmark!
            try await play(bookID: active.bookID, chapterID: active.chapterID, fromBookmarkIfMatching: true)
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
                    self.currentFragmentElapsedSeconds = item.candidate.durationSeconds
                    self.chapterElapsedSeconds = self.chapterTotalDurationSeconds
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
            throw error
        }

        isPlaying = playbackOwner.isPlaying
        isPaused = false
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
    }
}
