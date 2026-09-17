import AppKit
import Foundation
import SpeechRailControlKit
import SwiftUI
import UniformTypeIdentifiers

public struct CreatorSurfaceView: View {
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        switch route {
        case .dubbing:
            DubbingDeskView()
        case .voiceDesign:
            VoiceDesignView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .works:
            WorksView()
        default:
            EmptyView()
        }
    }
}

// MARK: - 配音台 (Dubbing Desk)

public struct DubbingDeskView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I），
    /// 页面直接绑定它，不再各写一条「显示开发者详情」菜单项（§6.2）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @SceneStorage("speechrail.dubbing.text") private var dubbingText = "在星际航行的漫长岁月里，人类学会了倾听寂静。每当脉冲信号穿越猎户座悬臂，控制台都会闪烁起熟悉的琥珀色微光。"
    @SceneStorage("speechrail.dubbing.voiceID") private var selectedVoiceID = ""
    /// `0` means "this window has no opinion yet", so the Settings default
    /// applies until the user moves the control in this window
    /// (REDESIGN-SPEC §7.10).
    @SceneStorage("speechrail.dubbing.speed") private var storedSpeed: Double = 0
    @AppStorage("speechrail.creator.defaultVoiceID") private var defaultVoiceID = ""
    @AppStorage("speechrail.creator.defaultSpeed") private var defaultSpeed: Double = 1.0
    @State private var isVoicePickerPresented = false
    @State private var selectionNotice: String?
    @State private var exportDocument = WAVFileDocument(data: Data())
    @State private var exportFileName = "SpeechRail-配音"
    @State private var isExporting = false
    @State private var exportMessage: String?
    @FocusState private var isScriptFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        PageScaffold(route: .dubbing, scrollable: false) {
            // 输入卡 / 控制条 / 结果条之间是页面级「块与块」：帧实测 19–20pt
            // （原先用 sm=12，比稿紧 8pt；REDESIGN-SPEC §5.6 / §11.6 第十七轮）。
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                scriptCard
                controlBar
                resultSlot
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(
                reduceMotion ? nil : .easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
                value: model.lastCreatedWork?.id
            )
        }
        // 头部（页面身份）由窗口组合根 `ControlCenterView` 声明；这一页没有头部动作：
        // 「生成语音」（⌘⏎）在正文里紧挨文稿，D9 之后也没有「服务状态」入口（§6.2）。
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取音色列表") {
                Task {
                    await model.refreshCreatorVoices()
                    syncSelectedVoice()
                }
            }
        )
        .inspector(isPresented: $showInspector) {
            dubbingInspector
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .wav,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                exportMessage = "已导出“\(exportFileName).wav”。"
            case .failure:
                exportMessage = "导出失败：未能写入目标位置，请重试。"
            }
        }
        .task {
            await model.refreshCreatorVoices()
            syncSelectedVoice()
        }
        .onChange(of: model.creatorVoices) { _, _ in
            syncSelectedVoice()
        }
        .onChange(of: selectedVoiceID) { _, _ in
            normalizeSelectedVoiceSettings()
        }
        .onDisappear {
            model.cancelVoicePreview()
            model.stopAudio()
        }
    }

    // MARK: 文稿

    private static let scriptLineSpacing: CGFloat = 4
    private static let voicePopoverWidth: CGFloat = 320
    private static let voicePopoverHeight: CGFloat = 280

    /// 2026-09-15 用户复核 + 2026-09-16 三度、五度、六度校准（REDESIGN-SPEC §7.1）：
    /// 输入区不占满剩余高度。高度**跟随正文**：短文稿给下限 144pt（静止状态看得见
    /// 3 行写作区），正文每长一行就长一行，到上限 360pt 为止，再长由原生滚动条承担
    /// （组件仍是原生 `TextEditor`，滚动条由系统画）。离屏实测（1440 × 900、默认 53 字
    /// 一行文稿）证明固定区间会把 277pt 高的编辑框留给 16pt 的文字；跟随内容后编辑框
    /// 高度只比正文多一行余量，下限收到 144 后一行文稿下方只空 45pt。区间与口径见
    /// `Layout.creatorComposer*Height`。
    private var scriptCard: some View {
        SpeechRailComposerTextEditor(
            text: $dubbingText,
            label: "配音文稿",
            isFocused: $isScriptFocused,
            heightPolicy: .contentDriven(
                minimum: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight,
                maximum: SpeechRailDesignTokens.Layout.creatorComposerMaximumHeight
            ),
            lineSpacing: Self.scriptLineSpacing
        ) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                scriptCountLabel
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                // 稿（Figma `editor/meta`）把「清空」画成「橡皮擦 + 文字」的安静按钮。
                Button {
                    dubbingText = ""
                } label: {
                    Label("清空", systemImage: "eraser")
                }
                .buttonStyle(.borderless)
                // 稿的 `editor/meta` 里「清空」是 `Subheadline`(11)：4x 帧上两个字的墨迹
                // 各宽约 9.5–9.75pt ≈ 11pt 字号。按钮仍是原生 `.borderless`，只钉字号。
                .font(SpeechRailDesignTokens.Typography.secondary)
                .disabled(dubbingText.isEmpty)
                .accessibilityLabel("清空文稿")
            }
            // 页脚信息行与上方正文对齐（稿 `editor/meta` 是 padX 18 → `Layout.cardInset`，
            // 由组件按 `chrome` 统一给）；竖直方向由组件按 `Layout.composerMetaRowHeight`
            // （42pt 带）居中。
        }
    }

    private var scriptCountLabel: some View {
        let count = dubbingText.count
        let limit = SpeechRailCreatorLimits.speechTextMaximumLength
        let isOverLimit = count > limit
        return HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            if isOverLimit {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
            }
            Text("\(count) / \(limit) 字")
                .monospacedDigit()
        }
        // 稿的 `editor/meta` 是 `Subheadline`(11) + `text/secondary`：4x 帧上这一行实测
        // #6E6E73（= secondary）、数字 ink 7.75pt ≈ 11pt。应用此前用 `caption`（10）
        // （REDESIGN-SPEC §11.6 第二十轮）。
        .font(SpeechRailDesignTokens.Typography.secondary)
        .foregroundStyle(
            isOverLimit
                ? SpeechRailDesignTokens.Color.critical
                : SpeechRailDesignTokens.Color.inkSecondary
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文稿 \(count) 字，上限 \(limit) 字")
    }

    // MARK: 控制条

    /// One bar under the script. Narrow windows get two rows with the same
    /// controls rather than a squeezed single row (§7.1).
    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: SpeechRailDesignTokens.Spacing.md) {
                voiceControl
                speedControl
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                generateButton
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                voiceControl
                speedControl
                generateButton
            }
        }
        // 稿的 `composer` 控制卡是 padX 16 / padY 12（帧实测文字左沿距卡沿约 18pt）。
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.panel)
    }

    /// 稿的 `composer/fieldGroup` 给两组控件各配一个 `Subheadline`(11) 小标签：4x 帧实测
    /// 「音色」在 x 278.75–299.25、「语速」在 459.5–480.25，两个字各约 9.5pt 宽 = 11pt。
    /// 应用此前只在语速一侧有标签，胶囊上方是空的（REDESIGN-SPEC §11.6 第二十轮）。
    private var voiceControl: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("音色")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            voicePickerButton
        }
    }

    private var voicePickerButton: some View {
        Button {
            isVoicePickerPresented = true
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform")
                    // 稿的胶囊是 `icon(capsule, "audio-waveform", 15, V["accent/voice"])`：
                    // 波形是**琥珀**（4x 帧同样量到琥珀），与 §5.4「琥珀只标记声音/音色类
                    // 对象——音色徽标、波形、候选卡」一致。应用此前不设色，继承成正文色。
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    .accessibilityHidden(true)
                Text(voicePickerTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let voice = selectedVoice {
                    Text(voice.isSystem ? "系统" : "我的")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    // 稿（脚本 1336）是 `icon(capsule, "chevron-down", 14, V["text/secondary"])`：
                    // 次级色，不是三级色。应用自己的折叠行 chevron 也用 `inkSecondary`，
                    // 只有这里用三级色，属于唯一异类（REDESIGN-SPEC §11.6 第三十九轮）。
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorVoicePickerWidth, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        // 稿的 `voiceCapsule` 是 30pt 高（帧实测 757.0 → 786.75）；系统次按钮的
        // `.large` 档是 28pt（本机离屏实测），取这一档。REDESIGN-SPEC §11.6 第二十一轮。
        .controlSize(.large)
        .disabled(model.isRefreshingCreatorVoices && model.creatorVoices.isEmpty)
        .popover(isPresented: $isVoicePickerPresented, arrowEdge: .bottom) {
            voicePickerPopover
        }
        .accessibilityLabel("音色")
        .accessibilityValue(voicePickerTitle)
    }

    private var voicePickerTitle: String {
        if let voice = selectedVoice { return voice.name }
        return model.isRefreshingCreatorVoices ? "正在读取音色…" : "没有可用音色"
    }

    @ViewBuilder
    private var voicePickerPopover: some View {
        if availableVoices.isEmpty {
            ContentUnavailableView {
                Label("没有可用音色", systemImage: "waveform.slash")
            } description: {
                Text("服务当前没有返回可用于配音的音色。")
            } actions: {
                Button("去音色创作") {
                    isVoicePickerPresented = false
                    navigation.request(.voiceDesign)
                }
                .speechRailButton(.primary)
            }
            .frame(width: Self.voicePopoverWidth)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(availableVoices) { voice in
                            voicePickerRow(voice)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.micro)
                }
                .frame(width: Self.voicePopoverWidth, height: Self.voicePopoverHeight)

                Divider()

                Button {
                    isVoicePickerPresented = false
                    navigation.request(.voiceLibrary)
                } label: {
                    Label("管理音色库", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(SpeechRailDesignTokens.Spacing.xs)
            }
        }
    }

    private func voicePickerRow(_ voice: CreatorVoice) -> some View {
        let isSelected = voice.id == selectedVoiceID
        let isPreviewing = model.previewingVoiceID == voice.id
        return HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                selectedVoiceID = voice.id
                isVoicePickerPresented = false
            } label: {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(voice.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(voice.isSystem ? "系统" : "我的")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    }
                    Text(voice.description.isEmpty ? "没有描述" : voice.description)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(voice.name)，\(voice.isSystem ? "系统音色" : "我的音色")")
            .accessibilityHint("选择并用于配音")

            Button {
                if isPreviewing {
                    model.cancelVoicePreview()
                } else {
                    model.startVoicePreview(voice)
                }
            } label: {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!voice.available)
            .accessibilityLabel(isPreviewing ? "停止试听 \(voice.name)" : "试听 \(voice.name)")
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
        .background(
            isSelected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: SpeechRailDesignTokens.Corner.nestedShape
        )
    }

    private var speedControl: some View {
        let isSpeedLocked = selectedVoice?.mode == "clone"
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("语速")
                // 与「音色」同一档（稿 `fieldGroup/label` = Subheadline 11，帧实测同上）。
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            // 稿的 `speedRow` 是**一行**：滑块（132pt 定宽）、当前取值、快捷档位。
            // 应用此前把取值塞进标签行并靠右浮着，滑块又被 HStack 拉成整行宽
            // （4x 帧实测控件区 748pt vs 稿 132pt；REDESIGN-SPEC §11.6 第二十八轮）。
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Slider(value: speechSpeedBinding, in: 0.5...2.0, step: 0.1)
                    // 稿 `speedRow/slider` 的轨道是 132pt 定宽、thumb 14；定宽也让
                    // 控制条保持「左侧一组控件 + 右侧主动作」的稿式构图（§7.1）。
                    .frame(width: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                    .disabled(isSpeedLocked)
                    .accessibilityLabel("语速")

                Text(String(format: "%.1fx", speechSpeed))
                    // 稿的 `speedRow/value` 是 `Body / Medium`(13)：帧实测这一串 ink 9.5pt
                    // ≈ 13pt 数字。保留等宽数字（§7.1 要求显示当前值），并给一个定宽槽
                    // 免得数字位数变化时整行控件左右跳。
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .frame(
                        minWidth: SpeechRailDesignTokens.Layout.creatorSpeedValueWidth,
                        alignment: .leading
                    )

                // **有意保留的偏离**：帧的 `speedRow` 只画了「滑块 / 取值 / 分段」三段
                // （`figma-kit/main.js:1342-1360` 同样没有），但 §7.1 的「语速」条文
                // 明确要求 `Slider` + `Stepper`（步长 0.1，范围 0.5–2.0）。两者冲突时
                // 以明确条文为准，代价是整组比帧宽 28pt（§11.6 第二十八轮已记，
                // 第五十二轮复核时再次确认）。
                Stepper(value: speechSpeedBinding, in: 0.5...2.0, step: 0.1) {
                    EmptyView()
                }
                .labelsHidden()
                .disabled(isSpeedLocked)
                .accessibilityLabel("语速微调")

                Picker("快捷语速", selection: quickSpeedBinding) {
                    ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { speed in
                        Text(String(format: "%.1f", speed)).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isSpeedLocked)
            }

            if isSpeedLocked {
                Text("参考音色固定为 1.0x")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.creatorVoiceControlWidth)
    }

    /// A segmented control can only show one of its own values, so the slider
    /// and the presets share one binding instead of fighting each other.
    private var quickSpeedBinding: Binding<Double> {
        Binding(
            get: {
                [0.8, 1.0, 1.2, 1.5].min { abs($0 - speechSpeed) < abs($1 - speechSpeed) } ?? 1.0
            },
            set: { storedSpeed = $0 }
        )
    }

    private var speechSpeed: Double {
        storedSpeed == 0 ? defaultSpeed : storedSpeed
    }

    private var speechSpeedBinding: Binding<Double> {
        Binding(
            get: { speechSpeed },
            set: { storedSpeed = $0 }
        )
    }

    private var generateButton: some View {
        Button {
            if model.isCreatingSpeech {
                model.cancelSynthesis()
            } else {
                startSynthesis()
            }
        } label: {
            if model.isCreatingSpeech {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    ProgressView()
                        .controlSize(.small)
                    Text("停止")
                }
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Label("生成语音", systemImage: "waveform.badge.plus")
                    ButtonShortcutHint("⌘⏎")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        // 稿的主按钮是 34pt（帧实测 737.0 → 770.75）；系统 `.large` 是 28、`.extraLarge`
        // 是 36（本机离屏实测），取最近的一档。REDESIGN-SPEC §11.6 第二十一轮。
        .controlSize(.extraLarge)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canGenerate)
        .help("生成语音 ⌘⏎")
        .accessibilityLabel(model.isCreatingSpeech ? "停止生成" : "生成语音")
    }

    // MARK: 结果

    @ViewBuilder
    private var resultSlot: some View {
        if let selectionNotice {
            Text(selectionNotice)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }

        if let work = model.lastCreatedWork {
            resultBar(for: work)
        } else if let creatorMessage = model.creatorMessage {
            failureBar(message: creatorMessage)
        }
    }

    /// The result stays on the page it was produced on: play, reveal, export
    /// and a way into the library, instead of an implicit page change (§7.1).
    private func resultBar(for work: CreativeWork) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                // 稿的行首不是 SF Symbol，而是 `waveform(result, [5, 11, 16, …], voice, 2)`
                // 这一排 **12 根 2pt 圆角条**（`main.js:1372`）：4x 帧 `▸ 配音台.png`
                // 实测墨迹 46.0 × 17.0，应用此前那个 `waveform` 字形只有 11.5 × 10.0，
                // 于是标题整列左移 34.5pt（REDESIGN-SPEC §11.6 第四十二轮）。
                WaveformBars(
                    pattern: SpeechRailDesignTokens.Waveform.resultBar,
                    isPlaying: isPlaying(work)
                )
                .accessibilityHidden(true)

                // 稿（`main.js` 1366-1375）的标题区是 `frame("titles", { gap: 8 })`：
                // 名称 `Body / Medium` + 时长 `Callout` `text/secondary`，两者**并列**、
                // 中间只有 8pt 间距。应用此前把时长并进同一行文本写成「· 0:12」，
                // 于是多出一个稿上没有的分隔符、字号也跟着标题走。
                // 4x 帧实测：名称墨迹 x 334.5–448（= 卡左沿 261 + pad 14 + 波形 46 + gap 12
                // + 首字留白 1.5），时长墨迹 x 457.75–487.25，两者之间是 9.75pt 的字形间距
                // ——对应脚本的 gap 8（REDESIGN-SPEC §11.6 第四十一轮）。
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    // 结果条是单行窄条：名称按可用宽度自然截断（`displayTitle` 见
                    // `CreativeWork` 的说明，第四十八轮）。
                    Text(work.displayTitle)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let durationText = work.durationText {
                        Text(durationText)
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                Button {
                    model.playWork(work)
                } label: {
                    Label(
                        isPlaying(work) ? "停止" : "播放",
                        systemImage: isPlaying(work) ? "stop.fill" : "play.fill"
                    )
                }
                .accessibilityLabel(isPlaying(work) ? "停止播放" : "播放")

                Button {
                    revealInFinder(work)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .accessibilityLabel("在 Finder 中显示")

                Button {
                    prepareExport(for: work)
                } label: {
                    Label("导出…", systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel("导出配音")

                // 稿（`main.js` 1377-1383）把这一格画成**安静行**而不是第四颗边框按钮：
                // `padX 8 / padY 4 / radius 7` 的无底色行，内容是 `Callout` `text/secondary`
                // 的「查看我的作品」+ 13pt 框的 `chevron-right`（`text/tertiary`）。
                // 4x 帧上它是纯文字 + `›`，与左边三颗白底按钮明显不同族。
                // 应用此前用默认样式的 `Button`，离屏实渲出来是第四颗边框按钮。
                Button {
                    navigation.request(.works)
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("查看我的作品")
                        Image(systemName: "chevron.right")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                // 稿的安静行自带 `padX 8 / padY 4` 的内边距（hover/pressed 反馈就画在
                // 这一圈上）。4x 帧实测它的 chevron 墨迹右沿距结果条右沿 27.5pt
                // （= 条内边距 14 + 安静行 8 + 13 框里 4.25 宽墨迹的居中留白）；
                // 应用不给这 8pt 时只有 17.5pt，整块出口比稿更贴右沿。
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                .contentShape(Rectangle())
                .accessibilityLabel("查看我的作品")
            }

            if let playbackMessage = model.workPlaybackMessage {
                Text(playbackMessage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
        // 稿 `resultBar` 是 `pad: 14`、高度实测 59pt（4x 帧 y820.5 → 879.5）。应用此前
        // 12/8 的紧内边距只画到约 44pt。取 4pt 网格上最近的一档 16：整条 60pt，
        // 与稿差 1pt，同时和卡片内边距同值（REDESIGN-SPEC §11.6 第二十八轮）。
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailSurface(.elevated)
        .accessibilityElement(children: .contain)
        .transition(
            reduceMotion
                ? AnyTransition.identity
                : AnyTransition.move(edge: .bottom).combined(with: .opacity)
        )
    }

    /// A failed run reports in the same place the result would have appeared.
    private func failureBar(message: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                // 稿 `Result Bar` 的 `State=Error` 变体写的是「生成未完成：服务端没有返回音频」
                // （`main.js` 912）。应用把它拆成「标题 + 真实原因」两行——原因由服务端给，
                // 不能钉死成稿上的示例句——标题则取稿的前半句（REDESIGN-SPEC §11.6 第三十六轮改回）。
                Text("生成未完成")
                    // 失败条与结果条同骨架：稿的结果条标题是 `Body / Medium`。
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Button("重试") {
                startSynthesis()
            }
            // 稿把这一对都画成次级按钮（`main.js` 914–915 的 `secondaryButton`）。
            .speechRailButton(.secondary)
            .disabled(!canGenerate)
            Button("查看诊断") {
                navigation.request(.diagnostics)
            }
            .speechRailButton(.secondary)
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.panel)
        .accessibilityElement(children: .contain)
    }

    private func isPlaying(_ work: CreativeWork) -> Bool {
        model.playingWorkID == work.id && model.isAudioPlaying
    }

    private var canGenerate: Bool {
        model.isCreatingSpeech
            || (selectedVoice != nil
                && !dubbingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && dubbingText.count <= SpeechRailCreatorLimits.speechTextMaximumLength)
    }

    private func startSynthesis() {
        guard let voice = selectedVoice else { return }
        exportMessage = nil
        model.startSynthesisAndSave(text: dubbingText, voice: voice, speed: speechSpeed)
    }

    private func revealInFinder(_ work: CreativeWork) {
        guard let url = model.workAudioURL(work) else {
            exportMessage = "找不到该作品的音频文件。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func prepareExport(for work: CreativeWork) {
        do {
            exportDocument = WAVFileDocument(data: try model.loadWorkAudio(work))
            exportFileName = work.exportBaseName
            exportMessage = nil
            isExporting = true
        } catch {
            exportMessage = "导出失败：作品音频暂时不可用。"
        }
    }

    private var dubbingInspector: some View {
        DeveloperInspector {
            SectionHeading(
                title: "配音技术摘要",
                detail: "面向开发者的安全运行信息；不展示原始文稿、凭据或本地绝对路径。"
            )
            LabeledContent("文稿长度", value: "\(dubbingText.count) 字")
            LabeledContent("音色", value: selectedVoice?.name ?? "未选择")
            LabeledContent("音色状态", value: selectedVoice.map { $0.available ? "当前可用" : "当前不可用" } ?? "未读取")
            LabeledContent("语速", value: String(format: "%.1fx", speechSpeed))
            LabeledContent("输出格式", value: "WAV")
            LabeledContent("采样率", value: "服务配置未提供")
            LabeledContent("生成状态", value: model.isCreatingSpeech ? "生成中" : "空闲")
            LabeledContent("播放状态", value: model.isAudioPlaying ? "正在播放" : "未播放")
            if let workPlaybackMessage = model.workPlaybackMessage {
                Divider()
                Text(workPlaybackMessage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
            }
        }
    }

    private var availableVoices: [CreatorVoice] {
        model.creatorVoices.filter { $0.available }
    }

    private var selectedVoice: CreatorVoice? {
        availableVoices.first { $0.id == selectedVoiceID }
    }

    private func syncSelectedVoice() {
        let preferredVoice = availableVoices.first { $0.id == defaultVoiceID } ?? availableVoices.first
        guard let firstVoice = preferredVoice else {
            if !selectedVoiceID.isEmpty {
                selectionNotice = "当前所选音色已不可用，请先读取可用音色。"
            }
            selectedVoiceID = ""
            return
        }
        if !availableVoices.contains(where: { $0.id == selectedVoiceID }) {
            if !selectedVoiceID.isEmpty {
                selectionNotice = "原选音色已不可用，已切换到“\(firstVoice.name)”。"
            }
            selectedVoiceID = firstVoice.id
        }
        normalizeSelectedVoiceSettings()
    }

    private func normalizeSelectedVoiceSettings() {
        if selectedVoice?.mode == "clone", speechSpeed != 1.0 {
            storedSpeed = 1.0
        }
    }
}

// MARK: - 音色创作 (Voice Design with Acoustic Rack)

public struct VoiceDesignView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @SceneStorage("speechrail.voiceDesign.description") private var description = "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。"
    @SceneStorage("speechrail.voiceDesign.name") private var voiceName = "夜航主持"
    @SceneStorage("speechrail.voiceDesign.referenceText") private var referenceText = "欢迎来到 SpeechRail，这是用于试听和保存音色的参考文案。"
    @FocusState private var isEditorFocused: Bool
    @State private var playingSlot: String? = nil
    @State private var selectedSlot: String? = nil
    @State private var pendingSave: VoiceDesignCandidateSnapshot? = nil
    @State private var errorMessage: String? = nil
    @State private var showsAdvanced = false

    private var candidates: [VoiceDesignCandidateSnapshot] {
        model.voiceDesignCandidates
    }

    private var savedSlots: Set<String> {
        model.voiceDesignSavedSlots
    }

    private var isGenerating: Bool {
        model.isGeneratingVoiceDesign
    }

    private enum VoiceDesignAvailability: Equatable {
        case checking
        case available
        case requiresQuality
        case serviceUnavailable
        case unsupported

        var isAvailable: Bool {
            self == .available
        }

    }

    private struct AvailabilityBanner {
        let title: String
        let message: String
        let actionTitle: String
        let route: AppRoute
    }

    private let acousticChips = [
        "磁性胸腔", "治愈温暖", "播音质感", "微醺叙事", "少年清冽", "知性温婉", "沙哑沉郁"
    ]
    public init(showInspector: Binding<Bool> = .constant(false)) {}

    public var body: some View {
        PageScaffold(route: .voiceDesign) {
            promptCard
            voiceDesignFeedback
            candidateSection
        }
        // 音色创作也是「描述 → 生成 → 保存」一路在正文里走完，所以没有头部动作；
        // 页面身份由窗口组合根声明，重新读取音色列表与档位留在 ⌘R（§6.2）。
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取音色列表") {
                Task {
                    await model.refresh()
                    await model.refreshCreatorVoices()
                }
            }
        )
        .inspector(isPresented: $showInspector) {
            voiceDesignInspector
        }
        .sheet(item: $pendingSave) { candidate in
            VoiceCandidateSaveSheet(
                candidate: candidate,
                voiceName: $voiceName,
                onSave: {
                    save(candidate)
                    pendingSave = nil
                },
                onCancel: { pendingSave = nil }
            )
        }
        .task {
            await model.refresh()
            await model.refreshCreatorVoices()
        }
        .onDisappear {
            model.stopAudio()
            playingSlot = nil
            selectedSlot = nil
        }
        .onChange(of: model.isAudioPlaying) { _, isPlaying in
            if !isPlaying {
                playingSlot = nil
            }
        }
    }

    /// Three steps, not a form: describe the voice, keep the reference text and
    /// the name out of the way until they are needed, then audition candidates
    /// (§7.2).
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SpeechRailComposerTextEditor(
                text: $description,
                label: "音色描述",
                isFocused: $isEditorFocused,
                heightPolicy: .band(
                    minimum: SpeechRailDesignTokens.Layout.creatorVoiceInstructionMinimumHeight,
                    ideal: SpeechRailDesignTokens.Layout.creatorVoiceInstructionIdealHeight,
                    maximum: SpeechRailDesignTokens.Layout.creatorVoiceInstructionMaximumHeight
                ),
                // 这一行的带高比配音台紧一档：整卡 160 = 稿字段 130 + 提示行 + 元信息行，
                // 取一个紧凑控件的高度（28）作为下限。
                metaRowHeight: SpeechRailDesignTokens.Control.compactHeight,
                hint: "继续描述场景、听众或情绪，候选之间的差异会更明显。",
                // 描述框不是自己一张卡：稿里正文、计数行、声学特征芯片与生成按钮同属
                // `promptCard` 这张面板，面板给内边距，正文与计数行之间也没有分隔线。
                chrome: .embedded
            ) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    descriptionCountLabel
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    // 稿的 `promptCard/meta` 右半是保存门禁的说明，不是描述作用的解释。
                    Text("真实预览未返回前不可保存")
                        // 与左侧计数同一档（稿 `promptCard/meta` 两处都是 `Subheadline`）。
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // 与上方正文对齐（稿 `promptCard/meta` 与字段同宽，内边距由外层面板的
                // `Layout.cardInset` 给）；竖直方向由组件按 `Control.compactHeight` 居中。
            }

            acousticChipRow
            voiceDesignAvailabilityLine

            // 稿的 `promptCard/foot` 是**一行**：左边折叠行，右边键帽 + 主按钮。帧实测
            // 折叠行文字 ink 中心 395.4pt、按钮填充 378.5–412.5pt（中心 395.5、高 34），
            // 两处中心重合。应用此前把按钮另起一行，卡片因此比稿高约 46pt
            // （REDESIGN-SPEC §11.6 第二十轮）。
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                DisclosureGroup("更多设置：参考文案与保存名称", isExpanded: $showsAdvanced) {
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                        voiceNameField
                            .frame(
                                minWidth: SpeechRailDesignTokens.Layout.creatorVoiceNameMinimumWidth,
                                idealWidth: SpeechRailDesignTokens.Layout.creatorVoiceNameWidth,
                                maxWidth: SpeechRailDesignTokens.Layout.creatorVoiceNameMaximumWidth
                            )
                        referenceTextField
                    }
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                }
                // 稿的折叠行标签是 `Callout`（12pt Regular），不是中等字重。
                .font(SpeechRailDesignTokens.Typography.callout)
                // 之前这里吃的是系统默认样式：可点区域只有三角和文字本身，
                // 整行右侧是死区（2026-09-15 用户反馈「点击困难」）。共享样式把
                // 整行做成一个原生 Button 命中区域。
                .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())

                // 快捷键不再是按钮左边那颗独立键帽，而是长在按钮标签尾部
                // （`ButtonShortcutHint`，第四十八轮）。
                generateCandidatesButton
                // 折叠行是 44pt 命中区、内容竖直居中。右侧同一行时要对齐它的中心而不是
                // 顶边：换个同样高的盒子居中，展开后按钮仍停在标签行上。
                .frame(
                    minHeight: SpeechRailDesignTokens.List.rowHeight,
                    alignment: .center
                )
            }
        }
        // 稿的 `promptCard` 是 `pad: 18`（帧实测字段正文左沿距卡沿 20pt）→ `Layout.cardInset`。
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        // **描述框就是这张卡**：稿的 `main.js:1448-1452` 明确写过「在白卡里再套一个白
        // 输入框只会给同一句话画两圈边」，所以表面与边界都落在卡上，卡内不再有第二个框
        // （4x 帧浅/深两版实测：卡内只有一圈描边，位于卡沿；描述区与卡面同值
        // `#FFFFFF` / `#2B292C`）。焦点环同理，跟边界同一个形状。
        .speechRailEditorCard()
        .speechRailFocusRing(isEditorFocused)
    }

    private var descriptionCountLabel: some View {
        let count = description.count
        let limit = SpeechRailCreatorLimits.voiceInstructionMaximumLength
        let isOverLimit = count > limit
        return HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            if isOverLimit {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
            }
            // 计数行与配音台同一写法（`n/上限 字`，REDESIGN-SPEC §7.1/§7.2）：
            // 同一个 App 里两个计数行各写一套是最容易被当成 bug 的差异。
            Text("\(count) / \(limit) 字")
                .monospacedDigit()
        }
        // 稿的 `promptCard/meta` 是 `Subheadline`(11) + `text/tertiary`：4x 帧上这一行
        // 实测 #A1A1A6（= tertiary）。应用此前用 `caption`（10）+ secondary，字号小一档、
        // 颜色比稿重一档（REDESIGN-SPEC §11.6 第二十轮）。
        .font(SpeechRailDesignTokens.Typography.secondary)
        .foregroundStyle(
            isOverLimit
                ? SpeechRailDesignTokens.Color.critical
                : SpeechRailDesignTokens.Color.inkTertiary
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("描述 \(count) 字，上限 \(limit) 字")
    }

    private var acousticChipRow: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("快速加入声学特征")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                // 稿的 `chips` 容器是 `gap: 6`（4x 帧实测相邻 chip 363 → 370）。
                HStack(spacing: SpeechRailDesignTokens.Chip.spacing) {
                    ForEach(acousticChips, id: \.self) { chip in
                        Button {
                            appendChip(chip)
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Chip.labelSpacing) {
                                Image(systemName: "plus")
                                    .font(.system(size: SpeechRailDesignTokens.Chip.iconSize))
                                    // 墨迹按稿的 8.66pt，布局框仍是稿的 13pt（`iconBox`）：
                                    // 只按墨迹改字号会让胶囊比稿窄约 3pt。
                                    .frame(
                                        width: SpeechRailDesignTokens.Chip.iconBox,
                                        height: SpeechRailDesignTokens.Chip.iconBox
                                    )
                                Text(chip)
                            }
                            // 稿的 chip 标签是 `Subheadline`(11)，不是 `Caption`(10)：
                            // 4x 帧上标签 ink 10.25pt，`secondary` 渲染出来 10.5pt
                            // （REDESIGN-SPEC §11.6 第三十四轮）。
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .speechRailKnurledCapsule(selected: false)
                            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                        }
                        .buttonStyle(.plain)
                        .speechRailPointerCursor()
                        .accessibilityLabel("插入声学特征：\(chip)")
                    }
                }
                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            }
        }
    }

    private var generateCandidatesButton: some View {
        Button {
            if isGenerating {
                model.cancelVoiceDesignGeneration()
                model.stopAudio()
                playingSlot = nil
            } else {
                startGeneration()
            }
        } label: {
            if isGenerating {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    ProgressView()
                        .controlSize(.small)
                    Text("停止生成")
                }
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Label("生成候选音色", systemImage: AppRoute.voiceDesign.systemImage)
                    ButtonShortcutHint("⌘⏎")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        // 同「生成语音」：稿的主按钮 34pt，取系统的 `.extraLarge`(36)。
        .controlSize(.extraLarge)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(
            (!isGenerating && !voiceDesignAvailable)
                || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || description.count > SpeechRailCreatorLimits.voiceInstructionMaximumLength
                || model.isRegisteringVoice
        )
        .help("生成候选音色 ⌘⏎")
        .accessibilityLabel(isGenerating ? "停止生成候选音色" : "根据当前描述生成 4 组候选音色")
    }

    /// Candidates read as one grid of four equal cards. A capability gate or an
    /// empty shelf replaces the grid in place, so the page never collapses into
    /// a line of grey text (REDESIGN-SPEC §7.2).
    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "候选试听",
                detail: "只有收到真实预览音频的候选才可试听或按其参数注册；同一时刻只播放一个候选。"
            )

            if !candidates.isEmpty {
                Text(candidateProgressText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(candidateProgressText)
            }

            if !candidates.isEmpty {
                candidateGrid
            } else if voiceDesignAvailability == .checking {
                checkingCandidates
            } else if let banner = voiceDesignAvailabilityBanner {
                unavailableCandidates(banner)
            } else {
                emptyCandidates
            }
        }
        // Figma 把「候选试听」的区块标题放在页面上，卡片只属于四个候选本身；
        // 外面再套一层卡会变成卡里装卡，网格也就不再读起来是网格。
    }

    /// §8 部分成功：`n/4 可试听` has to be readable at a glance instead of
    /// making the user count cards.
    private var candidateProgressText: String {
        let ready = candidates.filter { candidate in
            if case .ready = candidate.status { return true }
            return false
        }.count
        return "\(ready)/\(candidates.count) 可试听"
    }

    private var candidateGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: SpeechRailDesignTokens.Spacing.sm),
                GridItem(.flexible(), spacing: SpeechRailDesignTokens.Spacing.sm),
            ],
            spacing: SpeechRailDesignTokens.Spacing.sm
        ) {
            ForEach(candidates) { candidate in
                VoiceCandidateCard(
                    candidate: candidate,
                    isPlaying: playingSlot == candidate.slot && model.isAudioPlaying,
                    isSaved: savedSlots.contains(candidate.slot),
                    isSaving: model.voiceDesignSavingSlot == candidate.slot,
                    isRegistering: model.isRegisteringVoice,
                    isSelected: selectedSlot == candidate.slot,
                    onPlayToggle: { play(candidate) },
                    onSave: { pendingSave = candidate },
                    onOpenLibrary: { navigation.request(.voiceLibrary) },
                    onRetry: { model.retryVoiceDesignCandidate(slot: candidate.slot) }
                )
            }
        }
    }

    private var checkingCandidates: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("正在核对当前服务、档位和音色能力。")
        }
    }

    private var emptyCandidates: some View {
        ContentUnavailableView {
            Label("还没有候选音色", systemImage: AppRoute.voiceDesign.systemImage)
        } description: {
            Text("先填写描述，再生成一组可试听的真实音频。")
        }
    }

    private func unavailableCandidates(_ banner: AvailabilityBanner) -> some View {
        ContentUnavailableView {
            Label(banner.title, systemImage: "waveform.badge.exclamationmark")
        } description: {
            Text(banner.message)
        } actions: {
            Button(banner.actionTitle) {
                navigation.request(banner.route)
            }
        }
    }

    private var voiceDesignInspector: some View {
        let readyCount = candidates.filter { candidate in
            if case .ready = candidate.status { return true }
            return false
        }.count
        let failedCount = candidates.filter { candidate in
            if case .failed = candidate.status { return true }
            return false
        }.count
        return DeveloperInspector {
            SectionHeading(
                title: "VoiceDesign 技术摘要",
                detail: "候选试听音频仅保留在本次会话；注册时服务端会按参数重新生成并持久化参考音频。"
            )
            LabeledContent("能力门禁", value: voiceDesignAvailabilityText)
            LabeledContent("音色描述", value: "\(description.count) 字")
            LabeledContent("参考文案", value: "\(referenceText.count) 字")
            LabeledContent("候选状态", value: "\(readyCount) 个可试听 · \(failedCount) 个失败")
            LabeledContent("预览请求", value: model.isCreatingVoicePreview ? "进行中" : "空闲")
            LabeledContent("注册状态", value: model.isRegisteringVoice ? "进行中" : "空闲")
            LabeledContent("播放状态", value: playingSlot.map { "候选 \($0) 正在播放" } ?? "未播放")
            LabeledContent("候选试听音频", value: "仅本次会话，不持久化")
            LabeledContent("注册参考音频", value: "服务端重新生成并持久化")
        }
    }

    private var voiceDesignAvailabilityText: String {
        switch voiceDesignAvailability {
        case .checking:
            "正在核对"
        case .available:
            "已确认可用"
        case .requiresQuality:
            "需要 Quality 档位"
        case .serviceUnavailable:
            "TTS 服务未就绪"
        case .unsupported:
            "服务端未提供"
        }
    }

    private func appendChip(_ chip: String) {
        if description.contains(chip) { return }
        if description.hasSuffix("，") || description.hasSuffix("。") || description.hasSuffix(" ") {
            description += "\(chip)、"
        } else if description.isEmpty {
            description = chip
        } else {
            description += "，\(chip)"
        }
    }

    private var voiceDesignAvailable: Bool {
        voiceDesignAvailability.isAvailable
    }

    private var voiceNameField: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("保存名称")
                // 字段标签按稿的 `fieldLabel`：`Caption / Medium`（10pt Medium），
                // 不是 `caption`（Regular）——见 REDESIGN-SPEC §11.6 第三十七轮。
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            TextField("例如：夜航主持", text: $voiceName)
                .textFieldStyle(.plain)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                .speechRailRecessedSlot()
                .accessibilityLabel("音色保存名称")
        }
    }

    private var referenceTextField: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("试听与注册参考文案 · \(referenceText.count)/\(SpeechRailCreatorLimits.referenceTextMaximumLength)")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            TextEditor(text: $referenceText)
                .font(SpeechRailDesignTokens.Typography.body)
                .frame(minHeight: SpeechRailDesignTokens.Layout.creatorReferenceMinimumHeight)
                .scrollContentBackground(.hidden)
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .speechRailRecessedSlot()
                .accessibilityLabel("音色试听与注册参考文案")
        }
    }

    @ViewBuilder
    private var voiceDesignAvailabilityLine: some View {
        let status: (tone: StatusTone, title: String, message: String, image: String) = switch voiceDesignAvailability {
        case .checking:
            (.neutral, "正在核对 VoiceDesign", "读取当前服务、档位和能力声明。", "arrow.clockwise")
        case .available:
            (.healthy, "VoiceDesign 已确认可用", "Quality、TTS 与服务声明的 VoiceDesign capability 均已确认。", "checkmark.circle")
        case .requiresQuality:
            (.attention, "当前档位未提供 VoiceDesign", "请在模型页确认 Quality 制品并应用目标档位。", "slider.horizontal.3")
        case .serviceUnavailable:
            (.attention, "TTS 服务尚未就绪", "先恢复服务状态，再生成真实候选音频。", "exclamationmark.triangle")
        case .unsupported:
            (.critical, "服务端未公开 VoiceDesign", "服务未公开 VoiceDesign capability，请在模型页核对 Quality 制品和当前档位。", "xmark.circle")
        }

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                availabilityStatusLine(status)
                availabilityActionButton
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                availabilityStatusLine(status)
                availabilityActionButton
            }
        }
    }

    private func availabilityStatusLine(
        _ status: (tone: StatusTone, title: String, message: String, image: String)
    ) -> some View {
        SpeechRailStatusLine(
            tone: status.tone,
            title: status.title,
            message: status.message,
            systemImage: status.image
        )
    }

    @ViewBuilder
    private var availabilityActionButton: some View {
        if let banner = voiceDesignAvailabilityBanner {
            Button(banner.actionTitle) {
                navigation.request(banner.route)
            }
            .speechRailButton(.secondary)
        }
    }

    @ViewBuilder
    private var voiceDesignFeedback: some View {
        if let error = errorMessage ?? model.voiceDesignErrorMessage {
            StatusBanner(
                tone: .critical,
                title: "音色生成未完成",
                message: error,
                actionTitle: "重新生成"
            ) {
                errorMessage = nil
                startGeneration()
            }
        } else if let message = model.creatorMessage {
            StatusBanner(
                tone: .critical,
                title: "音色操作未完成",
                message: message,
                actionTitle: needsCapabilityRefresh ? "重新读取能力" : nil,
                action: needsCapabilityRefresh
                    ? {
                        Task {
                            await model.refresh()
                            await model.refreshCreatorVoices()
                        }
                    }
                    : nil
            )
        } else if let successMessage = model.voiceDesignSuccessMessage {
            StatusBanner(
                tone: .healthy,
                title: "音色已保存",
                message: successMessage,
                actionTitle: "查看音色库"
            ) {
                navigation.request(.voiceLibrary)
            }
        }
    }

    private var voiceDesignAvailability: VoiceDesignAvailability {
        guard !model.isRefreshingService,
              !model.isRefreshingCreatorVoices,
              !model.isRefreshingServiceCapabilities
        else {
            return .checking
        }
        guard let health = displayedHealth else {
            return model.healthFailure == nil ? .checking : .serviceUnavailable
        }
        guard health.profile == .quality else {
            return .requiresQuality
        }
        guard health.status == "ok", health.ttsReady == true, health.ready == true else {
            return .serviceUnavailable
        }
        // 门禁读服务声明（`/v1/models.capabilities`）。旧实现要求音色列表里先有
        // 一条可用的 voice_design 音色，等于拿用户数据当能力依据：列表为空时，
        // 能力明明已发布也会被判成“服务端未提供”。
        switch model.serviceCapabilitiesLoadState {
        case .unknown, .loading:
            return .checking
        case .failed:
            // 读不到能力清单属于服务不可用，不要把“不知道”说成“服务端未提供”。
            return .serviceUnavailable
        case .loaded:
            break
        }
        guard let capabilities = model.serviceCapabilities else {
            return .checking
        }
        return capabilities.supportsInstruction && capabilities.supportsPreview
            ? .available
            : .unsupported
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    /// 音色列表与能力声明任一读失败，都给同一个重试入口：能力结论不再依赖列表，
    /// 但两个读取都是这一页的事实来源。
    private var needsCapabilityRefresh: Bool {
        model.creatorVoicesLoadState == .failed
            || model.serviceCapabilitiesLoadState == .failed
    }

    private var voiceDesignAvailabilityBanner: AvailabilityBanner? {
        switch voiceDesignAvailability {
        case .checking, .available:
            nil
        case .requiresQuality:
            AvailabilityBanner(
                title: "音色创作需要 Quality 档位",
                message: "当前档位不会加载 VoiceDesign 能力。切换档位不会自动发生，请在模型页确认后再操作。",
                actionTitle: "去模型页切档",
                route: .models
            )
        case .serviceUnavailable:
            AvailabilityBanner(
                title: "服务尚未就绪",
                message: "当前没有确认 TTS 服务可用。请先查看服务状态，修复后再生成候选音色。",
                actionTitle: "查看服务状态",
                route: .overview
            )
        case .unsupported:
            AvailabilityBanner(
                title: "当前 TTS 不支持 VoiceDesign",
                message: "服务未公开可用的 VoiceDesign preview 能力。请在模型页核对 Quality 制品和当前档位。",
                actionTitle: "去模型页切档",
                route: .models
            )
        }
    }

    private func startGeneration() {
        let instruction = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            errorMessage = "请先填写音色描述"
            return
        }
        let previewText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (SpeechRailCreatorLimits.referenceTextMinimumLength...SpeechRailCreatorLimits.referenceTextMaximumLength)
            .contains(previewText.count)
        else {
            errorMessage = "试听与注册参考文案需要 20–240 个字符"
            return
        }
        guard instruction.count <= SpeechRailCreatorLimits.voiceInstructionMaximumLength else {
            errorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
            return
        }
        guard voiceDesignAvailable else {
            errorMessage = "当前尚未确认 VoiceDesign 能力，请先完成服务状态和音色能力检查。"
            return
        }
        errorMessage = nil
        playingSlot = nil
        selectedSlot = nil
        model.startVoiceDesignGeneration(
            instruction: instruction,
            referenceText: previewText,
            speed: 1.0
        )
    }

    private func play(_ candidate: VoiceDesignCandidateSnapshot) {
        if playingSlot == candidate.slot, model.isAudioPlaying {
            model.stopAudio()
            playingSlot = nil
            return
        }
        guard let audioData = candidate.audioData else { return }
        do {
            try model.playAudio(data: audioData)
            playingSlot = candidate.slot
            selectedSlot = candidate.slot
            errorMessage = nil
        } catch {
            errorMessage = "候选音频无法播放，请重新生成"
            playingSlot = nil
        }
    }

    private func save(_ candidate: VoiceDesignCandidateSnapshot) {
        guard model.voiceDesignSavingSlot == nil, !model.isRegisteringVoice else { return }
        guard candidate.audioData != nil else { return }
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "请先填写保存名称"
            return
        }
        errorMessage = nil
        model.saveVoiceDesignCandidate(candidate, name: name)
    }
}

/// One candidate in the 2×2 shelf. Every card keeps the same header / waveform
/// / action-row skeleton; a card without audio swaps the waveform for the
/// reason it has none, so the grid still reads as a grid (REDESIGN-SPEC §7.2).
private struct VoiceCandidateCard: View {
    let candidate: VoiceDesignCandidateSnapshot
    let isPlaying: Bool
    let isSaved: Bool
    let isSaving: Bool
    let isRegistering: Bool
    let isSelected: Bool
    let onPlayToggle: () -> Void
    let onSave: () -> Void
    let onOpenLibrary: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            header
            waveformArea
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.control)
        .overlay {
            if isSelected {
                // 底已经是容器形状：描边用同一形状，选中宽度与档位卡一致（1pt）。
                SpeechRailDesignTokens.Corner.containerShape
                    .stroke(
                        Color.accentColor,
                        lineWidth: SpeechRailDesignTokens.Stroke.strong
                    )
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 头部

    /// 头部三件套与 Figma `Candidate Tile` 一致：槽位名（Body / Medium）→
    /// 状态胶囊 → 右对齐 seed（Caption / tertiary）。四张卡共用同一骨架，
    /// 网格才读起来是网格（REDESIGN-SPEC §7.2）。
    private var header: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(candidate.title)
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                .background(statusColor.opacity(0.14), in: .capsule)

            Spacer(minLength: 0)

            Text("seed \(candidate.seed)")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    // MARK: 波形区

    @ViewBuilder
    private var waveformArea: some View {
        if isLoading || hasAudio {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                // 稿 `main.js` 1393 / 1425：波形区是 `waveRow`（`justify CENTER`）里那排
                // **18 根、间隙 3** 的琥珀条（4x 帧 `▸ 音色创作.png` 实测 87.0 × 36.0），
                // 整块在卡片里居中、竖直方向吃掉图片区剩余的高度。应用此前是 9 根 / 72 × 20
                // 且靠左贴住（REDESIGN-SPEC §11.6 第四十二轮）。
                WaveformBars(
                    pattern: SpeechRailDesignTokens.Waveform.candidateTile,
                    isPlaying: isPlaying
                )
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: reasonImage)
                    .font(SpeechRailDesignTokens.Typography.statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(reasonText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 动作行

    private var actionRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            if canRetry {
                Button("重试", action: onRetry)
                    .speechRailButton(.secondary)
                    .disabled(isRegistering)
                    .accessibilityLabel("重新生成候选 \(candidate.slot)")
            } else {
                Button(action: onPlayToggle) {
                    Label(isPlaying ? "停止" : "试听", systemImage: isPlaying ? "stop.fill" : "play.fill")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .speechRailButton(.secondary)
                .disabled(!hasAudio || isLoading)
                .accessibilityLabel("候选 \(candidate.slot) 试听：\(isPlaying ? "停止" : "播放")")
            }

            Spacer(minLength: 0)

            Text(durationText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)

            if hasAudio {
                // 保存成功后动作行改成入口而不是停用按钮：「已保存」已经由头部
                // 状态胶囊承担，这里给出下一步（REDESIGN-SPEC §7.2）。
                if isSaved {
                    Button(action: onOpenLibrary) {
                        Label("在音色库中查看", systemImage: "music.note.list")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .speechRailButton(.secondary)
                    .accessibilityLabel("在音色库中查看候选 \(candidate.slot)")
                } else {
                    Button(action: onSave) {
                        Label(
                            isSaving ? "保存中" : "保存为音色",
                            systemImage: "square.and.arrow.down"
                        )
                        .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .speechRailButton(.secondary)
                    .disabled(isSaving || isRegistering)
                    .accessibilityLabel("把候选 \(candidate.slot) 保存到音色库")
                }
            }
        }
    }

    private var canRetry: Bool {
        switch candidate.status {
        case .failed, .cancelled:
            true
        case .loading, .ready:
            false
        }
    }

    private var hasAudio: Bool {
        if case .ready = candidate.status { return candidate.audioData != nil }
        return false
    }

    private var reasonImage: String {
        switch candidate.status {
        case .failed:
            "exclamationmark.triangle.fill"
        case .cancelled:
            "stop.circle"
        case .loading:
            "hourglass"
        case .ready:
            "waveform.slash"
        }
    }

    private var reasonText: String {
        switch candidate.status {
        case let .failed(message):
            message
        case .cancelled:
            "本次生成已停止，可单独重试这一张。"
        case .loading:
            "正在生成这一张候选音频。"
        case .ready:
            "这张候选没有可试听的音频数据。"
        }
    }

    private var isLoading: Bool {
        if case .loading = candidate.status { return true }
        return false
    }

    private var statusText: String {
        switch candidate.status {
        case .loading:
            "生成中"
        case .ready:
            isSaved ? "已保存" : "可试听"
        case .cancelled:
            "已停止"
        case .failed:
            "生成失败"
        }
    }

    private var statusColor: Color {
        switch candidate.status {
        case .loading:
            SpeechRailDesignTokens.Color.attention
        case .ready:
            isSaved ? SpeechRailDesignTokens.Color.ready : SpeechRailDesignTokens.Color.voice
        case .cancelled:
            SpeechRailDesignTokens.Color.attention
        case .failed:
            SpeechRailDesignTokens.Color.critical
        }
    }

    private var durationText: String {
        guard let seconds = candidate.durationSeconds else { return "—" }
        return String(format: "%.1fs", seconds)
    }
}

/// One-time confirmation before a candidate becomes a saved voice: the name,
/// the description, the reference text and the seed all in one place
/// (REDESIGN-SPEC §7.2).
private struct VoiceCandidateSaveSheet: View {
    let candidate: VoiceDesignCandidateSnapshot
    @Binding var voiceName: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("保存候选 \(candidate.slot) 为音色")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)

            Text("服务端会按下面的描述、参考文案和 seed 重新生成参考音频并注册。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("音色名称")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                TextField("例如：夜航主持", text: $voiceName)
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                    .speechRailRecessedSlot()
                    .accessibilityLabel("音色名称")
            }

            summaryRow("音色描述", value: candidate.instructionSnapshot)
            summaryRow("参考文案", value: candidate.referenceTextSnapshot)
            summaryRow("Seed", value: String(candidate.seed))
            summaryRow("时长", value: durationText)

            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .speechRailButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("保存到音色库", action: onSave)
                    .speechRailButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(width: Self.sheetWidth, alignment: .leading)
        .onAppear { isNameFocused = true }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var durationText: String {
        guard let seconds = candidate.durationSeconds else { return "—" }
        return String(format: "%.1fs", seconds)
    }

    private static let sheetWidth: CGFloat = 420
}

/// 稿 `waveform(...)` 的落点：按给定高度序列画一排 2pt 圆角条，宽高由 `pattern` 推出。
///
/// 三处调用都渲染**同一形态**（`Color.voice` 琥珀、满高），稿上没有「未播放 = 灰且半高」
/// 这一态：候选卡用描边、动作行用「试听 / 停止」区分播放中，所以这里不再按
/// `isPlaying` 改颜色或高度。`isPlaying` 只驱动播放中的脉冲（§5.7 / §5.8 的
/// 「波形脉冲」），`reduceMotion` 下停在静态——条状视图接不了 `.symbolEffect`，
/// 因此脉冲是一段显式的透明度动画。
///
/// 2026-09-16（第五十七轮）用户指出「播放音波效果是假的」后补上两条真实通道：
/// - `levels`：条高改为这段音频**自己的幅度包络**（`AudioEnvelope`），按 `pattern`
///   重采样；`pattern.heights` 因此只决定**条数与排布**（宽度 / 间隙 / 峰值高度）。
/// - `progress`：播放中未播到的部分降到 `Waveform.remainingOpacity`，读的是
///   `AppModel.playbackProgress`（播放器真实的 `currentTime / duration`）。
///
/// 两者都没有时（这段音频还没算过——例如还没试听过的音色）退回稿的固定数组，并且
/// **只有这种情形**才保留脉冲：脉冲是「在播但画不出形状」时的状态提示，一旦能画出
/// 真实形状与进度，它只会和真实信息打架。
/// 三处波形（候选卡 / 结果条 / 目录页试听）共用的排布。内部可见而不是 `private`：
/// 音色克隆页回放刚录的那段参考音频时用它画同一件事的形状（REDESIGN-SPEC §13.2）。
struct WaveformBars: View {
    let pattern: SpeechRailDesignTokens.Waveform.Pattern
    var isPlaying = false
    /// 真实包络（0…1，条数任意）。`nil` = 这段音频还没算过。
    var levels: [CGFloat]?
    /// 播放中的真实进度（0…1）。`nil` = 当前不是在播这一段。
    var progress: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: pattern.gap) {
            ForEach(Array(resolvedHeights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Waveform.barRadius)
                    .fill(SpeechRailDesignTokens.Color.voice)
                    .opacity(opacity(at: index))
                    .frame(
                        width: SpeechRailDesignTokens.Waveform.barWidth,
                        height: height
                    )
            }
        }
        .frame(width: pattern.width, height: pattern.height)
        .opacity(isPulsing ? 0.55 : 1)
        .onAppear { isPulsing = pulses }
        .onChange(of: isPlaying) { _, playing in
            isPulsing = pulses
        }
        .onChange(of: levels?.count) { _, _ in isPulsing = pulses }
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced else { return }
            withAnimation(.linear(duration: 0.2)) { isPulsing = false }
        }
        .animation(pulseAnimation, value: isPulsing)
    }

    /// 真实包络（重采样并按 `pattern` 的峰值高度缩放），没有就退回稿的固定数组。
    private var resolvedHeights: [CGFloat] {
        guard let levels, !levels.isEmpty else { return pattern.heights }
        let peak = pattern.height
        return AudioEnvelope.resample(levels, to: pattern.heights.count).map {
            max(SpeechRailDesignTokens.Waveform.envelopeMinimumHeight, $0 * peak)
        }
    }

    /// 播放中：已播到的条满色，未播到的降一档；没在播就不分档。
    private func opacity(at index: Int) -> Double {
        guard let progress, isPlaying else { return 1 }
        let played = Double(index + 1) / Double(pattern.heights.count)
        return played <= progress ? 1 : SpeechRailDesignTokens.Waveform.remainingOpacity
    }

    /// 只有「在播 + 没开减弱动态 + 画不出真实形状」三者同时成立时才脉动。
    private var pulses: Bool {
        isPlaying && !reduceMotion && (levels?.isEmpty ?? true)
    }

    /// 只有「开始播放且没开减弱动态」时才持续脉动；其他情形立即切回静态。
    private var pulseAnimation: Animation? {
        guard isPulsing, pulses else { return nil }
        return .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
    }
}

// MARK: - 音色库 (Voice Library)

public struct VoiceLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var sampleText = "这是 SpeechRail 的音色试听。清晰、自然的声音，让每一句表达都恰到好处。"
    @State private var selectedVoiceID: String?
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var sourceFilter = VoiceSourceFilter.all
    @State private var selectionNotice: String?
    @State private var pendingDeleteVoice: CreatorVoice?
    @State private var isConfirmingDeletion = false
    @State private var deletionMessage: String?
    @State private var editingVoice: CreatorVoice?
    @State private var editorFocus = VoiceEditorSheet.Focus.name

    /// Showing both kinds at once is the only way the source column means
    /// anything, so 全部 is the default (REDESIGN-SPEC §7.3).
    private enum VoiceSourceFilter: String, CaseIterable, Identifiable {
        case all
        case system
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部"
            case .system: "系统"
            case .custom: "我的"
            }
        }
    }

    /// 详情列（inspector）的开关。
    ///
    /// 它**不是**工具栏项（REDESIGN-SPEC §11.6 第六十二轮）：窗口工具栏里每一件动作的
    /// 落点都由系统按「固定项 + 浮动间隔」重新分配，内容列右端没有可声明的槽位——
    /// 离屏实测（`--hier`，本页与「我的作品」）同一枚按钮在窗口 1120 / 1280 / 1440 /
    /// 1600pt 时分别落在 x 639.5 / 719.5 / 799.5 / 879.5（宽 44），到详情列左沿
    /// （= 窗口宽 − 360）的距离随窗口宽从 76.5 涨到 316.5；`.status` / `.secondaryAction` /
    /// 交给 inspector 自己声明 / 可拉伸容器四种写法都不改变「落点由系统分配」这件事。
    /// 内容列**首行尾端**才是与详情列左沿固定间距的位置：这一行由页面内容列承载，
    /// 它的右沿就是详情列左沿，间隔即 `Layout.contentPadding`（20pt）。
    private var voiceInspectorToggle: some View {
        PageActionButton(
            systemImage: "sidebar.right",
            helpText: showInspector ? "隐藏音色详情" : "显示音色详情"
        ) {
            showInspector.toggle()
        }
    }

    public init() {}

    public var body: some View {
        PageScaffold(route: .voiceLibrary, scrollable: false) {
            voiceLibraryBody
        } trailing: {
            voiceInspectorToggle
        }
        // Figma `filters` 的占位符逐字一致：搜索范围由占位符自己说清楚。
        .searchable(text: $searchText, placement: .toolbar, prompt: "按名称或描述搜索")
        .toolbar {
            // 这一页的主动作是新建音色：它是头部**唯一**的入口，
            // 列表页脚的重复按钮因此去掉（§6.2 / §6.4 唯一性）。
            ToolbarItem(placement: .primaryAction) {
                PageActionButton(
                    title: "新建音色",
                    systemImage: "plus",
                    helpText: "用一句话描述新音色"
                ) {
                    navigation.request(.voiceDesign)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取音色列表") {
                Task { await model.refreshCreatorVoices() }
            }
        )
        .confirmationDialog(
            "确认删除音色？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            if let voice = pendingDeleteVoice {
                Button("删除“\(voice.name)”", role: .destructive) {
                    let voiceToDelete = voice
                    pendingDeleteVoice = nil
                    Task {
                        if await model.deleteVoice(voiceToDelete) {
                            if selectedVoiceID == voiceToDelete.id {
                                selectedVoiceID = nil
                                showInspector = false
                            }
                            deletionMessage = "“\(voiceToDelete.name)” 已从当前服务音色库移除。"
                        }
                    }
                }
                .disabled(model.isDeletingVoice)
            }
            Button("取消", role: .cancel) {
                pendingDeleteVoice = nil
            }
        } message: {
            Text("删除后该音色在配音台将不再可选，引用它的作品音频文件不会被删除。系统音色不受影响；正在使用中的音色可能无法删除。")
        }
        .inspector(isPresented: $showInspector) {
            voiceInspector
        }
        .sheet(item: $editingVoice) { voice in
            VoiceEditorSheet(voice: voice, focus: editorFocus)
        }
        .task {
            await model.refreshCreatorVoices()
            syncSelectedVoice()
        }
        .task(id: selectedVoiceID) {
            guard let selectedVoiceID else { return }
            await model.refreshCreatorVoiceDetail(id: selectedVoiceID)
        }
        .onChange(of: model.creatorVoices) { _, _ in
            syncSelectedVoice()
        }
        .onDisappear {
            model.cancelVoicePreview()
            model.stopAudio()
        }
    }

    @ViewBuilder
    private var voiceLibraryBody: some View {
        if model.isRefreshingCreatorVoices && model.creatorVoices.isEmpty {
            ProgressView("正在读取服务端音色…")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if model.creatorVoices.isEmpty {
            emptyVoicesCard
        } else {
            voiceLibraryList
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let selectionNotice {
            StatusBanner(
                tone: .attention,
                title: "列表已更新",
                message: selectionNotice
            )
        }
        if let message = model.creatorMessage {
            StatusBanner(
                tone: .critical,
                title: "音色操作未完成",
                message: message,
                actionTitle: model.creatorVoicesLoadState == .failed ? "重新加载音色" : nil,
                action: model.creatorVoicesLoadState == .failed
                    ? { Task { await model.refreshCreatorVoices() } }
                    : nil
            )
        }
        if let deletionMessage {
            StatusBanner(
                tone: .healthy,
                title: "音色已删除",
                message: deletionMessage
            )
        }
    }

    private var emptyVoicesCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            statusBanners
            ContentUnavailableView {
                Label("当前没有可用音色", systemImage: AppRoute.voiceLibrary.systemImage)
            } description: {
                Text("请确认服务已就绪，或先到音色创作生成自定义音色。")
            } actions: {
                Button("去音色创作") {
                    navigation.request(.voiceDesign)
                }
                .speechRailButton(.primary)
                Button("重新加载") {
                    Task { await model.refreshCreatorVoices() }
                }
                .speechRailButton(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The list is the page: a source filter, the result count, then the system
    /// `List` that owns row selection for the inspector (REDESIGN-SPEC §7.3).
    private var voiceLibraryList: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("来源", selection: $sourceFilter) {
                    ForEach(VoiceSourceFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("按来源筛选音色")

                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

                Text(countText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .monospacedDigit()
            }

            statusBanners

            if filteredVoices.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的音色", systemImage: "magnifyingglass")
                } description: {
                    Text("换个关键词，或把来源筛选切回「全部」。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardSurface {
                    CardHead(title: "音色")
                    Divider()
                    List(selection: $selectedVoiceID) {
                        ForEach(filteredVoices) { voice in
                            voiceLibraryRow(voice)
                                .tag(voice.id)
                                // 选中行换成稿的 `surface/railTint`（§12.4 决定 15）：
                                // 系统默认是实心强调蓝，既不是稿的淡底也不跟随本 App 的强调色。
                                // 只有 `listRowBackground` 能换掉那层系统高亮，其余写法会被它合成掉。
                                .listRowBackground(
                                    voice.id == selectedVoiceID
                                        ? SpeechRailDesignTokens.Surface.selectionTint
                                        : nil
                                )
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("音色列表")
                    .onKeyPress(.space) {
                        guard let voice = selectedVoice else { return .ignored }
                        togglePreview(voice)
                        return .handled
                    }
                    Divider()
                    // 「新建音色」只在工具栏有 **一处**入口（§6.4 唯一性）：
                    // 页脚此前重复的那颗按钮已去掉，页脚只留本机事实。
                    CardFoot(note: "复刻音色保存在本机，不会上传。") { EmptyView() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「8 个音色 · 3 个来自复刻」（Figma `filters` 右侧计数）。来源拆分只在筛选
    /// 没有藏起任何音色时才成立，否则退回「筛选数 / 总数」。
    private var countText: String {
        let total = filteredVoices.count
        guard total == model.creatorVoices.count else {
            return "\(total) / \(model.creatorVoices.count) 个音色"
        }
        let cloned = filteredVoices.filter { !$0.isSystem }.count
        return cloned > 0 ? "\(total) 个音色 · \(cloned) 个来自复刻" : "\(total) 个音色"
    }

    /// One row: name, source badge, one line of description, the availability
    /// note, and the inline preview. Everything heavier lives in the inspector
    /// (REDESIGN-SPEC §7.3).
    private func voiceLibraryRow(_ voice: CreatorVoice) -> some View {
        let isPlaying = model.playingVoiceID == voice.id && model.isAudioPlaying
        let isPreviewing = model.previewingVoiceID == voice.id
        return HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(voice.name)
                        // 稿的行首是 `Body / Medium`（脚本 `row/name`），与作品行同一档。
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    sourceBadge(voice)
                }
                Text(voiceListDescription(for: voice))
                    // 副行是 `Callout`（脚本 `row/sub`）：4x 帧实测该行 ink 10.75pt ≈ 12pt，
                    // 应用此前用 `caption`（10pt）比稿小一档，也与作品行的 `callout` 不一致。
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !voice.available {
                Label("当前档位不可用", systemImage: "exclamationmark.triangle.fill")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .lineLimit(1)
            }

            Button {
                togglePreview(voice)
            } label: {
                if isPreviewing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(
                            width: SpeechRailDesignTokens.Control.iconButtonSize,
                            height: SpeechRailDesignTokens.Control.iconButtonSize
                        )
                } else {
                    RowActionGlyph(systemImage: isPlaying ? "stop" : "play")
                }
            }
            .speechRailButton(.quiet)
            .disabled(previewDisabled(for: voice))
            .accessibilityLabel(
                isPreviewing
                    ? "取消 \(voice.name) 的试听"
                    : "\(voice.name)\(isPlaying ? "停止试听" : "试听")"
            )

        }
        // 稿 `row` 是 padX 16 / padY 12。行内边距由行自己给、`listRowInsets` 清零，
        // 行高由 `pageRowMinimumHeight` 钉住：4x 帧实测三页行距 64.00 = 行框 63 + 1pt hairline，
        // 而应用的内容盒（系统行盒 16 + 4 + 15 = 35）比稿的 Figma 行盒（19.5 + 2 + 17.4）矮 3.9，
        // 所以单靠 padY 12 只有 59——那一档的账见 token 注释与 REDESIGN-SPEC §11.6 第三十七轮。
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .listRowInsets(EdgeInsets())
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.List.pageRowMinimumHeight,
            alignment: .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityHint("选中后可在右侧查看详情、重命名或删除")
    }

    private func sourceBadge(_ voice: CreatorVoice) -> some View {
        Text(voice.isSystem ? "系统" : "我的")
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            .background(
                SpeechRailDesignTokens.Surface.voiceBadgeFill,
                in: .capsule
            )
    }

    private func togglePreview(_ voice: CreatorVoice) {
        if model.previewingVoiceID == voice.id {
            model.cancelVoicePreview()
        } else if model.playingVoiceID == voice.id && model.isAudioPlaying {
            model.stopAudio()
        } else {
            model.startVoicePreview(voice, text: sampleText)
        }
    }

    private func previewDisabled(for voice: CreatorVoice) -> Bool {
        !voice.available
            || (model.isCreatingSpeech && model.previewingVoiceID != voice.id)
            || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sampleText.count > SpeechRailCreatorLimits.speechTextMaximumLength
    }

    /// 试听文案输入槽的行数区间（多行字段；两个取值都在 token 层，§11.6 第五十七轮）。
    private var previewTextLineCount: ClosedRange<Int> {
        let layout = SpeechRailDesignTokens.Layout.self
        return layout.previewTextMinimumLines...layout.previewTextMaximumLines
    }

    private var filteredVoices: [CreatorVoice] {
        let bySource = model.creatorVoices.filter { voice in
            switch sourceFilter {
            case .all: true
            case .system: voice.isSystem
            case .custom: !voice.isSystem
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return bySource }
        return bySource.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// List rows are a summary surface. Keep untrusted service descriptions from
    /// becoming an unbounded layout input; the inspector exposes a bounded
    /// description and length-only user-authored fields in its fixed-width,
    /// scrollable surface.
    private func voiceListDescription(for voice: CreatorVoice) -> String {
        let fallback = "服务端已注册，当前档位\(voice.available ? "可用" : "不可用")。"
        let normalized = voice.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumPreviewLength = SpeechRailDesignTokens.List.descriptionPreviewMaximumCharacters
        guard normalized.count > maximumPreviewLength else {
            return normalized.isEmpty ? fallback : normalized
        }
        let end = normalized.index(normalized.startIndex, offsetBy: maximumPreviewLength)
        return String(normalized[..<end]) + "…"
    }

    @ViewBuilder
    private var voiceInspector: some View {
        if let voice = selectedVoice {
            // 稿 `main.js` 1584–1631 的 Inspector 是一条竖列：身份带 → 试听行 →
            // 取值区 → 压在底部的动作区，段与段之间是**整宽**的 1pt `border/separator`
            // hairline（4x 帧 `▸ 音色库.png` 实测三条色带：y 260.0–261.0、
            // 341.0–342.0、820.0–821.0，都从卡片左沿通到右沿；§11.6 第四十五轮）。
            // 四段结构（身份带 / 试听 / 取值 / 固定动作区）与段间那条整宽 hairline
            // 由 `SpeechRailInspectorPanel` 声明一次：这一页与「我的作品」共用它，
            // 两块侧边栏的段落顺序、内边距与字号档不可能再各自漂移
            // （REDESIGN-SPEC §11.6 第五十四轮）。
            SpeechRailInspectorPanel(
                title: voice.name,
                badge: voice.isSystem ? "系统音色" : "自定义音色",
                preview: { voicePreviewSection(voice) },
                body: { voiceFactsSection(voice) },
                actions: { voiceInspectorActions(voice) }
            )
        } else {
            ContentUnavailableView(
                "请选择一个音色",
                systemImage: AppRoute.voiceLibrary.systemImage,
                description: Text("选择列表中的音色后，这里会显示试听、参数和可用性。")
            )
            // 空态也是这一列：列宽声明不能只挂在面板上，否则「列表还没读回来」的那一瞬
            // 这一列会落回系统默认宽度（离屏实测 270），与我的作品那一列读起来是两个宽度
            // （§11.6 第六十一轮）。
            .speechRailInspectorColumn()
        }
    }

    /// 取值段：服务端详情状态 + 取值行 + 描述全文。段内的间距与内边距由
    /// `SpeechRailInspectorPanel` 给，这里只管内容本身。
    @ViewBuilder
    private func voiceFactsSection(_ voice: CreatorVoice) -> some View {
        VStack(
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Inspector.sectionSpacing
        ) {
            if model.isRefreshingCreatorVoiceDetail {
                Label("正在读取服务端详情…", systemImage: "arrow.triangle.2.circlepath")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            } else if let detailMessage = model.creatorVoiceDetailMessage {
                StatusBanner(
                    tone: .attention,
                    title: "服务端详情未读取",
                    message: detailMessage,
                    actionTitle: "重新读取详情"
                ) {
                    Task { await model.refreshCreatorVoiceDetail(id: voice.id) }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                LabeledContent(
                    "可用性",
                    value: voice.available ? "可用" : "当前档位不可用"
                )
                LabeledContent("采样种子", value: voice.seed.map(String.init) ?? "未提供")
                LabeledContent("创建时间", value: createdAtText(for: voice))
                LabeledContent("变体", value: voice.variant ?? "未提供")
                LabeledContent("模式", value: voice.mode ?? "未提供")
                LabeledContent(
                    "音频时长",
                    value: voice.durationSeconds.map { String(format: "%.1f s", $0) }
                        ?? "未提供"
                )
                LabeledContent("使用次数", value: "\(worksUsing(voice).count) 个作品")
                LabeledContent("关联作品", value: relatedWorksText(for: voice))
            }
            .speechRailInspectorContent()

            voiceDescriptionSection(voice)
        }
    }

    /// The inspector opens with the one thing the page is for: hearing the
    /// voice (REDESIGN-SPEC §7.3).
    private func voicePreviewSection(_ voice: CreatorVoice) -> some View {
        let isPlaying = model.playingVoiceID == voice.id && model.isAudioPlaying
        let isPreviewing = model.previewingVoiceID == voice.id
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            // 稿 `main.js` 1594–1603：`previewWrap`（padX 16 / padY 14）里嵌一个
            // `preview` 面板 —— `gap 10 / padX 12 / padY 10 / radius 10 / fill surface/panel`
            // + 1pt `border/separator`，里面是 28pt 图标按钮与**居中**的波形。
            // 4x 帧实测面板填充带 50.0（波形 30 + 上下各 10）、外框 52.0（描边画在填充外）。
            HStack(spacing: SpeechRailDesignTokens.Inspector.previewGap) {
                Button {
                    togglePreview(voice)
                } label: {
                    if isPreviewing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(
                                width: SpeechRailDesignTokens.Control.iconButtonSize,
                                height: SpeechRailDesignTokens.Control.iconButtonSize
                            )
                    } else {
                        // 稿这里和列表行用的是同一个原语（无底色、15pt 图标框、
                        // `text/secondary`）；应用此前的琥珀实心圆是自造形态，
                        // 见 `Icon.rowActionSize` 的帧量测。
                        RowActionGlyph(systemImage: isPlaying ? "stop" : "play")
                    }
                }
                .speechRailButton(.quiet)
                .disabled(previewDisabled(for: voice))
                .accessibilityLabel(
                    isPreviewing ? "取消试听" : "\(voice.name)\(isPlaying ? "停止试听" : "试听")"
                )

                // 稿 `main.js` 1596-1601：试听行是 `play` 图标按钮 + 一排
                // **16 根、间隙 3** 的琥珀条（4x 帧 `▸ 音色库.png` 实测 77.0 × 30.0），
                // 波形整块在剩余宽度里居中（`stretch(grow(wave))`）。
                WaveformBars(
                    pattern: SpeechRailDesignTokens.Waveform.libraryPreview,
                    isPlaying: isPlaying,
                    // 试听过的音色画它自己的包络与真实进度；没试听过则退回稿的
                    // 固定图形（那时确实还没有音频可画，§11.6 第五十七轮）。
                    levels: model.waveformEnvelope(forVoiceID: voice.id),
                    progress: isPlaying ? model.playbackProgress : nil
                )
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
            // 面板底色、描边、半径与稿 `previewWrap` 的上下 14pt 留白都归
            // `speechRailInspectorPreviewPanel()` 一处（音色库与我的作品共用它）。
            .speechRailInspectorPreviewPanel()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("试听文案 · \(sampleText.count)/\(SpeechRailCreatorLimits.speechTextMaximumLength)")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(
                        sampleText.count > SpeechRailCreatorLimits.speechTextMaximumLength
                            ? SpeechRailDesignTokens.Color.critical
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                // 这个槽是应用自有的入口（稿上没有，§11.6 第四十五轮 ⑤），上限
                // 4096 字——**单行放不下**。单行字段的宽度由内容决定，长文案会让
                // 「详情列多宽」变成「用户打了多少字」的函数；改成多行后宽度回给
                // 容器，长文案改在槽内换行，两行起、五行封顶，再长由原生编辑器
                // 内部滚动（REDESIGN-SPEC §11.6 第五十七轮）。
                TextField("输入试听文案", text: $sampleText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(previewTextLineCount)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Control.regularHeight,
                        alignment: .topLeading
                    )
                    .speechRailRecessedSlot()
                    .accessibilityLabel("音色试听文案")
            }
            // 段尾留白：这块「试听文案」输入区是应用自有的（稿上没有入口，§11.6 第四十五轮 ⑤），
            // 它排在试听面板之后、试听段之内，因此这不属于面板自己的 `padY 14`。没有这层留白
            // 时，输入槽的下边框直接贴住下面那条 hairline、再贴住「可用性」表（用户复核：
            // 「试听文案下方应该留有一定间距，不要与下方的表格紧挨着」）。取值用试听段自己的
            // 那档留白（`Inspector.previewWrapInsetY` = 稿 `previewWrap` 的 `padY 14`）：试听段
            // 因此上下都是 14pt，与我的作品那一页（段尾只有面板自带的 14pt）同值
            // （REDESIGN-SPEC §11.6 第六十一轮）。
            .padding(.bottom, SpeechRailDesignTokens.Inspector.previewWrapInsetY)
        }
    }

    /// The full description, not a clipped preview: the inspector is where an
    /// untrusted service description is allowed to be long
    /// (REDESIGN-SPEC §7.3).
    @ViewBuilder
    private func voiceDescriptionSection(_ voice: CreatorVoice) -> some View {
        if !voice.description.isEmpty {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("描述")
                    // 稿 `sideBody` 的字段标签是 `Caption / Medium`（10pt Medium）：与本段
                    // 同级的「试听文案」已经用这一档，原来这一处用 `caption`（10 Regular）
                    // 又比它轻一档，同一块面板里出现两种标签字重（§11.6 第五十四轮）。
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(voice.description)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func voiceInspectorActions(_ voice: CreatorVoice) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button("去配音台") {
                navigation.request(.dubbing)
            }
            .speechRailButton(.primary)

            if !voice.isSystem {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("重命名") {
                        editorFocus = .name
                        editingVoice = voice
                    }
                    .speechRailButton(.secondary)
                    .disabled(model.isUpdatingVoice)

                    Button("编辑描述") {
                        editorFocus = .instruction
                        editingVoice = voice
                    }
                    .speechRailButton(.secondary)
                    .disabled(model.isUpdatingVoice || voice.mode == "clone")

                    Spacer(minLength: 0)

                    Button("删除", role: .destructive) {
                        deletionMessage = nil
                        pendingDeleteVoice = voice
                        isConfirmingDeletion = true
                    }
                    // 稿的 `actions` 里三颗都是同一个次级按钮（`secondaryButton`），
                    // 删除没有单独的红底；`role` 保留给无障碍，视觉仍走次级档。
                    .speechRailButton(.secondary)
                    .disabled(model.isDeletingVoice)
                }
            }

            if showDeveloperDetails {
                DisclosureGroup("技术上下文") {
                    VStack(alignment: .leading, spacing: 0) {
                        LabeledContent(
                            "本音色支持 instruction",
                            value: voice.capabilities.supportsInstruction ? "是" : "否"
                        )
                        LabeledContent(
                            "本音色来自参考音频复刻",
                            value: voice.capabilities.supportsClone ? "是" : "否"
                        )
                        LabeledContent(
                            "instruction",
                            value: voice.instruction.isEmpty
                                ? "未提供"
                                : "\(voice.instruction.count) 字（内容未展示）"
                        )
                        LabeledContent(
                            "参考文案",
                            value: voice.refText.map { "\($0.count) 字（内容未展示）" } ?? "未提供"
                        )
                    }
                    .speechRailInspectorContent()
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                }
                .font(SpeechRailDesignTokens.Typography.callout)
                .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
            }
        }
    }

    private func worksUsing(_ voice: CreatorVoice) -> [CreativeWork] {
        model.works.filter { $0.voiceID == voice.id || $0.voiceName == voice.name }
    }

    private func relatedWorksText(for voice: CreatorVoice) -> String {
        guard let latest = worksUsing(voice).max(by: { $0.createdAt < $1.createdAt }) else {
            return "还没有作品使用它"
        }
        return "最近：\(latest.title)"
    }

    private var selectedVoice: CreatorVoice? {
        guard let selectedVoiceID else { return nil }
        return model.creatorVoices.first { $0.id == selectedVoiceID }
    }

    private func syncSelectedVoice() {
        guard let firstVoice = model.creatorVoices.first(where: \.available) ?? model.creatorVoices.first else {
            if selectedVoiceID != nil {
                selectionNotice = "原选音色已不在服务端列表中。"
            }
            selectedVoiceID = nil
            return
        }
        guard let selectedVoiceID,
              model.creatorVoices.contains(where: { $0.id == selectedVoiceID })
        else {
            if self.selectedVoiceID != nil {
                selectionNotice = "原选音色已不在服务端列表中，已选择“\(firstVoice.name)”。"
            }
            self.selectedVoiceID = firstVoice.id
            return
        }
    }

    private func createdAtText(for voice: CreatorVoice) -> String {
        guard voice.createdAt > 0 else { return "未提供" }
        return Date(timeIntervalSince1970: voice.createdAt)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct VoiceEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The inspector offers 重命名 and 编辑描述 as separate commands; both open
    /// this sheet, so it has to know which field the user meant
    /// (REDESIGN-SPEC §7.3).
    enum Focus {
        case name
        case instruction
    }

    let voice: CreatorVoice
    let focus: Focus
    @FocusState private var focusedField: Focus?
    @State private var name: String
    @State private var instruction: String
    @State private var seedText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(voice: CreatorVoice, focus: Focus = .name) {
        self.voice = voice
        self.focus = focus
        _name = State(initialValue: voice.name)
        _instruction = State(initialValue: voice.instruction)
        _seedText = State(initialValue: String(voice.seed ?? 42))
    }

    private var isClone: Bool {
        voice.mode == "clone"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            SectionHeading(
                title: "编辑音色",
                detail: isClone
                    ? "可修改显示名称；参考音频、来源和质量记录保持不变。"
                    : "修改后会写入当前 SpeechRail 服务，并同步到所有使用该音色的入口。"
            )

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("名称")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                TextField("音色名称", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                    // 可编辑 = 输入槽（带 1pt `border/strong` 边界）；`.speechRailField()`
                    // 留给非输入的状态/操作槽（第四十八轮定形状、第五十一轮定边界语义）。
                    .speechRailRecessedSlot()
                    .accessibilityLabel("音色名称")
            }

            if isClone {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Label("参考来源不可编辑", systemImage: "lock.fill")
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("这是由 VoiceDesign 生成的参考音色。修改名称不会替换参考音频或来源证明。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
                .speechRailContentSurface()
            } else {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("音色描述")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    TextEditor(text: $instruction)
                        .focused($focusedField, equals: .instruction)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: SpeechRailDesignTokens.Layout.creatorVoiceInstructionMinimumHeight)
                        .padding(SpeechRailDesignTokens.Spacing.xs)
                        .speechRailRecessedSlot()
                        .accessibilityLabel("自然语言音色描述")
                    Text("\(instruction.count)/\(SpeechRailCreatorLimits.voiceInstructionMaximumLength)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("采样种子")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    TextField("0–4294967295", text: $seedText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                        .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                        .speechRailRecessedSlot()
                        .accessibilityLabel("采样种子")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .speechRailButton(.secondary)
                Button("保存") {
                    save()
                }
                .speechRailButton(.primary)
                .disabled(isSaving || model.isUpdatingVoice)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.xl)
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.creatorEditorMinimumWidth,
            minHeight: isClone
                ? SpeechRailDesignTokens.Layout.creatorEditorCloneMinimumHeight
                : SpeechRailDesignTokens.Layout.creatorEditorMinimumHeight
        )
        .onAppear { focusedField = focus }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "音色名称不能为空"
            return
        }

        let nameUpdate = trimmedName == voice.name ? nil : trimmedName
        var instructionUpdate: String?
        var seedUpdate: Int?
        if isClone {
            instructionUpdate = nil
            seedUpdate = nil
        } else {
            let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInstruction.isEmpty else {
                errorMessage = "音色描述不能为空"
                return
            }
            guard trimmedInstruction.count <= SpeechRailCreatorLimits.voiceInstructionMaximumLength else {
                errorMessage = "音色描述不能超过 \(SpeechRailCreatorLimits.voiceInstructionMaximumLength) 个字符"
                return
            }
            guard let parsedSeed = Int(seedText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...Int(UInt32.max)).contains(parsedSeed)
            else {
                errorMessage = "采样种子必须在 0–4294967295 之间"
                return
            }
            instructionUpdate = trimmedInstruction == voice.instruction ? nil : trimmedInstruction
            seedUpdate = parsedSeed == voice.seed ? nil : parsedSeed
        }

        guard nameUpdate != nil || instructionUpdate != nil || seedUpdate != nil else {
            errorMessage = "没有可保存的音色修改"
            return
        }

        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            let success = await model.updateVoice(
                voice,
                name: nameUpdate,
                instruction: instructionUpdate,
                seed: seedUpdate
            )
            isSaving = false
            if success {
                dismiss()
            } else {
                errorMessage = model.creatorMessage ?? "音色修改未保存，请重试"
            }
        }
    }
}

// MARK: - 我的作品 (Works with Privacy Boundary & Inspector)

public struct WorksView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var selectedWorkID: String?
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var sortOrder = WorkSortOrder.newestFirst
    @State private var pendingDeleteWork: CreativeWork?
    @State private var isConfirmingDeletion = false
    @State private var renamingWork: CreativeWork?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var exportDocument = WAVFileDocument(data: Data())
    @State private var exportFileName = "SpeechRail-作品"
    @State private var isExporting = false
    @State private var exportMessage: String?

    private enum WorkSortOrder: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newestFirst: "最新优先"
            case .oldestFirst: "最早优先"
            }
        }
    }

    /// Figma `cols`：时长列 64pt，动作列 = 三个 28pt 图标按钮 + 两个 4pt 间距。
    private static let durationColumnWidth: CGFloat = 64
    private static let actionColumnWidth: CGFloat =
        SpeechRailDesignTokens.Control.iconButtonSize * 3 + SpeechRailDesignTokens.Spacing.micro * 2

    /// 详情列（inspector）的开关。落点与理由见 `VoiceLibraryView.voiceInspectorToggle`
    /// （REDESIGN-SPEC §11.6 第六十二轮）：作品的动作都挂在**那一行作品**上
    /// （行内「⋯」+ 右键菜单），导出另有 ⌘E，内容列首行尾端只放这一枚列开关。
    private var worksInspectorToggle: some View {
        PageActionButton(
            systemImage: "sidebar.right",
            helpText: showInspector ? "隐藏作品详情" : "显示作品详情"
        ) {
            showInspector.toggle()
        }
    }

    public init() {}

    public var body: some View {
        PageScaffold(route: .works, scrollable: false) {
            worksBody
        } trailing: {
            worksInspectorToggle
        }
        .focusedSceneValue(
            \.selectedWorkCommand,
            selectedWork.map { work in
                SelectedWorkCommand(title: work.displayTitle) {
                    prepareExport(for: work)
                }
            }
        )
        // Figma `toolbar` 的占位符逐字一致。
        .searchable(text: $searchText, placement: .toolbar, prompt: "按标题搜索")
        .inspector(isPresented: $showInspector) {
            worksInspector
        }
        .confirmationDialog(
            "删除作品？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            if let work = pendingDeleteWork {
                Button("删除“\(work.displayTitle)”", role: .destructive) {
                    let workToDelete = work
                    pendingDeleteWork = nil
                    if model.deleteWork(workToDelete), selectedWorkID == workToDelete.id {
                        selectedWorkID = model.works.first?.id
                    }
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteWork = nil
            }
        } message: {
            Text("作品条目和它的音频文件会一起从本机移除，且不可恢复。")
        }
        .sheet(isPresented: $isRenaming) {
            renameSheet
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .wav,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                exportMessage = "已将“\(exportFileName).wav”导出到你选择的位置。"
            case .failure:
                exportMessage = "导出失败：未能写入目标位置，请重试。"
            }
        }
        .task {
            model.refreshWorks()
            if selectedWorkID == nil {
                selectedWorkID = model.works.first?.id
            }
        }
        .onChange(of: model.works) { _, works in
            guard let selectedWorkID else { return }
            if !works.contains(where: { $0.id == selectedWorkID }) {
                self.selectedWorkID = works.first?.id
            }
        }
        .onDisappear {
            model.stopAudio()
        }
    }

    @ViewBuilder
    private var worksBody: some View {
        if model.works.isEmpty, model.worksMessage == nil {
            emptyWorksCard
        } else if !model.works.isEmpty {
            worksListSurface
        } else {
            worksFeedbackSection
        }
    }

    @ViewBuilder
    private var worksFeedbackSection: some View {
        if let message = model.worksMessage {
            StatusBanner(
                tone: .critical,
                title: "作品历史暂时不可用",
                message: message,
                actionTitle: "重新加载"
            ) {
                model.refreshWorks()
            }
        }

        if let message = model.workPlaybackMessage {
            StatusBanner(
                tone: .critical,
                title: "作品音频无法播放",
                message: message
            )
        }

        if let exportMessage {
            StatusBanner(
                tone: exportMessage.hasPrefix("导出失败") ? .critical : .healthy,
                title: exportMessage.hasPrefix("导出失败") ? "导出未完成" : "作品已导出",
                message: exportMessage,
                actionTitle: nil,
                action: nil
            )
        }

        if let message = model.workActionMessage {
            StatusBanner(
                tone: .healthy,
                title: "作品已更新",
                message: message
            )
        }
    }

    private var emptyWorksCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            worksFeedbackSection
            ContentUnavailableView {
                Label("还没有作品", systemImage: AppRoute.works.systemImage)
            } description: {
                Text("在配音台生成一段音频后，作品会保存在这里。")
            } actions: {
                Button("去配音台") {
                    navigation.request(.dubbing)
                }
                .speechRailButton(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            SectionHeading(
                title: "重命名作品",
                detail: "只修改显示名称；音频文件按标识命名，不会被移动或重写。"
            )
            TextField("作品名称", text: $renameText)
                .textFieldStyle(.plain)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                .speechRailRecessedSlot()
                .accessibilityLabel("作品名称")
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Spacer(minLength: 0)
                Button("取消") {
                    renamingWork = nil
                    isRenaming = false
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.cancelAction)
                Button("重命名") {
                    commitRename()
                }
                .speechRailButton(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(width: 400, alignment: .leading)
    }

    @ViewBuilder
    private var worksInspector: some View {
        if let work = selectedWork ?? model.works.first {
            // 与音色库共用同一个结构声明（`SpeechRailInspectorPanel`）：身份带 / 试听 /
            // 取值 / 固定动作区，段间一条整宽 hairline。此前这一页是另一套——用
            // `SectionHeading`（13pt + 12pt）当标题带、唯一那条 `Divider` 被 16pt
            // 内边距缩进、动作散在正文与滚动内容里（重命名/删除跟着内容滚走），
            // 于是同一个窗口里两块侧边栏读起来像两个体系（§11.6 第五十四轮）。
            SpeechRailInspectorPanel(
                title: work.displayTitle,
                badge: "本机作品",
                preview: { workPreviewSection(work) },
                body: { workFactsSection(work) },
                actions: { workInspectorActions(work) }
            )
        } else {
            ContentUnavailableView(
                "请选择一个作品",
                systemImage: AppRoute.works.systemImage,
                description: Text("选择列表中的作品后，这里会显示文稿、音频和参数。")
            )
            // 与音色库同一条列宽声明（见 `speechRailInspectorColumn()`）。
            .speechRailInspectorColumn()
        }
    }

    /// 试听段：与音色库同形——稿 `preview` 那个嵌套面板里是「28pt 图标按钮 +
    /// 居中波形」。作品也是听觉对象，详情面板的第一件事同样是「听它」
    /// （§7.4：行内主动作是播放）。
    private func workPreviewSection(_ work: CreativeWork) -> some View {
        let playing = isPlaying(work)
        return HStack(spacing: SpeechRailDesignTokens.Inspector.previewGap) {
            Button {
                model.playWork(work)
            } label: {
                RowActionGlyph(systemImage: playing ? "stop" : "play")
            }
            .speechRailButton(.quiet)
            .accessibilityLabel(playing ? "停止试听" : "试听")

            WaveformBars(
                pattern: SpeechRailDesignTokens.Waveform.resultBar,
                isPlaying: playing,
                levels: model.waveformEnvelope(forWorkID: work.id),
                progress: playing ? model.playbackProgress : nil
            )
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .speechRailInspectorPreviewPanel()
        // 选中哪一条作品就先把那一条的包络算好（命中缓存立即返回），于是「点开详情
        // 就能看见这段音频的形状」，不必先播一遍（§11.6 第五十七轮）。
        .task(id: work.id) {
            model.prepareWaveform(for: work)
        }
    }

    /// 取值段：作品的可靠事实 + 文稿全文 + 本机存储说明。
    @ViewBuilder
    private func workFactsSection(_ work: CreativeWork) -> some View {
        VStack(
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Inspector.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                LabeledContent("音色", value: work.voiceName)
                LabeledContent(
                    "生成时间",
                    value: work.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent("音频时长", value: durationText(for: work))
                LabeledContent("格式", value: "WAV")
                LabeledContent("文稿字数", value: "\(work.scriptText.count) 字")
            }
            .speechRailInspectorContent()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("文稿")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(work.scriptText)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Text("作品正文和音频保存在本机 Application Support，不会写入 SpeechRail 仓库。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 固定动作区：作品的动作与行内「⋯」/右键菜单同源，导出另有 `⌘E`
    /// （`File ▸ 导出选中作品…`）。主按钮给导出，其次是在 Finder 中显示 / 重命名 / 删除；
    /// 这一格**不随内容滚动**，破坏性动作不会再被正文推走。
    @ViewBuilder
    private func workInspectorActions(_ work: CreativeWork) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button("导出…") {
                prepareExport(for: work)
            }
            .speechRailButton(.primary)

            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("在 Finder 中显示") {
                    revealInFinder(work)
                }
                .speechRailButton(.secondary)

                Button("重命名") {
                    beginRename(work)
                }
                .speechRailButton(.secondary)

                Spacer(minLength: 0)

                Button("删除", role: .destructive) {
                    requestDelete(work)
                }
                .speechRailButton(.secondary)
            }

            if showDeveloperDetails {
                DisclosureGroup("技术上下文") {
                    VStack(alignment: .leading, spacing: 0) {
                        LabeledContent("音色 ID", value: work.voiceID)
                        LabeledContent("音频文件", value: work.audioFileName)
                        LabeledContent("采样率", value: "未提供（遵循服务配置）")
                        LabeledContent("请求延迟", value: "未提供（当前协议未返回）")
                    }
                    .speechRailInspectorContent()
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                }
                .font(SpeechRailDesignTokens.Typography.callout)
                .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
            }
        }
    }

    private var worksListSurface: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("排序", selection: $sortOrder) {
                    ForEach(WorkSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("作品排序方式")

                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

                Text(countText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .monospacedDigit()
            }

            worksFeedbackSection

            if filteredWorks.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的作品", systemImage: "magnifyingglass")
                } description: {
                    Text("换个关键词试试，或清空搜索框。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardSurface {
                    workColumnsHeader
                    Divider()
                    List(selection: $selectedWorkID) {
                        ForEach(filteredWorks) { work in
                            workListRow(work)
                                .tag(work.id)
                                // 同音色库列表：选中行取稿的 `surface/railTint`（§12.4 决定 15）。
                                .listRowBackground(
                                    work.id == selectedWorkID
                                        ? SpeechRailDesignTokens.Surface.selectionTint
                                        : nil
                                )
                                .contextMenu {
                                    workContextMenu(work)
                                }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("作品列表")
                    .onKeyPress(.space) {
                        guard let work = selectedWork else { return .ignored }
                        model.playWork(work)
                        return .handled
                    }
                    Divider()
                    CardFoot(note: "导出快捷键 ⌘E。删除作品会同时移除本地音频文件。") {
                        Group {
                            Button {
                                navigation.request(.dubbing)
                            } label: {
                                Label("新建配音", systemImage: AppRoute.dubbing.systemImage)
                            }
                            .speechRailButton(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Figma `cols`：列头让右侧的时长与行内动作不再像无主的装饰
    /// （REDESIGN-SPEC §7.4）。
    private var workColumnsHeader: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("作品")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("时长")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: Self.durationColumnWidth, alignment: .trailing)
            Text("操作")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: Self.actionColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        // 稿 `cols` 是 padX 16 / padY 10 + `Caption / Medium`（10pt，行高 13.5）= 33.5，
        // 帧实测 33.75（`▸ 我的作品.png` y=181..214.75）。
        //
        // 2026-09-16 第三十五轮改成稿的 **10**：此前取 4pt 节奏里的 `sm`(12) 是为了「和下方行
        // 同为 padY 12」，但列头不是列表行（行是 padY 12 + 两行内容 = 64，列头只有一行），
        // 套上去让带高变成 12 + 13 + 12 = **37**，比帧高 3.25pt。取 10 后 10 + 13 + 10 = 33，
        // 残差 0.75；`Settings.rowLabelSpacing`(3) 先例说明「稿的非 4 倍数值可以直接用」。
        // 离屏实测：分隔线由 y=158 上移到 y=154（上下各收 2pt）。
        .padding(.vertical, Self.columnsHeaderVerticalPadding)
    }

    /// 稿 `cols` 的 `padY: 10`。
    private static let columnsHeaderVerticalPadding: CGFloat = 10

    private func workListRow(_ work: CreativeWork) -> some View {
        let isPlaying = model.playingWorkID == work.id && model.isAudioPlaying

        return HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                // 名称按可用宽度自然截断：窗口越宽显示越多，不再被写入时的 24 字上限钉死
                // （2026-09-16 用户反馈，`CreativeWork.generatedTitle` / `displayTitle`）。
                Text(work.displayTitle)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(workListSummary(work))
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(durationText(for: work))
                .font(SpeechRailDesignTokens.Typography.callout)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
                .frame(width: Self.durationColumnWidth, alignment: .trailing)

            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Button {
                    model.playWork(work)
                } label: {
                    RowActionGlyph(systemImage: isPlaying ? "stop" : "play")
                }
                .speechRailButton(.quiet)
                .accessibilityLabel("\(work.displayTitle)\(isPlaying ? "停止试听" : "试听")")

                Button {
                    prepareExport(for: work)
                } label: {
                    RowActionGlyph(systemImage: "square.and.arrow.down")
                }
                .speechRailButton(.quiet)
                .accessibilityLabel("导出 \(work.displayTitle)")

                Menu {
                    workContextMenu(work)
                } label: {
                    RowActionGlyph(systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作：\(work.displayTitle)")
            }
            .frame(width: Self.actionColumnWidth, alignment: .trailing)
        }
        // 与音色库行同一条规则（稿 `row` = padX 16 / padY 12）：显示行填满、行高钉到帧的 63。
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .listRowInsets(EdgeInsets())
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.List.pageRowMinimumHeight,
            alignment: .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityHint("选中后可导出、在 Finder 中显示、重命名或删除")
        // UI 测试按标识定位行并选中：行标签本身是按标题拼出来的，测试侧无法先验
        // 知道标题，所以给一个稳定的标识（同页 `workspace-title` 的同类做法）。
        .accessibilityIdentifier("work-row")
    }

    /// 「时间 · 音色」：作品行只有这两条可靠事实。设计稿还画了「24-bit 44.1 kHz」，
    /// 但服务的公开 PCM profile 是 24 kHz / 16-bit / 单声道
    /// （`backends/qwen3_tts.py`、`domain/tts.py`），行内不写与实测不符的格式声明。
    private func workListSummary(_ work: CreativeWork) -> String {
        "\(work.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(work.voiceName)"
    }

    @ViewBuilder
    private func workContextMenu(_ work: CreativeWork) -> some View {
        Button {
            model.playWork(work)
        } label: {
            Label(
                isPlaying(work) ? "停止试听" : "试听",
                systemImage: isPlaying(work) ? "stop" : "play"
            )
        }
        Divider()
        Button {
            prepareExport(for: work)
        } label: {
            Label("导出…", systemImage: "square.and.arrow.down")
        }
        Button {
            revealInFinder(work)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        Divider()
        Button {
            beginRename(work)
        } label: {
            Label("重命名…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            requestDelete(work)
        } label: {
            Label("删除…", systemImage: "trash")
        }
    }

    private func durationText(for work: CreativeWork) -> String {
        work.durationText ?? "未读取"
    }

    private func isPlaying(_ work: CreativeWork) -> Bool {
        model.playingWorkID == work.id && model.isAudioPlaying
    }

    private var filteredWorks: [CreativeWork] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 搜索匹配**界面上显示的名称**（`displayTitle`），不是磁盘里那一版：旧记录
        // 存的是「24 字 + …」，用 `title` 匹配会让用户搜一个明明看得见的词却搜不到
        // （第五十一轮）。
        let matched = query.isEmpty
            ? model.works
            : model.works.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
        return matched.sorted { left, right in
            sortOrder == .newestFirst
                ? left.createdAt > right.createdAt
                : left.createdAt < right.createdAt
        }
    }

    /// 「8 个作品 · 共 11:05」（Figma `toolbar` 右侧计数）。总时长只在每条作品
    /// 都读出时长时才相加，不把「未读取」当成 0。
    private var countText: String {
        let total = filteredWorks.count
        guard total == model.works.count else {
            return "\(total) / \(model.works.count) 个作品"
        }
        let durations = filteredWorks.compactMap(\.durationSeconds)
        guard total > 0, durations.count == total else { return "\(total) 个作品" }
        let seconds = Int(durations.reduce(0, +).rounded())
        // 与作品行的时长同形（零填充 mm:ss），否则同一个工具栏里会出现
        // 「共 9:05」配「09:05」两种写法（REDESIGN-SPEC §11.6 第四十一轮）。
        return "\(total) 个作品 · 共 \(String(format: "%02d:%02d", seconds / 60, seconds % 60))"
    }

    private func revealInFinder(_ work: CreativeWork) {
        guard let url = model.workAudioURL(work) else {
            exportMessage = "导出失败：作品音频暂时不可用，请重新生成或重试。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginRename(_ work: CreativeWork) {
        renamingWork = work
        renameText = work.displayTitle
        isRenaming = true
    }

    private func commitRename() {
        guard let work = renamingWork else { return }
        if model.renameWork(work, title: renameText) {
            renamingWork = nil
            isRenaming = false
        }
    }

    private func requestDelete(_ work: CreativeWork) {
        pendingDeleteWork = work
        isConfirmingDeletion = true
    }

    private var selectedWork: CreativeWork? {
        guard let selectedWorkID else { return nil }
        return model.works.first(where: { $0.id == selectedWorkID })
    }

    private func prepareExport(for work: CreativeWork) {
        do {
            exportDocument = WAVFileDocument(data: try model.loadWorkAudio(work))
            exportFileName = work.exportBaseName
            exportMessage = nil
            isExporting = true
        } catch {
            exportMessage = "导出失败：作品音频暂时不可用，请重新生成或重试。"
        }
    }
}

private struct WAVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    static var writableContentTypes: [UTType] { [.wav] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
