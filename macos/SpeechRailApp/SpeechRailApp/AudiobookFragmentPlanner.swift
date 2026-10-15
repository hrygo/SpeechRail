import Foundation

/// T07：合成片段规划器（连续同说话人合并至 <=240 scalars，绝不跨说话人边界，保持字节完整覆盖）。
public struct AudiobookRenderPolicy: Codable, Equatable, Hashable, Sendable {
    public var version: String
    public var targetFragmentScalars: Int
    public var maxFragmentScalars: Int
    public var defaultSpeed: Double
    public var sampleRate: Int
    public var channels: Int

    public static let standard = AudiobookRenderPolicy()

    public init(
        // v2 stores actual policy-rate PCM; v1 candidates may contain mislabeled 24 kHz WAV.
        version: String = "audiobook_render_policy_v2",
        targetFragmentScalars: Int = AudiobookLimits.targetFragmentScalars,
        maxFragmentScalars: Int = AudiobookLimits.maxFragmentScalars,
        defaultSpeed: Double = AudiobookLimits.defaultRenderSpeed,
        sampleRate: Int = AudiobookLimits.intermediateSampleRate,
        channels: Int = AudiobookLimits.intermediateChannels
    ) {
        self.version = version
        self.targetFragmentScalars = targetFragmentScalars
        self.maxFragmentScalars = maxFragmentScalars
        self.defaultSpeed = defaultSpeed
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var policyDigest: String {
        let raw = "\(version)|target:\(targetFragmentScalars)|max:\(maxFragmentScalars)|speed:\(String(format: "%.3f", defaultSpeed))|sr:\(sampleRate)|ch:\(channels)"
        return AudiobookDigest.sha256Hex(Data(raw.utf8))
    }
}

public enum AudiobookFragmentPlanningError: LocalizedError, Equatable, Sendable {
    case unresolvedUnknownSpeaker(atomID: UUID, chapterID: UUID)
    case missingVoiceBinding(roleID: UUID)
    case missingAnnotationsForChapter(chapterID: UUID)
    case atomExceedsMaximumFragmentScalars(atomID: UUID, scalarCount: Int, maxScalars: Int)

    public var errorDescription: String? {
        switch self {
        case .unresolvedUnknownSpeaker:
            return "当前章节仍存在未确认的说话人，请确认后再生成音频。"
        case .missingVoiceBinding:
            return "当前章节包含尚未绑定音色的角色。"
        case .missingAnnotationsForChapter:
            return "当前章节缺少说话人标注记录。"
        case let .atomExceedsMaximumFragmentScalars(_, count, maxScalars):
            return "单个正文切分块长度（\(count) 字符）超过片段上限（\(maxScalars) 字符）。"
        }
    }
}

public enum AudiobookFragmentPlanner {
    /// 计划接口：当提供 `source` 与 `atoms` 时校验精确 scalar 计数与全文覆盖（含格式与排除区间）。
    public static func plan(
        chapter: AudiobookChapter,
        annotations: [AudiobookAnnotation],
        bindings: [UUID: AudiobookVoiceBinding],
        policy: AudiobookRenderPolicy = .standard,
        source: AudiobookSourceIndex? = nil,
        atoms: [AudiobookTextAtom]? = nil
    ) throws -> [AudiobookFragment] {
        let chapterAnnotations = annotations
            .filter { $0.chapterID == chapter.id }
            .sorted { $0.sourceRange < $1.sourceRange }

        guard !chapterAnnotations.isEmpty else {
            throw AudiobookFragmentPlanningError.missingAnnotationsForChapter(chapterID: chapter.id)
        }

        struct ResolvedUnit {
            let atomID: UUID
            let roleID: UUID
            let sourceRange: AudiobookSourceRange
            let scalarCount: Int
        }

        var units: [ResolvedUnit] = []
        units.reserveCapacity(chapterAnnotations.count)

        for ann in chapterAnnotations {
            guard let roleID = ann.assignment.roleID else {
                throw AudiobookFragmentPlanningError.unresolvedUnknownSpeaker(
                    atomID: ann.atomID,
                    chapterID: chapter.id
                )
            }
            guard let binding = bindings[roleID], binding.isSynthesisReady else {
                throw AudiobookFragmentPlanningError.missingVoiceBinding(roleID: roleID)
            }
            let scalarCount: Int
            if let source {
                let text = try source.text(in: ann.sourceRange)
                scalarCount = text.unicodeScalars.count
            } else {
                scalarCount = max(1, Int(ann.sourceRange.byteCount))
            }
            guard scalarCount <= policy.maxFragmentScalars else {
                throw AudiobookFragmentPlanningError.atomExceedsMaximumFragmentScalars(
                    atomID: ann.atomID,
                    scalarCount: scalarCount,
                    maxScalars: policy.maxFragmentScalars
                )
            }
            units.append(
                ResolvedUnit(
                    atomID: ann.atomID,
                    roleID: roleID,
                    sourceRange: ann.sourceRange,
                    scalarCount: scalarCount
                )
            )
        }

        // Coalesce contiguous units that share the exact same speaker roleID and are contiguous or separated only by formatting atoms,
        // never exceeding policy.maxFragmentScalars and never crossing speaker boundaries.
        let formattingRanges: Set<AudiobookSourceRange> = Set(
            (atoms ?? [])
                .filter { $0.chapterID == chapter.id && $0.kind == .formatting }
                .map(\.sourceRange)
        )

        var groups: [[ResolvedUnit]] = []
        for unit in units {
            if var currentGroup = groups.popLast(),
               let lastUnit = currentGroup.last
            {
                let currentScalars = currentGroup.reduce(0) { $0 + $1.scalarCount }
                let gapRange = AudiobookSourceRange(
                    lowerBound: lastUnit.sourceRange.upperBound,
                    upperBound: unit.sourceRange.lowerBound
                )
                let isStrictlyContiguous = (lastUnit.sourceRange.upperBound == unit.sourceRange.lowerBound)
                let isFormattingBridge = !gapRange.isEmpty && formattingRanges.contains(gapRange)

                if lastUnit.roleID == unit.roleID,
                   (isStrictlyContiguous || isFormattingBridge),
                   currentScalars + unit.scalarCount <= policy.maxFragmentScalars
                {
                    currentGroup.append(unit)
                    groups.append(currentGroup)
                    continue
                }
                groups.append(currentGroup)
            }
            groups.append([unit])
        }

        let policyDigest = policy.policyDigest
        var fragments: [AudiobookFragment] = []
        fragments.reserveCapacity(groups.count)

        for (ordinal, group) in groups.enumerated() {
            let first = group[0]
            let last = group[group.count - 1]
            let roleID = first.roleID
            let range = AudiobookSourceRange(
                lowerBound: first.sourceRange.lowerBound,
                upperBound: last.sourceRange.upperBound
            )
            let atomIDs = group.map(\.atomID)
            let binding = bindings[roleID]!

            let localAssignmentCanonical = group
                .map { "\($0.sourceRange.lowerBound)-\($0.sourceRange.upperBound):\($0.roleID.uuidString)" }
                .joined(separator: ",")
            let localAssignmentDigest = AudiobookDigest.sha256Hex(Data(localAssignmentCanonical.utf8))
            let voiceBindingDigest = binding.bindingDigest
            let dependencyCanonical = [
                "frag_dep_v1",
                "\(chapter.sourceID.uuidString)",
                "\(range.lowerBound)-\(range.upperBound)",
                localAssignmentDigest,
                voiceBindingDigest,
                policyDigest
            ].joined(separator: "|")
            let dependencyDigest = AudiobookDigest.sha256Hex(Data(dependencyCanonical.utf8))

            let fragmentID = deterministicFragmentID(
                bookID: chapter.bookID,
                chapterID: chapter.id,
                sourceRange: range
            )

            fragments.append(
                AudiobookFragment(
                    id: fragmentID,
                    bookID: chapter.bookID,
                    chapterID: chapter.id,
                    ordinal: ordinal,
                    roleID: roleID,
                    sourceRange: range,
                    atomIDs: atomIDs,
                    localAssignmentDigest: localAssignmentDigest,
                    voiceBindingDigest: voiceBindingDigest,
                    policyDigest: policyDigest,
                    dependencyDigest: dependencyDigest
                )
            )
        }

        return fragments
    }

    private static func deterministicFragmentID(
        bookID: UUID,
        chapterID: UUID,
        sourceRange: AudiobookSourceRange
    ) -> UUID {
        let seed = "fragment|\(bookID.uuidString)|\(chapterID.uuidString)|\(sourceRange.lowerBound)|\(sourceRange.upperBound)"
        let hex = AudiobookDigest.sha256Hex(Data(seed.utf8))
        let chars = Array(hex.prefix(32))
        let formatted = String(chars[0..<8]) + "-"
            + String(chars[8..<12]) + "-"
            + String(chars[12..<16]) + "-"
            + String(chars[16..<20]) + "-"
            + String(chars[20..<32])
        return UUID(uuidString: formatted) ?? UUID()
    }
}
