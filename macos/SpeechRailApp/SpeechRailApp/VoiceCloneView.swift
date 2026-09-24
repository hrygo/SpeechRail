import AVFoundation
import AppKit
import SwiftUI

/// 音色克隆：读一段提词稿，用用户自己的声音注册一个可复用的音色。
///
/// 四步在同一页里走完（选稿 → 录制 → 回听与核对 → 注册），因为每一步都是「这段录音能不能用」
/// 的证据链：把录制与回听从页面里拆出去，用户就只剩一个「上传文件」按钮，
/// 而这一页真正要回答的是「我读得对不对」（REDESIGN-SPEC §13.2）。
public struct VoiceCloneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 开发者详情是全 App 的一个偏好（View ▸ ⌘⌥I），与其余七页同一条开关。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @SceneStorage("speechrail.voiceClone.promptID") private var promptID = ""
    /// 自己写的那一段稿件（不覆盖官方提词稿：选了「自己写」才用这个值）。
    @SceneStorage("speechrail.voiceClone.customScript") private var customScript = ""
    @SceneStorage("speechrail.voiceClone.spokenText") private var spokenText = ""
    @SceneStorage("speechrail.voiceClone.voiceName") private var voiceName = ""
    @State private var isPlayingTake = false
    @State private var didAdoptScriptForSpokenText = false
    @State private var inputDeviceName: String?
    @FocusState private var isSpokenTextFocused: Bool

    public init() {}

    private static let customPromptID = "custom"

    public var body: some View {
        PageScaffold(route: .voiceClone) {
            scriptCard
            recordCard
            if model.cloneRecordingAudio != nil {
                reviewCard
                registerCard
            }
            feedback
        }
        // 这一页没有头部动作：录制与注册是页面里的主按钮，⌘R 留给「重新读取提词稿」。
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取提词稿") {
                Task { await model.refreshClonePrompts() }
            }
        )
        .inspector(isPresented: $showInspector) { inspector }
        .task {
            if model.clonePromptLoadState == .unknown {
                await model.refreshClonePrompts()
            }
            adoptDefaultPrompt()
            inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        }
        .onChange(of: model.clonePrompts) { _, _ in adoptDefaultPrompt() }
        .onChange(of: model.recording.isRecording) { _, isRecording in
            if !isRecording { finishRecording() }
        }
        .onChange(of: model.isAudioPlaying) { _, isPlaying in
            if !isPlaying { isPlayingTake = false }
        }
        .onDisappear {
            model.stopAudio()
            isPlayingTake = false
            model.recording.discard()
            spokenText = ""
            didAdoptScriptForSpokenText = false
        }
    }

    // MARK: - 1. 提词稿

    private var selectedPrompt: ClonePrompt? {
        model.clonePrompts.first { $0.id == promptID }
    }

    private var isCustomScript: Bool {
        selectedPrompt == nil
    }

    /// 页面上真正要读的那一段：官方提词稿，或用户自己写的那一段。
    private var scriptText: String {
        selectedPrompt?.script ?? customScript
    }

    private var scriptCard: some View {
        CardSurface {
            CardHead(title: "提词稿", detail: nil) {
                Text(durationGuidance)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
            }
            Divider()
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                promptOptions
                scriptBody
                scriptTips
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var durationGuidance: String {
        let minimum = Int(SpeechRailDesignTokens.VoiceClone.minimumSeconds)
        let target = Int(SpeechRailDesignTokens.VoiceClone.targetSeconds)
        let maximum = Int(SpeechRailDesignTokens.VoiceClone.Contract.maximumSeconds)
        return "建议朗读 \(minimum)–\(target) 秒；服务接受 2–\(maximum) 秒。"
    }

    private var promptOptions: some View {
        // 稿这一行是「放不下就换行」（`wrap: true`），不是横向滚动：五个选项里只要有一个
        // 被藏在滚动区外，用户就不知道还有别的提词稿可选，而「有没有别的稿子」正是他此刻的问题。
        WrapHStack(spacing: SpeechRailDesignTokens.Chip.spacing) {
            ForEach(model.clonePrompts) { prompt in
                promptOption(title: prompt.title, isSelected: prompt.id == promptID) {
                    selectPrompt(prompt)
                }
            }
            promptOption(title: "自己写一段", isSelected: isCustomScript) {
                selectCustomScript()
            }
        }
    }

    private func promptOption(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    isSelected
                        ? SpeechRailDesignTokens.Color.rail
                        : SpeechRailDesignTokens.Color.inkSecondary
                )
                .padding(.horizontal, SpeechRailDesignTokens.Chip.insetX)
                .padding(.vertical, SpeechRailDesignTokens.Chip.insetY + 1)
                .background {
                    // 选中态同时用底色与描边两处表示：只靠颜色深浅，色觉障碍下
                    // 与未选中读不出区别（§9 无障碍）。
                    Capsule()
                        .fill(
                            isSelected
                                ? SpeechRailDesignTokens.Surface.selectionTint
                                : SpeechRailDesignTokens.Color.field
                        )
                }
                .overlay {
                    Capsule().stroke(
                        isSelected
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.separator,
                        lineWidth: SpeechRailDesignTokens.Chip.borderWidth
                    )
                }
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var scriptBody: some View {
        // 五个选项（四段官方稿 + 自己写一段）共用**同一个外框**：高度、内边距、正文原点
        // 三样都必须逐点相同。
        //
        // 高度跟着稿子走的话，每换一次稿整张卡片就跳一次，用户正盯着这一块读，页面却在动；
        // 内边距不统一则是 2026-09-16 的第二次复核「我自己输入的文本框和其他几个高度有一点
        // 差异」——当时编辑器走 `Spacing.xs`(8) 内边距、只读稿走 `Spacing.md`(16)，两种形态
        // 外框虽然都是 112，但**正文顶沿差 8pt、左沿差 3pt**（离屏实测：`TextEditor` 背后的
        // `PlatformTextView` 是 `textContainerInset = (0, 0)`、`lineFragmentPadding = 5`，
        // 所以正文位置就是内边距本身），切一个 tab 正文就跳一次。
        //
        // 现在两形态都用 `Spacing.md`，并把这层固定的 `.frame(height:)` 套在**两种形态之外**：
        // 外框高度不再是「内层定高 + 内外边距恰好抵平」推出来的巧合，而是一处写死的事实。
        Group {
            if isCustomScript {
                TextEditor(text: $customScript)
                    .font(SpeechRailDesignTokens.Typography.promptScript)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // 左内边距减掉原生编辑器自带的 5pt 行片段内边距，正文左沿才与只读稿同一条竖线。
                    .padding(
                        .leading,
                        SpeechRailDesignTokens.Spacing.md
                            - SpeechRailDesignTokens.VoiceClone.editorLineFragmentPadding
                    )
                    .padding(.trailing, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
                    .speechRailRecessedSlot()
                    .accessibilityLabel("自己写的朗读文本")
            } else {
                Text(scriptText)
                    // 朗读时眼睛只看这一行：它是这一页唯一的大字对象。
                    .font(SpeechRailDesignTokens.Typography.promptScript)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(SpeechRailDesignTokens.VoiceClone.scriptMaximumLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .speechRailField()
                    .accessibilityLabel("朗读文本")
            }
        }
        .frame(height: SpeechRailDesignTokens.VoiceClone.scriptBodyHeight)
    }

    @ViewBuilder
    private var scriptTips: some View {
        if let prompt = selectedPrompt, !prompt.tips.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .accessibilityHidden(true)
                Text(prompt.tips)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
    }

    // MARK: - 2. 录制

    private var recordCard: some View {
        CardSurface {
            // 稿 `recordHead`：标题 → 状态胶囊 → 空档 → 设备名。设备名是这一页唯一一处
            // 「声音从哪来」的事实，和状态同一行读完，不必再单独占一行。
            CardHead(title: "录制", detail: nil, accessory: deviceLine) {
                StatusPill(tone: recordTone, label: recordToneLabel)
            }
            Divider()
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    recordButton
                    VoiceLevelMeter(
                        level: model.recording.isRecording ? model.recording.level : 0,
                        isActive: model.recording.isRecording
                    )
                    Text(formattedElapsed)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium.monospacedDigit())
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .frame(
                            width: SpeechRailDesignTokens.VoiceClone.timerWidth,
                            alignment: .trailing
                        )
                        .accessibilityLabel("已录制 \(formattedElapsed)")
                }
                preparationHint
                signalHint
                Text("录音只用于这次注册：收下后立刻删除临时文件，注册成功后内存里的原始录音也一并放掉。")
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 准备麦克风时的一行说明。
    ///
    /// 首次采集要走一次 CoreAudio 冷启动（实测最坏一次 36 秒，见 `VoiceRecordingController`
    /// 的类型注释）：这段时间里用户已经按了按钮、却什么都还没发生，所以必须有一句话解释
    /// 「在等什么」和「不想等怎么办」，而不是让按钮旁边空着。
    @ViewBuilder
    private var preparationHint: some View {
        if model.recording.isPreparing {
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(
                    model.recording.preparationIsSlow
                        ? "麦克风还在准备（首次启动可能要几十秒）；不想等就再按一下左侧按钮取消。"
                        : "正在准备麦克风…"
                )
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 录了几秒仍然没有任何输入信号：把「我们没收到声音」直说出来。
    ///
    /// 2026-09-16 用户反馈「录音时声波不动、没有声音」——那一次实测的根因在系统侧
    /// （录音文件整段样点全 0；同一时刻 ffmpeg 走 AVCapture 也是全 0），而界面当时
    /// 只会「电平条一直不亮」：用户看不出是应用坏了、麦克风选错了，还是设备被静音了。
    /// 这条提示不改录音行为，只负责在 4 秒内把结论给出来（`VoiceRecordingController.hasSignal`）。
    @ViewBuilder
    private var signalHint: some View {
        if model.recording.isRecording,
           !model.recording.hasSignal,
           model.recording.elapsed >= SpeechRailDesignTokens.VoiceClone.silenceHintSeconds {
            HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .accessibilityHidden(true)
                Text("麦克风没有收到声音：确认系统输入设备选的是你在用的那支麦克风、输入音量不是 0，并且没有被静音。")
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            .accessibilityElement(children: .combine)
        }
    }

    private var recordTone: StatusTone {
        if model.recording.permissionDenied { return .attention }
        if model.recording.isPreparing { return .attention }
        // 稿把「录音中」画成 Attention（橙）：红色留给按钮本身那个「停」的动作，
        // 一个状态里出现两处红，读起来像出了错。
        if model.recording.isRecording { return .attention }
        if model.cloneRecordingAudio != nil { return .healthy }
        return .neutral
    }

    private var recordToneLabel: String {
        if model.recording.permissionDenied { return "没有麦克风权限" }
        if model.recording.isPreparing { return "正在准备麦克风" }
        if model.recording.isRecording { return "录音中" }
        if model.cloneRecordingAudio != nil { return "已录好" }
        return "还没开始"
    }

    private var deviceLine: String {
        let device = inputDeviceName ?? "未找到输入设备"
        return "\(device) · 48 kHz 单声道"
    }

    private var formattedElapsed: String {
        let total = Int(model.recording.elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var recordButton: some View {
        Button {
            if model.recording.isPreparing {
                model.recording.cancelPreparation()
            } else if model.recording.isRecording {
                model.recording.stop()
            } else {
                startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        model.recording.isRecording
                            ? SpeechRailDesignTokens.Color.critical
                            : SpeechRailDesignTokens.Color.voice
                    )
                if model.recording.isPreparing {
                    // 准备期间的按钮是**退出口**：写着「取消」的那一下不会留下任何文件。
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(SpeechRailDesignTokens.Color.onRail)
                } else {
                    SpeechRailButtonIcon(
                        model.recording.isRecording ? .stop : .micFill,
                        size: SpeechRailDesignTokens.VoiceClone.recordGlyphSize,
                        weight: .semibold
                    )
                    .foregroundStyle(SpeechRailDesignTokens.Color.onRail)
                }
            }
            .frame(
                width: SpeechRailDesignTokens.VoiceClone.recordButtonSize,
                height: SpeechRailDesignTokens.VoiceClone.recordButtonSize
            )
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
        .accessibilityLabel(recordButtonLabel)
        .help(recordButtonLabel)
    }

    private var recordButtonLabel: String {
        if model.recording.isPreparing { return "取消准备麦克风" }
        return model.recording.isRecording ? "停止录音" : "开始录音"
    }

    // MARK: - 3. 回听与核对

    private var reviewCard: some View {
        CardSurface {
            CardHead(title: "回听与核对", detail: nil) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    if let verdict = model.cloneReferenceAnalysis?.verdict {
                        StatusPill(tone: verdict.tone, label: verdict.title)
                    } else {
                        StatusPill(tone: .attention, label: "无法解码")
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                    // 波形是「这段录音自己的形状」，不是装饰：回听的第一步就是确认这件事。
                    Text("波形来自刚才这段录音本身")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                takeRow
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("实际朗读的文本（服务用它给参考音频做内容校验）")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    TextEditor(text: $spokenText)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .scrollContentBackground(.hidden)
                        .focused($isSpokenTextFocused)
                        .frame(minHeight: SpeechRailDesignTokens.Layout.creatorReferenceMinimumHeight)
                        .padding(SpeechRailDesignTokens.Spacing.xs)
                        .speechRailRecessedSlot()
                        .accessibilityLabel("实际朗读的文本")
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var takeRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            WaveformBars(
                pattern: SpeechRailDesignTokens.Waveform.resultBar,
                isPlaying: isPlayingTake,
                levels: model.cloneReferenceAnalysis?.envelope,
                progress: isPlayingTake ? model.playbackProgress : nil
            )
            if let duration = model.cloneReferenceAnalysis?.durationText {
                Text(duration)
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            Spacer(minLength: 0)
            // 稿给这一行都画了图标（`play` / `mic`，删除沿用同一套 `trash`）：回听、重录、
            // 删除是三条不同的动作，图标让它们在余光里就分得开，不必逐字读。
            Button {
                toggleTakePlayback()
            } label: {
                SpeechRailButtonLabel(
                    isPlayingTake ? "停止" : "播放",
                    icon: isPlayingTake ? .stop : .play
                )
            }
            .speechRailButton(.secondary)
            .speechRailPointerCursor()
            Button {
                startRecording()
            } label: {
                SpeechRailButtonLabel("重录", icon: .mic)
            }
            .speechRailButton(.secondary)
            .speechRailPointerCursor()
            // 「听完了，不想用」的出口：录音收下之后，磁盘上的临时文件已经删掉了
            // （`acceptCloneRecording`），内存里这一段是唯一副本，重录的代价也只是再读一遍——
            // 所以这一颗不问「确定吗」，点下去就回到「还没开始」。
            Button(role: .destructive) {
                deleteTake()
            } label: {
                SpeechRailButtonLabel("删除", icon: .delete)
            }
            // 稿的动作行里同一档的按钮都长一样，删除没有单独的红底；`role` 仍留给无障碍。
            .speechRailButton(.secondary)
            .speechRailPointerCursor()
            .accessibilityLabel("删除这段录音")
            .help("删除这段录音")
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .speechRailField()
    }

    /// 删掉这一段还没注册的录音：停掉回听、清掉这一轮的错误提示，把录制卡与回听卡
    /// 一起收回到「还没开始」。
    ///
    /// 「实际朗读的文本」是用户的**输入**（下一遍还要用），不是这一段录音的一部分，所以留着；
    /// 试听位置（`isPlayingTake`）与电平表/计时（`recording.discard()`）则必须回到零，
    /// 否则卡片会一边说「还没开始」、一边停在上一段的读数上。
    private func deleteTake() {
        model.stopAudio()
        isPlayingTake = false
        model.clearCloneMessage()
        model.discardCloneRecording()
        model.recording.discard()
    }

    private func referenceMetrics(_ analysis: AudioReferenceAnalysis) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.lg) {
            metricFact("时长", analysis.durationText)
            metricFact("人声占比", percentText(analysis.speechActiveRatio))
            metricFact("估计信噪比", signalToNoiseText)
            metricFact(
                "削波",
                analysis.clippingRatio > 0
                    ? percentText(analysis.clippingRatio)
                    : "无"
            )
        }
    }

    /// 估计信噪比只有服务端预检给得出（本地量测只做时长、人声占比、峰值与削波）；
    /// 没跑预检时如实写「未预检」，不拿本地猜的数字顶替（稿这一格是 `24 dB`）。
    private var signalToNoiseText: String {
        guard let decibels = model.cloneEvaluation?.reference.estimatedSNRDecibels else {
            // 页面上的按钮是「先检查参考音频」，这一格就跟着说「未检查」——
            // 「预检」是服务侧的说法，留在开发者详情里（用户 2026-09-19）。
            return "未检查"
        }
        return String(format: "%.0f dB", decibels)
    }

    private func metricFact(_ label: String, _ value: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
            Text(label)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func percentText(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    private func decibelText(_ decibels: Double) -> String {
        String(format: "%.0f dBFS", decibels)
    }

    // MARK: - 4. 注册

    private var registerCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    TextField("给这个音色起个名字", text: $voiceName)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .speechRailSingleLineInput(.regular)
                        .frame(width: SpeechRailDesignTokens.VoiceClone.nameFieldWidth)
                        .accessibilityLabel("音色名称")
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.evaluateCloneReference(referenceText: effectiveReferenceText, name: voiceName) }
                    } label: {
                        // 稿的注册卡**没有卡头**：它整张就是那一行动作 + 一行结论。
                        // 于是「正在做什么」只能由按下的那颗按钮自己说——进度放在卡头里，
                        // 用户还得先把眼睛挪到卡片上沿才知道刚才那一下生效了没有。
                        if model.isEvaluatingCloneReference {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                ProgressView().controlSize(.small)
                                Text("正在检查…")
                            }
                        } else {
                            SpeechRailButtonLabel("先检查参考音频", icon: .checkShield)
                        }
                    }
                    .speechRailButton(.secondary)
                    .disabled(!canSubmit || model.isEvaluatingCloneReference || model.isRegisteringCloneVoice)
                    .speechRailPointerCursor()
                    .accessibilityLabel(
                        model.isEvaluatingCloneReference ? "正在检查参考音频" : "先检查参考音频"
                    )
                    Button {
                        Task { await register() }
                    } label: {
                        if model.isRegisteringCloneVoice {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                ProgressView().controlSize(.small)
                                Text("正在注册…")
                            }
                        } else {
                            SpeechRailButtonLabel("注册音色", icon: .mic)
                        }
                    }
                    .speechRailButton(.primary)
                    .disabled(
                        !canSubmit
                            || cloneIsGated
                            || model.isRegisteringCloneVoice
                            || model.isEvaluatingCloneReference
                    )
                    .speechRailPointerCursor()
                    .accessibilityLabel(
                        model.isRegisteringCloneVoice ? "正在注册音色" : "注册音色"
                    )
                }
                // 稿把这段录音的结论和「还差什么」放在同一行：注册按钮的正下方就是
                // 按下它之前该看的两个答案——这段录音怎么样、还缺哪一步。
                HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.lg) {
                    if let analysis = model.cloneReferenceAnalysis {
                        referenceMetrics(analysis)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.gutter)
                    submissionHint
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 提交给服务端的**实际朗读文本**：默认是提词稿全文，用户改过就用改过的。
    private var effectiveReferenceText: String {
        let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? scriptText.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    private var canSubmit: Bool {
        model.cloneRecordingAudio != nil
            && !voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveReferenceText.isEmpty
    }

    @ViewBuilder
    private var submissionHint: some View {
        if !canSubmit {
            Text(blockingReason)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
        } else if cloneIsGated {
            Text(cloneCapabilityMessage)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
        }
    }

    private var blockingReason: String {
        if model.cloneRecordingAudio == nil { return "先录一段参考音频。" }
        if voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "填写音色名称后可以注册。" }
        return "填写你实际朗读的文本后可以注册。"
    }

    /// Only a positive service declaration enables clone registration.
    private var cloneIsGated: Bool {
        !cloneCapabilityConfirmed
    }

    private var cloneCapabilityConfirmed: Bool {
        model.serviceCapabilitiesLoadState == .loaded
            && model.serviceCapabilities?.supportsClone == true
    }

    private var cloneCapabilityTitle: String {
        switch model.serviceCapabilitiesLoadState {
        case .unknown, .loading:
            "正在确认音色克隆能力"
        case .failed:
            "暂时无法读取服务能力"
        case .loaded:
            "当前服务没有开放音色克隆"
        }
    }

    private var cloneCapabilityMessage: String {
        switch model.serviceCapabilitiesLoadState {
        case .unknown, .loading:
            "正在确认服务是否开放音色克隆；确认前暂不能注册。"
        case .failed:
            "暂时无法读取服务能力，音色克隆是否可用尚未确认。"
        case .loaded:
            "当前服务没有发布音色克隆能力；可在「模型」页查看当前档位与所需模型。"
        }
    }

    /// 服务端预检结论的语气与标题。写成页面里的两个小函数而不是给快照加扩展，
    /// 是为了不把「怎么显示」塞进传输层的类型（`VoiceQualityReportSnapshot` 只描述服务端说了什么）。
    private func preflightTone(_ report: VoiceQualityReportSnapshot) -> StatusTone {
        switch report.status {
        case .pass: .healthy
        case .warn: .attention
        case .reject: .critical
        case .unevaluated: .neutral
        }
    }

    private func preflightTitle(_ report: VoiceQualityReportSnapshot) -> String {
        switch report.status {
        case .pass: "检查通过"
        case .warn: "检查有提醒"
        case .reject: "检查没通过"
        case .unevaluated: "这次没给结论"
        }
    }

    /// 「先检查参考音频」的回执。
    ///
    /// 这一按的结果此前只落在结论行最后一格（估计信噪比从「未预检」变成一个数）：
    /// 那样一处四五个字的变化，承载不了「刚才跑了一次完整的服务端质量门」这件事，
    /// 预检**没通过**时更是连失败码都只写在开发者详情里。既然按钮承诺了一次检查，
    /// 结论就要自己说话——通过、提醒、拒绝三档都说清，并带上服务端给的数字。
    private func preflightReceiptMessage(_ report: VoiceQualityReportSnapshot) -> String {
        let facts = [
            "时长 \(secondsText(report.reference.durationSeconds))",
            "采样率 \(report.reference.sampleRate) Hz",
            String(format: "估计信噪比 %.0f dB", report.reference.estimatedSNRDecibels),
            report.reference.transcriptMatch.map { "内容匹配 \(percentText($0))" } ?? "内容匹配 未评估"
        ].joined(separator: "、")
        let codes = report.failureCodes.isEmpty
            ? ""
            : "失败码：\(report.failureCodes.joined(separator: "、"))。"
        switch report.status {
        case .pass:
            return "这段参考音频检查通过（\(facts)）。保存成音色时还会再检查一次。"
        case .warn:
            return "这段参考音频有几个提醒（\(facts)）。\(codes)仍可以保存，按提醒重录一段会更稳。"
        case .reject:
            return "这段参考音频没通过（\(facts)）。\(codes)现在保存会被拒绝，请先重录一段。"
        case .unevaluated:
            return "这次没有给出结论（\(facts)）。\(codes)保存时服务会再独立检查一次。"
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let message = model.cloneMessage ?? model.recording.message {
            StatusBanner(
                tone: .attention,
                title: "这一步没完成",
                message: message,
                actionTitle: model.recording.permissionDenied ? "打开系统设置" : nil,
                action: model.recording.permissionDenied ? { openMicrophoneSettings() } : nil
            )
        }
        if let report = model.cloneEvaluation {
            StatusBanner(
                tone: preflightTone(report),
                title: preflightTitle(report),
                message: preflightReceiptMessage(report)
            )
        }
        if let verdict = model.cloneReferenceAnalysis?.verdict, verdict != .ready {
            StatusBanner(
                tone: verdict.tone,
                title: verdict.title,
                message: verdict.guidance
            )
        }
        if let voice = model.lastRegisteredCloneVoice {
            StatusBanner(
                tone: .healthy,
                title: "音色已注册",
                message: "「\(voice.name)」已写进本机音色库，可以在配音台直接选用。",
                actionTitle: "去音色库查看",
                action: { navigation.request(.voiceLibrary) }
            )
        }
        cloneCapabilityBanner
    }

    @ViewBuilder
    private var cloneCapabilityBanner: some View {
        if cloneIsGated {
            if let actionTitle = cloneCapabilityActionTitle {
                StatusBanner(
                    tone: .attention,
                    title: cloneCapabilityTitle,
                    message: cloneCapabilityMessage,
                    actionTitle: actionTitle,
                    action: { handleCloneCapabilityAction() }
                )
            } else {
                StatusBanner(
                    tone: .attention,
                    title: cloneCapabilityTitle,
                    message: cloneCapabilityMessage
                )
            }
        }
    }

    // MARK: - 开发者详情

    private var inspector: some View {
        DeveloperInspector {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                SectionHeading(
                    title: "参考音频",
                    detail: "本地量测与服务端预检是两件事：左边这组来自本机解码，下面那组来自服务端质量门。"
                )
                if let analysis = model.cloneReferenceAnalysis {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        LabeledContent("时长", value: analysis.durationText)
                        LabeledContent("峰值电平", value: decibelText(analysis.peakDecibels))
                        LabeledContent("有效电平", value: decibelText(analysis.activeDecibels))
                        LabeledContent("人声占比", value: percentText(analysis.speechActiveRatio))
                        LabeledContent("削波比例", value: percentText(analysis.clippingRatio))
                        LabeledContent("起始静音", value: secondsText(analysis.leadingSilence))
                        LabeledContent("结尾静音", value: secondsText(analysis.trailingSilence))
                    }
                    .speechRailInspectorContent()
                } else {
                    Text("还没有录音。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Divider()
                SectionHeading(title: "服务端预检", detail: nil)
                if let report = model.cloneEvaluation {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        LabeledContent("结论", value: report.status.rawValue)
                        LabeledContent("策略版本", value: report.policyVersion)
                        LabeledContent(
                            "失败码",
                            value: report.failureCodes.isEmpty ? "无" : report.failureCodes.joined(separator: ", ")
                        )
                        LabeledContent("参考时长", value: secondsText(report.reference.durationSeconds))
                        LabeledContent("采样率", value: "\(report.reference.sampleRate) Hz")
                        LabeledContent("估计信噪比", value: String(format: "%.1f dB", report.reference.estimatedSNRDecibels))
                        LabeledContent("噪声底", value: String(format: "%.1f dBFS", report.reference.noiseFloorDecibels))
                        LabeledContent(
                            "内容匹配",
                            value: report.reference.transcriptMatch.map { percentText($0) } ?? "未评估"
                        )
                    }
                    .speechRailInspectorContent()
                } else {
                    Text("还没跑预检；注册时服务端仍会独立核对一次。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    LabeledContent("注册标识", value: model.cloneRegistrationID ?? "—")
                    LabeledContent("幂等键", value: model.cloneIdempotencyKey ?? "—")
                }
                .speechRailInspectorContent()
            }
        }
    }

    private func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }

    // MARK: - 动作

    private func selectPrompt(_ prompt: ClonePrompt) {
        promptID = prompt.id
        adoptionIfEmpty()
    }

    private func selectCustomScript() {
        promptID = Self.customPromptID
        adoptionIfEmpty()
    }

    private func adoptDefaultPrompt() {
        guard promptID.isEmpty, let first = model.clonePrompts.first else {
            adoptionIfEmpty()
            return
        }
        promptID = first.id
        adoptionIfEmpty()
    }

    /// 提词稿变了就同步「实际朗读的文本」——但只在用户还没动过它的时候：
    /// 已经改过的文本是「他实际说了什么」，不能被下一次选稿悄悄覆盖。
    private func adoptionIfEmpty() {
        guard !didAdoptScriptForSpokenText else { return }
        spokenText = scriptText
        didAdoptScriptForSpokenText = !spokenText.isEmpty
    }

    private func startRecording() {
        model.stopAudio()
        model.clearCloneMessage()
        model.discardCloneRecording()
        didAdoptScriptForSpokenText = false
        adoptionIfEmpty()
        Task {
            await model.recording.start()
        }
    }

    private func finishRecording() {
        Task {
            // 先等录音器把 wav 封口：`stop()` 只是把「停」发出去了，此刻读文件会读到
            // 一段还没写完的音频（`AudioReferenceCheck` 会把它判成「无法解码」）。
            guard let url = await model.recording.finish() else { return }
            await model.acceptCloneRecording(fileAt: url)
            if spokenTextIsEmpty() { adoptionIfEmpty() }
        }
    }

    private func spokenTextIsEmpty() -> Bool {
        spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleTakePlayback() {
        if isPlayingTake {
            model.stopAudio()
            isPlayingTake = false
            return
        }
        guard let audio = model.cloneRecordingAudio else { return }
        do {
            try model.playAudio(data: audio)
            isPlayingTake = true
        } catch {
            isPlayingTake = false
        }
    }

    private func register() async {
        if cloneIsGated {
            if model.serviceCapabilitiesLoadState == .loaded {
                navigation.request(.models)
            }
            return
        }
        let voice = await model.registerCloneVoice(
            referenceText: effectiveReferenceText,
            name: voiceName
        )
        if voice != nil {
            model.stopAudio()
            isPlayingTake = false
        }
    }

    private var cloneCapabilityActionTitle: String? {
        switch model.serviceCapabilitiesLoadState {
        case .unknown, .loading:
            nil
        case .failed:
            "重新读取"
        case .loaded:
            "查看模型"
        }
    }

    private func handleCloneCapabilityAction() {
        switch model.serviceCapabilitiesLoadState {
        case .failed:
            Task { await model.refresh() }
        case .loaded:
            navigation.request(.models)
        case .unknown, .loading:
            break
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 录音电平表：28 根条，已过去的那一段用音色语义色，剩下的刻度用分隔色——
/// 同一行既读得出「现在多响」，也读得出「离满还有多远」。
private struct VoiceLevelMeter: View {
    let level: Double
    let isActive: Bool

    private var activeBars: Int {
        guard isActive else { return 0 }
        return Int((level * Double(SpeechRailDesignTokens.VoiceClone.meterBarCount)).rounded())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: SpeechRailDesignTokens.VoiceClone.meterBarSpacing) {
            ForEach(0..<SpeechRailDesignTokens.VoiceClone.meterBarCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index < activeBars
                            ? SpeechRailDesignTokens.Color.voice
                            : SpeechRailDesignTokens.Color.separator
                    )
                    .frame(
                        width: SpeechRailDesignTokens.VoiceClone.meterBarWidth,
                        height: height(at: index)
                    )
            }
        }
        .frame(height: SpeechRailDesignTokens.VoiceClone.meterHeight)
        .accessibilityElement()
        .accessibilityLabel("录音电平")
        .accessibilityValue(isActive ? "\(Int((level * 100).rounded()))%" : "未在录音")
    }

    /// 中间高、两端略低的固定轮廓：电平条的高度是**刻度**，只有颜色随真实电平走——
    /// 让条高也随电平跳，会把「读数」变成「动画」。
    private func height(at index: Int) -> CGFloat {
        let total = SpeechRailDesignTokens.VoiceClone.meterBarCount
        let position = Double(index) / Double(max(1, total - 1))
        let envelope = sin(position * .pi)
        let minimum = SpeechRailDesignTokens.VoiceClone.meterHeight * 0.15
        return minimum + (SpeechRailDesignTokens.VoiceClone.meterHeight - minimum) * envelope
    }
}
