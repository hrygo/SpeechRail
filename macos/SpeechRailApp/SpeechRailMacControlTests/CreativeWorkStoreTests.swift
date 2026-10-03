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

    /// 作品库在提交时补上文件字节摘要，所以"是不是同一条作品"要比对身份，
    /// 摘要单独验证确实对应真实落盘字节。
    private func assertSameWork(
        _ actual: CreativeWork,
        _ expected: CreativeWork,
        audio: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.withProvenance(expected.provenance), expected, file: file, line: line)
        XCTAssertEqual(
            actual.provenance.audioFileSHA256,
            CreativeWorkTransaction.digest(audio),
            "保存后的文件摘要必须对应真实落盘字节",
            file: file,
            line: line
        )
    }

    private func assertSameWorks(
        _ actual: [CreativeWork],
        _ expected: [CreativeWork],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, work) in actual.enumerated() where index < expected.count {
            XCTAssertEqual(
                work.withProvenance(expected[index].provenance),
                expected[index],
                file: file,
                line: line
            )
        }
    }

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
        assertSameWork(loaded, work, audio: Data([1, 2, 3, 4]))
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
        XCTAssertEqual(loaded.provenance, .legacyUnknown, "老记录没有追溯字段，不回填")
        XCTAssertNil(loaded.provenance.recipe)
        XCTAssertNil(loaded.provenance.audioFileSHA256)
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

    // MARK: - Recoverable persistence

    func testSavingTheSameResultTwiceKeepsTheOriginalCreationDate() throws {
        let store = CreativeWorkStore(directory: directory)
        let audio = Data([1, 2, 3, 4])
        let first = makeWork(id: "work_same")
        try store.save(first, audioData: audio)

        let retry = CreativeWork(
            id: first.id,
            title: "重试时换过的标题",
            scriptText: first.scriptText,
            voiceID: first.voiceID,
            voiceName: first.voiceName,
            voiceRevision: first.voiceRevision,
            planID: first.planID,
            renderRevision: first.renderRevision,
            createdAt: Date(timeIntervalSince1970: 1_780_000_100),
            durationSeconds: first.durationSeconds,
            audioFileName: first.audioFileName
        )

        let committed = try store.save(retry, audioData: audio)

        assertSameWork(committed, first, audio: audio)
        assertSameWorks(try store.list(), [first])
    }

    func testReusingAWorkIDForDifferentAudioPreservesTheOriginalWork() throws {
        let store = CreativeWorkStore(directory: directory)
        let original = makeWork(id: "work_conflict")
        try store.save(original, audioData: Data([1, 2, 3, 4]))

        XCTAssertThrowsError(
            try store.save(original, audioData: Data([9, 9, 9, 9]))
        ) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .workConflict)
        }

        assertSameWorks(try store.list(), [original])
        XCTAssertEqual(try store.loadAudio(for: original), Data([1, 2, 3, 4]))
    }

    func testIndexWriteFailureBeforeCommitLeavesTheOriginalWorkIntact() throws {
        let original = makeWork(id: "work_existing")
        try CreativeWorkStore(directory: directory).save(
            original,
            audioData: Data([1, 2, 3, 4])
        )
        let failing = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "works.json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        let store = CreativeWorkStore(directory: directory, fileOperations: failing)
        let added = makeWork(id: "work_added", script: "第二份文稿")

        XCTAssertThrowsError(try store.save(added, audioData: Data([5, 6, 7, 8])))

        assertSameWorks(try store.list(), [original])
        XCTAssertEqual(try store.loadAudio(for: original), Data([1, 2, 3, 4]))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("work_added.wav").path
            ),
            "没有提交进索引的新音频不能留在正式作品目录"
        )
    }

    func testRestartRecoversAnUncommittedSaveWithoutPublishingOrphanAudio() throws {
        let original = makeWork(id: "work_before_crash")
        try CreativeWorkStore(directory: directory).save(
            original,
            audioData: Data([1, 2, 3, 4])
        )
        let interrupting = CreativeWorkFileOperations(
            moveInterceptor: { _, destination in
                if destination.lastPathComponent == "work_after_crash.wav" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let crashingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: interrupting
        )

        XCTAssertThrowsError(
            try crashingStore.save(
                makeWork(id: "work_after_crash", script: "中断前生成"),
                audioData: Data([5, 6, 7, 8])
            )
        ) { error in
            XCTAssertEqual(
                error as? CreativeWorkTransactionInterruption,
                .simulatedProcessExit
            )
        }

        let reopened = CreativeWorkStore(directory: directory)
        assertSameWorks(try reopened.list(), [original])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("work_after_crash.wav").path
            )
        )
    }

    func testRestartRemovesAudioThatWasPublishedBeforeTheIndexCommit() throws {
        let original = makeWork(id: "work_before_audio_sync_crash")
        try CreativeWorkStore(directory: directory).save(
            original,
            audioData: Data([1, 2, 3, 4])
        )
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "work_audio_sync_crash.wav" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let crashingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: interrupting
        )

        XCTAssertThrowsError(
            try crashingStore.save(
                makeWork(id: "work_audio_sync_crash", script: "音频已发布"),
                audioData: Data([5, 6, 7, 8])
            )
        ) { error in
            XCTAssertEqual(
                error as? CreativeWorkTransactionInterruption,
                .simulatedProcessExit
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("work_audio_sync_crash.wav").path
            ),
            "模拟中断发生在音频发布之后"
        )

        let reopened = CreativeWorkStore(directory: directory)
        assertSameWorks(try reopened.list(), [original])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("work_audio_sync_crash.wav").path
            ),
            "索引未提交时，重启必须回收刚发布的音频"
        )
    }

    func testRestartKeepsASaveWhoseIndexCommitAlreadySucceeded() throws {
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let crashingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: interrupting
        )
        let work = makeWork(id: "work_committed")

        XCTAssertThrowsError(
            try crashingStore.save(work, audioData: Data([7, 7, 7, 7]))
        ) { error in
            XCTAssertEqual(
                error as? CreativeWorkTransactionInterruption,
                .simulatedProcessExit
            )
        }

        let reopened = CreativeWorkStore(directory: directory)
        assertSameWorks(try reopened.list(), [work])
        XCTAssertEqual(try reopened.loadAudio(for: work), Data([7, 7, 7, 7]))
    }

    func testDeleteFailureBeforeIndexCommitKeepsTheWorkAndItsAudio() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_delete_failure")
        let audio = Data([3, 1, 4])
        try store.save(work, audioData: audio)
        let failing = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "works.json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        let failingStore = CreativeWorkStore(directory: directory, fileOperations: failing)

        XCTAssertThrowsError(try failingStore.delete(work))

        assertSameWorks(try store.list(), [work])
        XCTAssertEqual(try store.loadAudio(for: work), audio)
    }

    func testRestartCompletesADeleteWhoseIndexCommitAlreadySucceeded() throws {
        let work = makeWork(id: "work_delete_committed")
        let audio = Data([2, 7, 1, 8])
        try CreativeWorkStore(directory: directory).save(work, audioData: audio)

        // 新建一个中断实例：删除的索引提交后会模拟进程退出，音频尚未隔离。
        let deleteInterrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let deletingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: deleteInterrupting
        )
        XCTAssertThrowsError(try deletingStore.delete(work)) { error in
            XCTAssertEqual(
                error as? CreativeWorkTransactionInterruption,
                .simulatedProcessExit
            )
        }

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertTrue(try reopened.list().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(work.audioFileName).path
            )
        )
        let recoveryFiles = try FileManager.default.subpathsOfDirectory(
            atPath: directory.appendingPathComponent(".recovery", isDirectory: true).path
        )
        XCTAssertTrue(
            recoveryFiles.contains { $0.hasSuffix(work.audioFileName) },
            "删除已提交后重启必须把音频移入受管恢复区，而不是留在作品目录"
        )
    }

    func testRenameFailureBeforeIndexCommitKeepsTheOriginalTitle() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_rename_failure")
        try store.save(work, audioData: Data([4, 4, 4, 4]))
        let failing = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "works.json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        let failingStore = CreativeWorkStore(directory: directory, fileOperations: failing)

        XCTAssertThrowsError(try failingStore.rename(work, title: "不会写进去"))

        assertSameWorks(try store.list(), [work])
        XCTAssertEqual(try store.loadAudio(for: work), Data([4, 4, 4, 4]))
    }

    func testRestartKeepsARenameWhoseIndexCommitAlreadySucceeded() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_rename_committed")
        try store.save(work, audioData: Data([5, 6, 7, 8]))
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let interruptedStore = CreativeWorkStore(
            directory: directory,
            fileOperations: interrupting
        )

        XCTAssertThrowsError(try interruptedStore.rename(work, title: "重启后仍保留"))

        let reopened = CreativeWorkStore(directory: directory)
        let reloaded = try XCTUnwrap(try reopened.list().first)
        XCTAssertEqual(reloaded.title, "重启后仍保留")
        XCTAssertEqual(try reopened.loadAudio(for: reloaded), Data([5, 6, 7, 8]))
        XCTAssertEqual(try reopened.list(), [reloaded], "恢复必须幂等")
    }

    func testUnknownPendingJournalFailsClosedWithoutTouchingUserFiles() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_with_bad_journal")
        let audio = Data([8, 8, 8, 8])
        try store.save(work, audioData: audio)
        let transactionDirectory = directory
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(String(repeating: "a", count: 32), isDirectory: true)
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try Data("not a journal".utf8).write(
            to: transactionDirectory.appendingPathComponent("journal.json")
        )

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .recoveryRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: transactionDirectory.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(work.audioFileName)), audio)
    }

    func testAnUnindexedAudioFileIsNeverAdoptedOrOverwritten() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let orphanURL = directory.appendingPathComponent("work_orphan.wav")
        let orphanAudio = Data([9, 1, 9, 1])
        try orphanAudio.write(to: orphanURL)
        let work = makeWork(id: "work_orphan")

        let store = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try store.save(work, audioData: Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .workConflict)
        }

        XCTAssertEqual(try Data(contentsOf: orphanURL), orphanAudio)
        XCTAssertTrue(try store.list().isEmpty, "未知音频不能被猜成一条作品")
    }

    func testDeletingAnAlreadyCommittedWorkIsIdempotent() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_delete_twice")
        try store.save(work, audioData: Data([1, 3, 5, 7]))

        try store.delete(work)
        XCTAssertNoThrow(try store.delete(work))
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testASavedAudioSymlinkIsNeverFollowedAsUserAudio() throws {
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-outside-\(UUID().uuidString).wav")
        let outsideAudio = Data([6, 6, 6, 6])
        try outsideAudio.write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let work = makeWork(id: "work_symlink")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(work.audioFileName),
            withDestinationURL: outsideURL
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([work]).write(
            to: directory.appendingPathComponent("works.json"),
            options: [.atomic]
        )

        let store = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try store.loadAudio(for: work)) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .audioUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideAudio)
    }

    func testStagedAudioWriteFailureLeavesTheLibraryUntouched() throws {
        let original = makeWork(id: "work_before_enospc")
        let audio = Data([1, 2, 3, 4])
        try CreativeWorkStore(directory: directory).save(original, audioData: audio)
        let outOfSpace = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "staged.wav" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }
        )
        let failingStore = CreativeWorkStore(directory: directory, fileOperations: outOfSpace)
        let added = makeWork(id: "work_after_enospc", script: "磁盘满时生成")

        XCTAssertThrowsError(try failingStore.save(added, audioData: Data([5, 6, 7, 8])))

        assertSameWorks(try CreativeWorkStore(directory: directory).list(), [original])
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(original.audioFileName)),
            audio
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(added.audioFileName).path
            ),
            "暂存写入失败时不应发布任何正式音频"
        )
    }

    func testJournalWriteFailureLeavesTheLibraryUntouched() throws {
        let original = makeWork(id: "work_before_journal_failure")
        try CreativeWorkStore(directory: directory).save(
            original,
            audioData: Data([1, 2, 3, 4])
        )
        let journalFailing = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "journal.json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        let failingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: journalFailing
        )
        let added = makeWork(id: "work_after_journal_failure", script: "回执写不进去")

        XCTAssertThrowsError(try failingStore.save(added, audioData: Data([5, 6, 7, 8])))

        assertSameWorks(try CreativeWorkStore(directory: directory).list(), [original])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(added.audioFileName).path
            ),
            "没有可恢复的 journal 时不许发布音频"
        )
    }

    func testACorruptedIndexIsNotReadAsAnEmptyLibrary() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let indexURL = directory.appendingPathComponent("works.json")
        let corrupted = Data("{ this is not an index".utf8)
        try corrupted.write(to: indexURL)

        let store = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .storageUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), corrupted, "坏索引必须原样保留")
    }

    func testAFutureJournalSchemaFailsClosedWithoutTouchingUserFiles() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_future_journal")
        let audio = Data([8, 8, 8, 8])
        try store.save(work, audioData: audio)
        let transactionID = String(repeating: "b", count: 32)
        let transactionDirectory = directory
            .appendingPathComponent(".transactions", isDirectory: true)
            .appendingPathComponent(transactionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        let futureJournal = """
        {
          "schemaVersion" : 2,
          "transactionID" : "\(transactionID)",
          "operation" : "save",
          "workID" : "\(work.id)",
          "audioFileName" : "\(work.audioFileName)",
          "committedIndexSHA256" : "\(String(repeating: "c", count: 64))"
        }
        """
        let journalURL = transactionDirectory.appendingPathComponent("journal.json")
        try Data(futureJournal.utf8).write(to: journalURL)

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .recoveryRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(work.audioFileName)),
            audio,
            "认不出的 journal 不能触发任何用户文件变动"
        )
    }

    func testTwoPendingTransactionsFailClosedUntilOneIsResolved() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_two_transactions")
        let audio = Data([3, 5, 7])
        try store.save(work, audioData: audio)
        let transactionsDirectory = directory.appendingPathComponent(
            ".transactions",
            isDirectory: true
        )
        let digests = try (0..<2).map { offset -> (String, URL) in
            let transactionID = String(repeating: offset == 0 ? "d" : "e", count: 32)
            let transactionDirectory = transactionsDirectory
                .appendingPathComponent(transactionID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
            let journal = CreativeWorkTransactionJournal(
                transactionID: transactionID,
                operation: .save,
                workID: work.id,
                audioFileName: work.audioFileName,
                audioSHA256: CreativeWorkTransaction.digest(audio),
                previousIndexSHA256: nil,
                previousIndexData: nil,
                committedIndexSHA256: String(repeating: "f", count: 64)
            )
            try CreativeWorkTransaction
                .encodeJournal(journal)
                .write(to: transactionDirectory.appendingPathComponent("journal.json"))
            return (transactionID, transactionDirectory)
        }

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(
                error as? CreativeWorkStoreError,
                .recoveryRequired,
                "同时存在两个未归档事务时不能猜哪个有效"
            )
        }

        try FileManager.default.removeItem(at: digests[1].1)
        let afterResolving = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try afterResolving.list()) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .recoveryRequired)
        }
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(work.audioFileName)),
            audio,
            "无论恢复能否判定，原作品音频都不能被移动或删除"
        )
    }

    func testRestartNeverQuarantinesAnAudioSymlinkLeftAtTheManagedPath() throws {
        let work = makeWork(id: "work_delete_symlink")
        let audio = Data([4, 2, 6])
        try CreativeWorkStore(directory: directory).save(work, audioData: audio)
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let deletingStore = CreativeWorkStore(
            directory: directory,
            fileOperations: interrupting
        )
        XCTAssertThrowsError(try deletingStore.delete(work))

        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-outside-delete-\(UUID().uuidString).wav")
        let outsideAudio = Data([1, 1, 1, 1])
        try outsideAudio.write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let audioURL = directory.appendingPathComponent(work.audioFileName)
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.createSymbolicLink(at: audioURL, withDestinationURL: outsideURL)

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideAudio, "不能移动或删除库外文件")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL.path),
            "未知链接原位保留，交给用户处理"
        )
    }
}
