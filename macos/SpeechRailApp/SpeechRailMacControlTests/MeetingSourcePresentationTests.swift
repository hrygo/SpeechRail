import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会前/会中的来源呈现（方案 MA-10 / MC-01、MC-03、MC-04、MC-16、MC-74）。
///
/// 这里钉的都是**界面不许说没有的事**：
/// - 没勾麦克风就不能提麦克风（MC-03）；
/// - 电平只是电平，不是识别也不是保存（MC-74）；
/// - 静音麦克风、暂停全部、恢复是三件事（MC-16）；
/// - 检查失败之后输入与来源原样保留（MC-04）。
final class MeetingSourcePresentationTests: XCTestCase {
    private let micOnly = MeetingSourcePresentation.Selection(
        usesMicrophone: true, systemAppNames: []
    )
    private let appOnly = MeetingSourcePresentation.Selection(
        usesMicrophone: false, systemAppNames: ["腾讯会议"]
    )
    private let mixed = MeetingSourcePresentation.Selection(
        usesMicrophone: true, systemAppNames: ["腾讯会议", "Zoom"]
    )

    private func presentation(
        _ capture: MeetingSourcePresentation.Capture,
        selection: MeetingSourcePresentation.Selection,
        isRecognizing: Bool = true,
        savedLineCount: Int = 0
    ) -> MeetingSourcePresentation {
        MeetingSourcePresentation(
            capture: capture, selection: selection,
            isRecognizing: isRecognizing, savedLineCount: savedLineCount
        )
    }

    // MARK: - MC-01：没开始就说没开始

    func testNotStartedSaysNothingIsHappening() {
        let view = presentation(.notStarted, selection: micOnly, savedLineCount: 0)
        XCTAssertEqual(view.title, "还没开始")
        XCTAssertEqual(view.levelCaption, "还没有开始采集")
        XCTAssertTrue(view.facts.contains("没有采集，也没有识别"))
        XCTAssertEqual(view.primaryAction?.kind, .start)
        XCTAssertFalse(
            view.facts.contains { $0.contains("已存下") },
            "没开始就不该报任何已保存的行"
        )
    }

    // MARK: - MC-03：没勾麦克风就不许提麦克风

    func testAppOnlySelectionNeverMentionsTheMicrophone() {
        for capture in [MeetingSourcePresentation.Capture.live, .microphoneMuted] {
            let view = presentation(capture, selection: appOnly)
            XCTAssertFalse(
                view.sourceSummary.contains("麦克风"),
                "只勾了 App 的系统声音，就不许提麦克风（MC-03）"
            )
            XCTAssertTrue(view.sourceSummary.contains("腾讯会议"))
        }
    }

    func testAppOnlyDoesNotRequestOrClaimMicrophoneCapture() {
        let view = presentation(.live, selection: appOnly)
        XCTAssertFalse(view.isMicrophoneSelected)
        XCTAssertEqual(view.systemAppCount, 1)
        XCTAssertEqual(view.sourceSummary, "正在录：腾讯会议 的系统声音")
        XCTAssertTrue(
            view.facts.allSatisfy { !$0.contains("麦克风") },
            "状态事实里同样不许出现麦克风"
        )
    }

    func testMixedSelectionNamesBothSources() {
        let view = presentation(.live, selection: mixed)
        XCTAssertEqual(view.sourceSummary, "正在录：麦克风 + 2 个 App 的系统声音")
    }

    // MARK: - MC-74：电平不冒充识别或保存

    func testLevelIsNeverPresentedAsRecognitionOrSaving() {
        let live = presentation(.live, selection: micOnly, isRecognizing: true, savedLineCount: 0)
        XCTAssertTrue(live.levelCaption.contains("不代表已经转成文字"))
        XCTAssertFalse(live.levelCaption.contains("已保存"))
        XCTAssertFalse(live.levelCaption.contains("保存成功"))

        let notRecognizing = presentation(.live, selection: micOnly, isRecognizing: false)
        XCTAssertFalse(
            notRecognizing.levelCaption.contains("识别中"),
            "识别没连上时，电平不能被说成「识别中」"
        )
        XCTAssertTrue(
            notRecognizing.facts.contains("识别还没连上，文字不会自己出现"),
            "采集在跑但没识别，这两件事要分开说"
        )
    }

    func testSavedCountIsReportedSeparatelyFromLevel() {
        let view = presentation(.live, selection: micOnly, isRecognizing: true, savedLineCount: 3)
        XCTAssertTrue(view.facts.contains("已存下 3 句"))
        XCTAssertTrue(view.levelCaption.contains("不代表已经转成文字"))
    }

    // MARK: - MC-16：静音麦克风 / 暂停全部 / 恢复是三件事

    func testMutePauseAndResumeAreThreeDifferentThings() {
        let muted = presentation(.microphoneMuted, selection: mixed)
        XCTAssertEqual(muted.title, "正在录音 · 麦克风已静音")
        XCTAssertEqual(muted.primaryAction?.kind, .unmuteMicrophone)
        XCTAssertTrue(muted.sourceSummary.contains("麦克风（已静音）"))
        XCTAssertTrue(
            muted.facts.contains("麦克风已静音，系统声音仍在录"),
            "静音一路不等于停掉全部，界面要说清哪一路还在录"
        )

        let paused = presentation(.pausedAll, selection: mixed)
        XCTAssertEqual(paused.title, "已暂停全部")
        XCTAssertEqual(paused.primaryAction?.kind, .resume)
        XCTAssertTrue(paused.sourceSummary.contains("当前没有在录"))
        XCTAssertTrue(paused.levelCaption.contains("看不到电平"))
        XCTAssertNotEqual(
            paused.primaryAction?.kind, .unmuteMicrophone,
            "暂停全部之后要给「恢复全部」，不是「取消静音」"
        )
    }

    func testPausedSegmentIsNotSilentlyJoinedWithTheNextSentence() {
        let paused = presentation(.pausedAll, selection: micOnly)
        XCTAssertTrue(
            paused.facts.contains("暂停前后的句子不会拼在一起"),
            "停记区间必须可追溯，否则用户会以为漏听了"
        )
    }

    func testSelectionSurvivesPauseAndMute() {
        // 暂停与静音**不改变**用户当初勾了什么；重置它等于悄悄改采集范围。
        let paused = presentation(.pausedAll, selection: appOnly)
        XCTAssertEqual(paused.selection, appOnly)
        XCTAssertFalse(paused.isMicrophoneSelected)
        let muted = presentation(.microphoneMuted, selection: mixed)
        XCTAssertEqual(muted.selection, mixed)
    }

    func testMuteWithoutMicrophoneSelectedReadsAsSystemAudioOnly() {
        let view = presentation(.microphoneMuted, selection: appOnly)
        XCTAssertEqual(view.title, "正在录音 · 只在录系统声音")
        XCTAssertTrue(view.levelCaption.contains("电平不代表麦克风"))
    }

    func testLivePrimaryActionIsPauseAll() {
        let view = presentation(.live, selection: micOnly)
        XCTAssertEqual(view.primaryAction?.kind, .pauseAll)
        XCTAssertEqual(view.primaryAction?.title, "暂停全部")
    }

    // MARK: - MC-04：检查失败之后输入与来源原样保留

    func testRetryKeepsTitleNotesAndSelection() {
        let draft = MeetingSourcePresentation.RetryDraft(
            title: "周五发布评审", notes: "重点看回滚方案", selection: mixed
        )
        let result = MeetingSourcePresentation.retryDraft(
            previous: draft, failure: "麦克风被别的应用占用了"
        )
        XCTAssertEqual(result.draft, draft, "重试要用的东西一个字都不能变")
        XCTAssertEqual(result.message, "麦克风被别的应用占用了")
        XCTAssertEqual(result.draft.selection, mixed, "来源不被重置")
    }

    func testRetryDraftSurvivesRepeatedFailures() {
        let draft = MeetingSourcePresentation.RetryDraft(
            title: "会前笔记", notes: "", selection: appOnly
        )
        var current = draft
        for failure in ["第一次失败", "第二次失败"] {
            current = MeetingSourcePresentation.retryDraft(previous: current, failure: failure).draft
        }
        XCTAssertEqual(current, draft, "连续失败也不能把输入清掉")
    }
}
