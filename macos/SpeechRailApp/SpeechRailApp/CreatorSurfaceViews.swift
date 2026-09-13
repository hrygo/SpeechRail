import SpeechRailControlKit
import SwiftUI

public struct CreatorSurfaceView: View {
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
            ToolbarItem {
                ServiceStatusBadge()
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
    @State private var dubbingText = "在星际航行的漫长岁月里，人类学会了倾听寂静。每当脉冲信号穿越猎户座悬臂，控制台都会闪烁起熟悉的琥珀色微光。"
    @State private var selectedVoice = "晨光 (温暖青年)"
    @State private var speechSpeed: Double = 1.0
    @State private var isPlaying = false

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
                    .buttonStyle(.plain)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                SectionHeading(
                    title: "声学参数配置",
                    detail: "基于当前运行档位选择已加载的音色资产。"
                )
                HStack(spacing: SpeechRailDesignTokens.Spacing.lg) {
                    Picker("音色预设", selection: $selectedVoice) {
                        Text("晨光 (温暖青年)").tag("晨光 (温暖青年)")
                        Text("松风 (沉稳叙事)").tag("松风 (沉稳叙事)")
                        Text("清泉 (灵动少女)").tag("清泉 (灵动少女)")
                        Text("星原 (科技播报)").tag("星原 (科技播报)")
                    }
                    .frame(width: SpeechRailDesignTokens.Layout.creatorVoicePickerWidth + 60)

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Text("语速")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        Slider(value: $speechSpeed, in: 0.5...2.0, step: 0.1)
                            .frame(width: 120)
                        Text(String(format: "%.1fx", speechSpeed))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    }

                    Spacer()

                    Button {
                        isPlaying.toggle()
                    } label: {
                        Label(isPlaying ? "停止试听" : "生成并试听", systemImage: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpeechRailDesignTokens.Color.rail)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }
}

// MARK: - 音色创作 (Voice Design with Acoustic Rack)

public struct VoiceDesignView: View {
    @State private var description = "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。"
    @FocusState private var isEditorFocused: Bool
    @State private var candidates: [VoiceCandidate] = [
        VoiceCandidate(slot: "A", title: "晨曦质感", detail: "磁性胸腔 · 咬字温润 · 语速舒缓", duration: "0:05"),
        VoiceCandidate(slot: "B", title: "醇厚叙事", detail: "低频沉稳 · 空间感丰富 · 亲和力强", duration: "0:06"),
        VoiceCandidate(slot: "C", title: "明亮轻快", detail: "高频通透 · 活力灵动 · 科技感", duration: "0:05"),
        VoiceCandidate(slot: "D", title: "知性理性", detail: "冷静专业 · 节律分明 · 纪录片腔", duration: "0:07")
    ]
    @State private var playingSlot: String? = nil
    @State private var savedSlots: Set<String> = []
    @State private var errorMessage: String? = nil

    private let acousticChips = [
        "磁性胸腔", "治愈温暖", "播音质感", "微醺叙事", "少年清冽", "知性温婉", "沙哑沉郁"
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            // Prompt 描述与声学胶囊区
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(
                        title: "从一句话开始",
                        detail: "先描述你想要的声音，再试听候选并保存。"
                    )
                    Spacer()
                    Text("Quality 创作档位")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                }

                // 编辑器带陶土色聚焦高亮
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
                                lineWidth: 1.5
                            )
                    )
                    .accessibilityLabel("音色描述输入")

                // 声学特征胶囊 (Acoustic Chips)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("声学特征胶囊 (点击插入)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(acousticChips, id: \.self) { chip in
                            Button {
                                appendChip(chip)
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "plus")
                                        .font(.caption2)
                                    Text(chip)
                                }
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                .padding(.vertical, 4)
                                .background(
                                    SpeechRailDesignTokens.Color.voice.opacity(0.12),
                                    in: .capsule
                                )
                                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("插入声学特征：\(chip)")
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("生成候选音色") {
                        generateCandidates()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SpeechRailDesignTokens.Color.voice)
                    .accessibilityLabel("根据当前描述生成 4 组候选音色")
                }
            }

            if let error = errorMessage {
                StatusBanner(
                    tone: .critical,
                    title: "音色生成未就绪",
                    message: error,
                    actionTitle: "重新尝试"
                ) {
                    errorMessage = nil
                    generateCandidates()
                }
            }

            Divider()

            // A/B/C/D 试听机架
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "候选试听机架 (A/B/C/D 候选池)",
                    detail: "并列试听不同声学特征演化候选，满意后直接保存至音色库。"
                )

                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(candidates) { candidate in
                        CandidateRackRow(
                            candidate: candidate,
                            isPlaying: playingSlot == candidate.slot,
                            isSaved: savedSlots.contains(candidate.slot),
                            onPlayToggle: {
                                if playingSlot == candidate.slot {
                                    playingSlot = nil
                                } else {
                                    playingSlot = candidate.slot
                                }
                            },
                            onSave: {
                                savedSlots.insert(candidate.slot)
                            }
                        )
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
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

    private func generateCandidates() {
        // 模拟生成与刷新试听机架
        playingSlot = nil
        candidates = [
            VoiceCandidate(slot: "A", title: "自然偏暖", detail: "胸腔共鸣 · 治愈温和 · 舒缓叙事", duration: "0:05"),
            VoiceCandidate(slot: "B", title: "清澈知性", detail: "发音清晰 · 专业节律 · 现代通透", duration: "0:05"),
            VoiceCandidate(slot: "C", title: "低沉醇厚", detail: "近讲效应 · 醇厚磁性 · 播客感", duration: "0:06"),
            VoiceCandidate(slot: "D", title: "生动跃动", detail: "高频灵动 · 呼吸自然 · 对话感", duration: "0:05")
        ]
    }
}

private struct VoiceCandidate: Identifiable {
    var id: String { slot }
    let slot: String
    let title: String
    let detail: String
    let duration: String
}

private struct CandidateRackRow: View {
    let candidate: VoiceCandidate
    let isPlaying: Bool
    let isSaved: Bool
    let onPlayToggle: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            // 槽位徽章
            Text(candidate.slot)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                .frame(width: 32, height: 32)
                .background(
                    SpeechRailDesignTokens.Color.voice.opacity(0.15),
                    in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.control)
                )

            // 信息
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(candidate.title)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(candidate.detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)

            // 静态/动态声波可视化
            AcousticWaveformBar(active: isPlaying)
                .frame(width: 72, height: 20)
                .accessibilityHidden(true)

            // 时长
            Text(candidate.duration)
                .font(SpeechRailDesignTokens.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

            // 试听按钮
            Button(action: onPlayToggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(candidate.slot) 槽位试听：\(isPlaying ? "暂停" : "播放")")

            // 保存按钮
            Button(action: onSave) {
                Label(isSaved ? "已保存" : "保存", systemImage: isSaved ? "checkmark" : "square.and.arrow.down")
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .buttonStyle(.bordered)
            .disabled(isSaved)
            .accessibilityLabel("保存 \(candidate.title) 至音色库")
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct AcousticWaveformBar: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? SpeechRailDesignTokens.Color.voice : SpeechRailDesignTokens.Color.inkSecondary.opacity(0.35))
                    .frame(width: 3, height: barHeight(for: index))
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
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            SectionHeading(
                title: "系统音色与创作资产",
                detail: "已加载的预置基础音色与通过 VoiceDesign 保存的自定义音色。"
            )

            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                voiceLibraryItem(
                    name: "晨光",
                    type: "预置音色 · 青年",
                    desc: "明亮自然，亲和力强，适合导览与学习类播客",
                    isPreset: true
                )
                Divider()
                voiceLibraryItem(
                    name: "松风",
                    type: "预置音色 · 中年",
                    desc: "低频沉稳，磁性胸腔，适合有声书与纪录片旁白",
                    isPreset: true
                )
                Divider()
                voiceLibraryItem(
                    name: "星原·智述",
                    type: "自定义创作 · 科技",
                    desc: "由 VoiceDesign 训练生成，冷静专业，节奏清晰",
                    isPreset: false
                )
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    private func voiceLibraryItem(name: String, type: String, desc: String, isPreset: Bool) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: isPreset ? "waveform.circle.fill" : "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(isPreset ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.voice)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(name)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(type)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Text(desc)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            Spacer()

            Button("试听") {}
                .buttonStyle(.bordered)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
    }
}

// MARK: - 我的作品 (Works with Privacy Boundary & Inspector)

public struct WorksView: View {
    @State private var selectedWorkID: String? = "work_01"
    @State private var showInspector = false

    private let mockWorks = [
        WorkItem(
            id: "work_01",
            title: "《流浪地球》旁白选段",
            promptText: "起初，没有人在意这一场灾难。这不过是一场山火，一次旱灾，一个物种的灭绝，一座城市的消失。直到这场灾难和每个人息息相关。",
            voiceName: "松风 (沉稳叙事)",
            createdAt: "今天 14:32",
            duration: "0:18",
            requestID: "req_7f2b918a",
            latencyMs: 168,
            tokens: 72,
            workerPID: 10482,
            speakerTag: "speaker_0"
        ),
        WorkItem(
            id: "work_02",
            title: "科技早报导语",
            promptText: "早上好，这里是科技早班车。今天我们要关注 Apple Silicon 神经网络引擎在边缘端音频推理上的最新架构升级。",
            voiceName: "晨光 (温暖青年)",
            createdAt: "昨天 09:15",
            duration: "0:12",
            requestID: "req_3a1c582e",
            latencyMs: 145,
            tokens: 58,
            workerPID: 10482,
            speakerTag: "speaker_0"
        )
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            SectionHeading(
                title: "创作历史与文稿回溯",
                detail: "主视图展示完整的创作者输入文本；开发者 Inspector 严格遵循脱敏审计协议。"
            )

            VStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                ForEach(mockWorks) { work in
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        HStack {
                            Text(work.title)
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Spacer()
                            Text("\(work.voiceName) · \(work.duration)")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }

                        // 业务资产侧：完整展示创作者输入文本 (AC-06 规范保障)
                        Text(work.promptText)
                            .font(SpeechRailDesignTokens.Typography.body)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            .textSelection(.enabled)
                            .padding(SpeechRailDesignTokens.Spacing.sm)
                            .background(
                                SpeechRailDesignTokens.Color.field,
                                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
                            )

                        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                            Text(work.createdAt)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Button("作品审计") {
                                selectedWorkID = work.id
                                showInspector.toggle()
                            }
                            .buttonStyle(.bordered)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            Spacer()
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                    .background(
                        selectedWorkID == work.id
                            ? SpeechRailDesignTokens.Color.rail.opacity(0.06)
                            : Color.clear,
                        in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
                    )
                    .onTapGesture {
                        selectedWorkID = work.id
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("脱敏技术详情", systemImage: "info.circle")
                }
                .help("查看脱敏的运行元数据 (AC-06)")
            }
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                if let work = mockWorks.first(where: { $0.id == selectedWorkID }) ?? mockWorks.first {
                    SectionHeading(
                        title: "开发者审计 (隐私脱敏)",
                        detail: "严格隐藏用户输入与音频二进制，仅展示脱敏技术指标 (AC-06)。"
                    )
                    LabeledContent("请求 ID", value: work.requestID)
                    LabeledContent("推理时延", value: "\(work.latencyMs) ms")
                    LabeledContent("词元消耗", value: "\(work.tokens) tokens")
                    LabeledContent("Worker PID", value: String(work.workerPID))
                    LabeledContent("分人标识", value: work.speakerTag)
                    Divider()
                    Text("本面板绝不包含任何用户输入 Prompt 原文、音频明文或绝对路径。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
        }
    }
}

private struct WorkItem: Identifiable {
    let id: String
    let title: String
    let promptText: String
    let voiceName: String
    let createdAt: String
    let duration: String
    let requestID: String
    let latencyMs: Int
    let tokens: Int
    let workerPID: Int
    let speakerTag: String
}
