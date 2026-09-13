import Foundation
import SpeechRailControlKit
import SwiftUI
import UniformTypeIdentifiers

public struct CreatorSurfaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    public let route: AppRoute

    public init(route: AppRoute) {
        self.route = route
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: route)
                creatorContent
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            if route != .works {
                ToolbarItem(placement: .primaryAction) {
                    WorkspaceActionsMenu(helpText: "刷新服务状态，或打开服务状态页") {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("刷新服务状态", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshingService)
                        Divider()
                        Button {
                            navigation.request(.overview)
                        } label: {
                            Label("查看服务状态", systemImage: AppRoute.overview.systemImage)
                        }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    @ViewBuilder
    private var creatorContent: some View {
        switch route {
        case .dubbing:
            DubbingDeskView()
        case .voiceDesign:
            VoiceDesignView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .works:
            WorksView()
        case .overview, .monitoring, .models, .diagnostics:
            EmptyView()
        }
    }
}

// MARK: - 配音台 (Dubbing Desk)

public struct DubbingDeskView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var dubbingText = "在星际航行的漫长岁月里，人类学会了倾听寂静。每当脉冲信号穿越猎户座悬臂，控制台都会闪烁起熟悉的琥珀色微光。"
    @State private var selectedVoiceID = ""
    @State private var speechSpeed: Double = 1.0
    @State private var successMessage: String?
    @State private var selectionNotice: String?
    @State private var synthesisTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "文稿编辑与配音",
                    detail: "输入需要合成的旁白、对话或有声书文本，选择目标音色并调整语速。"
                )
                TextEditor(text: $dubbingText)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                    .speechRailField()
                    .accessibilityLabel("配音文稿内容")

                HStack {
                    Text("字数统计：\(dubbingText.count) 字")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                    Button("清空文稿") {
                        dubbingText = ""
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .speechRailButton(.quiet)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                SectionHeading(
                    title: "声学参数配置",
                    detail: "从当前服务公开的可用音色中选择；生成后自动保存 WAV 作品并播放。"
                )
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.lg) {
                        voicePicker
                        speedControl
                        Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                        dubbingActionButton
                    }
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.lg) {
                            voicePicker
                            speedControl
                        }
                        HStack {
                            Spacer()
                            dubbingActionButton
                        }
                    }
                }
                Text("输出格式：WAV · 采样率遵循当前服务配置")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            dubbingContextStatus

            if let selectionNotice {
                Label(selectionNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }

            if let creatorMessage = model.creatorMessage, successMessage == nil {
                StatusBanner(
                    tone: .critical,
                    title: "配音未完成",
                    message: creatorMessage,
                    actionTitle: model.creatorVoicesLoadState == .failed ? "重新读取音色" : nil,
                    action: model.creatorVoicesLoadState == .failed
                        ? { Task { await model.refreshCreatorVoices() } }
                        : nil
                )
            }

            if let successMessage {
                StatusBanner(
                    tone: .healthy,
                    title: "作品已生成并保存",
                    message: successMessage,
                    actionTitle: "查看我的作品"
                ) {
                    navigation.request(.works)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .task {
            await model.refreshCreatorVoices()
            syncSelectedVoice()
        }
        .onChange(of: model.creatorVoices) { _, _ in
            syncSelectedVoice()
        }
        .onDisappear {
            synthesisTask?.cancel()
            synthesisTask = nil
            model.stopAudio()
        }
    }

    private var availableVoices: [CreatorVoice] {
        model.creatorVoices.filter { $0.available }
    }

    private var selectedVoice: CreatorVoice? {
        availableVoices.first { $0.id == selectedVoiceID }
    }

    @ViewBuilder
    private var voicePicker: some View {
        Picker("音色预设", selection: $selectedVoiceID) {
            if model.isRefreshingCreatorVoices && model.creatorVoices.isEmpty {
                Text("正在读取音色…").tag("")
            } else if availableVoices.isEmpty {
                Text("暂无可用音色").tag("")
            } else {
                ForEach(availableVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.creatorVoicePickerWidth)
        .speechRailPointerCursor()
        .accessibilityLabel("音色预设")
    }

    private var speedControl: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("语速")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Slider(value: $speechSpeed, in: 0.5...2.0, step: 0.1)
                .frame(minWidth: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                .accessibilityLabel("语速")
            Text(String(format: "%.1fx", speechSpeed))
                .font(SpeechRailDesignTokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    private var dubbingActionButton: some View {
        Button {
            if model.isCreatingSpeech {
                synthesisTask?.cancel()
                synthesisTask = nil
                selectionNotice = "已停止等待本次生成；如果服务端已经接收请求，后台可能仍会完成处理。"
            } else if model.isAudioPlaying {
                model.stopAudio()
            } else if let voice = selectedVoice {
                successMessage = nil
                synthesisTask = Task { @MainActor in
                    if let work = await model.synthesizeAndSave(
                        text: dubbingText,
                        voice: voice,
                        speed: speechSpeed
                    ) {
                        successMessage = model.workPlaybackMessage == nil && model.isAudioPlaying
                            ? "“\(work.title)” 已保存到“我的作品”，并已开始播放。"
                            : "“\(work.title)” 已保存到“我的作品”，但本次播放未完成，请在“我的作品”中重新试听。"
                    }
                }
            }
        } label: {
            if model.isCreatingSpeech {
                Label("取消生成", systemImage: "stop.circle")
            } else {
                Label(
                    model.isAudioPlaying ? "停止试听" : "生成并保存",
                    systemImage: model.isAudioPlaying ? "stop.fill" : "play.fill"
                )
            }
        }
        .speechRailButton(.primary)
        .tint(SpeechRailDesignTokens.Color.rail)
        .disabled(
            !model.isCreatingSpeech
                && (selectedVoice == nil
                    || dubbingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
        .accessibilityLabel(
            model.isCreatingSpeech
                ? "取消配音生成"
                : model.isAudioPlaying ? "停止试听" : "生成并保存配音"
        )
    }

    @ViewBuilder
    private var dubbingContextStatus: some View {
        if model.isRefreshingCreatorVoices && model.creatorVoices.isEmpty {
            SpeechRailStatusLine(
                tone: .neutral,
                title: "正在读取音色",
                message: "从当前 SpeechRail 服务获取可用于配音的音色。",
                systemImage: "arrow.clockwise"
            )
        } else if availableVoices.isEmpty {
            SpeechRailStatusLine(
                tone: .attention,
                title: "没有可用音色",
                message: "请检查服务状态或先在音色库中确认服务端返回。",
                systemImage: "exclamationmark.triangle"
            )
        } else if model.isCreatingSpeech {
            SpeechRailStatusLine(
                tone: .attention,
                title: "正在生成并保存",
                message: "服务端正在合成，文稿和音色选择会保留。",
                systemImage: "waveform"
            )
        } else if model.isAudioPlaying {
            SpeechRailStatusLine(
                tone: .healthy,
                title: "正在试听",
                message: "生成的音频正在播放；再次点击主按钮可停止。",
                systemImage: "speaker.wave.2"
            )
        }
    }

    private func syncSelectedVoice() {
        guard let firstVoice = availableVoices.first else {
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
    }
}

// MARK: - 音色创作 (Voice Design with Acoustic Rack)

public struct VoiceDesignView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var description = "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。"
    @State private var voiceName = "夜航主持"
    @State private var referenceText = "欢迎来到 SpeechRail，这是用于试听和保存音色的参考文案。"
    @FocusState private var isEditorFocused: Bool
    @State private var candidates: [VoiceCandidate] = []
    @State private var playingSlot: String? = nil
    @State private var savedSlots: Set<String> = []
    @State private var savingSlot: String?
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var isGenerating = false
    @State private var generationRequest: VoiceGenerationRequest?

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
    private let candidateSpecs = [
        CandidateSpec(slot: "A", seed: 101, title: "候选 A", detail: "同一试听文案 · seed 101"),
        CandidateSpec(slot: "B", seed: 202, title: "候选 B", detail: "同一试听文案 · seed 202"),
        CandidateSpec(slot: "C", seed: 303, title: "候选 C", detail: "同一试听文案 · seed 303"),
        CandidateSpec(slot: "D", seed: 404, title: "候选 D", detail: "同一试听文案 · seed 404")
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(
                        title: "从一句话开始",
                        detail: "描述声音特征，生成真实候选音频，再选择一个保存到音色库。"
                    )
                }

                TextEditor(text: $description)
                    .focused($isEditorFocused)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .frame(minHeight: SpeechRailDesignTokens.Layout.creatorComposerMinimumHeight)
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                    .speechRailField()
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.control)
                            .stroke(
                                isEditorFocused
                                    ? SpeechRailDesignTokens.Color.voice
                                    : Color.clear,
                                lineWidth: SpeechRailDesignTokens.Control.focusStrokeWidth
                            )
                    )
                    .accessibilityLabel("音色描述输入")

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("快速加入声学特征")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(acousticChips, id: \.self) { chip in
                                Button {
                                    appendChip(chip)
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "plus")
                                            .font(SpeechRailDesignTokens.Typography.technical)
                                        Text(chip)
                                    }
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                                    .background(
                                        SpeechRailDesignTokens.Surface.voiceSelectedFill,
                                        in: .capsule
                                    )
                                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                                }
                                .speechRailInteractiveButtonStyle()
                                .accessibilityLabel("插入声学特征：\(chip)")
                            }
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                        voiceNameField
                            .frame(width: SpeechRailDesignTokens.Layout.creatorVoiceNameWidth)
                        referenceTextField
                    }
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        voiceNameField
                        referenceTextField
                    }
                }

                Text("候选音频只用于本次试听；注册时服务会按描述、参考文案和 seed 创建可复用音色，不会把候选音频本身当作音色资产保存。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)

                voiceDesignAvailabilityLine

                HStack {
                    Spacer()
                    Button {
                        if isGenerating {
                            generationRequest = nil
                            model.stopAudio()
                            playingSlot = nil
                        } else {
                            startGeneration()
                        }
                    } label: {
                        if isGenerating {
                            Label("停止生成", systemImage: "stop.fill")
                        } else {
                            Label("生成候选音色", systemImage: AppRoute.voiceDesign.systemImage)
                        }
                    }
                    .speechRailButton(.primary)
                    .tint(SpeechRailDesignTokens.Color.voice)
                    .disabled(
                        (!isGenerating && !voiceDesignAvailable)
                            || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.isRegisteringVoice
                    )
                    .accessibilityLabel(isGenerating ? "停止生成候选音色" : "根据当前描述生成 4 组候选音色")
                }
            }

            voiceDesignFeedback

            Divider()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "候选试听",
                    detail: "只有收到真实预览音频的候选才可试听或保存；同一时刻只播放一个候选。"
                )

                if candidates.isEmpty {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Label("还没有候选音色", systemImage: AppRoute.voiceDesign.systemImage)
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("先填写描述，再生成一组可试听的真实音频。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .speechRailField()
                } else {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(candidates) { candidate in
                            CandidateRackRow(
                                candidate: candidate,
                                isPlaying: playingSlot == candidate.slot && model.isAudioPlaying,
                                isSaved: savedSlots.contains(candidate.slot),
                                isSaving: savingSlot == candidate.slot,
                                onPlayToggle: { play(candidate) },
                                onSave: { save(candidate) }
                            )
                        }
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .task(id: generationRequest?.id) {
            guard let generationRequest else { return }
            await generateCandidates(for: generationRequest)
        }
        .task {
            await model.refresh()
            await model.refreshCreatorVoices()
        }
        .onDisappear {
            generationRequest = nil
            model.stopAudio()
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
                .speechRailField()
                .accessibilityLabel("音色保存名称")
        }
    }

    private var referenceTextField: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text("试听与注册参考文案 · \(referenceText.count)/240")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            TextEditor(text: $referenceText)
                .font(SpeechRailDesignTokens.Typography.body)
                .frame(minHeight: SpeechRailDesignTokens.Layout.creatorReferenceMinimumHeight)
                .padding(SpeechRailDesignTokens.Spacing.xs)
                .speechRailField()
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

        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SpeechRailStatusLine(
                tone: status.tone,
                title: status.title,
                message: status.message,
                systemImage: status.image
            )
            if let banner = voiceDesignAvailabilityBanner {
                Button(banner.actionTitle) {
                    navigation.request(banner.route)
                }
                .speechRailButton(.secondary)
            }
        }
    }

    @ViewBuilder
    private var voiceDesignFeedback: some View {
        if let error = errorMessage {
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
        } else if let successMessage {
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
        guard let health = model.health else {
            return .checking
        }
        guard model.creatorVoicesLoadState == .loaded else {
            return .checking
        }
        guard health.profile == .quality else {
            return .requiresQuality
        }
        guard health.status == "ok", health.ttsReady == true, model.service.ready == true else {
            return .serviceUnavailable
        }

        let supportsVoiceDesign = model.creatorVoices.contains { voice in
            voice.available
                && voice.variant == "voice_design"
                && voice.capabilities.supportsInstruction
        }
        return supportsVoiceDesign ? .available : .unsupported
    }

    private var voiceDesignAvailabilityBanner: AvailabilityBanner? {
        switch voiceDesignAvailability {
        case .checking, .available:
            nil
        case .requiresQuality:
            AvailabilityBanner(
                title: "音色创作需要 Quality 档位",
                message: "当前档位不会加载 VoiceDesign 能力。切换档位不会自动发生，请在模型页确认后再操作。",
                actionTitle: "打开模型页",
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
                actionTitle: "打开模型页",
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
        guard (20...240).contains(previewText.count) else {
            errorMessage = "试听与注册参考文案需要 20–240 个字符"
            return
        }
        guard voiceDesignAvailable else {
            errorMessage = "当前尚未确认 VoiceDesign 能力，请先完成服务状态和音色能力检查。"
            return
        }
        errorMessage = nil
        successMessage = nil
        playingSlot = nil
        model.stopAudio()
        candidates = candidateSpecs.map {
            VoiceCandidate(
                slot: $0.slot,
                seed: $0.seed,
                title: $0.title,
                detail: $0.detail,
                status: .loading
            )
        }
        isGenerating = true
        generationRequest = VoiceGenerationRequest(
            instruction: instruction,
            previewText: previewText
        )
    }

    @MainActor
    private func generateCandidates(for request: VoiceGenerationRequest) async {
        defer { isGenerating = false }
        var failedSlots: [String] = []
        for spec in candidateSpecs {
            guard !Task.isCancelled else { return }
            updateCandidate(slot: spec.slot, status: .loading)
            guard let data = await model.previewDesignedVoice(
                text: request.previewText,
                instruction: request.instruction,
                speed: 1.0,
                seed: spec.seed
            ) else {
                guard !Task.isCancelled else { return }
                let message = model.creatorMessage ?? "预览未生成，请稍后重试"
                updateCandidate(slot: spec.slot, status: .failed(message))
                failedSlots.append(spec.slot)
                continue
            }
            updateCandidate(
                slot: spec.slot,
                status: .ready,
                audioData: data,
                durationSeconds: model.audioDuration(for: data)
            )
        }
        if !failedSlots.isEmpty {
            errorMessage = "候选 \(failedSlots.joined(separator: "、")) 未生成；已保留其他成功候选，可重新生成。"
        }
    }

    private func updateCandidate(
        slot: String,
        status: VoiceCandidateStatus,
        audioData: Data? = nil,
        durationSeconds: TimeInterval? = nil
    ) {
        guard let index = candidates.firstIndex(where: { $0.slot == slot }) else { return }
        candidates[index].status = status
        if let audioData {
            candidates[index].audioData = audioData
        }
        if let durationSeconds {
            candidates[index].durationSeconds = durationSeconds
        }
    }

    private func play(_ candidate: VoiceCandidate) {
        if playingSlot == candidate.slot, model.isAudioPlaying {
            model.stopAudio()
            playingSlot = nil
            return
        }
        guard let audioData = candidate.audioData else { return }
        do {
            try model.playAudio(data: audioData)
            playingSlot = candidate.slot
            errorMessage = nil
        } catch {
            errorMessage = "候选音频无法播放，请重新生成"
            playingSlot = nil
        }
    }

    private func save(_ candidate: VoiceCandidate) {
        guard candidate.audioData != nil else { return }
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "请先填写保存名称"
            return
        }
        savingSlot = candidate.slot
        errorMessage = nil
        successMessage = nil
        Task {
            let voice = await model.saveDesignedVoice(
                name: name,
                instruction: description.trimmingCharacters(in: .whitespacesAndNewlines),
                referenceText: referenceText.trimmingCharacters(in: .whitespacesAndNewlines),
                seed: candidate.seed
            )
            savingSlot = nil
            if let voice {
                savedSlots.insert(candidate.slot)
                successMessage = "“\(voice.name)” 已按候选 \(candidate.slot) 的 seed 注册，可在音色库中复用。"
            }
        }
    }
}

private struct VoiceGenerationRequest: Equatable {
    let id = UUID()
    let instruction: String
    let previewText: String
}

private struct CandidateSpec {
    let slot: String
    let seed: Int
    let title: String
    let detail: String
}

private enum VoiceCandidateStatus: Equatable {
    case loading
    case ready
    case failed(String)
}

private struct VoiceCandidate: Identifiable {
    var id: String { slot }
    let slot: String
    let seed: Int
    let title: String
    let detail: String
    var status: VoiceCandidateStatus
    var audioData: Data? = nil
    var durationSeconds: TimeInterval? = nil
}

private struct CandidateRackRow: View {
    let candidate: VoiceCandidate
    let isPlaying: Bool
    let isSaved: Bool
    let isSaving: Bool
    let onPlayToggle: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            // 槽位徽章
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

            // 信息
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(candidate.title)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(statusText)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(statusColor)
                }
                Text(detailText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

            // 静态/动态声波可视化
            AcousticWaveformBar(active: isPlaying)
                .frame(
                    width: SpeechRailDesignTokens.Layout.creatorWaveformWidth,
                    height: SpeechRailDesignTokens.Layout.creatorWaveformHeight
                )
                .accessibilityHidden(true)

            // 时长
            Text(durationText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            Button(action: onPlayToggle) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.statusIcon)
                        .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                }
            }
            .speechRailInteractiveButtonStyle()
            .disabled(!hasAudio || isLoading)
            .accessibilityLabel("\(candidate.slot) 槽位试听：\(isPlaying ? "暂停" : "播放")")

            Button(action: onSave) {
                Label(
                    isSaving ? "注册中" : (isSaved ? "已注册" : "注册此候选"),
                    systemImage: isSaved ? "checkmark" : "square.and.arrow.down"
                )
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .speechRailButton(.secondary)
            .disabled(isSaved || isSaving || !hasAudio)
            .accessibilityLabel("按 \(candidate.title) 注册至音色库")
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
        )
        .accessibilityElement(children: .contain)
    }

    private var isLoading: Bool {
        if case .loading = candidate.status { return true }
        return false
    }

    private var hasAudio: Bool {
        if case .ready = candidate.status { return candidate.audioData != nil }
        return false
    }

    private var detailText: String {
        if case let .failed(message) = candidate.status {
            return message
        }
        return candidate.detail
    }

    private var statusText: String {
        switch candidate.status {
        case .loading:
            "生成中"
        case .ready:
            isSaved ? "已注册" : "可试听"
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
        case .failed:
            SpeechRailDesignTokens.Color.critical
        }
    }

    private var durationText: String {
        guard let seconds = candidate.durationSeconds else { return "—" }
        return String(format: "%.1fs", seconds)
    }
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
    @State private var showInspector = false
    @State private var selectionNotice: String?
    @State private var pendingDeleteVoice: CreatorVoice?
    @State private var isConfirmingDeletion = false
    @State private var deletionMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(
                    title: "系统音色与创作资产",
                    detail: "列表来自当前 SpeechRail 服务；系统音色与自定义音色分别管理。"
                )
                Spacer()
                Button {
                    showInspector.toggle()
                } label: {
                    Label(
                        showInspector ? "隐藏详情" : "显示详情",
                        systemImage: "info.circle"
                    )
                }
                .speechRailButton(.secondary)
                .disabled(selectedVoice == nil)
                Button {
                    Task { await model.refreshCreatorVoices() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .speechRailButton(.secondary)
                .disabled(model.isRefreshingCreatorVoices)
            }

            if let selectionNotice {
                Label(selectionNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("试听文案")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                TextField("输入试听文案", text: $sampleText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                    .frame(minHeight: SpeechRailDesignTokens.Control.regularHeight)
                    .speechRailField()
                    .accessibilityLabel("音色试听文案")
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

            if model.isRefreshingCreatorVoices && model.creatorVoices.isEmpty {
                ProgressView("正在读取服务端音色…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SpeechRailDesignTokens.Spacing.lg)
                    .speechRailField()
            } else if model.creatorVoices.isEmpty {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Label("当前没有可用音色", systemImage: AppRoute.voiceLibrary.systemImage)
                        .font(SpeechRailDesignTokens.Typography.body)
                    Text("请确认服务已就绪，或先到音色创作生成自定义音色。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    HStack {
                        Button("重新加载") {
                            Task { await model.refreshCreatorVoices() }
                        }
                        .speechRailButton(.secondary)
                        Button("去音色创作") {
                            navigation.request(.voiceDesign)
                        }
                        .speechRailButton(.primary)
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.lg)
                .speechRailField()
            } else {
                voiceListSurface
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
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
            Text("仅删除当前服务中的自定义音色；系统音色不会受影响。正在使用中的音色可能无法删除。")
        }
        .inspector(isPresented: $showInspector) {
            voiceInspector
        }
        .task {
            showInspector = showDeveloperDetails
            await model.refreshCreatorVoices()
            syncSelectedVoice()
        }
        .onChange(of: model.creatorVoices) { _, _ in
            syncSelectedVoice()
        }
        .onChange(of: showInspector) { _, value in
            showDeveloperDetails = value
        }
        .onDisappear {
            model.stopAudio()
        }
    }

    private var voiceListSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !systemVoices.isEmpty {
                voiceGroup(
                    title: "系统音色",
                    detail: "随当前服务档位提供，不会写入本机作品库。",
                    voices: systemVoices
                )
            }
            if !customVoices.isEmpty {
                if !systemVoices.isEmpty {
                    Divider()
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
                }
                voiceGroup(
                    title: "自定义音色",
                    detail: "由 VoiceDesign 注册，可在配音台复用。",
                    voices: customVoices
                )
            }
        }
        .speechRailContentSurface()
    }

    private func voiceGroup(title: String, detail: String, voices: [CreatorVoice]) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(title: title, detail: detail)
            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(voices) { voice in
                    voiceLibraryItem(voice)
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
    }

    private func voiceLibraryItem(_ voice: CreatorVoice) -> some View {
        let isSelected = selectedVoiceID == voice.id
        let isPlaying = model.playingVoiceID == voice.id && model.isAudioPlaying
        let type = voice.isSystem ? "系统音色" : "自定义音色"
        let description = voice.description.isEmpty ? "服务端已注册，当前档位\(voice.available ? "可用" : "不可用")。" : voice.description
        let metadata = voiceMetadata(for: voice, type: type)
        return HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Button {
                withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
                    selectedVoiceID = voice.id
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    Image(systemName: AppRoute.voiceLibrary.systemImage)
                        .font(SpeechRailDesignTokens.Typography.statusGlyph)
                        .foregroundStyle(voice.isSystem ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.voice)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(voice.name)
                                .font(SpeechRailDesignTokens.Typography.body)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text(type)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        Text(metadata)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Text(description)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Label(
                            voice.available ? "当前可用" : "当前档位不可用",
                            systemImage: voice.available
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(
                            voice.available
                                ? SpeechRailDesignTokens.Color.ready
                                : SpeechRailDesignTokens.Color.attention
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .speechRailInteractiveButtonStyle()
            .accessibilityLabel("选择音色：\(voice.name)")
            .accessibilityValue(
                "\(type)，\(voice.available ? "当前可用" : "当前不可用")，\(isSelected ? "已选中" : "未选中")"
            )

            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

            Button {
                if isPlaying {
                    model.stopAudio()
                } else {
                    Task { await model.previewVoice(voice, text: sampleText) }
                }
            } label: {
                Label(
                    isPlaying ? "停止试听" : "试听",
                    systemImage: isPlaying ? "stop.fill" : "play.fill"
                )
            }
            .speechRailButton(.secondary)
            .disabled(!voice.available || model.isCreatingSpeech)
            .accessibilityLabel("\(voice.name)\(isPlaying ? "停止试听" : "试听")")

            if !voice.isSystem {
                Button(role: .destructive) {
                    deletionMessage = nil
                    pendingDeleteVoice = voice
                    isConfirmingDeletion = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .speechRailButton(.quiet)
                .tint(SpeechRailDesignTokens.Color.critical)
                .disabled(model.isDeletingVoice)
                .accessibilityLabel("删除自定义音色：\(voice.name)")
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            isSelected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
        )
    }

    @ViewBuilder
    private var voiceInspector: some View {
        DeveloperInspector {
            if let voice = selectedVoice {
                SectionHeading(
                    title: voice.name,
                    detail: "普通用户查看用途与试听，开发者查看服务端实际返回的安全 metadata。"
                )
                LabeledContent("类型", value: voice.isSystem ? "系统音色" : "自定义音色")
                LabeledContent("当前可用", value: voice.available ? "是" : "否")
                LabeledContent("试听", value: sampleText.isEmpty ? "未填写试听文案" : "可用")
                if !voice.description.isEmpty {
                    Text(voice.description)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .textSelection(.enabled)
                }
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("去配音台") {
                        navigation.request(.dubbing)
                    }
                    .speechRailButton(.primary)
                    Button("试听") {
                        Task { await model.previewVoice(voice, text: sampleText) }
                    }
                    .speechRailButton(.secondary)
                    .disabled(!voice.available || model.isCreatingSpeech || sampleText.isEmpty)
                }
                Divider()
                Text("开发者详情")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                LabeledContent("variant", value: voice.variant ?? "未提供")
                LabeledContent("mode", value: voice.mode ?? "未提供")
                LabeledContent("创建时间", value: createdAtText(for: voice))
                LabeledContent("音频时长", value: voice.durationSeconds.map { String(format: "%.1f s", $0) } ?? "未提供")
                LabeledContent("支持 instruction", value: voice.capabilities.supportsInstruction ? "是" : "否")
                LabeledContent("支持 clone", value: voice.capabilities.supportsClone ? "是" : "否")
            } else {
                ContentUnavailableView(
                    "请选择一个音色",
                    systemImage: AppRoute.voiceLibrary.systemImage,
                    description: Text("选择列表中的音色后，这里会显示用途和安全技术摘要。")
                )
            }
        }
    }

    private func voiceMetadata(for voice: CreatorVoice, type: String) -> String {
        var values = [type]
        if let variant = voice.variant, !variant.isEmpty {
            values.append(variant.replacingOccurrences(of: "_", with: " "))
        }
        if voice.createdAt > 0 {
            values.append(
                Date(timeIntervalSince1970: voice.createdAt)
                    .formatted(date: .abbreviated, time: .omitted)
            )
        }
        return values.joined(separator: " · ")
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

    private var systemVoices: [CreatorVoice] {
        model.creatorVoices.filter { $0.isSystem }
    }

    private var customVoices: [CreatorVoice] {
        model.creatorVoices.filter { !$0.isSystem }
    }
}

// MARK: - 我的作品 (Works with Privacy Boundary & Inspector)

public struct WorksView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var selectedWorkID: String?
    @State private var expandedWorkID: String?
    @State private var showInspector = false
    @State private var exportDocument = WAVFileDocument(data: Data())
    @State private var exportFileName = "SpeechRail-作品"
    @State private var isExporting = false
    @State private var exportMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            SectionHeading(
                title: "创作历史与文稿回溯",
                detail: "作品音频和文稿只保存在本机；开发者信息只展示必要的技术摘要。"
            )

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

            if model.works.isEmpty, model.worksMessage == nil {
                VStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                    Image(systemName: AppRoute.works.systemImage)
                        .font(SpeechRailDesignTokens.Typography.emptyStateGlyph)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text("还没有作品")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("在配音台生成一段音频后，作品会保存在这里。")
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Button("去配音台") {
                        navigation.request(.dubbing)
                    }
                    .speechRailButton(.primary)
                }
                .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
            } else if !model.works.isEmpty {
                worksListSurface
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                        WorkspaceActionsMenu(helpText: "查看当前作品的技术摘要") {
                    Button {
                        if let work = selectedWork {
                            prepareExport(for: work)
                        }
                    } label: {
                        Label("导出选中作品", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selectedWork == nil)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏作品信息" : "显示作品信息",
                            systemImage: "info.circle"
                        )
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                if let work = model.works.first(where: { $0.id == selectedWorkID }) ?? model.works.first {
                    SectionHeading(
                        title: "作品技术摘要",
                        detail: "不展示绝对路径、请求凭据或音频二进制。"
                    )
                    LabeledContent("音色", value: work.voiceName)
                    LabeledContent("音色 ID", value: work.voiceID)
                    LabeledContent(
                        "生成时间",
                        value: work.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent("音频时长", value: durationText(for: work))
                    LabeledContent("格式", value: "WAV")
                    LabeledContent("文稿字数", value: "\(work.scriptText.count) 字")
                    LabeledContent("音频文件", value: work.audioFileName)
                    LabeledContent("采样率", value: "未提供（遵循服务配置）")
                    LabeledContent("请求延迟", value: "未提供（当前协议未返回）")
                    Divider()
                    Text("作品正文和音频保存在本机 Application Support，不会写入 SpeechRail 仓库。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
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
        .onDisappear {
            model.stopAudio()
        }
    }

    private var worksListSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.works.enumerated()), id: \.element.id) { index, work in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
                }
                workListRow(work)
            }
        }
        .speechRailContentSurface()
    }

    private func workListRow(_ work: CreativeWork) -> some View {
        let isSelected = selectedWorkID == work.id
        let isPlaying = model.playingWorkID == work.id && model.isAudioPlaying

        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Button {
                withAnimation(SpeechRailDesignTokens.Motion.selectionFeedback) {
                    selectedWorkID = work.id
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "waveform")
                        .font(SpeechRailDesignTokens.Typography.statusIcon)
                        .foregroundStyle(
                            isSelected
                                ? SpeechRailDesignTokens.Color.rail
                                : SpeechRailDesignTokens.Color.inkSecondary
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(work.title)
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .lineLimit(1)
                        Text("音色：\(work.voiceName)")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                    VStack(alignment: .trailing, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(durationText(for: work))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Text(work.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.creatorListRowMinimumHeight,
                    alignment: .leading
                )
            }
            .speechRailInteractiveButtonStyle()
            .accessibilityLabel("选择作品：\(work.title)")
            .accessibilityValue(isSelected ? "已选择" : "未选择")

            if isSelected {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedWorkID == work.id },
                        set: { expandedWorkID = $0 ? work.id : nil }
                    )
                ) {
                    Text(work.scriptText)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .textSelection(.enabled)
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .speechRailField()
                        .accessibilityLabel("作品文稿：\(work.title)")
                } label: {
                    Label(
                        expandedWorkID == work.id ? "收起文稿" : "展开文稿",
                        systemImage: "doc.text"
                    )
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
                .accessibilityLabel("作品文稿，\(work.scriptText.count) 字")
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                Label(
                    isPlaying ? "正在播放" : "可试听",
                    systemImage: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2"
                )
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(
                    isPlaying
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.inkSecondary
                )
                Button {
                    model.playWork(work)
                } label: {
                    Label(
                        isPlaying ? "停止试听" : "试听作品",
                        systemImage: isPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .speechRailButton(.secondary)
                .accessibilityLabel("\(work.title)\(isPlaying ? "停止试听" : "试听作品")")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
        .background(
            isSelected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
        )
    }

    private func durationText(for work: CreativeWork) -> String {
        guard let duration = work.durationSeconds else { return "未读取" }
        let totalSeconds = max(0, Int(duration.rounded()))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private var selectedWork: CreativeWork? {
        guard let selectedWorkID else { return nil }
        return model.works.first(where: { $0.id == selectedWorkID })
    }

    private func prepareExport(for work: CreativeWork) {
        do {
            exportDocument = WAVFileDocument(data: try model.loadWorkAudio(work))
            exportFileName = exportBaseName(for: work)
            exportMessage = nil
            isExporting = true
        } catch {
            exportMessage = "导出失败：作品音频暂时不可用，请重新生成或重试。"
        }
    }

    private func exportBaseName(for work: CreativeWork) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = work.title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "SpeechRail-作品" : String(cleaned.prefix(80))
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
