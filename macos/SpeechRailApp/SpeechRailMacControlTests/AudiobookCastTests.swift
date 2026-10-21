import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookCastTests: XCTestCase {
    func testExplicitGlobalRegistrationPreservesSourceAndRejectsBookPromotion() async throws {
        let catalog = VoiceCatalogStore()
        try await catalog.toggleFavorite(voiceID: "global-clone")
        try await catalog.registerGlobalVoice(voiceID: "global-clone", creationSource: .instantClone)
        try await catalog.registerGlobalVoice(voiceID: "global-clone", creationSource: .instantClone)
        let catalogActual1 = await catalog.metadata(for: "global-clone")?.visibilityScope
        XCTAssertEqual(catalogActual1, .globalReusable)
        let catalogActual2 = await catalog.metadata(for: "global-clone")?.creationSource
        XCTAssertEqual(catalogActual2, .instantClone)
        let catalogActual3 = await catalog.metadata(for: "global-clone")?.isFavorite
        XCTAssertEqual(catalogActual3, true)
        try await catalog.registerBookExclusiveVoice(voiceID: "book-only", bookID: UUID(), bookTitle: nil,
            roleID: nil, roleName: nil, archetype: nil, creationSource: .voiceDesign)
        do {
            _ = try await catalog.registerGlobalVoice(voiceID: "book-only", creationSource: .voiceDesign)
            XCTFail("Expected catalog operation to fail")
        } catch {}
        let catalogActual4 = await catalog.metadata(for: "book-only")?.visibilityScope
        XCTAssertEqual(catalogActual4, .bookExclusive)
    }
    private func makeTestCastController(store: AudiobookProjectStore) -> AudiobookCastController {
        let ids = ["custom", "custom-voice-1", "draft-designed-voice", "dylan", "fault-archetype-voice", "fault-fixture-hero", "fault-fixture-narrator", "fault-replacement-hero", "fault-shared-pool-voice", "master_zhao", "one", "other-book", "serena", "shared-voice", "split-hero", "split-narrator", "test-source-exclusive-voice", "test-target-exclusive-voice", "uncle_chen", "uncle_fu", "v", "v-narrator", "v_bookA_lindong", "v_bookB_role_1", "v_global_7", "vivian", "voice-hero", "voice-narrator"]
        let snapshot = p0Snapshot(ids.map { makeTestSafeVoice(id: $0, name: $0) })
        return AudiobookCastController(store: store, capabilityProvider: { snapshot })
    }

    private func p0Snapshot(_ voices: [SafeVoiceEntry]) -> EffectiveCapabilitySnapshot {
        let model = ConfiguredModelIdentity(assurance: .configuredCatalog, catalogRevision: String(repeating: "a", count: 40))
        return .init(serviceInstanceEpoch: "p0", catalogRevision: "p0", snapshotID: "p0", profile: "p0",
                     models: ["tts": model, "tts_clone": model], voices: voices, operations: [:], guarantees: [:])
    }

    private func p0Roles(bookID: UUID, count: Int) -> ([AudiobookCharacter], [AudiobookAnnotation]) {
        let roles = (0..<count).map { AudiobookCharacter(bookID: bookID, displayName: "角色\($0)", isNarrator: $0 == 0, isMajor: $0 == 0) }
        let chapter = UUID(), window = UUID()
        let annotations = roles.enumerated().map { offset, role in
            AudiobookAnnotation(bookID: bookID, chapterID: chapter, windowID: window, atomID: UUID(),
                sourceRange: .init(lowerBound: Int64(offset * 10), upperBound: Int64(offset * 10 + 5)), assignment: .assigned(roleID: role.id))
        }
        return (roles, annotations)
    }

    func testRechunkingPreservesDialogueScalarCount() throws {
        let book = UUID(), chapter = UUID(), role = AudiobookCharacter(bookID: UUID(), displayName: "甲", isMajor: false)
        let source = try AudiobookSourceIndex(utf8: Data("甲乙abc😀".utf8))
        func ann(_ lower: Int64, _ upper: Int64) -> AudiobookAnnotation {
            .init(bookID: book, chapterID: chapter, windowID: UUID(), atomID: UUID(), sourceRange: .init(lowerBound: lower, upperBound: upper), assignment: .assigned(roleID: role.id))
        }
        let whole = AudiobookCastRegistry.computeRoleDialogueStats(characters: [role], annotations: [ann(0, 13)], source: source)
        let split = AudiobookCastRegistry.computeRoleDialogueStats(characters: [role], annotations: [ann(0, 6), ann(6, 13)], source: source)
        XCTAssertEqual(whole.statsByRoleID[role.id]?.dialogueScalarCount, 6)
        XCTAssertEqual(split.statsByRoleID[role.id]?.dialogueScalarCount, 6)
        XCTAssertEqual(whole.statsByRoleID[role.id]?.tier, split.statsByRoleID[role.id]?.tier)
    }

    func testNarrationDistanceDoesNotCreateDirectDialogue() {
        let (roles, base) = p0Roles(bookID: UUID(), count: 3)
        let chapter = base[0].chapterID
        let annotations: [AudiobookAnnotation] = (0..<10).map { i in
            let id = i == 0 ? roles[1].id : (i == 9 ? roles[2].id : roles[0].id)
            let range = AudiobookSourceRange(lowerBound: Int64(i * 10), upperBound: Int64(i * 10 + 5))
            return AudiobookAnnotation(bookID: roles[0].bookID, chapterID: chapter, windowID: UUID(), atomID: UUID(), sourceRange: range, assignment: .assigned(roleID: id))
        }
        let graph = AudiobookSceneConflictGraph.build(characters: roles, annotations: annotations)
        XCTAssertFalse(graph.edges.contains { $0.kind == .directDialogue })
        XCTAssertTrue(graph.edges.contains { $0.kind == .chapterCoPresence })
    }

    func testDifferentScenesKeepDistinctEdges() {
        let (roles, annotations) = p0Roles(bookID: UUID(), count: 3)
        let scenes = [AudiobookCastingScene(chapterID: annotations[0].chapterID, sourceRange: .init(lowerBound: 0, upperBound: 20)),
                      AudiobookCastingScene(chapterID: annotations[0].chapterID, sourceRange: .init(lowerBound: 20, upperBound: 30))]
        let graph = AudiobookSceneConflictGraph.build(characters: roles, annotations: annotations, scenes: scenes)
        XCTAssertFalse(graph.edges.contains { $0.kind == .directDialogue })
        XCTAssertTrue(graph.edges.contains { $0.kind == .chapterCoPresence })
    }

    func testDuplicateWindowsDoNotDoubleCountEdges() {
        let (roles, annotations) = p0Roles(bookID: UUID(), count: 3)
        let once = AudiobookSceneConflictGraph.build(characters: roles, annotations: annotations)
        let twice = AudiobookSceneConflictGraph.build(characters: roles, annotations: annotations + annotations)
        XCTAssertEqual(once, twice)
    }

    func testWeakEdgesNeverBecomeDirectDialogue() {
        let (roles, _) = p0Roles(bookID: UUID(), count: 3)
        let rows = (0..<10).flatMap { _ -> [AudiobookAnnotation] in
            let chapter = UUID()
            return [0, 10].enumerated().map { offset, position in .init(bookID: roles[0].bookID, chapterID: chapter, windowID: UUID(), atomID: UUID(),
                sourceRange: .init(lowerBound: Int64(position * 10), upperBound: Int64(position * 10 + 5)), assignment: .assigned(roleID: roles[offset + 1].id)) }
        }
        // Authoritative atom positions retain the eight intervening formatting/narration blocks.
        let atoms = Set(rows.map(\.chapterID)).flatMap { chapter in (0...10).map { index in
            AudiobookTextAtom(chapterID: chapter, ordinal: index, sourceRange: .init(lowerBound: Int64(index * 10), upperBound: Int64(index * 10 + 5)), kind: .body)
        } }
        let graph = AudiobookSceneConflictGraph.build(characters: roles, annotations: rows, atoms: atoms)
        XCTAssertFalse(graph.edges.contains { $0.kind == .directDialogue })
        XCTAssertEqual(Set(graph.edges.map(\.kind)), [.chapterCoPresence])
    }

    func testVoiceTaxonomyKeepsIndependentUnknownAttributes() {
        let fixtures: [(String, String, String)] = [("男童 high", "male", "child"), ("女童", "female", "child"),
            ("elderly female 老年女性", "female", "elder"), ("中性 neutral", "neutral", "unknown"), ("", "unknown", "unknown"),
            ("young male 青年男声", "male", "young")]
        for (text, gender, age) in fixtures {
            let traits = VoiceTaxonomyClassifier.resolveTraits(description: text)
            XCTAssertEqual(traits.gender.value, gender, text)
            XCTAssertEqual(traits.age.value, age, text)
        }
        XCTAssertEqual(VoiceTaxonomyClassifier.resolveTraits(description: "柔和").gender.source, .unknown)
    }

    func testManualVoiceTraitsOverrideInference() {
        var manual = AudiobookVoiceTraits()
        manual.gender = .init(value: "neutral", source: .manual, confidence: 1)
        let traits = VoiceTaxonomyClassifier.resolveTraits(description: "elder female", override: manual)
        XCTAssertEqual(traits.gender.value, "neutral")
        XCTAssertEqual(traits.gender.source, .manual)
        XCTAssertEqual(traits.age.value, "elder")
    }

    func testScenePlannerSolvesKnownColorableFixture() throws {
        let roles = (0..<6).map { _ in UUID() }
        let edges = (0..<6).map { i in AudiobookSceneConflictGraph.Edge(roleA: roles[i], roleB: roles[(i + 1) % 6], kind: .directDialogue, sourceIDs: ["edge-\(i)"]) }
        let graph = AudiobookSceneConflictGraph(edges: edges)
        let candidates = Dictionary(uniqueKeysWithValues: roles.map { ($0, ["a", "b"]) })
        let result = try AudiobookCastingPlanner.assign(roleIDs: roles, candidates: candidates, graph: graph, strategy: .sceneAware)
        XCTAssertTrue(result.residualDirectPairs.isEmpty)
        XCTAssertEqual(result.assignments.count, 6)
        let baseline = try AudiobookCastingPlanner.assign(roleIDs: roles, candidates: candidates, graph: graph, strategy: .baseline)
        XCTAssertGreaterThanOrEqual(baseline.residualDirectPairs.count, result.residualDirectPairs.count)
    }

    func testTwoVoicesCannotResolveDialogueTriangle() throws {
        let roles = (0..<3).map { _ in UUID() }
        let graph = AudiobookSceneConflictGraph(edges: [
            .init(roleA: roles[0], roleB: roles[1], kind: .directDialogue, sourceIDs: ["1"]),
            .init(roleA: roles[1], roleB: roles[2], kind: .directDialogue, sourceIDs: ["2"]),
            .init(roleA: roles[0], roleB: roles[2], kind: .directDialogue, sourceIDs: ["3"])])
        let result = try AudiobookCastingPlanner.assign(roleIDs: roles, candidates: Dictionary(uniqueKeysWithValues: roles.map { ($0, ["a", "b"]) }), graph: graph)
        XCTAssertFalse(result.residualDirectPairs.isEmpty)
        XCTAssertEqual(result.status, .provenInsufficient)
    }

    func testSearchBudgetDoesNotRelaxLockedBindings() throws {
        let a = UUID(), b = UUID()
        let graph = AudiobookSceneConflictGraph(edges: [.init(roleA: a, roleB: b, kind: .directDialogue, sourceIDs: ["1"])])
        let result = try AudiobookCastingPlanner.assign(roleIDs: [a, b], candidates: [a: ["a", "b"], b: ["a", "b"]], graph: graph, frozen: [a: "a"], budget: 0)
        XCTAssertEqual(result.assignments[a], "a")
        XCTAssertEqual(result.status, .budgetExceeded)
        XCTAssertEqual(result.evaluatedCandidates, 0)
    }

    func testSearchBudgetCountsCandidateEvaluationIncludingGreedyOrdering() throws {
        let role = UUID()
        let result = try AudiobookCastingPlanner.assign(roleIDs: [role], candidates: [role: (0..<100).map { "v\($0)" }],
            graph: .init(edges: []), budget: 2)
        XCTAssertEqual(result.evaluatedCandidates, 2)
        XCTAssertEqual(result.status, .budgetExceeded)
    }

    func testConstrainedColoringPreservesPreallocatedVoice() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let graph = AudiobookSceneConflictGraph(edges: [.init(roleA: a, roleB: b, kind: .directDialogue, sourceIDs: ["a-b"]),
            .init(roleA: b, roleB: c, kind: .directDialogue, sourceIDs: ["b-c"])])
        let result = try AudiobookCastingPlanner.assign(roleIDs: [a, b, c], candidates: [a: ["a"], b: ["a", "b"], c: ["a"]], graph: graph, frozen: [a: "a"])
        XCTAssertEqual(result.status, .solved)
        XCTAssertEqual(result.assignments, [a: "a", b: "b", c: "a"])
    }

    func testStructuredVoiceTraitsKeepServiceFactsAndManualPriority() throws {
        let voice = makeTestSafeVoice(id: "profile", name: "young female")
        let profile = VoiceTaxonomyClassifier.resolveTraits(for: voice)
        XCTAssertEqual(profile.locale.value, "zh")
        XCTAssertEqual(profile.locale.source, .service)
        var manual = AudiobookVoiceTraits(); manual.gender = .init(value: "male", source: .manual, confidence: 1)
        let overridden = VoiceTaxonomyClassifier.resolveTraits(for: voice, metadata: .init(voiceID: voice.id, voiceTraits: manual))
        XCTAssertEqual(overridden.gender.value, "male")
        XCTAssertEqual(overridden.locale.value, "zh")
    }

    func testPlannerScoreCacheInvalidatesOnlyChangedVoice() throws {
        let book = UUID(), (roles, annotations) = p0Roles(bookID: book, count: 200)
        let voices = (0..<500).map { makeTestSafeVoice(id: "score-v\($0)", name: "声音\($0)") }
        let snapshot = p0Snapshot(voices)
        let first = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations, snapshot: snapshot,
            catalog: .init(), bookID: book, existingBindings: [:], requiredRoleIDs: nil)
        XCTAssertTrue(first.isApplicable)
        XCTAssertEqual(first.scoredCombinations, 100_000)
        let second = AudiobookCastRegistry.makeCastingPlan(characters: roles.reversed(), annotations: annotations.reversed(), snapshot: snapshot,
            catalog: .init(), bookID: book, existingBindings: [:], requiredRoleIDs: nil, cachedScores: first.cachedScores)
        XCTAssertEqual(second.scoredCombinations, 0)
        XCTAssertEqual(second.proposedBindings, first.proposedBindings)
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voices[0].id: .init(voiceID: voices[0].id, visibilityScope: .globalReusable, isFavorite: true)]))
        let changed = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations, snapshot: snapshot,
            catalog: catalog, bookID: book, existingBindings: [:], requiredRoleIDs: nil, cachedScores: second.cachedScores)
        XCTAssertEqual(changed.scoredCombinations, 200)
    }

    func testOversizedScoreMatrixStopsWithoutChangingExistingBindings() throws {
        let book = UUID(), (roles, annotations) = p0Roles(bookID: book, count: 201)
        let voices = (0..<500).map { makeTestSafeVoice(id: "bounded-v\($0)", name: "声音\($0)") }
        let existing = AudiobookVoiceBinding(roleID: roles[0].id, voiceID: voices[0].id,
            voiceRevision: voices[0].voiceRevision, modelRevision: String(repeating: "a", count: 40))
        let plan = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations, snapshot: p0Snapshot(voices),
            catalog: .init(), bookID: book, existingBindings: [roles[0].id: existing], requiredRoleIDs: nil)
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.issues.contains { $0.code == .searchBudgetExceeded && $0.isBlocking })
        XCTAssertFalse(plan.issues.contains { $0.code == .insufficientVoiceCapacity })
        XCTAssertLessThanOrEqual(plan.scoredCombinations, 100_000)
        XCTAssertTrue(plan.proposedBindings == [roles[0].id: existing], "预算耗尽必须保留原绑定")
    }

    func testWeightedMatchingBudgetIsDistinctFromInfeasibility() throws {
        let role = UUID()
        XCTAssertThrowsError(try AudiobookCastRegistry.maximumWeightExclusiveMatching(roleIDs: [role],
            candidates: [role: ["a", "b"]], scores: [role: ["a": 2, "b": 1]], workBudget: 0)) { error in
            XCTAssertEqual(error as? AudiobookCastRegistry.ExclusiveMatchingError, .budgetExceeded)
        }
        let result = try AudiobookCastRegistry.maximumWeightExclusiveMatching(roleIDs: [role],
            candidates: [role: ["a", "b"]], scores: [role: ["a": 2, "b": 1]], workBudget: 100)
        XCTAssertEqual(result[role], "a")
    }

    func testSurfaceCatalogRequiresDefaultSystemIdentityForUnknownVoices() throws {
        let nonDefault = CreatorVoice(id: "unregistered-system", name: "非默认系统声音", isDefault: false,
            isSystem: true, available: true, mode: "system")
        let systemDefault = CreatorVoice(id: "system-default", name: "默认声音", isDefault: true,
            isSystem: true, available: true, mode: "system")
        let falseSystem = CreatorVoice(id: "clone", name: "克隆", isDefault: true,
            isSystem: true, available: true, mode: "clone")
        let missing = VoiceCatalogSnapshot()
        XCTAssertFalse(missing.permitsSurface(nonDefault, bookID: nil))
        XCTAssertTrue(missing.permitsSurface(systemDefault, bookID: nil))
        XCTAssertFalse(missing.permitsSurface(falseSystem, bookID: nil))
        let unknown = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [nonDefault.id: .init(voiceID: nonDefault.id)]))
        XCTAssertFalse(unknown.permitsSurface(nonDefault, bookID: nil))
        let explicitlyGlobal = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [nonDefault.id:
            .init(voiceID: nonDefault.id, visibilityScope: .globalReusable)]))
        XCTAssertTrue(explicitlyGlobal.permitsSurface(nonDefault, bookID: nil))
        let base = makeTestSafeVoice(id: "safe-non-default", name: "非默认")
        let safeNonDefault = SafeVoiceEntry(id: base.id, name: base.name, mode: "system",
            isSystem: true, isDefault: false, available: true, availabilityReason: base.availabilityReason,
            voiceIdentityAssurance: base.voiceIdentityAssurance, model: base.model, descriptors: base.descriptors,
            operations: base.operations)
        XCTAssertFalse(missing.permitsSurface(safeNonDefault, bookID: nil))
    }

    func testLargeCastingKeepsCompletePlanWithoutClaimingResidualConflictsAreProven() throws {
        let roles = (0..<80).map { _ in UUID() }
        let triangle: [AudiobookSceneConflictGraph.Edge] = [
            .init(roleA: roles[0], roleB: roles[1], kind: .directDialogue, sourceIDs: ["a"]),
            .init(roleA: roles[1], roleB: roles[2], kind: .directDialogue, sourceIDs: ["b"]),
            .init(roleA: roles[0], roleB: roles[2], kind: .directDialogue, sourceIDs: ["c"])
        ]
        let outcome = try AudiobookCastingPlanner.assign(roleIDs: roles,
            candidates: Dictionary(uniqueKeysWithValues: roles.map { ($0, ["a", "b"]) }),
            graph: .init(edges: triangle))

        XCTAssertEqual(outcome.assignments.count, 80)
        XCTAssertFalse(outcome.residualDirectPairs.isEmpty)
        XCTAssertEqual(outcome.status, .residualConflicts, "大角色表不进行完备搜索，不能宣称已经证明无解")
        XCTAssertLessThanOrEqual(outcome.evaluatedCandidates, 160, "大角色表只执行有界初次分配，避免深度修复黑洞")
    }

    func testResidualSceneSharingRequiresExplicitAcknowledgement() throws {
        let book = UUID(), (roles, annotations) = p0Roles(bookID: book, count: 4)
        let voices = (0..<2).map { makeTestSafeVoice(id: "shared-risk-v\($0)", name: "声音\($0)") }
        let plan = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations, snapshot: p0Snapshot(voices),
            catalog: .init(), bookID: book, existingBindings: [:], requiredRoleIDs: nil)
        XCTAssertTrue(plan.isApplicable)
        XCTAssertTrue(plan.hasUnavoidableSceneConflicts)
        let risks = plan.issues.filter { $0.code == .sharedSceneRisk }
        XCTAssertFalse(risks.isEmpty)
        XCTAssertTrue(risks.allSatisfy { $0.severity == .warning && plan.requiredAcknowledgements.contains($0.id) })
    }

    func testUnavoidableSceneConflictsClearsWhenPoolSufficient() throws {
        let book = UUID(), (roles, annotations) = p0Roles(bookID: book, count: 4)
        let voices = (0..<4).map { makeTestSafeVoice(id: "sufficient-v\($0)", name: "声音\($0)") }
        let plan = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations, snapshot: p0Snapshot(voices),
            catalog: .init(), bookID: book, existingBindings: [:], requiredRoleIDs: nil)
        XCTAssertTrue(plan.isApplicable)
        XCTAssertFalse(plan.hasUnavoidableSceneConflicts)
    }

    func testAtomicWriteFailureDoesNotNotifyOrReplaceState() async throws {
        final class Probe: @unchecked Sendable {
            let lock = NSLock(); var count = 0
            func increment() { lock.withLock { count += 1 } }
        }
        let url = tempRoot.appendingPathComponent("write-failure.json")
        try await VoiceCatalogStore(storageURL: url).toggleFavorite(voiceID: "retained")
        let original = try Data(contentsOf: url)
        let catalog = VoiceCatalogStore(storageURL: url, writeAtomically: { _, _ in throw VoiceCatalogError.unavailable })
        let before = await catalog.refresh(), probe = Probe()
        let observer = NotificationCenter.default.addObserver(forName: VoiceCatalogStore.didChange, object: catalog, queue: nil) { _ in probe.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            _ = try await catalog.toggleFavorite(voiceID: "new")
            XCTFail("Expected catalog operation to fail")
        } catch {}
        let catalogActual5 = await catalog.refresh()
        XCTAssertEqual(catalogActual5, before)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(probe.lock.withLock { probe.count }, 0)
    }

    func testTwoHundredRolesFiveHundredVoicesScoreOnlyOnce() throws {
        let roles = (0..<200).map { _ in UUID() }, voices = (0..<500).map { "v\($0)" }
        var cache = AudiobookCastingScoreCache()
        let first = cache.scores(roleIDs: roles, voiceIDs: voices, roleRevision: "r", voiceRevision: "v") { _, _ in 1 }
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(cache.evaluationCount, 100_000)
        let second = cache.scores(roleIDs: roles.reversed(), voiceIDs: voices.reversed(), roleRevision: "r", voiceRevision: "v") { _, _ in XCTFail("缓存不应重复评分"); return 0 }
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.evaluationCount, 100_000)
    }

    func testPromoteArchiveRestoreKeepsGlobalScope() async throws {
        let url = tempRoot.appendingPathComponent("lifecycle.json"), book = UUID()
        let catalog = VoiceCatalogStore(storageURL: url)
        try await catalog.registerBookExclusiveVoice(voiceID: "voice", bookID: book, bookTitle: "夹具", roleID: UUID(), roleName: "甲", archetype: .youngMale)
        try await catalog.promoteToGlobalReusable(voiceID: "voice")
        try await catalog.archiveVoices(voiceIDs: ["voice"])
        try await catalog.unarchiveVoices(voiceIDs: ["voice"])
        let restarted = VoiceCatalogStore(storageURL: url)
        _ = await restarted.refresh()
        let catalogActual6 = await restarted.metadata(for: "voice")?.visibilityScope
        XCTAssertEqual(catalogActual6, .globalReusable)
        let catalogActual7 = await restarted.isVoiceActiveForBook(voiceID: "voice", currentBookID: UUID())
        XCTAssertTrue(catalogActual7)
    }

    func testArchivedLegacyOriginIsNotEnoughToInferScope() async throws {
        let url = tempRoot.appendingPathComponent("old-catalog.json")
        let document: [String: Any] = ["metadataByVoiceID": ["old": ["voiceID": "old", "scope": "archived", "originBookID": UUID().uuidString,
            "isFavorite": false, "customTags": [], "collectionIDs": [], "updatedAt": 0]], "collections": [], "preferredCollectionIDByBookID": []]
        let original = try JSONSerialization.data(withJSONObject: document)
        try original.write(to: url)
        let catalog = VoiceCatalogStore(storageURL: url)
        do {
            _ = try await catalog.unarchiveVoices(voiceIDs: ["old"])
            XCTFail("Expected catalog operation to fail")
        } catch {}
        let catalogActual8 = await catalog.isVoiceActiveForBook(voiceID: "old", currentBookID: nil)
        XCTAssertFalse(catalogActual8)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWriteFailureDoesNotPublishSuccess() async throws {
        let url = tempRoot.appendingPathComponent("catalog-is-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let catalog = VoiceCatalogStore(storageURL: url)
        let before = await catalog.refresh()
        do {
            _ = try await catalog.toggleFavorite(voiceID: "new")
            XCTFail("Expected catalog operation to fail")
        } catch {}
        let catalogActual9 = await catalog.refresh()
        XCTAssertEqual(catalogActual9, before)
        let catalogActual10 = await catalog.metadata(for: "new")
        XCTAssertNil(catalogActual10)
    }

    func testCatalogMigrationPreservesCollectionsAndUnknownFieldsOnRestart() async throws {
        let url = tempRoot.appendingPathComponent("migration-catalog.json"), book = UUID(), collection = VoiceCollection(name: "夹具剧团", voiceIDs: ["voice"])
        let state = VoiceCatalogStore.PersistedState(metadataByVoiceID: ["voice": .init(voiceID: "voice", visibilityScope: .globalReusable, collectionIDs: [collection.id])], collections: [collection], preferredCollectionIDByBookID: [book: collection.id])
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var metadata = raw["metadataByVoiceID"] as! [String: [String: Any]]
        let oldScope = metadata["voice"]?.removeValue(forKey: "visibilityScope")
        metadata["voice"]?["scope"] = oldScope
        metadata["voice"]?.removeValue(forKey: "lifecycleState")
        metadata["voice"]?.removeValue(forKey: "createdAt")
        metadata["voice"]?["futureFacts"] = "keep"
        var traits = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AudiobookVoiceTraits())) as! [String: Any]
        traits["futureDimension"] = ["keep": true]
        var gender = traits["gender"] as! [String: Any]; gender["futureConfidence"] = "keep"; traits["gender"] = gender
        metadata["voice"]?["voiceTraits"] = traits
        raw["metadataByVoiceID"] = metadata
        var collections = raw["collections"] as! [[String: Any]]; collections[0]["futureCollection"] = "keep"
        raw["collections"] = collections
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        let catalog = VoiceCatalogStore(storageURL: url)
        try await catalog.toggleFavorite(voiceID: "voice")
        let restarted = VoiceCatalogStore(storageURL: url)
        _ = await restarted.refresh()
        let catalogActual11 = await restarted.collections
        XCTAssertEqual(catalogActual11, [collection])
        let catalogActual12 = await restarted.preferredCollectionID(for: book)
        XCTAssertEqual(catalogActual12, collection.id)
        let catalogActual13 = await restarted.metadata(for: "voice")?.isFavorite == true
        XCTAssertTrue(catalogActual13)
        let catalogActual14 = await restarted.metadata(for: "voice")?.createdAt
        XCTAssertNil(catalogActual14, "旧文件没有提供的创建时点保持未知")
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 2)
        let saved = envelope["state"] as! [String: Any]
        XCTAssertEqual((saved["metadataByVoiceID"] as? [String: [String: Any]])?["voice"]?["futureFacts"] as? String, "keep")
        let savedTraits = ((saved["metadataByVoiceID"] as? [String: [String: Any]])?["voice"]?["voiceTraits"] as? [String: Any])
        XCTAssertEqual((savedTraits?["futureDimension"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual((savedTraits?["gender"] as? [String: Any])?["futureConfidence"] as? String, "keep")
        XCTAssertEqual((saved["collections"] as? [[String: Any]])?.first?["futureCollection"] as? String, "keep")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).contains { $0.contains("migration-catalog.json.legacy.") })
    }

    func testUnreadableCatalogPreservesUnknownRecords() async throws {
        let url = tempRoot.appendingPathComponent("unknown-catalog.json")
        let data = Data("{\"schemaVersion\":999,\"unrecognized\":{\"keep\":true}}".utf8)
        try data.write(to: url)
        let catalog = VoiceCatalogStore(storageURL: url)
        let catalogActual15 = await catalog.refresh().loadState
        XCTAssertEqual(catalogActual15, .unsupportedSchema)
        do {
            _ = try await catalog.toggleFavorite(voiceID: "new")
            XCTFail("Expected catalog operation to fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testBookOriginVoiceCanBeCastInAnotherBookWithoutPromotion() {
        let sourceBook = UUID(), targetBook = UUID()
        let voice = makeTestSafeVoice(id: "reused-custom", name: "历史文稿声音", mode: "clone")
        let (roles, annotations) = p0Roles(bookID: targetBook, count: 1)
        let metadata = VoiceAssetMetadata(voiceID: voice.id, visibilityScope: .bookExclusive,
            originBookID: sourceBook, originRoleID: UUID())
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voice.id: metadata]))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: annotations,
            snapshot: p0Snapshot([voice]), catalog: catalog, bookID: targetBook, existingBindings: [:])

        XCTAssertTrue(catalog.permits(voice, bookID: targetBook))
        XCTAssertTrue(plan.isApplicable, "有效的来源登记不应限制跨书复用：\(plan.issues)")
        XCTAssertEqual(plan.eligibleVoiceCount, 1)
        XCTAssertEqual(plan.proposedBindings[roles[0].id]?.voiceID, voice.id)
        XCTAssertEqual(catalog.state.metadataByVoiceID[voice.id], metadata, "复用不应晋升或改写来源")

        let unvalidated = makeTestSafeVoice(id: voice.id, name: voice.name, mode: "clone", productionReady: false)
        let blocked = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: annotations,
            snapshot: p0Snapshot([unvalidated]), catalog: catalog, bookID: targetBook, existingBindings: [:])
        XCTAssertFalse(blocked.isApplicable, "跨书复用不能绕过制作验收")
        XCTAssertTrue(blocked.proposedBindings.isEmpty)
        XCTAssertTrue(blocked.issues.contains { $0.code == .voiceNotProductionReady })
    }

    func testBookOriginVoiceCatalogHelpersAllowCrossBookReuseAndRejectInvalidRecords() {
        let sourceBook = UUID(), targetBook = UUID()
        let voice = makeTestSafeVoice(id: "reusable", name: "历史声音", mode: "clone")
        let surfaceVoice = CreatorVoice(id: voice.id, name: voice.name, isDefault: false,
            isSystem: false, available: true, mode: "clone")
        let active = VoiceAssetMetadata(voiceID: voice.id, visibilityScope: .bookExclusive, originBookID: sourceBook)
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voice.id: active]))
        for bookID in [sourceBook, targetBook, nil] {
            XCTAssertTrue(catalog.isVoiceActiveForBook(voiceID: voice.id, currentBookID: bookID))
            XCTAssertTrue(catalog.permitsSurface(voice, bookID: bookID))
            XCTAssertTrue(catalog.permitsSurface(surfaceVoice, bookID: bookID))
        }
        let rejected: [VoiceAssetMetadata] = [
            .init(voiceID: voice.id, visibilityScope: .unknown, originBookID: sourceBook),
            .init(voiceID: voice.id, visibilityScope: .bookExclusive, lifecycleState: .archived, originBookID: sourceBook),
            .init(voiceID: voice.id, visibilityScope: .bookExclusive)
        ]
        for metadata in rejected {
            let invalid = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voice.id: metadata]))
            XCTAssertFalse(invalid.permits(voice, bookID: targetBook))
            XCTAssertFalse(invalid.isVoiceActiveForBook(voiceID: voice.id, currentBookID: targetBook))
            XCTAssertFalse(invalid.permitsSurface(voice, bookID: targetBook))
            XCTAssertFalse(invalid.permitsSurface(surfaceVoice, bookID: targetBook))
        }
    }

    func testTraitBasedRecastingReusesOtherBookVoicesWithoutChangingItsBindings() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let source = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let target = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        XCTAssertNotEqual(source.bookID, target.bookID)
        let catalogStore = VoiceCatalogStore()
        let voices = [
            makeTestSafeVoice(id: "narrator", name: "旁白 narrator"),
            makeTestSafeVoice(id: "a-male", name: "青年男声", mode: "clone"),
            makeTestSafeVoice(id: "b-male", name: "另一青年男声", mode: "clone"),
            makeTestSafeVoice(id: "z-female", name: "青年女声", mode: "clone")
        ]
        for voice in voices.dropFirst() {
            try await catalogStore.registerBookExclusiveVoice(voiceID: voice.id, bookID: source.bookID,
                bookTitle: "历史文稿", roleID: source.hero.id, roleName: source.hero.displayName,
                archetype: voice.id == "z-female" ? .youngFemale : .youngMale)
        }
        let snapshot = p0Snapshot(voices)
        let catalog = await catalogStore.refresh()
        let sourceBinding = AudiobookVoiceBinding(roleID: source.hero.id, voiceID: "a-male",
            voiceRevision: voices[1].voiceRevision, modelRevision: String(repeating: "a", count: 40))
        try await store.saveVoiceBindings(bookID: source.bookID, bindings: [sourceBinding])
        let sourceBindings = try await store.voiceBindings(for: source.bookID)
        let sourceCharacters = try await store.characters(for: source.bookID)

        var characters = try await store.characters(for: target.bookID)
        characters.append(contentsOf: [
            AudiobookCharacter(bookID: target.bookID, displayName: "女配甲", isMajor: false),
            AudiobookCharacter(bookID: target.bookID, displayName: "女配丙", isMajor: false),
            AudiobookCharacter(bookID: target.bookID, displayName: "女配乙", isMajor: false)
        ])
        let maleRoleID = target.hero.id
        for index in characters.indices {
            characters[index].voicePolicy = .init(sharingPolicy: characters[index].isNarrator || characters[index].id == maleRoleID ? .exclusive : .automatic,
                bindingOrigin: .manual, isLocked: true)
            guard !characters[index].isNarrator else { continue }
            var traits = AudiobookVoiceTraits()
            traits.gender = .init(value: characters[index].id == maleRoleID ? "male" : "female", source: .manual, confidence: 1)
            traits.age = .init(value: "young", source: .manual, confidence: 1)
            characters[index].voiceTraitsOverride = traits
        }
        try await store.saveCharacters(bookID: target.bookID, characters: characters)
        var annotations = try await store.annotations(for: target.bookID)
        XCTAssertGreaterThanOrEqual(annotations.count, characters.count)
        for index in annotations.indices {
            annotations[index].assignment = .assigned(roleID: characters[index % characters.count].id)
        }
        try await store.saveAnnotations(bookID: target.bookID, annotations: annotations)
        let previous = characters.map { AudiobookVoiceBinding(roleID: $0.id, voiceID: "a-male",
            voiceRevision: voices[1].voiceRevision, modelRevision: String(repeating: "a", count: 40)) }
        try await store.saveVoiceBindings(bookID: target.bookID, bindings: previous)
        let originalTargetBindings = try await store.voiceBindings(for: target.bookID)

        let plan = try await store.prepareRecastingPlan(bookID: target.bookID, snapshot: snapshot, catalog: catalog)
        XCTAssertTrue(plan.isApplicable, "显式重配应重新规划已有重复绑定：\(plan.issues)")
        XCTAssertEqual(plan.proposedBindings[target.narrator.id]?.voiceID, "narrator")
        for role in characters where !role.isNarrator && role.id != maleRoleID {
            XCTAssertEqual(plan.proposedBindings[role.id]?.voiceID, "z-female", "女声不能因来源书籍或候选ID排序被排除")
        }
        XCTAssertTrue(["a-male", "b-male"].contains(plan.proposedBindings[maleRoleID]?.voiceID ?? ""))
        let replacement = try XCTUnwrap(plan.issues.first { $0.code == .bindingReplacementConsentRequired })
        XCTAssertTrue(plan.requiredAcknowledgements.contains(replacement.id))
        let controller = AudiobookCastController(store: store, capabilityProvider: { snapshot }, voiceCatalog: catalogStore)
        do {
            try await controller.applyCastingPlan(bookID: target.bookID, plan: plan, acknowledgedIssueIDs: [])
            XCTFail("重配已有绑定必须先确认")
        } catch {}
        let unconfirmedBindings = try await store.voiceBindings(for: target.bookID)
        XCTAssertEqual(unconfirmedBindings, originalTargetBindings)
        try await controller.applyCastingPlan(bookID: target.bookID, plan: plan,
            acknowledgedIssueIDs: plan.requiredAcknowledgements)
        let savedTargetBindings = try await store.voiceBindings(for: target.bookID)
        let savedSourceBindings = try await store.voiceBindings(for: source.bookID)
        let savedSourceCharacters = try await store.characters(for: source.bookID)
        let savedCatalog = await catalogStore.refresh()
        XCTAssertEqual(savedTargetBindings, plan.proposedBindings)
        XCTAssertEqual(savedSourceBindings, sourceBindings, "当前书的重配不得改写历史书籍绑定")
        XCTAssertEqual(Self.charactersByID(savedSourceCharacters), Self.charactersByID(sourceCharacters))
        XCTAssertEqual(savedCatalog.state, catalog.state, "复用不应改写声音来源或分类")
    }

    func testSharedPoolReservesMatchingTraitsBeforeExclusiveAllocation() {
        let book = UUID()
        var (roles, annotations) = p0Roles(bookID: book, count: 11)
        var femaleTraits = AudiobookVoiceTraits()
        femaleTraits.gender = .init(value: "female", source: .manual, confidence: 1)
        femaleTraits.age = .init(value: "young", source: .manual, confidence: 1)
        for index in roles.indices where !roles[index].isNarrator {
            roles[index].voiceTraitsOverride = femaleTraits
            roles[index].isMajor = index <= 2
        }
        var maleTraits = femaleTraits
        maleTraits.gender = .init(value: "male", source: .manual, confidence: 1)
        roles[2].voiceTraitsOverride = maleTraits
        for roleIndex in 1...2 {
            for index in 0..<(roleIndex == 1 ? 20 : 10) {
                let offset = Int64(1_000 + roleIndex * 1_000 + index * 10)
                annotations.append(.init(bookID: book, chapterID: annotations[0].chapterID, windowID: UUID(), atomID: UUID(),
                    sourceRange: .init(lowerBound: offset, upperBound: offset + 5), assignment: .assigned(roleID: roles[roleIndex].id)))
            }
        }
        let narrator = makeTestSafeVoice(id: "narrator", name: "旁白 narrator")
        let maleVoices = (0..<7).map { makeTestSafeVoice(id: "a-male-\($0)", name: "青年男声\($0)") }
        let female = makeTestSafeVoice(id: "z-female", name: "青年女声")
        let voices = [narrator] + maleVoices + [female]
        var metadata = Dictionary(uniqueKeysWithValues: maleVoices.map {
            ($0.id, VoiceAssetMetadata(voiceID: $0.id, visibilityScope: .globalReusable, voiceTraits: maleTraits))
        })
        metadata[female.id] = .init(voiceID: female.id, visibilityScope: .globalReusable, voiceTraits: femaleTraits)
        let narratorBinding = AudiobookVoiceBinding(roleID: roles[0].id, voiceID: narrator.id,
            voiceRevision: narrator.voiceRevision, modelRevision: String(repeating: "a", count: 40))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: annotations,
            snapshot: p0Snapshot(voices), catalog: .init(state: .init(metadataByVoiceID: metadata)), bookID: book,
            existingBindings: [roles[0].id: narratorBinding])

        XCTAssertGreaterThan(roles.count, voices.count)
        XCTAssertTrue(plan.isApplicable, "目录中的女声应先保留给共享女性角色：\(plan.issues)")
        XCTAssertEqual(plan.proposedBindings[roles[0].id], narratorBinding, "已有旁白独占绑定必须保留")
        XCTAssertEqual(plan.proposedPolicies[roles[0].id]?.sharingPolicy, .exclusive)
        for role in roles.dropFirst(3) {
            XCTAssertEqual(plan.proposedPolicies[role.id]?.sharingPolicy, .sharedMinor)
            XCTAssertEqual(plan.proposedBindings[role.id]?.voiceID, female.id,
                "共享女性角色不能因较早ID男声占满候选池，或唯一女声先被自动独占而错配")
        }
    }

    func testEmptyScopedPoolNeverFallsBack() {
        let bookID = UUID(), voice = makeTestSafeVoice(id: "other-book", name: "他书声音")
        let (roles, anns) = p0Roles(bookID: bookID, count: 1)
        for metadata in [VoiceAssetMetadata(voiceID: voice.id, visibilityScope: .bookExclusive),
                         .init(voiceID: voice.id, visibilityScope: .unknown, originBookID: UUID()),
                         .init(voiceID: voice.id, visibilityScope: .bookExclusive, lifecycleState: .archived, originBookID: UUID())] {
            let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voice.id: metadata]))
            let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
                snapshot: p0Snapshot([voice]), catalog: catalog, bookID: bookID, existingBindings: [:])
            XCTAssertTrue(plan.proposedBindings.isEmpty)
            XCTAssertFalse(plan.isApplicable)
            XCTAssertTrue(plan.issues.contains { $0.code == .noEligibleVoices })
        }
    }

    func testAvailableButNotProductionReadyIsExcluded() throws {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        for value in [false as Any, NSNull()] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeTestSafeVoice(id: "v", name: "v"))) as? [String: Any])
            object["production_ready"] = value
            let voice = try JSONDecoder().decode(SafeVoiceEntry.self, from: JSONSerialization.data(withJSONObject: object))
            let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns, snapshot: p0Snapshot([voice]),
                catalog: .init(), bookID: book, existingBindings: [:])
            XCTAssertFalse(plan.isApplicable)
            XCTAssertEqual(plan.eligibleVoiceCount, 0)
            XCTAssertTrue(plan.issues.contains { $0.code == .voiceNotProductionReady && $0.voiceIDs == [voice.id] })
        }
    }

    func testMissingCustomScopeNeedsConfirmation() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        let voice = makeTestSafeVoice(id: "custom", name: "custom", mode: "clone")
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice]), catalog: .init(loadState: .missing), bookID: book, existingBindings: [:])
        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.proposedBindings.isEmpty)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceIdentityUnknown && $0.voiceIDs == [voice.id] })
        let missingOrigin = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [voice.id: .init(voiceID: voice.id, visibilityScope: .bookExclusive)]))
        XCTAssertFalse(missingOrigin.permits(voice, bookID: book))
    }

    func testUnknownOriginAndArchivedVoiceHaveDifferentRepairActions() throws {
        let book = UUID(), (roles, annotations) = p0Roles(bookID: book, count: 1)
        let unknown = makeTestSafeVoice(id: "unknown", name: "未知来源", mode: "clone")
        let archived = makeTestSafeVoice(id: "archived", name: "归档音色", mode: "clone")
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [
            unknown.id: .init(voiceID: unknown.id, visibilityScope: .unknown),
            archived.id: .init(voiceID: archived.id, visibilityScope: .globalReusable, lifecycleState: .archived)
        ]))
        let plan = AudiobookCastRegistry.makeCastingPlan(characters: roles, annotations: annotations,
            snapshot: p0Snapshot([unknown, archived]), catalog: catalog, bookID: book, existingBindings: [:], requiredRoleIDs: nil)
        let unknownIssue = try XCTUnwrap(plan.issues.first { $0.voiceIDs == [unknown.id] })
        XCTAssertEqual(unknownIssue.code, .voiceIdentityUnknown)
        XCTAssertTrue(unknownIssue.nextAction.contains("来源"))
        XCTAssertFalse(unknownIssue.nextAction.contains("归档"))
        let archivedIssue = try XCTUnwrap(plan.issues.first { $0.voiceIDs == [archived.id] })
        XCTAssertEqual(archivedIssue.code, .voiceScopeUnavailable)
        XCTAssertTrue(archivedIssue.nextAction.contains("归档"))
    }

    func testLibrarySourceClassificationIsIndependentOfCrossBookPermission() {
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [
            "cast": .init(voiceID: "cast", visibilityScope: .bookExclusive, originBookID: UUID()),
            "global": .init(voiceID: "global", visibilityScope: .globalReusable),
            "archived": .init(voiceID: "archived", visibilityScope: .globalReusable, lifecycleState: .archived),
            "unknown": .init(voiceID: "unknown", visibilityScope: .unknown)
        ]))
        XCTAssertFalse(catalog.isGlobalLibrarySource(voiceID: "cast", isDefaultSystemPreset: false))
        XCTAssertTrue(catalog.isGlobalLibrarySource(voiceID: "global", isDefaultSystemPreset: false))
        XCTAssertFalse(catalog.isGlobalLibrarySource(voiceID: "archived", isDefaultSystemPreset: false))
        XCTAssertFalse(catalog.isGlobalLibrarySource(voiceID: "unknown", isDefaultSystemPreset: false))
        XCTAssertTrue(catalog.isGlobalLibrarySource(voiceID: "preset", isDefaultSystemPreset: true))
        XCTAssertTrue(catalog.isVoiceActiveForBook(voiceID: "cast", currentBookID: UUID()))
    }

    func testCatalogReadFailureIsNotEmptyCatalog() async throws {
        let url = tempRoot.appendingPathComponent("catalog.json")
        let catalogActual16 = await VoiceCatalogStore(storageURL: url).refresh().loadState
        XCTAssertEqual(catalogActual16, .missing)
        try Data("broken json".utf8).write(to: url)
        let catalogActual17 = await VoiceCatalogStore(storageURL: url).refresh().loadState
        XCTAssertEqual(catalogActual17, .unreadable)
        try Data(#"{"schema_version":99}"#.utf8).write(to: url)
        let catalogActual18 = await VoiceCatalogStore(storageURL: url).refresh().loadState
        XCTAssertEqual(catalogActual18, .unsupportedSchema)
        try JSONEncoder().encode(VoiceCatalogStore.PersistedState()).write(to: url)
        let catalogActual19 = await VoiceCatalogStore(storageURL: url).refresh().loadState
        XCTAssertEqual(catalogActual19, .ready)
    }

    func testAliasesDoNotIncreaseVoiceCapacity() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voice = makeTestSafeVoice(id: "one", name: "one", aliases: ["alias-one", "alias-two"])
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice]), catalog: .init(), bookID: book, existingBindings: [:])
        XCTAssertEqual(plan.eligibleVoiceCount, 1)
        XCTAssertFalse(plan.isApplicable)
    }

    func testCrossChapterSharingRequiresExplicitAcceptance() {
        let book = UUID(), (roles, _) = p0Roles(bookID: book, count: 3)
        let anns = roles.map { role in AudiobookAnnotation(bookID: book, chapterID: UUID(), windowID: UUID(), atomID: UUID(),
            sourceRange: .init(lowerBound: 0, upperBound: 5), assignment: .assigned(roleID: role.id)) }
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }), catalog: .init(), bookID: book, existingBindings: [:])
        XCTAssertTrue(plan.isApplicable)
        XCTAssertFalse(plan.requiredAcknowledgements.isEmpty, "共享方案不因角色分属不同章节而免于接受")
    }

    func testOriginRoleIsPreferenceWithoutRestrictingOtherBooks() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["local", "global"].map { makeTestSafeVoice(id: $0, name: $0) }
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: ["local": .init(voiceID: "local", visibilityScope: .bookExclusive, originBookID: book, originRoleID: UUID())]))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(voices), catalog: catalog, bookID: book, existingBindings: [:])
        XCTAssertTrue(plan.isApplicable, "来源角色不同不应排除已登记的声音")
        XCTAssertEqual(Set(plan.proposedBindings.values.map(\.voiceID)), Set(["local", "global"]))
        XCTAssertTrue(catalog.permits(voices[0], bookID: UUID()))
    }

    func testCatalogIdentityMismatchFailsClosedAndChangesRevision() async throws {
        let voice = makeTestSafeVoice(id: "A", name: "A", mode: "clone"), book = UUID()
        let metadata = VoiceAssetMetadata(voiceID: "B", visibilityScope: .bookExclusive, originBookID: book)
        let mismatched = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: ["A": metadata]))
        let correct = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: ["B": metadata]))
        XCTAssertFalse(mismatched.permits(voice, bookID: book))
        XCTAssertNotEqual(mismatched.revision, correct.revision, "目录 key 也是身份事实")
        let url = tempRoot.appendingPathComponent("mismatched.json")
        let data = try JSONEncoder().encode(mismatched.state)
        try data.write(to: url)
        let loaded = await VoiceCatalogStore(storageURL: url).refresh()
        XCTAssertEqual(loaded.loadState, .unreadable)
        XCTAssertFalse(loaded.permits(voice, bookID: book))
        XCTAssertEqual(try Data(contentsOf: url), data, "拒绝读取不能覆盖未知记录")
    }

    func testUnsupportedCandidateParameterExplainsExclusionWithoutRiskConsent() throws {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeTestSafeVoice(id: "unsupported", name: "未声明参数"))) as? [String: Any])
        object["operations"] = ["http_speech": ["parameters": ["speed": ["status": "unknown"]]]]
        let voice = try JSONDecoder().decode(SafeVoiceEntry.self, from: JSONSerialization.data(withJSONObject: object))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice, makeTestSafeVoice(id: "ready", name: "可用")]), catalog: .init(), bookID: book, existingBindings: [:])
        XCTAssertTrue(plan.isApplicable)
        XCTAssertTrue(plan.issues.contains { $0.code == .unsupportedRenderParameter && $0.voiceIDs == [voice.id] })
        XCTAssertTrue(plan.requiredAcknowledgements.isEmpty, "未采用候选的排除说明不应要求接受共享风险")
    }

    func testInferredLeadRolesDoNotBlockAutomaticCastingOfFiftyFourCharacters() {
        let book = UUID()
        var (roles, annotations) = p0Roles(bookID: book, count: 54)
        for index in 1..<8 { roles[index].isMajor = true }
        let voices = (0..<2).map { makeTestSafeVoice(id: "auto-\($0)", name: "声音\($0)") }

        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: annotations,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: [:])

        XCTAssertTrue(plan.isApplicable, "推断主角不应被当成人工独占要求：\(plan.issues)")
        XCTAssertEqual(plan.proposedBindings.count, 54)
        XCTAssertEqual(plan.narratorVoiceCount, 1)
        XCTAssertEqual(plan.sharedVoiceCount, 1)
        XCTAssertEqual(plan.proposedPolicies[roles[0].id]?.sharingPolicy, .exclusive)
        XCTAssertTrue(roles.dropFirst().allSatisfy { plan.proposedPolicies[$0.id]?.sharingPolicy == .sharedMinor })
    }

    func testAutomaticCastingStillHonorsExplicitExclusivePolicy() {
        let book = UUID()
        var (roles, annotations) = p0Roles(bookID: book, count: 54)
        roles[1].voicePolicy = .init(sharingPolicy: .exclusive, bindingOrigin: .manual, isLocked: true)
        let voices = (0..<2).map { makeTestSafeVoice(id: "explicit-\($0)", name: "声音\($0)") }

        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: annotations,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: [:])

        XCTAssertFalse(plan.isApplicable)
        XCTAssertTrue(plan.issues.contains { $0.code == .insufficientVoiceCapacity })
        XCTAssertEqual(plan.proposedPolicies[roles[1].id], roles[1].voicePolicy)
        XCTAssertTrue(plan.proposedBindings.isEmpty, "不能为通过一键配声而放宽人工独占")
    }

    func testMissingVoiceMessageOffersOneClickInsteadOfListingEveryCharacter() {
        let names = (0..<54).map { "角色\($0)" }
        let message = AudiobookCastError.missingVoiceBindings(unboundRoleNames: names).localizedDescription
        XCTAssertTrue(message.contains("54"))
        XCTAssertTrue(message.contains("一键智能配声"))
        XCTAssertFalse(message.contains(names.last!))
    }

    func testCastingCapacityIncludesNarrator() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 12)
        for count in [0, 1, 2, 3, 5, 6] {
            let voices = (0..<count).map { makeTestSafeVoice(id: "voice-\($0)", name: "声音\($0)") }
            let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
                snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: [:])
            XCTAssertEqual(plan.isApplicable, count >= 2, "M=\(count), \(plan.issues)")
            XCTAssertLessThanOrEqual(plan.narratorVoiceCount + plan.exclusiveVoiceCount + plan.sharedVoiceCount, count)
            if count == 6 { XCTAssertEqual(plan.exclusiveVoiceCount, 0); XCTAssertEqual(plan.sharedVoiceCount, 5) }
            if count == 2 { XCTAssertEqual(plan.exclusiveVoiceCount, 0); XCTAssertEqual(plan.sharedVoiceCount, 1) }
        }
        let small = AudiobookCastRegistry.recommendVoiceBindings(characters: Array(roles.prefix(2)), annotations: Array(anns.prefix(2)),
            snapshot: p0Snapshot((0..<6).map { makeTestSafeVoice(id: "v\($0)", name: "v\($0)") }), catalog: .init(), bookID: book, existingBindings: [:])
        XCTAssertTrue(small.isApplicable)
        XCTAssertEqual(small.sharedVoiceCount, 0)
    }

    func testExclusiveMatchingDoesNotConsumeAnotherRolesOnlyCandidate() throws {
        let a = UUID(), b = UUID()
        let match = try AudiobookCastRegistry.maximumExclusiveMatching(roleIDs: [a, b], candidates: [a: ["a", "b"], b: ["a"]])
        XCTAssertEqual(match[a], "b")
        XCTAssertEqual(match[b], "a")
        XCTAssertThrowsError(try AudiobookCastRegistry.maximumExclusiveMatching(roleIDs: [a, b], candidates: [a: ["a"], b: ["a"]]))
        XCTAssertThrowsError(try AudiobookCastRegistry.maximumExclusiveMatching(roleIDs: [a], candidates: [a: ["a"]], visitBudget: 0))
    }

    func testMatchingBudgetExhaustionIsNotReportedAsInfeasible() {
        let role = UUID()
        XCTAssertThrowsError(try AudiobookCastRegistry.maximumExclusiveMatching(roleIDs: [role], candidates: [role: ["a"]], visitBudget: 0)) { error in
            XCTAssertEqual(error as? AudiobookCastRegistry.ExclusiveMatchingError, .budgetExceeded)
        }
    }

    func testLockedDuplicateReturnsIssueWithoutDemotion() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voice = makeTestSafeVoice(id: "one", name: "one")
        let bindings = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, AudiobookVoiceBinding(roleID: $0.id, voiceID: voice.id,
            voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "a", count: 40))) })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns, snapshot: p0Snapshot([voice]),
            catalog: .init(), bookID: book, existingBindings: bindings)
        XCTAssertTrue(plan.issues.contains { $0.code == .lockedBindingConflict && $0.isBlocking })
        XCTAssertEqual(plan.proposedBindings, bindings)
        XCTAssertFalse(plan.isApplicable)
    }

    func testEngineRevisionChangeReconfirmsLockedVoiceWithoutReSelection() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }
        let stale = Dictionary(uniqueKeysWithValues: roles.indices.map { index -> (UUID, AudiobookVoiceBinding) in
            let role = roles[index], voice = voices[index]
            return (role.id, AudiobookVoiceBinding(roleID: role.id, voiceID: voice.id,
                voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "b", count: 40)))
        })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: stale)
        XCTAssertFalse(plan.issues.contains { $0.code == .voiceIdentityUnknown }, "同一声音只换了引擎版本，不该要求重选")
        let reconfirmation = try? XCTUnwrap(plan.issues.first { $0.code == .castRevisionChanged })
        XCTAssertEqual(reconfirmation?.isBlocking, false)
        XCTAssertEqual(reconfirmation?.severity, .warning)
        XCTAssertEqual(Set(reconfirmation?.roleIDs ?? []), Set(roles.map(\.id)))
        XCTAssertTrue(plan.isApplicable)
        XCTAssertEqual(plan.affectedRoleIDs, Set(roles.map(\.id)), "沿用原声音也要落库，才能固定新的引擎版本")
        for index in roles.indices {
            let role = roles[index], voice = voices[index]
            XCTAssertEqual(plan.proposedBindings[role.id]?.voiceID, voice.id, "不能替用户换声音")
            XCTAssertEqual(plan.proposedBindings[role.id]?.modelRevision, String(repeating: "a", count: 40))
            XCTAssertEqual(plan.proposedBindings[role.id]?.voiceRevision, voice.voiceRevision)
        }
    }

    func testChangedVoiceRevisionStillNeedsReSelection() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }
        let stale = Dictionary(uniqueKeysWithValues: roles.indices.map { index -> (UUID, AudiobookVoiceBinding) in
            let role = roles[index], voice = voices[index]
            return (role.id, AudiobookVoiceBinding(roleID: role.id, voiceID: voice.id,
                voiceRevision: "vr_ffffffffffffffffffffffffffffffff", modelRevision: String(repeating: "b", count: 40)))
        })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: stale)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceIdentityUnknown && $0.isBlocking })
        XCTAssertFalse(plan.issues.contains { $0.code == .castRevisionChanged && $0.isBlocking == false })
        XCTAssertFalse(plan.isApplicable)
        XCTAssertEqual(plan.proposedBindings, stale, "声音本身变了，只能由用户重新选")
    }

    func testEngineReconfirmationCannotRestoreVoiceWithoutOrigin() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        let voice = makeTestSafeVoice(id: "old", name: "old")
        let other = makeTestSafeVoice(id: "available", name: "available")
        let stale = [roles[0].id: AudiobookVoiceBinding(roleID: roles[0].id, voiceID: voice.id,
            voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "b", count: 40))]
        let catalog = VoiceCatalogSnapshot(state: .init(metadataByVoiceID: [
            voice.id: .init(voiceID: voice.id, visibilityScope: .bookExclusive)
        ]))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice, other]), catalog: catalog, bookID: book, existingBindings: stale)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceScopeUnavailable && $0.isBlocking })
        XCTAssertFalse(plan.isApplicable)
        XCTAssertEqual(plan.proposedBindings, stale)
        XCTAssertFalse(plan.issues.contains { $0.code == .castRevisionChanged })
    }

    func testMissingVoiceStillNeedsReSelection() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }
        let stale = Dictionary(uniqueKeysWithValues: roles.indices.map { index -> (UUID, AudiobookVoiceBinding) in
            let role = roles[index], voice = voices[index]
            return (role.id, AudiobookVoiceBinding(roleID: role.id, voiceID: voice.id,
                voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "a", count: 40)))
        })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voices[0]]), catalog: .init(), bookID: book, existingBindings: stale)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceIdentityUnknown && $0.isBlocking })
        XCTAssertFalse(plan.issues.contains { $0.code == .castRevisionChanged })
        XCTAssertFalse(plan.isApplicable)
    }

    /// 引擎升级让输出验收失效、但声音与可见范围都没变：可行修复是重新验收，
    /// 所以不能报成「重选声音」，也不能在规划阶段改绑定。
    func testStaleValidationKeepsVoiceAndAsksForRevalidation() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0, productionReady: false) }
        let bounds = Dictionary(uniqueKeysWithValues: roles.indices.map { index -> (UUID, AudiobookVoiceBinding) in
            let role = roles[index], voice = voices[index]
            return (role.id, AudiobookVoiceBinding(roleID: role.id, voiceID: voice.id,
                voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "a", count: 40)))
        })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: bounds)
        XCTAssertFalse(plan.issues.contains { $0.code == .voiceIdentityUnknown }, "声音没变，不该要求重选")
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceNotProductionReady && $0.isBlocking })
        XCTAssertEqual(plan.voicesNeedingValidation, ["v0", "v1"])
        XCTAssertFalse(plan.isApplicable, "验收失效期间不能进入制作")
        XCTAssertEqual(plan.proposedBindings, bounds, "规划阶段不能改绑定")
    }

    /// 声音还在、版本也没变，但已归档：只能重选，重新验收没有意义。
    func testArchivedBoundVoiceAsksForReSelectionNotRevalidation() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        let voice = makeTestSafeVoice(id: "v0", name: "v0")
        let bound = [roles[0].id: AudiobookVoiceBinding(roleID: roles[0].id, voiceID: voice.id,
            voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "a", count: 40))]
        let otherBook = UUID()
        let stored = VoiceCatalogStore.PersistedState(metadataByVoiceID: [
            voice.id: VoiceAssetMetadata(voiceID: voice.id, visibilityScope: .bookExclusive,
                lifecycleState: .archived, originBookID: otherBook)
        ])
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice]), catalog: VoiceCatalogSnapshot(state: stored),
            bookID: book, existingBindings: bound)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceScopeUnavailable && $0.isBlocking })
        XCTAssertTrue(plan.voicesNeedingValidation.isEmpty)
        XCTAssertFalse(plan.isApplicable)
    }

    func testUnvalidatedVoiceWithChangedRevisionStillNeedsReSelection() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 1)
        let voice = makeTestSafeVoice(id: "v0", name: "v0", productionReady: false)
        let stale = [roles[0].id: AudiobookVoiceBinding(roleID: roles[0].id, voiceID: voice.id,
            voiceRevision: "vr_ffffffffffffffffffffffffffffffff", modelRevision: String(repeating: "a", count: 40))]
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot([voice]), catalog: .init(), bookID: book, existingBindings: stale)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceIdentityUnknown && $0.isBlocking })
        XCTAssertTrue(plan.voicesNeedingValidation.isEmpty, "声音本身变了，重新验收旧记录没有意义")
        XCTAssertFalse(plan.isApplicable)
    }

    func testReconfirmationCannotBypassUnsupportedRenderParameters() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 2)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }
        let stale = Dictionary(uniqueKeysWithValues: roles.indices.map { index -> (UUID, AudiobookVoiceBinding) in
            let role = roles[index], voice = voices[index]
            return (role.id, AudiobookVoiceBinding(roleID: role.id, voiceID: voice.id,
                voiceRevision: voice.voiceRevision, modelRevision: String(repeating: "b", count: 40),
                allowedSpeed: 9))
        })
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns,
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: stale)
        XCTAssertTrue(plan.issues.contains { $0.code == .voiceIdentityUnknown && $0.isBlocking })
        XCTAssertFalse(plan.issues.contains { $0.code == .castRevisionChanged })
        XCTAssertFalse(plan.isApplicable)
    }

    func testUnprovenSilentLockedRoleStillReservesItsVoice() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 3)
        let voices = ["v0", "v1"].map { makeTestSafeVoice(id: $0, name: $0) }
        let locked = AudiobookVoiceBinding(roleID: roles[2].id, voiceID: "v0", voiceRevision: voices[0].voiceRevision,
            modelRevision: String(repeating: "a", count: 40))
        let plan = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: Array(anns.prefix(2)),
            snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: [roles[2].id: locked])
        XCTAssertFalse(plan.isApplicable, "零台词不释放用户已锁定的独占声音")
        XCTAssertEqual(plan.proposedBindings[roles[2].id], locked)
    }

    func testNarratorCannotBeChangedToSharedPolicy() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let before = try await store.characters(for: fixture.bookID)
        let narrator = try XCTUnwrap(before.first(where: \.isNarrator))
        do {
            try await makeTestCastController(store: store).setAllowSharedMinorVoice(bookID: fixture.bookID, roleID: narrator.id, allowed: true)
            XCTFail("旁白必须保持独占")
        } catch {}
        let after = try await store.characters(for: fixture.bookID)
        XCTAssertEqual(Self.charactersByID(after), Self.charactersByID(before))
    }

    func testAutomaticVoiceReturnCannotOverwriteBindingAddedDuringCreation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let controller = makeTestCastController(store: store)
        let context = try await controller.makeVoiceReturnContext(bookID: fixture.bookID, roleID: fixture.hero.id)
        let original = AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "voice-hero", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        try await controller.bindVoice(bookID: fixture.bookID, roleID: fixture.hero.id, binding: original)
        let replacement = AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "fault-replacement-hero", voiceRevision: original.voiceRevision, modelRevision: original.modelRevision)
        do {
            try await controller.completeVoiceReturn(context: context, activeBookID: fixture.bookID, binding: replacement, onlyIfUnbound: true)
            XCTFail("自动创建期间的新绑定不能被覆盖")
        } catch { XCTAssertEqual(error as? AudiobookCastError, .staleVoiceReturnContext) }
        let saved = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(saved[fixture.hero.id], original)
    }

    func testGeneratedVoiceReturnFreezesBindingSet() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let controller = makeTestCastController(store: store)
        let context = try await controller.makeVoiceReturnContext(bookID: fixture.bookID, roleID: fixture.hero.id)
        let selected = AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "voice-hero", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        try await controller.bindVoice(bookID: fixture.bookID, roleID: fixture.hero.id, binding: selected)
        let output = AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "fault-replacement-hero", voiceRevision: selected.voiceRevision, modelRevision: selected.modelRevision)
        do {
            try await controller.completeVoiceReturn(context: context, activeBookID: fixture.bookID, binding: output)
            XCTFail("单角色生成也不能覆盖等待期间的人工选择")
        } catch { XCTAssertEqual(error as? AudiobookCastError, .staleVoiceReturnContext) }
        let saved = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(saved[fixture.hero.id], selected)
    }

    func testCastingInputReorderingIsDeterministic() {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 12)
        let voices = (0..<6).map { makeTestSafeVoice(id: "v\($0)", name: "v\($0)") }
        let first = AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns, snapshot: p0Snapshot(voices), catalog: .init(), bookID: book, existingBindings: [:])
        let second = AudiobookCastRegistry.recommendVoiceBindings(characters: roles.reversed(), annotations: anns.reversed(), snapshot: p0Snapshot(voices.reversed()), catalog: .init(), bookID: book, existingBindings: [:])
        XCTAssertEqual(first.proposedBindings, second.proposedBindings)
        XCTAssertEqual(first.inputDigest, second.inputDigest)
        XCTAssertEqual(Set(first.issues.map(\.id)), Set(second.issues.map(\.id)))
    }

    func testNewEnsembleVoicePreservesOriginAndCanBeReusedAcrossBooks() async throws {
        let catalog = VoiceCatalogStore(), book = UUID()
        let metadata = try await catalog.registerArchetypeEnsembleVoice(voiceID: "ensemble", bookID: book, bookTitle: "夹具", archetype: .youngMale)
        XCTAssertEqual(metadata.visibilityScope, .bookExclusive)
        XCTAssertEqual(metadata.originBookID, book)
        let catalogActual20 = await catalog.refresh().permits(makeTestSafeVoice(id: "ensemble", name: "群像", mode: "clone"), bookID: UUID())
        XCTAssertTrue(catalogActual20)
    }

    func testBatchConflictNeverEnablesSharing() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let other = AudiobookCharacter(bookID: fixture.bookID, displayName: "乙", isMajor: true)
        var characters = try await store.characters(for: fixture.bookID); characters.append(other)
        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)
        let controller = makeTestCastController(store: store)
        let bindings = [fixture.hero, other].map { AudiobookVoiceBinding(roleID: $0.id, voiceID: "shared-voice",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)) }
        do {
            _ = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: bindings)
            XCTFail("exclusive conflict must fail the whole batch")
        } catch let error as AudiobookCastError {
            guard case .duplicateVoiceRequiresSharedMinorConsent = error else { return XCTFail("Unexpected: \(error)") }
        }
        let after = try await store.characters(for: fixture.bookID), saved = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(Self.charactersByID(after), Self.charactersByID(characters))
        XCTAssertTrue(saved.isEmpty)
    }

    func testBatchLastMissingRoleOrUnreadyVoiceNeverCommitsEarlierBinding() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let controller = makeTestCastController(store: store)
        let before = try await store.characters(for: fixture.bookID)
        let narrator = try XCTUnwrap(before.first(where: \.isNarrator))
        let first = AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "voice-hero", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
        for missingRole in [true, false] {
            let last = AudiobookVoiceBinding(roleID: missingRole ? UUID() : narrator.id, voiceID: "voice-narrator",
                voiceRevision: first.voiceRevision, modelRevision: first.modelRevision, isSynthesisReady: missingRole)
            do {
                _ = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: [first, last])
                XCTFail("末项非法必须拒绝整批")
            } catch let error as AudiobookCastError {
                if missingRole { XCTAssertEqual(error, .characterNotFound(last.roleID)) }
                else { XCTAssertEqual(error, .voiceNotSynthesisReady(voiceID: last.voiceID)) }
            }
            let saved = try await store.voiceBindings(for: fixture.bookID)
            let roles = try await store.characters(for: fixture.bookID)
            XCTAssertTrue(saved.isEmpty)
            XCTAssertEqual(Self.charactersByID(roles), Self.charactersByID(before))
        }
    }

    func testCancelledCastingAndMatchingBudgetStopWithoutBindings() async throws {
        let book = UUID(), (roles, anns) = p0Roles(bookID: book, count: 12)
        let snapshot = p0Snapshot((0..<6).map { makeTestSafeVoice(id: "v\($0)", name: "v\($0)") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return AudiobookCastRegistry.recommendVoiceBindings(characters: roles, annotations: anns, snapshot: snapshot,
                catalog: .init(), bookID: book, existingBindings: [:])
        }
        let result = await task.value
        XCTAssertFalse(result.isApplicable)
        XCTAssertTrue(result.proposedBindings.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.code == .searchBudgetExceeded })
    }

    func testClonePolicyOmitsCallerSeed() async {
        let role = AudiobookCharacter(bookID: UUID(), displayName: "配角")
        for slot in 0..<8 {
            let policy = AudiobookCastRegistry.computeMicroProsodyAndSeed(
                for: role, archetype: .neutralEnsemble, voiceMode: "clone", slotIndex: slot
            )
            XCTAssertEqual(policy.allowedSpeed, 1)
            XCTAssertNil(policy.callerSeed)
        }
    }

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

    private static func makeTwoChapterBook(store: AudiobookProjectStore, root: URL) async throws -> (
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
        let url = root.appendingPathComponent("two_chapters.txt")
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
            .filter { $0.kind != .formatting }
        let atomsB = try await store.atoms(for: bookID, chapterID: chapterB.id)
            .filter { $0.kind != .formatting }
        let windowA = UUID()
        let windowB = UUID()

        var anns: [AudiobookAnnotation] = []
        var unknownAtom: AudiobookTextAtom?
        for (idx, atom) in atomsA.enumerated() {
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
        for (idx, atom) in atomsB.enumerated() {
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

    private static func executeSQLite(_ sql: String, databaseURL: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let database { sqlite3_close_v2(database) }
            throw NSError(
                domain: "AudiobookCastTests.SQLite",
                code: Int(openResult),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        defer { sqlite3_close_v2(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) }
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "AudiobookCastTests.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message ?? String(cString: sqlite3_errmsg(database))]
            )
        }
    }

    private static func installWriteAbortTrigger(
        table: String,
        keyColumn: String,
        rowID: String,
        triggerPrefix: String,
        marker: String,
        databaseURL: URL
    ) throws {
        let sql = ["INSERT", "UPDATE"].map { operation in
            """
            CREATE TRIGGER \(triggerPrefix)_\(operation.lowercased())
            BEFORE \(operation) ON \(table)
            WHEN NEW.\(keyColumn) = '\(rowID)'
            BEGIN
                SELECT RAISE(ABORT, '\(marker)');
            END;
            """
        }.joined(separator: "\n")
        try executeSQLite(sql, databaseURL: databaseURL)
    }

    private static func removeWriteAbortTrigger(
        triggerPrefix: String,
        databaseURL: URL
    ) throws {
        try executeSQLite(
            "DROP TRIGGER IF EXISTS \(triggerPrefix)_insert; DROP TRIGGER IF EXISTS \(triggerPrefix)_update;",
            databaseURL: databaseURL
        )
    }

    private static func charactersByID(_ characters: [AudiobookCharacter]) -> [UUID: AudiobookCharacter] {
        Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
    }

    private func confirmCoreCastAndAudition(
        store: AudiobookProjectStore,
        controller: AudiobookCastController,
        bookID: UUID,
        narratorID: UUID,
        heroID: UUID
    ) async throws -> AudiobookBook {
        let annotations = try await store.annotations(for: bookID)
        try await store.saveAnnotations(bookID: bookID, annotations: annotations.map { annotation in
            var copy = annotation
            if copy.assignment.isUnknown { copy.assignment = .assigned(roleID: narratorID) }
            return copy
        })
        var book = try await store.book(id: bookID)
        book.analysisState = .allWindowsValidated
        try await store.updateBook(book)
        try await store.saveVoiceBindings(
            bookID: bookID,
            bindings: [
                AudiobookVoiceBinding(
                    roleID: narratorID,
                    voiceID: "fault-fixture-narrator",
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                    modelRevision: String(repeating: "a", count: 40)
                ),
                AudiobookVoiceBinding(
                    roleID: heroID,
                    voiceID: "fault-fixture-hero",
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                    modelRevision: String(repeating: "a", count: 40)
                )
            ]
        )
        let revisionID = try await controller.currentCastRevisionID(for: bookID)
        try await controller.confirmCast(bookID: bookID, revisionID: revisionID)
        let voiceDigest = try await controller.currentVoiceSetDigest(for: bookID)
        try await controller.confirmAudition(bookID: bookID, voiceSetDigest: voiceDigest)
        return try await store.book(id: bookID)
    }

    private func appendSharedMinorPair(
        store: AudiobookProjectStore,
        fixture: (bookID: UUID, chapterA: AudiobookChapter, chapterB: AudiobookChapter, narrator: AudiobookCharacter, hero: AudiobookCharacter, unknownAtomInA: AudiobookTextAtom),
        allowSharedMinorVoice: Bool
    ) async throws -> (AudiobookCharacter, AudiobookCharacter) {
        var explicitTraits = AudiobookVoiceTraits()
        explicitTraits.gender = .init(value: "male", source: .manual, confidence: 1)
        explicitTraits.age = .init(value: "middleAged", source: .manual, confidence: 1)
        let partnerA = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "张掌柜",
            isNarrator: false,
            isMajor: false,
            allowSharedMinorVoice: allowSharedMinorVoice,
            chapterIDs: [fixture.chapterA.id],
            voiceTraitsOverride: explicitTraits
        )
        let partnerB = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "李掌柜",
            isNarrator: false,
            isMajor: false,
            allowSharedMinorVoice: allowSharedMinorVoice,
            chapterIDs: [fixture.chapterA.id],
            voiceTraitsOverride: explicitTraits
        )
        var characters = try await store.characters(for: fixture.bookID)
        characters.append(contentsOf: [partnerA, partnerB])
        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)
        return (partnerA, partnerB)
    }

    func testMergeCharactersRollsBackOnFirstAndLaterAnnotationWriteFailures() async throws {
        try await assertMergeRollbackWhenAnnotationWriteFails(ordinal: 0, rootName: "merge-first-annotation-failure")
        try await assertMergeRollbackWhenAnnotationWriteFails(ordinal: 1, rootName: "merge-late-annotation-failure")
    }

    private func assertMergeRollbackWhenAnnotationWriteFails(ordinal: Int, rootName: String) async throws {
        let libraryRoot = tempRoot.appendingPathComponent(rootName, isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let store = try AudiobookProjectStore(root: libraryRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)

        let target = AudiobookCharacter(
            bookID: fixture.bookID,
            displayName: "周船长",
            aliases: ["老周"],
            evidences: [],
            primaryVoiceTraitSummary: "沉稳低音，语速从容",
            isMajor: false,
            allowSharedMinorVoice: true,
            firstAppearanceRange: .init(lowerBound: 20, upperBound: 35),
            chapterIDs: [fixture.chapterB.id]
        )
        var characters = try await store.characters(for: fixture.bookID)
        characters.append(target)
        try await store.saveCharacters(bookID: fixture.bookID, characters: characters)

        let atomsA = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterA.id)
        let atomsB = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterB.id)
        let sourceAtomIDs = [
            try XCTUnwrap(atomsA.first(where: { $0.kind != .formatting })).id,
            try XCTUnwrap(atomsB.first(where: { $0.kind != .formatting })).id,
        ]
        XCTAssertEqual(Set(sourceAtomIDs).count, 2)

        var annotations = try await store.annotations(for: fixture.bookID)
        for atomID in sourceAtomIDs {
            let index = try XCTUnwrap(annotations.firstIndex(where: { $0.atomID == atomID }))
            annotations[index].assignment = .assigned(roleID: fixture.hero.id)
            annotations[index].userConfirmed = false
            annotations[index].annotationRevision = 4
        }
        try await store.saveAnnotations(
            bookID: fixture.bookID,
            annotations: annotations.filter { Set(sourceAtomIDs).contains($0.atomID) }
        )

        let sourceBinding = AudiobookVoiceBinding(
            roleID: fixture.hero.id,
            voiceID: "test-source-exclusive-voice",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40),
            allowedSpeed: 0.95,
            callerSeed: 71
        )
        let targetBinding = AudiobookVoiceBinding(
            roleID: target.id,
            voiceID: "test-target-exclusive-voice",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40),
            allowedSpeed: 1.05,
            callerSeed: 29
        )
        try await store.saveVoiceBindings(bookID: fixture.bookID, bindings: [sourceBinding, targetBinding])

        // Force the pre-merge role and annotation values into the same Store caches.
        let originalCharacters = try await store.characters(for: fixture.bookID)
        let originalAnnotations = try await store.annotations(for: fixture.bookID)
        let originalBindings = try await store.voiceBindings(for: fixture.bookID)
        let originalSource = try XCTUnwrap(originalCharacters.first(where: { $0.id == fixture.hero.id }))
        let originalTarget = try XCTUnwrap(originalCharacters.first(where: { $0.id == target.id }))
        let sourceAssignments = originalAnnotations
            .filter { $0.assignment.roleID == fixture.hero.id }
            .sorted { $0.sourceRange < $1.sourceRange }
        XCTAssertGreaterThanOrEqual(sourceAssignments.count, 2, "故障必须发生在至少一条 source 标注已尝试写入之后")
        XCTAssertEqual(originalBindings[fixture.hero.id], sourceBinding)
        XCTAssertEqual(originalBindings[target.id], targetBinding)

        let generationBeforeFailure = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: fixture.hero.id
        ).generation

        // 第一条或较晚一条 source 标注触发 ABORT；后者能够暴露逐条提交造成的部分重派。
        let failingAtomID = sourceAssignments[ordinal].atomID.uuidString
        let triggerSQL = """
        CREATE TRIGGER inject_late_merge_annotation_insert
        BEFORE INSERT ON annotations
        WHEN NEW.atom_id = '\(failingAtomID)'
        BEGIN
            SELECT RAISE(ABORT, 'injected_merge_annotation_failure');
        END;
        CREATE TRIGGER inject_late_merge_annotation_update
        BEFORE UPDATE ON annotations
        WHEN NEW.atom_id = '\(failingAtomID)'
        BEGIN
            SELECT RAISE(ABORT, 'injected_merge_annotation_failure');
        END;
        """
        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3", isDirectory: false)
        try Self.executeSQLite(triggerSQL, databaseURL: databaseURL)
        defer {
            try? Self.executeSQLite(
                "DROP TRIGGER IF EXISTS inject_late_merge_annotation_insert; DROP TRIGGER IF EXISTS inject_late_merge_annotation_update;",
                databaseURL: databaseURL
            )
        }

        var injectedFailure: String?
        do {
            _ = try await controller.mergeCharacters(
                bookID: fixture.bookID,
                sourceRoleID: fixture.hero.id,
                intoTargetRoleID: target.id
            )
            XCTFail("SQLite 注入的后写入故障应使角色合并失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(
            injectedFailure?.contains("injected_merge_annotation_failure") == true,
            "必须确认数据库触发器命中，实际错误：\(injectedFailure ?? "<none>")"
        )

        try Self.executeSQLite(
            "DROP TRIGGER IF EXISTS inject_late_merge_annotation_insert; DROP TRIGGER IF EXISTS inject_late_merge_annotation_update;",
            databaseURL: databaseURL
        )

        // 同一 Store 的角色缓存刷新后仍应完整；标注缓存与 SQLite 重开读取也都必须维持原样。
        let sameStoreCharacters = try await store.characters(for: fixture.bookID)
        let sameStoreAnnotations = try await store.annotations(for: fixture.bookID)
        let sameStoreBindings = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: sameStoreCharacters.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: originalCharacters.map { ($0.id, $0) })
        )
        XCTAssertEqual(sameStoreCharacters.first(where: { $0.id == fixture.hero.id }), originalSource)
        XCTAssertEqual(sameStoreCharacters.first(where: { $0.id == target.id }), originalTarget)
        XCTAssertEqual(sameStoreAnnotations, originalAnnotations)
        XCTAssertEqual(sameStoreBindings, originalBindings)

        let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
        let reopenedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        let reopenedAnnotations = try await reopenedStore.annotations(for: fixture.bookID)
        let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: reopenedCharacters.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: originalCharacters.map { ($0.id, $0) })
        )
        XCTAssertEqual(reopenedCharacters.first(where: { $0.id == fixture.hero.id }), originalSource)
        XCTAssertEqual(reopenedCharacters.first(where: { $0.id == target.id }), originalTarget)
        XCTAssertEqual(reopenedAnnotations, originalAnnotations)
        XCTAssertEqual(reopenedBindings, originalBindings)

        let generationAfterFailure = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: fixture.hero.id
        ).generation
        XCTAssertEqual(generationAfterFailure, generationBeforeFailure, "失败的合并不得使音色往返上下文过期")

        let retryPreview: AudiobookCastImpactPreview
        do {
            retryPreview = try await controller.mergeCharacters(
                bookID: fixture.bookID,
                sourceRoleID: fixture.hero.id,
                intoTargetRoleID: target.id
            )
        } catch {
            XCTFail("清除故障触发器后应能重试合并，实际错误：\(error)")
            return
        }
        XCTAssertEqual(retryPreview.affectedQuotesCount, sourceAssignments.count)

        let mergedCharacters = try await store.characters(for: fixture.bookID)
        let mergedAnnotations = try await store.annotations(for: fixture.bookID)
        let mergedBindings = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertNil(mergedCharacters.first(where: { $0.id == fixture.hero.id }))
        let mergedTarget = try XCTUnwrap(mergedCharacters.first(where: { $0.id == target.id }))
        XCTAssertEqual(mergedTarget.displayName, originalTarget.displayName)
        XCTAssertEqual(mergedTarget.isMajor, originalTarget.isMajor)
        XCTAssertEqual(mergedTarget.allowSharedMinorVoice, originalTarget.allowSharedMinorVoice)
        XCTAssertTrue(mergedTarget.aliases.contains(originalSource.displayName))
        XCTAssertEqual(mergedBindings[target.id], targetBinding)
        XCTAssertNil(mergedBindings[fixture.hero.id])

        let expectedMergedAnnotations = originalAnnotations.map { annotation -> AudiobookAnnotation in
            guard annotation.assignment.roleID == fixture.hero.id else { return annotation }
            var reassigned = annotation
            reassigned.assignment = .assigned(roleID: target.id)
            reassigned.userConfirmed = true
            reassigned.annotationRevision += 1
            return reassigned
        }
        XCTAssertEqual(mergedAnnotations, expectedMergedAnnotations)

        let generationAfterRetry = try await controller.makeVoiceReturnContext(
            bookID: fixture.bookID,
            roleID: target.id
        ).generation
        XCTAssertEqual(generationAfterRetry, generationBeforeFailure + 1, "成功重试只应推进一次角色代次")
    }

    func testSplitCharacterFaultRollsBackAtFirstAndLaterAnnotationWrites() async throws {
        for (ordinal, rootName) in [
            (0, "split-first-annotation-failure"),
            (1, "split-late-annotation-failure")
        ] {
            let libraryRoot = tempRoot.appendingPathComponent(rootName, isDirectory: true)
            try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            let store = try AudiobookProjectStore(root: libraryRoot)
            let controller = makeTestCastController(store: store)
            let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)

            let atomsA = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterA.id)
            let atomsB = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterB.id)
            let selectedAtomIDs = [
                try XCTUnwrap(atomsA.first(where: { $0.kind != .formatting })).id,
                try XCTUnwrap(atomsB.first(where: { $0.kind != .formatting })).id
            ]
            var annotations = try await store.annotations(for: fixture.bookID)
            for atomID in selectedAtomIDs {
                let index = try XCTUnwrap(annotations.firstIndex(where: { $0.atomID == atomID }))
                annotations[index].assignment = .assigned(roleID: fixture.hero.id)
                annotations[index].userConfirmed = false
                annotations[index].annotationRevision = 7
            }
            try await store.saveAnnotations(
                bookID: fixture.bookID,
                annotations: annotations.filter { Set(selectedAtomIDs).contains($0.atomID) }
            )
            try await store.saveVoiceBindings(
                bookID: fixture.bookID,
                bindings: [
                    AudiobookVoiceBinding(roleID: fixture.narrator.id, voiceID: "split-narrator", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40)),
                    AudiobookVoiceBinding(roleID: fixture.hero.id, voiceID: "split-hero", voiceRevision: "vr_0123456789abcdef0123456789abcdef", modelRevision: String(repeating: "a", count: 40))
                ]
            )

            // 预热角色、标注与绑定读取，再记录故障前状态。
            let originalCharacters = try await store.characters(for: fixture.bookID)
            let originalAnnotations = try await store.annotations(for: fixture.bookID)
            let originalBindings = try await store.voiceBindings(for: fixture.bookID)
            let generationBefore = try await controller.makeVoiceReturnContext(
                bookID: fixture.bookID,
                roleID: fixture.hero.id
            ).generation
            let marker = "injected_split_annotation_failure_\(ordinal)"
            let triggerPrefix = "inject_split_\(ordinal)"
            let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3")
            try Self.installWriteAbortTrigger(
                table: "annotations",
                keyColumn: "atom_id",
                rowID: selectedAtomIDs[ordinal].uuidString,
                triggerPrefix: triggerPrefix,
                marker: marker,
                databaseURL: databaseURL
            )
            defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

            var injectedFailure: String?
            do {
                _ = try await controller.splitCharacter(
                    bookID: fixture.bookID,
                    sourceRoleID: fixture.hero.id,
                    newDisplayName: "分拆角色",
                    atomIDs: selectedAtomIDs
                )
                XCTFail("标注写入故障应使拆分失败")
            } catch {
                injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
            }
            XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中 SQLite 故障点，实际错误：\(injectedFailure ?? "<none>")")
            try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

            let sameStoreCharacters = try await store.characters(for: fixture.bookID)
            let sameStoreAnnotations = try await store.annotations(for: fixture.bookID)
            let sameStoreBindings = try await store.voiceBindings(for: fixture.bookID)
            let sameStoreIntact = Self.charactersByID(sameStoreCharacters) == Self.charactersByID(originalCharacters)
                && sameStoreAnnotations == originalAnnotations
                && sameStoreBindings == originalBindings
            XCTAssertEqual(Self.charactersByID(sameStoreCharacters), Self.charactersByID(originalCharacters))
            XCTAssertEqual(sameStoreAnnotations, originalAnnotations)
            XCTAssertEqual(sameStoreBindings, originalBindings)

            let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
            let reopenedCharacters = try await reopenedStore.characters(for: fixture.bookID)
            let reopenedAnnotations = try await reopenedStore.annotations(for: fixture.bookID)
            let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
            let reopenedIntact = Self.charactersByID(reopenedCharacters) == Self.charactersByID(originalCharacters)
                && reopenedAnnotations == originalAnnotations
                && reopenedBindings == originalBindings
            XCTAssertEqual(Self.charactersByID(reopenedCharacters), Self.charactersByID(originalCharacters))
            XCTAssertEqual(reopenedAnnotations, originalAnnotations)
            XCTAssertEqual(reopenedBindings, originalBindings)

            let generationAfterFailure = try await controller.makeVoiceReturnContext(
                bookID: fixture.bookID,
                roleID: fixture.hero.id
            ).generation
            XCTAssertEqual(generationAfterFailure, generationBefore, "拆分失败不得推进 generation")

            var noUndoWasAdded = false
            do {
                try await controller.undoLastAssignment(bookID: fixture.bookID)
                XCTFail("失败的拆分不得新增可撤销改派")
            } catch let error as AudiobookCastError {
                noUndoWasAdded = error == .nothingToUndo
                XCTAssertEqual(error, .nothingToUndo)
            }
            XCTAssertTrue(noUndoWasAdded, "失败拆分不应压入 undo 历史")
            guard sameStoreIntact, reopenedIntact, generationAfterFailure == generationBefore, noUndoWasAdded else {
                continue
            }

            let splitRole = try await controller.splitCharacter(
                bookID: fixture.bookID,
                sourceRoleID: fixture.hero.id,
                newDisplayName: "分拆角色",
                atomIDs: selectedAtomIDs
            )
            let splitCharacters = try await store.characters(for: fixture.bookID)
            let splitAnnotations = try await store.annotations(for: fixture.bookID)
            XCTAssertEqual(splitCharacters.count, originalCharacters.count + 1)
            XCTAssertEqual(
                Set(splitCharacters.map(\.id)),
                Set(originalCharacters.map(\.id)).union([splitRole.id]),
                "拆分只应新增一个角色身份；现有角色仍可补齐声音画像"
            )
            XCTAssertTrue(splitCharacters.contains(where: { $0.id == splitRole.id }))
            XCTAssertEqual(splitRole.displayName, "分拆角色")
            for atomID in selectedAtomIDs {
                let before = try XCTUnwrap(originalAnnotations.first(where: { $0.atomID == atomID }))
                var expected = before
                expected.assignment = .assigned(roleID: splitRole.id)
                expected.userConfirmed = true
                expected.annotationRevision += 1
                XCTAssertEqual(splitAnnotations.first(where: { $0.atomID == atomID }), expected)
            }
            let generationAfterRetry = try await controller.makeVoiceReturnContext(
                bookID: fixture.bookID,
                roleID: splitRole.id
            ).generation
            XCTAssertEqual(generationAfterRetry, generationBefore + 1, "成功重试应只推进一次 generation")
            let bindingsAfterRetry = try await store.voiceBindings(for: fixture.bookID)
            XCTAssertEqual(bindingsAfterRetry, originalBindings, "拆分不应更换原角色的声音")

            try await controller.undoLastAssignment(bookID: fixture.bookID)
            let annotationsAfterUndo = try await store.annotations(for: fixture.bookID)
            XCTAssertEqual(annotationsAfterUndo, originalAnnotations, "成功重试后的改派应可撤销")
        }
    }

    func testAssignRoleFaultDoesNotAddUndoHistory() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let atomsA = try await store.atoms(for: fixture.bookID, chapterID: fixture.chapterA.id)
        let firstAtomID = fixture.unknownAtomInA.id
        let failingAtomID = try XCTUnwrap(atomsA.first(where: { $0.kind != .formatting && $0.id != firstAtomID })).id
        let originalAnnotations = try await store.annotations(for: fixture.bookID)

        try await controller.assignRole(bookID: fixture.bookID, atomIDs: [firstAtomID], roleID: fixture.hero.id)
        let stateAfterFirstAssignment = try await store.annotations(for: fixture.bookID)

        let marker = "injected_assign_annotation_failure"
        let triggerPrefix = "inject_assign_fault"
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "annotations",
            keyColumn: "atom_id",
            rowID: failingAtomID.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            try await controller.assignRole(bookID: fixture.bookID, atomIDs: [failingAtomID], roleID: fixture.narrator.id)
            XCTFail("注入的标注写入故障应使改派失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中 SQLite 故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let afterFailure = try await store.annotations(for: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedAfterFailure = try await reopenedStore.annotations(for: fixture.bookID)
        XCTAssertEqual(afterFailure, stateAfterFirstAssignment)
        XCTAssertEqual(reopenedAfterFailure, stateAfterFirstAssignment)

        try await controller.undoLastAssignment(bookID: fixture.bookID)
        let afterOneUndo = try await store.annotations(for: fixture.bookID)
        XCTAssertEqual(afterOneUndo, originalAnnotations, "一次撤销应回滚成功的第一次改派")
        var secondUndoWasEmpty = false
        do {
            try await controller.undoLastAssignment(bookID: fixture.bookID)
            XCTFail("失败的第二次改派不应留下额外 undo 项")
        } catch let error as AudiobookCastError {
            secondUndoWasEmpty = error == .nothingToUndo
            XCTAssertEqual(error, .nothingToUndo)
        }
        XCTAssertTrue(secondUndoWasEmpty)
    }

    func testConcurrentUndosRestoreEverySuccessfulAssignment() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let originalAnnotations = try await store.annotations(for: fixture.bookID)
        let bookID = fixture.bookID
        for index in 0..<8 {
            try await controller.assignRole(
                bookID: bookID,
                atomIDs: [fixture.unknownAtomInA.id],
                roleID: index.isMultiple(of: 2) ? fixture.hero.id : fixture.narrator.id
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await controller.undoLastAssignment(bookID: bookID) }
            }
            try await group.waitForAll()
        }
        let restoredAnnotations = try await store.annotations(for: bookID)
        XCTAssertEqual(restoredAnnotations, originalAnnotations)
        do {
            try await controller.undoLastAssignment(bookID: bookID)
            XCTFail("每个已提交的改派应只被撤销一次")
        } catch let error as AudiobookCastError {
            XCTAssertEqual(error, .nothingToUndo)
        }
    }

    func testUndoAssignmentFaultDoesNotConsumeUndoHistory() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let originalAnnotations = try await store.annotations(for: fixture.bookID)
        try await controller.assignRole(
            bookID: fixture.bookID,
            atomIDs: [fixture.unknownAtomInA.id],
            roleID: fixture.hero.id
        )
        let assignedAnnotations = try await store.annotations(for: fixture.bookID)

        let marker = "injected_undo_annotation_failure"
        let triggerPrefix = "inject_undo_fault"
        let databaseURL = tempRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "annotations",
            keyColumn: "atom_id",
            rowID: fixture.unknownAtomInA.id.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            try await controller.undoLastAssignment(bookID: fixture.bookID)
            XCTFail("注入的撤销保存故障应使撤销失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中 SQLite 故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let afterFailure = try await store.annotations(for: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: tempRoot)
        let reopenedAfterFailure = try await reopenedStore.annotations(for: fixture.bookID)
        XCTAssertEqual(afterFailure, assignedAnnotations)
        XCTAssertEqual(reopenedAfterFailure, assignedAnnotations)

        try await controller.undoLastAssignment(bookID: fixture.bookID)
        let afterRetry = try await store.annotations(for: fixture.bookID)
        XCTAssertEqual(afterRetry, originalAnnotations, "清除故障后应能重试撤销并恢复原标注")
    }

    func testBindVoiceBookInvalidationFaultPreservesBindingAndRetry() async throws {
        let libraryRoot = tempRoot.appendingPathComponent("bind-voice-book-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let store = try AudiobookProjectStore(root: libraryRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)
        let originalBook = try await confirmCoreCastAndAudition(
            store: store,
            controller: controller,
            bookID: fixture.bookID,
            narratorID: fixture.narrator.id,
            heroID: fixture.hero.id
        )
        let originalBindings = try await store.voiceBindings(for: fixture.bookID)
        let originalHeroBinding = try XCTUnwrap(originalBindings[fixture.hero.id])
        let replacement = AudiobookVoiceBinding(
            roleID: fixture.hero.id,
            voiceID: "fault-replacement-hero",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40)
        )
        let marker = "injected_bind_voice_book_failure"
        let triggerPrefix = "inject_bind_voice_book_fault"
        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "books",
            keyColumn: "id",
            rowID: fixture.bookID.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            try await controller.bindVoice(bookID: fixture.bookID, roleID: fixture.hero.id, binding: replacement)
            XCTFail("书籍试听确认失效化写入故障应使换绑失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中 SQLite 故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let bindingsAfterFailure = try await store.voiceBindings(for: fixture.bookID)
        let bookAfterFailure = try await store.book(id: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
        let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        let reopenedBook = try await reopenedStore.book(id: fixture.bookID)
        let stateIntact = bindingsAfterFailure == originalBindings
            && bookAfterFailure == originalBook
            && reopenedBindings == originalBindings
            && reopenedBook == originalBook
        XCTAssertEqual(bindingsAfterFailure, originalBindings)
        XCTAssertEqual(bindingsAfterFailure[fixture.hero.id], originalHeroBinding)
        XCTAssertEqual(bookAfterFailure, originalBook)
        XCTAssertEqual(reopenedBindings, originalBindings)
        XCTAssertEqual(reopenedBook, originalBook)
        guard stateIntact else { return }

        try await controller.bindVoice(bookID: fixture.bookID, roleID: fixture.hero.id, binding: replacement)
        let retryBindings = try await store.voiceBindings(for: fixture.bookID)
        let retryBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(retryBindings[fixture.hero.id], replacement)
        XCTAssertNil(retryBook.confirmedAuditionVoiceSetDigest)

        let newDigest = try await controller.currentVoiceSetDigest(for: fixture.bookID)
        try await controller.confirmAudition(bookID: fixture.bookID, voiceSetDigest: newDigest)
        let confirmedBook = try await store.book(id: fixture.bookID)
        try await controller.bindVoice(bookID: fixture.bookID, roleID: fixture.hero.id, binding: replacement)
        let sameBindingBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(sameBindingBook, confirmedBook, "重复保存完全相同的绑定应保留试听确认")
    }

    func testBindVoicesBatchSecondBindingFaultPreservesStateAndRetry() async throws {
        let libraryRoot = tempRoot.appendingPathComponent("batch-binding-second-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let store = try AudiobookProjectStore(root: libraryRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)
        let (partnerA, partnerB) = try await appendSharedMinorPair(
            store: store,
            fixture: fixture,
            allowSharedMinorVoice: true
        )
        let originalBook = try await confirmCoreCastAndAudition(
            store: store,
            controller: controller,
            bookID: fixture.bookID,
            narratorID: fixture.narrator.id,
            heroID: fixture.hero.id
        )
        let originalCharacters = try await store.characters(for: fixture.bookID)
        let originalBindings = try await store.voiceBindings(for: fixture.bookID)
        let submitted = [partnerA, partnerB].map {
            AudiobookVoiceBinding(
                roleID: $0.id,
                voiceID: "fault-shared-pool-voice",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        }
        let marker = "injected_second_voice_binding_failure"
        let triggerPrefix = "inject_batch_second_binding_fault"
        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "voice_bindings",
            keyColumn: "role_id",
            rowID: partnerB.id.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            _ = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: submitted)
            XCTFail("第二条绑定写入故障应使批量换绑失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中第二条绑定的 SQLite 故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let charactersAfterFailure = try await store.characters(for: fixture.bookID)
        let bindingsAfterFailure = try await store.voiceBindings(for: fixture.bookID)
        let bookAfterFailure = try await store.book(id: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
        let reopenedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        let reopenedBook = try await reopenedStore.book(id: fixture.bookID)
        let stateIntact = Self.charactersByID(charactersAfterFailure) == Self.charactersByID(originalCharacters)
            && bindingsAfterFailure == originalBindings
            && bookAfterFailure == originalBook
            && Self.charactersByID(reopenedCharacters) == Self.charactersByID(originalCharacters)
            && reopenedBindings == originalBindings
            && reopenedBook == originalBook
        XCTAssertEqual(Self.charactersByID(charactersAfterFailure), Self.charactersByID(originalCharacters))
        XCTAssertEqual(bindingsAfterFailure, originalBindings)
        XCTAssertTrue(try XCTUnwrap(charactersAfterFailure.first(where: { $0.id == partnerA.id })).allowSharedMinorVoice)
        XCTAssertTrue(try XCTUnwrap(charactersAfterFailure.first(where: { $0.id == partnerB.id })).allowSharedMinorVoice)
        XCTAssertEqual(bookAfterFailure, originalBook)
        XCTAssertEqual(Self.charactersByID(reopenedCharacters), Self.charactersByID(originalCharacters))
        XCTAssertEqual(reopenedBindings, originalBindings)
        XCTAssertEqual(reopenedBook, originalBook)
        guard stateIntact else { return }

        let retryCount = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: submitted)
        let retryCharacters = try await store.characters(for: fixture.bookID)
        let retryBindings = try await store.voiceBindings(for: fixture.bookID)
        let retryBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(retryCount, 2)
        XCTAssertTrue(try XCTUnwrap(retryCharacters.first(where: { $0.id == partnerA.id })).allowSharedMinorVoice)
        XCTAssertTrue(try XCTUnwrap(retryCharacters.first(where: { $0.id == partnerB.id })).allowSharedMinorVoice)
        XCTAssertEqual(retryBindings[partnerA.id], submitted[0])
        XCTAssertEqual(retryBindings[partnerB.id], submitted[1])
        XCTAssertNil(retryBook.confirmedAuditionVoiceSetDigest)
    }

    func testBindVoicesBatchBookInvalidationFaultPreservesStateAndRetry() async throws {
        let libraryRoot = tempRoot.appendingPathComponent("batch-book-invalidation-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let store = try AudiobookProjectStore(root: libraryRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)
        let (partnerA, partnerB) = try await appendSharedMinorPair(
            store: store,
            fixture: fixture,
            allowSharedMinorVoice: true
        )
        let originalBook = try await confirmCoreCastAndAudition(
            store: store,
            controller: controller,
            bookID: fixture.bookID,
            narratorID: fixture.narrator.id,
            heroID: fixture.hero.id
        )
        let originalCharacters = try await store.characters(for: fixture.bookID)
        let originalBindings = try await store.voiceBindings(for: fixture.bookID)
        let submitted = [partnerA, partnerB].map {
            AudiobookVoiceBinding(
                roleID: $0.id,
                voiceID: "fault-shared-pool-voice",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        }
        let marker = "injected_batch_book_invalidation_failure"
        let triggerPrefix = "inject_batch_book_fault"
        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "books",
            keyColumn: "id",
            rowID: fixture.bookID.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            _ = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: submitted)
            XCTFail("书籍确认失效化故障应使批量换绑失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中书籍更新故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let charactersAfterFailure = try await store.characters(for: fixture.bookID)
        let bindingsAfterFailure = try await store.voiceBindings(for: fixture.bookID)
        let bookAfterFailure = try await store.book(id: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
        let reopenedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        let reopenedBook = try await reopenedStore.book(id: fixture.bookID)
        let stateIntact = Self.charactersByID(charactersAfterFailure) == Self.charactersByID(originalCharacters)
            && bindingsAfterFailure == originalBindings
            && bookAfterFailure == originalBook
            && Self.charactersByID(reopenedCharacters) == Self.charactersByID(originalCharacters)
            && reopenedBindings == originalBindings
            && reopenedBook == originalBook
        XCTAssertEqual(Self.charactersByID(charactersAfterFailure), Self.charactersByID(originalCharacters))
        XCTAssertEqual(bindingsAfterFailure, originalBindings)
        XCTAssertTrue(try XCTUnwrap(charactersAfterFailure.first(where: { $0.id == partnerA.id })).allowSharedMinorVoice)
        XCTAssertTrue(try XCTUnwrap(charactersAfterFailure.first(where: { $0.id == partnerB.id })).allowSharedMinorVoice)
        XCTAssertEqual(bookAfterFailure, originalBook)
        XCTAssertEqual(Self.charactersByID(reopenedCharacters), Self.charactersByID(originalCharacters))
        XCTAssertEqual(reopenedBindings, originalBindings)
        XCTAssertEqual(reopenedBook, originalBook)
        guard stateIntact else { return }

        let retryCount = try await controller.bindVoicesBatch(bookID: fixture.bookID, bindings: submitted)
        let retryCharacters = try await store.characters(for: fixture.bookID)
        let retryBindings = try await store.voiceBindings(for: fixture.bookID)
        let retryBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(retryCount, 2)
        XCTAssertTrue(try XCTUnwrap(retryCharacters.first(where: { $0.id == partnerA.id })).allowSharedMinorVoice)
        XCTAssertTrue(try XCTUnwrap(retryCharacters.first(where: { $0.id == partnerB.id })).allowSharedMinorVoice)
        XCTAssertEqual(retryBindings[partnerA.id], submitted[0])
        XCTAssertEqual(retryBindings[partnerB.id], submitted[1])
        XCTAssertNil(retryBook.confirmedAuditionVoiceSetDigest)
    }

    func testBatchBindArchetypeVoiceBookInvalidationFaultPreservesStateAndRetry() async throws {
        let libraryRoot = tempRoot.appendingPathComponent("archetype-book-invalidation-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let store = try AudiobookProjectStore(root: libraryRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: libraryRoot)
        let (partnerA, partnerB) = try await appendSharedMinorPair(
            store: store,
            fixture: fixture,
            allowSharedMinorVoice: true
        )
        let charactersBefore = try await store.characters(for: fixture.bookID)
        XCTAssertEqual(partnerA.inferredVoiceArchetype(peers: charactersBefore), .matureMale)
        XCTAssertEqual(partnerB.inferredVoiceArchetype(peers: charactersBefore), .matureMale)
        let originalBook = try await confirmCoreCastAndAudition(
            store: store,
            controller: controller,
            bookID: fixture.bookID,
            narratorID: fixture.narrator.id,
            heroID: fixture.hero.id
        )
        let originalCharacters = try await store.characters(for: fixture.bookID)
        let originalBindings = try await store.voiceBindings(for: fixture.bookID)
        let voice = makeTestSafeVoice(
            id: "fault-archetype-voice",
            name: "故障注入声部音色",
            styleTags: ["中年", "男声"]
        )
        let marker = "injected_archetype_book_invalidation_failure"
        let triggerPrefix = "inject_archetype_book_fault"
        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite3")
        try Self.installWriteAbortTrigger(
            table: "books",
            keyColumn: "id",
            rowID: fixture.bookID.uuidString,
            triggerPrefix: triggerPrefix,
            marker: marker,
            databaseURL: databaseURL
        )
        defer { try? Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL) }

        var injectedFailure: String?
        do {
            _ = try await controller.batchBindArchetypeVoice(
                bookID: fixture.bookID,
                archetype: .matureMale,
                voice: voice
            )
            XCTFail("书籍试听确认失效化故障应使声部批量换绑失败")
        } catch {
            injectedFailure = "\(String(describing: error)) \(error.localizedDescription)"
        }
        XCTAssertTrue(injectedFailure?.contains(marker) == true, "必须命中书籍更新故障点，实际错误：\(injectedFailure ?? "<none>")")
        try Self.removeWriteAbortTrigger(triggerPrefix: triggerPrefix, databaseURL: databaseURL)

        let charactersAfterFailure = try await store.characters(for: fixture.bookID)
        let bindingsAfterFailure = try await store.voiceBindings(for: fixture.bookID)
        let bookAfterFailure = try await store.book(id: fixture.bookID)
        let reopenedStore = try AudiobookProjectStore(root: libraryRoot)
        let reopenedCharacters = try await reopenedStore.characters(for: fixture.bookID)
        let reopenedBindings = try await reopenedStore.voiceBindings(for: fixture.bookID)
        let reopenedBook = try await reopenedStore.book(id: fixture.bookID)
        let stateIntact = Self.charactersByID(charactersAfterFailure) == Self.charactersByID(originalCharacters)
            && bindingsAfterFailure == originalBindings
            && bookAfterFailure == originalBook
            && Self.charactersByID(reopenedCharacters) == Self.charactersByID(originalCharacters)
            && reopenedBindings == originalBindings
            && reopenedBook == originalBook
        XCTAssertEqual(Self.charactersByID(charactersAfterFailure), Self.charactersByID(originalCharacters))
        XCTAssertEqual(bindingsAfterFailure, originalBindings)
        XCTAssertEqual(bindingsAfterFailure[fixture.narrator.id], originalBindings[fixture.narrator.id])
        XCTAssertEqual(bindingsAfterFailure[fixture.hero.id], originalBindings[fixture.hero.id])
        XCTAssertEqual(bookAfterFailure, originalBook)
        XCTAssertEqual(Self.charactersByID(reopenedCharacters), Self.charactersByID(originalCharacters))
        XCTAssertEqual(reopenedBindings, originalBindings)
        XCTAssertEqual(reopenedBook, originalBook)
        guard stateIntact else { return }

        let retryCount = try await controller.batchBindArchetypeVoice(
            bookID: fixture.bookID,
            archetype: .matureMale,
            voice: voice
        )
        let retryBindings = try await store.voiceBindings(for: fixture.bookID)
        let retryBook = try await store.book(id: fixture.bookID)
        XCTAssertEqual(retryCount, 2)
        XCTAssertEqual(retryBindings[partnerA.id]?.voiceID, voice.id)
        XCTAssertEqual(retryBindings[partnerB.id]?.voiceID, voice.id)
        XCTAssertEqual(retryBindings[fixture.narrator.id], originalBindings[fixture.narrator.id])
        XCTAssertEqual(retryBindings[fixture.hero.id], originalBindings[fixture.hero.id])
        XCTAssertNil(retryBook.confirmedAuditionVoiceSetDigest)
    }

    func testUnknownDialogueKeepsChapterGate() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
            )
        )
        try await controller.bindVoice(
            bookID: fixture.bookID,
            roleID: fixture.hero.id,
            binding: AudiobookVoiceBinding(
                roleID: fixture.hero.id,
                voiceID: "voice-hero",
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

        let designOnlyBinding = AudiobookVoiceBinding(
            roleID: fixture.hero.id,
            voiceID: "draft-designed-voice",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40),
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
        let controller = makeTestCastController(store: store)
        let fixture1 = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
        let fixture2 = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

        let returnContext = try await controller.makeVoiceReturnContext(
            bookID: fixture1.bookID,
            roleID: fixture1.hero.id
        )
        let readyBinding = AudiobookVoiceBinding(
            roleID: fixture1.hero.id,
            voiceID: "custom-voice-1",
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            modelRevision: String(repeating: "a", count: 40),
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
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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
                    voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                    modelRevision: String(repeating: "a", count: 40)
                )
            )
            XCTFail("未显式开启次要角色共用声线时，不应静默共用同一音色")
        } catch let error as AudiobookCastError {
            guard case let .duplicateVoiceRequiresSharedMinorConsent(voiceID, conflictingRoleID) = error else { return XCTFail("Unexpected: \(error)") }
            XCTAssertEqual(voiceID, "shared-voice")
            XCTAssertTrue([fixture.hero.id, guardRole.id].contains(conflictingRoleID), "冲突必须指向未允许共享的角色之一")
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
                voiceRevision: "vr_0123456789abcdef0123456789abcdef",
                modelRevision: String(repeating: "a", count: 40)
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
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

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

    private func recommendTestBindings(
        characters: [AudiobookCharacter], availableVoices: [SafeVoiceEntry], existingBindings: [UUID: AudiobookVoiceBinding] = [:],
        annotations: [AudiobookAnnotation] = [], bookID: UUID? = nil, preferredCollectionID: UUID? = nil,
        voiceMetadataByID: [String: VoiceAssetMetadata] = [:]
    ) -> [UUID: AudiobookVoiceBinding] {
        let id = bookID ?? characters[0].bookID
        var state = VoiceCatalogStore.PersistedState(metadataByVoiceID: voiceMetadataByID)
        state.preferredCollectionIDByBookID[id] = preferredCollectionID
        return AudiobookCastRegistry.recommendVoiceBindings(characters: characters, annotations: annotations,
            snapshot: p0Snapshot(availableVoices), catalog: .init(state: state), bookID: id,
            existingBindings: existingBindings).proposedBindings
    }

    private func makeTestSafeVoice(
        id: String,
        name: String,
        mode: String = "system",
        aliases: [String] = [],
        styleTags: [String] = [],
        productionReady: Bool = true
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
            runtimeRevision: String(repeating: "a", count: 40),
            catalogRevision: String(repeating: "a", count: 40)
        )
        return SafeVoiceEntry(
            id: id,
            name: name,
            aliases: aliases,
            mode: mode,
            isSystem: mode == "system", isDefault: mode == "system",
            available: true,
            availabilityReason: .available,
            voiceRevision: "vr_0123456789abcdef0123456789abcdef",
            voiceIdentityAssurance: .contentAddressed,
            model: model,
            descriptors: desc,
            operations: ["http_speech": JSONValue(.object(["parameters": JSONValue(.object(["speed": JSONValue(.object(["status": JSONValue(.string("supported")), "minimum": JSONValue(.number(0.25)), "maximum": JSONValue(.number(4))]))]))]))],
            productionReady: productionReady
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
            XCTAssertEqual(roleByID[minor.id]?.isMajor, minor.isMajor)
            XCTAssertEqual(roleByID[minor.id]?.allowSharedMinorVoice, minor.allowSharedMinorVoice, "统计建议不能授予声音共享")
        }
        for silent in silentRoles {
            XCTAssertEqual(statsByID[silent.id]?.tier, .ensemble)
            XCTAssertEqual(statsByID[silent.id]?.requiresVoiceBinding, false)
            XCTAssertEqual(roleByID[silent.id]?.allowSharedMinorVoice, silent.allowSharedMinorVoice)
        }
    }

    func testAC2_50RolesVs5VoicesDualPoolZeroDeadlockAndAC6_SilentRoleExemption() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

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
        // 本夹具验证手动独占的双池分配；角色重要性本身不构成独占要求。
        for index in characters.indices where characters[index].id == fixture.hero.id || characters[index].id == leadFemale.id {
            characters[index].voicePolicy = .init(sharingPolicy: .exclusive, bindingOrigin: .manual, isLocked: true)
        }

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

        let recommended = recommendTestBindings(
            characters: stratifiedChars,
            availableVoices: voices,
            annotations: annotations,
            bookID: fixture.bookID,
            voiceMetadataByID: [:]
        )

        XCTAssertEqual(recommended.count, stratifiedChars.count - 2, "零台词人物不消耗音色容量")

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
        do {
            try await controller.confirmCast(bookID: fixture.bookID, revisionID: castRev)
            XCTFail("虚构的额外标注与 unknown 不能证明两个角色确实没有台词")
        } catch let error as AudiobookCastError {
            guard case .missingVoiceBindings = error else { return XCTFail("Unexpected: \(error)") }
        }
    }

    func testAC3_ScenePartnerGraphColoringAndAC4_MicroProsodyAndAC5_BatchArchetypeBinding() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let controller = makeTestCastController(store: store)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)

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

        let recommended = recommendTestBindings(
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
        XCTAssertEqual(sysSpeed0, sysSpeed1, "默认推荐在试听验收前不启用微语速")

        let (cloneSpeed0, cloneSeed0) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerA, archetype: .matureMale, voiceMode: "clone", slotIndex: 0
        )
        let (cloneSpeed1, cloneSeed1) = AudiobookCastRegistry.computeMicroProsodyAndSeed(
            for: partnerB, archetype: .matureMale, voiceMode: "clone", slotIndex: 1
        )
        XCTAssertEqual(cloneSpeed0, 1.0)
        XCTAssertEqual(cloneSpeed1, 1.0)
        XCTAssertNil(cloneSeed0)
        XCTAssertNil(cloneSeed1)

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
        XCTAssertEqual(updatedCount, 0, "默认批量操作保护已有绑定")
        let updatedBindings = try await store.voiceBindings(for: fixture.bookID)
        XCTAssertEqual(updatedBindings[partnerA.id]?.voiceID, recommended[partnerA.id]?.voiceID)
        XCTAssertEqual(updatedBindings[partnerB.id]?.voiceID, recommended[partnerB.id]?.voiceID)
        XCTAssertEqual(updatedBindings[partnerC.id]?.voiceID, recommended[partnerC.id]?.voiceID)
        XCTAssertEqual(updatedBindings[fixture.hero.id]?.voiceID, heroOriginalVoice, "核心主角音色绝不可被声部批量换绑覆盖")
    }

    func testAC7_AC8_AC9_AC10_100PlusVoiceReusePromotionTaxonomyAndCollections() async throws {
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
        try await catalogStore.registerBookExclusiveVoice(
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
            try await catalogStore.registerBookExclusiveVoice(
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
                metadata: await catalogStore.metadata(for: vid)
            )
            XCTAssertEqual(resolved, sample.2, "100+ 音色必须准确自动归入六大声部行当")
        }

        // 他书来源音色可跨书复用；来源角色仍可作为当前角色的匹配偏好。
        for i in 1...30 {
            let catalogActual21 = await catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_\(i)", currentBookID: bookA)
            XCTAssertTrue(catalogActual21,
                "已登记且活跃的声音不应因来源书籍不同而被排除"
            )
        }
        let bindingsA = recommendTestBindings(
            characters: [AudiobookCharacter(bookID: bookA, displayName: "旁白", isNarrator: true), roleHeroA],
            availableVoices: voices,
            bookID: bookA,
            voiceMetadataByID: await catalogStore.metadataByVoiceID
        )
        XCTAssertEqual(bindingsA[roleHeroA.id]?.voiceID, "v_bookA_lindong")

        // AC8：显式调整分类后仍保留原始来源。
        try await catalogStore.promoteToGlobalReusable(voiceID: "v_bookB_role_1")
        let catalogActual22 = await catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_1", currentBookID: bookA)
        XCTAssertTrue(catalogActual22)
        let catalogActual23 = await catalogStore.isVoiceActiveForBook(voiceID: "v_bookB_role_1", currentBookID: nil)
        XCTAssertTrue(catalogActual23)
        let catalogActual24 = await catalogStore.metadata(for: "v_bookB_role_1")?.originBookTitle
        XCTAssertEqual(catalogActual24, "他书B")

        // AC10：创建剧团音色包并验证优先选角与归档隔离
        let collection = try await catalogStore.createCollection(name: "古风仙侠剧团包", voiceIDs: ["v_global_1"])
        try await catalogStore.archiveVoices(voiceIDs: ["v_global_7"])
        let catalogActual25 = await catalogStore.isVoiceActiveForBook(voiceID: "v_global_7", currentBookID: bookA)
        XCTAssertFalse(catalogActual25)

        let newLead = AudiobookCharacter(bookID: bookB, displayName: "新书少年男主", isNarrator: false, isMajor: true, allowSharedMinorVoice: false)
        let bindingsWithCollection = recommendTestBindings(
            characters: [AudiobookCharacter(bookID: bookB, displayName: "旁白", isNarrator: true), newLead],
            availableVoices: voices.filter { !$0.id.hasPrefix("v_bookB_") },
            bookID: bookB,
            preferredCollectionID: collection.id,
            voiceMetadataByID: await catalogStore.metadataByVoiceID
        )
        XCTAssertEqual(bindingsWithCollection[newLead.id]?.voiceID, "v_global_1", "绑定剧团音色包后应优先从该合集中选角")
    }

    func testHighVolumePlanningPreservesFunctionalReadinessAndResume() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let castController = makeTestCastController(store: store)
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
                isMajor: rIdx < 2,
                allowSharedMinorVoice: rIdx >= 2,
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

        // A recommendation includes its sharing policies and acknowledgements;
        // copying bindings into a manual batch would discard the accepted policy.
        let castingPlan = try await store.prepareCastingPlan(bookID: bookID,
            snapshot: p0Snapshot(voices), catalog: .init())
        XCTAssertTrue(castingPlan.isApplicable)
        try await castController.applyCastingPlan(bookID: bookID, plan: castingPlan,
            acknowledgedIssueIDs: castingPlan.requiredAcknowledgements)
        let recommended = try await store.voiceBindings(for: bookID)
        XCTAssertEqual(recommended.count, characters.count)

        // Functional fixture only; timing and UI responsiveness require separately authorized measurement.
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

        XCTAssertEqual(Set(recommended.keys), Set(characters.map(\.id)))
    }

    @MainActor
    func testSecondaryUnknownResolutionAndLeadExclusiveVoiceSynthesisAndFastManualConfirmation() async throws {
        let store = try AudiobookProjectStore(root: tempRoot)
        let fixture = try await Self.makeTwoChapterBook(store: store, root: tempRoot)
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
                    productionReady: false,
                    productionReadyReason: "reference_validation_not_passed"
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
                    modelRevision: String(repeating: "a", count: 40)
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

        // 3. 检测并补全六类群像音色（旁白叙事、青年男声、中老年男声、青年女声、成熟女声、特色群像）
        XCTAssertEqual(workflow.missingArchetypesForBook(bookID: fixture.bookID).count, 6)
        let createdArchetypeCount = await workflow.ensureSixArchetypeVoicesForBook(for: fixture.bookID, quietBanner: true)
        XCTAssertEqual(createdArchetypeCount, 6, "当系统仅存在默认音色时，应自动创建满足小说场景的完整六类群像音色")
        XCTAssertTrue(workflow.missingArchetypesForBook(bookID: fixture.bookID).isEmpty)

        // 4. 自动补全保留已有声音；未验收的新增声音不会覆盖系统预设。
        let createdLeadCount = await workflow.createExclusiveVoicesForLeadCharacters(for: fixture.bookID)
        XCTAssertEqual(createdLeadCount, 0, "已有绑定的旁白与主角不参与自动创建")
        XCTAssertEqual(fakeRenderer.createdLeadRequests.count, 8, "未绑定主角可生成资产，但未验收资产不能绑定")
        let mergedVoices = workflow.mergedAvailableVoices()
        XCTAssertEqual(mergedVoices.count, 10, "选择器保留已生成资产供后续检查")
        let heroBinding = try XCTUnwrap(workflow.voiceBindings[fixture.hero.id])
        XCTAssertFalse(heroBinding.voiceID.hasPrefix("ab_"), "新增声音不能自动覆盖已有绑定")
        let originalVoiceMetadata = await deps.voiceCatalog.metadata(for: heroBinding.voiceID)
        XCTAssertNil(originalVoiceMetadata, "原系统预设仍保持原来的选择")

        // 5. 确认合法的系统配声后进入制作；新增的未验收声音不参与正式制作。
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
        XCTAssertNil(updatedCh0?.currentChapterRevisionID, "缺少实际声音身份的候选必须留待复核，不能自动采用")
    }

    @MainActor
    func testAC11_to_AC12_NewlyExtractedCharactersDefaultToEnsembleAndAutoStratify() throws {
        let bookID = UUID()
        let ch1 = UUID()
        let narrator = AudiobookCharacter(bookID: bookID, displayName: "旁白", isNarrator: true, isMajor: true, allowSharedMinorVoice: false)

        // AC-1.1: Newly extracted characters via applyMergeBatch must default to isMajor == false, allowSharedMinorVoice == true
        let sampleText = "“这是什么？”“小心脚下。”石碑记载鲁殇王。"
        let sourceIndex = try AudiobookSourceIndex(utf8: Data(sampleText.utf8))
        let sampleAtom = AudiobookTextAtom(
            chapterID: ch1,
            ordinal: 0,
            sourceRange: sourceIndex.wholeRange,
            kind: .body
        )
        let outcome = AudiobookCastRegistry.applyMergeBatch(
            bookID: bookID,
            existingCharacters: [narrator],
            batchMentions: [
                AudiobookExtractionResponse.Mention(surfaceName: "吴邪", aliases: ["我"], evidenceAtomIDs: [sampleAtom.id], voiceTraitEvidence: "青年男声"),
                AudiobookExtractionResponse.Mention(surfaceName: "三叔", aliases: ["吴三省"], evidenceAtomIDs: [sampleAtom.id], voiceTraitEvidence: "中年男声"),
                AudiobookExtractionResponse.Mention(surfaceName: "鲁殇王", aliases: [], evidenceAtomIDs: [sampleAtom.id], voiceTraitEvidence: nil),
            ],
            mergeGroups: [
                AudiobookMergeResponse.Group(canonicalName: "吴邪", memberSurfaceNames: ["吴邪"], aliases: ["我"], isCollisionUnresolved: false, evidenceSummary: "青年男声"),
                AudiobookMergeResponse.Group(canonicalName: "三叔", memberSurfaceNames: ["三叔"], aliases: ["吴三省"], isCollisionUnresolved: false, evidenceSummary: "中年男声"),
                AudiobookMergeResponse.Group(canonicalName: "鲁殇王", memberSurfaceNames: ["鲁殇王"], aliases: [], isCollisionUnresolved: false, evidenceSummary: nil),
            ],
            atomsByID: [sampleAtom.id: sampleAtom],
            source: sourceIndex
        )
        let extractedNonNarrators = outcome.characters.filter { !$0.isNarrator }
        XCTAssertEqual(extractedNonNarrators.count, 3)
        for role in extractedNonNarrators {
            XCTAssertFalse(role.isMajor, "AC-1.1: 新提取角色默认不应标记为 isMajor=true")
            XCTAssertTrue(role.allowSharedMinorVoice, "AC-1.1: 新提取角色默认应允许共享群像音色")
        }

        // AC-1.2: 1-line and 0-line characters are excluded from automatic .lead, and automatic .lead count is capped
        var roles: [AudiobookCharacter] = [narrator]
        var annotations: [AudiobookAnnotation] = []
        var offset: Int64 = 0
        let winID = UUID()

        for idx in 1...12 {
            // Simulate legacy unstratified characters (isMajor=true, allowSharedMinorVoice=false)
            let role = AudiobookCharacter(
                bookID: bookID,
                displayName: "角色\(idx)",
                isNarrator: false,
                isMajor: true,
                allowSharedMinorVoice: false,
                chapterIDs: [ch1]
            )
            roles.append(role)
            let lineCount: Int
            if idx <= 3 {
                lineCount = 15 - idx * 2 // 13, 11, 9 lines -> core leads
            } else if idx <= 9 {
                lineCount = 1 // 1 line -> ensemble, never lead
            } else {
                lineCount = 0 // 0 lines -> silent mention
            }
            for _ in 0..<lineCount {
                let range = AudiobookSourceRange(lowerBound: offset, upperBound: offset + 12)
                offset += 12
                annotations.append(
                    AudiobookAnnotation(
                        bookID: bookID,
                        chapterID: ch1,
                        windowID: winID,
                        atomID: UUID(),
                        sourceRange: range,
                        assignment: .assigned(roleID: role.id)
                    )
                )
            }
        }

        let (_, statsByID, _) = AudiobookCastRegistry.computeRoleDialogueStats(
            characters: roles,
            annotations: annotations,
            availableVoiceCount: 6
        )
        let autoLeads = roles.filter { !$0.isNarrator && statsByID[$0.id]?.tier == .lead }
        XCTAssertLessThanOrEqual(autoLeads.count, 4, "AC-1.2: 6 个可用音色下自动核心主角数不超过 4")
        for role in roles where !role.isNarrator {
            let stat = try XCTUnwrap(statsByID[role.id])
            if stat.dialogueAtomCount <= 1 {
                XCTAssertEqual(stat.tier, .ensemble, "AC-1.2: 0 句或 1 句台词的角色必须归为群像 (.ensemble)")
            }
        }

        let refreshed = AudiobookCastRegistry.refreshCharacterMajorStatusAndOrder(
            characters: roles,
            annotations: annotations,
            availableVoiceCount: 6
        )
        let refreshedMajorNonNarrators = refreshed.filter { !$0.isNarrator && $0.isMajor }
        XCTAssertEqual(refreshedMajorNonNarrators.count, 3, "AC-1.1/1.2: 仅高频主角标为 isMajor=true，低频角色自动标为 allowSharedMinorVoice=true")
    }
}
