import CryptoKit
import Foundation

/// Errors raised by the UI-independent preparation pipeline.
public enum TeleprompterPreparationError: Error, Equatable, LocalizedError, Sendable {
    case emptySource
    case invalidUTF8
    case containsNUL
    case unsupportedImport
    case byteLimitExceeded
    case sourceUnitLimitExceeded
    case referenceDurationExceeded
    case invalidTargetMinutes
    case invalidSourceUnits
    case invalidTimingPlan
    case invalidPromptResponse

    public var errorDescription: String? {
        switch self {
        case .emptySource: "稿件没有可朗读内容"
        case .invalidUTF8: "文件不是有效的 UTF-8 文本"
        case .containsNUL: "稿件包含不支持的 NUL 字符"
        case .unsupportedImport: "请选择 TXT 或 Markdown 文本"
        case .byteLimitExceeded: "稿件超过 1 MiB 大小限制"
        case .sourceUnitLimitExceeded: "稿件分片数量超过限制"
        case .referenceDurationExceeded: "稿件超过约 2 小时的导入容量限制"
        case .invalidTargetMinutes: "目标时长必须是 1–120 分钟的整数"
        case .invalidSourceUnits: "稿件分片无法无损恢复"
        case .invalidTimingPlan: "无法为这份稿件建立时间预算"
        case .invalidPromptResponse: "AI 返回的结构化结果无法使用"
        }
    }
}

public enum TeleprompterSourceFormatHint: String, Codable, Equatable, Sendable {
    case plaintext
    case markdown
    case unknown
}

public struct TeleprompterImportLimits: Codable, Equatable, Sendable {
    public let maxBytes: Int
    public let maxSourceUnits: Int
    public let maxReferenceSeconds: TimeInterval

    public init(
        maxBytes: Int = 1_048_576,
        maxSourceUnits: Int = 20_000,
        maxReferenceSeconds: TimeInterval = 7_200
    ) {
        self.maxBytes = maxBytes
        self.maxSourceUnits = maxSourceUnits
        self.maxReferenceSeconds = maxReferenceSeconds
    }
}

public struct TeleprompterImportedSource: Equatable, Sendable {
    public let sourceRevisionID: String
    public let sourceText: String
    public let formatHint: TeleprompterSourceFormatHint
    public let hasBOM: Bool
    public let originalUTF8Data: Data
    public let sourceSHA256: String
    public let builderVersion: String
    public let referenceSeconds: TimeInterval

    public init(
        sourceRevisionID: String,
        sourceText: String,
        formatHint: TeleprompterSourceFormatHint,
        hasBOM: Bool,
        originalUTF8Data: Data,
        sourceSHA256: String,
        builderVersion: String = TeleprompterSourceUnitBuilder.version,
        referenceSeconds: TimeInterval
    ) {
        self.sourceRevisionID = sourceRevisionID
        self.sourceText = sourceText
        self.formatHint = formatHint
        self.hasBOM = hasBOM
        self.originalUTF8Data = originalUTF8Data
        self.sourceSHA256 = sourceSHA256
        self.builderVersion = builderVersion
        self.referenceSeconds = referenceSeconds
    }
}

public enum TeleprompterSourceImporter {
    public static func load(
        from url: URL,
        limits: TeleprompterImportLimits = .init()
    ) throws -> TeleprompterImportedSource {
        let extensionName = url.pathExtension.isEmpty ? nil : url.pathExtension
        return try importData(Data(contentsOf: url), fileExtension: extensionName, limits: limits)
    }

    public static func importData(
        _ data: Data,
        fileExtension: String? = nil,
        limits: TeleprompterImportLimits = .init()
    ) throws -> TeleprompterImportedSource {
        guard data.count <= limits.maxBytes else { throw TeleprompterPreparationError.byteLimitExceeded }

        let formatHint: TeleprompterSourceFormatHint
        if let fileExtension {
            switch fileExtension.lowercased() {
            case "txt": formatHint = .plaintext
            case "md", "markdown": formatHint = .markdown
            default: throw TeleprompterPreparationError.unsupportedImport
            }
        } else {
            formatHint = .unknown
        }

        let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hasBOM ? data.dropFirst(3) : data[...]
        guard let sourceText = String(data: Data(body), encoding: .utf8) else {
            throw TeleprompterPreparationError.invalidUTF8
        }
        guard !sourceText.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TeleprompterPreparationError.containsNUL
        }
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeleprompterPreparationError.emptySource
        }

        let referenceSeconds = TeleprompterDurationEstimator.referenceSeconds(for: sourceText)
        guard referenceSeconds <= limits.maxReferenceSeconds else {
            throw TeleprompterPreparationError.referenceDurationExceeded
        }

        let digest = SHA256.hash(data: Data(body))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return TeleprompterImportedSource(
            sourceRevisionID: "source-\(hash.prefix(16))",
            sourceText: sourceText,
            formatHint: formatHint,
            hasBOM: hasBOM,
            originalUTF8Data: data,
            sourceSHA256: hash,
            referenceSeconds: referenceSeconds
        )
    }
}

public struct TeleprompterSourceUnit: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let ordinal: Int
    public let sourceRevisionID: String
    public let sourceRange: TeleprompterSourceRange
    public let rawText: String
    public let continuation: Bool
    public let budgetUnits: Int

    public init(
        id: Int,
        ordinal: Int,
        sourceRevisionID: String,
        sourceRange: TeleprompterSourceRange,
        rawText: String,
        continuation: Bool,
        budgetUnits: Int
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceRevisionID = sourceRevisionID
        self.sourceRange = sourceRange
        self.rawText = rawText
        self.continuation = continuation
        self.budgetUnits = budgetUnits
    }
}

public struct TeleprompterSourceUnitBuilder: Sendable {
    public static let version = "source-unit-builder.v1"
    public let maxBudgetUnits: Int

    public init(maxBudgetUnits: Int = 600) {
        self.maxBudgetUnits = max(1, maxBudgetUnits)
    }

    public func build(_ source: TeleprompterImportedSource) throws -> [TeleprompterSourceUnit] {
        let text = source.sourceText
        let characters = Array(text)
        guard !characters.isEmpty else { throw TeleprompterPreparationError.emptySource }

        var boundaries = Array(text.indices)
        boundaries.append(text.endIndex)
        var prefixBytes = [0]
        prefixBytes.reserveCapacity(characters.count + 1)
        for character in characters {
            prefixBytes.append(prefixBytes[prefixBytes.count - 1] + String(character).utf8.count)
        }

        var units: [TeleprompterSourceUnit] = []
        var start = 0
        while start < characters.count {
            var hardEnd = start + 1
            while hardEnd <= characters.count,
                  prefixBytes[hardEnd] - prefixBytes[start] <= maxBudgetUnits {
                hardEnd += 1
            }
            hardEnd -= 1
            guard hardEnd > start else { throw TeleprompterPreparationError.invalidSourceUnits }

            let end: Int
            if hardEnd == characters.count {
                end = hardEnd
            } else {
                end = preferredEnd(in: characters, start: start, hardEnd: hardEnd)
            }

            let startIndex = boundaries[start]
            let endIndex = boundaries[end]
            let rawText = String(text[startIndex..<endIndex])
            let nsRange = NSRange(startIndex..<endIndex, in: text)
            guard nsRange.length > 0 else { throw TeleprompterPreparationError.invalidSourceUnits }

            units.append(
                TeleprompterSourceUnit(
                    id: units.count,
                    ordinal: units.count,
                    sourceRevisionID: source.sourceRevisionID,
                    sourceRange: TeleprompterSourceRange(start: nsRange.location, end: nsRange.location + nsRange.length),
                    rawText: rawText,
                    continuation: start > 0 && !isWhitespace(characters[start - 1]),
                    budgetUnits: max(1, rawText.utf8.count)
                )
            )
            start = end

            guard units.count <= 20_000 else {
                throw TeleprompterPreparationError.sourceUnitLimitExceeded
            }
        }

        guard units.map(\.rawText).joined().data(using: .utf8)
                == text.data(using: .utf8) else {
            throw TeleprompterPreparationError.invalidSourceUnits
        }
        return units
    }

    private func preferredEnd(in characters: [Character], start: Int, hardEnd: Int) -> Int {
        guard hardEnd > start + 1 else { return hardEnd }
        for end in stride(from: hardEnd, through: start + 1, by: -1) {
            let previous = characters[end - 1]
            if isSemanticBoundary(previous) {
                return end
            }
        }
        return hardEnd
    }

    private func isSemanticBoundary(_ character: Character) -> Bool {
        let value = String(character)
        return value == "\n" || value == "\r" || value == "。" || value == "！" || value == "？"
            || value == "." || value == "!" || value == "?" || value == ";" || value == "；"
            || isWhitespace(character)
    }

    private func isWhitespace(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }
}

public struct TeleprompterDurationEstimate: Codable, Equatable, Sendable {
    public let pointSeconds: TimeInterval?
    public let rangeSeconds: ClosedRange<TimeInterval>?
    public let knownPartSeconds: TimeInterval
    public let uncertaintyReasons: [String]

    public init(
        pointSeconds: TimeInterval?,
        rangeSeconds: ClosedRange<TimeInterval>?,
        knownPartSeconds: TimeInterval,
        uncertaintyReasons: [String] = []
    ) {
        self.pointSeconds = pointSeconds
        self.rangeSeconds = rangeSeconds
        self.knownPartSeconds = knownPartSeconds
        self.uncertaintyReasons = uncertaintyReasons
    }

    public var isCertain: Bool { pointSeconds != nil && uncertaintyReasons.isEmpty }
}

public enum TeleprompterDurationEstimator {
    public static func estimate(
        _ text: String,
        pace: TeleprompterPace = .natural,
        calibrationFactor: Double = 1
    ) -> TeleprompterDurationEstimate {
        let metrics = metrics(in: text)
        let knownPartSeconds = 60 * (
            Double(metrics.hanCount) / pace.cjkUnitsPerMinute
                + Double(metrics.latinWordCount) / pace.latinWordsPerMinute
        ) * calibrationFactor

        guard metrics.uncertaintyReasons.isEmpty else {
            return TeleprompterDurationEstimate(
                pointSeconds: nil,
                rangeSeconds: nil,
                knownPartSeconds: knownPartSeconds,
                uncertaintyReasons: metrics.uncertaintyReasons
            )
        }
        let lower = knownPartSeconds * 0.8
        let upper = knownPartSeconds * 1.25
        return TeleprompterDurationEstimate(
            pointSeconds: knownPartSeconds,
            rangeSeconds: lower...upper,
            knownPartSeconds: knownPartSeconds
        )
    }

    public static func referenceSeconds(for text: String) -> TimeInterval {
        let metrics = metrics(in: text)
        return 60 * (
            Double(metrics.hanCount) / 250
                + Double(metrics.latinWordCount) / 160
        )
    }

    public static func metrics(in text: String) -> (hanCount: Int, latinWordCount: Int, uncertaintyReasons: [String]) {
        var hanCount = 0
        var latinWordCount = 0
        var inLatinWord = false
        var reasons = Set<String>()
        var hasDigit = false
        var hasURLMarker = false

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if isHan(value) {
                hanCount += 1
                inLatinWord = false
            } else if value < 128 && CharacterSet.letters.contains(scalar) {
                if !inLatinWord { latinWordCount += 1 }
                inLatinWord = true
            } else if CharacterSet.decimalDigits.contains(scalar) {
                hasDigit = true
                inLatinWord = false
            } else if CharacterSet.letters.contains(scalar) {
                reasons.insert("nonLatinLanguage")
                inLatinWord = false
            } else {
                if scalar == ":" || scalar == "/" { hasURLMarker = true }
                inLatinWord = false
            }
        }

        if hasDigit || hasURLMarker { reasons.insert("unresolvedPronunciation") }
        return (hanCount, latinWordCount, reasons.sorted())
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
    }
}

public enum TeleprompterTimingWeightMode: String, Codable, Equatable, Sendable {
    case estimatedDuration
    case proxyCharacters
}

public struct TeleprompterTimingAllocation: Codable, Equatable, Sendable {
    public let sourceUnitID: Int
    public let weight: Double
    public let budgetSeconds: TimeInterval

    public init(sourceUnitID: Int, weight: Double, budgetSeconds: TimeInterval) {
        self.sourceUnitID = sourceUnitID
        self.weight = weight
        self.budgetSeconds = budgetSeconds
    }
}

public struct TeleprompterTimingPlan: Codable, Equatable, Sendable {
    public let targetMinutes: Int
    public let targetSeconds: TimeInterval
    public let budgetSeconds: TimeInterval
    public let weightMode: TeleprompterTimingWeightMode
    public let allocations: [TeleprompterTimingAllocation]

    public init(
        targetMinutes: Int,
        targetSeconds: TimeInterval,
        budgetSeconds: TimeInterval,
        weightMode: TeleprompterTimingWeightMode,
        allocations: [TeleprompterTimingAllocation]
    ) {
        self.targetMinutes = targetMinutes
        self.targetSeconds = targetSeconds
        self.budgetSeconds = budgetSeconds
        self.weightMode = weightMode
        self.allocations = allocations
    }

    public func budget(for sourceUnitIDs: [Int]) -> TimeInterval {
        let ids = Set(sourceUnitIDs)
        return allocations.reduce(0) { partial, allocation in
            partial + (ids.contains(allocation.sourceUnitID) ? allocation.budgetSeconds : 0)
        }
    }
}

public enum TeleprompterTimingPlanner {
    public static func validateTargetMinutes(_ minutes: Int) throws -> Int {
        guard (TeleprompterTimingPolicy.minimumTargetMinutes...TeleprompterTimingPolicy.maximumTargetMinutes)
            .contains(minutes) else {
            throw TeleprompterPreparationError.invalidTargetMinutes
        }
        return minutes * 60
    }

    public static func validateTargetMinutes(_ minutes: Double) throws -> Int {
        guard minutes.isFinite, minutes.rounded() == minutes else {
            throw TeleprompterPreparationError.invalidTargetMinutes
        }
        return try validateTargetMinutes(Int(minutes))
    }

    public static func plan(
        sourceUnits: [TeleprompterSourceUnit],
        estimates: [TimeInterval?],
        targetMinutes: Int
    ) throws -> TeleprompterTimingPlan {
        let targetSeconds = try validateTargetMinutes(targetMinutes)
        guard !sourceUnits.isEmpty, estimates.count == sourceUnits.count else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }

        let allEstimated = estimates.allSatisfy { value in
            guard let value else { return false }
            return value.isFinite && value >= 0
        }
        let mode: TeleprompterTimingWeightMode = allEstimated ? .estimatedDuration : .proxyCharacters
        let rawWeights = sourceUnits.enumerated().map { index, unit in
            let weight: Double
            switch mode {
            case .estimatedDuration:
                weight = max(0.001, estimates[index] ?? 0.001)
            case .proxyCharacters:
                weight = Double(max(1, unit.rawText.filter { !$0.isWhitespace }.count))
            }
            return (unit.id, weight)
        }
        let totalWeight = rawWeights.reduce(0) { $0 + $1.1 }
        guard totalWeight.isFinite, totalWeight > 0 else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }

        let budgetSeconds = Double(targetSeconds) * TeleprompterTimingPolicy.budgetRatio
        var allocations: [TeleprompterTimingAllocation] = []
        allocations.reserveCapacity(rawWeights.count)
        var assigned = 0.0
        for (index, item) in rawWeights.enumerated() {
            let budget: Double
            if index == rawWeights.index(before: rawWeights.endIndex) {
                budget = budgetSeconds - assigned
            } else {
                budget = budgetSeconds * item.1 / totalWeight
            }
            assigned += budget
            allocations.append(.init(sourceUnitID: item.0, weight: item.1, budgetSeconds: budget))
        }

        guard abs(assigned - budgetSeconds) <= 0.001 else {
            throw TeleprompterPreparationError.invalidTimingPlan
        }
        return TeleprompterTimingPlan(
            targetMinutes: targetMinutes,
            targetSeconds: Double(targetSeconds),
            budgetSeconds: budgetSeconds,
            weightMode: mode,
            allocations: allocations
        )
    }
}
