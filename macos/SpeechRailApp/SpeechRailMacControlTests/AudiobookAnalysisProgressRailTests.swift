import SwiftUI
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 分析进度轨道的离屏视觉回归：`ImageRenderer` 不开窗口、不抢前台/焦点，
/// 不属于被禁的前台 UI 自动化；只断言渲染成功、尺寸稳定、关键帧非空白。
/// 长时运行仿真用生产发射器按脚本时间线产出结构真实的事件流（含 75 秒停滞
/// 空隙与重试簇），经生产投影折叠后逐帧渲染生产视图；环境矩阵覆盖三档宽度、
/// 浅深色与大字号。
@MainActor
final class AudiobookAnalysisProgressRailTests: XCTestCase {
    private func makeProgress(
        phase: AudiobookAnalysisPhase = .extracting,
        idleSeconds: TimeInterval = 1,
        isRetrying: Bool = false
    ) -> AudiobookAnalysisProgress {
        let now = Date()
        var progress = AudiobookAnalysisProgress(firstEvent: AudiobookAnalysisEvent(
            runID: "rail-test-run-id-0001",
            bookID: UUID(),
            sequence: 0,
            kind: .planned,
            occurredAt: now.addingTimeInterval(-90),
            totalWindows: 42,
            extractedWindows: 6,
            mergeBatchesDone: 0,
            mergeBatchesTotal: 3,
            annotatedWindows: 0,
            currentChapterOrdinal: 2,
            currentWindowOrdinal: 7,
            attempt: 1,
            maxAttempts: 6
        ))
        progress.phase = phase
        progress.lastEventAt = now.addingTimeInterval(-idleSeconds)
        progress.isRetrying = isRetrying
        if isRetrying {
            progress.attempt = 2
        }
        return progress
    }

    private func renderRail(
        progress: AudiobookAnalysisProgress,
        now: Date,
        expandedDevSection: Bool = false
    ) -> NSImage? {
        renderRail(progress: progress, now: now, width: 560, colorScheme: .light, sizeCategory: .large, expandedDevSection: expandedDevSection)
    }

    private func renderRail(
        progress: AudiobookAnalysisProgress,
        now: Date,
        width: CGFloat,
        colorScheme: ColorScheme,
        sizeCategory: ContentSizeCategory,
        expandedDevSection: Bool = false
    ) -> NSImage? {
        let rail = AudiobookAnalysisProgressRailView(
            progress: progress,
            tick: now,
            eventCount: 12,
            showDeveloperDetails: true,
            isDeveloperSectionExpanded: .constant(expandedDevSection),
            onPause: {}
        )
        .frame(width: width)
        .preferredColorScheme(colorScheme)
        .environment(\.sizeCategory, sizeCategory)
        let renderer = ImageRenderer(content: rail)
        renderer.scale = 1.0
        return renderer.nsImage
    }

    /// 长时运行仿真：生产发射器按脚本时间线发射结构真实的事件（含一次
    /// 拆窗重试簇与 75 秒停滞空隙），调用方经生产投影逐帧折叠并渲染。
    /// 返回 (帧快照, 每帧的渲染时刻, 停滞空隙开始的帧下标)。
    private func simulateLongRunFrames() -> (frames: [AudiobookAnalysisEvent], ticks: [Date], stallStartIndex: Int) {
        let bookID = UUID()
        let recorder = SimulationEventRecorder()
        let emitter = AudiobookAnalysisEventEmitter(
            runID: "rail-long-run-0001",
            bookID: bookID,
            sink: recorder.sink
        )
        emitter.setPlan(totalWindows: 40, reusedCheckpointWindows: 4, maxAttempts: 6)

        // 脚本时间线（秒）：t=0 规划；每个提取窗口 8s；第 3 窗重试簇额外 2×6s；
        // 第 20 窗后插入 75s 停滞空隙；随后归并 2 组、标注 40 窗各 1s。
        var scriptedNow = Date()
        func advance(_ seconds: TimeInterval) { scriptedNow = scriptedNow.addingTimeInterval(seconds) }
        // emitter 的 occurredAt 取 Date()，此处用重写时间戳的方式对齐脚本时间。
        func stampLastEvent(at date: Date) {
            recorder.stampLastEvent(at: date)
        }

        emitter.emit(.planned)
        stampLastEvent(at: scriptedNow)
        var frameTicks: [Date] = [scriptedNow]
        // 停滞空隙后的首个事件下标：在循环内动态记录，避免手工算序号。
        var stallStartIndex = 0

        var windowIndex = 0
        for window in 0..<40 {
            emitter.setCurrentWindow(chapterOrdinal: window / 10 + 1, windowOrdinal: window + 1)
            advance(4)
            emitter.emit(.awaitingLLM, attempt: 1)
            stampLastEvent(at: scriptedNow)
            frameTicks.append(scriptedNow)
            if windowIndex == 2 {
                // 重试簇：retryingSplit + 两次子窗口等待。
                advance(6)
                emitter.emit(.retryingSplit, attempt: 2)
                stampLastEvent(at: scriptedNow)
                frameTicks.append(scriptedNow)
                advance(6)
                emitter.emit(.awaitingLLM, attempt: 3)
                stampLastEvent(at: scriptedNow)
                frameTicks.append(scriptedNow)
                advance(6)
                emitter.emit(.awaitingLLM, attempt: 4)
                stampLastEvent(at: scriptedNow)
                frameTicks.append(scriptedNow)
            }
            if windowIndex == 20 {
                // 停滞空隙：75 秒无任何事件。
                advance(75)
                stallStartIndex = recorder.events.count
            }
            advance(4)
            emitter.noteExtracted()
            emitter.emit(.windowExtracted)
            stampLastEvent(at: scriptedNow)
            frameTicks.append(scriptedNow)
            windowIndex += 1
        }

        emitter.setMergeBatches(total: 2)
        for _ in 0..<2 {
            advance(3)
            emitter.noteBatchMerged()
            emitter.emit(.castBatchMerged)
            stampLastEvent(at: scriptedNow)
            frameTicks.append(scriptedNow)
        }
        for window in 0..<40 {
            emitter.setCurrentWindow(chapterOrdinal: window / 10 + 1, windowOrdinal: window + 1)
            advance(1)
            emitter.noteAnnotated()
            emitter.emit(.windowAnnotated)
            stampLastEvent(at: scriptedNow)
            frameTicks.append(scriptedNow)
        }
        advance(1)
        emitter.emitRunEnded(outcome: .completed)
        stampLastEvent(at: scriptedNow)
        frameTicks.append(scriptedNow)
        return (recorder.events, frameTicks, stallStartIndex)
    }

    private func nonBackgroundPixelCount(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pixels = rep.bitmapData
        else { return 0 }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow
        let samples = Int(rep.samplesPerPixel)
        guard samples >= 3 else { return 0 }
        // 左上角采样为背景色；与其差异超过阈值的像素计为"有内容"。
        let bgR = pixels[0], bgG = pixels[1], bgB = pixels[2]
        var count = 0
        for y in 0..<height {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let px = row.advanced(by: x * samples)
                let dr = abs(Int(px[0]) - Int(bgR))
                let dg = abs(Int(px[1]) - Int(bgG))
                let db = abs(Int(px[2]) - Int(bgB))
                if dr + dg + db > 36 {
                    count += 1
                }
            }
        }
        return count
    }

    /// 正常态渲染成功、尺寸稳定、非空白。
    func testRailRendersNormalState() throws {
        let now = Date()
        let image = try XCTUnwrap(renderRail(progress: makeProgress(), now: now))
        XCTAssertGreaterThan(image.size.width, 500)
        XCTAssertGreaterThan(image.size.height, 40)
        XCTAssertLessThan(image.size.height, 400)
        XCTAssertGreaterThan(nonBackgroundPixelCount(in: image), 2_000)
    }

    /// 三阶段标题各不相同且渲染成功（阶段推进在视觉上有表达）。
    func testRailPhaseTitlesDiffer() throws {
        let now = Date()
        let titles = AudiobookAnalysisPhase.allRenderableCases.map(\.stepTitle)
        XCTAssertEqual(Set(titles).count, titles.count)
        for phase in AudiobookAnalysisPhase.allRenderableCases {
            let image = try XCTUnwrap(renderRail(progress: makeProgress(phase: phase), now: now))
            XCTAssertGreaterThan(nonBackgroundPixelCount(in: image), 2_000, "阶段 \(phase) 不得渲染为空白")
        }
    }

    /// 重试态与停滞态都增加视觉高度（多一行提示/横条），且渲染成功。
    func testRailRetryAndStallStatesGrowHeight() throws {
        let now = Date()
        let normal = try XCTUnwrap(renderRail(progress: makeProgress(idleSeconds: 1), now: now))
        let retry = try XCTUnwrap(renderRail(progress: makeProgress(idleSeconds: 1, isRetrying: true), now: now))
        let stalled = try XCTUnwrap(renderRail(
            progress: makeProgress(idleSeconds: AudiobookAnalysisProgressLimits.stallWarningSeconds + 5),
            now: now
        ))
        XCTAssertGreaterThan(retry.size.height, normal.size.height, "重试行必须增加轨道高度")
        XCTAssertGreaterThan(stalled.size.height, normal.size.height, "停滞横条必须增加轨道高度")
        XCTAssertGreaterThan(nonBackgroundPixelCount(in: retry), 2_000)
        XCTAssertGreaterThan(nonBackgroundPixelCount(in: stalled), 2_000)
    }

    /// 开发者区展开后高度继续增加（折叠态不挤占正常轨道）。
    func testRailDeveloperSectionExpandsHeight() throws {
        let now = Date()
        let collapsed = try XCTUnwrap(renderRail(progress: makeProgress(), now: now, expandedDevSection: false))
        let expanded = try XCTUnwrap(renderRail(progress: makeProgress(), now: now, expandedDevSection: true))
        XCTAssertGreaterThan(expanded.size.height, collapsed.size.height)
    }

    /// 用户语言守卫：主文案不得出现内部术语；心跳三档阈值与 Limits 一致。
    func testRailUserLanguageAndHeartbeatThresholds() {
        let now = Date()
        let titles = AudiobookAnalysisPhase.allRenderableCases.map(\.stepTitle)
            + AudiobookAnalysisPhase.allRenderableCases.compactMap(\.stepCounter)
        let forbidden = ["window", "attempt", "LLM", "token", "run", "epoch", "sink", "emit"]
        for title in titles {
            for term in forbidden {
                XCTAssertFalse(title.localizedCaseInsensitiveContains(term), "用户文案不得出现内部术语 \(term)：\(title)")
            }
        }

        let fresh = makeProgress(idleSeconds: 2)
        XCTAssertEqual(AudiobookAnalysisProgressRailView.heartbeatText(progress: fresh, now: now), "进展正常")
        let awaiting = makeProgress(idleSeconds: 10)
        XCTAssertTrue(AudiobookAnalysisProgressRailView.heartbeatText(progress: awaiting, now: now).hasPrefix("等待 AI 返回"))
        let longWait = makeProgress(idleSeconds: AudiobookAnalysisProgressLimits.awaitingCallNoticeSeconds + 1)
        XCTAssertTrue(AudiobookAnalysisProgressRailView.heartbeatText(progress: longWait, now: now).hasPrefix("仍在等待"))
        let stalled = makeProgress(idleSeconds: AudiobookAnalysisProgressLimits.stallWarningSeconds + 1)
        XCTAssertTrue(AudiobookAnalysisProgressRailView.heartbeatText(progress: stalled, now: now).hasPrefix("上次进展"))
        XCTAssertTrue(stalled.isStalled(at: now))
        XCTAssertFalse(awaiting.isStalled(at: now))
    }

    /// 胶囊文案与无障碍标签：带百分比与计数，不带内部术语。
    func testRailPillAndAccessibilityLabels() {
        let progress = makeProgress()
        let pill = AudiobookAnalysisProgressRailView.pillLabel(for: progress)
        XCTAssertTrue(pill.contains("找出书中人物"))
        XCTAssertTrue(pill.contains("第 7/42 窗"))
        let label = AudiobookAnalysisProgressRailView.accessibilityLabel(progress: progress)
        XCTAssertTrue(label.contains("正在找出书中人物"))
        XCTAssertTrue(label.contains("%"))
        XCTAssertTrue(label.contains("第 7/42 窗"))
    }

    /// 长时运行仿真：全 run 每一帧渲染成功、非空白，百分比单调不回退。
    func testLongRunEveryFrameRendersAndFractionIsMonotonic() throws {
        let (events, ticks, _) = simulateLongRunFrames()
        XCTAssertGreaterThan(events.count, 100)
        var projection: AudiobookAnalysisProgress?
        var lastFraction = -1.0
        var renderedFrames = 0
        for (index, event) in events.enumerated() {
            if var current = projection {
                current.apply(event)
                projection = current
            } else {
                projection = AudiobookAnalysisProgress(firstEvent: event)
            }
            let progress = try XCTUnwrap(projection)
            XCTAssertGreaterThanOrEqual(
                progress.fraction, lastFraction,
                "第 \(index) 帧百分比回退：\(lastFraction) → \(progress.fraction)"
            )
            lastFraction = progress.fraction
            // 每 5 帧渲染一次（含首尾帧），控制测试耗时。
            if index % 5 == 0 || index == events.count - 1 {
                let image = try XCTUnwrap(
                    renderRail(progress: progress, now: ticks[index]),
                    "第 \(index) 帧渲染失败"
                )
                XCTAssertGreaterThan(image.size.height, 40, "第 \(index) 帧高度异常")
                XCTAssertLessThan(image.size.height, 900, "第 \(index) 帧高度爆炸")
                XCTAssertGreaterThan(nonBackgroundPixelCount(in: image), 2_000, "第 \(index) 帧渲染为空白")
                renderedFrames += 1
            }
        }
        XCTAssertGreaterThan(renderedFrames, 20)
        XCTAssertEqual(projection?.outcome, .completed)
        XCTAssertEqual(projection?.fraction ?? 0, 1.0, accuracy: 0.0001)
    }

    /// 长时运行仿真：重试簇帧出现重试行（增高），窗口完成后复位（回落）。
    func testLongRunRetryClusterShowsAndResets() throws {
        let (events, ticks, _) = simulateLongRunFrames()
        guard let retryIndex = events.firstIndex(where: { $0.kind == .retryingSplit }) else {
            XCTFail("仿真时间线必须包含 retryingSplit 事件")
            return
        }
        var projection: AudiobookAnalysisProgress?
        var heights: [Int: CGFloat] = [:]
        for (index, event) in events.enumerated() {
            if var current = projection {
                current.apply(event)
                projection = current
            } else {
                projection = AudiobookAnalysisProgress(firstEvent: event)
            }
            if index == retryIndex - 1 || index == retryIndex || index == retryIndex + 4 {
                let image = try XCTUnwrap(renderRail(progress: projection!, now: ticks[index]))
                heights[index] = image.size.height
            }
        }
        let before = try XCTUnwrap(heights[retryIndex - 1])
        let during = try XCTUnwrap(heights[retryIndex])
        let after = try XCTUnwrap(heights[retryIndex + 4])
        XCTAssertGreaterThan(during, before, "重试帧必须比重试前更高（多重试行）")
        XCTAssertLessThan(after, during, "窗口完成后重试行复位，高度必须回落")
    }

    /// 长时运行仿真：75 秒停滞空隙中横条出现（增高），恢复后消失（回落）。
    func testLongRunStallGapShowsBannerThenRecovers() throws {
        let (events, ticks, stallStartIndex) = simulateLongRunFrames()
        var projection: AudiobookAnalysisProgress?
        for event in events[..<stallStartIndex] {
            if var current = projection {
                current.apply(event)
                projection = current
            } else {
                projection = AudiobookAnalysisProgress(firstEvent: event)
            }
        }
        let stalledProgress = try XCTUnwrap(projection)
        // 空隙中点（+40s）：仍在等待，横条未出；空隙末（+75s）：横条必须出现。
        let gapMid = ticks[stallStartIndex - 1].addingTimeInterval(40)
        let gapEnd = ticks[stallStartIndex - 1].addingTimeInterval(75)
        XCTAssertFalse(stalledProgress.isStalled(at: gapMid))
        XCTAssertTrue(stalledProgress.isStalled(at: gapEnd))
        let midImage = try XCTUnwrap(renderRail(progress: stalledProgress, now: gapMid))
        let endImage = try XCTUnwrap(renderRail(progress: stalledProgress, now: gapEnd))
        XCTAssertGreaterThan(endImage.size.height, midImage.size.height, "停滞横条必须增加轨道高度")
        // 恢复：折叠空隙后的事件，心跳回到等待档，横条消失。
        var recovered = stalledProgress
        recovered.apply(events[stallStartIndex])
        XCTAssertFalse(recovered.isStalled(at: ticks[stallStartIndex]))
        let recoveredImage = try XCTUnwrap(renderRail(progress: recovered, now: ticks[stallStartIndex]))
        XCTAssertLessThan(recoveredImage.size.height, endImage.size.height, "恢复后横条消失，高度必须回落")
    }

    /// 环境矩阵：三档宽度 × 浅深色 × 常规/大字号，全部渲染成功且非空白。
    func testRailEnvironmentMatrixRenders() throws {
        let now = Date()
        let states: [(String, AudiobookAnalysisProgress)] = [
            ("normal", makeProgress(idleSeconds: 1)),
            ("retry", makeProgress(idleSeconds: 1, isRetrying: true)),
            ("stalled", makeProgress(idleSeconds: AudiobookAnalysisProgressLimits.stallWarningSeconds + 5)),
        ]
        let widths: [CGFloat] = [360, 560, 900]
        let schemes: [ColorScheme] = [.light, .dark]
        let sizes: [ContentSizeCategory] = [.medium, .extraExtraLarge]
        var rendered = 0
        for (name, progress) in states {
            for width in widths {
                for scheme in schemes {
                    for size in sizes {
                        let image = try XCTUnwrap(
                            renderRail(progress: progress, now: now, width: width, colorScheme: scheme, sizeCategory: size),
                            "\(name) w=\(width) \(scheme) \(size) 渲染失败"
                        )
                        XCTAssertGreaterThan(image.size.width, width - 1, "\(name) 宽度异常")
                        XCTAssertGreaterThan(nonBackgroundPixelCount(in: image), 1_000, "\(name) w=\(width) \(scheme) \(size) 为空白")
                        rendered += 1
                    }
                }
            }
        }
        XCTAssertEqual(rendered, 3 * 3 * 2 * 2)
    }

    /// 关键帧导出（人工走查辅助）：仅当设置环境变量
    /// `SPEECHRAIL_EXPORT_RAIL_KEYFRAMES=1` 时执行，把生产视图的关键状态渲染成
    /// PNG 落到 /tmp/speechrail-rail-keyframes/，供走查人逐张目检；常规回归中跳过。
    func testExportKeyframesForManualReview() throws {
        guard ProcessInfo.processInfo.environment["SPEECHRAIL_EXPORT_RAIL_KEYFRAMES"] == "1" else {
            throw XCTSkip("仅人工走查时导出关键帧：SPEECHRAIL_EXPORT_RAIL_KEYFRAMES=1")
        }
        let now = Date()
        let dir = URL(fileURLWithPath: "/tmp/speechrail-rail-keyframes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func save(_ image: NSImage?, name: String) throws {
            let image = try XCTUnwrap(image, "\(name) 渲染失败")
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                XCTFail("\(name) PNG 编码失败")
                return
            }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }

        let normal = makeProgress(idleSeconds: 1)
        let retry = makeProgress(idleSeconds: 1, isRetrying: true)
        let stalled = makeProgress(idleSeconds: AudiobookAnalysisProgressLimits.stallWarningSeconds + 5)
        let merging = makeProgress(phase: .merging, idleSeconds: 2)
        let annotating = makeProgress(phase: .annotating, idleSeconds: 2)

        // 对照：裸 ProgressView.tint(.rail) 与裸 .primary 按钮（与轨道用同一 Token）。
        // 若同样发黄，即为测试 bundle 环境 artifact，与轨道代码无关。
        func saveControl(_ view: AnyView, name: String) throws {
            let renderer = ImageRenderer(content: view.frame(width: 560))
            renderer.scale = 1.0
            try save(renderer.nsImage, name: name)
        }
        try saveControl(AnyView(
            ProgressView(value: 0.5).controlSize(.small).tint(SpeechRailDesignTokens.Color.rail)
        ), name: "00-control-progress-tint")
        try saveControl(AnyView(
            Button("暂停分析", action: {}).speechRailButton(.primary)
        ), name: "00-control-primary-button")
        // 二次对照：同一进度条但用系统语义色（不经过 accentColor asset）。
        try saveControl(AnyView(
            ProgressView(value: 0.5).controlSize(.small).tint(Color(nsColor: .systemBlue))
        ), name: "00-control-progress-systemblue")

        try save(renderRail(progress: normal, now: now), name: "01-normal-light")
        try save(renderRail(progress: retry, now: now), name: "02-retry-light")
        try save(renderRail(progress: stalled, now: now), name: "03-stalled-light")
        try save(renderRail(progress: merging, now: now), name: "04-merging-light")
        try save(renderRail(progress: annotating, now: now), name: "05-annotating-light")
        try save(renderRail(progress: normal, now: now, expandedDevSection: true), name: "06-dev-expanded-light")
        try save(renderRail(progress: normal, now: now, width: 560, colorScheme: .dark, sizeCategory: .large), name: "07-normal-dark")
        try save(renderRail(progress: stalled, now: now, width: 560, colorScheme: .dark, sizeCategory: .large), name: "08-stalled-dark")
        try save(renderRail(progress: normal, now: now, width: 360, colorScheme: .light, sizeCategory: .large), name: "09-narrow-normal-light")
        try save(renderRail(progress: stalled, now: now, width: 360, colorScheme: .light, sizeCategory: .large), name: "10-narrow-stalled-light")
        try save(renderRail(progress: normal, now: now, width: 560, colorScheme: .light, sizeCategory: .accessibilityExtraLarge), name: "11-normal-xxxlarge")
        try save(renderRail(progress: stalled, now: now, width: 560, colorScheme: .light, sizeCategory: .accessibilityExtraLarge), name: "12-stalled-xxxlarge")
    }
}

private extension AudiobookAnalysisPhase {
    /// 需要逐阶段渲染验证的运行态（准备中/已结束由首尾事件覆盖，不在此列）。
    static var allRenderableCases: [AudiobookAnalysisPhase] {
        [.extracting, .merging, .annotating]
    }
}

/// 仿真事件记录器：`@Sendable` sink 要求锁保护，与
/// `AudiobookAnalysisProgressTests.EventRecorder` 同模式；额外支持重写
/// 末事件时间戳，把生产发射器的 `Date()` 对齐到脚本时间线。
private final class SimulationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudiobookAnalysisEvent] = []

    var sink: AudiobookAnalysisProgressSink {
        AudiobookAnalysisProgressSink { [weak self] event in
            guard let self else { return }
            self.lock.withLock {
                self.stored.append(event)
            }
        }
    }

    var events: [AudiobookAnalysisEvent] {
        lock.withLock { stored }
    }

    func stampLastEvent(at date: Date) {
        lock.withLock {
            guard !stored.isEmpty else { return }
            stored[stored.count - 1].occurredAt = date
        }
    }
}
