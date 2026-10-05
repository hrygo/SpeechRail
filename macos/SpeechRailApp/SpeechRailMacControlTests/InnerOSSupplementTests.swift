import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 私密问答「写进纪要」（MC-43 / 验收 4）。
///
/// `MeetingPrivacyDeletionTests` 已经钉住库这一侧：勾选哪句就只有哪句进快照，
/// 而且它**不混进转录行修订**。这一组钉的是**界面上真的走的那条路**——
/// `InnerOSSession` → 协调器 → 库。上一组测试整条调用的是 `store.setInnerOSInMinutes`，
/// 把中间这一层换掉不会有一条变红。
///
/// 三条要守的：
/// - 默认不进纪要，仍然由结构决定，不是由"记得别勾"决定；
/// - 勾上要真的写进库，界面上不能只是把标签翻过来；
/// - **写失败不能说成功**——这一条最要紧：私密问答默认不进入纪要，
///   用户靠这个标签判断"这句到底进没进去"。
@MainActor
final class InnerOSSupplementTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var coordinator: SessionCoordinator?
    private var session: InnerOSSession?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inner-os-supplement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "inner-os-\(UUID().uuidString)"))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        self.directory = directory
        self.store = store
        self.coordinator = coordinator
        session = InnerOSSession(coordinator: coordinator)
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        coordinator = nil
        session = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }
    private func requireSession() throws -> InnerOSSession { try XCTUnwrap(session) }

    /// 造一场会，并准备好两条已答完的私密问答。
    private func makeMeetingWithTwoAnswers() async throws -> (sessionID: String, first: String, second: String) {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "发布评审")
        )
        _ = try await store.appendLine(
            LineDraft(
                sessionID: record.id, role: .speaker, text: "先记一下这两件事。",
                source: .microphone, tStart: 0, status: .final
            ),
            id: "\(record.id)-line"
        )
        for (index, id) in ["qa-1", "qa-2"].enumerated() {
            let draft = InnerOSExchange(id: id, sessionID: record.id, question: "第 \(index + 1) 问？")
            _ = try await store.saveInnerOSExchange(draft, evidence: [])
            var answered = draft
            answered.answerText = "第 \(index + 1) 条说法。"
            answered.status = .ready
            _ = try await store.finishInnerOSExchange(answered)
        }
        return (record.id, "qa-1", "qa-2")
    }

    // MARK: - 默认不进纪要

    func testNothingEntersMinutesUntilTheUserSaysSo() async throws {
        let store = try requireStore()
        let made = try await makeMeetingWithTwoAnswers()
        let session = try requireSession()
        await session.bind(sessionID: made.sessionID)

        XCTAssertEqual(session.inMinutesCount, 0, "默认一条都不进")
        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertTrue(supplements.isEmpty, "没勾就是没有，不是「忘了勾」")
    }

    // MARK: - 勾上要真的写进库

    func testIncludeInMinutesActuallyReachesTheStore() async throws {
        let store = try requireStore()
        let made = try await makeMeetingWithTwoAnswers()
        let session = try requireSession()
        await session.bind(sessionID: made.sessionID)

        let ok = await session.includeInMinutes(exchangeID: made.first)
        XCTAssertTrue(ok)
        XCTAssertEqual(session.inMinutesCount, 1)

        // 界面上翻过去的标签不算数，去库里看。
        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(supplements.map(\.exchangeID), [made.first])

        let reloaded = try await store.innerOSExchanges(sessionID: made.sessionID)
        XCTAssertTrue(
            reloaded.first { $0.id == made.first }?.inMinutes == true,
            "重开一次仍然是写进纪要的，光靠内存里的标记不算"
        )
    }

    /// 勾了哪句就只有哪句进快照，另一句不许跟着沾光。
    func testOnlyTheCheckedOneEntersTheSnapshot() async throws {
        let store = try requireStore()
        let made = try await makeMeetingWithTwoAnswers()
        let session = try requireSession()
        await session.bind(sessionID: made.sessionID)
        _ = await session.includeInMinutes(exchangeID: made.second)

        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(supplements.map(\.exchangeID), [made.second])

        // 关键：它是 AI 的说法，不是会上说的话。
        let revisions = try await store.transcriptRevisions(lineID: "\(made.sessionID)-line")
        XCTAssertFalse(
            revisions.contains { $0.text.contains("第 2 条说法") },
            "私密问答的回答不得写进行修订——那是把模型的话升级成会议事实"
        )
    }

    // MARK: - 写失败不能说成功

    func testAFailedWriteDoesNotClaimSuccess() async throws {
        let made = try await makeMeetingWithTwoAnswers()
        let session = try requireSession()
        await session.bind(sessionID: made.sessionID)

        let ok = await session.includeInMinutes(exchangeID: "根本没有这一条")
        XCTAssertFalse(ok, "写不进库就不能返回成功")
        XCTAssertEqual(session.inMinutesCount, 0, "标签不许翻过去")
        let hint = try XCTUnwrap(session.supplementError)
        XCTAssertFalse(hint.isEmpty, "失败要有一句能看的话")
        XCTAssertTrue(
            hint.contains("没有改动"),
            "要说清这一句其实没进去，用户才知道不能就这么放心封存"
        )
    }

    // MARK: - 勾错了要能撤回

    /// 「写进纪要」原来是一条**单行道**：勾上之后界面上只剩一枚静态标签，
    /// `setInnerOSInMinutes(included: false)` 在生产代码里够不着。
    func testInclusionCanBeTakenBack() async throws {
        let store = try requireStore()
        let made = try await makeMeetingWithTwoAnswers()
        let session = try requireSession()
        await session.bind(sessionID: made.sessionID)

        _ = await session.includeInMinutes(exchangeID: made.first)
        XCTAssertEqual(session.inMinutesCount, 1)

        let ok = await session.excludeFromMinutes(exchangeID: made.first)
        XCTAssertTrue(ok)
        XCTAssertEqual(session.inMinutesCount, 0)

        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertTrue(supplements.isEmpty, "撤回之后不该再进快照")

        let reloaded = try await store.innerOSExchanges(sessionID: made.sessionID)
        XCTAssertEqual(
            reloaded.first { $0.id == made.first }?.inMinutes, false,
            "撤回要真的落库，不是把界面上的标签藏起来"
        )
    }

    /// 撤回失败也要说真话。两个方向共用一个写入口，但**界面上是两个按钮**，
    /// 所以两条路都要各自被钉住。
    func testFailedWithdrawalAlsoDoesNotClaimSuccess() async throws {
        let session = try requireSession()
        await session.bind(sessionID: "不存在的会话")

        let ok = await session.excludeFromMinutes(exchangeID: "根本没有这一条")
        XCTAssertFalse(ok)
        let hint = try XCTUnwrap(session.supplementError)
        XCTAssertTrue(hint.contains("没有改动"))
    }

    // MARK: - MC-43 粒度：选的是**一句**，不是整条问答
    //
    // 验收原话是「用户只选择私密问答中**一句**加入补充 → 只**该句**进入 source snapshot」。
    // 此前的实现只有一个整条问答的布尔旗标，`selectedSupplements` 把整段 `answer_text`
    // 收进快照——用户想留半句，留不下；不想让另一半进纪要，也拦不住。
    //
    // 这一组钉的是句子粒度。四条要守的：
    // - 只选一句，快照里就只有那一句，不是整段；
    // - 显式选「整条」仍然可用（老行没有 excerpt，按整条读，不猜）；
    // - 改选要真的覆盖，不是追加；
    // - **送进模型的 prompt 也只能有那一句**——快照对了但 prompt 拿整段，
    //   等于把没选的那半句又偷偷用了一次。

    /// 一条有三句话的答案，外加一句不在任何一句里的尾巴。
    private func makeMultiSentenceAnswer() async throws -> (sessionID: String, exchangeID: String) {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "发布评审")
        )
        _ = try await store.appendLine(
            LineDraft(
                sessionID: record.id, role: .speaker, text: "先记一下这两件事。",
                source: .microphone, tStart: 0, status: .final
            ),
            id: "\(record.id)-line"
        )
        let draft = InnerOSExchange(id: "qa-multi", sessionID: record.id, question: "灰度怎么排？")
        _ = try await store.saveInnerOSExchange(draft, evidence: [])
        var answered = draft
        answered.answerText = "灰度下周三开始。先跑 5% 流量。回滚预案要提前写好。"
        answered.status = .ready
        _ = try await store.finishInnerOSExchange(answered)
        return (record.id, draft.id)
    }

    func testSelectingOneSentencePutsOnlyThatSentenceIntoTheSnapshot() async throws {
        let store = try requireStore()
        let made = try await makeMultiSentenceAnswer()

        let included = try await store.setInnerOSInMinutes(
            exchangeID: made.exchangeID, included: true, excerpt: "先跑 5% 流量。"
        )
        XCTAssertTrue(included)

        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(supplements.count, 1)
        XCTAssertEqual(
            supplements.first?.answerText, "先跑 5% 流量。",
            "只该句进入快照——整段答案不该跟进来"
        )
        XCTAssertFalse(
            supplements.first?.answerText.contains("回滚预案") ?? true,
            "没选的那句不得跟着沾光"
        )
    }

    /// 老行没有 excerpt，一律按整条读。**不猜**：迁移前写下的勾选就是"整条进"，
    /// 凭空截断等于替用户改了他当时的选择。
    func testRowWithoutExcerptIsReadAsTheWholeAnswer() async throws {
        let store = try requireStore()
        let made = try await makeMultiSentenceAnswer()
        _ = try await store.setInnerOSInMinutes(exchangeID: made.exchangeID, included: true)

        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(
            supplements.first?.answerText, "灰度下周三开始。先跑 5% 流量。回滚预案要提前写好。",
            "没有 excerpt 的行按整条读，不擅自截断"
        )
    }

    /// 改选要**覆盖**。追加的话用户先选了一句、后来改成两句，
    /// 库里却留下三句，而他界面上看到的只是两句。
    func testReselectingReplacesTheEarlierExcerpt() async throws {
        let store = try requireStore()
        let made = try await makeMultiSentenceAnswer()
        _ = try await store.setInnerOSInMinutes(
            exchangeID: made.exchangeID, included: true, excerpt: "先跑 5% 流量。"
        )
        _ = try await store.setInnerOSInMinutes(
            exchangeID: made.exchangeID, included: true,
            excerpt: "灰度下周三开始。先跑 5% 流量。"
        )

        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(supplements.first?.answerText, "灰度下周三开始。先跑 5% 流量。")
    }

    /// 撤回要把 excerpt 一起清掉。清不掉的话，用户撤回这一条之后重新勾上，
    /// 上次选过的那半句会自己回来——他明明已经说过"这句不要"。
    func testWithdrawingClearsTheExcerptToo() async throws {
        let store = try requireStore()
        let made = try await makeMultiSentenceAnswer()
        _ = try await store.setInnerOSInMinutes(
            exchangeID: made.exchangeID, included: true, excerpt: "先跑 5% 流量。"
        )
        _ = try await store.setInnerOSInMinutes(exchangeID: made.exchangeID, included: false)

        let reloaded = try await store.innerOSExchanges(sessionID: made.sessionID)
        let row = try XCTUnwrap(reloaded.first)
        XCTAssertFalse(row.inMinutes)
        XCTAssertNil(row.minutesExcerpt, "撤回后不留残句，下次勾选从干净状态开始")

        _ = try await store.setInnerOSInMinutes(exchangeID: made.exchangeID, included: true)
        let snapshot = try await store.sealMeetingSource(sessionID: made.sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(
            supplements.first?.answerText, "灰度下周三开始。先跑 5% 流量。回滚预案要提前写好。",
            "重新勾选且没指定句子时是整条，不是上次留下的半句"
        )
    }

    /// **送进模型的 prompt 也只能有那一句。**
    /// 快照对了而 prompt 拿整段，等于没选的那半句被偷偷用了一次——
    /// 而纪要是从 prompt 生成的，于是"只该句进入"在最终产物上并不成立。
    func testPromptRendersOnlyTheChosenSentence() async throws {
        let session = try requireSession()
        await session.bind(sessionID: "unused")
        let rendered = MinutesGenerator.userSupplements(
            exchanges: [
                InnerOSExchange(
                    id: "qa-1", sessionID: "s", question: "灰度怎么排？",
                    answerText: "灰度下周三开始。先跑 5% 流量。回滚预案要提前写好。",
                    status: .ready, inMinutes: true,
                    minutesExcerpt: "先跑 5% 流量。"
                )
            ],
            verifiedExchangeIDs: ["qa-1"]
        )
        XCTAssertTrue(rendered.contains("先跑 5% 流量。"))
        XCTAssertFalse(rendered.contains("回滚预案"), "没选的那句不得进 prompt")
        XCTAssertFalse(rendered.contains("灰度下周三开始"))
    }

    /// 句子切分要老实：中文标点断句，数字与小数点不切开。
    func testSentenceSplittingKeepsDecimalsIntact() {
        let sentences = InnerOSSession.selectableSentences(
            in: "灰度下周三开始。先跑 5% 流量，误差 0.5% 以内！回滚预案提前写。"
        )
        XCTAssertEqual(
            sentences, ["灰度下周三开始。", "先跑 5% 流量，误差 0.5% 以内！", "回滚预案提前写。"]
        )
    }

    /// 空答案切不出句子，界面就不该给出可选的东西。
    func testSentenceSplittingOfEmptyAnswerIsEmpty() {
        XCTAssertTrue(InnerOSSession.selectableSentences(in: "   ").isEmpty)
    }
}
