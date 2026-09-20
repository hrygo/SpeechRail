import Foundation

public enum TeleprompterPreparationPhase: String, Codable, Equatable, Sendable {
    case mapping
    case reducing
    case finalizing
}

public struct TeleprompterPreparationProgress: Codable, Equatable, Sendable {
    public let phase: TeleprompterPreparationPhase
    public let completed: Int
    public let total: Int
    public let currentIndex: Int?

    public init(
        phase: TeleprompterPreparationPhase,
        completed: Int,
        total: Int,
        currentIndex: Int? = nil
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentIndex = currentIndex
    }
}

public struct TeleprompterPreparationInput: Equatable, Sendable {
    public let source: TeleprompterImportedSource
    public let sourceUnits: [TeleprompterSourceUnit]
    public let timingPlan: TeleprompterTimingPlan
    public let pace: TeleprompterPace
    public let operation: TeleprompterPreparationOperation
    public let selectedUnitIDs: Set<Int>?

    public init(
        source: TeleprompterImportedSource,
        sourceUnits: [TeleprompterSourceUnit],
        timingPlan: TeleprompterTimingPlan,
        pace: TeleprompterPace,
        operation: TeleprompterPreparationOperation = .prepare,
        selectedUnitIDs: Set<Int>? = nil
    ) {
        self.source = source
        self.sourceUnits = sourceUnits
        self.timingPlan = timingPlan
        self.pace = pace
        self.operation = operation
        self.selectedUnitIDs = selectedUnitIDs
    }
}

public struct TeleprompterPreparationPolicy: Codable, Equatable, Sendable {
    public let maxWindowUnits: Int
    public let maxWindowBudgetUnits: Int
    public let maxGroupUnits: Int
    public let maxReadOnlyContextUnits: Int

    public init(
        maxWindowUnits: Int = 24,
        maxWindowBudgetUnits: Int = 1_600,
        maxGroupUnits: Int = 8,
        maxReadOnlyContextUnits: Int = 1
    ) {
        self.maxWindowUnits = max(1, maxWindowUnits)
        self.maxWindowBudgetUnits = max(1, maxWindowBudgetUnits)
        self.maxGroupUnits = max(1, maxGroupUnits)
        self.maxReadOnlyContextUnits = max(0, maxReadOnlyContextUnits)
    }
}

public struct TeleprompterPreparationMapWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let sourceUnitIDs: [Int]
    public let localBudgetSeconds: TimeInterval

    public init(
        id: String,
        ordinal: Int,
        sourceUnitIDs: [Int],
        localBudgetSeconds: TimeInterval
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceUnitIDs = sourceUnitIDs
        self.localBudgetSeconds = localBudgetSeconds
    }
}

public enum TeleprompterPreparationBoundaryState: String, Codable, Equatable, Sendable {
    case checked
    case unchecked
    case notApplicable
}

public struct TeleprompterPreparationBoundary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let leftBlockID: String
    public let rightBlockID: String
    public var state: TeleprompterPreparationBoundaryState
    public var reviewBlockIDs: [String]
    public var failureMessage: String?

    public init(
        id: String,
        leftBlockID: String,
        rightBlockID: String,
        state: TeleprompterPreparationBoundaryState,
        reviewBlockIDs: [String] = [],
        failureMessage: String? = nil
    ) {
        self.id = id
        self.leftBlockID = leftBlockID
        self.rightBlockID = rightBlockID
        self.state = state
        self.reviewBlockIDs = reviewBlockIDs
        self.failureMessage = failureMessage
    }

    public var isChecked: Bool { state == .checked }
}

public enum TeleprompterPreparationStatus: String, Codable, Equatable, Sendable {
    case complete
    case reviewRequired
    case boundaryUnchecked
}

public struct TeleprompterReadingDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceRevisionID: String
    public let sourceSHA256: String
    public let targetMinutes: Int
    public let targetSeconds: TimeInterval
    public let budgetSeconds: TimeInterval
    public var blocks: [TeleprompterReadingBlock]
    public var revisions: [String: Int]
    public var boundaries: [TeleprompterPreparationBoundary]
    public var durationEstimate: TeleprompterDurationEstimate

    public init(
        id: String,
        sourceRevisionID: String,
        sourceSHA256: String,
        targetMinutes: Int,
        targetSeconds: TimeInterval,
        budgetSeconds: TimeInterval,
        blocks: [TeleprompterReadingBlock],
        revisions: [String: Int],
        boundaries: [TeleprompterPreparationBoundary],
        durationEstimate: TeleprompterDurationEstimate
    ) {
        self.id = id
        self.sourceRevisionID = sourceRevisionID
        self.sourceSHA256 = sourceSHA256
        self.targetMinutes = targetMinutes
        self.targetSeconds = targetSeconds
        self.budgetSeconds = budgetSeconds
        self.blocks = blocks
        self.revisions = revisions
        self.boundaries = boundaries
        self.durationEstimate = durationEstimate
    }
}

public struct TeleprompterPreparationResult: Codable, Equatable, Sendable {
    public let draft: TeleprompterReadingDraft
    public let status: TeleprompterPreparationStatus
    public let mapWindows: [TeleprompterPreparationMapWindow]
    public let mapRequestCount: Int
    public let reduceRequestCount: Int

    public init(
        draft: TeleprompterReadingDraft,
        status: TeleprompterPreparationStatus,
        mapWindows: [TeleprompterPreparationMapWindow],
        mapRequestCount: Int,
        reduceRequestCount: Int
    ) {
        self.draft = draft
        self.status = status
        self.mapWindows = mapWindows
        self.mapRequestCount = mapRequestCount
        self.reduceRequestCount = reduceRequestCount
    }

    public var blocks: [TeleprompterReadingBlock] { draft.blocks }
    public var boundaries: [TeleprompterPreparationBoundary] { draft.boundaries }
}

public struct TeleprompterPreparationPipeline: Sendable {
    public typealias Completion = @Sendable (TeleprompterPreparationPrompt) async throws -> String
    public typealias ProgressHandler = @Sendable (TeleprompterPreparationProgress) -> Void

    private let completion: Completion
    private let policy: TeleprompterPreparationPolicy

    public init(
        completion: @escaping Completion,
        policy: TeleprompterPreparationPolicy = .init()
    ) {
        self.completion = completion
        self.policy = policy
    }

    public func prepare(
        _ input: TeleprompterPreparationInput,
        onProgress: ProgressHandler? = nil
    ) async throws -> TeleprompterPreparationResult {
        let selection = try validate(input)
        let windows = try makeWindows(selection: selection, input: input)
        onProgress?(.init(phase: .mapping, completed: 0, total: windows.count))

        var windowStates: [[BlockState]] = []
        windowStates.reserveCapacity(windows.count)
        var mapRequestCount = 0

        for (windowIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            let sourceUnits = selection.unitsByID
            let targets = window.sourceUnitIDs.compactMap { sourceUnits[$0] }
            guard targets.count == window.sourceUnitIDs.count else {
                throw TeleprompterPreparationError.invalidSourceUnits
            }
            let prompt = try TeleprompterPreparationPromptBuilder.map(
                targets: targets,
                formatHint: input.source.formatHint,
                globalTargetSeconds: input.timingPlan.targetSeconds,
                localBudgetSeconds: window.localBudgetSeconds,
                weightMode: input.timingPlan.weightMode,
                pace: input.pace,
                operation: input.operation,
                readOnlyContext: makeContext(
                    for: window,
                    selection: selection,
                    maxUnits: policy.maxReadOnlyContextUnits
                ),
                maxGroupUnits: policy.maxGroupUnits
            )
            let response = try await call(prompt)
            try Task.checkCancellation()
            let output = try TeleprompterMapDecoder().decode(
                response,
                targets: targets,
                maxGroupUnits: policy.maxGroupUnits
            )
            let states = try makeBlockStates(
                output: output,
                window: window,
                sourceUnits: sourceUnits,
                pace: input.pace
            )
            guard !states.isEmpty else { throw TeleprompterPreparationError.invalidPromptResponse }
            windowStates.append(states)
            mapRequestCount += 1
            onProgress?(.init(
                phase: .mapping,
                completed: windowIndex + 1,
                total: windows.count,
                currentIndex: windowIndex
            ))
        }

        let allBlocks = windowStates.flatMap { $0 }
        let reduceBoundaries = makeReduceBoundaries(
            windowStates: windowStates,
            selection: selection
        )
        onProgress?(.init(phase: .reducing, completed: 0, total: reduceBoundaries.count))

        var mutableStates = allBlocks
        var boundaries: [TeleprompterPreparationBoundary] = []
        boundaries.reserveCapacity(reduceBoundaries.count)
        var reduceRequestCount = 0

        for (boundaryIndex, boundaryPair) in reduceBoundaries.enumerated() {
            try Task.checkCancellation()
            let left = mutableStates[boundaryPair.leftIndex]
            let right = mutableStates[boundaryPair.rightIndex]
            var boundary = TeleprompterPreparationBoundary(
                id: boundaryPair.id,
                leftBlockID: left.block.id,
                rightBlockID: right.block.id,
                state: .notApplicable
            )

            guard left.block.disposition == .speak, right.block.disposition == .speak else {
                boundaries.append(boundary)
                onProgress?(.init(
                    phase: .reducing,
                    completed: boundaryIndex + 1,
                    total: reduceBoundaries.count,
                    currentIndex: boundaryIndex
                ))
                continue
            }

            let editable = [
                TeleprompterReduceEditableBlock(id: left.block.id, revision: left.revision, text: left.block.text),
                TeleprompterReduceEditableBlock(id: right.block.id, revision: right.revision, text: right.block.text)
            ]
            let readOnly = makeReduceContext(
                for: boundaryPair,
                states: mutableStates
            )
            let prompt = try TeleprompterPreparationPromptBuilder.reduce(
                editableBlocks: editable,
                readOnlyBlocks: readOnly,
                editableBudgetSeconds: left.block.budgetSeconds + right.block.budgetSeconds,
                editableEstimatedSeconds: estimateSeconds(
                    text: left.block.text + right.block.text,
                    pace: input.pace
                ),
                pace: input.pace
            )
            reduceRequestCount += 1
            do {
                let response = try await call(prompt)
                try Task.checkCancellation()
                let output = try TeleprompterReduceDecoder().decode(
                    response,
                    editableBlocks: editable
                )
                try apply(output: output, to: &mutableStates)
                boundary.state = .checked
                boundary.reviewBlockIDs = output.reviewBlockIDs
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                boundary.state = .unchecked
                boundary.failureMessage = "boundary reduction unavailable"
            }
            boundaries.append(boundary)
            onProgress?(.init(
                phase: .reducing,
                completed: boundaryIndex + 1,
                total: reduceBoundaries.count,
                currentIndex: boundaryIndex
            ))
        }

        try Task.checkCancellation()
        onProgress?(.init(phase: .finalizing, completed: 0, total: 1))
        let draft = try finalize(
            input: input,
            selection: selection,
            states: mutableStates,
            boundaries: boundaries
        )
        let status: TeleprompterPreparationStatus
        if boundaries.contains(where: { $0.state == .unchecked }) {
            status = .boundaryUnchecked
        } else if draft.blocks.contains(where: { $0.disposition == .unresolved })
                    || boundaries.contains(where: { !$0.reviewBlockIDs.isEmpty }) {
            status = .reviewRequired
        } else {
            status = .complete
        }
        onProgress?(.init(phase: .finalizing, completed: 1, total: 1))
        return .init(
            draft: draft,
            status: status,
            mapWindows: windows,
            mapRequestCount: mapRequestCount,
            reduceRequestCount: reduceRequestCount
        )
    }
}

private extension TeleprompterPreparationPipeline {
    struct Selection {
        let units: [TeleprompterSourceUnit]
        let unitsByID: [Int: TeleprompterSourceUnit]
        let selectedIDs: [Int]
    }

    struct BlockState {
        var block: TeleprompterReadingBlock
        var sourceUnitIDs: [Int]
        var revision: Int
    }

    struct BoundaryPair {
        let id: String
        let leftIndex: Int
        let rightIndex: Int
    }

    func call(_ prompt: TeleprompterPreparationPrompt) async throws -> String {
        do {
            return try await completion(prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
    }

    func validate(_ input: TeleprompterPreparationInput) throws -> Selection {
        let units = input.sourceUnits
        guard !units.isEmpty,
              units.allSatisfy({ $0.sourceRevisionID == input.source.sourceRevisionID }),
              units.map(\.id) == Array(units.indices),
              units.map(\.ordinal) == Array(units.indices),
              units.map(\.rawText).joined().data(using: .utf8) == input.source.sourceText.data(using: .utf8) else {
            throw TeleprompterPreparationError.invalidSourceUnits
        }
        let unitsByID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
        let selectedIDs = input.selectedUnitIDs.map { $0.sorted() } ?? units.map(\.id)
        guard !selectedIDs.isEmpty,
              selectedIDs == Array(Set(selectedIDs)).sorted(),
              selectedIDs.allSatisfy({ unitsByID[$0] != nil }),
              input.timingPlan.allocations.map(\.sourceUnitID).allSatisfy({ unitsByID[$0] != nil }) else {
            throw TeleprompterPreparationError.invalidSourceUnits
        }
        guard input.timingPlan.allocations.count == units.count,
              input.timingPlan.allocations.map(\.sourceUnitID) == units.map(\.id),
              input.timingPlan.allocations.allSatisfy({ $0.budgetSeconds.isFinite && $0.budgetSeconds >= 0 }) else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }
        return Selection(units: units, unitsByID: unitsByID, selectedIDs: selectedIDs)
    }

    func makeWindows(
        selection: Selection,
        input: TeleprompterPreparationInput
    ) throws -> [TeleprompterPreparationMapWindow] {
        var windows: [TeleprompterPreparationMapWindow] = []
        var currentIDs: [Int] = []
        var currentBudgetUnits = 0

        func flush() {
            guard !currentIDs.isEmpty else { return }
            windows.append(.init(
                id: "map-\(windows.count)",
                ordinal: windows.count,
                sourceUnitIDs: currentIDs,
                localBudgetSeconds: input.timingPlan.budget(for: currentIDs)
            ))
            currentIDs.removeAll(keepingCapacity: true)
            currentBudgetUnits = 0
        }

        for (index, id) in selection.selectedIDs.enumerated() {
            let unit = selection.unitsByID[id]!
            let previousID = index > 0 ? selection.selectedIDs[index - 1] : nil
            let isNewRun = previousID.map { $0 + 1 != id } ?? false
            if isNewRun { flush() }
            guard unit.budgetUnits <= policy.maxWindowBudgetUnits else {
                throw TeleprompterPreparationError.invalidPromptResponse
            }
            let exceedsCount = currentIDs.count >= policy.maxWindowUnits
            let exceedsBudget = !currentIDs.isEmpty
                && currentBudgetUnits + unit.budgetUnits > policy.maxWindowBudgetUnits
            if exceedsCount || exceedsBudget { flush() }
            currentIDs.append(id)
            currentBudgetUnits += unit.budgetUnits
        }
        flush()
        guard !windows.isEmpty else { throw TeleprompterPreparationError.invalidSourceUnits }
        return windows
    }

    func makeContext(
        for window: TeleprompterPreparationMapWindow,
        selection: Selection,
        maxUnits: Int
    ) -> TeleprompterMapReadOnlyContext {
        guard maxUnits > 0, let first = window.sourceUnitIDs.first, let last = window.sourceUnitIDs.last else {
            return .init()
        }
        let selected = Set(selection.selectedIDs)
        var before: [TeleprompterMapContextItem] = []
        var after: [TeleprompterMapContextItem] = []
        if selected.contains(first - 1), let unit = selection.unitsByID[first - 1] {
            before.append(.init(id: unit.id, rawText: unit.rawText))
        }
        if selected.contains(last + 1), let unit = selection.unitsByID[last + 1] {
            after.append(.init(id: unit.id, rawText: unit.rawText))
        }
        return .init(hints: [], before: Array(before.prefix(maxUnits)), after: Array(after.prefix(maxUnits)))
    }

    func makeBlockStates(
        output: TeleprompterMapOutput,
        window: TeleprompterPreparationMapWindow,
        sourceUnits: [Int: TeleprompterSourceUnit],
        pace: TeleprompterPace
    ) throws -> [BlockState] {
        output.blocks.enumerated().map { offset, block in
            let IDs = window.sourceUnitIDs.filter { $0 >= block.startUnit && $0 < block.endUnit }
            guard let first = IDs.first, let last = IDs.last,
                  let firstUnit = sourceUnits[first], let lastUnit = sourceUnits[last] else {
                return nil
            }
            let rawText = IDs.compactMap { sourceUnits[$0]?.rawText }.joined()
            let text: String
            let disposition: TeleprompterBlockDisposition
            switch block.mode {
            case .speak:
                text = block.text
                disposition = .speak
            case .review:
                text = block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawText : block.text
                disposition = .unresolved
            case .omit:
                text = ""
                disposition = .unresolved
            }
            let reviewIssues = block.issues
            return BlockState(
                block: .init(
                    id: "block-\(first)-\(block.endUnit)",
                    ordinal: offset,
                    sourceRange: .init(start: firstUnit.sourceRange.start, end: lastUnit.sourceRange.end),
                    text: text,
                    rawSourceText: rawText,
                    disposition: disposition,
                    origin: .ai,
                    reviewIssues: reviewIssues,
                    budgetSeconds: window.localBudgetSeconds * Double(IDs.reduce(0) { $0 + sourceUnits[$1]!.budgetUnits })
                        / Double(max(1, window.sourceUnitIDs.reduce(0) { $0 + sourceUnits[$1]!.budgetUnits }))
                ),
                sourceUnitIDs: IDs,
                revision: 0
            )
        }.compactMap { $0 }
    }

    func makeReduceBoundaries(
        windowStates: [[BlockState]],
        selection: Selection
    ) -> [BoundaryPair] {
        guard windowStates.count > 1 else { return [] }
        var offsets: [Int] = []
        var cursor = 0
        for states in windowStates {
            offsets.append(cursor)
            cursor += states.count
        }
        var boundaries: [BoundaryPair] = []
        for index in 0..<(windowStates.count - 1) {
            guard let left = windowStates[index].last,
                  let right = windowStates[index + 1].first,
                  left.sourceUnitIDs.last.map({ $0 + 1 }) == right.sourceUnitIDs.first else {
                continue
            }
            let leftIndex = offsets[index] + windowStates[index].count - 1
            let rightIndex = offsets[index + 1]
            boundaries.append(.init(
                id: "boundary-\(left.block.id)-\(right.block.id)",
                leftIndex: leftIndex,
                rightIndex: rightIndex
            ))
        }
        return boundaries
    }

    func makeReduceContext(
        for boundary: BoundaryPair,
        states: [BlockState]
    ) -> [TeleprompterReduceEditableBlock] {
        if boundary.leftIndex > 0 {
            let state = states[boundary.leftIndex - 1]
            return [.init(id: state.block.id, revision: state.revision, text: state.block.text)]
        }
        if boundary.rightIndex + 1 < states.count {
            let state = states[boundary.rightIndex + 1]
            return [.init(id: state.block.id, revision: state.revision, text: state.block.text)]
        }
        return []
    }

    func apply(
        output: TeleprompterReduceOutput,
        to states: inout [BlockState]
    ) throws {
        let indices = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.block.id, $0.offset) })
        let patches = output.patches.compactMap { patch -> (Int, TeleprompterReducePatch)? in
            guard let index = indices[patch.blockID] else { return nil }
            return (index, patch)
        }
        guard patches.count == output.patches.count,
              patches.map(\.0).count == Set(patches.map(\.0)).count else {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
        for (index, patch) in patches {
            guard states[index].revision == patch.revision else {
                throw TeleprompterPreparationError.invalidPromptResponse
            }
        }
        for (index, patch) in patches {
            states[index].block.text = patch.text
            states[index].revision += 1
        }
    }

    func estimateSeconds(text: String, pace: TeleprompterPace) -> TimeInterval? {
        let estimate = TeleprompterDurationEstimator.estimate(text, pace: pace)
        return estimate.pointSeconds ?? (estimate.knownPartSeconds > 0 ? estimate.knownPartSeconds : nil)
    }

    func finalize(
        input: TeleprompterPreparationInput,
        selection: Selection,
        states: [BlockState],
        boundaries: [TeleprompterPreparationBoundary]
    ) throws -> TeleprompterReadingDraft {
        let covered = states.flatMap(\.sourceUnitIDs)
        guard covered == selection.selectedIDs,
              Set(states.map { $0.block.id }).count == states.count,
              states.allSatisfy({ !$0.block.rawSourceText.isEmpty || $0.block.disposition == .unresolved }) else {
            throw TeleprompterPreparationError.invalidPromptResponse
        }
        var blocks = states.map(\.block)
        for index in blocks.indices { blocks[index].ordinal = index }
        let revisions = Dictionary(uniqueKeysWithValues: states.map { ($0.block.id, $0.revision) })
        let readingText = blocks
            .filter { $0.disposition == .speak || $0.disposition == .unresolved }
            .map(\.text)
            .joined(separator: "\n")
        let durationEstimate = TeleprompterDurationEstimator.estimate(readingText, pace: input.pace)
        return .init(
            id: "draft-\(input.source.sourceRevisionID)-\(input.operation.rawValue)",
            sourceRevisionID: input.source.sourceRevisionID,
            sourceSHA256: input.source.sourceSHA256,
            targetMinutes: input.timingPlan.targetMinutes,
            targetSeconds: input.timingPlan.targetSeconds,
            budgetSeconds: input.timingPlan.budgetSeconds,
            blocks: blocks,
            revisions: revisions,
            boundaries: boundaries,
            durationEstimate: durationEstimate
        )
    }
}
