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
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @SceneStorage("speechrail.dubbing.text") private var dubbingText = "在星际航行的漫长岁月里，人类学会了倾听寂静。每当脉冲信号穿越猎户座悬臂，控制台都会闪烁起熟悉的琥珀色微光。"
    @SceneStorage("speechrail.dubbing.voiceID") private var selectedVoiceID = ""
    /// `0` means "this window has no opinion yet", so the Settings default
    /// applies until the user moves the control in this window
    /// (REDESIGN-SPEC §7.10).
    @SceneStorage("speechrail.dubbing.speed") private var storedSpeed: Double = 0
    @AppStorage("speechrail.creator.defaultVoiceID") private var defaultVoiceID = ""
    @AppStorage("speechrail.creator.defaultSpeed") private var defaultSpeed: Double = 1.0
    @State private var showInspector = false
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
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "刷新服务状态，或打开服务状态页") {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新服务状态", systemImage: "arrow.clockwise")
                            .speechRailMenuRow()
                    }
                    .disabled(model.isRefreshingService)
                    Divider()
                    Button {
                        navigation.request(.overview)
                    } label: {
                        Label("查看服务状态", systemImage: AppRoute.overview.systemImage)
                            .speechRailMenuRow()
                    }
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                        .speechRailMenuRow()
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
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
        .onAppear {
            showInspector = showDeveloperDetails
        }
        .onChange(of: showInspector) { _, value in
            showDeveloperDetails = value
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

    /// The script owns the remaining window height. The count and the clear
    /// action belong to the editor they act on, so they live inside the same
    /// card, under a divider (§7.1).
    private var scriptCard: some View {
        VStack(spacing: 0) {
            TextEditor(text: $dubbingText)
                .font(SpeechRailDesignTokens.Typography.body)
                .lineSpacing(Self.scriptLineSpacing)
                .scrollContentBackground(.hidden)
                .padding(SpeechRailDesignTokens.Spacing.sm)
                .focused($isScriptFocused)
                .accessibilityLabel("配音文稿")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                scriptCountLabel
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Button("清空") {
                    dubbingText = ""
                }
                .buttonStyle(.borderless)
                .disabled(dubbingText.isEmpty)
                .accessibilityLabel("清空文稿")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
        .background(Color(nsColor: .textBackgroundColor), in: ConcentricRectangle())
        .overlay { scriptFocusRing }
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
            Text("\(count)/\(limit) 字")
                .monospacedDigit()
        }
        .font(SpeechRailDesignTokens.Typography.caption)
        .foregroundStyle(
            isOverLimit
                ? SpeechRailDesignTokens.Color.critical
                : SpeechRailDesignTokens.Color.inkSecondary
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文稿 \(count) 字，上限 \(limit) 字")
    }

    @ViewBuilder
    private var scriptFocusRing: some View {
        ConcentricRectangle()
            .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
            .opacity(isScriptFocused ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: 控制条

    /// One bar under the script. Narrow windows get two rows with the same
    /// controls rather than a squeezed single row (§7.1).
    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: SpeechRailDesignTokens.Spacing.md) {
                voicePickerButton
                speedControl
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                generateButton
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                voicePickerButton
                speedControl
                generateButton
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.panel)
    }

    private var voicePickerButton: some View {
        Button {
            isVoicePickerPresented = true
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform")
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
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: SpeechRailDesignTokens.Layout.creatorVoicePickerWidth, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
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
            in: ConcentricRectangle()
        )
    }

    private var speedControl: some View {
        let isSpeedLocked = selectedVoice?.mode == "clone"
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("语速")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Text(String(format: "%.1fx", speechSpeed))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Slider(value: speechSpeedBinding, in: 0.5...2.0, step: 0.1)
                    .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                    .disabled(isSpeedLocked)
                    .accessibilityLabel("语速")

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
                Label("生成语音", systemImage: "waveform.badge.plus")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying(work))
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    .accessibilityHidden(true)

                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(work.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let durationText = work.durationText {
                        Text("· \(durationText)")
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

                Button("查看我的作品") {
                    navigation.request(.works)
                }
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
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
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
                Text("配音未完成")
                    .font(SpeechRailDesignTokens.Typography.label)
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Button("重试") {
                startSynthesis()
            }
            .disabled(!canGenerate)
            Button("查看诊断") {
                navigation.request(.diagnostics)
            }
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
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var showInspector = false
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "刷新服务状态，或查看开发信息") {
                    Button {
                        Task {
                            await model.refresh()
                            await model.refreshCreatorVoices()
                        }
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                            .speechRailMenuRow()
                    }
                    .disabled(model.isRefreshingCreatorVoices)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                        .speechRailMenuRow()
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
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
            showInspector = showDeveloperDetails
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
        .onChange(of: showInspector) { _, value in
            showDeveloperDetails = value
        }
    }

    /// Three steps, not a form: describe the voice, keep the reference text and
    /// the name out of the way until they are needed, then audition candidates
    /// (§7.2).
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(spacing: 0) {
                TextEditor(text: $description)
                    .focused($isEditorFocused)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                    .accessibilityLabel("音色描述")
                    .frame(minHeight: SpeechRailDesignTokens.Layout.creatorVoiceInstructionMinimumHeight)

                Divider()

                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    descriptionCountLabel
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Text("描述决定音色，参考文案只用于试听与保存。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
            }
            .background(Color(nsColor: .textBackgroundColor), in: ConcentricRectangle())
            .overlay { descriptionFocusRing }

            acousticChipRow
            voiceDesignAvailabilityLine

            DisclosureGroup("更多设置", isExpanded: $showsAdvanced) {
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
            .font(SpeechRailDesignTokens.Typography.label)

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                generateCandidatesButton
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .speechRailSurface(.panel)
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
            Text("\(count)/\(limit)")
                .monospacedDigit()
        }
        .font(SpeechRailDesignTokens.Typography.caption)
        .foregroundStyle(
            isOverLimit
                ? SpeechRailDesignTokens.Color.critical
                : SpeechRailDesignTokens.Color.inkSecondary
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("描述 \(count) 字，上限 \(limit) 字")
    }

    @ViewBuilder
    private var descriptionFocusRing: some View {
        ConcentricRectangle()
            .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
            .opacity(isEditorFocused ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var acousticChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(acousticChips, id: \.self) { chip in
                    Button {
                        appendChip(chip)
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                            Image(systemName: "plus")
                                .font(SpeechRailDesignTokens.Typography.technical)
                            Text(chip)
                        }
                        .font(SpeechRailDesignTokens.Typography.caption)
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
                Label("生成候选音色", systemImage: AppRoute.voiceDesign.systemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
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
                .font(SpeechRailDesignTokens.Typography.caption)
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
                .font(SpeechRailDesignTokens.Typography.caption)
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
            (.neutral, "正在核对 VoiceDesign", "读取当前服务、档位和音色能力。", "arrow.clockwise")
        case .available:
            (.healthy, "VoiceDesign 已确认可用", "Quality、TTS 和服务端 capability 均已读取。", "checkmark.circle")
        case .requiresQuality:
            (.attention, "当前档位未提供 VoiceDesign", "请在模型页确认 Quality 制品并应用目标档位。", "slider.horizontal.3")
        case .serviceUnavailable:
            (.attention, "TTS 服务尚未就绪", "先恢复服务状态，再生成真实候选音频。", "exclamationmark.triangle")
        case .unsupported:
            (.critical, "服务端未公开 VoiceDesign", "当前音色列表没有可用的 VoiceDesign capability。", "xmark.circle")
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
                actionTitle: model.creatorVoicesLoadState == .failed ? "重新读取能力" : nil,
                action: model.creatorVoicesLoadState == .failed
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
        guard !model.isRefreshingService, !model.isRefreshingCreatorVoices else {
            return .checking
        }
        guard let health = displayedHealth else {
            return model.healthFailure == nil ? .checking : .serviceUnavailable
        }
        guard model.creatorVoicesLoadState == .loaded else {
            return .checking
        }
        guard health.profile == .quality else {
            return .requiresQuality
        }
        guard health.status == "ok", health.ttsReady == true, health.ready == true else {
            return .serviceUnavailable
        }

        let supportsVoiceDesign = model.creatorVoices.contains { voice in
            voice.available
                && voice.variant == "voice_design"
                && voice.capabilities.supportsInstruction
        }
        return supportsVoiceDesign ? .available : .unsupported
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
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
                ConcentricRectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(candidate.slot)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                .frame(
                    width: SpeechRailDesignTokens.Layout.creatorSlotBadgeSize,
                    height: SpeechRailDesignTokens.Layout.creatorSlotBadgeSize
                )
                .background(
                    SpeechRailDesignTokens.Surface.voiceBadgeFill,
                    in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.control)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(candidate.title)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(candidate.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                .background(statusColor.opacity(0.14), in: .capsule)
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
                AcousticWaveformBar(active: isPlaying)
                    .frame(
                        width: SpeechRailDesignTokens.Layout.creatorWaveformWidth,
                        height: SpeechRailDesignTokens.Layout.creatorWaveformHeight
                    )
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
                Button(action: onSave) {
                    Label(
                        isSaving ? "保存中" : (isSaved ? "已保存" : "保存为音色"),
                        systemImage: isSaved ? "checkmark" : "square.and.arrow.down"
                    )
                    .font(SpeechRailDesignTokens.Typography.caption)
                }
                .speechRailButton(.secondary)
                .disabled(isSaved || isSaving || isRegistering)
                .accessibilityLabel("把候选 \(candidate.slot) 保存到音色库")
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
                    .keyboardShortcut(.cancelAction)
                Button("保存到音色库", action: onSave)
                    .buttonStyle(.borderedProminent)
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

private struct AcousticWaveformBar: View {
    let active: Bool

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Control.waveformBarSpacing) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Control.waveformBarRadius)
                    .fill(active ? SpeechRailDesignTokens.Color.voice : SpeechRailDesignTokens.Color.waveformInactive)
                    .frame(
                        width: SpeechRailDesignTokens.Control.waveformBarWidth,
                        height: barHeight(for: index)
                    )
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [6, 12, 18, 14, 20, 16, 10, 15, 8]
        let base = pattern[index % pattern.count]
        return active ? base : base * 0.5
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

    public init() {}

    public var body: some View {
        PageScaffold(route: .voiceLibrary, scrollable: false) {
            voiceLibraryBody
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索音色名称与描述")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "刷新音色列表，或打开音色创作") {
                    Button {
                        Task { await model.refreshCreatorVoices() }
                    } label: {
                        Label("刷新音色列表", systemImage: "arrow.clockwise")
                            .speechRailMenuRow()
                    }
                    .disabled(model.isRefreshingCreatorVoices)
                    Divider()
                    Button {
                        navigation.request(.voiceDesign)
                    } label: {
                        Label("新建音色", systemImage: "plus")
                            .speechRailMenuRow()
                    }
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏详情" : "显示详情",
                            systemImage: "sidebar.right"
                        )
                        .speechRailMenuRow()
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
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
                .buttonStyle(.borderedProminent)
                Button("重新加载") {
                    Task { await model.refreshCreatorVoices() }
                }
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
                List(selection: $selectedVoiceID) {
                    ForEach(filteredVoices) { voice in
                        voiceLibraryRow(voice)
                            .tag(voice.id)
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("音色列表")
                .onKeyPress(.space) {
                    guard let voice = selectedVoice else { return .ignored }
                    togglePreview(voice)
                    return .handled
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var countText: String {
        let total = filteredVoices.count
        return total == model.creatorVoices.count
            ? "\(total) 个音色"
            : "\(total) / \(model.creatorVoices.count) 个音色"
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
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    sourceBadge(voice)
                }
                Text(voiceListDescription(for: voice))
                    .font(SpeechRailDesignTokens.Typography.caption)
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
                } else {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.statusIcon)
                        .foregroundStyle(SpeechRailDesignTokens.Color.voice)
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
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Inspector.sectionSpacing) {
                    SectionHeading(
                        title: voice.name,
                        detail: voice.isSystem ? "系统音色" : "自定义音色"
                    )

                    voicePreviewSection(voice)

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
                        LabeledContent("可用性", value: voice.available ? "可用" : "当前档位不可用")
                        LabeledContent("采样种子", value: voice.seed.map(String.init) ?? "未提供")
                        LabeledContent("创建时间", value: createdAtText(for: voice))
                        LabeledContent("变体", value: voice.variant ?? "未提供")
                        LabeledContent("模式", value: voice.mode ?? "未提供")
                        LabeledContent(
                            "音频时长",
                            value: voice.durationSeconds.map { String(format: "%.1f s", $0) } ?? "未提供"
                        )
                        LabeledContent("使用次数", value: "\(worksUsing(voice).count) 个作品")
                        LabeledContent("关联作品", value: relatedWorksText(for: voice))
                    }
                    .speechRailInspectorContent()

                    voiceDescriptionSection(voice)
                    voiceInspectorActions(voice)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpeechRailDesignTokens.Inspector.contentPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ContentUnavailableView(
                "请选择一个音色",
                systemImage: AppRoute.voiceLibrary.systemImage,
                description: Text("选择列表中的音色后，这里会显示试听、参数和可用性。")
            )
        }
    }

    /// The inspector opens with the one thing the page is for: hearing the
    /// voice (REDESIGN-SPEC §7.3).
    private func voicePreviewSection(_ voice: CreatorVoice) -> some View {
        let isPlaying = model.playingVoiceID == voice.id && model.isAudioPlaying
        let isPreviewing = model.previewingVoiceID == voice.id
        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button {
                    togglePreview(voice)
                } label: {
                    if isPreviewing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(SpeechRailDesignTokens.Typography.statusIcon)
                            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    }
                }
                .speechRailButton(.quiet)
                .disabled(previewDisabled(for: voice))
                .accessibilityLabel(
                    isPreviewing ? "取消试听" : "\(voice.name)\(isPlaying ? "停止试听" : "试听")"
                )

                AcousticWaveformBar(active: isPlaying)
                    .frame(
                        width: SpeechRailDesignTokens.Layout.creatorWaveformWidth,
                        height: SpeechRailDesignTokens.Layout.creatorWaveformHeight
                    )
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text("试听文案 · \(sampleText.count)/\(SpeechRailCreatorLimits.speechTextMaximumLength)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(
                        sampleText.count > SpeechRailCreatorLimits.speechTextMaximumLength
                            ? SpeechRailDesignTokens.Color.critical
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                TextField("输入试听文案", text: $sampleText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                    .speechRailRecessedSlot()
                    .accessibilityLabel("音色试听文案")
            }
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
                    .font(SpeechRailDesignTokens.Typography.caption)
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
            Divider()

            Button("去配音台") {
                navigation.request(.dubbing)
            }
            .buttonStyle(.borderedProminent)

            if !voice.isSystem {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("重命名") {
                        editorFocus = .name
                        editingVoice = voice
                    }
                    .disabled(model.isUpdatingVoice)

                    Button("编辑描述") {
                        editorFocus = .instruction
                        editingVoice = voice
                    }
                    .disabled(model.isUpdatingVoice || voice.mode == "clone")

                    Spacer(minLength: 0)

                    Button("删除", role: .destructive) {
                        deletionMessage = nil
                        pendingDeleteVoice = voice
                        isConfirmingDeletion = true
                    }
                    .disabled(model.isDeletingVoice)
                }
            }

            if showDeveloperDetails {
                DisclosureGroup("技术上下文") {
                    VStack(alignment: .leading, spacing: 0) {
                        LabeledContent(
                            "支持 instruction",
                            value: voice.capabilities.supportsInstruction ? "是" : "否"
                        )
                        LabeledContent(
                            "支持 clone",
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
                .font(SpeechRailDesignTokens.Typography.label)
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
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                TextField("音色名称", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                    .speechRailField()
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
                        .speechRailField()
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
                        .speechRailField()
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

    public init() {}

    public var body: some View {
        PageScaffold(route: .works, scrollable: false) {
            worksBody
        }
        .focusedSceneValue(
            \.selectedWorkCommand,
            selectedWork.map { work in
                SelectedWorkCommand(title: work.title) {
                    prepareExport(for: work)
                }
            }
        )
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索作品标题")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "导出、定位或删除选中的作品") {
                    Button {
                        if let work = selectedWork {
                            prepareExport(for: work)
                        }
                    } label: {
                        Label("导出选中作品", systemImage: "square.and.arrow.down")
                            .speechRailMenuRow()
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(selectedWork == nil)
                    Button {
                        if let work = selectedWork {
                            revealInFinder(work)
                        }
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                            .speechRailMenuRow()
                    }
                    .disabled(selectedWork == nil)
                    Divider()
                    Button {
                        if let work = selectedWork {
                            beginRename(work)
                        }
                    } label: {
                        Label("重命名…", systemImage: "pencil")
                            .speechRailMenuRow()
                    }
                    .disabled(selectedWork == nil)
                    Button(role: .destructive) {
                        if let work = selectedWork {
                            requestDelete(work)
                        }
                    } label: {
                        Label("删除…", systemImage: "trash")
                            .speechRailMenuRow()
                    }
                    .disabled(selectedWork == nil)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏详情" : "显示详情",
                            systemImage: "sidebar.right"
                        )
                        .speechRailMenuRow()
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $showInspector) {
            worksInspector
        }
        .confirmationDialog(
            "删除作品？",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            if let work = pendingDeleteWork {
                Button("删除“\(work.title)”", role: .destructive) {
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
                .buttonStyle(.borderedProminent)
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
                .keyboardShortcut(.cancelAction)
                Button("重命名") {
                    commitRename()
                }
                .buttonStyle(.borderedProminent)
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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Inspector.sectionSpacing) {
                    SectionHeading(title: work.title, detail: "本机作品")

                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Button {
                            model.playWork(work)
                        } label: {
                            Label(
                                isPlaying(work) ? "停止" : "试听",
                                systemImage: isPlaying(work) ? "stop.fill" : "play.fill"
                            )
                        }
                        .speechRailButton(.secondary)

                        Button("导出…") {
                            prepareExport(for: work)
                        }
                        .speechRailButton(.secondary)
                    }

                    Button("在 Finder 中显示") {
                        revealInFinder(work)
                    }
                    .speechRailButton(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Text(work.scriptText)
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    Divider()

                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Button("重命名") {
                            beginRename(work)
                        }
                        Button("删除", role: .destructive) {
                            requestDelete(work)
                        }
                        Spacer(minLength: 0)
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
                        .font(SpeechRailDesignTokens.Typography.label)
                    }

                    Text("作品正文和音频保存在本机 Application Support，不会写入 SpeechRail 仓库。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SpeechRailDesignTokens.Inspector.contentPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ContentUnavailableView(
                "请选择一个作品",
                systemImage: AppRoute.works.systemImage,
                description: Text("选择列表中的作品后，这里会显示文稿、音频和参数。")
            )
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
                List(selection: $selectedWorkID) {
                    ForEach(filteredWorks) { work in
                        workListRow(work)
                            .tag(work.id)
                            .contextMenu {
                                workContextMenu(work)
                            }
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("作品列表")
                .onKeyPress(.space) {
                    guard let work = selectedWork else { return .ignored }
                    model.playWork(work)
                    return .handled
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workListRow(_ work: CreativeWork) -> some View {
        let isPlaying = model.playingWorkID == work.id && model.isAudioPlaying

        return HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(work.title)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("音色：\(work.voiceName)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(work.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)

            Text(durationText(for: work))
                .font(SpeechRailDesignTokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: 56, alignment: .trailing)

            Button {
                model.playWork(work)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(SpeechRailDesignTokens.Typography.statusIcon)
                    .foregroundStyle(
                        isPlaying
                            ? SpeechRailDesignTokens.Color.ready
                            : SpeechRailDesignTokens.Color.voice
                    )
            }
            .speechRailButton(.quiet)
            .accessibilityLabel("\(work.title)\(isPlaying ? "停止试听" : "试听")")
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .accessibilityElement(children: .contain)
        .accessibilityHint("选中后可导出、在 Finder 中显示、重命名或删除")
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
        let matched = query.isEmpty
            ? model.works
            : model.works.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return matched.sorted { left, right in
            sortOrder == .newestFirst
                ? left.createdAt > right.createdAt
                : left.createdAt < right.createdAt
        }
    }

    private var countText: String {
        filteredWorks.count == model.works.count
            ? "\(model.works.count) 个作品"
            : "\(filteredWorks.count) / \(model.works.count) 个作品"
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
        renameText = work.title
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
