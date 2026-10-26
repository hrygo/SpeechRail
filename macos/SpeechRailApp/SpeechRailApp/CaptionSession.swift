import Foundation
import Observation
import SpeechRailControlKit

public protocol CaptionRealtimeClient: RealtimeTextDrainClient {
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event>
    func connect() async throws
    func append(_ pcm: Data) async throws
    func close() async
}


extension RealtimeASRClient: CaptionRealtimeClient {}

public struct CaptionRealtimeClientConfiguration: Sendable, Equatable {
    public var port: Int
    public var scenePreset: ASRScenePreset
    public var diarizationEnabled: Bool
    public var apiKey: String?
    public var expectedASRRevision: String?
    public var windowScene: SpeechRailWindowScene?
    /// 用户选定的源语言；`nil` 表示自动识别。只在建连时生效。
    public var language: String?
    /// 字幕术语表的原文词条，随建连传给 ASR 作为专名提示。
    public var keywords: [String]?

    public init(
        port: Int,
        scenePreset: ASRScenePreset = .caption,
        diarizationEnabled: Bool,
        apiKey: String?,
        expectedASRRevision: String?,
        windowScene: SpeechRailWindowScene? = nil,
        language: String? = nil,
        keywords: [String]? = nil
    ) {
        self.port = port
        self.scenePreset = scenePreset
        self.diarizationEnabled = diarizationEnabled
        self.apiKey = apiKey
        self.expectedASRRevision = expectedASRRevision
        self.windowScene = windowScene
        self.language = language
        self.keywords = keywords
    }
}

public struct CaptionSessionDependencies: Sendable {
    public var makeRealtimeClient:
        @Sendable (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient
    public var persistenceConfiguration: TranscriptPersistenceQueue.Configuration
    public var saveLine: (@Sendable (LineDraft, String) async throws -> Int)?
    public var attachTranscriptAttribution: (@Sendable (String, [TranscriptAttributionUnit]) async throws -> TranscriptLine)?
    public var drainTimeout: Duration
    public var revisionWindowEnabled: Bool?

    public init(
        makeRealtimeClient: @escaping @Sendable
            (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient,
        persistenceConfiguration: TranscriptPersistenceQueue.Configuration = .init(),
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        attachTranscriptAttribution: (@Sendable (String, [TranscriptAttributionUnit]) async throws -> TranscriptLine)? = nil,
        drainTimeout: Duration = .seconds(12),
        revisionWindowEnabled: Bool? = nil
    ) {
        self.makeRealtimeClient = makeRealtimeClient
        self.persistenceConfiguration = persistenceConfiguration
        self.saveLine = saveLine
        self.attachTranscriptAttribution = attachTranscriptAttribution
        self.drainTimeout = drainTimeout
        self.revisionWindowEnabled = revisionWindowEnabled
    }

    public static func production() -> Self {
        Self(makeRealtimeClient: { configuration in
            RealtimeASRClient(
                port: configuration.port,
                language: configuration.language,
                keywords: configuration.keywords,
                scenePreset: configuration.scenePreset,
                windowScene: configuration.windowScene,
                diarizationEnabled: configuration.diarizationEnabled,
                apiKey: configuration.apiKey,
                expectedASRRevision: configuration.expectedASRRevision
            )
        })
    }
}

/// Rendering and scroll invalidation share the text actually visible in the band.
/// Wire revisions without a text change must not create another scroll request.
struct CaptionBandContent: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        enum ID: Hashable, Sendable {
            case final(String)
            case window(String)
            case partial
        }
        /// 未定稿原文的视觉分层（`spec §11.1`）：稳定前缀提高对比度，活跃尾部保持次级色。
        ///
        /// 两段拼接等于该行原文；`isSecondary` 表示原文画在次行（双语模式下已有译文时）。
        struct SourceTiering: Equatable, Sendable {
            let stablePrefix: String
            let volatileTail: String
            let isSecondary: Bool
        }
        let id: ID
        let text: String
        let primaryText: String
        let secondaryText: String?
        let sourceTiering: SourceTiering?
        /// 主行（通常是译文）的稳定前缀分层；终稿没有尾部，因此为 nil。
        let primaryTiering: SourceTiering?
        let isPartial: Bool
        let isTranslating: Bool

        init(
            id: ID,
            text: String,
            primaryText: String? = nil,
            secondaryText: String? = nil,
            sourceTiering: SourceTiering? = nil,
            primaryTiering: SourceTiering? = nil,
            isPartial: Bool,
            isTranslating: Bool = false
        ) {
            self.id = id
            self.text = text
            self.primaryText = primaryText ?? text
            self.secondaryText = secondaryText
            self.sourceTiering = sourceTiering
            self.primaryTiering = primaryTiering
            self.isPartial = isPartial
            self.isTranslating = isTranslating
        }
    }
    let rows: [Row]

    init(
        lines: [CaptionSession.Line],
        pendingCommands: [TranscriptPersistenceQueue.Command] = [],
        activeRecordID: String? = nil,
        windowUnits: [TranscriptWindowUnit]?,
        partialText: String?,
        partialTranslatedText: String? = nil,
        partialStablePrefixLength: Int = 0,
        partialTranslationStablePrefixLength: Int = 0,
        displayMode: CaptionDisplayMode = .bilingual,
        shouldTranslatePartial: Bool? = nil
    ) {
        var rows: [Row] = []
        for line in lines {
            let primary: String
            let secondary: String?
            switch displayMode {
            case .originalOnly:
                primary = line.text
                secondary = nil
            case .chineseOnly:
                primary = line.translatedText ?? line.text
                secondary = nil
            case .bilingual:
                if let translated = line.translatedText, !translated.isEmpty, translated != line.text {
                    primary = translated
                    secondary = line.text
                } else {
                    primary = line.text
                    secondary = nil
                }
            }
            rows.append(Row(
                id: .final(line.id),
                text: primary,
                primaryText: primary,
                secondaryText: secondary,
                isPartial: false,
                isTranslating: displayMode != .originalOnly && line.isTranslating
            ))
        }

        var visibleLineIDs = Set(lines.map(\.id))
        for command in pendingCommands {
            guard let activeRecordID,
                  command.sessionID == activeRecordID,
                  command.formal,
                  visibleLineIDs.insert(command.lineID).inserted
            else { continue }
            rows.append(Row(
                id: .final(command.lineID),
                text: command.text,
                primaryText: command.text,
                secondaryText: nil,
                isPartial: false,
                isTranslating: false
            ))
        }

        let currentPartial = windowUnits?.map(\.text).joined() ?? partialText
        if let currentPartial, !currentPartial.isEmpty {
            let cleanedPartialTranslation = partialTranslatedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 模型原样回显原句：屏幕上没必要显示两遍，按「没有译文」去重。
            let translation = (cleanedPartialTranslation?.isEmpty == false
                && cleanedPartialTranslation != currentPartial) ? partialTranslatedText : nil
            // 但「是否还在翻」要另算：仅在该半句确实需要翻译（非仅原文、非中文）且尚无译文时才显示翻译中。
            let needsPartialTranslation = shouldTranslatePartial ?? (
                displayMode != .originalOnly
                    && !CaptionLanguageDetector.detect(for: currentPartial).isChinese
            )
            let isTranslatingPartial = needsPartialTranslation && (cleanedPartialTranslation ?? "").isEmpty
            let primary: String
            let secondary: String?
            var sourceIsSecondary = false
            switch displayMode {
            case .originalOnly:
                primary = currentPartial
                secondary = nil
            case .chineseOnly:
                primary = translation ?? currentPartial
                secondary = nil
            case .bilingual:
                if let translation {
                    primary = translation
                    secondary = currentPartial
                    sourceIsSecondary = true
                } else {
                    primary = currentPartial
                    secondary = nil
                }
            }
            let rowID: Row.ID = windowUnits != nil ? .window(windowUnits?.first?.unitID ?? "window") : .partial
            // 视觉分层只能挂在「原文真的上屏」的那一格：`tieredSourceText` 渲染的是分层里那根
            // 字符串本身。「仅中文」档只要有译文，原文就不上屏，此时若还挂着分层，
            // 渲染层会把原文（例如英文）画进本该显示中文的位置。
            let sourceTextIsOnScreen = displayMode != .chineseOnly || translation == nil
            let translationTiering = displayMode == .originalOnly ? nil : translation.flatMap {
                Self.sourceTiering(
                    for: $0,
                    stablePrefixLength: partialTranslationStablePrefixLength,
                    isSecondary: false
                )
            }
            rows.append(Row(
                id: rowID,
                text: primary,
                primaryText: primary,
                secondaryText: secondary,
                sourceTiering: sourceTextIsOnScreen
                    ? Self.sourceTiering(
                        for: currentPartial,
                        stablePrefixLength: partialStablePrefixLength,
                        isSecondary: sourceIsSecondary
                    )
                    : nil,
                primaryTiering: translationTiering,
                isPartial: true,
                isTranslating: isTranslatingPartial
            ))
        }
        self.rows = rows.filter { !$0.primaryText.isEmpty }
    }

    /// 把未定稿原文切成「稳定前缀 + 活跃尾部」两段；长度不合法时不分层，整行同色。
    private static func sourceTiering(
        for sourceText: String,
        stablePrefixLength: Int,
        isSecondary: Bool
    ) -> Row.SourceTiering? {
        guard stablePrefixLength > 0, stablePrefixLength < sourceText.count else { return nil }
        let stable = String(sourceText.prefix(stablePrefixLength))
        let tail = String(sourceText.dropFirst(stablePrefixLength))
        guard !stable.isEmpty, !tail.isEmpty else { return nil }
        return Row.SourceTiering(stablePrefix: stable, volatileTail: tail, isSecondary: isSecondary)
    }
}

// 实时字幕的会话层（`SESSIONS-SPEC` §6.3、`TECHNICAL-DESIGN` §5.7）。
//
// **它不认识 AppKit，也不认识窗口。** 浮层由 `CaptionBandWindowController` 负责；这里只说
// "现在该看得见 / 看不见"（`presentBand`）。于是这一层可以脱离界面单独跑——阶段 3 的验收
// 正是这么做的：用文件音频源驱动同一条链路，核对库里真的落了行与时间码。
//
// 三段职责，边界不能混：
//   ① 设备与连接的生命周期（用户裁决：**按功能启用、功能离开释放**）；
//   ② 内存里的 partial 与定稿；**定稿即落库**，库里不出现 `status='partial'` 的行；
//   ③ 受阻：几类原因共用同一条带子，**一律保留最后一句字幕**（可读、可复制）。
//
// 两条只在这里才说得清的取舍：
//
//   - **时间码是相对会话开始的墙钟秒**（§15 的 `t_start` 注释）。暂停与断线留下的空档
//     因此在导出物里是**看得见的跳变**，而不是被悄悄抹平——那正是 §16.7 要的证据。
//     不用"已录音频的秒数"当基准，因为那会把空档伪装成连续。
//   - **`timing_quality` 只在拿到对齐证据时才写**。它随 `speechrail.alignment.done`
//     独立到达，属于分人那一步；字幕不协商对齐时这一列保持 NULL，不假装有时间码。

@MainActor
@Observable
public final class CaptionSession {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case preparing
        case running
        case paused
        /// 正在收尾（把最后半句交出去、等终态）。
        case ending

        public var isLive: Bool { self == .running || self == .paused }
    }

    /// 受阻的原因。共用同一条带子，各给一个出口（§6.3.1 / §16.3）。
    public enum BlockReason: Equatable, Sendable {
        case microphoneDenied
        case serviceNotReady(String)
        /// 服务可达，但流式 worker 被另一个实时会话占着（`backend_busy`）。
        case serviceBusy(String)
        /// 已经在跑另一个会话：麦克风同一时刻只能由一个会话使用（§6.4）。
        case occupiedBy(SessionKind)
        case storeUnavailable(String)
        /// 转写链路中途断了。正文保留，可以重新接上（新 epoch，不重放 PCM）。
        case streamFailed(String)
        case noTargetSelected
        case systemAudioUnavailable(String)

        public var title: String {
            switch self {
            case .microphoneDenied: "麦克风未授权，字幕带已暂停"
            case .serviceNotReady: "语音服务未就绪"
            case .serviceBusy: "语音服务正忙"
            case .occupiedBy(let kind): "\(kind.title)正在使用麦克风"
            case .storeUnavailable: "记录库不可用"
            case .streamFailed: "转写中断了"
            case .noTargetSelected: "还没有选择要显示字幕的应用窗口"
            case .systemAudioUnavailable: "应用音频采集未就绪"
            }
        }

        public var detail: String {
            switch self {
            case .microphoneDenied:
                "在系统设置里允许 SpeechRail 使用麦克风，然后回到这里重试。"
            case .serviceNotReady(let message):
                message
            case .serviceBusy(let message):
                message
            case .occupiedBy:
                "字幕带不会再开第二条会话。可以在会议的文字记录里看，或者结束会议并启动字幕。"
            case .storeUnavailable(let message):
                message
            case .streamFailed(let message):
                // 断开码要带给用户：`1008`（握手被拒）与「服务中途挂了」是两件事，
                // 只写"中断了"会让人没法判断该去检查 key 还是该去看服务。
                "\(message)丢掉的音频就是没录上；已经定稿的字幕都还在，可以重新接上往下听。"
            case .noTargetSelected:
                "点击「选择应用窗口」拾取正在播放视频或音频的窗口，或切换为麦克风收音。"
            case .systemAudioUnavailable(let message):
                "\(message)请在系统设置 → 隐私与安全性 → 录音中允许 SpeechRail，然后重试。"
            }
        }

        /// `重新接上` 只对流式中断有意义：其他几种要么还没开始过，要么是别的东西占着。
        public var canResume: Bool {
            if case .streamFailed = self { return true }
            return false
        }
    }

    /// 带子里的一行。**只有定稿才会出现在这里**；未定稿在 `partialText`。
    public struct Line: Identifiable, Sendable, Equatable {
        public var id: String
        public var ordinal: Int
        public var text: String
        public var start: TimeInterval?
        public var end: TimeInterval?
        /// 分人给的匿名标签（`A`…`D`）。未开分人时为 `nil`，行内就不出现 chip。
        public var speakerLabel: String?
        public var attributionUnits: [TranscriptAttributionUnit] = []
        public var speakerLabelIsManual = false
        public var sourceLanguage: String?
        public var translatedText: String?
        public var isTranslating: Bool = false

        public init(
            id: String,
            ordinal: Int,
            text: String,
            start: TimeInterval? = nil,
            end: TimeInterval? = nil,
            speakerLabel: String? = nil,
            attributionUnits: [TranscriptAttributionUnit] = [],
            speakerLabelIsManual: Bool = false,
            sourceLanguage: String? = nil,
            translatedText: String? = nil,
            isTranslating: Bool = false
        ) {
            self.id = id
            self.ordinal = ordinal
            self.text = text
            self.start = start
            self.end = end
            self.speakerLabel = speakerLabel
            self.attributionUnits = attributionUnits
            self.speakerLabelIsManual = speakerLabelIsManual
            self.sourceLanguage = sourceLanguage
            self.translatedText = translatedText
            self.isTranslating = isTranslating
        }
    }

    public enum ServiceReadiness: Sendable {
        /// 服务可用，顺带带上当前档位（写进会话记录，服务读不到时给 `unknown`）。
        case ready(profile: String?)
        case notReady(String)
    }

    // MARK: 状态

    public private(set) var phase: Phase = .idle
    public private(set) var blocked: BlockReason?
    /// 本次会话已定稿的行（内存镜像；权威在库里，这里只给浮层与导出用）。
    public let transcriptPresentation = TranscriptPresentation<Line>()
    public private(set) var lines: [Line] {
        get { transcriptPresentation.rows }
        set { transcriptPresentation.reset(newValue) }
    }
    /// 未定稿的增量累加结果。`nil` 表示这一轮还没开始出字。
    public private(set) var partialText: String? {
        didSet {
            partialStablePrefixLength = CaptionPartialStability.stablePrefixLength(
                previous: oldValue ?? "",
                current: partialText ?? ""
            )
            guard let text = partialText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                // 注意：此处不调用 `translationCoordinator.cancelPartial()`，因为 `.completed` 先将
                // `partialText` 置 `nil`，随后在 `didSaveTranscript` 中才调用 `translateCompletedLine`
                // 读取协调器内的 `stabilizedDraftPrefix` 与 `lastPartialTranslation`。
                partialTranslatedText = nil
                isTranslatingPartial = false
                return
            }
            if oldValue != partialText {
                scheduleCurrentPartialTranslation(for: text)
            }
        }
    }

    private func scheduleCurrentPartialTranslation(for text: String) {
        guard translationEnabled else { return }
        let context = lines.suffix(2).map {
            CaptionContextTurn(
                sourceText: $0.text,
                translatedText: $0.translatedText
            ).formattedPromptLine
        }
        translationCoordinator.schedulePartialTranslation(
            sourceText: text,
            contextLines: context,
            displayMode: effectiveDisplayMode,
            preferredLanguage: sourceLanguage,
            glossary: glossary
        ) { [weak self] translated in
            guard let self else { return }
            self.partialTranslatedText = translated
            if let translated,
               let stable = self.translationCoordinator.stabilizedDraftPrefix,
               translated.hasPrefix(stable) {
                self.partialTranslationStablePrefixLength = stable.count
            } else {
                self.partialTranslationStablePrefixLength = 0
            }
            let latestSource = self.partialText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackSource = latestSource.isEmpty ? text : latestSource
            let matchedSource = self.translationCoordinator.currentTranslatedSourceText ?? fallbackSource
            // 中文直通时 `translated` 为 nil：那份草稿不再属于任何一句，一起清掉。
            self.lastPartialTranslation = translated.map {
                (sourceText: matchedSource, translatedText: $0)
            }
        }
    }
    /// 未定稿原文的稳定前缀长度（`spec §11.1` 视觉分层；`0` 表示这次还看不出稳定区）。
    public private(set) var partialStablePrefixLength = 0
    /// 最近一次到达的未定稿译文，连同它**出自哪一句原文**。
    ///
    /// 要单独留一份而不是读 `partialTranslatedText`，有两个理由：
    /// ① `commit()` 先把 `partialText` 清零，再走 `didSaveTranscript`，那时预览译文已经没了；
    /// ② 被拒绝/丢弃的预览同样会走到"清零"这一步，只按"最近一次"继承会把上一句的译文
    ///    挪到下一句上。带上原文，才判断得出这份草稿是不是这一句的前身。
    private var lastPartialTranslation: (sourceText: String, translatedText: String)?
    /// 采集的真实电平 0…1（浮层页脚那几根柱子读它）。
    public private(set) var level: Double = 0
    public private(set) var sessionID: String?
    /// 浮层是否应该可见。界面层照着它显隐。
    public private(set) var isBandVisible = false
    /// 失败过的话这里是给人看的一句；原始错误码不外泄（§9 的脱敏口径）。
    public private(set) var lastFailure: String?
    /// 导出动作独立于转写状态；界面以浮层呈现，不改变字幕受阻或收尾状态。
    public private(set) var exportFailure: String?

    public func clearExportFailure() { exportFailure = nil }
    public func clearFailure() {
        lastFailure = nil
        labeling.clearDiagnostic()
    }

    #if DEBUG
    /// 离屏渲染工装（`/tmp` 里的 `NSHostingView`）用的**只写展示状态**夹具。
    ///
    /// 字幕带是浮层，真机验收要"解锁 + 麦克风 + 服务"三样同时在手；在此之前，版面
    /// （行、半句、页脚、受阻行）只能靠渲染真实视图来看。这个钩子沿用 App 里已有的
    /// `--ui-test` fixture 口径：只在 Debug 构建里存在，不碰存储、网络与设备，
    /// 也不改变任何产线行为。
    func applyRenderFixture(
        lines: [Line],
        partialText: String?,
        phase: Phase,
        blocked: BlockReason?
    ) {
        self.lines = lines
        self.partialText = partialText
        self.phase = phase
        self.blocked = blocked
    }
    #endif

    // MARK: 目标与翻译

    private let defaults: UserDefaults

    /// 当前选定的字幕音频源（默认 nil，首次开启时引导拾取窗口或使用上次选定的运行中应用）。
    public var audioTarget: CaptionAudioTarget?
    /// 是否把外语字幕实时翻译成中文。**默认关**：用户没主动打开时，一个翻译请求都不发。
    ///
    /// 关掉时 `effectiveDisplayMode` 恒为 `.originalOnly`，屏幕上只出现原文；已经存在
    /// 记录里的译文不删，重新打开即可继续用。`displayMode` 只决定打开翻译后的排版。
    public var translationEnabled: Bool {
        didSet {
            defaults.set(translationEnabled, forKey: "speechrail.caption.translationEnabled")
            guard oldValue != translationEnabled else { return }
            if translationEnabled {
                // 旧版本只存过「仅原文」：打开翻译时给一个能看见译文的排版。
                if displayMode == .originalOnly { displayMode = .bilingual }
                retranslateUntranslatedFinalLinesIfNeeded()
                if let text = partialText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    scheduleCurrentPartialTranslation(for: text)
                }
            } else {
                translationCoordinator.cancelPartial()
                partialTranslatedText = nil
                lastPartialTranslation = nil
            }
        }
    }
    /// 字幕显示模式（双语对照 / 仅中文 / 仅原文）。只在翻译打开时决定排版。
    ///
    /// 持久化的是用户的**排版偏好**；是否调用翻译模型由 `translationEnabled` 单独决定。
    public var displayMode: CaptionDisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: "speechrail.caption.displayMode")
            guard oldValue != displayMode, translationEnabled else { return }
            if displayMode == .originalOnly {
                translationCoordinator.cancelPartial()
                partialTranslatedText = nil
                lastPartialTranslation = nil
            } else {
                retranslateUntranslatedFinalLinesIfNeeded()
                if let text = partialText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    scheduleCurrentPartialTranslation(for: text)
                }
            }
        }
    }
    /// 实际生效的排版：翻译关着时只显示原文。
    public var effectiveDisplayMode: CaptionDisplayMode {
        translationEnabled ? displayMode : .originalOnly
    }
    /// 现在是否真的有一个可用的翻译模型（设置里配了 `.captions`，或跟随全局配置）。
    public var isTranslationAvailable: Bool {
        makeTranslationClient?() != nil
    }
    /// 本场字幕的翻译延迟/队列/成败汇总；只含毫秒与计数，不含正文。
    public var translationMetrics: CaptionTranslationMetrics {
        translationCoordinator.metrics
    }
    /// 字幕术语表原文（逗号/分号/换行分隔，可写「原文=译法」），持久化到 UserDefaults。
    ///
    /// 只影响字幕：原文词条随下一次建连喂给 ASR `keywords`，完整条目注入翻译提示词。
    /// 输入上限 2000 字符；实际生效最多 24 条，避免撑大握手与提示词。
    public var glossaryText: String {
        didSet {
            let bounded = String(glossaryText.prefix(2_000))
            if bounded != glossaryText {
                glossaryText = bounded
                return
            }
            defaults.set(glossaryText, forKey: "speechrail.caption.glossaryText")
        }
    }
    /// 由 `glossaryText` 解析出的当前术语表。
    public var glossary: CaptionGlossary {
        CaptionGlossary(text: glossaryText)
    }
    /// 字幕音频源语种（自动识别 / 英语 / 日语 / 韩语 / 中文），持久化到 UserDefaults。
    ///
    /// 它是**识别**语言，不只是翻译设置：非自动档会随建连透传给 Realtime ASR。
    /// 会话中途切换时，翻译侧立即按新语种补翻；识别侧从下一次建连（暂停后继续 /
    /// 重新接上）生效，不在音频流中途切语言。
    public var sourceLanguage: CaptionSourceLanguage {
        didSet {
            defaults.set(sourceLanguage.rawValue, forKey: "speechrail.caption.sourceLanguage")
            guard oldValue != sourceLanguage else { return }
            if sourceLanguage == .chinese {
                translationCoordinator.cancelPartial()
                partialTranslatedText = nil
                lastPartialTranslation = nil
            } else if translationEnabled {
                retranslateUntranslatedFinalLinesIfNeeded()
                if let text = partialText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    scheduleCurrentPartialTranslation(for: text)
                }
            }
        }
    }
    /// 浮层定位模式（智能吸附目标窗口 / 自由悬浮钉住）。
    public var placementMode: CaptionBandPlacementMode = .dockedToTargetWindow
    /// 外语未定稿句的实时中文预览译文。
    public private(set) var partialTranslatedText: String? {
        didSet {
            if partialTranslatedText == nil {
                partialTranslationStablePrefixLength = 0
            }
        }
    }
    /// 预览译文里已经经两次 LocalAgreement 确认的稳定前缀长度；只影响显示分层。
    public private(set) var partialTranslationStablePrefixLength = 0
    /// Stage 1 未定稿预览翻译是否正在请求中（仅在流式请求在途且尚未产出首字时为 true，防抖未达阈值或请求失败后立即置 false，避免卡死显示「翻译中」）。
    public private(set) var isTranslatingPartial = false
    /// 由 App 层注入：按 CaptionAudioTarget 创建对应的 AudioChunkSource（App -> SystemAudioCapture, Mic -> MicrophoneCapture）。
    public var makeAudioSourceForTarget: (@MainActor (CaptionAudioTarget) -> AudioChunkSource)?
    /// 由 App 层注入：唤起全屏窗口拾取器。
    public var presentWindowPicker: (@MainActor () async -> CaptionAudioTarget?)?
    /// 由 App 层注入：提供翻译客户端（读取 SessionPreferences 中 .captions 模块的 LLM 配置）。
    public var makeTranslationClient: (@MainActor () -> (any CaptionTranslationClient)?)?

    /// 翻译协调器
    @ObservationIgnored private lazy var translationCoordinator: CaptionTranslationCoordinator = {
        let coordinator = CaptionTranslationCoordinator(makeClient: { [weak self] in
            self?.makeTranslationClient?()
        })
        coordinator.onPartialTranslatingStateChange = { [weak self] isTranslating in
            self?.isTranslatingPartial = isTranslating
        }
        return coordinator
    }()

    // MARK: 挂载点（由 App 注入）

    /// 浮层呈现口：`true` 出现、`false` 隐藏。会话层不认识窗口。
    public var presentBand: (@MainActor (Bool) -> Void)?
    /// `/readyz` 只作为诊断来源；Realtime capability binding 才决定能否启动。
    public var serviceReadiness: (@MainActor () async -> ServiceReadiness)?
    public var realtimeCapabilityBindingProvider:
        (@MainActor () async -> RealtimeCapabilityBinding?)?
    /// 音频来源。默认麦克风；核对时换成文件源，链路其余部分完全不变。
    public var audioSourceFactory: @MainActor () -> AudioChunkSource = { MicrophoneCapture() }
    /// 这一场要不要开分人。**每场一次**：契约规定只能在首个 PCM 之前协商。
    /// 默认关（§14.3 的开关粒度）。
    public var diarizationPreference: @MainActor () -> Bool = { false }

    private let coordinator: SessionCoordinator
    /// 分人归属账本。会议与字幕共用底座，这里持有的是本场那一个实例。
    public let labeling: SpeakerLabeling
    private let dependencies: CaptionSessionDependencies
    private let port: Int
    private let apiKey: String?

    private var source: AudioChunkSource?
    private var client: (any CaptionRealtimeClient)?
    private var pump: Task<Void, Never>?
    private var uploadPump: Task<Void, Never>?
    private var sessionStartedAt: Date?
    private var nextConnectionID = 0
    private var sessionGeneration = 0
    private var previewIdentity: TranscriptPreviewLedger.Identity?
    public private(set) var windowCapture: TranscriptWindowCapture?
    private var retiredWindowCaptures: [TranscriptWindowCapture] = []
    private var windowFallbackNote: String?
    private var completionRecordID: String?
    public private(set) var completionDiagnosticCode: String?
    public var completionFailure: SessionDrainFailure? {
        let recordID = completionRecordID ?? sessionID ?? coordinator.activeSessionID
        guard let recordID else { return nil }
        if let failure = coordinator.captureCompletionFailure(recordID: recordID) { return failure }
        if let pending = coordinator.pendingSeals[recordID],
           pending.failureReason != nil || coordinator.activeSessionID != recordID {
            return SessionDrainFailure(stage: .seal,
                message: pending.failureReason ?? "记录尚未确认封存，请保留已有文字。")
        }
        return nil
    }
    public var transcriptionStatusText: String? {
        if completionFailure != nil { return "字幕收尾尚未确认" }
        return windowCapture?.statusText ?? windowFallbackNote
    }
    var bandContent: CaptionBandContent {
        let pendingCommands = sessionID.map { recordID in
            inputPersistence.unsettledInputs(sessionID: recordID).map { $0.command }
        } ?? []
        let mode = effectiveDisplayMode
        let partialCandidate = windowCapture?.visibleUnits.map(\.text).joined() ?? partialText
        let shouldTranslatePartial = isTranslatingPartial && (partialCandidate.map {
            Self.shouldTranslate(
                text: $0,
                displayMode: mode,
                preferredLanguage: sourceLanguage,
                hasTranslationClient: makeTranslationClient?() != nil
            )
        } ?? false)
        return CaptionBandContent(
            lines: lines,
            pendingCommands: pendingCommands,
            activeRecordID: sessionID,
            windowUnits: windowCapture?.visibleUnits,
            partialText: partialText,
            partialTranslatedText: partialTranslatedText,
            partialStablePrefixLength: partialStablePrefixLength,
            partialTranslationStablePrefixLength: partialTranslationStablePrefixLength,
            displayMode: mode,
            shouldTranslatePartial: shouldTranslatePartial
        )
    }

    private func beginWindowCapture(enabled: Bool, identity: TranscriptPreviewLedger.Identity, captureStartedAt: Date) {
        if let previous = windowCapture {
            previous.retainTail()
            retiredWindowCaptures.removeAll { $0.queue.isComplete }
            retiredWindowCaptures.append(previous)
        }
        windowCapture = nil
        guard enabled, let recordID = sessionID else { return }
        let coordinator = coordinator
        windowCapture = TranscriptWindowCapture(recordID: recordID, identity: identity,
            source: audioTarget?.lineSource ?? .microphone, offsetSeconds: captureStartedAt.timeIntervalSince(sessionStartedAt ?? captureStartedAt),
            observedAt: captureStartedAt, save: { command in
                switch command {
                case .sealed(let batch): return try await coordinator.appendSealedWindow(batch)
                case .checkpoint(let checkpoint):
                    try await coordinator.saveWindowCheckpoint(checkpoint)
                    return WindowSaveAck(transactionID: checkpoint.id, lineOrdinals: [:], savedThrough: 0)
                }
            }, didSave: { [weak self] command, ordinal in
                await self?.didSaveTranscript(command, ordinal: ordinal)
                if self?.windowCapture?.identity == identity {
                    let text = self?.windowCapture?.visibleText ?? ""
                    self?.partialText = text.isEmpty ? nil : text
                }
            })
    }
    private var previewLedger = TranscriptPreviewLedger()
    /// 终态事件计数：收尾时用来判断"最后半句到底回来了没有"。
    private var terminalCount = 0
    private var isStoppingIntentionally = false
    private var currentOrdinal = 0
    /// `(connection, generation, itemID)` → 已落库的行，防止迟到辅助结果串写。
    private var lineByItem = LiveTranscriptItemIndex()
    private var pendingAttributions = TranscriptAttributionBuffer()
    private var admissionLedger = TranscriptAdmissionLedger()
    @ObservationIgnored private lazy var inputPersistence = TranscriptPersistenceQueue(
        configuration: dependencies.persistenceConfiguration,
        save: { [weak self] command in
            guard let self else { throw CancellationError() }
            return try await self.saveTranscriptLine(command)
        },
        didSave: { [weak self] command, ordinal in
            await self?.didSaveTranscript(command, ordinal: ordinal)
        }
    )
    /// 已经补写过 `timing_quality` 的行；同一行只写一次。
    private var timingQualityApplied: Set<String> = []
    /// 这一场是否协商过分人（决定了结束时要等 EOF 屏障）。
    private var diarizationActive = false

    public init(
        coordinator: SessionCoordinator,
        port: Int = 8201,
        apiKey: String? = nil,
        dependencies: CaptionSessionDependencies? = nil,
        audioSourceFactory: (@MainActor () -> AudioChunkSource)? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedDependencies = dependencies ?? .production()
        self.coordinator = coordinator
        self.labeling = SpeakerLabeling(coordinator: coordinator, attachAttribution: resolvedDependencies.attachTranscriptAttribution)
        self.dependencies = resolvedDependencies
        self.port = port
        self.apiKey = apiKey
        self.defaults = defaults
        // 翻译默认关：旧版本没有这个键时 `bool` 返回 false，正好是「用户没主动打开」。
        self.translationEnabled = defaults.bool(forKey: "speechrail.caption.translationEnabled")
        self.glossaryText = defaults.string(forKey: "speechrail.caption.glossaryText") ?? ""
        if let raw = defaults.string(forKey: "speechrail.caption.displayMode"),
           let mode = CaptionDisplayMode(rawValue: raw),
           mode != .originalOnly {
            // 旧版本把「仅原文」当成一个排版档存下来；新语义里它等价于「翻译关」，
            // 排版偏好退回双语，这样用户下次打开翻译时能立刻看到译文。
            self.displayMode = mode
        } else {
            self.displayMode = .bilingual
        }
        if let raw = defaults.string(forKey: "speechrail.caption.sourceLanguage"),
           let lang = CaptionSourceLanguage(rawValue: raw) {
            self.sourceLanguage = lang
        } else {
            self.sourceLanguage = .auto
        }
        if let audioSourceFactory {
            self.audioSourceFactory = audioSourceFactory
        }
    }

    public var isRunning: Bool { phase == .running || phase == .preparing }

    private func saveTranscriptLine(_ command: TranscriptPersistenceQueue.Command) async throws -> Int {
        do {
            if let save = dependencies.saveLine {
                return try await save(command.lineDraft, command.lineID)
            }
            return try await coordinator.appendLine(command.lineDraft, id: command.lineID)
        } catch {
            if sessionID == command.sessionID { lastFailure = "这一句未保存，可重试保存。" }
            throw error
        }
    }

    private var allWindowCaptures: [TranscriptWindowCapture] {
        retiredWindowCaptures + [windowCapture].compactMap { $0 }
    }
    public var pendingSaveRecordIDs: [String] {
        Array(Set(inputPersistence.outstandingRecordIDs + admissionLedger.recordIDs
            + allWindowCaptures.filter { !$0.queue.isComplete || $0.blockedCommand != nil }.map(\.recordID))).sorted()
    }

    public func pendingSaveCommands(recordID: String) -> [TranscriptPersistenceQueue.Command] {
        inputPersistence.unsettledInputs(sessionID: recordID).map(\.command)
            + allWindowCaptures.filter { $0.recordID == recordID }.flatMap(\.recoveryCommands)
    }

    public func saveFailures(recordID: String) -> [TranscriptPersistenceQueue.Failure] {
        inputPersistence.failures(sessionID: recordID) + allWindowCaptures
            .filter { $0.recordID == recordID && ($0.queue.failure != nil || $0.blockedCommand != nil) }
            .flatMap { capture in capture.recoveryCommands.map {
                TranscriptPersistenceQueue.Failure(command: $0, message: "文字尚未保存，可重试保存。")
            } }
    }

    public func waitForPendingSaves(recordID: String) async -> TranscriptPersistenceQueue.DrainReport {
        let captures = allWindowCaptures.filter { $0.recordID == recordID }
        for capture in captures { await capture.queue.waitUntilSettled() }
        let saved = await inputPersistence.waitUntilSettled(sessionID: recordID)
        let combined = TranscriptPersistenceQueue.DrainReport(
            pendingCommands: saved.pendingCommands + captures.flatMap(\.recoveryCommands),
            failures: saveFailures(recordID: recordID),
            admissionRejections: saved.admissionRejections + captures.reduce(0) { $0 + $1.queue.rejectionCount })
        return admissionLedger.report(recordID: recordID, saved: combined)
    }

    @discardableResult
    public func retryPendingSaves(recordID: String) async -> Bool {
        for capture in allWindowCaptures where capture.recordID == recordID { await capture.retryPending() }
        for failure in saveFailures(recordID: recordID) {
            inputPersistence.retry(sessionID: recordID, lineID: failure.command.lineID)
        }
        return await waitForPendingSaves(recordID: recordID).isComplete
    }

    public func unsavedTranscriptText(recordID: String) -> String {
        var text = pendingSaveCommands(recordID: recordID).map(\.text)
        if let rejected = admissionLedger.copyText(recordID: recordID) { text.append(rejected) }
        return text.joined(separator: "\n")
    }

    public func admissionRecovery(recordID: String) -> TranscriptAdmissionRecovery? {
        admissionLedger.recovery(recordID: recordID)
    }

    public var saveRecoveryRecords: [TranscriptSaveRecoveryRecord] {
        pendingSaveRecordIDs.compactMap { id in
            let failures = saveFailures(recordID: id)
            let admission = admissionRecovery(recordID: id)
            guard !failures.isEmpty || admission != nil,
                  let observedAt = failures.first?.command.observedAt ?? admission?.observedAt else { return nil }
            return .init(id: id, observedAt: observedAt, failedCount: failures.count, admission: admission)
        }
    }

    private var resolvingAdmissionRecords: Set<String> = []

    public func endIncompleteRecord(_ snapshot: TranscriptAdmissionRecovery) async -> Bool {
        let id = snapshot.recordID
        guard admissionLedger.recovery(recordID: id) == snapshot,
              resolvingAdmissionRecords.insert(id).inserted else { return false }
        defer { resolvingAdmissionRecords.remove(id) }
        if sessionID == id { await stopCapture() }
        let saved = await inputPersistence.waitUntilSettled(sessionID: id)
        guard saved.isComplete, admissionLedger.recovery(recordID: id) == snapshot else { return false }
        do {
            _ = try await saveTranscriptLine(snapshot.command)
        } catch {
            return false
        }
        guard admissionLedger.recovery(recordID: id) == snapshot else { return false }
        let result = await coordinator.sealSessionReporting(id: id, reason: .interrupted)
        guard case .sealed(recordID: id) = result,
              let record = try? await coordinator.record(id: id),
              record.state == .archived, record.endReason == .interrupted,
              admissionLedger.confirmResolution(snapshot) else { return false }
        pendingAttributions.discard(recordID: id)
        return true
    }

    /// 记录库文件位置。设置页与受阻时的「打开数据目录」读它。
    public var libraryURL: URL { coordinator.libraryURL }

    /// 现在拿着麦克风的是哪一个能力（受阻带着它时给「打开会议转录」那条出口用文案）。
    public var activeOwnerTitle: String {
        if case .occupiedBy(let kind) = blocked { return kind.title }
        return coordinator.occupancy?.kind.title ?? "会话"
    }

    /// 用户当下看得见的那一段（`复制这一段` 复制它）：按当前显示模式优先返回未定稿或最新定稿内容。
    public var currentSegmentText: String? {
        if let row = bandContent.rows.last {
            if let secondary = row.secondaryText, !secondary.isEmpty, secondary != row.primaryText {
                return "\(row.primaryText)\n\(secondary)"
            }
            return row.primaryText
        }
        if let partialText, !partialText.isEmpty { return partialText }
        return lines.last?.text
    }

    // MARK: - 全局入口（`⌘⇧L`）

    /// `⌘⇧L`：空闲时打开并开始，进行中暂停，暂停中继续。
    ///
    /// 结束**不**走这个键：§16.2.3 的 E6 把浮层上的 `✕` 定为字幕闭环唯一的结束点，
    /// 所以这里不提供第二种"结束"。（§5.2 那句"出现或隐藏"更宽松，取更严格的一条，
    /// 已记在 §12.1 的进度表里。）
    public func toggleFromGlobalShortcut() async {
        switch phase {
        case .idle: await openBand()
        case .running: await pause()
        case .paused: await resume()
        case .preparing, .ending: break
        }
    }

    /// 打开浮层。已经在跑就只是再显示一次，不重开会话。
    public func openBand() async {
        if phase.isLive || phase == .preparing {
            setBandVisible(true)
            return
        }
        blocked = nil
        lastFailure = nil
        setBandVisible(true)

        // 别的会话拿着麦克风：**不开第二条会话**，浮层以受阻态出现并给两个出口（§16.3 X1）。
        if let occupancy = coordinator.occupancy, occupancy.kind != .captions,
           case .needsConfirmation = coordinator.decision(for: .captions) {
            blocked = .occupiedBy(occupancy.kind)
            return
        }
        await coordinator.requestStart(.captions)
    }

    /// 用户在窗口拾取器或快捷菜单中选定了新的目标应用（或麦克风）。
    public func selectTarget(_ target: CaptionAudioTarget) async {
        let previous = audioTarget
        audioTarget = target
        switch target {
        case .app:
            placementMode = .dockedToTargetWindow
        case .microphone:
            placementMode = .freeFloatingPinned
        }
        if phase.isLive {
            if previous != target {
                await finish()
                await openBand()
            }
        } else {
            await openBand()
        }
    }

    /// 唤起全屏窗口拾取器让用户选择目标窗口或麦克风。
    public func promptSelectTarget() async {
        guard let picker = presentWindowPicker else { return }
        if let target = await picker() {
            await selectTarget(target)
        }
    }

    /// 隐藏浮层。**这不是结束会话**：字幕继续、记录继续落库。
    public func hideBand() {
        setBandVisible(false)
    }

    /// 浮层受阻时那条「结束会议并启动字幕」的出口：走同一个守卫（§6.4）。
    public func takeOverOccupiedMicrophone() async {
        guard case .occupiedBy = blocked else { return }
        blocked = nil
        await coordinator.requestStart(.captions)
    }

    // MARK: - 生命周期（由协调器的钩子调用）

    /// 协调器拿定占用之后的"真的开始采集"。抛错 = 受阻，协调器会把占用退回去。
    ///
    /// **受阻的原因必须留在这一层**：协调器只负责退回占用与走时，它调 `starter` 时的
    /// 异常不带界面的落点（`SessionCoordinator.requestStart` 只能 `try?`）。所以这里
    /// 先把原因写进 `blocked`，再抛给协调器——浮层要显示的正是这句话（§6.3.1）。
    public func beginCapture() async throws {
        phase = .preparing
        blocked = nil
        lastFailure = nil
        completionRecordID = nil
        completionDiagnosticCode = nil
        translationCoordinator.resetMetrics()
        do {
            guard admissionLedger.canStartNewRecord else {
                throw Blocked(.storeUnavailable("未保存的恢复记录已达到上限，请先复制恢复内容。"))
            }
            try await startPipeline()
        } catch {
            let reason = Self.blockReason(for: error)
            blocked = reason
            // 本地也要退回"没在跑"：采集没起来，界面不能显示成在录。
            // 已经定稿的字幕留着（可读、可复制），受阻态就贴在这一句上面。
            resetToIdleKeepingLines()
            throw Blocked(reason)
        }
    }

    /// 一次完整的启动：读档位 → 起采集 → 连服务 → 建库里的行 → 开始上行。
    ///
    /// 每一步失败都把已经拿到的资源还回去（来源、连接），不留给下一个人收拾；
    /// 库里那一行只在采集与服务都起来之后才建（§5.3.1：不留空记录）。
    private func startPipeline() async throws {
        retiredWindowCaptures.removeAll { $0.queue.isComplete }
        guard allWindowCaptures.filter({ !$0.queue.isComplete }).count < 8 else {
            throw Blocked(.streamFailed("请先保存或保留之前未保存的文字，再开始新一段。"))
        }
        let binding = await realtimeCapabilityBindingProvider?()
        if realtimeCapabilityBindingProvider != nil, binding == nil {
            throw Blocked(.serviceNotReady("当前服务未确认实时语音识别能力，请刷新服务信息后重试。"))
        }
        // 档位是**服务的事实**，不是会话的选择：写进记录的是本次读到的那一个，
        // 读不到写 `unknown`（不为了一个标签去阻塞会话启动）。
        var profile = "unknown"
        if let serviceReadiness {
            switch await serviceReadiness() {
            case .notReady:
                // Readiness can lag operation capability; connection admission
                // and the Realtime handshake provide the actionable result.
                break
            case .ready(let reported):
                profile = reported ?? "unknown"
            }
        }

        let source = makeCurrentAudioSource()
        self.source = source
        let stream: AudioChunkStream
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(Self.blockReason(for: error))
        }

        // 分人在**首个 PCM 之前**协商一次，之后改不了（契约 §Diarization 扩展）。
        // 是否可用的唯一事实来源是服务的能力声明：这里按用户开关原样请求，
        // 不在本地按档位拦截。分人单项不可用时不拦整场：重建一条不带分人的
        // 连接，正文继续，分人记 `unavailable`。
        let diarizationRequested = diarizationPreference()
        var diarizationUnavailableNote: String?

        var windowEnabled = dependencies.revisionWindowEnabled
            ?? defaults.bool(forKey: "speechrail.captionRevisionWindowEnabled")
        windowFallbackNote = nil

        func makeClient(diarizationEnabled: Bool) -> any CaptionRealtimeClient {
            dependencies.makeRealtimeClient(
                CaptionRealtimeClientConfiguration(
                    port: port,
                    scenePreset: .caption,
                    diarizationEnabled: diarizationEnabled,
                    apiKey: apiKey,
                    expectedASRRevision: binding?.asrModelRevision,
                    windowScene: windowEnabled ? .caption : nil,
                    language: sourceLanguage.asrLanguageCode,
                    keywords: glossary.asrKeywords.isEmpty ? nil : glossary.asrKeywords
                )
            )
        }

        var diarizationEnabled = diarizationRequested
        var client = makeClient(diarizationEnabled: diarizationEnabled)
        while true {
            do {
                try await client.connect()
                break
            } catch {
                await client.close()
                let failure = error as? RealtimeASRClient.Failure
                if windowEnabled, failure?.revisionWindowUnavailable == true {
                    windowEnabled = false
                    windowFallbackNote = "当前服务暂不支持回溯修正，已使用标准转写继续记录。"
                } else if diarizationEnabled, failure?.diarizationUnavailableCode != nil {
                    diarizationEnabled = false
                    diarizationUnavailableNote = "这场没有标出谁在说话；正文照常记录。"
                } else {
                    await source.stop()
                    self.source = nil
                    throw Blocked(.serviceNotReady(error.localizedDescription))
                }
                client = makeClient(diarizationEnabled: diarizationEnabled)
            }
        }
        diarizationActive = diarizationEnabled
        self.client = client

        // 记录行在**采集真的起来之后**才建：麦克风没起来、服务连不上，都不该在记录库里
        // 留下一条什么都没有的会话（§5.3.1）。
        let startedAt = Date()
        sessionStartedAt = startedAt
        lines = []
        partialText = nil
        terminalCount = 0
        currentOrdinal = 0
        lineByItem = .init()
        timingQualityApplied = []
        isStoppingIntentionally = false
        do {
            let record = try await coordinator.createSession(
                SessionDraft(
                    kind: .captions,
                    engineProfile: profile,
                    audioSource: audioTarget?.resolvedAudioSource ?? .microphone,
                    diarization: diarizationEnabled ? .active
                        : (diarizationUnavailableNote == nil ? .off : .unavailable),
                    diarizationNote: diarizationUnavailableNote,
                    startedAt: startedAt,
                    targetBundleID: audioTarget?.targetBundleID,
                    targetAppName: audioTarget?.targetAppName
                )
            )
            sessionID = record.id
            labeling.begin(sessionID: record.id, enabled: diarizationEnabled)
            if let diarizationUnavailableNote {
                labeling.markUnavailable(note: diarizationUnavailableNote)
            }
            coordinator.sessionDidStartRecording(id: record.id)
        } catch {
            await client.close()
            await source.stop()
            self.source = nil
            self.client = nil
            throw Blocked(.storeUnavailable(error.localizedDescription))
        }

        phase = .running
        sessionGeneration &+= 1
        let identity = beginPreviewGeneration(captureStartedAt: startedAt)
        beginWindowCapture(enabled: windowEnabled, identity: identity, captureStartedAt: Date())
        startPump(stream: stream, client: client, identity: identity)
    }

    /// 协调器的 stopper：把最后半句交出去、关掉连接。**不封存记录**——那是协调器接下来做的事。
    ///
    /// 唯一要挡的是重入（`:ending` 里还等着最后一句）。其余相位都照做：`idle` 时也把浮层
    /// 收起来——协调器决定"这次会话结束了"，浮层就不该继续挂在屏幕上。
    private var stopCaptureTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var isClosingCaptureTransport = false

    public func stopCapture() async { await beginCaptureStop(preservingRecord: false).value }

    private func beginCaptureStop(preservingRecord: Bool) -> Task<Void, Never> {
        if let stopCaptureTask { return stopCaptureTask }
        let task = Task { @MainActor in
            defer { self.stopCaptureTask = nil }
            await self.performStopCapture(preservingRecord: preservingRecord)
        }
        stopCaptureTask = task
        return task
    }

    private func audioStreamFailed(_ error: any Error, identity: TranscriptPreviewLedger.Identity) {
        guard isCurrent(identity) else { return }
        let failure = (error as? AudioStreamError) ?? AudioStreamError(reason: .sourceLost)
        lastFailure = failure.localizedDescription
        if failure.reason != .sourceLost, let sessionID {
            coordinator.recordCaptureCompletionFailure(recordID: sessionID,
                failure: .init(stage: .capture, message: failure.localizedDescription))
        }
        guard !isStoppingIntentionally, stopCaptureTask == nil else { return }
        _ = beginCaptureStop(preservingRecord: true)
    }

    private func performStopCapture(preservingRecord: Bool) async {
        let deadline = SessionDrainDeadline(timeout: windowCapture == nil ? dependencies.drainTimeout : .seconds(30))
        let endingRecordID = sessionID
        completionRecordID = endingRecordID
        if let endingRecordID {
            coordinator.recordCaptureCompletionDeadline(recordID: endingRecordID, deadline: deadline)
        }
        let endingIdentity = previewIdentity
        let endingWindow = windowCapture
        let endingClient = client
        let endingUploader = uploadPump
        let endingPump = pump
        isClosingCaptureTransport = false
        phase = .ending
        isStoppingIntentionally = true
        await source?.stop()
        source = nil
        // `stop()` closes the source stream but does not retract chunks it has
        // already buffered. Upload those before committing the server-side tail.
        if let endingUploader {
            await deadline.wait(stage: .upload) { await endingUploader.value }
        }
        if let endingClient {
            await deadline.wait(stage: .protocolDrain) {
                do {
                        try await endingClient.drainAndClear(timeout: endingWindow == nil ? .seconds(8) : .seconds(30),
                            beforeAuxiliary: { sample in
                                if let endingWindow { try await endingWindow.waitSaved(through: sample) }
                            })
                    }
                catch {
                    if self.previewIdentity == endingIdentity, self.sessionID == endingRecordID {
                        await self.markDiarizationDrainFailureIfNeeded(error)
                    }
                    throw error
                }
            }
            isClosingCaptureTransport = true
            await deadline.wait(stage: .transportClose, cleanup: true) { await endingClient.close() }
        }
        // The client finishes its event stream on close. Let the event owner
        // persist every buffered final/attribution before retiring this identity.
        if let endingPump {
            await deadline.wait(stage: .receiver) { await endingPump.value }
        }
        if deadline.failure != nil { endingWindow?.retainTail() }
        var complete = deadline.failure == nil
        if let endingRecordID, let failure = deadline.failure {
            coordinator.recordCaptureCompletionFailure(recordID: endingRecordID, failure: failure)
        }
        if let endingRecordID, coordinator.captureCompletionFailure(recordID: endingRecordID) != nil {
            complete = false
        }
        if let endingRecordID {
            let saved = await deadline.wait(stage: .persistence) {
                let report = await self.waitForPendingSaves(recordID: endingRecordID)
                guard report.isComplete else {
                    throw SessionDrainFailure(stage: .persistence, message: "部分文字尚未保存，请重试保存。")
                }
            }
            complete = complete && saved
            if !complete {
                coordinator.discardCaptureCompletionDeadline(recordID: endingRecordID)
                if sessionID == endingRecordID {
                    lastFailure = coordinator.captureCompletionFailure(recordID: endingRecordID)?.message
                        ?? deadline.failure?.message ?? "本场收尾尚未确认完整。"
                }
                if !preservingRecord, coordinator.activeSessionID == endingRecordID, coordinator.occupancy?.kind == .captions {
                    coordinator.abandonOccupancy()
                }
            }
        }
        endingUploader?.cancel()
        endingPump?.cancel()
        if !preservingRecord {
            uploadPump = nil
            pump = nil
            previewIdentity = nil
            client = nil
            diarizationActive = false
            isClosingCaptureTransport = false
            resetToIdleKeepingLines()
            setBandVisible(false)
        } else if previewIdentity == endingIdentity, sessionID == endingRecordID {
            uploadPump = nil
            pump = nil
            previewIdentity = nil
            client = nil
            diarizationActive = false
            isClosingCaptureTransport = false
            isStoppingIntentionally = false
            level = 0; phase = .paused
            blocked = .streamFailed(lastFailure ?? "音频来源已中断，可以重新接上。")
            if coordinator.occupancy?.kind == .captions {
                _ = await coordinator.markInterruption(.sourceLost, atOrdinal: currentOrdinal)
            }
        }
    }

    /// 用户在浮层上按 `✕`：字幕闭环**唯一**的结束点（E6）。结束即保存。
    ///
    /// 它只结束**自己的**会话。占用在别的能力手里时（字幕带正以受阻态贴在屏幕上，
    /// `§16.3` X1 的那一条），`✕` 只把带子收起来——否则"关掉字幕"会把正在录的会议
    /// 推进"整理中"：麦克风的所有权只由守卫（§6.4）交还，不由浮层的关闭键交还。
    public func finish() async {
        translationCoordinator.cancelPartial()
        partialTranslatedText = nil
        lastPartialTranslation = nil
        if let pauseTask {
            await pauseTask.value
        }
        if coordinator.occupancy?.kind == .captions {
            await coordinator.stopCapture(endingWith: .user)
        }
        translationCoordinator.cancelAll()
        blocked = nil
        resetToIdleKeepingLines()
        setBandVisible(false)
    }

    /// 当字幕收尾发生异常或遗留未确认状态时，由用户确认按中断保存并封存记录。
    @discardableResult
    public func finishIncompleteCapture(recordID: String? = nil) async -> Bool {
        let targetID = recordID ?? completionRecordID ?? sessionID
        guard let targetID else { return false }
        if let pauseTask {
            await pauseTask.value
        }
        if sessionID == targetID, phase.isLive {
            await stopCapture()
        }
        let result = await coordinator.sealSessionReporting(id: targetID, reason: .interrupted)
        switch result {
        case .sealed:
            if completionRecordID == targetID {
                completionRecordID = nil
            }
            if sessionID == targetID || phase != .running {
                resetToIdleKeepingLines()
            }
            return true
        default:
            return false
        }
    }

    /// 把"正在跑"的那一套本地状态清掉，**保留已经定稿的字幕**。
    private func resetToIdleKeepingLines() {
        phase = .idle
        level = 0
        partialText = nil
        partialTranslatedText = nil
        lastPartialTranslation = nil
        previewIdentity = nil
        sessionStartedAt = nil
        sessionID = nil
    }

    // MARK: - 暂停 / 继续

    /// 暂停：**停采集、断连接、放设备**（用户裁决：功能离开就释放），会话与记录都留着。
    ///
    /// 暂停**不**写中断账本：它不是"服务丢了"，是用户按的；这一段空档在导出物的时间码上
    /// 本来就是看得见的（`t_start` 跳一段），账本里再写一条反而把"用户按的"和
    /// "真的断了"混成同一种事。
    public func pause() async {
        guard phase == .running else { return }
        if let pauseTask {
            await pauseTask.value
            return
        }
        let task = Task { @MainActor in
            defer { self.pauseTask = nil }
            await self.performPause()
        }
        pauseTask = task
        await task.value
    }

    private func performPause() async {
        guard phase == .running, !isStoppingIntentionally else { return }
        isStoppingIntentionally = true
        defer { isStoppingIntentionally = false }
        await source?.stop()
        source = nil
        await uploadPump?.value
        uploadPump = nil
        if let client {
            do {
                let endingWindow = windowCapture
                try await client.drainAndClear(timeout: endingWindow == nil ? .seconds(8) : .seconds(30),
                    beforeAuxiliary: { sample in
                        if let endingWindow { try await endingWindow.waitSaved(through: sample) }
                    })
            } catch {
                lastFailure = error.localizedDescription
                windowCapture?.retainTail()
                await markDiarizationDrainFailureIfNeeded(error)
                if let sessionID {
                    coordinator.recordCaptureCompletionFailure(recordID: sessionID, failure: .init(
                        stage: .protocolDrain, message: "暂停收尾未确认完整，已保存的文字仍在。"
                    ))
                }
            }
            await client.close()
        }
        await pump?.value
        pump = nil
        client = nil
        previewIdentity = nil
        level = 0
        // 未定稿尾文只作为 partial 恢复材料，不升级为正式行。
        translationCoordinator.cancelPartial()
        partialText = nil
        partialTranslatedText = nil
        lastPartialTranslation = nil
        if phase == .running || phase == .preparing {
            phase = .paused
        }
    }

    public func resume() async {
        guard phase == .paused else { return }
        do {
            try await restartPipeline()
        } catch {
            blocked = Self.blockReason(for: error)
        }
    }

    /// 受阻之后重新接上。判据是**占用还在不在自己手里**，而不是受阻的类型：
    ///
    ///   - 占用仍是 `.captions`（服务忙、中途断线、续接失败）：这不是"再开一次会话"，
    ///     是"把这条断掉的链路接回去"。走 `requestStart` 只会拿到 `.alreadyActive`，
    ///     于是按钮点了没反应、界面还显示成在跑——那是最糟的一种失败。
    ///   - 占用不在自己手里（麦克风未授权、服务未就绪、别人占着）：走守卫重新开始，
    ///     该弹确认就弹确认。**原因在成功之前不清掉**，用户取消后浮层回到原样。
    public func retry() async {
        if coordinator.occupancy?.kind == .captions {
            if coordinator.phase == .interrupted {
                await coordinator.resumeAfterInterruption()
            }
            do {
                try await restartPipeline()
            } catch {
                blocked = Self.blockReason(for: error)
            }
            return
        }
        await coordinator.requestStart(.captions)
    }

    private func restartPipeline() async throws {
        retiredWindowCaptures.removeAll { $0.queue.isComplete }
        guard allWindowCaptures.filter({ !$0.queue.isComplete }).count < 8 else {
            throw Blocked(.streamFailed("请先保存或保留之前未保存的文字，再重新接上。"))
        }
        // 续接是"新 epoch"，不是"再叠一路"：上一次留下的采集件先还回去，
        // 否则旧的引擎会一直被持着（用户裁决：功能离开就释放）。
        await source?.stop()
        source = nil
        let binding = await realtimeCapabilityBindingProvider?()
        if realtimeCapabilityBindingProvider != nil, binding == nil {
            throw Blocked(.serviceNotReady("当前服务未确认实时语音识别能力，请刷新服务信息后重试。"))
        }
        let source = makeCurrentAudioSource()
        self.source = source
        let stream: AudioChunkStream
        do {
            stream = try await source.start()
        } catch {
            self.source = nil
            throw Blocked(Self.blockReason(for: error))
        }
        // 续接是**新连接、新 epoch**（§6.5）：分人在新连接上要重新协商一次，
        // 否则这一段的归属会静默丢掉。
        var windowEnabled = dependencies.revisionWindowEnabled
            ?? defaults.bool(forKey: "speechrail.captionRevisionWindowEnabled")
        windowFallbackNote = nil

        func makeClient(diarizationEnabled: Bool) -> any CaptionRealtimeClient {
            dependencies.makeRealtimeClient(
                CaptionRealtimeClientConfiguration(
                    port: port,
                    scenePreset: .caption,
                    diarizationEnabled: diarizationEnabled,
                    apiKey: apiKey,
                    expectedASRRevision: binding?.asrModelRevision,
                    windowScene: windowEnabled ? .caption : nil,
                    language: sourceLanguage.asrLanguageCode,
                    keywords: glossary.asrKeywords.isEmpty ? nil : glossary.asrKeywords
                )
            )
        }
        let diarizationRequested = diarizationActive
        var diarizationEnabled = diarizationRequested
        var client = makeClient(diarizationEnabled: diarizationEnabled)
        var diarizationUnavailableNote: String?
        while true {
            do {
                try await client.connect()
                break
            } catch {
                await client.close()
                let failure = error as? RealtimeASRClient.Failure
                if windowEnabled, failure?.revisionWindowUnavailable == true {
                    windowEnabled = false
                    windowFallbackNote = "当前服务暂不支持回溯修正，已使用标准转写继续记录。"
                } else if diarizationEnabled, failure?.diarizationUnavailableCode != nil {
                    diarizationEnabled = false
                    diarizationUnavailableNote = "这场没有标出谁在说话；正文照常记录。"
                } else {
                    await source.stop()
                    self.source = nil
                    throw Blocked(.serviceNotReady(error.localizedDescription))
                }
                client = makeClient(diarizationEnabled: diarizationEnabled)
            }
        }
        diarizationActive = diarizationEnabled
        self.client = client
        // Gap3：续接只重置 uid 坐标系，面板上已标出的标签/改名/计数保留。
        // 以前这里不动账本——uid 表残留旧连接的坐标，迟到修订可能串写。
        if let sessionID {
            labeling.beginNewConnection(sessionID: sessionID)
            if let diarizationUnavailableNote {
                labeling.markUnavailable(note: diarizationUnavailableNote)
                await coordinator.updateSessionDiarization(
                    id: sessionID, state: .unavailable, note: diarizationUnavailableNote
                )
            }
        }
        isStoppingIntentionally = false
        blocked = nil
        phase = .running
        let identity = beginPreviewGeneration(captureStartedAt: Date())
        beginWindowCapture(enabled: windowEnabled, identity: identity, captureStartedAt: Date())
        startPump(stream: stream, client: client, identity: identity)
    }

    // MARK: - 采集 → 上行

    private func beginPreviewGeneration(captureStartedAt: Date) -> TranscriptPreviewLedger.Identity {
        nextConnectionID &+= 1
        let identity = TranscriptPreviewLedger.Identity(
            connection: nextConnectionID,
            generation: sessionGeneration
        )
        previewIdentity = identity
        previewLedger.beginGeneration(
            identity: identity,
            captureTimelineOffsetSeconds: captureStartedAt.timeIntervalSince1970
        )
        return identity
    }

    private func startPump(
        stream: AudioChunkStream,
        client: any CaptionRealtimeClient,
        identity: TranscriptPreviewLedger.Identity
    ) {
        uploadPump?.cancel()
        uploadPump = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.isCurrent(identity) else { return }
                    await self.upload(chunk, to: client, identity: identity)
                }
                if !Task.isCancelled { self?.audioStreamFailed(AudioStreamError(reason: .sourceLost), identity: identity) }
            } catch {
                if !(error is CancellationError) { self?.audioStreamFailed(error, identity: identity) }
            }
        }

        pump?.cancel()
        pump = Task { [weak self] in
            let events = await client.events()
            for await envelope in events {
                guard let self, self.isCurrent(identity) else { return }
                await self.handle(envelope, identity: identity)
            }
        }
    }

    private func isCurrent(_ identity: TranscriptPreviewLedger.Identity) -> Bool {
        identity == previewIdentity
    }

    private func upload(
        _ chunk: AudioChunk,
        to client: any CaptionRealtimeClient,
        identity: TranscriptPreviewLedger.Identity
    ) async {
        guard isCurrent(identity) else { return }
        let recordID = sessionID
        level = chunk.level
        do {
            try await client.append(chunk.pcm)
        } catch {
            guard isCurrent(identity) else { return }
            lastFailure = error.localizedDescription
            if let recordID {
                coordinator.recordCaptureCompletionFailure(recordID: recordID, failure: .init(
                    stage: .upload, message: "部分音频未能送达，记录尚未确认完整。"
                ))
            }
        }
    }

    // MARK: - 下行

    private func handle(
        _ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>,
        identity: TranscriptPreviewLedger.Identity
    ) async {
        guard identity == previewIdentity else { return }
        switch envelope.payload {
        case .ready, .configured,
             .ttsStarted(_, _, _), .ttsTextAccepted(_, _, _, _),
             .ttsAudio(_, _, _), .ttsEnded(_, _, _, _, _):
            // 字幕会话不接线 TTS：增量 utterance 属于助手那一层。
            break
        case .diarizationConfigured(let capacity, let serverSessionID):
            if let recordID = sessionID {
                labeling.configureCapacity(capacity, recordID:recordID,
                    generation:identity.generation,serverSessionID:serverSessionID,inputEpoch:0)
            }
        case .transcriptionWindow(let event):
            guard let capture = windowCapture, capture.identity == identity else { return }
            let admission = capture.apply(event, observedAt: Date())
            let text = capture.visibleText
            partialText = text.isEmpty ? nil : text
            if admission == .rejected || capture.queue.rejectionCount > 0 {
                lastFailure = "部分文字尚未保存，已暂停接收新的修订。请保留恢复内容。"
                Task { @MainActor in await self.enterInterrupted(.streamFailed(self.lastFailure ?? "保存队列已满")) }
            }
        case .partial(let itemID, let delta):
            guard windowCapture == nil else { return }
            _ = previewLedger.acceptDelta(
                identity: identity,
                itemID: itemID,
                delta: delta,
                eventID: envelope.metadata.eventID
            )
            partialText = previewLedger.visiblePartial
        case .partialSnapshot(let itemID, let revision, let text, _):
            guard windowCapture == nil else { return }
            _ = previewLedger.acceptSnapshot(
                identity: identity,
                itemID: itemID,
                revision: revision,
                text: text,
                eventID: envelope.metadata.eventID
            )
            partialText = previewLedger.visiblePartial
        case .segmentClosed(let itemID, let sampleSpan, let reason, let commitEventID):
            guard windowCapture == nil else { return }
            guard let closeReason = TranscriptPreviewLedger.SegmentCloseReason(
                rawValue: reason.rawValue
            ) else { return }
            _ = previewLedger.closeSegment(
                identity: identity,
                itemID: itemID,
                sampleSpan: sampleSpan,
                reason: closeReason,
                commitEventID: commitEventID,
                eventID: envelope.metadata.eventID
            )
        case .completed(let itemID, let transcript):
            guard windowCapture == nil else { return }
            terminalCount += 1
            let outcome = previewLedger.resolveCommit(
                identity: identity,
                itemID: itemID,
                transcript: transcript
            )
            partialText = previewLedger.visiblePartial
            guard case .commit(let committed) = outcome else { return }
            await commit(committed)
        case .failed(let itemID, let code, let message):
            guard windowCapture == nil else { return }
            terminalCount += 1
            lastFailure = "\(code)：\(message)"
            let recoveryNote = previewLedger.recoveryNote(
                identity: identity,
                itemID: itemID
            )
            let boundary = previewLedger.boundary(identity: identity, itemID: itemID)
            _ = previewLedger.resolveFailure(identity: identity, itemID: itemID)
            // 预览没有变成正式行：那份草稿不再属于任何一句，别留给下一句继承。
            translationCoordinator.cancelPartial()
            lastPartialTranslation = nil
            partialText = recoveryNote?.text ?? previewLedger.visiblePartial
            if let recoveryNote {
                acceptTranscript(
                    text: recoveryNote.text, itemID: itemID, identity: identity,
                    boundary: boundary, formal: false
                )
            }
        case .attribution(let itemID, let units, _):
            await applyAttribution(itemID: itemID, units: units, identity: identity)
        case .diarizationFinished:
            // 分人收口屏障：drain 已在客户端内等齐，这里无需再记状态。
            break
        case .itemRetired(let itemID):
            let key = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: itemID)
            if let entry = lineByItem.retire(key), let recordID = sessionID { retireLiveLine(recordID: recordID, lineID: entry.lineID) }
        case .alignmentFailed(_, let code, _):
            lastFailure = labeling.recordAlignmentFailure(code: code)
            if diarizationActive, let sessionID, let note = labeling.note {
                await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
            }
        case .auxiliaryIncomplete(_, let alignmentMissing, let diarizationMissing):
            if diarizationMissing, diarizationActive {
                labeling.markDegraded(
                    code: "auxiliary_window_expired",
                    message: "部分说话人归属未能及时到达，正文已经保留。"
                )
                if let sessionID, let note = labeling.note {
                    await coordinator.updateSessionDiarization(
                        id: sessionID,
                        state: .degraded,
                        note: note
                    )
                }
            }
            if labeling.diagnosticCode != nil {
                if let note = labeling.note { lastFailure = note }
            } else if alignmentMissing || diarizationMissing {
                lastFailure = "部分辅助信息未能及时到达，已保留转写内容。"
            }
        case .diarizationDegraded(let code, let message):
            labeling.markDegraded(code: code, message: message)
            if let sessionID, let note = labeling.note {
                await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
            }
        case .serverError(let code, let message, let requestID):
            if phase == .ending, requestID == nil, let sessionID {
                completionDiagnosticCode = code
                coordinator.recordCaptureCompletionFailure(recordID: sessionID, failure: .init(
                    stage: .protocolDrain, message: message
                ))
            }
            if isStoppingIntentionally { lastFailure = message }
            else { await handleServerError(code: code, message: message) }
        case .closed(let code):
            if phase == .ending, let sessionID,
               !isClosingCaptureTransport || (code != nil && code != 1000) {
                coordinator.recordCaptureCompletionFailure(recordID: sessionID, failure: .init(
                    stage: .protocolDrain, message: "识别连接在收尾确认前断开，记录尚未确认完整。"
                ))
            }
            await handleUnexpectedClose(code: code)
        }
    }

    /// 对齐（文本 → 采样区间）与分人（采样区间 → 匿名说话人）随后到达：
    /// 先记住 `segment_uid` → 行，再原位改归属，并补写一次 `timing_quality`。
    /// 正文与时间码一个字不动，也不留新行（§15.3 第 2 条）。
    private func applyAttribution(
        itemID: String,
        units: [RealtimeASRClient.AttributionUnit],
        identity: TranscriptPreviewLedger.Identity
    ) async {
        let itemIdentity = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: itemID)
        guard identity == previewIdentity, !units.isEmpty, let sessionID else { return }
        guard let entry = lineByItem[itemIdentity] else {
            if !pendingAttributions.store(
                units, recordID: sessionID, identity: itemIdentity, labelsEnabled: labeling.isEnabled
            ) {
                lastFailure = "部分说话人信息未能保存，正文继续保留。"
            }
            return
        }
        enqueueAttribution(
            recordID: sessionID, identity: identity, lineID: entry.lineID, ordinal: entry.ordinal,
            units: units, labelsEnabled: labeling.isEnabled
        )
    }

    private func enqueueAttribution(
        recordID: String, identity: TranscriptPreviewLedger.Identity, lineID: String, ordinal: Int,
        units: [RealtimeASRClient.AttributionUnit], labelsEnabled: Bool
    ) {
        let owner: SpeakerLabeling
        if sessionID == recordID, previewIdentity == identity {
            owner = labeling
        } else {
            owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: dependencies.attachTranscriptAttribution)
            owner.begin(sessionID: recordID, enabled: labelsEnabled)
        }
        let command = owner.freezeAttribution(units: units, lineID: lineID)
        let quality = Self.timingQuality(from: units)
        let accepted = inputPersistence.enqueueProjection(
            recordID: recordID, lineID: lineID, unitCount: units.count, coalescing: false
        ) { [weak self, owner] in
            guard let self else { return }
            let confirmedLabels = await owner.apply(command)
            var savedTiming = false
            if let quality, !(self.sessionID == recordID && self.timingQualityApplied.contains(lineID)) {
                do {
                    try await self.coordinator.attachTimingQuality(lineID: lineID, quality: quality)
                    savedTiming = true
                } catch {
                    if self.sessionID == recordID, self.previewIdentity == identity {
                        self.lastFailure = "有一条时间信息未能保存。"
                    }
                }
            }
            guard self.sessionID == recordID, self.previewIdentity == identity else { return }
            if savedTiming { self.timingQualityApplied.insert(lineID) }
            self.transcriptPresentation.update(id: lineID) { updated in
                if confirmedLabels.contains(lineID) {
                    if let saved = owner.attributedLine(forLineID: lineID) {
                        updated.speakerLabel = saved.speakerLabel
                        updated.attributionUnits = saved.attributionUnits
                        updated.speakerLabelIsManual = saved.speakerLabelIsManual
                    }
                }
            }
        }
        if accepted {
            if command.acceptsProjection(for: lineID) {
                owner.register(units: units, lineID: lineID, ordinal: ordinal)
            }
        } else if sessionID == recordID, previewIdentity == identity {
            lastFailure = "部分说话人和时间信息未能保存，正文已保留。"
        }
    }

    /// 定稿即落库；preview ledger 按连接和 item 去重，输入 sample span 冻结时间区间。
    private func commit(_ item: TranscriptPreviewLedger.CommittedItem) async {
        let formal = item.recoveryNote == nil
        let text = (item.recoveryNote?.text ?? item.finalText).trimmingCharacters(in: .whitespacesAndNewlines)
        if formal {
            partialTranslatedText = nil
            partialText = previewLedger.visiblePartial
        } else {
            partialText = text
        }
        if !formal { lastFailure = "有一句话没有拿到定稿正文，正在保留恢复内容。" }
        acceptTranscript(
            text: text, itemID: item.itemID, identity: item.identity,
            boundary: item.boundary, formal: formal
        )
    }

    private func acceptTranscript(
        text: String, itemID: String, identity: TranscriptPreviewLedger.Identity,
        boundary: TranscriptPreviewLedger.Boundary?, formal: Bool
    ) {
        guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }
        let inputTimes = sessionRelativeInputTimes(from: boundary, startedAt: startedAt)
        let command = TranscriptPersistenceQueue.Command(
            sessionID: sessionID, connection: identity.connection, itemID: itemID,
            generation: identity.generation, text: text, source: audioTarget?.lineSource ?? .microphone, role: .speaker,
            tStart: inputTimes?.start, tEnd: inputTimes?.end, formal: formal,
            isInterrupted: false, timingQuality: .unavailable, observedAt: Date()
        )
        switch inputPersistence.enqueue(command) {
        case .accepted, .duplicate: break
        case .capacityExceeded:
            admissionLedger.reject(recordID: sessionID, text: text)
            partialText = text
            lastFailure = "记录正在保存，暂时无法保存这句新内容，请先复制。"
        case .invalidIdentity:
            admissionLedger.reject(recordID: sessionID, text: text)
            partialText = text
            lastFailure = "无法确认这句内容属于哪场记录，请先复制。"
        }
    }

    private func retireLiveLine(recordID: String, lineID: String) {
        let owner = labeling
        let accepted = inputPersistence.enqueueProjection(recordID: recordID, lineID: lineID, unitCount: 0, coalescing: false) { [weak self, owner] in
            owner.retireLine(lineID)
            self?.timingQualityApplied.remove(lineID)
        }
        if !accepted {
            owner.retireLine(lineID); timingQualityApplied.remove(lineID)
            lastFailure = "辅助信息清理积压，已保留正文；请结束后检查记录。"
        }
    }
    var liveTranscriptLookupCount: Int { lineByItem.count }

    private func didSaveTranscript(_ command: TranscriptPersistenceQueue.Command, ordinal: Int) async {
        if sessionID == command.sessionID, !command.formal,
           lastFailure?.contains("正在保留恢复内容") == true {
            lastFailure = "有一句话没有拿到定稿正文，已原样保留恢复内容（不进正式记录）。"
        }
        let identity = TranscriptPreviewLedger.Identity(
            connection: command.connection, generation: command.generation
        )
        let itemIdentity = TranscriptPreviewLedger.ItemIdentity(identity: identity, itemID: command.itemID)
        defer {
            if lineByItem.isRetired(itemIdentity), command.formal {
                retireLiveLine(recordID: command.sessionID, lineID: command.lineID)
            }
        }
        // 行已经在了。对齐/分人结果到达时按 `utterance_id` 找回这一行。
        if sessionID == command.sessionID, command.formal {
            // 只清理“上一句转写失败”这类过期提示；对齐/分人失败的说明仍要留在
            // 页脚，等用户看一眼或倒计时/手动清除，不能被下一句正常保存悄悄抹掉。
            if lastFailure != nil, labeling.diagnosticCode == nil {
                lastFailure = nil
            }
            let mode = effectiveDisplayMode
            // ① 先取前 3 句双语平行历史，并显式排除当前句：若先 apply 再取 suffix，
            //    当前句自己会混进【前文背景】，轻量模型会漏翻或复读。
            let contextLines = Array(
                lines
                    .filter { $0.id != command.lineID }
                    .suffix(3)
                    .map {
                        CaptionContextTurn(
                            sourceText: $0.text,
                            translatedText: $0.translatedText
                        ).formattedPromptLine
                    }
            )
            // ② 定稿瞬间继承未定稿译文，消除「中文 → 外语 → 中文」的视觉断层。
            //    但只在**这一句真的会被翻译**时继承：中文句与「仅原文」档不调模型，
            //    继承上一句的草稿会让这一行先闪出别人的译文，再被 `onFinished(nil)` 抹掉。
            let initialDraftTranslation = Self.inheritableDraftTranslation(
                lastPartialTranslation: lastPartialTranslation?.translatedText,
                lastPartialSourceText: lastPartialTranslation?.sourceText,
                sourceText: command.text,
                displayMode: mode,
                preferredLanguage: sourceLanguage
            )
            lastPartialTranslation = nil
            partialTranslatedText = nil
            let lineID = command.lineID
            let sourceText = command.text
            let willTranslate = Self.shouldTranslate(
                text: sourceText,
                displayMode: mode,
                preferredLanguage: sourceLanguage,
                hasTranslationClient: makeTranslationClient?() != nil
            )

            lineByItem[itemIdentity] = (lineID: lineID, ordinal: ordinal)
            currentOrdinal = max(currentOrdinal, ordinal)
            transcriptPresentation.apply(Line(
                    id: lineID, ordinal: ordinal, text: sourceText,
                    start: command.tStart, end: command.tEnd, speakerLabel: command.speakerLabel,
                    translatedText: initialDraftTranslation,
                    isTranslating: willTranslate
                ))
            if let initialDraftTranslation, !initialDraftTranslation.isEmpty {
                try? await coordinator.attachLineTranslation(
                    lineID: lineID,
                    translatedText: initialDraftTranslation,
                    sourceLanguage: nil
                )
            }

            startStageTwoTranslation(
                lineID: lineID,
                sourceText: sourceText,
                contextLines: contextLines,
                initialDraftTranslation: initialDraftTranslation,
                requestedAt: command.observedAt
            )
        }
        guard let payload = pendingAttributions.take(recordID: command.sessionID, identity: itemIdentity),
              command.formal else { return }
        enqueueAttribution(
            recordID: command.sessionID, identity: identity, lineID: command.lineID, ordinal: ordinal,
            units: payload.units, labelsEnabled: payload.labelsEnabled
        )
    }

    private func startStageTwoTranslation(
        lineID: String,
        sourceText: String,
        contextLines: [String],
        initialDraftTranslation: String?,
        requestedAt: Date
    ) {
        translationCoordinator.translateCompletedLine(
            lineID: lineID,
            sourceText: sourceText,
            contextLines: contextLines,
            displayMode: effectiveDisplayMode,
            preferredLanguage: sourceLanguage,
            priorDraftHint: initialDraftTranslation,
            requestedAt: requestedAt,
            glossary: glossary,
            onStreamingUpdate: { [weak self] id, partialTranslation in
                self?.transcriptPresentation.update(id: id) {
                    $0.translatedText = partialTranslation
                    $0.isTranslating = true
                }
            },
            onFinished: { [weak self] id, finalTranslation, lang in
                guard let self else { return }
                // 终态不许把已经上屏的译文抹掉。Stage 2 在首个字符之前就失败时
                // （没有可用客户端、网络错、首字超时），协调器给不出终稿，而这一行在
                // 定稿瞬间已经继承了预览草稿；退回 nil 等于「中文闪回外语」，
                // 正是铁律 4 与 DoD 要消除的那一片空白。
                let resolvedTranslation = finalTranslation ?? initialDraftTranslation
                self.transcriptPresentation.update(id: id) {
                    if let resolvedTranslation { $0.translatedText = resolvedTranslation }
                    $0.sourceLanguage = lang
                    $0.isTranslating = false
                }
                if resolvedTranslation != nil || !lang.isEmpty {
                    try? await self.coordinator.attachLineTranslation(
                        lineID: id,
                        translatedText: resolvedTranslation,
                        sourceLanguage: lang.isEmpty ? nil : lang
                    )
                }
            }
        )
    }

    /// 用户打开翻译，或在会话中切换排版档 / 源语种时，自动补翻近期尚未翻译的定稿外语行。
    private func retranslateUntranslatedFinalLinesIfNeeded() {
        guard translationEnabled,
              displayMode != .originalOnly,
              sourceLanguage != .chinese,
              makeTranslationClient?() != nil else { return }
        let snapshot = lines
        let recentIDs = Set(snapshot.suffix(6).map(\.id))
        for (index, line) in snapshot.enumerated() where recentIDs.contains(line.id) {
            guard (line.translatedText ?? "").isEmpty, !line.isTranslating else { continue }
            guard Self.shouldTranslate(
                text: line.text,
                displayMode: effectiveDisplayMode,
                preferredLanguage: sourceLanguage,
                hasTranslationClient: true
            ) else { continue }
            let contextLines = Array(
                snapshot[..<index]
                    .suffix(3)
                    .map {
                        CaptionContextTurn(
                            sourceText: $0.text,
                            translatedText: $0.translatedText
                        ).formattedPromptLine
                    }
            )
            transcriptPresentation.update(id: line.id) {
                $0.isTranslating = true
            }
            startStageTwoTranslation(
                lineID: line.id,
                sourceText: line.text,
                contextLines: contextLines,
                initialDraftTranslation: nil,
                requestedAt: Date()
            )
        }
    }

    private func sessionRelativeInputTimes(
        from boundary: TranscriptPreviewLedger.Boundary?,
        startedAt: Date
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard let range = boundary?.inputRange,
              range.isApproximate,
              let absoluteStart = range.startSeconds,
              let absoluteEnd = range.endSeconds
        else { return nil }
        let start = absoluteStart - startedAt.timeIntervalSince1970
        let end = absoluteEnd - startedAt.timeIntervalSince1970
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return (start, end)
    }

    /// 判定一段字幕文本在当前显示模式与源语种设置下是否真的会发起 LLM 翻译。
    static func shouldTranslate(
        text: String,
        displayMode: CaptionDisplayMode,
        preferredLanguage: CaptionSourceLanguage = .auto,
        hasTranslationClient: Bool = true
    ) -> Bool {
        guard displayMode != .originalOnly, hasTranslationClient else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch preferredLanguage {
        case .chinese:
            return false
        case .english, .japanese, .korean:
            return true
        case .auto:
            return !CaptionLanguageDetector.detect(for: trimmed).isChinese
        }
    }

    /// 定稿瞬间可以继承的未定稿草稿。
    ///
    /// 判据与 `CaptionTranslationCoordinator.translateCompletedLine` 的短路条件**必须一致**：
    /// 中文句和「仅原文」档都不进翻译流程，给它们草稿等于把上一句的译文挪到这一行上闪一下。
    /// 不一致时表现为：混说场景里中文定稿先显示外语译文，一个 runloop 后才消失。
    static func inheritableDraftTranslation(
        lastPartialTranslation: String?,
        lastPartialSourceText: String?,
        sourceText: String,
        displayMode: CaptionDisplayMode,
        preferredLanguage: CaptionSourceLanguage = .auto
    ) -> String? {
        guard shouldTranslate(
            text: sourceText,
            displayMode: displayMode,
            preferredLanguage: preferredLanguage,
            hasTranslationClient: true
        ) else { return nil }
        guard let draft = lastPartialTranslation else { return nil }
        // 草稿必须出自这一句的前身。识别会把一句话改到面目全非，所以看的是"够长的公共前缀"
        // 而不是逐字相等；对不上就宁可空着，让精翻从零开始，也不要闪出上一句的译文。
        guard let partialSource = lastPartialSourceText, !partialSource.isEmpty else { return draft }
        // 门槛同时要有一个绝对下限：只按比例算的话，`"So,"` 这类两三字符的短预览会退化成
        // "开头一样就继承"——而短促开头在口播里到处都是，上一句的译文就这样被带到下一句。
        // 代价是短于 4 个字符的预览不再交接，那是"一闪而过"量级，不值得用错句风险去换。
        guard partialSource.count >= 4, sourceText.count >= 4 else { return nil }
        let shorterCount = Swift.min(partialSource.count, sourceText.count)
        let sharedPrefix = partialSource.commonPrefix(with: sourceText).count
        let matchesStrictPrefix = sharedPrefix >= Swift.max(4, shorterCount - 2)
        let matchesLongRevisedPrefix = shorterCount >= 12
            && sharedPrefix >= Swift.max(8, Int(Double(shorterCount) * 0.6))
        guard matchesStrictPrefix || matchesLongRevisedPrefix else { return nil }
        return draft
    }

    /// 分人档位下 `timing_quality` 由归属单元给：有对齐结果就是 `aligned`，
    /// 整 item 退成一个 `unavailable` 单元（契约）时就如实写 `unavailable`。
    /// 没开分人时不写——那一档本来就没有对齐结果，写 `available` 是撒谎。
    private static func timingQuality(
        from units: [RealtimeASRClient.AttributionUnit]
    ) -> SessionTimingQuality? {
        guard !units.isEmpty else { return nil }
        return units.contains { $0.timingQuality == "aligned" } ? .aligned : .unavailable
    }

    private func handleServerError(code: String, message: String) async {
        switch code {
        case "backend_busy":
            // 契约：`backend_busy` 时 session 仍可用，是准入结果而不是坏连接。
            // 但它意味着这一段音频进不去——按中断处理，给"重新接上"的出口（§3 同条结论）。
            await enterInterrupted(.serviceBusy("已有另一个实时转写会话在用语音引擎。等它结束后重新接上。"))
        case "language_not_supported":
            await enterInterrupted(.serviceNotReady("这台 Mac 现在的模型不支持当前语言。"))
        default:
            // 契约里这些失败都**保持 session 可用**：记下来，不打断采集
            // （`voice_not_found` 那种属于助手/TTS，这一档收不到）。
            lastFailure = message
        }
    }

    private func handleUnexpectedClose(code: Int?) async {
        guard !isStoppingIntentionally, phase == .running else { return }
        let reason = code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
        await enterInterrupted(.streamFailed(reason))
    }

    /// 中途断了：停采集、停连接、**写一条中断区间**（不重放 PCM），会话与记录都留着。
    /// 用户点「重新接上」就是新 epoch——序号与水位不重置（§6.5）。
    private func enterInterrupted(_ reason: BlockReason) async {
        await source?.stop()
        windowCapture?.retainTail()
        source = nil
        uploadPump?.cancel()
        uploadPump = nil
        pump?.cancel()
        pump = nil
        previewIdentity = nil
        if let client {
            await client.close()
            self.client = nil
        }
        level = 0
        translationCoordinator.cancelPartial()
        partialText = nil
        partialTranslatedText = nil
        lastPartialTranslation = nil
        if coordinator.occupancy?.kind == .captions {
            _ = await coordinator.markInterruption(.serviceLost, atOrdinal: currentOrdinal)
        }
        blocked = reason
    }

    private func markDiarizationDrainFailureIfNeeded(_ error: Error) async {
        guard diarizationActive,
              let drainError = error as? RealtimeASRClient.Failure,
              drainError == .drainTimedOut(.diarization)
        else { return }
        labeling.markDegraded(
            code: "finalization_timeout",
            message: "说话人编号没能在结束前对齐，正文已经存好了。"
        )
        if let sessionID, let note = labeling.note {
            await coordinator.updateSessionDiarization(id: sessionID, state: .degraded, note: note)
        }
    }

    // MARK: - 浮层上的动作

    /// `导出 SRT…`：走系统保存面板，只读库里的定稿行（§6.2 第三条判断）。
    public func exportSRT() async {
        exportFailure = nil
        guard let sessionID else { return }
        do {
            guard let record = try await coordinator.record(id: sessionID) else {
                exportFailure = "记录不存在，无法导出字幕。"
                return
            }
            let rows = try await coordinator.lines(sessionID: sessionID)
            let names = try await coordinator.speakerNames(sessionID: sessionID)
            try SessionExportPanel.write(
                SessionExportPayload(
                    record: record,
                    lines: rows,
                    speakerNames: names,
                    captionDisplayMode: effectiveDisplayMode
                ),
                as: .srt
            )
        } catch {
            exportFailure = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 小工具

    private func makeCurrentAudioSource() -> AudioChunkSource {
        if let target = audioTarget, let factory = makeAudioSourceForTarget {
            return factory(target)
        }
        return audioSourceFactory()
    }

    private func setBandVisible(_ visible: Bool) {
        isBandVisible = visible
        presentBand?(visible)
    }

    private static func blockReason(for error: Error) -> BlockReason {
        if let failure = error as? MicrophoneCapture.Failure, failure == .permissionDenied {
            return .microphoneDenied
        }
        if let audioBlocked = error as? MeetingAudioBlocked {
            switch audioBlocked.reason {
            case .microphoneDenied:
                return .microphoneDenied
            case .noSourceSelected:
                return .noTargetSelected
            case .systemAudioUnavailable(let message), .engineFailed(let message):
                return .systemAudioUnavailable(message)
            }
        }
        if let blocked = error as? Blocked { return blocked.reason }
        return .serviceNotReady(error.localizedDescription)
    }

    /// 受阻的内部信号：把原因从"真的开始采集"里带出来，交给协调器退回占用。
    struct Blocked: Error {
        var reason: BlockReason

        init(_ reason: BlockReason) {
            self.reason = reason
        }
    }
}
