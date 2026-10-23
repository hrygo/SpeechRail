import Foundation
import SpeechRailControlKit
import XCTest
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct AudiobookProductionRowSnapshotTests {
    private func fragments(count: Int) -> [AudiobookFragment] {
        let bookID = UUID(), chapterID = UUID(), roleID = UUID()
        return (0..<count).map { index in
            AudiobookFragment(bookID: bookID, chapterID: chapterID, ordinal: index,
                roleID: roleID, sourceRange: .init(lowerBound: Int64(index), upperBound: Int64(index + 1)),
                atomIDs: [], localAssignmentDigest: "assignment", voiceBindingDigest: "voice",
                policyDigest: "policy", dependencyDigest: "dependency")
        }
    }

    @Test(arguments: [0, 1, 3, 130])
    func preservesOrderIdentityAndPredecessors(count: Int) {
        let source = fragments(count: count)
        let rows = AudiobookWorkspaceProjection.productionRows(source)
        #expect(rows.map(\.id) == source.map(\.id))
        #expect(rows.map(\.fragment) == source)
        #expect(rows.map(\.previousFragment) == source.indices.map { $0 == 0 ? nil : source[$0 - 1] })
    }

    @Test(arguments: [0, 1, 130])
    func deferredRowsRemainCoherentAfterSourceReplacement(replacementCount: Int) {
        var current = fragments(count: 130)
        let original = current
        let rows = AudiobookWorkspaceProjection.productionRows(current)
        // LazyVStack may still render old rows after a chapter refresh or switch.
        let deferredRender = { rows.map { ($0.fragment, $0.previousFragment) } }
        current = fragments(count: replacementCount)
        let rendered = deferredRender()
        #expect(rendered.map(\.0) == original)
        #expect(rendered.map(\.1) == original.indices.map { $0 == 0 ? nil : original[$0 - 1] })
        let refreshed = AudiobookWorkspaceProjection.productionRows(current)
        #expect(refreshed.map(\.fragment) == current)
        #expect(refreshed.map(\.previousFragment) == current.indices.map { $0 == 0 ? nil : current[$0 - 1] })
    }
}

final class AudiobookWorkspacePerformanceTests: XCTestCase {
    private final class WorkCounter: Sendable {
        let value = Mutex(0)
        func increment() -> Int { value.withLock { $0 += 1; return $0 } }
        var count: Int { value.withLock { $0 } }
    }
    private actor ReadGate {
        let entered = AsyncStream<Void>.makeStream()
        private var continuation: CheckedContinuation<Void, Never>?
        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.continuation.yield(())
            }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testRoleStatsVisitAnnotationsAndEdgesOnceAndMatchReference() throws {
        let book = UUID(), chapterIDs = (0..<3).map { _ in UUID() }
        let source = try AudiobookSourceIndex(utf8: Data(String(repeating: "甲乙😀", count: 1_000).utf8))
        for scale in [1, 10] {
            let roles = (0..<(10 * scale)).map { AudiobookCharacter(bookID: book, displayName: "夹具角色\($0)", isNarrator: $0 == 0) }
            let annotations = (0..<(40 * scale)).map { i in
                AudiobookAnnotation(bookID: book, chapterID: chapterIDs[i % 3], windowID: UUID(), atomID: UUID(),
                    sourceRange: .init(lowerBound: Int64(i * 10), upperBound: Int64((i + 2) * 10)),
                    assignment: .assigned(roleID: roles[i % roles.count].id))
            }
            let duplicated = annotations + annotations.prefix(10)
            let graph = AudiobookSceneConflictGraph.build(characters: roles, annotations: duplicated)
            for sourceInput in [source, nil] {
                var work = AudiobookRoleStatsWork()
                let actual = try AudiobookCastRegistry.computeRoleDialogueStats(characters: roles, annotations: duplicated,
                    source: sourceInput, work: &work)
                let expected = referenceStats(characters: roles, annotations: duplicated, source: sourceInput)
                XCTAssertEqual(actual.updatedCharacters, expected.updatedCharacters)
                XCTAssertEqual(actual.statsByRoleID, expected.statsByRoleID)
                XCTAssertLessThanOrEqual(actual.statsByRoleID.values.filter { $0.tier == .lead }.count, 6,
                    "Eight available voices reserve two slots outside the automatic lead-role pool")
                XCTAssertEqual(actual.conflictWeights, expected.conflictWeights)
                XCTAssertEqual(work.annotationVisits, duplicated.count)
                XCTAssertEqual(work.edgeVisits, graph.edges.count)
                XCTAssertLessThanOrEqual(work.rangeVisits, annotations.count)
            }
        }
    }

    private func fixture() async throws -> (AudiobookProjectStore, UUID, [AudiobookChapter], AudiobookCharacter) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try AudiobookProjectStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 灯塔\n海风吹来。\n第二章 码头\n有人回来了。\n第三章 归途\n灯光照亮道路。\n".utf8), suggestedTitle: "夹具")
        let book = try await store.importBook(preview)
        let chapters = try await store.chapters(for: book)
        let roles = try await store.characters(for: book)
        XCTAssertEqual(chapters.count, 3)
        return (store, book, chapters, try XCTUnwrap(roles.first))
    }

    private func addCandidate(store: AudiobookProjectStore, book: UUID, chapter: AudiobookChapter,
        role: AudiobookCharacter, ordinal: Int) async throws -> AudiobookRenderCandidate {
        let atoms = try await store.atoms(for: book, chapterID: chapter.id).filter { $0.kind != .formatting }
        let atom = try XCTUnwrap(atoms.first)
        let fragment = AudiobookFragment(bookID: book, chapterID: chapter.id, ordinal: ordinal, roleID: role.id,
            sourceRange: atom.sourceRange, atomIDs: [atom.id], localAssignmentDigest: "assignment", voiceBindingDigest: "voice",
            policyDigest: "policy", dependencyDigest: "dependency")
        var fragments = try await store.fragments(for: book, chapterID: chapter.id)
        fragments.append(fragment)
        try await store.saveFragments(bookID: book, chapterID: chapter.id, fragments: fragments)
        var wav = Data()
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        wav.append(Data("RIFF".utf8)); integer(UInt32(36 + 480))
        wav.append(Data("WAVEfmt ".utf8)); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(24_000)); integer(UInt32(48_000)); integer(UInt16(2)); integer(UInt16(16))
        wav.append(Data("data".utf8)); integer(UInt32(480)); wav.append(Data(repeating: 0, count: 480))
        let candidate = AudiobookRenderCandidate(bookID: book, chapterID: chapter.id, fragmentID: fragment.id,
            generation: 1, relativeAssetPath: "books/\(book)/audio/\(UUID()).wav", fileSHA256: AudiobookDigest.sha256Hex(wav),
            pcmSHA256: try AudioDigest.sha256HexOfPCM(in: wav), frameCount: 240, dependencyDigest: fragment.dependencyDigest)
        try await store.commitCandidate(candidate, wav: wav)
        return candidate
    }

    func testChapterLoadDoesNotFetchOtherChapterCandidates() async throws {
        let (store, book, chapters, role) = try await fixture()
        let selected = try await addCandidate(store: store, book: book, chapter: chapters[0], role: role, ordinal: 0)
        let before = try await store.loadChapterWorkspaceInput(bookID: book, chapterID: chapters[0].id)
        for i in 0..<32 {
            _ = try await addCandidate(store: store, book: book, chapter: chapters[1], role: role, ordinal: i)
        }
        let after = try await store.loadChapterWorkspaceInput(bookID: book, chapterID: chapters[0].id)
        XCTAssertEqual(after.candidates.map(\.id), [selected.id])
        XCTAssertEqual(after.work.candidateRowsRead, 1)
        XCTAssertEqual(after.work.candidateQueries, 1)
        XCTAssertLessThanOrEqual(after.work.candidateVMSteps, before.work.candidateVMSteps + 8,
            "Unrelated chapter rows must not enter the indexed candidate read")
        XCTAssertEqual(after.work.candidateFullScanSteps, 0)
        XCTAssertEqual(after.revision, before.revision)
    }

    func testSameCompletedCountWithNewCandidateChangesRevision() async throws {
        let (store, book, chapters, role) = try await fixture()
        let before = try await store.loadChapterWorkspaceInput(bookID: book, chapterID: chapters[0].id)
        _ = try await addCandidate(store: store, book: book, chapter: chapters[0], role: role, ordinal: 0)
        let after = try await store.loadChapterWorkspaceInput(bookID: book, chapterID: chapters[0].id)
        XCTAssertNotEqual(after.revision, before.revision)
        XCTAssertEqual(after.candidates.count, 1)
        let checkpoint = try await store.productionCheckpoint(for: book)
        XCTAssertNil(checkpoint, "A candidate revision must not depend on progress counters")
    }

    func testCacheEvictsOldBookAndThirdChapter() async throws {
        let (store, book, chapters, _) = try await fixture()
        let reader = AudiobookWorkspaceReader(store: store)
        func request(_ chapter: UUID, generation: UInt64) -> AudiobookWorkspaceRequest {
            .init(bookID: book, chapterID: chapter, preferredFragmentID: nil, selectionGeneration: generation)
        }
        _ = try await reader.loadChapter(request(chapters[0].id, generation: 1))
        _ = try await reader.loadChapter(request(chapters[1].id, generation: 2))
        _ = try await reader.loadChapter(request(chapters[0].id, generation: 3))
        _ = try await reader.loadChapter(request(chapters[2].id, generation: 4))
        let cached = await reader.cacheState()
        XCTAssertEqual(cached.chapterIDs, [chapters[0].id, chapters[2].id])
        let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章 新书\n新的片段。\n".utf8), suggestedTitle: "新书夹具")
        let other = try await store.importBook(preview)
        let otherChapters = try await store.chapters(for: other)
        _ = try await reader.loadChapter(.init(bookID: other, chapterID: otherChapters[0].id,
            preferredFragmentID: nil, selectionGeneration: 5))
        let replaced = await reader.cacheState()
        XCTAssertEqual(replaced.bookID, other)
        XCTAssertEqual(replaced.chapterIDs, [otherChapters[0].id])
        await reader.stop()
        let stopped = await reader.cacheState()
        XCTAssertEqual(stopped.activeOperations, 0)
        XCTAssertEqual(stopped.waitingDomains, 0)
        XCTAssertTrue(stopped.chapterIDs.isEmpty)
    }

    func testUnchangedChapterProjectsOnceAndNewRevisionReloads() async throws {
        let (store, book, chapters, role) = try await fixture()
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let reader = AudiobookWorkspaceReader(store: store, metrics: metrics)
        let request = AudiobookWorkspaceRequest(bookID: book, chapterID: chapters[0].id,
            preferredFragmentID: nil, selectionGeneration: 1)
        _ = try await reader.loadChapter(request)
        _ = try await reader.loadChapter(request)
        XCTAssertEqual(metrics.snapshot(for: .workspaceProject).samples, 1)
        _ = try await addCandidate(store: store, book: book, chapter: chapters[1], role: role, ordinal: 0)
        _ = try await reader.loadChapter(request)
        XCTAssertEqual(metrics.snapshot(for: .workspaceProject).samples, 1, "Other chapter writes don't rebuild this chapter")
        _ = try await addCandidate(store: store, book: book, chapter: chapters[0], role: role, ordinal: 0)
        let updated = try await reader.loadChapter(request)
        XCTAssertEqual(updated.snapshot.candidates.count, 1)
        XCTAssertEqual(metrics.snapshot(for: .workspaceProject).samples, 2)
        await reader.stop()
    }

    private final class ProjectionGate: Sendable {
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let batches = Mutex(0)
        let ranOnMain = Mutex(false)
        func block(_ index: Int) {
            batches.withLock { $0 += 1 }
            let main = Thread.isMainThread
            ranOnMain.withLock { $0 = main }
            entered.continuation.yield(())
            if !main { release.wait() }
        }
    }

    func testCancellationStopsProjectionBatchesWithoutBlockingMainActor() async throws {
        let (store, book, chapters, _) = try await fixture()
        let original = try await store.loadChapterWorkspaceInput(bookID: book, chapterID: chapters[0].id)
        let atom = try XCTUnwrap(original.atoms.first)
        let large = AudiobookChapterWorkspaceInput(bookID: book, chapterID: original.chapterID, source: original.source,
            atoms: Array(repeating: atom, count: 10_000), annotations: [], fragments: [], candidates: [],
            revision: original.revision, work: original.work, changeToken: original.changeToken)
        let gate = ProjectionGate(), metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let task = Task {
            try await AudiobookWorkspaceProjection.chapter(large, preferredFragmentID: nil, metrics: metrics, onBatch: gate.block)
        }
        var iterator = gate.entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let heartbeat = await MainActor.run { 1 }
        XCTAssertEqual(heartbeat, 1)
        task.cancel()
        gate.release.signal()
        do { _ = try await task.value; XCTFail("Cancelled projection must not publish a partial snapshot") }
        catch is CancellationError {}
        XCTAssertFalse(gate.ranOnMain.withLock { $0 })
        XCTAssertEqual(gate.batches.withLock { $0 }, 1)
        XCTAssertEqual(metrics.snapshot(for: .workspaceProject).cancelled, 1)
    }

    func testBookProjectionRetriesWhenSelectedChapterChangesDuringProjection() async throws {
        try await assertProjectionRevalidates(bookWorkspace: true)
    }

    func testChapterProjectionRetriesWhenSelectedChapterChangesDuringProjection() async throws {
        try await assertProjectionRevalidates(bookWorkspace: false)
    }

    private func assertProjectionRevalidates(bookWorkspace: Bool) async throws {
        let (store, book, chapters, role) = try await fixture()
        let gate = ProjectionGate(), batches = WorkCounter()
        let reader = AudiobookWorkspaceReader(store: store, projectionBatch: { index in
            if batches.increment() == 1 { gate.block(index) }
        })
        let request = AudiobookWorkspaceRequest(bookID: book, chapterID: chapters[0].id,
            preferredFragmentID: nil, selectionGeneration: 1)
        let loading = Task { () throws -> [UUID] in
            if bookWorkspace { return try await reader.load(request).snapshot.chapterDetails.candidates.map(\.id) }
            return try await reader.loadChapter(request).snapshot.candidates.map(\.id)
        }
        var entered = gate.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        let added: AudiobookRenderCandidate
        do { added = try await addCandidate(store: store, book: book, chapter: chapters[0], role: role, ordinal: 0) }
        catch { gate.release.signal(); _ = try? await loading.value; throw error }
        gate.release.signal()
        let published = try await loading.value
        XCTAssertEqual(published, [added.id], "An edit within the same selection must invalidate the projected snapshot")
        XCTAssertGreaterThan(batches.count, 1)
        await reader.stop()
    }

    func testOneActiveReadAndOnePendingSelectionRetireSupersededWaiter() async throws {
        let (store, book, chapters, _) = try await fixture()
        let gate = ReadGate()
        let queued = AsyncStream<UInt64>.makeStream()
        let reads = WorkCounter()
        let reader = AudiobookWorkspaceReader(store: store, readBoundary: { _ in
            let count = reads.increment()
            if count == 1 {
                await gate.suspend()
            }
        }, queueObserver: { queued.continuation.yield($0) })
        func request(_ generation: UInt64) -> AudiobookWorkspaceRequest {
            .init(bookID: book, chapterID: chapters[0].id, preferredFragmentID: nil, selectionGeneration: generation)
        }
        let first = Task { try await reader.load(request(1)) }
        var starts = gate.entered.stream.makeAsyncIterator()
        _ = await starts.next()
        let second = Task { try await reader.load(request(2)) }
        var waiting = queued.stream.makeAsyncIterator()
        let queuedSecond = await waiting.next()
        XCTAssertEqual(queuedSecond, 2)
        let third = Task { try await reader.load(request(3)) }
        let queuedThird = await waiting.next()
        XCTAssertEqual(queuedThird, 3)
        do { _ = try await second.value; XCTFail("Superseded pending requests retire before the physical read exits") }
        catch is CancellationError {}
        let state = await reader.cacheState()
        XCTAssertEqual(state.activeOperations, 1)
        XCTAssertEqual(state.waitingDomains, 1)
        await gate.release()
        do { _ = try await first.value; XCTFail("The first result was superseded") } catch is CancellationError {}
        let result = try await third.value
        XCTAssertEqual(result.request.selectionGeneration, 3)
        XCTAssertEqual(reads.count, 2)
        await reader.stop()
    }

    func testStoreRetainsAtMostTwoBookIndexes() async throws {
        let (store, _, _, _) = try await fixture()
        for _ in 0..<5 {
            let preview = try AudiobookTXTImporter.prepare(rawData: Data("第一章\n海风吹来。\n".utf8), suggestedTitle: "缓存夹具")
            let book = try await store.importBook(preview)
            _ = try await store.sourceIndex(for: book)
            _ = try await store.characters(for: book)
            _ = try await store.annotations(for: book)
            let counts = await store.workspaceStoreCacheCounts()
            XCTAssertLessThanOrEqual(counts.sourceIndices, 2)
            XCTAssertLessThanOrEqual(counts.characters, 2)
            XCTAssertLessThanOrEqual(counts.annotations, 2)
        }
    }

    private func referenceStats(
        characters: [AudiobookCharacter], annotations: [AudiobookAnnotation], availableVoiceCount: Int = 8,
        source: AudiobookSourceIndex? = nil, atoms: [AudiobookTextAtom] = [], scenes: [AudiobookCastingScene] = []
    ) -> (updatedCharacters: [AudiobookCharacter], statsByRoleID: [UUID: AudiobookRoleDialogueStats], conflictWeights: [UUID: [UUID: Int]]) {
        let graph = AudiobookSceneConflictGraph.build(characters: characters, annotations: annotations, atoms: atoms, scenes: scenes)
        var counts: [UUID: Int] = [:], scalars: [UUID: Int] = [:], chapters: [UUID: Set<UUID>] = [:]
        let unique = Dictionary(grouping: annotations, by: { "\($0.chapterID)|\($0.sourceRange.lowerBound)|\($0.sourceRange.upperBound)|\($0.assignment.roleID?.uuidString ?? "unknown")" }).values.compactMap(\.first)
        for annotation in unique {
            guard let role = annotation.assignment.roleID else { continue }
            counts[role, default: 0] += 1
            chapters[role, default: []].insert(annotation.chapterID)
        }
        // Union source intervals before counting; repeated windows and overlapping retries cannot inflate text volume.
        for role in characters {
            let ranges = unique.filter { $0.assignment.roleID == role.id }.map(\.sourceRange).sorted()
            var merged: [AudiobookSourceRange] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = .init(lowerBound: last.lowerBound, upperBound: max(last.upperBound, range.upperBound))
                } else { merged.append(range) }
            }
            if let source { scalars[role.id] = merged.reduce(0) { $0 + ((try? source.text(in: $1).unicodeScalars.count) ?? 0) } }
        }
        func volume(_ id: UUID) -> Int { source == nil ? (counts[id] ?? 0) : (scalars[id] ?? 0) }
        let ranked = characters.filter { !$0.isNarrator && volume($0.id) > 0 }.sorted {
            volume($0.id) == volume($1.id) ? $0.id.uuidString < $1.id.uuidString : volume($0.id) > volume($1.id)
        }
        let total = ranked.reduce(0) { $0 + volume($1.id) }
        let maxLeadRoles = max(1, min(8, availableVoiceCount > 0 ? max(3, availableVoiceCount - 2) : 6))
        var front = 0, leads: Set<UUID> = []
        for role in ranked where front < Int(ceil(Double(total) * 0.75)) && leads.count < maxLeadRoles {
            if ranked.count > maxLeadRoles && (counts[role.id] ?? 0) <= 1 && !leads.isEmpty {
                break
            }
            leads.insert(role.id); front += volume(role.id)
        }
        var stats: [UUID: AudiobookRoleDialogueStats] = [:]
        for role in characters {
            let inferred: AudiobookRoleTier = role.isNarrator ? .narrator : (leads.contains(role.id) ? .lead : ((chapters[role.id]?.count ?? 0) > 1 ? .supporting : .ensemble))
            var item = AudiobookRoleDialogueStats(roleID: role.id, dialogueAtomCount: counts[role.id] ?? 0,
                speakingChapterIDs: chapters[role.id] ?? [], tier: role.manualTier ?? inferred,
                archetype: role.inferredVoiceArchetype(peers: characters))
            item.dialogueScalarCount = scalars[role.id] ?? 0
            item.statisticsRevision = source == nil ? "dialogue-stats-v2:source-unavailable" : "dialogue-stats-v2:unicode-scalars"
            for edge in graph.edges where edge.roleA == role.id || edge.roleB == role.id {
                let other = edge.roleA == role.id ? edge.roleB : edge.roleA
                if edge.kind == .directDialogue { item.scenePartnerRoleIDs.insert(other) }
                if edge.kind == .chapterCoPresence { item.sameChapterRoleIDs.insert(other) }
            }
            stats[role.id] = item
        }
        return (characters, stats, graph.weights)
    }

}
