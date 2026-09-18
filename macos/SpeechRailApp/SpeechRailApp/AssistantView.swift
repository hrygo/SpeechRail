import SwiftUI

// 语音助手页（`SESSIONS-SPEC` §6.1，五种态同页）。
//
// 页面只做一件事：把 `AssistantSession` 的状态摆出来，并把用户的动作交回去。
// 三种态的差别只在"页头下面那条结论区与中间的主区"，页头与右栏不动——
// 这正是稿把五态画在同一页上的原因（§6.1 开头）。

public struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionCoordinator.self) private var session
    @Environment(AssistantSession.self) private var assistant
    @Environment(SessionPreferences.self) private var preferences
    @Environment(\.openSettings) private var openSettings

    @State private var typed = ""
    @State private var rightTab: RightTab = .record
    @State private var memories: [AssistantMemory] = []
    /// 记录（这一轮说了什么）与回看。第五态「刚结束（记录库）」就落在这里。
    @State private var recent: [SessionSummary] = []
    @State private var reviewRecord: SessionRecord?
    @State private var reviewLines: [TranscriptLine] = []
    @State private var reviewSpeakerNames: [String: String] = [:]
    @State private var selectedPersonaID = ""
    @State private var selectedVoiceID = ""
    @State private var mode: AssistantMode = .turnTaking

    private enum RightTab: String, CaseIterable, Identifiable {
        case record
        case memory

        var id: String { rawValue }
        var title: String { self == .record ? "记录" : "记忆" }
    }

    public init() {}

    public var body: some View {
        PageScaffold(route: .assistant, scrollable: false) {
            VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                statusBar
                if let blocked = assistant.blocked, !blocked.allowsTyping {
                    blockedCard(blocked)
                }
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                        conversation
                        composer
                    }
                    inspector.speechRailInspectorColumn(alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } trailing: {
            if assistant.phase.isLive {
                PageActionButton(
                    title: "结束对话",
                    systemImage: "stop.circle",
                    helpText: "结束这次对话；记录会留在记录库里"
                ) {
                    Task { await session.stopCapture(endingWith: .user) }
                }
            }
        }
        .task {
            selectedPersonaID = preferences.defaultPersonaID
            selectedVoiceID = preferences.defaultVoiceID
            mode = preferences.assistantMode
            await reloadMemories()
            await reloadRecent()
        }
    }

    // MARK: - 状态带

    private var statusBar: some View {
        SessionStatusBar(
            title: statusTitle,
            tone: statusTone,
            facts: statusFacts,
            elapsed: assistant.phase.isLive ? session.elapsed : nil,
            level: assistant.phase.isLive ? assistant.level : nil
        ) {
            if assistant.phase.isLive {
                Button(assistant.isMuted ? "取消静音" : "静音麦克风") {
                    assistant.toggleMute()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("只是暂时不说了；对话、记录都留着。要结束用页头的「结束对话」")
            }
        }
    }

    private var statusTitle: String {
        if assistant.blocked != nil, !assistant.phase.isLive { return "这次对话没有开始" }
        if assistant.phase == .idle {
            return assistant.turns.isEmpty ? "还没有开始对话" : "已结束 · 记录在下面"
        }
        if assistant.isMuted { return "麦克风已静音" }
        return assistant.phase.title
    }

    private var statusTone: StatusTone {
        if assistant.blocked != nil { return .attention }
        switch assistant.phase {
        case .idle: return .neutral
        case .thinking, .preparing: return .attention
        default: return .healthy
        }
    }

    private var statusFacts: [String] {
        var facts: [String] = []
        if let model = assistant.llmModel { facts.append(model) }
        facts.append(mode.title)
        if let persona = assistant.persona { facts.append("人设：\(persona.title)") }
        if let name = currentVoiceName { facts.append("音色：\(name)") }
        return facts
    }

    private var currentVoiceName: String? {
        let id = assistant.voiceID ?? selectedVoiceID
        guard !id.isEmpty else { return nil }
        return model.creatorVoices.first { $0.id == id }?.name ?? id
    }

    // MARK: - 受阻

    private func blockedCard(_ blocked: AssistantSession.BlockReason) -> some View {
        StatusBanner(
            kind: .standard,
            tone: .attention,
            title: blocked.title,
            message: blocked.detail,
            actionTitle: actionTitle(for: blocked),
            action: { Task { await handleBlockedAction(blocked) } }
        )
    }

    private func actionTitle(for blocked: AssistantSession.BlockReason) -> String {
        switch blocked {
        case .llmNotConfigured, .llmUnreachable: "打开设置…"
        case .microphoneDenied: "重试"
        default: "重试"
        }
    }

    private func handleBlockedAction(_ blocked: AssistantSession.BlockReason) async {
        switch blocked {
        case .llmNotConfigured, .llmUnreachable:
            openSettings()
        default:
            await assistant.retry()
        }
    }

    // MARK: - 对话流

    private var conversation: some View {
        CardSurface {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        if let reviewRecord {
                            reviewHeader(reviewRecord)
                            ForEach(reviewLines) { line in
                                reviewLine(line)
                            }
                            if reviewLines.isEmpty {
                                Text("这一条记录里还没有正文。")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                        } else {
                        if assistant.turns.isEmpty, assistant.partialText == nil {
                            conversationPlaceholder
                        }
                        ForEach(assistant.turns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                        }
                        if let partial = assistant.partialText, !partial.isEmpty {
                            partialRow(partial)
                        }
                        if let streaming = assistant.streamingReply, !streaming.isEmpty {
                            streamingRow(streaming)
                        }
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.turns.count) { _, _ in
                    guard let last = assistant.turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var conversationPlaceholder: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("说一句话，或者直接打字。")
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            Text("人设与音色在下面定；开始之后人设本轮不再变（换了会让它把开头重读一遍），音色随时可换、下一句生效。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
    }

    private func reviewHeader(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(record.title ?? "这一轮对话")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                StatusPill(
                    tone: record.endedReason == .user ? .neutral : .attention,
                    label: record.endedReason.title
                )
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Button("回到实时") { closeReview() }
                    .buttonStyle(.link)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            Text(reviewSubtitle(record))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
        }
        .padding(.bottom, SpeechRailDesignTokens.Spacing.micro)
    }

    private func reviewSubtitle(_ record: SessionRecord) -> String {
        var parts = [record.startedAt.formatted(date: .numeric, time: .shortened), record.engineProfile]
        if let persona = record.persona { parts.append("人设：\(persona.title)") }
        if let model = record.llmModel { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private func reviewLine(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            StatusPill(
                tone: line.role == .assistant ? .neutral : .healthy,
                label: line.role == .assistant ? "助手" : "你"
            )
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(line.text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let label = line.speakerLabel {
                        Text(SpeakerLabeling.chipText(label: label, displayName: reviewSpeakerNames[label]))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    if line.source == .keyboard {
                        Text("打字")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    if line.isInterrupted {
                        // 被打断不是错误：正文仍在，也还能重播（§14.5）。
                        Text("被打断")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openRecord(_ summary: SessionSummary) async {
        guard let record = (try? await session.record(id: summary.id)) ?? nil else { return }
        reviewRecord = record
        reviewLines = (try? await session.lines(sessionID: summary.id)) ?? []
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
    }

    private func closeReview() {
        reviewRecord = nil
        reviewLines = []
        reviewSpeakerNames = [:]
    }

    private func reloadRecent() async {
        recent = (try? await session.listSummaries(kind: .assistant)) ?? []
    }

    private func turnRow(_ turn: AssistantSession.Turn) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            StatusPill(
                tone: turn.role == .assistant ? .neutral : .healthy,
                label: turn.role == .assistant ? "助手" : "你"
            )
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(turn.text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if turn.source == .keyboard {
                        Text("打字")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    if turn.isInterrupted {
                        // 被打断不是错误：正文仍然在，可以重放（§14.5）。
                        Text("被打断")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    if turn.role == .assistant {
                        Button("重播") { Task { await assistant.replay(turn: turn) } }
                            .buttonStyle(.link)
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.text, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(SpeechRailDesignTokens.Typography.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func partialRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            StatusPill(tone: .attention, label: "你")
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("正在识别…")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    private func streamingRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            StatusPill(tone: .attention, label: "助手")
            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部控制区（两行）

    private var composer: some View {
        CardSurface {
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                // 第一行是输入：语音仍是默认路径，打字是**随时可用的替代**（§6.1 第三轮）。
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    TextField("打字问也行…", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("发送") { send() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canType)
                }

                // 第二行是会话控制：模式分段控件 + 音色胶囊。
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Picker("对讲模式", selection: $mode) {
                        ForEach(AssistantMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .onChange(of: mode) { _, newValue in
                        preferences.assistantMode = newValue
                    }
                    .help(mode.detail)

                    Menu {
                        ForEach(availableVoices) { voice in
                            Button(voice.name) {
                                selectedVoiceID = voice.id
                                preferences.defaultVoiceID = voice.id
                                Task { await assistant.changeVoice(to: voice.id) }
                            }
                        }
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("音色：\(currentVoiceName ?? "未选")")
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("换音色下一句生效；它只改声音，不改人设")

                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                    if assistant.phase == .idle {
                        Button("开始对话") { Task { await start() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!preferences.isLLMConfigured)
                    }
                }

                if !preferences.isLLMConfigured {
                    Text("对话与纪要都要靠一台兼容 OpenAI、支持 Responses API 的服务；SpeechRail 只提供识别、合成与分人。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var availableVoices: [CreatorVoice] {
        model.creatorVoices.filter(\.available)
    }

    private var canType: Bool {
        switch assistant.blocked {
        case .none: assistant.phase.isLive
        case .some(let reason): reason.allowsTyping
        }
    }

    private func send() {
        let text = typed
        typed = ""
        Task { await assistant.ask(typed: text) }
    }

    private func start() async {
        let persona = preferences.persona(id: selectedPersonaID) ?? preferences.defaultPersona
        await assistant.start(
            persona: persona,
            voiceID: selectedVoiceID.isEmpty ? nil : selectedVoiceID,
            mode: mode
        )
    }

    // MARK: - 右栏（记录 / 记忆）

    private var inspector: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Picker("", selection: $rightTab) {
                ForEach(RightTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch rightTab {
            case .record:
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                    recordFacts
                    recentList
                }
            case .memory:
                memoryList
            }
        }
    }

    /// 「刚结束（记录库）」那一态：本能力的记录在这里回看（§6.1 第五节）。
    /// 记录库是资产，**不因为页面上多了一块实时区就变得够不着**。
    private var recentList: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "记录库") { EmptyView() }
                if recent.isEmpty {
                    Text("还没有对话记录。结束一轮之后，它会出现在这里。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(recent.prefix(12)) { summary in
                    Button {
                        Task { await openRecord(summary) }
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                                Text(summary.record.title ?? "这一轮对话")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .lineLimit(1)
                                Text(
                                    "\(summary.record.startedAt.formatted(date: .numeric, time: .shortened))"
                                        + " · \(summary.lineCount) 句"
                                )
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            if summary.openInterruption != nil {
                                StatusPill(tone: .attention, label: "有中断")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var recordFacts: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "这一轮") { EmptyView() }
                factRow("大模型", value: preferences.isLLMConfigured ? (assistant.llmModel ?? preferences.llmConfiguration.model) : "未配置")
                factRow("音色", value: currentVoiceName ?? "未选", detail: "下一句可换")
                if let persona = assistant.persona {
                    // 人设的控件是**只读行 + 锁 + 一个出口**，不是选择器（§14.4）。
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("人设（本轮已定 · 只读）")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Image(systemName: "lock.fill")
                                .accessibilityHidden(true)
                            Text(persona.title)
                                .font(SpeechRailDesignTokens.Typography.body)
                        }
                        Button("新开一轮…") {
                            Task {
                                await session.stopCapture(endingWith: .user)
                                await start()
                            }
                        }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .help(assistant.personaLock)
                    }
                }
                factRow("打断", value: mode.allowsBargeIn ? "实时对讲时生效" : "一问一答：它说话时闭麦")
                factRow("上下文", value: "\(assistant.turns.count) 轮")
                factRow("输入", value: "语音或打字")
                Text("打字提问时不朗读回复；回复仍可点「重播」。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func factRow(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            if let detail {
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    private var memoryList: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: "记忆") { EmptyView() }
                if memories.isEmpty {
                    Text("还没有记下来的事。它在对话里提议、你点头之后才会写进来。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text(memory.body)
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(memory.kind == .preference ? "偏好" : (memory.kind == .fact ? "事实" : "摘要"))
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            Button(memory.isActive ? "停用" : "启用") {
                                Task {
                                    try? await session.setMemoryActive(id: memory.id, active: !memory.isActive)
                                    await reloadMemories()
                                }
                            }
                            .buttonStyle(.link)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            Button("移除") {
                                Task {
                                    try? await session.removeMemory(id: memory.id)
                                    await reloadMemories()
                                }
                            }
                            .buttonStyle(.link)
                            .font(SpeechRailDesignTokens.Typography.caption)
                        }
                    }
                }
                Text("记忆在**下一轮**生效；移除记忆不会动历史记录。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private func reloadMemories() async {
        memories = (try? await session.memories(activeOnly: false)) ?? []
    }
}
