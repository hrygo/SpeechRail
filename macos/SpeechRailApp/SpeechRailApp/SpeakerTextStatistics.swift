import Foundation
import SwiftUI

/// Text coverage and high-signal representative utterance extraction, never speaking duration.
/// Every non-whitespace, non-punctuation Unicode scalar in the final transcript is counted once,
/// including unknown gaps. Representative excerpts help users identify speakers without audio playback.
public struct SpeakerTextStatistics: Sendable, Equatable {
    public private(set) var speakerOrder: [String] = []
    public private(set) var totalCharacters = 0
    public private(set) var unknownCharacters = 0
    public private(set) var charactersBySpeaker: [String: Int] = [:]
    public private(set) var representativeExcerptBySpeaker: [String: String] = [:]
    public private(set) var firstTimestampBySpeaker: [String: TimeInterval] = [:]

    private static let fillerReplies: Set<String> = [
        "好", "好的", "是的", "嗯", "嗯嗯", "对", "对的", "没错", "可以", "行", "走吧", "行了",
        "收到", "明白", "知道了", "没问题", "听得到吗", "能听到吗", "喂", "你好", "大家好",
        "谢谢", "哦", "啊", "ok", "okay", "yes", "yeah", "yep", "uh", "um"
    ]

    private static let highSignalKeywords: [String] = [
        "决定", "确认", "负责", "排期", "下周", "本周", "方案", "问题", "建议", "需要",
        "目标", "上线", "交付", "同步", "推进", "结论", "风险", "优先级", "时间", "版本"
    ]

    public init(lines: [TranscriptLine]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var bestScoreBySpeaker: [String: Int] = [:]

        for line in lines where line.status == .final {
            let runs: [TranscriptSpeakerRun]
            if !line.speakerLabelIsManual, !line.attributionUnits.isEmpty,
               (try? TranscriptAttributionUnit.validated(line.attributionUnits, text: line.text)) == nil {
                // A cached whole-line summary cannot repair invalid word evidence.
                runs = [.init(text: line.text, speakerLabel: nil,
                              textStart: 0, textEnd: line.text.unicodeScalars.count)]
            } else {
                runs = line.speakerRuns
            }
            for run in runs {
                let count = run.text.unicodeScalars.filter { !separators.contains($0) }.count
                guard count > 0 else { continue }
                totalCharacters += count
                if let label = run.speakerLabel, !label.isEmpty {
                    if charactersBySpeaker[label] == nil { speakerOrder.append(label) }
                    charactersBySpeaker[label, default: 0] += count

                    if firstTimestampBySpeaker[label] == nil,
                       line.timingQuality != .unavailable,
                       let start = line.tStart,
                       start >= 0 {
                        firstTimestampBySpeaker[label] = start
                    }

                    let candidateText = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let score = Self.representativeScore(for: candidateText)
                    if score > (bestScoreBySpeaker[label] ?? 0) {
                        bestScoreBySpeaker[label] = score
                        representativeExcerptBySpeaker[label] = Self.formattedRepresentativeExcerpt(candidateText)
                    }
                } else {
                    unknownCharacters += count
                }
            }
        }
        charactersBySpeaker = charactersBySpeaker.filter { $0.value > 0 }
    }

    public func share(for speaker: String) -> Double {
        totalCharacters == 0 ? 0 : Double(charactersBySpeaker[speaker, default: 0]) / Double(totalCharacters)
    }

    public var unknownShare: Double {
        totalCharacters == 0 ? 0 : Double(unknownCharacters) / Double(totalCharacters)
    }

    public func representativeExcerpt(for speaker: String) -> String? {
        representativeExcerptBySpeaker[speaker]
    }

    public func firstTimestamp(for speaker: String) -> TimeInterval? {
        firstTimestampBySpeaker[speaker]
    }

    /// Evaluates how informative a speaker run is for visual speaker identification (without audio).
    public static func representativeScore(for text: String) -> Int {
        let stripped = CaptionParagraphAssembler.trimTrailingPunctuation(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return 0 }
        let lower = stripped.lowercased()
        if fillerReplies.contains(lower) {
            return 1
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let meaningfulScalars = stripped.unicodeScalars.filter { !separators.contains($0) }
        let count = meaningfulScalars.count
        guard count > 2 else { return 1 }

        var score = 0
        switch count {
        case 10...48:
            score += 30
        case 5...9:
            score += 15
        case 3...4:
            score += 6
        default:
            score += 22
        }

        let hasDigitOrLatin = meaningfulScalars.contains { scalar in
            CharacterSet.decimalDigits.contains(scalar)
                || (scalar.isASCII && CharacterSet.letters.contains(scalar))
        }
        if hasDigitOrLatin {
            score += 8
        }

        if highSignalKeywords.contains(where: { stripped.contains($0) }) {
            score += 6
        }
        return score
    }

    public static func formattedRepresentativeExcerpt(_ text: String, maxCharacters: Int = 46) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }
        let prefix = String(cleaned.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }
}

/// Reads the complete final transcript, independently of the bounded display page.
struct SpeakerTextSharePanel: View {
    @Environment(SessionCoordinator.self) private var session
    let sessionID: String
    let names: [String: String]
    var displayOrdinals: [String: Int] = [:]
    var revision = ""
    var onStatisticsLoaded: ((SpeakerTextStatistics?) -> Void)? = nil
    @State private var statistics: SpeakerTextStatistics?
    @State private var loadedSessionID: String?
    @State private var failed = false

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("发言字数占比")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                if let statistics, loadedSessionID == sessionID {
                    let labels = statistics.speakerOrder
                    let ordinals = displayOrdinals.merging(SpeakerLabeling.displayOrdinals(for: labels)) { first, _ in first }
                    ForEach(labels, id: \.self) { label in
                        shareRow(
                            SpeakerLabeling.chipText(label: label, displayName: names[label], ordinal: ordinals[label]),
                            characterCount: statistics.charactersBySpeaker[label, default: 0],
                            share: statistics.share(for: label),
                            isPrimary: true
                        )
                    }
                    if statistics.unknownCharacters > 0 || labels.isEmpty {
                        shareRow(
                            "未识别",
                            characterCount: statistics.unknownCharacters,
                            share: statistics.unknownShare,
                            isPrimary: false
                        )
                    }
                    Text(statistics.totalCharacters == 0 ? "尚无有效文字。"
                        : "按定稿正文的有效字符计算（共 \(statistics.totalCharacters) 字），包含未识别文字；不代表发言时长。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(failed ? "文本占比暂时无法读取。" : "正在统计文字…")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
        .task(id: "\(sessionID):\(revision)") {
            if loadedSessionID != sessionID {
                statistics = nil
                onStatisticsLoaded?(nil)
            }
            failed = false
            do {
                // Coalesce the transcript and attribution receipts of one phrase.
                try await Task.sleep(for: .milliseconds(150))
                let rows = try await session.lines(sessionID: sessionID)
                let result = await Task.detached { SpeakerTextStatistics(lines: rows) }.value
                try Task.checkCancellation()
                statistics = result
                loadedSessionID = sessionID
                onStatisticsLoaded?(result)
            } catch is CancellationError {
            } catch {
                statistics = nil
                failed = true
                onStatisticsLoaded?(nil)
            }
        }
    }

    private func shareRow(_ name: String, characterCount: Int, share: Double, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(name)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(isPrimary ? SpeechRailDesignTokens.Color.ink : SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Text("\(characterCount) 字")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .monospacedDigit()
                Text(share, format: .percent.precision(.fractionLength(1)))
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                let clamped = min(max(share, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SpeechRailDesignTokens.Color.recessedField)
                    Capsule()
                        .fill(isPrimary ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.45))
                        .frame(width: max(clamped > 0 ? 4 : 0, proxy.size.width * clamped))
                }
            }
            .frame(height: SpeechRailDesignTokens.Spacing.micro)
            .accessibilityHidden(true)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
        .accessibilityElement(children: .combine)
    }
}
