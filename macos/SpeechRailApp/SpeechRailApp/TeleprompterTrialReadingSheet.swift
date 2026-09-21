import SwiftUI

/// 计时试读 Sheet。
///
/// 遵循 `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` §10.5：
/// - 用户选择一段代表性正文，进行 60–90 秒出声试读；
/// - 纯本地计算，无须麦克风录音，音频不落盘；
/// - 样本不足 30 秒、未读完或中途重来不产生校准；
/// - 计算语速校准系数 k = sampleActual / sampleBaseEstimate（有效范围 0.5–2.0）；
/// - 采用校准为显式动作，用于更新当前会话的朗读节奏预测。
public struct TeleprompterTrialReadingSheet: View {
    @Bindable var session: TeleprompterSession
    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var elapsedSeconds: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var trialResult: TeleprompterTrialReadingResult?
    @State private var guidanceMessage: String?
    @State private var sampleText: String = ""

    public init(session: TeleprompterSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            header
            sampleScriptSection
            timerAndControls
            if let trialResult {
                resultBanner(trialResult)
            } else if let guidanceMessage {
                guidanceNotice(guidanceMessage)
            }
            Spacer(minLength: 0)
            footerActions
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(
            width: SpeechRailDesignTokens.Teleprompter.trialReadingSheetWidth,
            height: SpeechRailDesignTokens.Teleprompter.trialReadingSheetHeight
        )
        .onAppear {
            prepareSampleText()
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - 头部说明

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("计时试读")
                    .font(SpeechRailDesignTokens.Typography.display)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text("大声朗读一段代表性文字（建议 60–90 秒），系统将测定你的个人语速并校准预测。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                SpeechRailButtonIcon(.close, size: SpeechRailDesignTokens.Icon.buttonIconSize)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        width: SpeechRailDesignTokens.Control.iconButtonSize,
                        height: SpeechRailDesignTokens.Control.iconButtonSize
                    )
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .accessibilityLabel("关闭")
        }
    }

    // MARK: - 试读样本正文

    private var sampleScriptSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Text("试读样本（约 \(sampleMetrics.totalUnits) 字/词）")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
                Text("基准预计用时：\(baseEstimateSeconds.map(formatSeconds) ?? "暂不可估")")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }

            ScrollView {
                Text(sampleText)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpeechRailDesignTokens.Spacing.sm)
            }
            .frame(height: 140)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
        }
    }

    // MARK: - 计时与控制

    private var timerAndControls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            // 等宽大数字计时器
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 20))
                    .foregroundStyle(isRunning ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkSecondary)

                Text(formatSeconds(elapsedSeconds))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(
                SpeechRailDesignTokens.Color.inputField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )

            if !isRunning {
                Button {
                    startTimer()
                } label: {
                    Label(elapsedSeconds == 0 ? "开始试读" : "重新试读", systemImage: "play.fill")
                }
                .speechRailButton(.primary)
                .controlSize(.large)
            } else {
                Button {
                    finishTrial()
                } label: {
                    Label("我读完了", systemImage: "checkmark.circle.fill")
                }
                .speechRailButton(.primary)
                .controlSize(.large)

                Button("放弃") {
                    stopTimer()
                    elapsedSeconds = 0
                    guidanceMessage = nil
                }
                .speechRailButton(.secondary)
                .controlSize(.large)
            }
        }
    }

    // MARK: - 结果展示

    @ViewBuilder
    private func resultBanner(_ result: TeleprompterTrialReadingResult) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: result.isWithinValidRange ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(result.isWithinValidRange ? SpeechRailDesignTokens.Color.ready : SpeechRailDesignTokens.Color.attention)

                Text(result.isWithinValidRange ? "语速测定成功" : "语速偏离基准过大")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Spacer()

                Text("校准倍率：\(String(format: "%.2fx", result.calibrationFactor))")
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            if result.isWithinValidRange {
                let wpm = Int(round(session.pace.cjkUnitsPerMinute / result.calibrationFactor))
                Text("你的实际朗读语速约为 \(wpm) 字/分钟。采用后，整份提词稿的时长预测将以此倍率进行个性化校准。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } else {
                Text("测定倍率超出 0.5–2.0 倍有效范围，这通常是因为试读中断或阅读节奏异常，建议重新测试。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(
                    result.isWithinValidRange ? SpeechRailDesignTokens.Color.ready.opacity(0.3) : SpeechRailDesignTokens.Color.attention.opacity(0.3),
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
        )
    }

    private func guidanceNotice(_ text: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)

            Text(text)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
    }

    // MARK: - 底部操作栏

    private var footerActions: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .speechRailButton(.secondary)

            Spacer()

            if let result = trialResult, result.isWithinValidRange {
                Button("采用此校准") {
                    session.applyTrialCalibration(k: result.calibrationFactor)
                    dismiss()
                }
                .speechRailButton(.primary)
            }
        }
    }

    // MARK: - 业务与计时辅助

    private var sampleMetrics: TeleprompterTimingPolicy.TextMetrics {
        TeleprompterTimingPolicy.countMetrics(in: sampleText)
    }

    private var baseEstimateSeconds: TimeInterval? {
        let est = TeleprompterTimingPolicy.estimateDuration(
            metrics: sampleMetrics,
            pace: session.pace,
            calibrationFactor: 1.0
        )
        return est.pointSeconds
    }

    private func prepareSampleText() {
        let raw = session.document?.sourceText ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sampleText = "SpeechRail 是面向 Apple Silicon Mac 的本地语音服务。它支持实时的语音识别与语音合成，帮助创作者在视频播客、直播与教学中获得自然的朗读体验。通过实测语速校准，提词器可以更精确地预测你的开讲节奏，让你游刃有余。"
        } else {
            // 取前 350 字作为代表性片段
            sampleText = String(trimmed.prefix(350))
        }
    }

    private func startTimer() {
        stopTimer()
        elapsedSeconds = 0
        trialResult = nil
        guidanceMessage = nil
        isRunning = true
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await MainActor.run {
                    if isRunning {
                        elapsedSeconds += 0.1
                    }
                }
            }
        }
    }

    private func finishTrial() {
        isRunning = false
        stopTimer()

        guard elapsedSeconds >= TeleprompterTimingPolicy.minimumTrialDurationSeconds else {
            guidanceMessage = "试读时间不足 \(Int(TeleprompterTimingPolicy.minimumTrialDurationSeconds)) 秒，样本过短无法获得稳定语速，建议重新试读。"
            trialResult = nil
            return
        }

        guard let baseEstimateSeconds else {
            guidanceMessage = "这段文字含数字、网址或暂时无法确定读法的内容，请换一段纯中英文正文再试读。"
            trialResult = nil
            return
        }

        let k = elapsedSeconds / max(1, baseEstimateSeconds)
        trialResult = TeleprompterTrialReadingResult(
            durationSeconds: elapsedSeconds,
            baseEstimateSeconds: baseEstimateSeconds,
            calibrationFactor: k,
            isAdopted: false
        )
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
