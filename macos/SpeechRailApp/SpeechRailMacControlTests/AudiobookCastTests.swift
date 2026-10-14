import Foundation
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
    }
}
