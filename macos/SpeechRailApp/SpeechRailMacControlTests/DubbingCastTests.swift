import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 多角色脚本：角色—音色绑定、句间停顿、逐段失效与导出清单。
///
/// 全部用临时目录里的真实 store 与真实 WAV；不合成、不播放、不碰用户数据。
@MainActor
final class DubbingCastTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-cast-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    private func recipe(
        voiceID: String,
        digest: String = "digest-a",
        voiceRevision: String? = "rev-1",
        engine: String = "engine-1",
        artifact: String = "artifact-1",
        artifactRevision: String = "artifact-rev-1",
        sampleRate: Int = 24_000
    ) -> RenderRecipeSnapshot {
        RenderRecipeSnapshot(
            state: .complete,
            missingFields: [],
            digest: digest,
            voiceID: voiceID,
            voiceRevision: voiceRevision,
            modelArtifact: artifact,
            modelArtifactRevision: artifactRevision,
            engineRevision: engine,
            sampleRate: sampleRate,
            channels: 1
        )
    }

    private func provenance(_ recipe: RenderRecipeSnapshot) -> RenderProvenanceSnapshot {
        RenderProvenanceSnapshot(state: .verified, reason: nil, recipe: recipe)
    }

    private func binding(_ voiceID: String, mode: String = "instruction", revision: String? = "rev-1")
    -> DubbingVoiceBinding {
        DubbingVoiceBinding(voiceID: voiceID, voiceName: voiceID, voiceRevision: revision, mode: mode)
    }

    private func role(
        _ id: String,
        _ name: String,
        voice: DubbingVoiceBinding? = nil,
        runtime: DubbingRenderRuntime? = nil,
        speed: Double = 1.0
    ) -> DubbingRole {
        DubbingRole(id: id, name: name, voice: voice, runtime: runtime, speed: speed)
    }

    private func project(
        segments: [DubbingSegment],
        cast: [DubbingRole],
        defaultRoleID: String? = nil
    ) -> DubbingProject {
        DubbingProject(
            id: "dub_cast",
            title: "多角色脚本",
            scriptText: "甲说。\n乙说。",
            recipe: .legacyUnknown,
            segments: segments,
            cast: cast,
            defaultRoleID: defaultRoleID,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func candidate(
        _ id: String,
        segmentID: String,
        text: String,
        voiceID: String,
        recipe overrides: RenderRecipeSnapshot? = nil
    ) -> DubbingCandidate {
        DubbingCandidate(
            id: id,
            segmentID: segmentID,
            text: text,
            audioFileName: "\(id).wav",
            provenance: provenance(overrides ?? recipe(voiceID: voiceID))
        )
    }

    /// 单声道 16 bit 线性 PCM，每段长度可指定，便于核对停顿插入量。
    private func wav(samples: Int, sampleRate: Int = 24_000, fill: UInt8 = 1) -> Data {
        var pcm = Data()
        for index in 0..<samples {
            pcm.append(fill)
            pcm.append(UInt8(index % 251))
        }
        var file = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { file.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { file.append(contentsOf: $0) }
        }
        file.append(Data("RIFF".utf8))
        append32(UInt32(pcm.count) + 36)
        file.append(Data("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        file.append(Data("data".utf8))
        append32(UInt32(pcm.count))
        file.append(pcm)
        return file
    }

    private func makeStore() -> DubbingProjectStore {
        DubbingProjectStore(directory: directory)
    }

    private func seed(
        _ store: DubbingProjectStore,
        project: DubbingProject,
        candidates: [(DubbingCandidate, Data)]
    ) async throws {
        _ = try await store.save(project, operationID: UUID())
        for (candidate, audio) in candidates {
            _ = try await store.addCandidate(
                candidate, audioData: audio, toProject: project.id, operationID: UUID()
            )
        }
    }

    // MARK: - 角色表规则

    func testEmptyAndDuplicateRoleNamesAreRejected() {
        XCTAssertThrowsError(try DubbingCastRules.validate([role("role_1", "   ")])) { error in
            XCTAssertEqual(error as? DubbingProjectError, .roleNameEmpty)
        }
        XCTAssertThrowsError(
            try DubbingCastRules.validate([role("role_1", "旁白"), role("role_2", "旁白")])
        ) { error in
            XCTAssertEqual(error as? DubbingProjectError, .roleNameDuplicate)
        }
        XCTAssertThrowsError(try DubbingCastRules.validate([role("role 1", "旁白")])) { error in
            XCTAssertEqual(error as? DubbingProjectError, .invalidIdentifier)
        }
    }

    func testRoleNamesAreTrimmedAndCapped() throws {
        let long = String(repeating: "长", count: DubbingRole.maximumNameLength + 10)
        let cast = try DubbingCastRules.validate([role("role_1", "  旁白  "), role("role_2", long)])
        XCTAssertEqual(cast[0].name, "旁白")
        XCTAssertEqual(cast[1].name.count, DubbingRole.maximumNameLength)
    }

    /// 参考音色只支持 1.0x：绑定到克隆声音时语速被钉死，而不是等到渲染才失败。
    func testCloneRoleIsPinnedToOneSpeed() throws {
        let cast = try DubbingCastRules.validate([
            role("role_1", "旁白", voice: binding("clone_voice", mode: "clone"), speed: 1.4)
        ])
        XCTAssertEqual(cast[0].speed, 1.0)
    }

    /// 语速越界是自相矛盾的数据：拒绝并说明边界，不悄悄夹成 1.0x。
    func testOutOfRangeRoleSpeedIsRejected() throws {
        for speed in [0.4, 2.1, -1.0, 10.0] {
            do {
                _ = try DubbingCastRules.validate([role("role_1", "旁白", speed: speed)])
                XCTFail("语速 \(speed) 不该被接受")
            } catch {
                XCTAssertEqual(error as? DubbingProjectError, .roleSpeedOutOfRange)
            }
        }
        // 边界值本身合法。
        _ = try DubbingCastRules.validate([role("role_1", "旁白", speed: 0.5)])
        _ = try DubbingCastRules.validate([role("role_1", "旁白", speed: 2.0)])
    }

    // MARK: - 停顿

    func testPauseIsClampedMeasuredAndLabelled() {
        XCTAssertEqual(DubbingPause.clamped(-20), 0)
        XCTAssertEqual(DubbingPause.clamped(99_999), DubbingPause.maximumMilliseconds)
        // 500ms @ 24kHz 单声道 16bit = 12000 采样 × 2 字节
        XCTAssertEqual(DubbingPause.byteCount(milliseconds: 500, sampleRate: 24_000), 24_000)
        XCTAssertEqual(DubbingPause.byteCount(milliseconds: 0, sampleRate: 24_000), 0)
        XCTAssertEqual(DubbingPause.byteCount(milliseconds: 500, sampleRate: 0), 0)
        XCTAssertEqual(DubbingPause.label(0), "无停顿")
        XCTAssertEqual(DubbingPause.label(400), "停顿 0.4 秒")
    }

    func testSegmentPauseIsClampedAtConstruction() {
        let segment = DubbingSegment(id: "seg_1", text: "甲说。", pauseAfterMilliseconds: 90_000)
        XCTAssertEqual(segment.pauseAfterMilliseconds, DubbingPause.maximumMilliseconds)
    }

    // MARK: - 角色与音色对账

    func testAuditStaysSilentUntilTheVoiceListIsRead() {
        let cast = [role("role_1", "旁白")]
        XCTAssertTrue(
            DubbingCastAudit.issues(cast: cast, voices: [], voicesLoadState: .loading).isEmpty
        )
        XCTAssertEqual(
            DubbingCastAudit.issues(cast: cast, voices: [], voicesLoadState: .failed).count,
            0
        )
    }

    func testAuditReportsEachProblemSeparately() {
        let cast = [
            role("role_1", "旁白"),
            role("role_2", "记者", voice: binding("gone")),
            role("role_3", "旁白二", voice: binding("busy")),
            role("role_4", "旁白三", voice: binding("moved", revision: "rev-old")),
        ]
        let voices = [
            CreatorVoice(id: "busy", name: "忙碌", available: false),
            CreatorVoice(id: "moved", name: "已改", available: true, revision: "rev-new"),
        ]

        let issues = DubbingCastAudit.issues(cast: cast, voices: voices, voicesLoadState: .loaded)

        XCTAssertEqual(issues.map(\.roleID), ["role_1", "role_2", "role_3", "role_4"])
        guard case .voiceUnassigned = issues[0] else { return XCTFail("未选声音未报出") }
        guard case .voiceMissing = issues[1] else { return XCTFail("音色被删未报出") }
        guard case .voiceUnavailable = issues[2] else { return XCTFail("音色不可用未报出") }
        guard case .voiceRevisionChanged = issues[3] else { return XCTFail("音色变化未报出") }
    }

    // MARK: - 历史记录无损读取

    func testLegacyProjectDecodesAsSingleVoice() throws {
        // 升级前的索引：没有 cast / defaultRoleID，段落也没有 roleID 与停顿。
        let legacy = """
        {
          "id": "dub_legacy",
          "title": "老项目",
          "scriptText": "第一段。",
          "recipe": {"state": "unavailable", "reason": "legacy_record_without_provenance"},
          "segments": [
            {"id": "s1", "text": "第一段。", "acceptedCandidateID": null, "adoptionHistory": []}
          ],
          "createdAt": "2026-06-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(DubbingProject.self, from: legacy)

        XCTAssertFalse(project.isMultiRole)
        XCTAssertTrue(project.cast.isEmpty)
        XCTAssertNil(project.defaultRoleID)
        XCTAssertNil(project.segments[0].roleID)
        XCTAssertEqual(project.segments[0].pauseAfterMilliseconds, 0)
    }

    // MARK: - 逐段失效

    func testChangingOneRoleInvalidatesOnlyItsSegments() {
        let cast = [
            role("role_1", "旁白", voice: binding("voice_a")),
            role("role_2", "记者", voice: binding("voice_b")),
        ]
        let segments = [
            DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1"),
            DubbingSegment(id: "s2", text: "乙说。", roleID: "role_2"),
        ]
        let project = project(segments: segments, cast: cast, defaultRoleID: "role_1")

        let a = candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a")
        let b = candidate("c2", segmentID: "s2", text: "乙说。", voiceID: "voice_b")
        XCTAssertTrue(project.isValid(a))
        XCTAssertTrue(project.isValid(b))

        // 只换「记者」的声音：旁白那一段不受影响。
        var updated = project
        updated.cast[1].voice = binding("voice_c")
        XCTAssertTrue(updated.isValid(a))
        XCTAssertEqual(updated.rejection(for: b), .candidateVoiceChanged)
    }

    func testSameVoiceWithANewRevisionInvalidatesCandidates() {
        let cast = [role("role_1", "旁白", voice: binding("voice_a"))]
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1")],
            cast: cast
        )
        // 角色还没跑过：任何声音对的候选都算有效。
        XCTAssertTrue(
            project.isValid(candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a"))
        )

        var fixed = project
        fixed.cast[0].runtime = DubbingRenderRuntime(recipe: recipe(voiceID: "voice_a"))
        XCTAssertTrue(
            fixed.isValid(candidate("c2", segmentID: "s1", text: "甲说。", voiceID: "voice_a"))
        )
        // 同一个 voiceID，但音色被改过（revision 变了）：旧候选必须失效。
        let changed = candidate(
            "c3", segmentID: "s1", text: "甲说。", voiceID: "voice_a",
            recipe: recipe(voiceID: "voice_a", voiceRevision: "rev-2")
        )
        XCTAssertEqual(fixed.rejection(for: changed), .candidateVoiceChanged)
    }

    func testDifferentRuntimeForTheSameRoleIsReportedAsRuntimeChange() {
        let cast = [role("role_1", "旁白", voice: binding("voice_a"))]
        var project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1")],
            cast: cast
        )
        project.cast[0].runtime = DubbingRenderRuntime(recipe: recipe(voiceID: "voice_a"))

        let moved = candidate(
            "c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a",
            recipe: recipe(voiceID: "voice_a", artifactRevision: "artifact-rev-2")
        )
        XCTAssertEqual(project.rejection(for: moved), .candidateRuntimeChanged)
    }

    func testSegmentWithoutRoleOrDefaultIsUnassignedNotGuessed() {
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。")],
            cast: [role("role_1", "旁白", voice: binding("voice_a"))]
        )
        let candidate = candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a")
        XCTAssertEqual(project.rejection(for: candidate), .segmentVoiceUnassigned)
    }

    // MARK: - Store：角色表提交

    func testDeletingARoleStillInUseIsRejected() async throws {
        let store = makeStore()
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1")],
            cast: [role("role_1", "旁白"), role("role_2", "记者")],
            defaultRoleID: "role_1"
        )
        try await seed(store, project: project, candidates: [])

        do {
            _ = try await store.updateCast(
                projectID: project.id,
                cast: [role("role_2", "记者")],
                defaultRoleID: "role_2",
                operationID: UUID()
            )
            XCTFail("还有段落指着这个角色时不该允许删除")
        } catch {
            // 「还在用」必须与「找不到」分开：用户要看到的下一步是改派段落，不是刷新。
            XCTAssertEqual(error as? DubbingProjectError, .roleStillInUse)
        }
        let reloaded = try await store.list().first { $0.id == project.id }
        XCTAssertEqual(reloaded?.cast.count, 2, "失败的提交不得改动角色表")
    }

    /// 删除默认角色本身不是错，错的是删完之后默认角色不在表里。
    func testDefaultRoleMissingFromCastIsStillRoleNotFound() async throws {
        let store = makeStore()
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。", roleID: "role_2")],
            cast: [role("role_1", "旁白"), role("role_2", "记者")],
            defaultRoleID: "role_1"
        )
        try await seed(store, project: project, candidates: [])

        do {
            _ = try await store.updateCast(
                projectID: project.id,
                cast: [role("role_2", "记者")],
                defaultRoleID: "role_1",
                operationID: UUID()
            )
            XCTFail("默认角色不在新角色表里时不该允许提交")
        } catch {
            XCTAssertEqual(error as? DubbingProjectError, .roleNotFound)
        }
    }

    func testAssigningAnUnknownRoleIsRejected() async throws {
        let store = makeStore()
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。")],
            cast: [role("role_1", "旁白")],
            defaultRoleID: "role_1"
        )
        try await seed(store, project: project, candidates: [])

        do {
            _ = try await store.assignSegmentRole(
                segmentID: "s1", inProject: project.id, roleID: "role_missing", operationID: UUID()
            )
            XCTFail("不该接受不存在的角色")
        } catch {
            XCTAssertEqual(error as? DubbingProjectError, .roleNotFound)
        }
    }

    func testSegmentRoleAndPauseRoundTripThroughTheStore() async throws {
        let store = makeStore()
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。"), DubbingSegment(id: "s2", text: "乙说。")],
            cast: [role("role_1", "旁白"), role("role_2", "记者")],
            defaultRoleID: "role_1"
        )
        try await seed(store, project: project, candidates: [])

        _ = try await store.assignSegmentRole(
            segmentID: "s2", inProject: project.id, roleID: "role_2", operationID: UUID()
        )
        _ = try await store.setSegmentPause(
            segmentID: "s1", inProject: project.id, milliseconds: 90_000, operationID: UUID()
        )

        let listed = try await store.list()
        let reloaded = try XCTUnwrap(listed.first { $0.id == project.id })
        XCTAssertEqual(reloaded.segments[1].roleID, "role_2")
        XCTAssertEqual(reloaded.segments[0].pauseAfterMilliseconds, DubbingPause.maximumMilliseconds)
    }

    /// 角色第一次成功渲染时固定运行事实，之后同角色的候选才有可比基准。
    func testFirstCandidateFixesTheRoleRuntime() async throws {
        let store = makeStore()
        let project = project(
            segments: [DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1")],
            cast: [role("role_1", "旁白", voice: binding("voice_a"))],
            defaultRoleID: "role_1"
        )
        let first = candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a")
        try await seed(store, project: project, candidates: [(first, wav(samples: 40))])

        let projects = try await store.list()
        let reloaded = try XCTUnwrap(projects.first { $0.id == project.id })
        let runtime = try XCTUnwrap(reloaded.cast.first?.runtime)
        XCTAssertEqual(runtime.engineRevision, "engine-1")
        XCTAssertEqual(runtime.voiceRevision, "rev-1")
        XCTAssertEqual(runtime.sampleRate, 24_000)
    }

    // MARK: - 导出

    func testExportWritesOrderRolePauseAndMatchingAudio() async throws {
        let store = makeStore()
        let cast = [
            role("role_1", "旁白", voice: binding("voice_a")),
            role("role_2", "记者", voice: binding("voice_b")),
        ]
        let project = project(
            segments: [
                DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1", pauseAfterMilliseconds: 500),
                DubbingSegment(id: "s2", text: "乙说。", roleID: "role_2"),
            ],
            cast: cast,
            defaultRoleID: "role_1"
        )
        let a = candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a")
        let b = candidate("c2", segmentID: "s2", text: "乙说。", voiceID: "voice_b")
        try await seed(
            store, project: project,
            candidates: [(a, wav(samples: 100)), (b, wav(samples: 60, fill: 2))]
        )
        _ = try await store.adopt(candidateID: "c1", inSegment: "s1", ofProject: project.id, operationID: UUID())
        _ = try await store.adopt(candidateID: "c2", inSegment: "s2", ofProject: project.id, operationID: UUID())

        let prepared = try await store.prepareExport(projectID: project.id)
        defer { Task { try? await store.releaseExport(leaseID: prepared.leaseID) } }

        let audio = try Data(contentsOf: prepared.audioURL)
        // 两段 PCM（100 + 60 采样）+ 段间停顿 500ms @24kHz（24000 字节）+ 44 字节头
        XCTAssertEqual(audio.count, 44 + (100 * 2) + 24_000 + (60 * 2))
        XCTAssertEqual(audio.prefix(4), Data("RIFF".utf8))

        let script = try String(contentsOf: prepared.scriptURL, encoding: .utf8)
        XCTAssertEqual(script, "甲说。\n乙说。", "停顿不是控制标记，不能进正文")

        let manifestData = try Data(contentsOf: prepared.manifestURL)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(document["schema_version"] as? String, DubbingExportManifest.schemaVersion)
        XCTAssertEqual(document["mode"] as? String, "multi_role")
        let segments = try XCTUnwrap(document["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0]["index"] as? Int, 1)
        XCTAssertEqual(segments[0]["role_name"] as? String, "旁白")
        XCTAssertEqual(segments[0]["voice_id"] as? String, "voice_a")
        XCTAssertEqual(segments[0]["pause_after_milliseconds"] as? Int, 500)
        XCTAssertEqual(segments[1]["role_name"] as? String, "记者")
        // 末段之后的停顿不进音频，清单里也不声称有。
        XCTAssertEqual(segments[1]["pause_after_milliseconds"] as? Int, 0)
    }

    func testExportRefusesAStaleSegmentInsteadOfSkippingIt() async throws {
        let store = makeStore()
        let project = project(
            segments: [
                DubbingSegment(id: "s1", text: "甲说。", roleID: "role_1"),
                DubbingSegment(id: "s2", text: "乙说。", roleID: "role_2"),
            ],
            cast: [
                role("role_1", "旁白", voice: binding("voice_a")),
                role("role_2", "记者", voice: binding("voice_b")),
            ],
            defaultRoleID: "role_1"
        )
        let a = candidate("c1", segmentID: "s1", text: "甲说。", voiceID: "voice_a")
        let b = candidate("c2", segmentID: "s2", text: "乙说。", voiceID: "voice_b")
        try await seed(store, project: project, candidates: [(a, wav(samples: 40)), (b, wav(samples: 40))])
        _ = try await store.adopt(candidateID: "c1", inSegment: "s1", ofProject: project.id, operationID: UUID())
        _ = try await store.adopt(candidateID: "c2", inSegment: "s2", ofProject: project.id, operationID: UUID())

        // 把「记者」换成另一个声音：第二段的已采用版本随之失效。
        _ = try await store.updateCast(
            projectID: project.id,
            cast: [
                role("role_1", "旁白", voice: binding("voice_a")),
                role("role_2", "记者", voice: binding("voice_c")),
            ],
            defaultRoleID: "role_1",
            operationID: UUID()
        )

        do {
            _ = try await store.prepareExport(projectID: project.id)
            XCTFail("失效段落不能被跳过拼成「完整」成品")
        } catch {
            XCTAssertEqual(error as? DubbingExportError, .incompleteProject)
        }
    }

    func testSingleVoiceProjectStillExportsWithNoPause() async throws {
        let store = makeStore()
        let project = DubbingProject(
            id: "dub_single",
            title: "单声音",
            scriptText: "第一段。",
            recipe: provenance(recipe(voiceID: "ryan")),
            segments: [DubbingSegment(id: "s1", text: "第一段。")],
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let only = DubbingCandidate(
            id: "c1", segmentID: "s1", text: "第一段。", audioFileName: "c1.wav",
            provenance: provenance(recipe(voiceID: "ryan"))
        )
        try await seed(store, project: project, candidates: [(only, wav(samples: 20))])
        _ = try await store.adopt(candidateID: "c1", inSegment: "s1", ofProject: project.id, operationID: UUID())

        let prepared = try await store.prepareExport(projectID: project.id)
        defer { Task { try? await store.releaseExport(leaseID: prepared.leaseID) } }

        let audio = try Data(contentsOf: prepared.audioURL)
        XCTAssertEqual(audio.count, 44 + 40)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: prepared.manifestURL))
                as? [String: Any]
        )
        XCTAssertEqual(document["mode"] as? String, "single_voice")
    }
}
