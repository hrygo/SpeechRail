import Foundation
import SwiftUI

/// Text coverage, never speaking duration. Every non-whitespace, non-punctuation
/// Unicode scalar in the final transcript is counted once, including unknown gaps.
public struct SpeakerTextStatistics: Sendable, Equatable {
    public private(set) var speakerOrder: [String] = []
    public private(set) var totalCharacters = 0
    public private(set) var unknownCharacters = 0
    public private(set) var charactersBySpeaker: [String: Int] = [:]

    public init(lines: [TranscriptLine]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
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
}

/// Reads the complete final transcript, independently of the bounded display page.
struct SpeakerTextSharePanel: View {
    @Environment(SessionCoordinator.self) private var session
    let sessionID: String
    let names: [String: String]
    var displayOrdinals: [String: Int] = [:]
    var revision = ""
    @State private var statistics: SpeakerTextStatistics?
    @State private var loadedSessionID: String?
    @State private var failed = false

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("文本占比")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                if let statistics, loadedSessionID == sessionID {
                    let labels = statistics.speakerOrder
                    let ordinals = displayOrdinals.merging(SpeakerLabeling.displayOrdinals(for: labels)) { first, _ in first }
                    ForEach(labels, id: \.self) { label in
                        shareRow(SpeakerLabeling.chipText(label: label, displayName: names[label],
                            ordinal: ordinals[label]), share: statistics.share(for: label))
                    }
                    shareRow("未识别", share: statistics.unknownShare)
                    Text(statistics.totalCharacters == 0 ? "尚无有效文字。"
                        : "按定稿正文的有效字符计算，包含未识别文字；不代表发言时长。空白和标点不计入。")
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
            if loadedSessionID != sessionID { statistics = nil }
            failed = false
            do {
                // Coalesce the transcript and attribution receipts of one phrase.
                try await Task.sleep(for: .milliseconds(150))
                let rows = try await session.lines(sessionID: sessionID)
                let result = await Task.detached { SpeakerTextStatistics(lines: rows) }.value
                try Task.checkCancellation()
                statistics = result
                loadedSessionID = sessionID
            } catch is CancellationError {
            } catch {
                statistics = nil
                failed = true
            }
        }
    }

    private func shareRow(_ name: String, share: Double) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(name)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(share, format: .percent.precision(.fractionLength(1)))
                .monospacedDigit()
        }
        .font(SpeechRailDesignTokens.Typography.caption)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        .accessibilityElement(children: .combine)
    }
}
