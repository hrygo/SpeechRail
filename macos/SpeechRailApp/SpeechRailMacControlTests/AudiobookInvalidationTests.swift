import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookInvalidationTests: XCTestCase {
    func testRechunkingKeepsEffectiveFragmentDependency() throws {
        let source = try AudiobookSourceIndex(utf8: Data("abcdefgh".utf8))
        let book = UUID(), role = UUID()
        let chapter = AudiobookChapter(bookID: book, sourceID: UUID(), ordinal: 0, title: "夹具", sourceRange: .init(lowerBound: 0, upperBound: 8))
        func annotation(_ lower: Int64, _ upper: Int64) -> AudiobookAnnotation {
            .init(bookID: book, chapterID: chapter.id, windowID: UUID(), atomID: UUID(), sourceRange: .init(lowerBound: lower, upperBound: upper), assignment: .assigned(roleID: role))
        }
        let binding = AudiobookVoiceBinding(roleID: role, voiceID: "voice", voiceRevision: nil, modelRevision: "model")
        let whole = try AudiobookFragmentPlanner.plan(chapter: chapter, annotations: [annotation(0, 8)], bindings: [role: binding], source: source)
        let split = try AudiobookFragmentPlanner.plan(chapter: chapter, annotations: [annotation(0, 4), annotation(4, 8)], bindings: [role: binding], source: source)
        XCTAssertEqual(whole.first?.dependencyDigest, split.first?.dependencyDigest)
        XCTAssertEqual(whole.first?.id, split.first?.id)
    }

    func testCoalescingNeverCrossesSpeakerBoundary() throws {
        let text = "夜风吹过长街。林远停下脚步。“有人跟在后面。”“别回头，继续走。”老周低声答道。"
        let utf8 = Data(text.utf8)
        let source = try AudiobookSourceIndex(utf8: utf8)
        let bookID = UUID()
        let sourceID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: sourceID,
            ordinal: 0,
            title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))
        )
        let atoms = try source.buildAtoms(for: chapter)
        let readableAtoms = atoms.filter { $0.kind != .formatting }
        XCTAssertGreaterThanOrEqual(readableAtoms.count, 4)

        let narratorID = UUID()
        let heroID = UUID()
        let elderID = UUID()

        let bindings: [UUID: AudiobookVoiceBinding] = [
            narratorID: AudiobookVoiceBinding(
                roleID: narratorID,
                voiceID: "v-narrator",
                voiceRevision: "r1",
                modelRevision: "m1"
            ),
            heroID: AudiobookVoiceBinding(
                roleID: heroID,
                voiceID: "v-hero",
                voiceRevision: "r1",
                modelRevision: "m1"
            ),
            elderID: AudiobookVoiceBinding(
                roleID: elderID,
                voiceID: "v-elder",
                voiceRevision: "r1",
                modelRevision: "m1"
            )
        ]

        // 前两个 atom 同属旁白，第 3 个属林远，第 4 个以后属老周
        let windowID = UUID()
        var annotations: [AudiobookAnnotation] = []
        for (idx, atom) in readableAtoms.enumerated() {
            let roleID: UUID
            if idx <= 1 {
                roleID = narratorID
            } else if idx == 2 {
                roleID = heroID
            } else {
                roleID = elderID
            }
            annotations.append(
                AudiobookAnnotation(
                    bookID: bookID,
                    chapterID: chapter.id,
                    windowID: windowID,
                    atomID: atom.id,
                    sourceRange: atom.sourceRange,
                    assignment: .assigned(roleID: roleID)
                )
            )
        }

        let fragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: annotations,
            bindings: bindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )

        // 前两个旁白 atom 合并为 1 个片段，林远对白独立为 1 个片段，老周连续 atom 合并为 1 个片段
        XCTAssertEqual(fragments.count, 3)
        XCTAssertEqual(fragments[0].roleID, narratorID)
        XCTAssertEqual(fragments[0].atomIDs.count, 2)
        XCTAssertEqual(fragments[1].roleID, heroID)
        XCTAssertEqual(fragments[1].atomIDs.count, 1)
        XCTAssertEqual(fragments[2].roleID, elderID)

        for fragment in fragments {
            let fragmentText = try source.text(in: fragment.sourceRange)
            XCTAssertLessThanOrEqual(
                fragmentText.unicodeScalars.count,
                AudiobookLimits.maxFragmentScalars
            )
        }
    }

    func testRenameKeepsAudioButRoleVoiceAndModelChangesInvalidatePrecisely() throws {
        let text = "旁白第一句。\n“主角第一句对白。”\n“配角第二句对白。”\n旁白收尾句。"
        let utf8 = Data(text.utf8)
        let source = try AudiobookSourceIndex(utf8: utf8)
        let bookID = UUID()
        let sourceID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID,
            sourceID: sourceID,
            ordinal: 0,
            title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))
        )
        let atoms = try source.buildAtoms(for: chapter)
        let readableAtoms = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(readableAtoms.count, 4)

        let narratorID = UUID()
        let heroID = UUID()
        let sidekickID = UUID()

        let baseBindings: [UUID: AudiobookVoiceBinding] = [
            narratorID: AudiobookVoiceBinding(roleID: narratorID, voiceID: "v-narr", voiceRevision: "1", modelRevision: "m1"),
            heroID: AudiobookVoiceBinding(roleID: heroID, voiceID: "v-hero", voiceRevision: "1", modelRevision: "m1"),
            sidekickID: AudiobookVoiceBinding(roleID: sidekickID, voiceID: "v-side", voiceRevision: "1", modelRevision: "m1")
        ]

        let windowID = UUID()
        let baseAnnotations: [AudiobookAnnotation] = [
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: windowID, atomID: readableAtoms[0].id, sourceRange: readableAtoms[0].sourceRange, assignment: .assigned(roleID: narratorID)),
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: windowID, atomID: readableAtoms[1].id, sourceRange: readableAtoms[1].sourceRange, assignment: .assigned(roleID: heroID)),
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: windowID, atomID: readableAtoms[2].id, sourceRange: readableAtoms[2].sourceRange, assignment: .assigned(roleID: sidekickID)),
            AudiobookAnnotation(bookID: bookID, chapterID: chapter.id, windowID: windowID, atomID: readableAtoms[3].id, sourceRange: readableAtoms[3].sourceRange, assignment: .assigned(roleID: narratorID))
        ]

        let baseFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: baseAnnotations,
            bindings: baseBindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )
        XCTAssertEqual(baseFragments.count, 4)

        let baseSnapshot = AudiobookDependencySnapshot(
            sourceSHA256: source.sourceSHA256,
            fragments: baseFragments,
            characterNamesByRoleID: [heroID: "林远"],
            characterAliasesByRoleID: [heroID: ["阿远"]]
        )

        // 1. 仅修改角色显示名与别称，或者生成新的全局 annotationRevision，不改变任何音频依赖
        let renamedAnnotations = baseAnnotations.map { ann -> AudiobookAnnotation in
            AudiobookAnnotation(
                id: UUID(),
                bookID: ann.bookID,
                chapterID: ann.chapterID,
                windowID: ann.windowID,
                atomID: ann.atomID,
                sourceRange: ann.sourceRange,
                assignment: ann.assignment,
                evidence: ann.evidence,
                annotationRevision: ann.annotationRevision + 1
            )
        }
        let renamedFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: renamedAnnotations,
            bindings: baseBindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )
        let renamedSnapshot = AudiobookDependencySnapshot(
            sourceSHA256: source.sourceSHA256,
            fragments: renamedFragments,
            characterNamesByRoleID: [heroID: "林大船长"],
            characterAliasesByRoleID: [heroID: ["阿远", "林兄"]]
        )
        XCTAssertTrue(
            AudiobookInvalidation.affectedFragments(before: baseSnapshot, after: renamedSnapshot).isEmpty,
            "修改角色名称、别称或递增全局标注版本号绝不能使已有片段失效"
        )

        // 2. 将第 3 句（配角）改归属给主角（使得第 2、3 句合并为一个主角片段）：仅第 2、3 句相关片段失效，首尾旁白片段保持有效
        var reassignedAnnotations = baseAnnotations
        reassignedAnnotations[2].assignment = .assigned(roleID: heroID)
        let reassignedFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: reassignedAnnotations,
            bindings: baseBindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )
        let reassignedSnapshot = AudiobookDependencySnapshot(
            sourceSHA256: source.sourceSHA256,
            fragments: reassignedFragments
        )
        let affectedByReassign = AudiobookInvalidation.affectedFragments(
            before: baseSnapshot,
            after: reassignedSnapshot
        )
        XCTAssertFalse(affectedByReassign.contains(baseFragments[0].id))
        XCTAssertFalse(affectedByReassign.contains(baseFragments[3].id))
        XCTAssertTrue(affectedByReassign.contains(baseFragments[1].id))
        XCTAssertTrue(affectedByReassign.contains(baseFragments[2].id))

        // 3. 更换主角音色：仅主角片段（index 1）失效
        var voiceChangedBindings = baseBindings
        voiceChangedBindings[heroID] = AudiobookVoiceBinding(
            roleID: heroID,
            voiceID: "v-hero-new",
            voiceRevision: "2",
            modelRevision: "m1"
        )
        let voiceChangedFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: baseAnnotations,
            bindings: voiceChangedBindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )
        let affectedByVoice = AudiobookInvalidation.affectedFragments(
            before: baseSnapshot,
            after: AudiobookDependencySnapshot(sourceSHA256: source.sourceSHA256, fragments: voiceChangedFragments)
        )
        XCTAssertEqual(affectedByVoice, [baseFragments[1].id])

        // 4. 升级底层模型版本（所有角色 modelRevision 变更为 m2）：全部 4 个片段失效
        let modelChangedBindings = baseBindings.mapValues { b in
            AudiobookVoiceBinding(
                roleID: b.roleID,
                voiceID: b.voiceID,
                voiceRevision: b.voiceRevision,
                modelRevision: "m2"
            )
        }
        let modelChangedFragments = try AudiobookFragmentPlanner.plan(
            chapter: chapter,
            annotations: baseAnnotations,
            bindings: modelChangedBindings,
            policy: .standard,
            source: source,
            atoms: atoms
        )
        let affectedByModel = AudiobookInvalidation.affectedFragments(
            before: baseSnapshot,
            after: AudiobookDependencySnapshot(sourceSHA256: source.sourceSHA256, fragments: modelChangedFragments)
        )
        XCTAssertEqual(affectedByModel, Set(baseFragments.map(\.id)))
    }
}
