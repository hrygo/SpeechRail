import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 制作项目的**身份与不可变性**测试：不联网、不合成、不碰播放。
///
/// 这里要证明的是目标架构 §6 的两条：制作项目保存当时的 voice revision 与 plan 身份；
/// 全局默认变化不会回头改写已有项目，刷新只可能由用户显式重做产生新的 render revision。
@MainActor
final class CreativeWorkStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-works-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeWork(
        id: String,
        script: String = "第一行文稿",
        voiceID: String = "voice_a",
        voiceRevision: String? = nil,
        planID: String? = nil,
        renderRevision: Int = 1
    ) -> CreativeWork {
        CreativeWork(
            id: id,
            title: CreativeWork.generatedTitle(fromScript: script),
            scriptText: script,
            voiceID: voiceID,
            voiceName: "音色 A",
            voiceRevision: voiceRevision,
            planID: planID,
            renderRevision: renderRevision,
            // 索引用 ISO8601（秒精度）落盘：整秒时间戳才能原样往返。
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            durationSeconds: 1.5,
            audioFileName: "\(id).wav"
        )
    }

    func testRenderIdentityRoundTripsThroughTheIndex() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(
            id: "work_a",
            voiceRevision: "rev_7",
            planID: "plan_0123456789abcdef0123456789abcdef",
            renderRevision: 3
        )
        try store.save(work, audioData: Data([1, 2, 3, 4]))

        let loaded = try XCTUnwrap(try store.list().first)

        XCTAssertEqual(loaded.voiceRevision, "rev_7")
        XCTAssertEqual(loaded.planID, "plan_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(loaded.renderRevision, 3)
        XCTAssertEqual(loaded, work)
    }

    /// 老 `works.json` 没有身份字段：必须原样读出来，而且**不回写磁盘**。
    func testLegacyRecordWithoutIdentityFieldsStillLoads() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: directory.appendingPathComponent("work_legacy.wav"))
        let legacy = """
        [
          {
            "id" : "work_legacy",
            "title" : "第一行文稿",
            "scriptText" : "第一行文稿",
            "voiceID" : "voice_a",
            "voiceName" : "音色 A",
            "createdAt" : "2026-09-01T00:00:00Z",
            "durationSeconds" : 1.5,
            "audioFileName" : "work_legacy.wav"
          }
        ]
        """
        let indexURL = directory.appendingPathComponent("works.json")
        try Data(legacy.utf8).write(to: indexURL)

        let store = CreativeWorkStore(directory: directory)
        let loaded = try XCTUnwrap(try store.list().first)

        XCTAssertEqual(loaded.id, "work_legacy")
        XCTAssertNil(loaded.voiceRevision, "老记录没有捕捉到音色 revision，读成 nil 而不是猜一个")
        XCTAssertNil(loaded.planID)
        XCTAssertEqual(loaded.renderRevision, 1, "老记录按第 1 次制作读")
        XCTAssertEqual(try Data(contentsOf: indexURL), Data(legacy.utf8), "只读不落盘")
    }

    func testNewRenderAppendsWithoutRewritingExistingProjects() throws {
        let store = CreativeWorkStore(directory: directory)
        let first = makeWork(id: "work_first", voiceRevision: "rev_1", planID: "plan_first")
        try store.save(first, audioData: Data([1, 2, 3, 4]))

        // 全局默认（音色/档位）变了之后又做了一次同一份文稿：
        // 新作品带新的 plan 与 revision，旧作品一个字都不许改。
        let second = makeWork(
            id: "work_second",
            voiceRevision: "rev_2",
            planID: "plan_second",
            renderRevision: try store.nextRenderRevision(
                scriptText: first.scriptText,
                voiceID: first.voiceID
            )
        )
        try store.save(second, audioData: Data([5, 6, 7, 8]))

        let works = try store.list()
        XCTAssertEqual(works.count, 2, "两次显式制作是两条记录，不是就地覆盖")
        let reloadedFirst = try XCTUnwrap(works.first { $0.id == "work_first" })
        XCTAssertEqual(reloadedFirst.voiceRevision, "rev_1")
        XCTAssertEqual(reloadedFirst.planID, "plan_first")
        XCTAssertEqual(reloadedFirst.renderRevision, 1)
        let reloadedSecond = try XCTUnwrap(works.first { $0.id == "work_second" })
        XCTAssertEqual(reloadedSecond.planID, "plan_second")
        XCTAssertEqual(reloadedSecond.renderRevision, 2, "重做一次就是新的 render revision")
    }

    func testRenameKeepsTheRenderIdentityOfTheProject() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_rename", voiceRevision: "rev_9", planID: "plan_9", renderRevision: 4)
        try store.save(work, audioData: Data([9, 9, 9, 9]))

        let renamed = try store.rename(work, title: "新名字")
        let reloaded = try XCTUnwrap(try store.list().first)

        XCTAssertEqual(renamed.title, "新名字")
        XCTAssertEqual(reloaded.voiceRevision, "rev_9")
        XCTAssertEqual(reloaded.planID, "plan_9")
        XCTAssertEqual(reloaded.renderRevision, 4)
        XCTAssertEqual(reloaded.audioFileName, work.audioFileName, "改名不动音频文件")
    }

    func testNextRenderRevisionOnlyCountsTheSameScriptAndVoice() throws {
        let store = CreativeWorkStore(directory: directory)
        try store.save(
            makeWork(id: "work_a", script: "甲", voiceID: "voice_a", renderRevision: 2),
            audioData: Data([1, 2])
        )
        try store.save(
            makeWork(id: "work_b", script: "乙", voiceID: "voice_a"),
            audioData: Data([1, 2])
        )

        XCTAssertEqual(try store.nextRenderRevision(scriptText: "甲", voiceID: "voice_a"), 3)
        XCTAssertEqual(try store.nextRenderRevision(scriptText: "乙", voiceID: "voice_a"), 2)
        XCTAssertEqual(
            try store.nextRenderRevision(scriptText: "甲", voiceID: "voice_b"),
            1,
            "换音色就是另一条制作线，从第 1 次重新数"
        )
    }
}
