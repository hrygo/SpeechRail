import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookCastTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookCastTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeTwoChapterBook(store: AudiobookProjectStore) async throws -> (
        bookID: UUID,
        chapterA: AudiobookChapter,
        chapterB: AudiobookChapter,
        narrator: AudiobookCharacter,
        hero: AudiobookCharacter,
        unknownAtomInA: AudiobookTextAtom
    ) {
        let text = """
        第一章 迷雾渡口
        夜色深沉。
        “到底是谁在敲门？”
        第二章 晴空万里
        林远走上甲板。
        “今天风平浪静。”林远笑道。
        """
        let url = tempRoot.appendingPathComponent("two_chapters.txt")
        try Data(text.utf8).write(to: url)
        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)

        let chapters = try await store.chapters(for: bookID)
        XCTAssertEqual(chapters.count, 2)
        let chapterA = chapters[0]
        let chapterB = chapters[1]

        var characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: \.isNarrator))
        let hero = AudiobookCharacter(
            bookID: bookID,
            displayName: "林远",
            aliases: ["阿远"],
            isNarrator: false,
            isMajor: true,
            chapterIDs: [chapterA.id, chapterB.id]
        )
        characters.append(hero)
        try await store.saveCharacters(bookID: bookID, characters: characters)

        let atomsA = try await store.atoms(for: bookID, chapterID: chapterA.id)
        let atomsB = try await store.atoms(for: bookID, chapterID: chapterB.id)
        let windowA = UUID()
        let windowB = UUID()

        var anns: [AudiobookAnnotation] = []
        var unknownAtom: AudiobookTextAtom?
        for (idx, atom) in atomsA.enumerated() where atom.kind != .formatting {
            let isUnknown = (idx == atomsA.count - 1)
            if isUnknown { unknownAtom = atom }
            anns.append(
                AudiobookAnnotation(
                    bookID: bookID,
                    chapterID: chapterA.id,
                    windowID: windowA,
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: isUnknown
                        ? .unknown(reason: "未指明说话人", candidateRoleIDs: [hero.id])
                        : .assigned(roleID: narrator.id)
                )
            )
        }
        for (idx, atom) in atomsB.enumerated() where atom.kind != .formatting {
            let roleID = (idx == atomsB.count - 1) ? hero.id : narrator.id
            anns.append(
                AudiobookAnnotation(
                    bookID: bookID,
                    chapterID: chapterB.id,
                    windowID: windowB,
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: .assigned(roleID: roleID)
                )
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)

        return (bookID, chapterA, chapterB, narrator, hero, try XCTUnwrap(unknownAtom))
    }

    func testUnknownBlocksOnlyItsChapterAfterGlobalAnalysis() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        // 全书分析尚未完成时，两章均不可制作
        let initialA = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterA.id)
        let initialB = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterB.id)
        XCTAssertEqual(initialA, .awaitingGlobalAnalysis)
        XCTAssertEqual(initialB, .awaitingGlobalAnalysis)

        // 标记全书窗口已验证，绑定并确认角色与试听
        var book = try await store.book(id: fixture.bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        try await controller.bindVoice(
            bookID: fixture.bookID,
            roleID: fixture.narrator.id,
            binding: AudiobookVoiceBinding(
                roleID: fixture.narrator.id,
                voiceID: "voice-narrator",
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        try await controller.bindVoice(
            bookID: fixture.bookID,
            roleID: fixture.hero.id,
            binding: AudiobookVoiceBinding(
                roleID: fixture.hero.id,
                voiceID: "voice-hero",
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        let castRev = try await controller.currentCastRevisionID(for: fixture.bookID)
        try await controller.confirmCast(bookID: fixture.bookID, revisionID: castRev)
        let voiceDigest = try await controller.currentVoiceSetDigest(for: fixture.bookID)
        try await controller.confirmAudition(bookID: fixture.bookID, voiceSetDigest: voiceDigest)

        // A 章有 unknown 仅阻塞 A 章，B 章可立即进入制作
        let readyA = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterA.id)
        let readyB = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterB.id)
        XCTAssertEqual(readyA, .blockedByUnknownSpeakers)
        XCTAssertEqual(readyB, .readyForProduction)

        // 人工消解 A 章的 unknown 后，A 章也可制作；撤销后恢复阻塞
        try await controller.assignRole(
            bookID: fixture.bookID,
            atomIDs: [fixture.unknownAtomInA.id],
            roleID: fixture.hero.id
        )
        let resolvedA = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterA.id)
        XCTAssertEqual(resolvedA, .readyForProduction)

        try await controller.undoLastAssignment(bookID: fixture.bookID)
        let undoneA = try await controller.chapterReadiness(bookID: fixture.bookID, chapterID: fixture.chapterA.id)
        XCTAssertEqual(undoneA, .blockedByUnknownSpeakers)
    }

    func testDesignedVoiceMustBecomeSynthesisReady() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        let designOnlyBinding = AudiobookVoiceBinding(
            roleID: fixture.hero.id,
            voiceID: "draft-designed-voice",
            voiceRevision: "draft",
            modelRevision: "qwen3-tts-v1",
            isSynthesisReady: false
        )

        do {
            try await controller.bindVoice(
                bookID: fixture.bookID,
                roleID: fixture.hero.id,
                binding: designOnlyBinding
            )
            XCTFail("未保存为可合成状态的音色草稿不应允许绑定到正式制作角色")
        } catch let error as AudiobookCastError {
            XCTAssertEqual(error, .voiceNotSynthesisReady(voiceID: "draft-designed-voice"))
        }
    }

    func testVoiceReturnCannotBindToAnotherBook() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture1 = try await makeTwoChapterBook(store: store)
        let fixture2 = try await makeTwoChapterBook(store: store)

        let returnContext = try await controller.makeVoiceReturnContext(
            bookID: fixture1.bookID,
            roleID: fixture1.hero.id
        )
        let readyBinding = AudiobookVoiceBinding(
            roleID: fixture1.hero.id,
            voiceID: "custom-voice-1",
            voiceRevision: "v1",
            modelRevision: "qwen3-tts-v1",
            isSynthesisReady: true
        )

        // 切换到另一本书时，旧往返上下文必须拒绝篡改当前书
        do {
            try await controller.completeVoiceReturn(
                context: returnContext,
                activeBookID: fixture2.bookID,
                binding: readyBinding
            )
            XCTFail("跨书返回不应绑定到另一本书")
        } catch let error as AudiobookCastError {
            XCTAssertEqual(error, .staleVoiceReturnContext)
        }

        // 在原书但 generation 递增（如角色合并/拆分后）同样拒绝旧上下文自动覆盖
        _ = await controller.bumpGeneration(for: fixture1.bookID)
        do {
            try await controller.completeVoiceReturn(
                context: returnContext,
                activeBookID: fixture1.bookID,
                binding: readyBinding
            )
            XCTFail("过期 generation 返回不应自动改动当前角色")
        } catch let error as AudiobookCastError {
            XCTAssertEqual(error, .staleVoiceReturnContext)
        }
    }

    func testSharedMinorVoiceRequiresVisibleChoice() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        var characters = try await store.characters(for: fixture.bookID)
        let guardRole = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "守卫乙",
            isNarrator: false,
            isMajor: true,
            allowSharedMinorVoice: false,
            chapterIDs: [fixture.chapterA.id]
        )
        characters.append(guardRole)
        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)

        try await controller.bindVoice(
            bookID: fixture.bookID,
            roleID: fixture.hero.id,
            binding: AudiobookVoiceBinding(
                roleID: fixture.hero.id,
                voiceID: "shared-voice",
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
            )
        )

        // 默认不开启共用时，将同一 voiceID 绑给另一角色必须拒绝
        do {
            try await controller.bindVoice(
                bookID: fixture.bookID,
                roleID: guardRole.id,
                binding: AudiobookVoiceBinding(
                    roleID: guardRole.id,
                    voiceID: "shared-voice",
                    voiceRevision: "v1",
                    modelRevision: "qwen3-tts-v1"
                )
            )
            XCTFail("未显式开启次要角色共用声线时，不应静默共用同一音色")
        } catch let error as AudiobookCastError {
            XCTAssertEqual(
                error,
                .duplicateVoiceRequiresSharedMinorConsent(
                    voiceID: "shared-voice",
                    conflictingRoleID: fixture.hero.id
                )
            )
        }

        // 双方均显式允许次要角色共用后，允许绑定同一音色
        try await controller.setAllowSharedMinorVoice(bookID: fixture.bookID, roleID: fixture.hero.id, allowed: true)
        try await controller.setAllowSharedMinorVoice(bookID: fixture.bookID, roleID: guardRole.id, allowed: true)

        try await controller.bindVoice(
            bookID: fixture.bookID,
            roleID: guardRole.id,
            binding: AudiobookVoiceBinding(
                roleID: guardRole.id,
                voiceID: "shared-voice",
                voiceRevision: "v1",
                modelRevision: "qwen3-tts-v1"
            )
        )
        let saved = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(saved[guardRole.id]?.voiceID, "shared-voice")

        // 验证跳转「设计新音色」的返回上下文自动携带角色专属音色描述与试听台词
        let returnCtx = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: fixture.hero.id
        )
        XCTAssertEqual(returnCtx.roleDisplayName, fixture.hero.displayName)
        XCTAssertNotNil(returnCtx.suggestedInstruction)
        XCTAssertTrue(returnCtx.suggestedInstruction?.contains(fixture.hero.displayName) == true)
        XCTAssertNotNil(returnCtx.suggestedReferenceText)
    }

    func testSelectCandidateSummariesStrictlyRespectsPolicyScalarLimitWithManyCharacters() throws {
        let bookID = UUID()
        let chapterID = UUID()
        // 构造 40 个各带详细声线线索与摘录的角色（模拟全书多角色场景，未裁剪时 32 角色 JSON 容易达到 5300+ 字符）
        let range = AudiobookSourceRange(lowerBound: 0, upperBound: 10)
        let characters = (0..<40).map { idx -> AudiobookCharacter in
            AudiobookCharacter(
                id: UUID(),
                bookID: bookID,
                displayName: "角色\(idx)",
                aliases: ["别称\(idx)A", "别名\(idx)B"],
                isNarrator: false,
                isMajor: idx < 5,
                evidences: [
                    AudiobookCharacterEvidence(
                        chapterID: chapterID,
                        sourceRange: range,
                        quoteExcerpt: "这是第\(idx)个角色的详细台词证据摘录，满面风霜，神态凄凉。",
                        voiceTraitSummary: "中年沉稳，略带沙哑与沧桑感"
                    )
                ],
                chapterIDs: [chapterID]
            )
        }

        let policy = AudiobookAnalysisPolicy.standard
        let selected = AudiobookCastRegistry.selectCandidateSummariesForWindow(
            characters: characters,
            chapterID: chapterID,
            windowText: "角色0 说道：天色不早了。角色1 点头称是。",
            policy: policy
        )

        // 验证返回的角色摘要严格不超过策略上限（4,000 字符）
        let serializedCount = AudiobookPromptCharacterSummary.serializedScalarCount(for: selected)
        XCTAssertLessThanOrEqual(
            serializedCount,
            policy.maxCharacterSummaryScalars,
            "筛选出的候选角色摘要序列化长度（\(serializedCount)）不得超出策略上限（\(policy.maxCharacterSummaryScalars)）"
        )
        XCTAssertFalse(selected.isEmpty)
        XCTAssertLessThanOrEqual(selected.count, policy.maxMergeCandidatesPerBatch)

        // 验证高分提及的角色（角色0、角色1）优先包含在内
        XCTAssertTrue(selected.contains { $0.canonicalName == "角色0" })
        XCTAssertTrue(selected.contains { $0.canonicalName == "角色1" })

        // 验证输入这些摘要构建 Annotation 与 Merge prompt 均不会触发 inputBudgetExceeded 异常
        let primaryAtom = AudiobookPromptAtomItem(
            atomID: UUID(),
            kind: .body,
            text: "旧历的年底毕竟最像年底。"
        )
        XCTAssertNoThrow(
            try AudiobookAnalysisPrompts.makeAnnotationPrompt(
                rootWindowID: UUID(),
                primaryAtoms: [primaryAtom],
                candidateCharacters: selected,
                policy: policy
            )
        )

        let mention = AudiobookExtractionResponse.Mention(
            surfaceName: "新人物",
            aliases: ["新别称"],
            evidenceAtomIDs: [primaryAtom.atomID],
            evidenceAtomRefs: ["1"],
            voiceTraitEvidence: "青年清亮",
            evidenceExcerpts: ["新人物快步走来。"]
        )
        XCTAssertNoThrow(
            try AudiobookAnalysisPrompts.makeMergePrompt(
                rootWindowID: UUID(),
                candidates: [mention],
                existingCharacters: selected,
                policy: policy
            )
        )
    }

    func testClampSummariesToBudgetGuaranteesPromptAcceptance() throws {
        let policy = AudiobookAnalysisPolicy.standard
        // 构造明显超标的 35 个候选角色摘要（总长度 > 5000 字符）
        let oversizedSummaries = (0..<35).map { idx in
            AudiobookPromptCharacterSummary(
                roleID: UUID(),
                canonicalName: "登场角色名称\(idx)",
                aliases: ["长别名代称A\(idx)", "长别名代称B\(idx)"],
                evidenceNote: "[中年男子，声音低沉沧桑] 这是很长的一段人物原著台词与神态描写线索摘录\(idx)。",
                roleKey: "R\(idx + 1)"
            )
        }
        let rawCount = AudiobookPromptCharacterSummary.serializedScalarCount(for: oversizedSummaries)
        XCTAssertGreaterThan(
            rawCount,
            policy.maxCharacterSummaryScalars,
            "测试前置条件：原始摘要列表必须超出 4000 标量上限以触发裁剪逻辑"
        )

        let clamped = AudiobookCastRegistry.clampSummariesToBudget(
            oversizedSummaries,
            maxScalars: policy.maxCharacterSummaryScalars,
            maxCandidates: policy.maxMergeCandidatesPerBatch
        )
        let clampedCount = AudiobookPromptCharacterSummary.serializedScalarCount(for: clamped)
        XCTAssertLessThanOrEqual(clampedCount, policy.maxCharacterSummaryScalars)
        XCTAssertFalse(clamped.isEmpty)

        let atom = AudiobookPromptAtomItem(
            atomID: UUID(),
            kind: .body,
            text: "林远举目远望。"
        )
        XCTAssertNoThrow(
            try AudiobookAnalysisPrompts.makeAnnotationPrompt(
                rootWindowID: UUID(),
                primaryAtoms: [atom],
                candidateCharacters: clamped,
                policy: policy
            )
        )
    }

    func testAutoPersonaVoiceDesignInstructionAndAuditionScriptSelector() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        // 构造同书另一位男性角色（老周），测试六维声学画像 + 同性别对比去重 + 原书台词引号提纯与阿拉伯数字转换
        var characters = try await store.characters(for: fixture.bookID)
        let elderRole = AudiobookCharacter(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            bookID: fixture.bookID,
            displayName: "老周",
            aliases: ["周掌柜"],
            evidences: [
                AudiobookCharacterEvidence(
                    chapterID: fixture.chapterA.id,
                    sourceRange: fixture.chapterA.sourceRange,
                    quoteExcerpt: "老周放下烟袋，低声叹道：“这渡口我已经守了30年，今晚风浪急，你们千万别出船！”",
                    voiceTraitSummary: "老年苍老沙哑、胸腔共鸣浑厚"
                )
            ],
            primaryVoiceTraitSummary: "老年苍老沙哑、胸腔共鸣浑厚",
            isNarrator: false,
            isMajor: true,
            chapterIDs: [fixture.chapterA.id]
        )
        characters.append(elderRole)
        characters = AudiobookCastRegistry.enrichCharactersWithVoicePersonas(characters)
        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)

        let ctxHero = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: fixture.hero.id
        )
        let ctxElder = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: elderRole.id
        )

        // 1. 验证六维声学画像编译出的指令包含成年基频守卫、归属语境（低声叹道 -> 舒缓沉着，不受引号内“风浪急”干扰）与同性别对比区分度
        let heroInst = try XCTUnwrap(ctxHero.suggestedInstruction)
        let elderInst = try XCTUnwrap(ctxElder.suggestedInstruction)
        XCTAssertTrue(heroInst.contains("林远"))
        XCTAssertTrue(elderInst.contains("老周"))
        XCTAssertTrue(elderInst.contains("老年男性"))
        XCTAssertTrue(elderInst.contains("老年苍老沙哑"))
        XCTAssertTrue(elderInst.contains("语速舒缓沉着"), "引号外的“低声叹道”应主导语速推断，不受引号内“风浪急”干扰")
        XCTAssertNotEqual(heroInst, elderInst)

        // 2. 验证原书试听台词自动剥离引号外旁白（“老周放下烟袋，低声叹道：”被剥离）、将阿拉伯数字 30 转为中文“三十”，且严格落在 20–240 字门禁区间
        let elderRef = try XCTUnwrap(ctxElder.suggestedReferenceText)
        XCTAssertFalse(elderRef.contains("老周放下烟袋"), "应当剥离引号外的旁白动作描写")
        XCTAssertFalse(elderRef.contains("30"), "阿拉伯数字应转换为汉字以避免转写数字校验误差")
        XCTAssertTrue(elderRef.contains("三十"), "应保留转换后的中文数字“三十”")
        XCTAssertGreaterThanOrEqual(elderRef.count, 20)
        XCTAssertLessThanOrEqual(elderRef.count, 240)

        // 3. 验证返回上下文携带原书多条候选试听台词与专属声学灵感标签
        XCTAssertFalse(ctxElder.suggestedReferenceTextCandidates.isEmpty)
        XCTAssertFalse(ctxElder.suggestedAcousticChips.isEmpty)
        XCTAssertNotNil(ctxElder.bookTitle)

        // 4. 验证年份、小数、百分比与夹叙夹议分裂引语的清洗拼接与标点收束
        let splitQuoteSample = "“从1998年到现在，”苏晴轻声道，“海面风速已经涨了3.5倍，成活率不到50%，咱们必须立刻撤离！”"
        let candidates = AudiobookAuditionScriptSelector.selectCandidates(
            from: [splitQuoteSample],
            roleName: "苏晴",
            isNarrator: false,
            maxCandidates: 2
        )
        let bestQuote = try XCTUnwrap(candidates.first)
        XCTAssertEqual(bestQuote, "从一九九八年到现在，海面风速已经涨了三点五倍，成活率不到百分之五十，咱们必须立刻撤离！")
        XCTAssertFalse(bestQuote.contains("苏晴轻声道"), "同段分裂引语中间的旁白提示应被剥离：\(bestQuote)")
        XCTAssertFalse(bestQuote.contains("，，") || bestQuote.contains("，。"), "拼接与句尾收敛不得产生连续标点伪影：\(bestQuote)")

        // 5. 验证角色改名后动态重算六维声学画像（无陈旧缓存冻结）
        try await controller.renameCharacter(bookID: fixture.bookID, roleID: fixture.hero.id, newName: "林远船长", aliases: ["林船长"])
        let ctxRenamed = try await controller.makeVoiceReturnContext(bookID: fixture.bookID, roleID: fixture.hero.id)
        XCTAssertEqual(ctxRenamed.roleDisplayName, "林远船长")
        XCTAssertTrue(ctxRenamed.suggestedInstruction?.contains("林远船长") == true)
    }

    // MARK: - AC1–AC10: 大规模角色配音与 100+ 音色库分级管理验收测试套件

    private func makeTestSafeVoice(
        id: String,
        name: String,
        mode: String = "system",
        styleTags: [String] = []
    ) -> SafeVoiceEntry {
        let desc = SafeVoiceDescriptor(
            voiceMode: mode,
            locales: ["zh-CN"],
            styleTags: styleTags,
            pitchBand: "unknown",
            timbreFamily: "unknown",
            baselinePace: "unknown",
            sourceType: mode == "system" ? "system_preset" : "custom",
            metadataMethod: "declared_only"
        )
        let model = ConfiguredModelIdentity(
            assurance: .configuredCatalog,
            runtimeRevision: "qwen3-tts-v1",
            catalogRevision: "qwen3-tts-v1"
        )
        return SafeVoiceEntry(
            id: id,
            name: name,
            mode: mode,
            available: true,
            availabilityReason: .available,
            voiceRevision: "v1",
            voiceIdentityAssurance: .contentAddressed,
            model: model,
            descriptors: desc,
            operations: [:],
            productionReady: true
        )
    }

    func testAC1_ParetoAdaptiveRoleStratification() {
        let bookID = UUID()
        let chapterA = UUID()
        let chapterB = UUID()
        let windowID = UUID()

        let narrator = AudiobookCharacter(bookID: bookID, displayName: "旁白", isNarrator: true, isMajor: true, allowSharedMinorVoice: false)
        let leads = (1...3).map { i in
            AudiobookCharacter(bookID: bookID, displayName: "主角_\(i)", isNarrator: false, isMajor: true, allowSharedMinorVoice: false, chapterIDs: [chapterA, chapterB])
        }
        let minors = (1...25).map { i in
            AudiobookCharacter(bookID: bookID, displayName: "路人_\(i)", isNarrator: false, isMajor: true, allowSharedMinorVoice: false, chapterIDs: [chapterA, chapterB])
        }
        let silentRoles = (1...5).map { i in
            AudiobookCharacter(bookID: bookID, displayName: "仅提及人物_\(i)", isNarrator: false, isMajor: true, allowSharedMinorVoice: false, chapterIDs: [chapterA])
        }

        var annotations: [AudiobookAnnotation] = []
        var offset: Int64 = 0
        for lead in leads {
            for _ in 0..<20 {
                annotations.append(
                    AudiobookAnnotation(
                        bookID: bookID,
                        chapterID: chapterA,
                        windowID: windowID,
                        atomID: UUID(),
                        sourceRange: AudiobookSourceRange(lowerBound: offset, upperBound: offset + 10),
                        assignment: .assigned(roleID: lead.id)
                    )
                )
                offset += 10
            }
        }
        for minor in minors {
            for ch in [chapterA, chapterB] {
                annotations.append(
                    AudiobookAnnotation(
                        bookID: bookID,
                        chapterID: ch,
                        windowID: windowID,
                        atomID: UUID(),
                        sourceRange: AudiobookSourceRange(lowerBound: offset, upperBound: offset + 10),
                        assignment: .assigned(roleID: minor.id)
                    )
                )
                offset += 10
            }
        }

        let allChars = [narrator] + leads + minors + silentRoles
        let (updated, statsByID, _) = AudiobookCastRegistry.computeRoleDialogueStats(
            characters: allChars,
            annotations: annotations,
            availableVoiceCount: 6
        )
        let roleByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })

        for lead in leads {
            XCTAssertEqual(statsByID[lead.id]?.tier, .lead)
            XCTAssertEqual(roleByID[lead.id]?.isMajor, true)
            XCTAssertEqual(roleByID[lead.id]?.allowSharedMinorVoice, false)
        }
        for minor in minors {
            XCTAssertEqual(roleByID[minor.id]?.isMajor, false)
            XCTAssertEqual(roleByID[minor.id]?.allowSharedMinorVoice, true, "仅说 2 句话的配角在多角色场景下必须自动开启共享声线")
        }
        for silent in silentRoles {
            XCTAssertEqual(statsByID[silent.id]?.tier, .ensemble)
            XCTAssertEqual(statsByID[silent.id]?.requiresVoiceBinding, false)
            XCTAssertEqual(roleByID[silent.id]?.allowSharedMinorVoice, true)
        }
    }

    func testAC2_50RolesVs5VoicesDualPoolZeroDeadlockAndAC6_SilentRoleExemption() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        var characters = try await store.characters(for: fixture.bookID)
        let leadFemale = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "苏晴",
            isNarrator: false,
            isMajor: true,
            allowSharedMinorVoice: false,
            chapterIDs: [fixture.chapterA.id, fixture.chapterB.id]
        )
        characters.append(leadFemale)

        var minors: [AudiobookCharacter] = []
        for idx in 1...45 {
            let m = AudiobookCharacter(
                bookID: fixture.bookID,
                displayName: idx % 2 == 0 ? "男配_\(idx)" : "女配_\(idx)",
                isNarrator: false,
                isMajor: false,
                allowSharedMinorVoice: true,
                chapterIDs: [fixture.chapterA.id]
            )
            minors.append(m)
            characters.append(m)
        }
        // 新增 2 个 0 台词仅提及人物（测试 AC6）
        let silent1 = AudiobookCharacter(bookID: fixture.bookID, displayName: "传说老祖甲", isNarrator: false, isMajor: false, allowSharedMinorVoice: true)
        let silent2 = AudiobookCharacter(bookID: fixture.bookID, displayName: "传说老祖乙", isNarrator: false, isMajor: false, allowSharedMinorVoice: true)
        characters.append(contentsOf: [silent1, silent2])

        var annotations = try await store.annotations(for: fixture.bookID)
        var offset: Int64 = 10_000
        let winID = UUID()
        for _ in 0..<15 {
            annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterA.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: fixture.hero.id)))
            offset += 10
            annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterA.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: leadFemale.id)))
            offset += 10
        }
        for m in minors {
            annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterA.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: m.id)))
            offset += 10
        }

        let voices: [SafeVoiceEntry] = [
            makeTestSafeVoice(id: "v-narrator", name: "默认沉稳旁白", styleTags: ["旁白"]),
            makeTestSafeVoice(id: "dylan", name: "北京青年男声", styleTags: ["青年", "男声"]),
            makeTestSafeVoice(id: "vivian", name: "明亮青年女声", styleTags: ["青年", "女声"]),
            makeTestSafeVoice(id: "uncle_fu", name: "醇厚中年男声", styleTags: ["中年", "男声"]),
            makeTestSafeVoice(id: "serena", name: "成熟温柔女声", styleTags: ["中年", "女声"])
        ]

        let (stratifiedChars, _, _) = AudiobookCastRegistry.computeRoleDialogueStats(
            characters: characters,
            annotations: annotations,
            availableVoiceCount: voices.count
        )
        try await store.saveCharacters(bookID: fixture.bookID, characters: stratifiedChars)
        try await store.saveAnnotations(bookID: fixture.bookID, annotations: annotations)

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: stratifiedChars,
            availableVoices: voices,
            annotations: annotations,
            bookID: fixture.bookID,
            voiceMetadataByID: [:]
        )

        XCTAssertEqual(recommended.count, stratifiedChars.count, "全部 50 个角色均应生成推荐绑定")

        // 逐个写入绑定（排除 2 个 0 台词人物以同时验证 AC6 门禁豁免）
        for role in stratifiedChars where role.id != silent1.id && role.id != silent2.id {
            let binding = try XCTUnwrap(recommended[role.id])
            try await controller.bindVoice(bookID: fixture.bookID, roleID: role.id, binding: binding)
        }

        let exclusiveVoices: Set<String> = [
            recommended[fixture.narrator.id]!.voiceID,
            recommended[fixture.hero.id]!.voiceID,
            recommended[leadFemale.id]!.voiceID
        ]
        XCTAssertEqual(exclusiveVoices.count, 3, "旁白与 2 名核心主角应各自独占不同音色")
        for m in minors {
            XCTAssertFalse(
                exclusiveVoices.contains(recommended[m.id]!.voiceID),
                "配角共享池绝不可侵占旁白或核心主角的独占音色"
            )
        }

        // AC6：即使 silent1 与 silent2 未绑定音色，confirmCast 仍应顺利通过
        var book = try await store.book(id: fixture.bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        let castRev = try await controller.currentCastRevisionID(for: fixture.bookID)
        try await controller.confirmCast(bookID: fixture.bookID, revisionID: castRev)
    }

    func testAC3_ScenePartnerGraphColoringAndAC4_MicroProsodyAndAC5_BatchArchetypeBinding() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = AudiobookCastController(store: store)
        let fixture = try await makeTwoChapterBook(store: store)

        let partnerA = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "张掌柜",
            isNarrator: false,
            isMajor: false,
            allowSharedMinorVoice: true,
            chapterIDs: [fixture.chapterA.id]
        )
        let partnerB = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "李掌柜",
            isNarrator: false,
            isMajor: false,
            allowSharedMinorVoice: true,
            chapterIDs: [fixture.chapterA.id]
        )
        let partnerC = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "王老汉",
            isNarrator: false,
            isMajor: false,
            allowSharedMinorVoice: true,
            chapterIDs: [fixture.chapterB.id]
        )

        var characters = try await store.characters(for: fixture.bookID)
        characters.append(contentsOf: [partnerA, partnerB, partnerC])

        var annotations = try await store.annotations(for: fixture.bookID)
        let winID = UUID()
        var offset: Int64 = 20_000
        for _ in 0..<12 {
            annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterA.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: fixture.hero.id)))
            offset += 10
        }
        // 张掌柜与李掌柜在同一场戏紧邻交替对话 4 轮
        for i in 0..<4 {
            let speakerID = (i % 2 == 0) ? partnerA.id : partnerB.id
            annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterA.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: speakerID)))
            offset += 10
        }
        annotations.append(.init(bookID: fixture.bookID, chapterID: fixture.chapterB.id, windowID: winID, atomID: UUID(), sourceRange: .init(lowerBound: offset, upperBound: offset + 10), assignment: .assigned(roleID: partnerC.id)))

        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)
        try await store.saveAnnotations(bookID: fixture.bookID, annotations: annotations)

        let voices: [SafeVoiceEntry] = [
            makeTestSafeVoice(id: "v-narrator", name: "旁白", styleTags: ["旁白"]),
            makeTestSafeVoice(id: "dylan", name: "青年男声", styleTags: ["青年", "男声"]),
            makeTestSafeVoice(id: "uncle_fu", name: "醇厚中年男声一号", styleTags: ["中年", "男声"]),
            makeTestSafeVoice(id: "uncle_chen", name: "沧桑中年男声二号", styleTags: ["中年", "男声"])
        ]

        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: characters,
            availableVoices: voices,
            annotations: annotations,
            bookID: fixture.bookID,
            voiceMetadataByID: [:]
        )

        // AC3：同场紧邻交替对话的张掌柜与李掌柜绝不分配同一音色
        XCTAssertNotEqual(
            recommended[partnerA.id]?.voiceID,
            recommended[partnerB.id]?.voiceID,
            "同场紧邻对手戏的两个同声部配角必须分配不同音色"
        )

        // AC4：验证 system 音色微语速错位与 clone 音色确定性种子错位
        let (sysSpeed0, sysSeed0) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerA, archetype: .matureMale, voiceMode: "system", slotIndex: 0
        )
        let (sysSpeed1, sysSeed1) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerB, archetype: .matureMale, voiceMode: "system", slotIndex: 1
        )
        XCTAssertNil(sysSeed0)
        XCTAssertNil(sysSeed1)
        XCTAssertNotEqual(sysSpeed0, sysSpeed1, "共用 system 音色的不同槽位配角应获得差异化微语速")

        let (cloneSpeed0, cloneSeed0) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerA, archetype: .matureMale, voiceMode: "clone", slotIndex: 0
        )
        let (cloneSpeed1, cloneSeed1) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerB, archetype: .matureMale, voiceMode: "clone", slotIndex: 1
        )
        XCTAssertEqual(cloneSpeed0, 1.0)
        XCTAssertEqual(cloneSpeed1, 1.0)
        XCTAssertNotEqual(cloneSeed0, cloneSeed1, "共用 clone 音色的配角应获得不同确定性 callerSeed")

        // AC5：按声部行当批量换绑，更新所有中老年男配角但绝不覆盖主角
        for role in characters {
            if let b = recommended[role.id] {
                try await controller.bindVoice(bookID: fixture.bookID, roleID: role.id, binding: b)
            }
        }
        let heroOriginalVoice = try await store.voiceBindings(for: fixture.bookID)[fixture.hero.id]?.voiceID
        let newMatureVoice = makeTestSafeVoice(id: "master_zhao", name: "新中老年男配声线", styleTags: ["中年", "男声"])
        let updatedCount = try await controller.batchBindArchetypeVoice(
            bookID: fixture.bookID,
            archetype: .matureMale,
            voice: newMatureVoice
        )
        XCTAssertEqual(updatedCount, 3)
        let updatedBindings = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(updatedBindings[partnerA.id]?.voiceID, "master_zhao")
        XCTAssertEqual(updatedBindings[partnerB.id]?.voiceID, "master_zhao")
        XCTAssertEqual(updatedBindings[partnerC.id]?.voiceID, "master_zhao")
        XCTAssertEqual(updatedBindings[fixture.hero.id]?.voiceID, heroOriginalVoice, "核心主角音色绝不可被声部批量换绑覆盖")
    }

    func testAC7_AC8_AC9_AC10_100PlusVoiceScopeIsolationPromotionTaxonomyAndCollections() throws {
        let catalogURL = tempRoot.appendingPathComponent("test_voice_catalog.json")
        let catalogStore = VoiceCatalogStore(storageURL: catalogURL)

        let bookA = UUID()
        let bookB = UUID()
        let roleHeroA = AudiobookCharacter(
            bookID: bookA,
            displayName: "林动",
            isNarrator: false,
            isMajor: true,
            allowSharedMinorVoice: false
        )

        // AC7：注册《书籍 A》角色专用音色与《书籍 B》30 个角色专用音色
        catalogStore.registerBookExclusiveVoice(
            voiceID: "v_bookA_lindong",
            bookID: bookA,
            bookTitle: "武动乾坤",
            roleID: roleHeroA.id,
            roleName: "林动",
            archetype: .youngMale
        )

        var voices: [SafeVoiceEntry] = [
            makeTestSafeVoice(id: "v_bookA_lindong", name: "林动专属定制音色", mode: "clone", styleTags: ["青年", "男声"])
        ]

        for i in 1...30 {
            let vid = "v_bookB_role_\(i)"
            catalogStore.registerBookExclusiveVoice(
                voiceID: vid,
                bookID: bookB,
                bookTitle: "他书B",
                roleID: UUID(),
                roleName: "他书角色_\(i)",
                archetype: .youngMale
            )
            voices.append(makeTestSafeVoice(id: vid, name: "他书男主音色_\(i)", mode: "clone", styleTags: ["青年", "男声"]))
        }

        // AC9：构造 90 个通用音色（总计 121 个音色），验证 100% 确定性归入六大声部行当
        let archetypeSamples: [(String, [String], AudiobookVoiceArchetype)] = [
            ("旁白叙事者", ["旁白", "叙事"], .narrator),
            ("阳光青年男声", ["青年", "男声"], .youngMale),
            ("沧桑大叔男声", ["中年", "男声", "醇厚"], .matureMale),
            ("清脆少女声线", ["青年", "女声", "少女"], .youngFemale),
            ("成熟温婉女声", ["中年", "女声", "成熟"], .matureFemale),
            ("活泼孩童群像", ["孩童", "中性"], .neutralEnsemble)
        ]
        for i in 0..<90 {
            let sample = archetypeSamples[i % archetypeSamples.count]
            let vid = "v_global_\(i)"
            let v = makeTestSafeVoice(id: vid, name: "\(sample.0)_\(i)", mode: "system", styleTags: sample.1)
            voices.append(v)
            let resolved = AudiobookCastRegistry.resolveVoiceArchetype(
                for: v,
                metadata: catalogStore.metadata(for: vid)
            )
            XCTAssertEqual(resolved, sample.2, "100+ 音色必须准确自动归入六大声部行当")
        }

        // 验证《书籍 A》选角时：100% 隔离《书籍 B》的 30 个专用音色，且「林动」精准匹配其专属音色
        for i in 1...30 {
            XCTAssertFalse(
                catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_\(i)", currentBookID: bookA),
                "其他书籍的专用音色不得出现在当前书活跃池中"
            )
        }
        let bindingsA = AudiobookCastRegistry.recommendVoiceBindings(
            characters: [roleHeroA],
            availableVoices: voices,
            bookID: bookA,
            voiceMetadataByID: catalogStore.metadataByVoiceID
        )
        XCTAssertEqual(bindingsA[roleHeroA.id]?.voiceID, "v_bookA_lindong")

        // AC8：将《书籍 B》专用音色一键晋升为全局通用音色后，对《书籍 A》与演播台立即可见
        catalogStore.promoteToGlobalReusable(voiceID: "v_bookB_role_1")
        XCTAssertTrue(catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_1", currentBookID: bookA))
        XCTAssertTrue(catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_1", currentBookID: nil))
        XCTAssertEqual(catalogStore.metadata(for: "v_bookB_role_1")?.originBookTitle, "他书B")

        // AC10：创建剧团音色包并验证优先选角与归档隔离
        let collection = catalogStore.createCollection(name: "古风仙侠剧团包", voiceIDs: ["v_global_1"])
        catalogStore.archiveVoices(voiceIDs: ["v_global_7"])
        XCTAssertFalse(catalogStore.isVoiceActiveForBook(voiceID: "v_global_7", currentBookID: bookA))

        let newLead = AudiobookCharacter(bookID: bookB, displayName: "新书少年男主", isNarrator: false, isMajor: true, allowSharedMinorVoice: false)
        let bindingsWithCollection = AudiobookCastRegistry.recommendVoiceBindings(
            characters: [newLead],
            availableVoices: voices.filter { !$0.id.hasPrefix("v_bookB_") },
            bookID: bookB,
            preferredCollectionID: collection.id,
            voiceMetadataByID: catalogStore.metadataByVoiceID
        )
        XCTAssertEqual(bindingsWithCollection[newLead.id]?.voiceID, "v_global_1", "绑定剧团音色包后应优先从该合集中选角")
    }

    func testPostAnalysisHighVolumeOperationsRemainSubSecondWithoutUIFreeze() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = AudiobookCastController(store: store)
        let revisionController = AudiobookRevisionController(store: store)

        // 构造 15 章、每章 60 段的正文（共 900 段原文与 80 名出场角色），模拟长篇小说全书 LLM 分析完成后的高负载状态
        var chapterLines: [String] = []
        for chIdx in 1...15 {
            chapterLines.append("第\(chIdx)章 烽火渡口")
            for pIdx in 1...60 {
                chapterLines.append("第\(chIdx)章第\(pIdx)段，“此地不宜久留，速速启程！”角色_\((chIdx + pIdx) % 80)低声喝道。")
            }
        }
        let fullText = chapterLines.joined(separator: "\n")
        let url = tempRoot.appendingPathComponent("large_novel.txt")
        try Data(fullText.utf8).write(to: url)

        let preview = try await AudiobookTXTImporter.prepare(fileURL: url, encoding: .utf8)
        let bookID = try await store.importBook(preview)
        let chapters = try await store.chapters(for: bookID).sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(chapters.count, 15)

        var characters = try await store.characters(for: bookID)
        let narrator = try XCTUnwrap(characters.first(where: \.isNarrator))
        for rIdx in 0..<80 {
            let role = AudiobookCharacter(
                bookID: bookID,
                displayName: "角色_\(rIdx)",
                aliases: ["别称_\(rIdx)"],
                isNarrator: false,
                isMajor: rIdx < 4,
                allowSharedMinorVoice: rIdx >= 4,
                evidences: [
                    AudiobookCharacterEvidence(
                        chapterID: chapters[rIdx % chapters.count].id,
                        sourceRange: chapters[rIdx % chapters.count].sourceRange,
                        quoteExcerpt: "“此地不宜久留！”角色_\(rIdx)沉声道。",
                        voiceTraitSummary: rIdx % 2 == 0 ? "中年男性沉稳浑厚" : "青年女性清亮明快"
                    )
                ],
                chapterIDs: [chapters[rIdx % chapters.count].id]
            )
            characters.append(role)
        }
        characters = AudiobookCastRegistry.enrichCharactersWithVoicePersonas(characters)
        try await store.saveCharacters(bookID: bookID, characters: characters)

        let allAtoms = try await store.atoms(for: bookID).filter { $0.kind != .formatting }
        let nonNarrators = characters.filter { !$0.isNarrator }
        let windowID = UUID()
        let anns: [AudiobookAnnotation] = allAtoms.enumerated().map { idx, atom in
            let roleID = (idx % 3 == 0) ? narrator.id : nonNarrators[idx % nonNarrators.count].id
            return AudiobookAnnotation(
                bookID: bookID,
                chapterID: atom.chapterID,
                windowID: windowID,
                atomID: atom.id,
                sourceRange: atom.sourceRange,
                assignment: .assigned(roleID: roleID)
            )
        }
        try await store.saveAnnotations(bookID: bookID, annotations: anns)

        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let voices: [SafeVoiceEntry] = [
            makeTestSafeVoice(id: "v-narrator", name: "沉稳旁白"),
            makeTestSafeVoice(id: "dylan", name: "北京青年男声"),
            makeTestSafeVoice(id: "vivian", name: "明亮青年女声"),
            makeTestSafeVoice(id: "uncle_fu", name: "醇厚中年男声"),
            makeTestSafeVoice(id: "serena", name: "温柔成熟女声")
        ]

        let t0 = ContinuousClock.now
        let recommended = AudiobookCastRegistry.recommendVoiceBindings(
            characters: characters,
            availableVoices: voices,
            annotations: anns,
            bookID: bookID,
            voiceMetadataByID: [:]
        )
        let boundCount = try await castController.bindVoicesBatch(
            bookID: bookID,
            bindings: Array(recommended.values)
        )
        XCTAssertEqual(boundCount, characters.count)

        // 验证全书章节就绪度批量计算、单段改派、书架摘要与恢复计划均在亚秒级完成，绝不阻塞主线程或 Actor
        let readinessMap = try await castController.chapterReadinessMap(for: bookID)
        XCTAssertEqual(readinessMap.count, 15)

        try await castController.assignRole(
            bookID: bookID,
            atomIDs: [allAtoms[0].id],
            roleID: nonNarrators[0].id
        )
        let summaries = try await store.listBooks()
        XCTAssertEqual(summaries.first?.totalChapterCount, 15)

        let plan = try await revisionController.resumePlan(bookID: bookID)
        XCTAssertFalse(plan.redoFragmentIDs.isEmpty)

        let elapsed = ContinuousClock.now - t0
        XCTAssertLessThan(elapsed, .seconds(2), "LLM 分析完成后的高频交互全链路耗时（\(elapsed)）必须保持亚秒级响应，严禁引发 UI 卡死")
    }

    @MainActor
    func testSecondaryUnknownResolutionAndLeadExclusiveVoiceSynthesisAndFastManualConfirmation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await makeTwoChapterBook(store: store)
        var book = try await store.book(id: fixture.bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)

        let chapters = try await store.chapters(for: fixture.bookID).sorted { $0.ordinal < $1.ordinal }
        let chapterAAtoms = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterA.id)
            .filter { $0.kind != .formatting }
            .sorted { $0.ordinal < $1.ordinal }

        // 在第一章再增加一处 unknown 对白（共 2 处 unknown）
        var currentAnns = try await store.annotations(for: fixture.bookID)
        if let firstBodyAtom = chapterAAtoms.first(where: { $0.id != fixture.unknownAtomInA.id }) {
            if let idx = currentAnns.firstIndex(where: { $0.atomID == firstBodyAtom.id }) {
                currentAnns[idx].assignment = .unknown(reason: "跨窗省略主语", candidateRoleIDs: [])
                try await store.saveAnnotations(bookID: fixture.bookID, annotations: [currentAnns[idx]])
            }
        }

        final class SecondaryPassFakeClient: AudiobookAnalysisClient, @unchecked Sendable {
            let configurationDigest: String
            let heroID: UUID
            let targetUnknownAtomID: UUID

            init(configurationDigest: String, heroID: UUID, targetUnknownAtomID: UUID) {
                self.configurationDigest = configurationDigest
                self.heroID = heroID
                self.targetUnknownAtomID = targetUnknownAtomID
            }

            func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String {
                // 将第 1 处 unknown 消解给主角林远，将第 2 处保留 unknown 但补充林远为候选角色
                let response = AudiobookAnnotationResponse(
                    items: [
                        .init(
                            atomID: UUID(),
                            atomRef: "1",
                            speakerKind: .character,
                            roleID: heroID,
                            confidence: 0.92,
                            evidence: "后文紧邻林远动作描写"
                        ),
                        .init(
                            atomID: targetUnknownAtomID,
                            atomRef: targetUnknownAtomID.uuidString,
                            speakerKind: .unknown,
                            roleID: nil,
                            candidateRoleIDs: [heroID],
                            confidence: 0.45,
                            evidence: "双人对话轮次需人工确认"
                        )
                    ]
                )
                let data = try JSONEncoder().encode(response)
                return String(decoding: data, as: UTF8.self)
            }
        }

        final class LeadVoiceAndRenderFakeRenderer: AudiobookSpeechRenderer, @unchecked Sendable {
            private let lock = NSLock()
            var createdLeadRequests: [AudiobookLeadVoiceCreationRequest] = []
            var publishedVoices: [SafeVoiceEntry]
            var shouldFailRender: Bool = false

            init(initialVoices: [SafeVoiceEntry]) {
                self.publishedVoices = initialVoices
            }

            func fetchEffectiveCapabilities() async throws -> EffectiveCapabilitySnapshot {
                let voices = lock.withLock { publishedVoices }
                let model = ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    runtimeRevision: "qwen3-tts-v1",
                    catalogRevision: "0123456789abcdef0123456789abcdef01234567"
                )
                return EffectiveCapabilitySnapshot(
                    serviceInstanceEpoch: "epoch-lead",
                    catalogRevision: "cat-lead",
                    snapshotID: "snap-lead",
                    profile: "quality",
                    models: ["tts": model, "tts_clone": model],
                    voices: voices,
                    operations: [:],
                    guarantees: [:]
                )
            }

            func createAndPublishLeadVoice(
                _ request: AudiobookLeadVoiceCreationRequest
            ) async throws -> AudiobookLeadVoiceCreationOutput {
                let model = ConfiguredModelIdentity(
                    assurance: .configuredCatalog,
                    runtimeRevision: "qwen3-tts-v1",
                    catalogRevision: "0123456789abcdef0123456789abcdef01234567"
                )
                let desc = SafeVoiceDescriptor(
                    voiceMode: "clone",
                    locales: ["zh-CN"],
                    styleTags: [],
                    pitchBand: "medium",
                    timbreFamily: "warm",
                    baselinePace: "moderate",
                    sourceType: "designed_clone",
                    metadataMethod: "declared_only"
                )
                let newEntry = SafeVoiceEntry(
                    id: request.targetVoiceID,
                    name: request.voiceName,
                    mode: "clone",
                    available: true,
                    availabilityReason: .available,
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                    voiceIdentityAssurance: .contentAddressed,
                    model: model,
                    descriptors: desc,
                    operations: [:],
                    productionReady: true
                )
                lock.withLock {
                    createdLeadRequests.append(request)
                    publishedVoices.removeAll { $0.id == newEntry.id }
                    publishedVoices.append(newEntry)
                }
                return AudiobookLeadVoiceCreationOutput(
                    voiceID: newEntry.id,
                    voiceName: newEntry.name,
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                    modelRevision: "0123456789abcdef0123456789abcdef01234567"
                )
            }

            func renderFragment(_ request: AudiobookRenderCallRequest) async throws -> AudiobookRenderCallOutput {
                let fail = lock.withLock { shouldFailRender }
                if fail {
                    throw ServiceAPIClientError.requestFailed
                }
                let pcmBytes = 4_800 * 2
                var data = Data(capacity: 44 + pcmBytes)
                data.append(contentsOf: "RIFF".utf8)
                var riffSize = UInt32(36 + pcmBytes).littleEndian
                data.append(Data(bytes: &riffSize, count: 4))
                data.append(contentsOf: "WAVEfmt ".utf8)
                var fmtChunkSize = UInt32(16).littleEndian
                var audioFormat = UInt16(1).littleEndian
                var numChannels = UInt16(1).littleEndian
                var sampleRate = UInt32(48_000).littleEndian
                var byteRate = UInt32(48_000 * 2).littleEndian
                var blockAlign = UInt16(2).littleEndian
                var bitsPerSample = UInt16(16).littleEndian
                data.append(Data(bytes: &fmtChunkSize, count: 4))
                data.append(Data(bytes: &audioFormat, count: 2))
                data.append(Data(bytes: &numChannels, count: 2))
                data.append(Data(bytes: &sampleRate, count: 4))
                data.append(Data(bytes: &byteRate, count: 4))
                data.append(Data(bytes: &blockAlign, count: 2))
                data.append(Data(bytes: &bitsPerSample, count: 2))
                data.append(contentsOf: "data".utf8)
                var dataChunkSize = UInt32(pcmBytes).littleEndian
                data.append(Data(bytes: &dataChunkSize, count: 4))
                data.append(Data(repeating: 0, count: pcmBytes))
                let pcmSHA = try AudioDigest.sha256HexOfPCM(in: data)
                return AudiobookRenderCallOutput(
                    wavData: data,
                    voiceRevision: nil,
                    modelRevision: request.expectedModelRevision,
                    pcmSHA256: pcmSHA,
                    requestID: "req-1",
                    receiptID: nil,
                    recipeSummary: "partial",
                    isProvenanceVerified: true
                )
            }
        }

        let llmConfig = LLMConfiguration(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3")
        let snapshot = AudiobookAnalysisConfigSnapshot(configuration: llmConfig, generation: 1)
        let fakeRenderer = LeadVoiceAndRenderFakeRenderer(
            initialVoices: [
                makeTestSafeVoice(id: "uncle_fu", name: "醇厚男声"),
                makeTestSafeVoice(id: "vivian", name: "明亮女声")
            ]
        )

        let deps = AudiobookDependencies(
            makeStore: { store },
            makeAnalysisClient: { snap in
                SecondaryPassFakeClient(
                    configurationDigest: snap.configurationDigest,
                    heroID: fixture.hero.id,
                    targetUnknownAtomID: fixture.unknownAtomInA.id
                )
            },
            resolveAnalysisSnapshot: { _ in snapshot },
            speechRenderer: fakeRenderer
        )

        let workflow = AudiobookWorkflowModel(dependencies: deps)
        await workflow.openBook(fixture.bookID)
        XCTAssertEqual(workflow.totalUnknownSpeakerCount, 2)
        XCTAssertEqual(workflow.unknownCountByChapterID[fixture.chapterA.id], 2)

        // 1. 执行 AI 二次复核未确认说话人：消解 1 处，剩余 1 处待人工确认并自动聚焦
        await workflow.resolveUnknownSpeakersWithLLM(for: fixture.bookID)
        XCTAssertEqual(workflow.totalUnknownSpeakerCount, 1)
        XCTAssertEqual(workflow.focusedUnknownAtomID, fixture.unknownAtomInA.id)

        // 2. 开启「仅看待确认对白」过滤并验证快捷候选角色与一键确认跳转
        workflow.showOnlyUnknownAtomsInChapter = true
        XCTAssertFalse(workflow.displayedChapterAtoms.isEmpty)
        let remainingUnknown = try XCTUnwrap(workflow.unknownAnnotationsInSelectedChapter.first)
        let quickCands = workflow.quickCandidateRoles(for: remainingUnknown)
        XCTAssertTrue(quickCands.contains(where: { $0.id == fixture.hero.id }))

        await workflow.assignSpeakerAndAdvanceToNextUnknown(
            atomID: remainingUnknown.atomID,
            roleID: fixture.hero.id
        )
        XCTAssertEqual(workflow.totalUnknownSpeakerCount, 0)
        XCTAssertFalse(workflow.showOnlyUnknownAtomsInChapter, "全部确认完毕后应自动关闭仅看待确认过滤")

        // 3. 为主要角色生成本书专属定制音色（不再只使用默认系统音色）
        let createdLeadCount = await workflow.createExclusiveVoicesForLeadCharacters(for: fixture.bookID)
        XCTAssertEqual(createdLeadCount, 2, "旁白与主角林远均应生成专属定制音色")
        XCTAssertEqual(fakeRenderer.createdLeadRequests.count, 2)
        let heroBinding = try XCTUnwrap(workflow.voiceBindings[fixture.hero.id])
        XCTAssertTrue(heroBinding.voiceID.hasPrefix("ab_"), "主角应绑定新生成的本书专属音色 ID：\(heroBinding.voiceID)")
        XCTAssertEqual(VoiceCatalogStore.shared.metadata(for: heroBinding.voiceID)?.scope, .bookExclusive)

        // 4. 确认角色与试听后进入制作：验证制作失败时 errorMessage 不会被 openBook 清空，成功时正常产出章节版本
        await workflow.confirmCastAndAudition()
        XCTAssertEqual(workflow.workbenchTab, .production)

        fakeRenderer.shouldFailRender = true
        workflow.makeConfirmedChapters(chapterIDs: [chapters[0].id])
        while workflow.isProducing {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(workflow.errorMessage, "制作失败时必须保留错误提示，不能被 openBook 清空为 nil")

        fakeRenderer.shouldFailRender = false
        workflow.makeConfirmedChapters(chapterIDs: [chapters[0].id])
        while workflow.isProducing {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(workflow.errorMessage)
        let updatedCh0 = try await store.chapters(for: fixture.bookID).first(where: { $0.id == chapters[0].id })
        XCTAssertNotNil(updatedCh0?.currentChapterRevisionID, "制作完成后应自动发布初始章节版本")
    }
}
