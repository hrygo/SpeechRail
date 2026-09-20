import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPreparationPipelineTests {
    @Test func shortSourceUsesOneMapAndDoesNotReduce() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let calls = CallLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(result.reduceRequestCount == 0)
        #expect(result.status == .complete)
        #expect(result.draft.blocks.count == 1)
        #expect(result.draft.blocks[0].disposition == .speak)
        #expect((await calls.schemaVersions) == ["teleprompter.preparation.v2"])
    }

    @Test func malformedMapResponseUsesOneBoundedRecoveryRequest() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let attempts = AttemptCounter()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2",
               await attempts.next() == 1 {
                return "{}"
            }
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 1)
        #expect(await attempts.value == 2)
    }

    @Test func longSourceMapsInBoundedWindowsThenReducesEachAdjacentSeam() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let calls = CallLog()
        let progress = ProgressLog()
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try await calls.append(prompt)
            return try Self.response(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input) { update in
            progress.append(update)
        }

        #expect(result.mapRequestCount == 4)
        #expect(result.reduceRequestCount == 3)
        #expect(result.mapWindows.count == 4)
        #expect(result.mapWindows.allSatisfy { $0.sourceUnitIDs.count <= 24 })
        #expect(result.boundaries.count == 3)
        #expect(result.boundaries.allSatisfy { $0.isChecked })
        #expect(result.status == .complete)
        #expect(result.draft.blocks.count == 12)

        let targetIDs = await calls.mapInputs.flatMap { $0.targets.map(\.id) }
        let reduceCount = await calls.reduceCount
        let reduceStartedOnlyAfterAllMaps = await calls.reduceStartedOnlyAfterAllMaps
        #expect(targetIDs == fixture.units.map(\.id))
        #expect(reduceCount == 3)
        #expect(reduceStartedOnlyAfterAllMaps)
        #expect(progress.updates.first?.phase == .mapping)
        #expect(progress.updates.last?.phase == .finalizing)
        #expect(progress.updates.contains { $0.phase == .reducing && $0.completed == 3 && $0.total == 3 })
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func reduceFailureKeepsCompleteLeafDraftAndMarksUncheckedSeams() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.reduction.v1" {
                throw TestFailure.reduceUnavailable
            }
            return try Self.mapResponse(for: prompt)
        })

        let result = try await pipeline.prepare(fixture.input)

        #expect(result.mapRequestCount == 4)
        #expect(result.reduceRequestCount == 3)
        #expect(result.draft.blocks.count == 12)
        #expect(result.boundaries.allSatisfy { !$0.isChecked })
        #expect(result.status == .boundaryUnchecked)
        #expect(result.draft.blocks.map(\.rawSourceText).joined() == fixture.source.sourceText)
    }

    @Test func mapFailureDoesNotProduceAnActivatablePartialDraft() async throws {
        let fixture = try makeFixture(lineCount: 96)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            if prompt.schemaVersion == "teleprompter.preparation.v2" {
                throw TestFailure.mapUnavailable
            }
            return ""
        })

        await #expect(throws: TeleprompterPreparationError.self) {
            try await pipeline.prepare(fixture.input)
        }
    }

    @Test func cancellationInvalidatesLateMapResponse() async throws {
        let fixture = try makeFixture(lineCount: 4)
        let pipeline = TeleprompterPreparationPipeline(completion: { prompt in
            try? await Task.sleep(for: .milliseconds(80))
            return try Self.mapResponse(for: prompt)
        })

        let task = Task {
            try await pipeline.prepare(fixture.input)
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private struct Fixture {
        let source: TeleprompterImportedSource
        let units: [TeleprompterSourceUnit]
        let input: TeleprompterPreparationInput
    }

    private enum TestFailure: Error, Sendable {
        case mapUnavailable
        case reduceUnavailable
    }

    private actor CallLog {
        var schemaVersions: [String] = []
        var mapInputs: [TeleprompterPreparationMapInput] = []
        var reduceCount = 0
        private var mapsCompleted = 0
        private(set) var reduceStartedOnlyAfterAllMaps = true

        func append(_ prompt: TeleprompterPreparationPrompt) throws {
            schemaVersions.append(prompt.schemaVersion)
            if prompt.schemaVersion == "teleprompter.preparation.v2" {
                let input = try JSONDecoder().decode(
                    TeleprompterPreparationMapInput.self,
                    from: Data(prompt.input.utf8)
                )
                mapInputs.append(input)
                mapsCompleted += 1
            } else if prompt.schemaVersion == "teleprompter.reduction.v1" {
                reduceCount += 1
                reduceStartedOnlyAfterAllMaps = reduceStartedOnlyAfterAllMaps && mapsCompleted == 4
            }
        }
    }

    private actor AttemptCounter {
        private(set) var value = 0

        func next() -> Int {
            value += 1
            return value
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TeleprompterPreparationProgress] = []

        func append(_ value: TeleprompterPreparationProgress) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var updates: [TeleprompterPreparationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func makeFixture(lineCount: Int) throws -> Fixture {
        let text = (0..<lineCount).map { "第\($0)段。\n" }.joined()
        let source = try TeleprompterSourceImporter.importData(Data(text.utf8), fileExtension: "txt")
        let units = try TeleprompterSourceUnitBuilder(maxBudgetUnits: 12).build(source)
        let plan = try TeleprompterTimingPlanner.plan(
            sourceUnits: units,
            estimates: Array(repeating: nil, count: units.count),
            targetMinutes: 20
        )
        return Fixture(
            source: source,
            units: units,
            input: TeleprompterPreparationInput(
                source: source,
                sourceUnits: units,
                timingPlan: plan,
                pace: .natural
            )
        )
    }

    private static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],"review_block_ids":[]}"#
        }
        return try mapResponse(for: prompt)
    }

    private static func mapResponse(for prompt: TeleprompterPreparationPrompt) throws -> String {
        let input = try JSONDecoder().decode(
            TeleprompterPreparationMapInput.self,
            from: Data(prompt.input.utf8)
        )
        guard !input.targets.isEmpty else {
            throw TestFailure.mapUnavailable
        }
        let blocks = stride(from: 0, to: input.targets.count, by: 8).map { start in
            let end = min(start + 8, input.targets.count)
            let group = Array(input.targets[start..<end])
            return TeleprompterMapBlock(
                startUnit: group[0].id,
                endUnit: group[group.count - 1].id + 1,
                mode: .speak,
                text: group.map(\.rawText).joined(),
                issues: []
            )
        }
        let output = TeleprompterMapOutput(blocks: blocks)
        return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    }
}
