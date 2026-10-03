import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 段落重做、采用与导出的确定性回归：不合成、不播放、不碰真实作品库。
@MainActor
final class DubbingProjectStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-dubbing-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Fixtures

    private func provenance(digest: String, state: RenderRecipeSnapshot.State = .complete)
    -> RenderProvenanceSnapshot {
        RenderProvenanceSnapshot(
            state: state == .complete ? .verified : .partial,
            reason: nil,
            recipe: RenderRecipeSnapshot(
                state: state,
                missingFields: state == .complete ? [] : ["model.engine_revision"],
                digest: state == .complete ? digest : nil,
                voiceID: "ryan"
            )
        )
    }

    private func makeProject(
        recipeDigest: String = "a",
        state: RenderRecipeSnapshot.State = .complete,
        segments: [DubbingSegment] = [
            DubbingSegment(id: "seg_first", text: "第一段。"),
            DubbingSegment(id: "seg_second", text: "第二段。"),
        ]
    ) -> DubbingProject {
        DubbingProject(
            id: "project_one",
            title: "示例配音",
            scriptText: "第一段。\n第二段。",
            recipe: provenance(digest: recipeDigest, state: state),
            segments: segments,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func makeCandidate(
        id: String,
        segmentID: String,
        text: String,
        recipeDigest: String = "a",
        state: RenderRecipeSnapshot.State = .complete
    ) -> DubbingCandidate {
        DubbingCandidate(
            id: id,
            segmentID: segmentID,
            text: text,
            audioFileName: "\(id).wav",
            provenance: provenance(digest: recipeDigest, state: state)
        )
    }

    private func wav(_ marker: UInt8, samples: Int = 4) -> Data {
        wav(marker, samples: samples, sampleRate: 24_000)
    }

    /// 可以指定真实格式的 WAV，用来验证导出不靠猜而是照实标注。
    private func wav(
        _ marker: UInt8,
        samples: Int = 4,
        sampleRate: Int,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        var pcm = Data()
        for index in 0..<samples {
            pcm.append(marker)
            pcm.append(UInt8(index))
        }
        return wavFile(
            pcm: pcm,
            format: DubbingAudioFormat(
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample
            )
        )
    }

    private func wavFile(
        pcm: Data,
        format: DubbingAudioFormat,
        formatCode: Int = 1
    ) -> Data {
        var file = Data()
        func append16(_ value: Int) {
            let value = UInt16(value)
            file.append(UInt8(value & 0xff))
            file.append(UInt8((value >> 8) & 0xff))
        }
        func append32(_ value: Int) {
            let value = UInt32(value)
            for shift in stride(from: 0, to: 32, by: 8) {
                file.append(UInt8((value >> UInt32(shift)) & 0xff))
            }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append32(36 + pcm.count)
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(formatCode)
        append16(format.channels)
        append32(format.sampleRate)
        append32(format.sampleRate * format.channels * format.bitsPerSample / 8)
        append16(format.channels * format.bitsPerSample / 8)
        append16(format.bitsPerSample)
        file.append(contentsOf: Array("data".utf8))
        append32(pcm.count)
        file.append(pcm)
        return file
    }

    // MARK: - 候选与采用

    func testSavingACandidateDoesNotAdoptIt() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)

        let candidate = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertEqual(candidate.provenance.audioFileSHA256?.count, 64)
        let reloaded = try XCTUnwrap(store.list().first)
        XCTAssertNil(
            reloaded.segments[0].acceptedCandidateID,
            "保存候选只是新增资产，采用必须由用户显式决定"
        )
        XCTAssertEqual(try store.candidates(forProject: project.id).map(\.id), ["cand_a"])
    }

    func testAdoptingSwitchesTheReferenceAndKeepsTheEarlierAudio() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x22),
            toProject: project.id
        )

        let adopted = try store.adopt(
            candidateID: first.id,
            inSegment: "seg_first",
            ofProject: project.id
        )
        let readopted = try store.adopt(
            candidateID: second.id,
            inSegment: "seg_first",
            ofProject: project.id
        )

        XCTAssertEqual(readopted.segments[0].acceptedCandidateID, second.id)
        XCTAssertEqual(
            try store.loadAudio(for: first),
            wav(0x11),
            "采用只改引用，旧候选的音频不能被销毁"
        )
        XCTAssertEqual(
            adopted.segments[0].adoptionHistory,
            [nil],
            "第一次采用要记住此前什么都没采用，否则撤销会退到不存在的版本"
        )
        XCTAssertEqual(readopted.segments[0].adoptionHistory, [nil, first.id])
    }

    func testUndoReturnsToThePreviousAdoptionAndStopsAtTheStart() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x22),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)
        try store.adopt(candidateID: second.id, inSegment: "seg_first", ofProject: project.id)

        let undone = try store.undoAdoption(inSegment: "seg_first", ofProject: project.id)
        XCTAssertEqual(undone.segments[0].acceptedCandidateID, first.id)

        let undoneAgain = try store.undoAdoption(
            inSegment: "seg_first",
            ofProject: project.id
        )
        XCTAssertNil(
            undoneAgain.segments[0].acceptedCandidateID,
            "没有历史时保持未采用，而不是回到一个不存在的版本"
        )
    }

    func testACandidateFromAnotherRecipeCannotBeAdopted() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject(recipeDigest: "a")
        try store.save(project)
        let foreign = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。", recipeDigest: "b"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: foreign.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
        XCTAssertNil(try XCTUnwrap(store.list().first).segments[0].acceptedCandidateID)
    }

    func testAnIncompleteRecipeMakesEveryCandidateUnusable() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject(state: .partial)
        try store.save(project)
        let candidate = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。", state: .partial),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: candidate.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
    }

    func testACandidateWhoseTextNoLongerMatchesIsNotAdoptable() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let stale = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "改过的第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )

        XCTAssertThrowsError(
            try store.adopt(
                candidateID: stale.id,
                inSegment: "seg_first",
                ofProject: project.id
            )
        )
    }

    func testSavingTheSameCandidateTwiceIsIdempotent() throws {
        let store = DubbingProjectStore(directory: directory)
        try store.save(makeProject())
        let candidate = makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。")
        let audio = wav(0x11)

        let first = try store.addCandidate(candidate, audioData: audio, toProject: "project_one")
        let retried = try store.addCandidate(candidate, audioData: audio, toProject: "project_one")

        XCTAssertEqual(first, retried)
        XCTAssertEqual(try store.candidates(forProject: "project_one").count, 1)
    }

    func testReusingACandidateIDForDifferentAudioIsRefused() throws {
        let store = DubbingProjectStore(directory: directory)
        try store.save(makeProject())
        let candidate = makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。")
        try store.addCandidate(candidate, audioData: wav(0x11), toProject: "project_one")

        XCTAssertThrowsError(
            try store.addCandidate(candidate, audioData: wav(0x99), toProject: "project_one")
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
        XCTAssertEqual(try store.loadAudio(for: candidate), wav(0x11))
    }

    // MARK: - 导出

    /// `isSafeIdentifier` 是配音项目目录唯一的逃逸防线。
    ///
    /// `URL.appendingPathComponent(_:)` 自己不会拒绝 `../`，它只是拼接；
    /// `audioFileName == "\(candidate.id).wav"`，所以 id 能带路径分隔符，
    /// 落盘位置就跟着跑到项目目录外面去。字符集、长度上限、不许点号三条性质分别钉住。
    func testACandidateWhoseIDCouldEscapeTheProjectDirectoryIsRefused() throws {
        // 项目库放在测试自己拥有的子目录里，「目录外」也留在测试沙箱内——
        // 直接拿系统临时目录当基准会跨用例互相污染。
        let library = directory.appendingPathComponent("projects", isDirectory: true)
        let store = DubbingProjectStore(directory: library)
        let project = makeProject()
        try store.save(project)
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
            XCTAssertThrowsError(
                try store.addCandidate(
                    makeCandidate(
                        id: hostileID,
                        segmentID: "seg_first",
                        text: "第一段。"
                    ),
                    audioData: wav(0x11),
                    toProject: project.id
                ),
                "候选标识符 \(hostileID) 必须被拒绝"
            ) { error in
                XCTAssertEqual(
                    error as? DubbingProjectError,
                    .invalidIdentifier,
                    "标识符 \(hostileID) 必须报标识符非法，而不是别的错误"
                )
            }
        }

        XCTAssertThrowsError(
            try store.save(
                DubbingProject(
                    id: "../escaped",
                    title: "越界项目",
                    scriptText: "正文",
                    recipe: provenance(digest: "a"),
                    segments: [DubbingSegment(id: "seg_first", text: "正文")],
                    createdAt: Date(timeIntervalSince1970: 1_780_000_000)
                )
            ),
            "项目标识符必须被拒绝"
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .invalidIdentifier)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "恶意标识符不得在项目目录外留下任何文件"
        )
        XCTAssertEqual(try store.list().map(\.id), [project.id])
    }

    func testExportJoinsOnlyAdoptedSegmentsAndMatchesTheScript() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11),
            toProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_second", text: "第二段。"),
            audioData: wav(0x22, samples: 6),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)

        XCTAssertNil(
            try store.export(projectID: project.id),
            "有一段还没采用时不能导出半成品"
        )

        try store.adopt(candidateID: second.id, inSegment: "seg_second", ofProject: project.id)
        let exported = try XCTUnwrap(try store.export(projectID: project.id))

        let expectedPCM = try DubbingAudioExport.clip(fromWAV: wav(0x11)).pcm
            + DubbingAudioExport.clip(fromWAV: wav(0x22, samples: 6)).pcm
        XCTAssertEqual(
            try DubbingAudioExport.clip(fromWAV: exported.audio).pcm,
            expectedPCM,
            "导出音频必须是被采用候选的样本按段落顺序拼接，且不改动样本字节"
        )
        XCTAssertEqual(
            try DubbingAudioExport.clip(fromWAV: exported.audio).format,
            DubbingAudioFormat(sampleRate: 24_000, channels: 1, bitsPerSample: 16)
        )
        XCTAssertEqual(exported.script, "第一段。\n第二段。")
    }

    func testExportStopsWhenAnAdoptedCandidateLostItsRecipe() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)

        // 两段都必须有被采用的候选。否则「导出返回 nil」可能只是因为有一段根本没采用，
        // 配方变化这条真正要考的原因就被掩盖掉了。
        for (candidateID, segmentID, text) in [
            ("cand_a", "seg_first", "第一段。"),
            ("cand_b", "seg_second", "第二段。"),
        ] {
            let candidate = try store.addCandidate(
                makeCandidate(id: candidateID, segmentID: segmentID, text: text),
                audioData: wav(0x11),
                toProject: project.id
            )
            try store.adopt(
                candidateID: candidate.id,
                inSegment: segmentID,
                ofProject: project.id
            )
        }

        // 先钉住「条件齐备时确实导得出」。少了这一步，后面那个 nil 什么都证明不了。
        XCTAssertNotNil(try store.export(projectID: project.id))

        // 项目配方变了，但已采用的候选原样保留——这才是本用例要考的场景。
        // 这里不能用 makeProject(recipeDigest: "b")：save 会整体替换 project，
        // 新构造出来的段落 acceptedCandidateID 全是 nil，导出会因为「没有采用任何候选」
        // 而返回 nil，于是配方变化这条原因依然被掩盖。
        let adopted = try XCTUnwrap(store.list().first { $0.id == project.id })
        try store.save(
            DubbingProject(
                id: adopted.id,
                title: adopted.title,
                scriptText: adopted.scriptText,
                recipe: provenance(digest: "b"),
                segments: adopted.segments,
                createdAt: adopted.createdAt
            )
        )

        XCTAssertNil(try store.export(projectID: project.id))
    }

    func testWAVExportRewritesTheHeaderForTheJoinedAudio() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let format = DubbingAudioFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        let exported = try DubbingAudioExport.makeWAV(from: [
            DubbingAudioClip(pcm: pcm, format: format),
            DubbingAudioClip(pcm: pcm, format: format),
        ])

        XCTAssertEqual(exported.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(exported.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(
            Int(exported.subdata(in: 40..<44).littleEndianUInt32ForTest),
            pcm.count * 2
        )
        XCTAssertEqual(try DubbingAudioExport.clip(fromWAV: exported).pcm, pcm + pcm)
        XCTAssertEqual(exported.count, 44 + pcm.count * 2)
        XCTAssertEqual(
            Int(exported.subdata(in: 24..<28).littleEndianUInt32ForTest),
            16_000,
            "header 的采样率必须来自数据，而不是导出层的常量"
        )
    }

    func testOddSizedSamplesAreRefusedInsteadOfSilentlyPadded() throws {
        let format = DubbingAudioFormat(sampleRate: 24_000, channels: 1, bitsPerSample: 16)
        XCTAssertThrowsError(
            try DubbingAudioExport.makeWAV(from: [
                DubbingAudioClip(pcm: Data([0x01]), format: format),
            ])
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .candidateNotAdoptable)
        }
        XCTAssertThrowsError(
            try DubbingAudioExport.clip(fromWAV: Data("not a wav at all".utf8))
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
    }

    /// 回归 #149：导出必须照着数据声明的采样率写 header。
    ///
    /// 旧实现丢掉 `fmt ` chunk 再写死 24 kHz，16 kHz 的输入会被标成 24 kHz——
    /// 文件照样能播放，只是语速与音高整体错位，属于最难被发现的一类错误。
    func testExportLabelsTheRealSampleRateInsteadOfAssumingOne() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let first = try store.addCandidate(
            makeCandidate(id: "cand_a", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x11, sampleRate: 16_000),
            toProject: project.id
        )
        try store.adopt(candidateID: first.id, inSegment: "seg_first", ofProject: project.id)
        // 16 kHz 的候选先占一段：随后这一段被 24 kHz 的候选换掉。
        let replacement = try store.addCandidate(
            makeCandidate(id: "cand_b", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x33, sampleRate: 16_000),
            toProject: project.id
        )
        try store.adopt(
            candidateID: replacement.id,
            inSegment: "seg_first",
            ofProject: project.id
        )
        let second = try store.addCandidate(
            makeCandidate(id: "cand_c", segmentID: "seg_second", text: "第二段。"),
            audioData: wav(0x22, sampleRate: 16_000),
            toProject: project.id
        )
        try store.adopt(candidateID: second.id, inSegment: "seg_second", ofProject: project.id)

        let exported = try XCTUnwrap(try store.export(projectID: project.id))
        let clip = try DubbingAudioExport.clip(fromWAV: exported.audio)
        XCTAssertEqual(
            clip.format.sampleRate, 16_000,
            "导出的采样率应随数据，不能被写死成 24 kHz，否则成品语速与音高会整体错位"
        )
    }

    /// 参与拼接的候选格式不同时必须显式失败，而不是取其中一个的采样率去标定全部。
    func testExportRefusesToJoinClipsWithDifferentFormats() throws {
        let format = DubbingAudioFormat(sampleRate: 24_000, channels: 1, bitsPerSample: 16)
        let other = DubbingAudioFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        XCTAssertThrowsError(
            try DubbingAudioExport.makeWAV(from: [
                DubbingAudioClip(pcm: Data([0x01, 0x00]), format: format),
                DubbingAudioClip(pcm: Data([0x02, 0x00]), format: other),
            ])
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatMismatch)
        }
    }

    /// 非单声道 16 bit 的剖面不做隐式转换——拒绝并说明原因。
    func testExportRefusesAFormatItCannotJoinHonestly() throws {
        let stereo = DubbingAudioFormat(sampleRate: 24_000, channels: 2, bitsPerSample: 16)
        XCTAssertThrowsError(
            try DubbingAudioExport.makeWAV(from: [
                DubbingAudioClip(pcm: Data([0x01, 0x00]), format: stereo),
            ])
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
        // 声明 0 Hz 的畸形文件同样要拒绝：照写会产出一份播放器拒绝或误读的 header。
        XCTAssertThrowsError(
            try DubbingAudioExport.makeWAV(from: [
                DubbingAudioClip(
                    pcm: Data([0x01, 0x00]),
                    format: DubbingAudioFormat(sampleRate: 0, channels: 1, bitsPerSample: 16)
                ),
            ])
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
        // 只有 RIFF/WAVE 头、没有 fmt 与 data 的文件不能被当成音频。
        var headerOnly = Data("RIFF".utf8)
        headerOnly.append(contentsOf: [24, 0, 0, 0])
        headerOnly.append(contentsOf: Array("WAVE".utf8))
        headerOnly.append(contentsOf: Array("fmt ".utf8))
        headerOnly.append(contentsOf: [16, 0, 0, 0])
        XCTAssertThrowsError(try DubbingAudioExport.clip(fromWAV: headerOnly)) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
    }

    /// 压缩 WAV 的 data 不是裸样本，即使它自称单声道 16 bit。
    ///
    /// μ-law / A-law 的 fmt 就是 channels=1、bitsPerSample=16，只有 format code
    /// 不是 1。放它过去，`makeWAV` 会把 μ-law 字节原样写进一个自称 16 bit PCM 的
    /// 容器——正是「听起来不对却能播放的成品」。所以拒绝发生在 clip 这一步。
    func testCompressedWAVIsRejectedBecauseItsDataIsNotRawPCM() {
        var pcm = Data()
        for index in 0..<8 {
            pcm.append(0xff)
            pcm.append(UInt8(index))
        }
        let muLaw = wavFile(
            pcm: pcm,
            format: DubbingAudioFormat(
                sampleRate: 24_000,
                channels: 1,
                bitsPerSample: 16
            ),
            formatCode: 7
        )

        XCTAssertThrowsError(try DubbingAudioExport.clip(fromWAV: muLaw)) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
    }

    /// `fmt ` 里的位深必须照实读出来，不能假定 16。
    ///
    /// 假定 16 会让 24 bit 的段落被当成 16 bit：字节数不变、采样率不变，
    /// 拼出来的成品能播放，只是速度与音色全错。
    func testBitDepthIsReadFromTheFmtChunkRatherThanAssumed() throws {
        let deep = wav(0x33, samples: 4, sampleRate: 24_000, bitsPerSample: 24)

        let clip = try DubbingAudioExport.clip(fromWAV: deep)

        XCTAssertEqual(clip.format.bitsPerSample, 24)
        XCTAssertEqual(clip.format.sampleRate, 24_000)
        XCTAssertEqual(clip.format.channels, 1)
        XCTAssertThrowsError(try DubbingAudioExport.makeWAV(from: [clip])) { error in
            XCTAssertEqual(error as? DubbingProjectError, .audioFormatUnsupported)
        }
    }

    /// 导出的正文只包含已采用候选对应的段落。
    ///
    /// 段落在导出时必然全部已采用，所以这条在 `export` 里走不到差异；
    /// 但 `adoptedScript` 是公开投影，它自己的承诺要自己站着。
    func testAdoptedScriptOmitsSegmentsThatAdoptedNothing() {
        let project = DubbingProject(
            id: "dub_script",
            title: "正文投影",
            scriptText: "甲。\n乙。\n丙。",
            recipe: RenderProvenanceSnapshot(state: .verified, reason: nil),
            segments: [
                DubbingSegment(id: "dub_script_s1", text: "甲。", acceptedCandidateID: "cand_1"),
                DubbingSegment(id: "dub_script_s2", text: "乙。"),
                DubbingSegment(id: "dub_script_s3", text: "丙。"),
            ]
        )

        XCTAssertEqual(project.adoptedScript, "甲。")
    }

    /// 没有可撤销的历史时，撤销必须什么都不做。
    ///
    /// 索引损坏或手工构造的项目可能出现「当前采用着某版本、历史却是空的」。
    /// 这时若撤销把采用项清空，那一段会静默从成品里消失——用户没报错，
    /// 只是导出的正文短了一段。
    func testUndoWithNoHistoryLeavesTheCurrentAdoptionAlone() {
        var segment = DubbingSegment(
            id: "dub_script_s1",
            text: "甲。",
            acceptedCandidateID: "cand_1",
            adoptionHistory: []
        )

        XCTAssertFalse(segment.undoAdoption())
        XCTAssertEqual(
            segment.acceptedCandidateID,
            "cand_1",
            "没有历史不等于清空采用项"
        )
    }

    // MARK: - 恢复

    func testRestartReclaimsAnUncommittedCandidate() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if url.lastPathComponent == "cand_crash.wav" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let crashing = DubbingProjectStore(
            directory: directory,
            fileOperations: interrupting
        )

        XCTAssertThrowsError(
            try crashing.addCandidate(
                makeCandidate(id: "cand_crash", segmentID: "seg_first", text: "第一段。"),
                audioData: wav(0x11),
                toProject: project.id
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("cand_crash.wav").path
            ),
            "模拟中断发生在音频发布之后"
        )

        let reopened = DubbingProjectStore(directory: directory)
        XCTAssertEqual(try reopened.list().map(\.id), [project.id])
        XCTAssertTrue(try reopened.candidates(forProject: project.id).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("cand_crash.wav").path
            ),
            "索引没提交，重启必须回收刚发布的音频"
        )
    }

    /// 失败的提交必须**当场**收尾，不许把残局留给下一次打开。
    ///
    /// 断言必须发生在任何触发重放的调用之前：`list()` / `candidates()` 都会先跑
    /// `recoverUnlocked()`，量到的是恢复之后的状态——分不清是立即回滚了，
    /// 还是留下了残局、等下次打开才被清掉。
    func testAFailedCommitLeavesNothingBehindBeforeTheStoreIsReopened() throws {
        let store = DubbingProjectStore(directory: directory)
        let project = makeProject()
        try store.save(project)
        let failing = CreativeWorkFileOperations(
            writeInterceptor: { url, _ in
                if url.lastPathComponent == "projects.json" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        )
        let failingStore = DubbingProjectStore(
            directory: directory,
            fileOperations: failing
        )

        XCTAssertThrowsError(
            try failingStore.addCandidate(
                makeCandidate(id: "cand_added", segmentID: "seg_first", text: "第一段。"),
                audioData: wav(0x22),
                toProject: project.id
            )
        )

        // 到这里为止没有任何调用触发过重放，磁盘就是失败瞬间的真实状态。
        let audioFiles = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertEqual(
            audioFiles,
            [],
            "索引写失败后，未提交的候选音频不得留在目录里"
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
    /// 下次打开就少了判定「这次提交到底成没成」的唯一依据。fsync 的顺序本身就是契约。
    func testTheJournalReachesDiskBeforeTheIndexIsCommitted() throws {
        var synced: [URL] = []
        let recording = CreativeWorkFileOperations(
            syncInterceptor: { url in synced.append(url) }
        )
        let store = DubbingProjectStore(directory: directory, fileOperations: recording)
        let project = makeProject()
        try store.save(project)
        synced.removeAll()

        try store.addCandidate(
            makeCandidate(id: "cand_order", segmentID: "seg_first", text: "第一段。"),
            audioData: wav(0x33),
            toProject: project.id
        )

        func position(where predicate: (URL) -> Bool) -> Int? {
            synced.firstIndex(where: predicate)
        }
        let journal = position { $0.lastPathComponent == "journal.json" }
        let transactionDirectory = position { $0.path.contains("/.transactions/") }
        let indexCommit = position { $0.lastPathComponent == "projects.json" }

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

    func testRestartKeepsACommittedCandidate() throws {
        let armed = ArmedInterruption()
        let interrupting = CreativeWorkFileOperations(
            syncInterceptor: { url in
                if armed.isArmed, url.lastPathComponent == "projects.json" {
                    throw CreativeWorkTransactionInterruption.simulatedProcessExit
                }
            }
        )
        let store = DubbingProjectStore(
            directory: directory,
            fileOperations: interrupting
        )
        try store.save(makeProject())
        armed.isArmed = true

        XCTAssertThrowsError(
            try store.addCandidate(
                makeCandidate(id: "cand_done", segmentID: "seg_first", text: "第一段。"),
                audioData: wav(0x11),
                toProject: "project_one"
            )
        )

        let reopened = DubbingProjectStore(directory: directory)
        XCTAssertEqual(try reopened.candidates(forProject: "project_one").map(\.id), ["cand_done"])
        XCTAssertEqual(try reopened.loadAudio(for: try XCTUnwrap(
 reopened.candidates(forProject: "project_one").first)), wav(0x11))
    }
}

/// Lets a test interrupt exactly one later commit instead of the first one.
private final class ArmedInterruption {
    var isArmed = false
}

private extension Data {
    var littleEndianUInt32ForTest: UInt32 {
        UInt32(self[0]) | UInt32(self[1]) << 8 | UInt32(self[2]) << 16 | UInt32(self[3]) << 24
    }
}

// MARK: - 切分：只用文稿，不产生任何时间戳

final class DubbingSegmentPlannerTests: XCTestCase {
    func testParagraphsSplitOnLineBreaksAndBlankLinesAreDropped() {
        let segments = DubbingSegmentPlanner.segments(
            from: "第一段正文。\n\n  第二段正文。  \n\n"
        )
        XCTAssertEqual(segments, ["第一段正文。", "第二段正文。"])
    }

    func testEmptyScriptProducesNoSegments() {
        XCTAssertEqual(DubbingSegmentPlanner.segments(from: "   \n\n  "), [])
    }

    func testLongParagraphSplitsAtSentenceBoundariesWithinTheLimit() {
        let sentence = String(repeating: "这是一个句子。", count: 40)
        let segments = DubbingSegmentPlanner.segments(from: sentence)

        XCTAssertGreaterThan(segments.count, 1, "超长段落必须可切分，否则无法局部返修")
        for segment in segments {
            XCTAssertLessThanOrEqual(
                segment.count,
                DubbingSegmentPlanner.maximumCharactersPerSegment
            )
            XCTAssertTrue(
                sentence.contains(segment),
                "切分不得丢字或改写：\(segment)"
            )
        }
        XCTAssertEqual(
            segments.joined(),
            sentence,
            "所有段落拼回去必须等于原文"
        )
    }

    /// 没有标点的超长文本也要能切：按字数硬切，不产生空白段或空段。
    func testUnpunctuatedLongTextSplitsWithoutEmptySegments() {
        let segments = DubbingSegmentPlanner.segments(
            from: String(repeating: "字", count: 500)
        )

        XCTAssertEqual(segments.joined(), String(repeating: "字", count: 500))
        XCTAssertFalse(segments.contains { $0.isEmpty })
        XCTAssertEqual(segments.count, 3)
    }
}
