---
title: "实时字幕模块重构详细工程实施方案（研发执行手册）"
status: approved
audience: "SpeechRail 初级/中级研发工程师、测试工程师、Code Reviewer"
version: "3.0.0"
date: 2026-10-25
---

# 实时字幕模块重构详细工程实施方案（研发执行手册）

> **致研发工程师**：本文档是可直接照单编码的**工程级执行手册（Runbook & Implementation Blueprint）**。文档已基于当前仓库 `SpeechRail 5.0.0` 源码完成逐行对账，明确了每个文件的修改位置、行号、数据结构、完整核心代码模板、SQL 迁移语句、构建系统登记方式以及单元测试验收命令。请严格按 **Task 1 → Task 5** 顺序执行，每完成一个 Task 必须跑通对应的单元测试门禁后再进入下一个 Task。

---

## 1. 重构背景与产品定稿契约

### 1.1 业务目标
将 `SpeechRailApp` 的「实时字幕」模块从“仅绑定麦克风、固定在显示器底部”彻底重构为**「任意本机应用音视频伴侣 + 实时中文字幕/双语字幕」**：
- **典型场景 1**：浏览器（Safari / Chrome / Arc）看无字幕 YouTube / 公开课视频，实时在视频窗口底部展示中文字幕。
- **典型场景 2**：QuickTime Player / IINA / VLC 播放本地无字幕外语或中文视频，实时在播放器窗口底部展示字幕。
- **典型场景 3**：任意语种音频（英、日、韩、法、德、俄、西等 30 语种），自动识别原文并流式翻译为中文字幕。

### 1.2 已锁定的 4 条核心产品裁决（不可偏离）

| 编号 | 决策维度 | 已锁定方案 | 工程实现硬约束 |
| :--- | :--- | :--- | :--- |
| **D1** | **音频采集源** | **本机应用为主 + 麦克风可选** | 默认使用 `SystemAudioCapture`（XPC + `CoreAudioTapCapture`）按目标应用 `bundleID` 抓音；保留 `MicrophoneCapture` 作为备选切换项。 |
| **D2** | **实时中译引擎** | **复用 `LLMProvider` 流式上下文翻译** | 新增 `LLMModule.captions`；中文音频（汉字占比 $\ge 55\%$）0 延迟直通免翻；外语音频走「Partial 节流单飞预览翻 + Completed 携带前 3 句上下文流式精翻」。 |
| **D3** | **字幕带窗口跟随** | **智能吸附 + 自由悬浮切换** | 默认 `.dockedToTargetWindow`（吸附在目标应用窗口底部内侧，随窗口移动/缩放/全屏自动跟随；切到 Obsidian 等其他应用记笔记时保持置顶可见）；用户手动拖动字幕带后自动切为 `.freeFloatingPinned`，工具栏提供「吸附回窗口」按钮一键归位。 |
| **D4** | **目标应用选择交互** | **屏幕窗口拾取器（Window Picker）** | 提供类似 macOS 截图（`⌘⇧4` 后按空格）的全屏鼠标悬停高亮拾取器 + 底部「正在发声/运行的应用图标排 + 麦克风按钮」快捷胶囊栏。 |

---

## 2. 工程师必读：5 条红线与避坑指南（防踩坑清单）

在动手写第一行代码前，所有研发人员必须熟记以下 5 条仓库红线：

1. **红线 1：SPM Target 与 Xcode App Target 的物理隔离**
   - `Package.swift` 中，`SpeechRailAppSupport` 是参与 `swift test` 的核心逻辑库，**不包含** `CaptureHelperClient.swift`（`SystemAudioCapture`）和 `CaptionBandWindow.swift`（它们在 `Package.swift` 的 `exclude` 列表中，只在 Xcode `SpeechRailApp` target 编译）。
   - **做法**：绝对禁止在 `CaptionSession.swift` 中直接写 `SystemAudioCapture(...)` 或引用 `NSPanel`。必须在 `CaptionSession.swift` 中通过协议/闭包（`audioSourceForTarget: @MainActor (CaptionAudioTarget) -> AudioChunkSource`）解耦，并在新增的 App-only 文件 `CaptionSessionProductionWiring.swift` 中注入真实实现。
2. **红线 2：严禁读取 `kCGWindowName`（防止触发屏幕录制 TCC 权限弹窗）**
   - 调用 `CGWindowListCopyWindowInfo` 获取窗口列表时，只允许读取 `kCGWindowNumber`、`kCGWindowOwnerPID`、`kCGWindowBounds`、`kCGWindowLayer`。
   - **绝对禁止读取 `kCGWindowName`**：一旦读取该键或调用截屏 API，macOS 会弹出「屏幕与系统音频录制」高危权限弹窗。应用名称与图标一律通过 `NSRunningApplication(processIdentifier: pid)` 的 `.localizedName` 与 `.icon` 获取。
3. **红线 3：不修改 Python 服务端与 `/v1/realtime` WebSocket 契约**
   - `contracts/realtime-openai.md` 是冻结契约。`RealtimeASRClient` 保持 `language: nil`（服务端 `qwen3_streaming.py` 默认即启用 30 语种 `"auto"` 识别）。
   - 客户端通过 `CaptionLanguageDetector`（Unicode 汉字占比 + `NLLanguageRecognizer`）在本地毫秒级判定识别出的文本是否为中文。
4. **红线 4：`SessionStore.sessionColumns` 列下标偏移保护**
   - 在 `SessionStore.swift:1864` 的 `listSessions` 中，子查询列紧跟在 `Self.sessionColumns` 之后（原先 `sessionColumns` 共 18 列，下标 `0...17`，子查询使用硬编码下标 `18, 19, 20, 21`）。
   - 当我们在 `sessionColumns` 末尾追加 `target_bundle_id, target_app_name`（变成 20 列，下标 `0...19`）时，**必须同步把 `listSessions` 中的子查询读取下标从 `18, 19, 20, 21` 更新为 `20, 21, 22, 23`**！否则会导致会话列表的行数统计与中断状态读错列。
5. **红线 5：视觉常量必须集中注册在 `SpeechRailDesignTokens.swift`**
   - 视图代码中禁止散落裸色值或魔法尺寸常量，所有新增尺寸/颜色语义 Token 先登记到 `SpeechRailDesignTokens.swift`。

---

## 3. 全局架构与数据流图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Xcode App Target (App-Only 视图与硬件接线层)               │
│                                                                              │
│  ┌──────────────────────────────┐      ┌──────────────────────────────────┐  │
│  │ CaptionWindowPicker.swift    │      │ TargetWindowTracker.swift        │  │
│  │ • 全屏非激活悬停高亮拾取器     │      │ • 15Hz 轮询目标 CGWindowID bounds │  │
│  │ • 底部活跃音频应用 + 麦克风栏  │      │ • Quartz(左上) → AppKit(左下)转换 │  │
│  └──────────────┬───────────────┘      └─────────────────┬────────────────┘  │
│                 │ 选定 CaptionAudioTarget                │ 实时目标窗口 NSRect │
│                 ▼                                        ▼                   │
│  ┌────────────────────────────────────┐  ┌────────────────────────────────┐  │
│  │ CaptionSessionProductionWiring     │  │ CaptionBandWindowController    │  │
│  │ •.appWindow -> SystemAudioCapture  │  │ • .dockedToTargetWindow 智能吸附│  │
│  │ •.microphone -> MicrophoneCapture  │  │ • .freeFloatingPinned 拖拽悬浮  │  │
│  └──────────────┬─────────────────────┘  └───────────────▲────────────────┘  │
└─────────────────┼────────────────────────────────────────┼───────────────────┘
                  │ AudioChunkStream (24kHz PCM16)         │ @Observable 状态驱动
┌─────────────────▼────────────────────────────────────────┴───────────────────┐
│              SpeechRailAppSupport Target (SPM 核心业务与单测层)                │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │ CaptionSession.swift                                                   │  │
│  │ • 持有 audioTarget (.appWindow / .microphone) & displayMode            │  │
│  │ • 统一在 didSaveTranscript 汇聚标准流与 windowCapture 定稿行             │  │
│  └──────┬───────────────────────────────────────────────────┬─────────────┘  │
│         │ 原文 partial / completed                           │ 译文持久化      │
│         ▼                                                   ▼                │
│  ┌──────────────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ CaptionTranslator.swift              │  │ SessionStore (Schema v15)    │  │
│  │ • CaptionLanguageDetector (汉字直通)  │  │ • session: +target_bundle_id │  │
│  │ • Partial 500ms 节流单飞预览翻        │  │            +target_app_name  │  │
│  │ • Completed 前 3 句上下文流式精翻      │  │ • line:    +source_language  │  │
│  │ • 调用 LLMProvider.streamTranslation │  │            +translated_text  │  │
│  └──────────────────────────────────────┘  └──────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 逐任务工程实施细则（Step-by-Step Guide）

---

### Task 1：数据库 Schema V15、领域模型与双语导出地基

**目标**：在不触碰 UI 的前提下，完成数据模型、SQLite V15 迁移、归档兼容与双语 SRT 导出，并跑通全部存储单测。

#### Step 1.1：扩展 `SessionDomain.swift`
打开 `macos/SpeechRailApp/SpeechRailApp/SessionDomain.swift`：

1. **新增实时字幕目标与显示模式领域类型**（建议加在 `SessionAudioSource` 定义下方，约第 215 行处）：
```swift
/// 本机应用字幕目标（纯值类型，不含 AppKit NSImage/NSWindow，可安全进入 SPM 单测目标）。
public struct CaptionTargetApp: Hashable, Codable, Sendable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var processID: Int32?
    public var windowID: UInt32?
    public var isPlayingAudio: Bool

    public var id: String { bundleID }

    public init(
        bundleID: String,
        appName: String,
        processID: Int32? = nil,
        windowID: UInt32? = nil,
        isPlayingAudio: Bool = false
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.windowID = windowID
        self.isPlayingAudio = isPlayingAudio
    }
}

/// 实时字幕的采集目标：默认选择本机应用窗口，可选本机麦克风（决策 D1）。
public enum CaptionAudioTarget: Hashable, Codable, Sendable {
    case app(CaptionTargetApp)
    case microphone

    public var resolvedAudioSource: SessionAudioSource {
        switch self {
        case .app: .system
        case .microphone: .microphone
        }
    }

    public var lineSource: SessionLineSource {
        switch self {
        case .app: .system
        case .microphone: .microphone
        }
    }

    public var displayTitle: String {
        switch self {
        case .app(let app): app.appName
        case .microphone: "麦克风"
        }
    }

    public var targetBundleID: String? {
        if case .app(let app) = self { return app.bundleID }
        return nil
    }

    public var targetAppName: String? {
        if case .app(let app) = self { return app.appName }
        return nil
    }
}

/// 字幕显示模式（决策 D2）。
public enum CaptionDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 中外双语上下对照（若源语言本身为中文，自动只渲染单行中文）
    case bilingual
    /// 仅显示中文字幕（外语自动译为中文，译文生成前暂显浅色原文）
    case chineseOnly = "chinese_only"
    /// 仅显示原文（不调用 LLM 翻译）
    case originalOnly = "original_only"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bilingual: "双语对照"
        case .chineseOnly: "仅中文"
        case .originalOnly: "仅原文"
        }
    }
}

/// 字幕浮层与目标窗口的绑定状态（决策 D3）。
public enum CaptionBandPlacementMode: String, Codable, Sendable, Equatable {
    /// 智能吸附在目标应用窗口底部内侧，随窗口移动、缩放、全屏自动跟随
    case dockedToTargetWindow = "docked"
    /// 自由悬浮钉住（用户手动拖拽了字幕带，或当前音频源为麦克风）
    case freeFloatingPinned = "free"
}
```

2. **扩展 `SessionRecord`（约第 2427 行）与 `SessionDraft`（约第 3205 行）**：
   - 在 `SessionRecord` 和 `SessionDraft` 中追加两个可选属性（保持默认值为 `nil`，确保全仓现有调用点无需修改即可编译）：
     ```swift
     public var targetBundleID: String?
     public var targetAppName: String?
     ```
3. **扩展 `TranscriptLine`（约第 2612 行）与 `LineDraft`（约第 3246 行）**：
   - 在 `TranscriptLine` 和 `LineDraft` 中追加两个可选属性（默认值均为 `nil`）：
     ```swift
     public var sourceLanguage: String?
     public var translatedText: String?
     ```

#### Step 1.2：升级 `SessionStoreSchema.swift`（`v14 → v15`）
打开 `macos/SpeechRailApp/SpeechRailApp/SessionStoreSchema.swift`：

1. 在 `schemaV1` 的 `CREATE TABLE session` 末尾（`end_reason TEXT` 之后）补上新库直建列：
   ```sql
   target_bundle_id TEXT,
   target_app_name  TEXT
   ```
2. 在 `schemaV1` 的 `CREATE TABLE line` 末尾补上新库直建列：
   ```sql
   source_language TEXT,
   translated_text TEXT
   ```
3. 新增幂等迁移函数 `migrateV14ToV15()`：
   ```swift
   /// v14 → v15：实时字幕支持绑定目标本机应用与流式中文译文持久化。
   /// 纯加法迁移，老记录保持 NULL。
   func migrateV14ToV15() throws {
       let sessionCols = try tableColumnNames("session")
       if !sessionCols.contains("target_bundle_id") {
           try execute("ALTER TABLE session ADD COLUMN target_bundle_id TEXT;")
       }
       if !sessionCols.contains("target_app_name") {
           try execute("ALTER TABLE session ADD COLUMN target_app_name TEXT;")
       }
       let lineCols = try tableColumnNames("line")
       if !lineCols.contains("source_language") {
           try execute("ALTER TABLE line ADD COLUMN source_language TEXT;")
       }
       if !lineCols.contains("translated_text") {
           try execute("ALTER TABLE line ADD COLUMN translated_text TEXT;")
       }
   }
   ```

#### Step 1.3：更新 `SessionStore.swift`、`SessionStoreArchivePackage.swift` 与 `SessionCoordinator.swift`
打开 `macos/SpeechRailApp/SpeechRailApp/SessionStore.swift`：

1. 将第 71 行 `public static let schemaVersion: Int32 = 14` 改为 `15`。
2. 在 `migrate()` 方法（约第 192 行 `if version < 14 { try migrateV13ToV14() }` 下方）加入：
   ```swift
   if version < 15 { try migrateV14ToV15() }
   ```
3. 更新 `createSession`（约第 205 行），在 `INSERT INTO session` 中加入 `target_bundle_id, target_app_name` 并绑定 `draft.targetBundleID` 与 `draft.targetAppName`。
4. 更新 `insertLine`（约第 286 行），在 `INSERT INTO line` 中加入 `source_language, translated_text` 并绑定 `draft.sourceLanguage` 与 `draft.translatedText`。
5. 新增译文回写方法 `attachLineTranslation`（放在 `attachTimingQuality` 附近，约第 355 行）：
   ```swift
   /// 实时字幕流式翻译完成后，原位补写该行的源语言与中文译文，原文 `text` 与时间码不动。
   @discardableResult
   public func attachLineTranslation(
       lineID: String,
       translatedText: String?,
       sourceLanguage: String?
   ) throws -> TranscriptLine {
       try withStatement(
           "UPDATE line SET translated_text = ?, source_language = COALESCE(?, source_language) WHERE id = ?;"
       ) { statement in
           bind(statement, 1, translatedText)
           bind(statement, 2, sourceLanguage)
           bind(statement, 3, lineID)
           try step(statement)
       }
       guard let saved = try storedLine(id: lineID) else {
           throw SessionStoreError.statementFailed("译文对应的转录行不存在")
       }
       return saved
   }
   ```
6. **【关键防坑点】更新查询列与下标**：
   - 将 `static let sessionColumns`（第 3550 行）更新为：
     ```swift
     static let sessionColumns = """
     id, kind, title, state, created_at, started_at, ended_at, engine_profile, audio_source,
     diarization, diarization_note, llm_endpoint, llm_model, persona_id, persona_title,
     voice_id, voice_name, end_reason, target_bundle_id, target_app_name
     """
     ```
   - 在 `sessionRecord(from statement:)`（第 3556 行）中读取 `columnText(statement, 18)` 作为 `targetBundleID`，`columnText(statement, 19)` 作为 `targetAppName`。
   - **同步更新 `listSessions`（第 1864 行）**：因为 `sessionColumns` 从 18 列变成了 20 列，必须将第 1864–1867 行的子查询列下标从 `18, 19, 20, 21` 改为 **`20, 21, 22, 23`**：
     ```swift
     lineCount: Int(columnInt(statement, 20)),
     speakerCount: Int(columnInt(statement, 21)),
     openInterruption: columnText(statement, 22).map(SessionInterruptionReason.init(reading:)),
     latestMinutesStatus: columnText(statement, 23).flatMap(MinutesStatus.init(rawValue:))
     ```
   - 在 `storedLine`、`lines(sessionID:)`、`linesPage`、`linesRange` 的 `SELECT` 语句末尾追加 `, source_language, translated_text`，并在 `transcriptLine(from statement:)`（第 3586 行）末尾读取：
     ```swift
     sourceLanguage: sqlite3_column_count(statement) > 17 ? columnText(statement, 17) : nil,
     translatedText: sqlite3_column_count(statement) > 18 ? columnText(statement, 18) : nil
     ```
7. 在 `SessionCoordinator.swift` 中新增转发方法：
   ```swift
   @discardableResult
   public func attachLineTranslation(
       lineID: String,
       translatedText: String?,
       sourceLanguage: String?
   ) async throws -> TranscriptLine {
       try await store.attachLineTranslation(
           lineID: lineID,
           translatedText: translatedText,
           sourceLanguage: sourceLanguage
       )
   }
   ```

#### Step 1.4：升级 `SessionExporter.swift` 支持双语 SRT 导出
打开 `macos/SpeechRailApp/SpeechRailApp/SessionExporter.swift`：
- 在 `SessionExportPayload` 中新增 `public var captionDisplayMode: CaptionDisplayMode = .bilingual`。
- 在 `srt(_ payload:)`（第 225 行）中，当 `line.translatedText` 非空时：
  - 若 `captionDisplayMode == .chineseOnly`，输出 `translatedText`；
  - 若 `captionDisplayMode == .originalOnly`，输出原文 `text`；
  - 若 `captionDisplayMode == .bilingual`（默认），输出双行字幕块：`"\(translatedText)\n\(text)"`。
- 在 `markdown(_ payload:)` 的元数据表中，若 `record.targetAppName` 非空，将音频来源渲染为 `"\(record.audioSource.title) · \(appName)"`。

#### Step 1.5：Task 1 验收门禁
运行以下命令确认数据库迁移与导出单测 100% 通过：
```bash
swift test --package-path macos/SpeechRailApp --filter "SessionStore|SessionExporter"
```

---

### Task 2：`LLMModule.captions` 与 `CaptionTranslator` 双阶段流式翻译引擎

**目标**：扩展 `LLMProvider` 支持实时字幕模块配置与轻量流式翻译，并实现零外部依赖的中文直通检测与双阶段（Partial 预览 + Completed 上下文）流式翻译器。

#### Step 2.1：在 `LLMProvider.swift` 中新增 `LLMModule.captions` 与 `streamTranslation`
打开 `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift`：

1. 在 `public enum LLMModule`（第 597 行）中新增 `case captions`：
   ```swift
   public enum LLMModule: String, CaseIterable, Codable, Identifiable, Sendable {
       case assistant
       case minutes
       case captions
       case teleprompter
       case audiobook

       public var id: String { rawValue }

       public var title: String {
           switch self {
           case .assistant: "语音助手"
           case .minutes: "会议纪要"
           case .captions: "实时字幕翻译"
           case .teleprompter: "AI 提词器"
           case .audiobook: "有声书工坊"
           }
       }

       public var detail: String {
           switch self {
           case .assistant: "语音助手与会议中的内心 OS，共用这一类对话能力。"
           case .minutes: "会后长任务，适合结构化输出能力更强的模型。"
           case .captions: "将外语视频或音频实时流式翻译为中文字幕；中文音频自动直通不调用。"
           case .teleprompter: "主动点击才发送原稿，跟读和直播过程中不会调用。"
           case .audiobook: "主动点击分析全书时才发送正文窗口，阅读或听书过程中不会调用。"
           }
       }

       public var requiredOperation: LLMOperation {
           switch self {
           case .minutes, .captions, .teleprompter, .audiobook: .chat
           case .assistant: .responses
           }
       }
   }
   ```
2. 在 `LLMProvider` actor 中新增 `streamTranslation` 方法：
   - 优先使用 `stream()`（Responses 流式）或当端点仅支持 `/chat/completions` 时回退 `completeChatText()`，设置紧凑超时预算（`firstTextTimeout = .seconds(8)`，`stallTimeout = .seconds(5)`，`maxOutputTokens = 256`），保证字幕翻译绝不挂起。

#### Step 2.2：新建 `macos/SpeechRailApp/SpeechRailApp/CaptionTranslator.swift`
创建该文件并加入 `Package.swift` 的 `SpeechRailAppSupport` `sources` 列表及 `project.pbxproj`：

```swift
import Foundation
import NaturalLanguage

/// 实时字幕源语言检测器（纯本地计算，耗时 < 0.1ms，不改变 /v1/realtime 协议契约）。
public enum CaptionLanguageDetector: Sendable {
    public struct DetectionResult: Equatable, Sendable {
        public let languageCode: String
        public let isChinese: Bool
    }

    /// 判定一段识别文本是否已经是中文（免翻译直通）。
    public static func detect(for text: String) -> DetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DetectionResult(languageCode: "und", isChinese: true)
        }

        var cjkCount = 0
        var meaningfulCount = 0
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            meaningfulCount += 1
            // CJK Unified Ideographs + Extension A
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjkCount += 1
            }
        }

        guard meaningfulCount > 0 else {
            return DetectionResult(languageCode: "und", isChinese: true)
        }

        // 注意：日语假名（0x3040...0x30FF）不计入 cjkCount。
        // 若存在平假名/片假名，直接识别为日语（需翻译为中文）。
        let hasKana = trimmed.unicodeScalars.contains {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
        if hasKana {
            return DetectionResult(languageCode: "ja", isChinese: false)
        }

        let cjkRatio = Double(cjkCount) / Double(meaningfulCount)
        if cjkRatio >= 0.55 {
            return DetectionResult(languageCode: "zh", isChinese: true)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let dominant = recognizer.dominantLanguage {
            let raw = dominant.rawValue
            if raw.hasPrefix("zh") {
                return DetectionResult(languageCode: "zh", isChinese: true)
            }
            return DetectionResult(languageCode: raw, isChinese: false)
        }
        return DetectionResult(languageCode: "en", isChinese: false)
    }
}

/// 翻译引擎抽象协议：生产环境注入 `LLMProvider`，单测注入确定性 Fake。
public protocol CaptionTranslationClient: Sendable {
    func translateStream(
        sourceText: String,
        contextLines: [String]
    ) -> AsyncThrowingStream<String, any Error>
}

/// 实时字幕双阶段流式翻译协调器（Stage 1: Partial 节流预览 + Stage 2: Completed 上下文精翻）。
@MainActor
public final class CaptionTranslationCoordinator {
    public static let systemInstructions = """
    你是一个专业的实时视频中文字幕翻译引擎。请将用户输入的【当前句】直接翻译为自然、简练、符合中文母语影视字幕习惯的简体中文。
    硬性规则：
    1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
    2. 参考【前文背景】保持专业术语、人名和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
    3. 若原文已经是通顺的中文，原样输出即可。
    """

    private let makeClient: @MainActor () -> (any CaptionTranslationClient)?
    private let partialDebounce: Duration
    private let minimumPartialDeltaChars: Int

    private var partialTask: Task<Void, Never>?
    private var lastPartialSourceText: String = ""
    private var lastPartialTriggeredAt: ContinuousClock.Instant?
    private var finalTasks: [String: Task<Void, Never>] = [:]

    public init(
        partialDebounce: Duration = .milliseconds(450),
        minimumPartialDeltaChars: Int = 10,
        makeClient: @escaping @MainActor () -> (any CaptionTranslationClient)?
    ) {
        self.partialDebounce = partialDebounce
        self.minimumPartialDeltaChars = minimumPartialDeltaChars
        self.makeClient = makeClient
    }

    public func cancelAll() {
        partialTask?.cancel()
        partialTask = nil
        lastPartialSourceText = ""
        lastPartialTriggeredAt = nil
        for task in finalTasks.values { task.cancel() }
        finalTasks.removeAll()
    }

    /// Stage 1：当外语 partial 增长时，节流触发单飞预览翻译。
    public func schedulePartialTranslation(
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        onUpdate: @escaping @MainActor (String?) -> Void
    ) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, displayMode != .originalOnly else {
            partialTask?.cancel()
            partialTask = nil
            onUpdate(nil)
            return
        }

        let detection = CaptionLanguageDetector.detect(for: trimmed)
        if detection.isChinese {
            partialTask?.cancel()
            partialTask = nil
            onUpdate(nil)
            return
        }

        let charDelta = abs(trimmed.count - lastPartialSourceText.count)
        let endsWithClauseBoundary = trimmed.last.map { ",.;?!，。；？！、".contains($0) } ?? false
        guard charDelta >= minimumPartialDeltaChars || endsWithClauseBoundary else { return }

        guard let client = makeClient() else { return }
        lastPartialSourceText = trimmed
        let debounce = partialDebounce

        partialTask?.cancel()
        partialTask = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                var accumulated = ""
                for try await delta in client.translateStream(sourceText: trimmed, contextLines: contextLines.suffix(2)) {
                    try Task.checkCancellation()
                    accumulated += delta
                    let cleaned = Self.cleanSubtitleOutput(accumulated)
                    if !cleaned.isEmpty {
                        onUpdate(cleaned)
                    }
                }
            } catch {
                // Partial 预览取消或失败静默忽略，不影响定稿翻译。
            }
        }
    }

    /// Stage 2：当句子定稿（completed / sealed）时，取消 partial 预览并携带前 3 句上下文精翻。
    public func translateCompletedLine(
        lineID: String,
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        onStreamingUpdate: @escaping @MainActor (String, String) -> Void,
        onFinished: @escaping @MainActor (String, String?, String) async -> Void
    ) {
        partialTask?.cancel()
        partialTask = nil
        lastPartialSourceText = ""

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detection = CaptionLanguageDetector.detect(for: trimmed)

        // 中文音频或仅原文模式：0 延迟直通，只记录语种标签，不调大模型。
        guard !detection.isChinese, displayMode != .originalOnly else {
            Task { @MainActor in
                await onFinished(lineID, nil, detection.languageCode)
            }
            return
        }

        guard let client = makeClient() else {
            Task { @MainActor in
                await onFinished(lineID, nil, detection.languageCode)
            }
            return
        }

        finalTasks[lineID]?.cancel()
        finalTasks[lineID] = Task { @MainActor [weak self] in
            defer { self?.finalTasks[lineID] = nil }
            do {
                var accumulated = ""
                let stream = client.translateStream(
                    sourceText: trimmed,
                    contextLines: Array(contextLines.suffix(3))
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    accumulated += delta
                    let cleaned = Self.cleanSubtitleOutput(accumulated)
                    if !cleaned.isEmpty {
                        onStreamingUpdate(lineID, cleaned)
                    }
                }
                let finalCleaned = Self.cleanSubtitleOutput(accumulated)
                await onFinished(
                    lineID,
                    finalCleaned.isEmpty ? nil : finalCleaned,
                    detection.languageCode
                )
            } catch {
                // 取消或网络错误时保留已有前缀或原文，不抛溃会话。
            }
        }
    }

    public static func buildUserPrompt(sourceText: String, contextLines: [String]) -> String {
        if contextLines.isEmpty {
            return "【当前句】\n\(sourceText)"
        }
        let contextJoined = contextLines.joined(separator: "\n")
        return "【前文背景（仅供参考语境，切勿翻译）】\n\(contextJoined)\n\n【当前句（请仅将此句译为简练中文字幕）】\n\(sourceText)"
    }

    public static func cleanSubtitleOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["【当前句】", "【译文】", "译文：", "翻译："] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
```

#### Step 2.3：Task 2 验收门禁
新建 `macos/SpeechRailApp/SpeechRailMacControlTests/CaptionTranslatorTests.swift`（并同步登记到 `project.pbxproj` 的 `SpeechRailAppTests` target），覆盖以下 4 个必测用例：
1. `testChineseTextBypassesLLMTranslation`：输入 `"今天我们讨论实时字幕架构"` 及 `"今天讨论 API Design"`，断言 `isChinese == true`，`FakeTranslationClient` 调用次数为 `0`。
2. `testJapaneseWithKanjiIsDetectedAsNonChinese`：输入 `"今日はいい天気ですね"`，断言 `languageCode == "ja"` 且 `isChinese == false`，触发中文翻译。
3. `testPartialTranslationDebouncesAndCancelsStaleInFlight`：连续快速输入 3 次英文 partial，断言只保留最后一次流式结果。
4. `testCompletedLineIncludesUpToThreeContextLines`：验证传入 5 条历史句时，Prompt 中精确携带最近 3 条作为 `【前文背景】`。

运行验证命令：
```bash
python3 scripts/check_macos_test_target_coverage.py
swift test --package-path macos/SpeechRailApp --filter CaptionTranslatorTests
```

---

### Task 3：`CaptionSession` 重构（支持本机应用目标、热切换与双语状态投影）

**目标**：将 `CaptionSession.swift` 从硬编码麦克风升级为可驱动任意本机应用（`CaptionAudioTarget.app`）或麦克风（`.microphone`），支持会话中切换目标应用，并将双阶段中文译文汇聚到 `CaptionBandContent`。

#### Step 3.1：升级 `CaptionSession.swift`
打开 `macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift`：

1. **扩展 `BlockReason`（约第 168 行）**：
   新增两个受阻枚举项以覆盖本机应用抓音与未选目标状态：
   ```swift
   case noTargetSelected
   case systemAudioUnavailable(String)
   ```
   - `title`:
     - `.noTargetSelected`: `"还没有选择要显示字幕的应用窗口"`
     - `.systemAudioUnavailable`: `"应用音频采集未就绪"`
   - `detail`:
     - `.noTargetSelected`: `"点击「选择应用窗口」拾取正在播放视频或音频的窗口，或切换为麦克风收音。"`
     - `.systemAudioUnavailable(let message)`: `"\(message)请在系统设置 → 隐私与安全性 → 录音中允许 SpeechRail，然后重试。"`

2. **扩展 `CaptionSession.Line`（约第 218 行）与 `CaptionBandContent.Row`（约第 82 行）**：
   - 在 `CaptionSession.Line` 中新增：
     ```swift
     public var sourceLanguage: String?
     public var translatedText: String?
     public var isTranslating: Bool = false
     ```
   - 在 `CaptionBandContent.Row` 中新增：
     ```swift
     let primaryText: String      // 主字号显示行（双语/仅中文下为中文译文，无译文时为原文）
     let secondaryText: String?   // 次字号对照行（双语模式下且存在译文时为外语原文）
     let isPartial: Bool
     let isTranslating: Bool
     ```
   - 这种设计让 `CaptionBandView` 和 `CaptionBandMetrics` 完全不需要关心复杂的语言判断，只看 `row.secondaryText` 是否非空即可决定画一行还是画上下双行！

3. **在 `CaptionSession` 中引入目标源管理与翻译协调器**：
   ```swift
   /// 当前选定的字幕音频源（默认 nil，首次开启时引导拾取窗口或使用上次选定的运行中应用）。
   public var audioTarget: CaptionAudioTarget?
   /// 字幕显示模式（双语对照 / 仅中文 / 仅原文），持久化到 UserDefaults。
   public var displayMode: CaptionDisplayMode = .bilingual {
       didSet {
           UserDefaults.standard.set(displayMode.rawValue, forKey: "speechrail.caption.displayMode")
       }
   }
   /// 浮层定位模式（智能吸附目标窗口 / 自由悬浮钉住）。
   public var placementMode: CaptionBandPlacementMode = .dockedToTargetWindow
   /// 外语未定稿句的实时中文预览译文。
   public private(set) var partialTranslatedText: String?
   /// 由 App 层注入：按 CaptionAudioTarget 创建对应的 AudioChunkSource（App -> SystemAudioCapture, Mic -> MicrophoneCapture）。
   public var makeAudioSourceForTarget: (@MainActor (CaptionAudioTarget) -> AudioChunkSource)?
   /// 由 App 层注入：唤起全屏窗口拾取器。
   public var presentWindowPicker: (@MainActor () async -> CaptionAudioTarget?)?
   /// 由 App 层注入：提供翻译客户端（读取 SessionPreferences 中 .captions 模块的 LLM 配置）。
   public var makeTranslationClient: (@MainActor () -> (any CaptionTranslationClient)?)?
   ```

4. **打通 `startPipeline()` 中的动态音源与 `SessionDraft`**：
   - 在 `startPipeline()`（约第 495 行）中：
     - 若 `let target = audioTarget, let factory = makeAudioSourceForTarget`，调用 `factory(target)` 获取 `AudioChunkSource`；否则回退 `audioSourceFactory()`（保持向后兼容既有单测！）。
     - 在 `coordinator.createSession(SessionDraft(...))`（约第 562 行）中，传入：
       ```swift
       audioSource: audioTarget?.resolvedAudioSource ?? .microphone,
       targetBundleID: audioTarget?.targetBundleID,
       targetAppName: audioTarget?.targetAppName,
       ```
     - 在 `beginWindowCapture` 与 `acceptTranscript` 中，将硬编码的 `source: .microphone` 替换为 `audioTarget?.lineSource ?? .microphone`。

5. **支持运行中热切换目标应用（`selectTarget(_ target: CaptionAudioTarget)`）**：
   ```swift
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
   ```

6. **在 `didSaveTranscript` 唯一汇聚点触发定稿翻译**：
   - 在 `didSaveTranscript(_ command: TranscriptPersistenceQueue.Command, ordinal: Int)`（约第 1280 行）中，当 `sessionID == command.sessionID && command.formal` 时：
     - 取当前 `lines.suffix(3).map(\.text)` 作为 `contextLines`；
     - 调用 `translationCoordinator.translateCompletedLine(...)`：
       - `onStreamingUpdate` 回调中调用 `transcriptPresentation.update(id: command.lineID) { $0.translatedText = partialTranslation; $0.isTranslating = true }`；
       - `onFinished` 回调中调用 `coordinator.attachLineTranslation(lineID: command.lineID, translatedText: finalTranslation, sourceLanguage: lang)` 并更新 `isTranslating = false`。

#### Step 3.2：Task 3 验收门禁
运行既有与新增的 `CaptionSessionTests`：
```bash
swift test --package-path macos/SpeechRailApp --filter CaptionSession
```

---

### Task 4：原生窗口拾取器（`CaptionWindowPicker`）、窗口跟随器（`TargetWindowTracker`）与浮层 UI

**目标**：实现零录屏权限弹窗的交互式窗口拾取器、15Hz 智能窗口吸附跟随器、拖拽自由悬浮切换以及双语字幕带视图。

#### Step 4.1：在 `SpeechRailDesignTokens.swift` 注册新增语义 Token
打开 `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`，在 `CaptionBand` 枚举中追加：
```swift
/// 窗口距离目标应用窗口内底边的默认吸附间距（避开播放器底部进度条）。
public static let dockedBottomInset: CGFloat = 36
/// 吸附在目标应用窗口内侧时的左右最小安全留白。
public static let dockedHorizontalMargin: CGFloat = 32
/// 窗口拾取器高亮边框线宽。
public static let windowPickerBorderWidth: CGFloat = 2.5
/// 窗口拾取器高亮圆角。
public static let windowPickerCornerRadius: CGFloat = 12
```

#### Step 4.2：新建 App-Only 文件 `CaptionWindowPicker.swift`
创建 `macos/SpeechRailApp/SpeechRailApp/CaptionWindowPicker.swift`（**注意**：将其文件名加入 `Package.swift` 的 `exclude` 列表，并加入 `project.pbxproj` 的 `SpeechRailApp` target）：

核心实现要点：
1. **`CaptionWindowCatalog.visibleAppWindows(excludingBundleID:)`**：
   - 先调用 `CoreAudioTapCapture.audioProcesses()` 获取当前拥有活跃 CoreAudio 输出流的 `bundleID` 集合 `activeAudioBundleIDs`。
   - 调用 `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`。
   - 遍历字典：仅读取 `kCGWindowLayer == 0`、`kCGWindowOwnerPID`、`kCGWindowNumber`、`kCGWindowBounds`（宽高均 $\ge 200\times 120$，且 `kCGWindowAlpha > 0.05`）。**严禁读取 `kCGWindowName`**。
   - 通过 `NSRunningApplication(processIdentifier: pid)` 过滤掉非 `.regular` 应用与 `SpeechRail` 自身，组装出带 Quartz 坐标与 `isPlayingAudio` 标记的候选窗口列表。
2. **`WindowPickerOverlayController`（全屏鼠标悬停高亮拾取器）**：
   - 为当前屏幕创建无边框透明 `NSPanel`（`styleMask: [.borderless, .nonactivatingPanel]`，`level: .statusBar`，`acceptsMouseMovedEvents = true`）。
   - 监听鼠标移动（`NSTrackingArea`）与 `ESC` 键退出：
     - 鼠标移动时，将 AppKit 鼠标屏幕坐标转换为 Quartz 坐标，在 `visibleAppWindows` 中按 Z-order（数组顺序即为从前到后）找到第一个包含鼠标点的窗口，绘制主题色高亮外框 + 顶部应用胶囊（图标 + 应用名 + `正在播放声音` 徽标 + `点击锁定此窗口`）。
     - 屏幕底部居中常驻一条「快捷选择栏」：展示所有正在发声/运行的 App 图标按钮（方便点选处于后台或最小化的应用）+ **「使用麦克风收音」**按钮 + **「取消 (ESC)」**按钮。

#### Step 4.3：新建 App-Only 文件 `TargetWindowTracker.swift`
创建 `macos/SpeechRailApp/SpeechRailApp/TargetWindowTracker.swift`（同样加入 `Package.swift` 的 `exclude` 列表与 `project.pbxproj` 的 `SpeechRailApp` target）：

核心实现要点：
```swift
import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class TargetWindowTracker {
    public enum TrackingState: Equatable {
        /// 目标窗口在当前屏幕上可见，返回转换后的 AppKit 屏幕坐标矩形及所在 NSScreen
        case visible(frame: NSRect, screen: NSScreen)
        /// 目标窗口已最小化、隐藏或在其他全屏 Space 中
        case offScreen
    }

    private var timer: DispatchSourceTimer?
    private var target: CaptionTargetApp?
    private let onUpdate: @MainActor (TrackingState) -> Void

    public init(onUpdate: @escaping @MainActor (TrackingState) -> Void) {
        self.onUpdate = onUpdate
    }

    public func startTracking(target: CaptionTargetApp) {
        self.target = target
        stopTimer()
        pollOnce()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(66), repeating: .milliseconds(66), leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pollOnce() }
        }
        timer = source
        source.resume()
    }

    public func stopTracking() {
        target = nil
        stopTimer()
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func pollOnce() {
        guard let target else { return }
        guard let resolved = Self.resolveAppKitFrame(for: target) else {
            onUpdate(.offScreen)
            return
        }
        onUpdate(.visible(frame: resolved.frame, screen: resolved.screen))
    }

    /// 将 CGWindowList 的 Quartz 坐标（主屏左上角原点）无损转换为 AppKit 屏幕坐标（主屏左下角原点）。
    public static func quartzToAppKit(_ quartzRect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: quartzRect.origin.x,
            y: primaryScreenHeight - (quartzRect.origin.y + quartzRect.size.height),
            width: quartzRect.size.width,
            height: quartzRect.size.height
        )
    }

    /// 根据目标 windowID（优先）或 bundleID（回退最大在屏标准窗口）解析当前窗口矩形。
    public static func resolveAppKitFrame(for target: CaptionTargetApp) -> (frame: NSRect, screen: NSScreen)? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let matchingPIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID)
                .map(\.processIdentifier)
        )
        guard !matchingPIDs.isEmpty else { return nil }

        var fallbackCandidate: CGRect?
        for entry in infoList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, matchingPIDs.contains(pid),
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 200, bounds.height >= 120
            else { continue }

            if let expectedWindowID = target.windowID,
               let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
               windowNumber == expectedWindowID {
                let appKitRect = quartzToAppKit(bounds, primaryScreenHeight: primaryHeight)
                let screen = NSScreen.screens.first { $0.frame.intersects(appKitRect) } ?? NSScreen.main ?? NSScreen.screens[0]
                return (appKitRect, screen)
            }
            if fallbackCandidate == nil || (bounds.width * bounds.height) > (fallbackCandidate!.width * fallbackCandidate!.height) {
                fallbackCandidate = bounds
            }
        }

        guard let bestBounds = fallbackCandidate else { return nil }
        let appKitRect = quartzToAppKit(bestBounds, primaryScreenHeight: primaryHeight)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitRect) } ?? NSScreen.main ?? NSScreen.screens[0]
        return (appKitRect, screen)
    }
}
```

#### Step 4.4：升级 `CaptionBandWindow.swift`（智能吸附 + 自由悬浮 + 双语渲染）
打开 `macos/SpeechRailApp/SpeechRailApp/CaptionBandWindow.swift`：

1. **升级 `CaptionBandMetrics`**：
   - 在计算每行视觉行数时，若 `row.secondaryText` 非空（即双语对照模式下同时有外语原文与中文译文），总高度 = `visualRowCount(for: secondaryText, style: .callout)` 的行高 + `visualRowCount(for: primaryText, fontSize: fontSize)` 的行高。
2. **在 `CaptionBandWindowController` 中集成 `TargetWindowTracker`**：
   - 增加 `private var isProgrammaticFrameUpdate = false`。
   - 当 `session.placementMode == .dockedToTargetWindow` 且 `session.audioTarget` 为 `.app(let targetApp)` 时，启动 `tracker.startTracking(target: targetApp)`：
     - 收到 `.visible(let windowFrame, let screen)` 时：
       ```swift
       let width = min(
           max(windowFrame.width - 2 * SpeechRailDesignTokens.CaptionBand.dockedHorizontalMargin,
               SpeechRailDesignTokens.Layout.captionBandMinimumWidth),
           SpeechRailDesignTokens.Layout.captionBandMaximumWidth
       )
       let height = CaptionBandMetrics.height(metrics)
       let originX = windowFrame.midX - width / 2
       let originY = max(screen.visibleFrame.minY + 12, windowFrame.minY + SpeechRailDesignTokens.CaptionBand.dockedBottomInset)
       let targetFrame = NSRect(x: originX, y: originY, width: width, height: height)
       isProgrammaticFrameUpdate = true
       panel.setFrame(targetFrame, display: true)
       isProgrammaticFrameUpdate = false
       ```
     - 当用户在界面上直接按住背景拖动面板触发 `windowDidMove` 时，若 `!isProgrammaticFrameUpdate && panel.isVisible`，自动将 `session.placementMode = .freeFloatingPinned` 并调用 `remember(panel)`。
3. **升级 `CaptionBandView` 工具条与字幕行**：
   - 悬停工具条左侧增加**「目标应用胶囊」**（显示当前捕获的 App 名字或麦克风，点击可重新唤起窗口拾取器或快速切换运行中应用）；
   - 增加**「显示模式菜单」**（`双语对照` / `仅中文` / `仅原文`）；
   - 当 `session.placementMode == .freeFloatingPinned` 且当前目标为应用窗口时，工具条显示**「吸附回窗口」**按钮（图标 `macwindow`），点击即设回 `.dockedToTargetWindow` 并立即归位。

#### Step 4.5：新建 `CaptionSessionProductionWiring.swift` 并更新 `App.swift` 与 `SessionSurfaceViews.swift`
1. 新建 `macos/SpeechRailApp/SpeechRailApp/CaptionSessionProductionWiring.swift`（加入 `Package.swift` `exclude` 及 `project.pbxproj` `SpeechRailApp` target）：
   - 将 `SystemAudioCapture`、`MicrophoneCapture`、`WindowPickerOverlayController`、`LLMProvider` 装配到 `CaptionSession`。
2. 在 `SessionSurfaceViews.swift`（第 520 行 `captionsIdleState`）中：
   - 将首屏引导从“只靠麦克风”升级为：**「选择任意应用窗口，实时生成中文字幕」**，提供主按钮「选择应用窗口」与下方「正在运行的应用快捷列表 + 麦克风收音选项」。

---

### Task 5：工程清单同步与全量验证门禁

1. **同步 `Package.swift` 与 `SpeechRailApp.xcodeproj/project.pbxproj`**：
   - `CaptionTranslator.swift` → 加入 `Package.swift` `SpeechRailAppSupport` `sources`，同时加入 `project.pbxproj` 的 `SpeechRailApp` 与 `SpeechRailAppTests` 编译阶段。
   - `CaptionWindowPicker.swift`、`TargetWindowTracker.swift`、`CaptionSessionProductionWiring.swift` → 加入 `Package.swift` `SpeechRailAppSupport` `exclude`，同时加入 `project.pbxproj` 的 `SpeechRailApp` 编译阶段。
   - `CaptionTranslatorTests.swift` → 加入 `SpeechRailMacControlTests/` 目录，并登记进 `project.pbxproj` 的 `SpeechRailAppTests` 编译阶段。

2. **按顺序执行 3 道自动化验收门禁**：
   ```bash
   # 门禁 1：校验 Xcode 与 SPM 测试目标清单零漂移
   python3 scripts/check_macos_test_target_coverage.py

   # 门禁 2：运行新增的实时字幕翻译器、存储 V15、会话与导出测试
   swift test --package-path macos/SpeechRailApp --filter "CaptionTranslatorTests|CaptionSession|SessionStore|SessionExporter"

   # 门禁 3：验证 Git diff 格式整洁无空白错误
   git diff --check
   ```

---

## 5. 交付验收清单（Definition of Done）

研发团队在提交 PR 前须逐项勾对以下验收项：

- [ ] **权限合规**：使用窗口拾取器选择 Chrome / Safari / QuickTime 窗口并开启实时字幕时，只请求“系统录音权限”（`NSAudioCaptureUsageDescription`），**绝不弹出“屏幕录制”或“辅助功能（无障碍）”权限请求**。
- [ ] **窗口跟随与跨应用记笔记**：移动或缩放 QuickTime / 浏览器窗口时，字幕带以 15Hz 丝滑吸附在目标窗口内底部；切到 Obsidian 记笔记时字幕带依然保持在视频窗口底部可见；手动拖动字幕带后自动定格为自由悬浮，点击「吸附回窗口」可一键归位。
- [ ] **任意语种 → 实时中文字幕**：
  - 播放中文视频时，`CaptionLanguageDetector` 判定为中文，0 延迟直接显示中文字幕，不产生任何 LLM 请求；
  - 播放英/日/韩等外语无字幕视频时，长句说话过程中有 Partial 预览中文字幕，断句后基于前 3 句上下文流式更新精准中文译文并写入 SQLite。
- [ ] **双语导出**：点击「导出 SRT…」导出的 `.srt` 文件包含准确的中文译文与原文双语对照时间轴。
- [ ] **自动化门禁**：`check_macos_test_target_coverage.py` 与 `swift test` 全部绿色通过。
