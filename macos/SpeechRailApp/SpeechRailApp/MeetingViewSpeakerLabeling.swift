import SwiftUI

// `MeetingView` 的会中标注说话人面板：录制中边走边改显示名与归属。
// 纯搬移自主文件；面板由主文件的 `body` 以 sheet 呈现。

// MARK: - 录制中的「标注说话人」面板

/// 稿 `screenMeetingRecording` 表头那颗按钮落成的面板：录制中也能打开，边走边改。
///
/// 它**不是**第二个实现：打开的就是会后右栏那块 `SpeakerLabelingPanel`，只是 `isLive` 为真
/// （文案从"说话人"变成"标注说话人"，并且说清"改的是归属，正文不动"）。
/// 单独一个 sheet，是因为录制中主区和右栏都已经被转录与会议占满——把这块内容塞进任何一栏
/// 都会挤掉正在看的转录。
struct SpeakerLabelingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let labeling: SpeakerLabeling
    let sessionID: String?
    let transcriptRevision: UInt64
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SpeechRailSheetHeader(
                title: "标注说话人",
                subtitle: "改的是说话人的名字与归属，记录正文一个字都不动。",
                isCompact: true,
                onClose: { close() }
            )
            if let sessionID {
                ScrollView(.vertical) {
                    SpeakerLabelingPanel(labeling: labeling, sessionID: sessionID, isLive: true, transcriptRevision: transcriptRevision)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            HStack {
                Spacer(minLength: 0)
                Button("完成") { close() }
                    .speechRailButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(
            width: SpeechRailDesignTokens.Layout.Sheet.popoverUtilityWidth,
            alignment: .topLeading
        )
        .frame(
            minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight,
            maxHeight: SpeechRailDesignTokens.Layout.Sheet.popoverUtilityMaxHeight
        )
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func close() {
        onClose()
        dismiss()
    }
}
