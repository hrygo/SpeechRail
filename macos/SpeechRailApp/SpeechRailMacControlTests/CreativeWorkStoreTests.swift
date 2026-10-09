import Foundation
import SpeechRailControlKit
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

    func testSuccessfulSaveRefusesDamagedPublishedAudioAndKeepsRecoveryJournal() throws {
        let root = try XCTUnwrap(directory)
        let work = makeWork(id: "work_damaged")
        let store = CreativeWorkStore(
            directory: root,
            fileOperations: CreativeWorkFileOperations(syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    try Data("damaged".utf8).write(to: root.appendingPathComponent(work.audioFileName))
                }
            })
        )
        XCTAssertThrowsError(try store.save(work, audioData: Data("original".utf8))) { error in
            XCTAssertEqual(error.localizedDescription, CreativeWorkStoreError.recoveryRequired.localizedDescription)
        }
        XCTAssertThrowsError(try CreativeWorkStore(directory: root).list()) { error in
            XCTAssertEqual(error.localizedDescription, CreativeWorkStoreError.recoveryRequired.localizedDescription)
        }
    }

    private func makeWork(
        id: String,
        script: String = "第一行文稿",
        voiceID: String = "voice_a",
        voiceRevision: String? = nil,
        planID: String? = nil,
        renderRevision: Int = 1,
        audioFileName: String? = nil
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
            audioFileName: audioFileName ?? "\(id).wav"
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
        XCTAssertNil(loaded.provenance.requestID)
        XCTAssertNil(loaded.provenance.receiptID)
        XCTAssertNil(loaded.provenance.receiptStatus)
        XCTAssertNil(loaded.provenance.receiptCompletedAt)
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

    /// `isSafeIdentifier` 是作品目录唯一的逃逸防线。
    ///
    /// `URL.appendingPathComponent(_:)` 自己**不会**拒绝 `../`——它只是拼接。
    /// `audioFileName == "\(work.id).wav"`，所以 id 一旦能带路径分隔符或点号，
    /// 落盘位置就跟着跑到作品目录外面去。字符集、长度上限、不许点号这三条性质
    /// 必须分别被钉住，不能只测「整体拒绝某个恶意串」——那无法区分是哪一条在起作用。
    func testAWorkWhoseIDCouldEscapeTheLibraryDirectoryIsRefused() throws {
        // 库放在测试自己拥有的子目录里，「目录外」也留在测试沙箱内——
        // 直接拿系统临时目录当基准会跨用例互相污染。
        let library = directory.appendingPathComponent("library", isDirectory: true)
        let store = CreativeWorkStore(directory: library)
        let outside = directory.appendingPathComponent("escaped.wav")
        let hostileIDs = [
            "../escaped",
            "../../escaped",
            "nested/id",
            "dot.id",
            "with space",
            String(repeating: "x", count: 81),
        ]

        for hostileID in hostileIDs {
            let work = makeWork(id: hostileID)
            XCTAssertThrowsError(
                try store.save(work, audioData: Data([1, 2, 3, 4])),
                "标识符 \(hostileID) 必须被拒绝"
            ) { error in
                XCTAssertEqual(
                    error as? CreativeWorkStoreError,
                    .invalidWorkID,
                    "标识符 \(hostileID) 必须报标识符非法，而不是别的错误"
                )
            }
            // 其余入口用的是同一个守卫，但各有各的调用点，逐个钉住。
            XCTAssertThrowsError(
                try store.rename(work, title: "改名"),
                "rename 必须拒绝 \(hostileID)"
            ) { error in
                XCTAssertEqual(error as? CreativeWorkStoreError, .invalidWorkID)
            }
            XCTAssertThrowsError(
                try store.loadAudio(for: work),
                "loadAudio 必须拒绝 \(hostileID)"
            ) { error in
                XCTAssertEqual(error as? CreativeWorkStoreError, .invalidWorkID)
            }
            XCTAssertThrowsError(
                try store.delete(work),
                "delete 必须拒绝 \(hostileID)"
            ) { error in
                XCTAssertEqual(error as? CreativeWorkStoreError, .invalidWorkID)
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "恶意标识符不得在作品目录外留下任何文件"
        )
        XCTAssertEqual(try store.list(), [], "被拒绝的作品不得进入索引")
    }

    /// 覆盖同一条作品的既有音频若是符号链接，不得顺着它读写。
    func testSavingOverASymlinkedAudioIsRefused() throws {
        let work = makeWork(id: "work_symlink")
        let store = CreativeWorkStore(directory: directory)
        try store.save(work, audioData: Data([1, 2, 3, 4]))

        let audioURL = directory.appendingPathComponent(work.audioFileName)
        let target = directory.appendingPathComponent("elsewhere.wav")
        try Data([9, 9, 9]).write(to: target)
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.createSymbolicLink(at: audioURL, withDestinationURL: target)

        XCTAssertThrowsError(
            try store.save(work, audioData: Data([5, 6, 7, 8]))
        ) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .audioUnavailable)
        }
        XCTAssertEqual(
            try Data(contentsOf: target),
            Data([9, 9, 9]),
            "符号链接指向的文件不得被这次保存改写"
        )
    }

    /// 标题是用户之后唯一会看到的标识：空标题或纯空白不得写进索引。
    func testRenamingToABlankTitleIsRefused() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_blank_title")
        try store.save(work, audioData: Data([1, 2, 3, 4]))

        for blank in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(
                try store.rename(work, title: blank),
                "标题 \(blank.debugDescription) 必须被拒绝"
            ) { error in
                XCTAssertEqual(error as? CreativeWorkStoreError, .invalidTitle)
            }
        }
        XCTAssertEqual(
            try store.list().first?.title,
            work.title,
            "被拒绝的改名不得改变已保存的标题"
        )
    }

    /// 音频文件名必须由标识符推导，不能由调用方给。
    ///
    /// `isSafeIdentifier(work.id)` 只管住了 `id`；`audioFileName` 是另一个字段，
    /// 同样是拼进路径的。放它过去，一个合法 `id` 配一个 `../../escaped.wav`
    /// 就能把音频写到作品目录之外——这正是 #161 那条防线要挡的事，
    /// 但守卫落在第二个字段上。
    func testAudioFileNameMustBeDerivedFromTheWorkID() throws {
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("escaped-\(UUID().uuidString).wav")
        let store = CreativeWorkStore(directory: directory)

        for hostileName in [
            "../\(outside.lastPathComponent)",
            "nested/other.wav",
            "绝对名字.wav",
        ] {
            let work = makeWork(id: "work_\(UUID().uuidString)", audioFileName: hostileName)
            XCTAssertThrowsError(
                try store.save(work, audioData: Data([1, 2, 3, 4])),
                "音频文件名 \(hostileName) 必须被拒绝"
            ) { error in
                XCTAssertEqual(error as? CreativeWorkStoreError, .invalidWorkID)
            }
            XCTAssertEqual(try store.list(), [], "被拒绝的作品不得进入索引")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "音频文件名不得把文件写到作品目录之外"
        )
    }

    /// 空音频不得进入索引：作品一旦列出来就必须真的有声音可放。
    func testSavingEmptyAudioIsRefused() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_empty_audio")

        XCTAssertThrowsError(try store.save(work, audioData: Data())) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .audioUnavailable)
        }
        XCTAssertEqual(try store.list(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(work.audioFileName).path
            ),
            "被拒绝的保存不得留下 0 字节文件"
        )
    }

    /// 磁盘上变成 0 字节的音频读回来时必须报不可用，而不是把空数据交给播放器。
    func testLoadingAZeroByteAudioReportsItAsUnavailable() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_truncated_audio")
        try store.save(work, audioData: Data([1, 2, 3, 4]))
        try Data().write(to: directory.appendingPathComponent(work.audioFileName))

        XCTAssertThrowsError(try store.loadAudio(for: work)) { error in
            XCTAssertEqual(error as? CreativeWorkStoreError, .audioUnavailable)
        }
    }

    /// 改名同样要收敛长度：作品列表与导出的文件名都按这个上限渲染。
    func testRenamingClampsAnOverlongTitle() throws {
        let store = CreativeWorkStore(directory: directory)
        let work = makeWork(id: "work_long_title")
        try store.save(work, audioData: Data([1, 2, 3, 4]))
        let overlong = String(repeating: "长", count: CreativeWork.titleMaximumLength + 40)

        let renamed = try store.rename(work, title: overlong)

        XCTAssertEqual(
            renamed.title.count,
            CreativeWork.titleMaximumLength + CreativeWork.titleEllipsis.count,
            "超长标题必须收敛到上限，而不是原样写进索引"
        )
        XCTAssertEqual(try store.list().first?.title, renamed.title)
    }

    /// 改名必须按标识符定位到**那一条**，而不是按它在索引里的位置。
    ///
    /// 此前所有改名用例的作品库里都只有一件作品，于是「取第一条」与
    /// 「取 ID 匹配的那条」结果必然相同——把
    /// `works.firstIndex(where: { $0.id == work.id })` 改成永远取第 0 条，
    /// 全量 535 条测试仍然全绿。库里只有一件时，第 0 条永远是正确答案。
    func testRenamingOneWorkLeavesTheOtherWorksUntouched() throws {
        let store = CreativeWorkStore(directory: directory)
        let first = makeWork(id: "work_rename_first", script: "第一件文稿")
        let second = makeWork(id: "work_rename_second", script: "第二件文稿")
        let third = makeWork(id: "work_rename_third", script: "第三件文稿")
        try store.save(first, audioData: Data([1, 2, 3, 4]))
        try store.save(second, audioData: Data([5, 6, 7, 8]))
        try store.save(third, audioData: Data([9, 10, 11, 12]))

        // 改中间那一件：按位置取的实现会错改第一件。
        let renamed = try store.rename(second, title: "只改这一件")

        XCTAssertEqual(renamed.id, second.id, "改名结果必须是被点中的那一件")
        XCTAssertEqual(renamed.title, "只改这一件")
        let titlesByID = Dictionary(
            uniqueKeysWithValues: try store.list().map { ($0.id, $0.title) }
        )
        XCTAssertEqual(
            titlesByID["work_rename_first"],
            first.title,
            "改第二件不得动第一件"
        )
        XCTAssertEqual(titlesByID["work_rename_second"], "只改这一件")
        XCTAssertEqual(
            titlesByID["work_rename_third"],
            third.title,
            "改第二件不得动第三件"
        )
    }

    /// 没有配方摘要的作品不提供「段落返修」入口。
    ///
    /// 段落返修的前提是「这次重做与原作品是同一制作条件」，只有配方摘要能证明它。
    /// 老作品读作 `legacyUnknown`、摘要为 nil，重做必然被拒。入口若照旧出现，
    /// 用户会打开弹层、点下重做、读到一句「无法安全地只重做其中一段」——
    /// 一个点下去一定失败的动作。
    func testSegmentRedoIsOfferedOnlyWhenTheRecipeCanProveTheConditions() {
        XCTAssertFalse(
            RenderProvenanceSnapshot.legacyUnknown.supportsSegmentRedo,
            "老作品没有配方摘要，不该出现段落返修入口"
        )
        XCTAssertFalse(
            RenderProvenanceSnapshot(state: .partial, reason: nil).supportsSegmentRedo,
            "连配方都没有时同样不该出现入口"
        )
        XCTAssertFalse(
            RenderProvenanceSnapshot(
                state: .verified,
                reason: nil,
                recipe: RenderRecipeSnapshot(
                    state: .partial,
                    missingFields: ["parameters.seed_policy"],
                    digest: nil,
                    voiceID: "ryan"
                )
            ).supportsSegmentRedo,
            "配方不完整就没有摘要，入口同样不该出现"
        )
        XCTAssertTrue(
            RenderProvenanceSnapshot(
                state: .verified,
                reason: nil,
                recipe: RenderRecipeSnapshot(
                    state: .complete,
                    missingFields: [],
                    digest: String(repeating: "e", count: 64),
                    voiceID: "ryan"
                )
            ).supportsSegmentRedo,
            "事实齐全的配方才允许按段落返修"
        )
    }


    /// 失败的提交必须**当场**收尾，不许把残局留给下一次打开。
    ///
    /// 这条断言必须发生在任何触发恢复的调用之前。`list()` / `loadAudio()` 都会走
    /// `withRecoveredLibrary` → `recoverPendingTransactionsUnlocked()`，也就是说
    /// 「失败之后紧接着读一次库」量到的是**恢复之后**的状态——分不清是立即回滚了，
    /// 还是留下了残局、等下次打开才被清掉。实测把 `rollbackUncommittedMutationUnlocked`
    /// 整段删掉，25 条测试依然全绿，原因就在这里。
    func testAFailedCommitLeavesNothingBehindBeforeTheLibraryIsReopened() throws {
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

        XCTAssertThrowsError(
            try store.save(makeWork(id: "work_added"), audioData: Data([5, 6, 7, 8]))
        )

        // 到这里为止没有任何调用触碰过作品库，磁盘就是失败瞬间的真实状态。
        let audioFiles = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertEqual(
            audioFiles,
            ["work_existing.wav"],
            "索引写失败后，未提交的音频不得留在正式作品目录"
        )

        let pending = try FileManager.default
            .contentsOfDirectory(
                atPath: directory.appendingPathComponent(".transactions").path
            )
        XCTAssertEqual(
            pending,
            [],
            "失败的提交不得留下待决事务——留着会让下次打开先面对一个歧义状态"
        )
    }

    /// journal 与事务目录必须先于索引落盘。
    ///
    /// 真实进程退出不执行任何 `catch`：若索引已经提交、而 journal 还只在页缓存里，
    /// 下次打开就少了判定「这次提交到底成没成」的唯一依据，只能 fail-closed
    /// 让用户自己进目录删文件。fsync 的顺序本身就是契约，必须被钉住。
    func testTheJournalReachesDiskBeforeTheIndexIsCommitted() throws {
        var synced: [URL] = []
        let recording = CreativeWorkFileOperations(
            syncInterceptor: { url in synced.append(url) }
        )
        let store = CreativeWorkStore(directory: directory, fileOperations: recording)

        try store.save(makeWork(id: "work_sync_order"), audioData: Data([1, 2, 3]))

        func position(where predicate: (URL) -> Bool) -> Int? {
            synced.firstIndex(where: predicate)
        }
        let journal = position { $0.lastPathComponent == "journal.json" }
        let transactionDirectory = position { $0.path.contains("/.transactions/") }
        let indexCommit = position { $0.lastPathComponent == "works.json" }

        XCTAssertNotNil(journal, "journal 必须被同步落盘")
        XCTAssertNotNil(transactionDirectory, "事务目录本身也必须被同步")
        XCTAssertNotNil(indexCommit, "索引必须被同步落盘")

        // 断言失败后代码仍会继续执行，先解包再比较，避免越界把整个测试进程带倒。
        guard let journal, let transactionDirectory, let indexCommit else { return }
        XCTAssertLessThan(
            journal,
            indexCommit,
            "journal 必须先于索引落盘，否则崩溃后无从判定这次提交是否已成"
        )
        XCTAssertLessThan(
            transactionDirectory,
            indexCommit,
            "事务目录必须先于索引落盘"
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

    /// 已经隔离进事务目录的旧音频，不得被后来出现的同名新音频顶掉。
    ///
    /// 恢复分两步：先把作品目录里的音频移进事务目录，再把整个事务目录搬进
    /// `.recovery`。第一步完成后进程退出、且期间有同名新音频落盘时，
    /// 第二次恢复会同时看到两个文件——这时必须保住先隔离的那一个。
    func testRecoveryDoesNotOverwriteAnAlreadyPreservedAudioFile() throws {
        let work = makeWork(id: "work_preserved_exists")
        try CreativeWorkStore(directory: directory).save(work, audioData: Data([1, 1, 1, 1]))

        let deleteInterrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        XCTAssertThrowsError(
            try CreativeWorkStore(
                directory: directory,
                fileOperations: deleteInterrupting
            ).delete(work)
        )

        let transactions = directory.appendingPathComponent(".transactions", isDirectory: true)
        let transactionDirectory = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil)
                .first
        )
        let preserved = Data([7, 7, 7, 7])
        try preserved.write(
            to: transactionDirectory.appendingPathComponent(work.audioFileName)
        )
        // 同名的新音频又出现在作品目录里。
        try Data([8, 8, 8, 8]).write(
            to: directory.appendingPathComponent(work.audioFileName)
        )

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertTrue(try reopened.list().isEmpty)

        let recovered = directory
            .appendingPathComponent(".recovery", isDirectory: true)
            .appendingPathComponent(transactionDirectory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(work.audioFileName)
        XCTAssertEqual(
            try Data(contentsOf: recovered),
            preserved,
            "先隔离的旧音频不得被同名的新音频覆盖"
        )
    }

    /// journal 的 `transactionID` 必须与它所在的事务目录同名。
    ///
    /// 两者都通过格式校验，但描述的不是同一个事务时，恢复会把文件搬进
    /// 另一个目录，让真正的事务目录留在原地。
    func testRecoveryRefusesAJournalThatDoesNotBelongToItsTransactionDirectory() throws {
        let work = makeWork(id: "work_journal_mismatch")
        try CreativeWorkStore(directory: directory).save(work, audioData: Data([3, 3, 3, 3]))

        let deleteInterrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "works.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        XCTAssertThrowsError(
            try CreativeWorkStore(
                directory: directory,
                fileOperations: deleteInterrupting
            ).delete(work)
        )

        let transactions = directory.appendingPathComponent(".transactions", isDirectory: true)
        let transactionDirectory = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil)
                .first
        )
        let realID = transactionDirectory.lastPathComponent
        let swappedID = realID == String(repeating: "a", count: 32)
            ? String(repeating: "b", count: 32)
            : String(repeating: "a", count: 32)
        let journalURL = transactionDirectory.appendingPathComponent("journal.json")
        let journal = try String(contentsOf: journalURL, encoding: .utf8)
        try journal
            .replacingOccurrences(of: realID, with: swappedID)
            .write(to: journalURL, atomically: true, encoding: .utf8)

        let reopened = CreativeWorkStore(directory: directory)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(
                error as? CreativeWorkStoreError,
                .recoveryRequired,
                "journal 不属于它所在的事务目录时必须拒绝恢复，而不是搬错目录"
            )
        }
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

    /// 删除必须按标识符定位到**那一条**，而不是按它在索引里的位置。
    ///
    /// 与改名同一处疏漏，且后果更重：`delete` 找不到时是**静默返回**
    /// （`else { return }`，不是抛错），所以「删错」不会有任何提示——
    /// 用户点的是第二件，消失的是第一件。库里只有一件时，第 0 条永远
    /// 是正确答案，于是既有删除用例全都测不到这一条。
    func testDeletingOneWorkLeavesTheOtherWorksAndTheirAudioIntact() throws {
        let store = CreativeWorkStore(directory: directory)
        let first = makeWork(id: "work_delete_first", script: "第一件文稿")
        let second = makeWork(id: "work_delete_second", script: "第二件文稿")
        let third = makeWork(id: "work_delete_third", script: "第三件文稿")
        try store.save(first, audioData: Data([1, 2, 3, 4]))
        try store.save(second, audioData: Data([5, 6, 7, 8]))
        try store.save(third, audioData: Data([9, 10, 11, 12]))

        // 删中间那一件：按位置取的实现会删掉第一件。
        try store.delete(second)

        let remaining = try store.list()
        XCTAssertEqual(
            remaining.map(\.id),
            [first.id, third.id],
            "只能删掉被点中的那一件"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(second.audioFileName).path
            ),
            "被删作品的音频必须一并消失"
        )
        // 幸存的两件连音频都要在：按位置取的实现会把第一件的音频也移走。
        for survivor in [first, third] {
            XCTAssertNoThrow(
                try store.loadAudio(for: survivor),
                "\(survivor.id) 的音频不得被误删"
            )
        }
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
