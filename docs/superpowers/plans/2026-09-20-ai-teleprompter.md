# AI Teleprompter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SpeechRail macOS App 中交付一个面向直播、演讲和录制场景的 AI 提词器：用户在独立舞台窗口中可见，直播软件通过摄像头/目标窗口采集时不包含提词内容；AI 只在准备阶段整理稿件，运行时由现有 ASR 和确定性匹配驱动跟读。

**Architecture:** 新增客户端 `Teleprompter` 领域、稿件存储、一次性 AI 分析、实时会话和独立舞台窗口。它复用 `SessionCoordinator` 的设备占用、`MicrophoneCapture` 的实时 PCM 约束和 `RealtimeASRClient` 的 ASR 子集，但不复用 `SessionStore` 的转录记录，也不修改 Python 服务协议。新增 UI 只消费 `SpeechRailDesignTokens`、macOS 语义颜色/字体和现有 session surface 组件。

**Tech Stack:** Swift 6 / SwiftUI / AppKit，macOS 26.0 App target，现有 `LLMProvider` Responses-compatible client，`Codable` 原子文件存储，XCTest 确定性测试，现有 Xcode project 与 SwiftPM `SpeechRailAppSupport` test target。

**Spec:** [`docs/superpowers/specs/2026-09-20-ai-teleprompter-design.md`](../specs/2026-09-20-ai-teleprompter-design.md)（v0.2.0，2026-09-20）。

## Global Constraints

- 只在独立 worktree `/Users/hrygo/.codex/worktrees/ai-teleprompter/SpeechRail` 的 `feat/ai-teleprompter` 分支修改；不得触碰主 worktree 的未提交改动。
- 保留当前 `SessionDesignSurface.swift` 及其他并行改动；不得整文件覆盖或用旧版本替换它们。
- 不新增 Python 路由、OpenAPI 字段、Realtime 事件、worker、TTS、摄像头、推流或录制能力。
- 麦克风只在用户点击“开始跟读”后获取；停止、异常、窗口关闭、应用退出准备路径均释放音频源、ASR 连接和会话租约；PCM、视频、完整 prompt、完整 transcript、API Key 不落盘或写日志。
- 提词运行调用 `SessionCoordinator`，但传入 `nil` 持久化 session ID；`SessionStore` 不新增提词转录记录，`TeleprompterStore` 只保存稿件、活动版本和最后段落。
- `partial` ASR 只更新预览，不推进段落；只有 completed 文本经过顺序、最低置信度和迟滞判定后才允许最多推进一段；低置信度停留并进入 `uncertain`，不得自动回退或跨越多个未确认段落。
- v1 不注册新的全局 Carbon 快捷键；舞台窗口内实现 `Space`、`←`、`→`、`R`、`Esc`，并提供按钮和 VoiceOver 标签。
- 新增 UI 的颜色、间距、圆角、字体、尺寸、表面和动效必须来自 `SpeechRailDesignTokens.swift`、既有 token modifier 或 macOS 系统语义值。需要的新值先扩展 token，再由视图消费；禁止在新增功能文件中使用十六进制/`Color(red:green:blue:)`、重复 `.cornerRadius(...)`、局部任意字号或固定阴影。
- 项目规则禁止未经当前用户逐次授权的自动化测试、UI 自动化、构建、smoke、benchmark 和完整 gate。本计划列出验证命令，但实施阶段默认只写测试并做静态检查；执行这些命令前先取得该授权。

## Review Focus

- `SessionCoordinator` 的非持久化占用路径是否仍能保证单一麦克风租约、busy 拒绝、失败回收和现有 assistant/meeting/captions 行为不变。
- AI 结构化结果是否严格校验 `teleprompter.analysis.v1`、可追溯到原稿，失败是否始终保留原稿并可手动提词。
- 对齐器是否满足 partial 不推进、只向前一段、重复不回退、手动接管清空旧匹配窗口和低置信度停留。
- 舞台窗口的窗口层级、跨空间、非激活和屏幕共享排除是否被表述为防护而非绝对安全保证；直播安全提示是否在开始前可见。
- 所有视觉值是否经过 `SpeechRailDesignTokens` 审查；新增 UI 是否支持浅色/深色、增加对比度、动态字体、VoiceOver 和 Reduce Motion。
- Xcode target、SwiftPM source list 和独立测试文件是否同步，且不把 AppKit/SwiftUI runtime 文件错误加入 `SpeechRailAppSupport`。

---

## Task 1: 建立领域值类型、确定性分段和跟读匹配（先写失败测试）

**Files:**

- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterDomain.swift`。
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterNormalizer.swift`。
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterSegmenter.swift`。
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift`。
- Create `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterNormalizerTests.swift`。
- Create `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterAlignerTests.swift`。
- Modify `macos/SpeechRailApp/Package.swift` to add the four Foundation-only files to `SpeechRailAppSupport.sources`.
- Modify `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` to add source/test file references and build entries.

**Public interfaces:**

```swift
public struct TeleprompterSourceRange: Codable, Equatable, Sendable {
    public let start: Int       // UTF-16 offset, inclusive
    public let end: Int         // UTF-16 offset, exclusive
}

public enum TeleprompterAnalysisSource: String, Codable, Sendable {
    case ai, deterministic, user
}

public enum TeleprompterPauseHint: String, Codable, Sendable {
    case short, medium, long
}

public struct TeleprompterSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let sourceRange: TeleprompterSourceRange
    public var text: String
    public var keywords: [String]
    public var matchPhrases: [String]
    public var pauseHint: TeleprompterPauseHint
}

public struct TeleprompterVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let sourceText: String
    public let segments: [TeleprompterSegment]
    public let analysisSource: TeleprompterAnalysisSource
    public let createdAt: Date
}

public struct TeleprompterDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var sourceText: String
    public var activeVersionID: String?
    public let createdAt: Date
    public var updatedAt: Date
}

public enum TeleprompterRunMode: String, Codable, Sendable {
    case following, paused, manual
}

public struct TeleprompterRunState: Codable, Equatable, Sendable {
    public let documentID: String
    public let versionID: String
    public var currentSegmentID: String?
    public var mode: TeleprompterRunMode
    public var lastUpdatedAt: Date
}

public enum TeleprompterAlignmentDecision: Equatable, Sendable {
    case stay(confidence: Double)
    case advance(to: Int, confidence: Double)
    case uncertain(candidate: Int?, confidence: Double)
}

public struct TeleprompterAlignmentResult: Equatable, Sendable {
    public let decision: TeleprompterAlignmentDecision
    public let matchedTokens: [String]
}

public struct TeleprompterAligner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumConfidence: Double = 0.72
        public var advanceMargin: Double = 0.12
        public var lookahead: Int = 2
    }

    public init(configuration: Configuration = .init())
    public func evaluate(completedTranscript: String, segments: [TeleprompterSegment], currentIndex: Int) -> TeleprompterAlignmentResult
}
```

**Implementation steps:**

- [ ] Write XCTest cases for Unicode punctuation/whitespace, common Chinese/English filler words, mixed-language tokenization, paragraph/sentence fallback segmentation, empty input and UTF-16 source ranges.
- [ ] Write alignment tests for current-segment stay, one-step advance, omitted short phrase, match phrase, repeated previous segment (no backward move), lookahead gap (no multi-step jump), low confidence (`uncertain`) and insufficient margin (`uncertain`).
- [ ] Implement `TeleprompterNormalizer` with Unicode normalization, punctuation/whitespace folding, lowercasing for Latin text, and a fixed filler-word set; do not call any network or model.
- [ ] Implement `TeleprompterSegmenter` with paragraph-first splitting, sentence punctuation fallback, bounded long-segment splitting, stable ordinal IDs, and ranges back to the source text. Empty/whitespace-only text returns an empty list and a typed validation error at the caller boundary.
- [ ] Implement `TeleprompterAligner` as a pure scorer over the current segment plus `lookahead` candidates. Candidate score combines normalized sequence coverage, keyword coverage and match-phrase coverage; it must not inspect segments before `currentIndex`, and it returns at most `currentIndex + 1` as an advance target.
- [ ] Keep all thresholds in `TeleprompterAligner.Configuration`; no UI copy or model name may determine a threshold.
- [ ] Add the files to the package/Xcode source maps without adding AppKit or SwiftUI imports.

**Expected test shape:**

```swift
func testPartialTranscriptDoesNotAdvance() {
    let result = aligner.evaluate(completedTranscript: "第一段", segments: segments, currentIndex: 0)
    XCTAssertEqual(result.decision, .stay(confidence: result.confidence))
}

func testLowConfidenceStaysOnCurrentSegment() {
    let result = aligner.evaluate(completedTranscript: "完全无关的话", segments: segments, currentIndex: 0)
    guard case .uncertain(let candidate, _) = result.decision else { return XCTFail() }
    XCTAssertNil(candidate)
}
```

The production session will call this only for completed events; the test name above documents the boundary, while the runtime event reducer in Task 3 enforces that partial events never invoke `evaluate`.

## Task 2: Implement versioned AI analysis, deterministic fallback and local稿件存储

**Files:**

- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterAnalysis.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterAIClient.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterStore.swift`.
- Create `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterAnalysisTests.swift`.
- Create `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStoreTests.swift`.
- Modify `macos/SpeechRailApp/Package.swift` and the Xcode project source maps for the new Foundation-only files/tests.

**Interfaces and invariants:**

```swift
public struct TeleprompterAnalysisRequest: Sendable {
    public let sourceText: String
    public let language: String?
    public let style: String?
}

public struct TeleprompterAnalysis: Codable, Equatable, Sendable {
    public static let schemaVersion = "teleprompter.analysis.v1"
    public let schemaVersion: String
    public let segments: [TeleprompterSegment]
}

public struct TeleprompterAnalysisDecoder: Sendable {
    public func decode(_ json: String, sourceText: String) throws -> TeleprompterAnalysis
}

public struct TeleprompterAIClient: Sendable {
    public typealias Completion = @Sendable (String) async throws -> String
    public init(completion: @escaping Completion)
    public func analyze(_ request: TeleprompterAnalysisRequest) async throws -> TeleprompterAnalysis
}

public struct TeleprompterDocumentBundle: Codable, Equatable, Sendable {
    public var document: TeleprompterDocument
    public var versions: [TeleprompterVersion]
    public var runState: TeleprompterRunState?
}

@MainActor
public final class TeleprompterStore {
    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws
    public func listDocuments() throws -> [TeleprompterDocument]
    public func loadBundle(documentID: String) throws -> TeleprompterDocumentBundle
    public func saveBundle(_ bundle: TeleprompterDocumentBundle) throws
    public func updateRunState(_ state: TeleprompterRunState) throws
    public func exportMarkdown(_ bundle: TeleprompterDocumentBundle) -> String
}
```

**Implementation steps:**

- [ ] Add decoder tests for the exact `schema_version`, valid ordered ranges, unknown fields, missing required fields, invalid range, overlapping segments, non-contiguous text, invalid `pause_hint`, and empty segments. Unknown JSON fields are ignored; malformed/unsafe required structure throws a typed error.
- [ ] Add AI client tests with an injected completion closure: valid JSON returns an analysis, invalid JSON throws without replacing source text, prompt contains only user-submitted text/preferences and the schema contract, and no API key or endpoint credential is part of the prompt.
- [ ] Build the production completion closure in the session layer from the existing `LLMProvider`/`LLMConfiguration`/Keychain path; set `store=false` through the existing provider behavior, request JSON, and map provider errors to a user-facing “AI 整理不可用” state without logging raw response or full prompt.
- [ ] Implement deterministic fallback from `TeleprompterSegmenter`; fallback versions are tagged `.deterministic` and can be activated without AI configuration.
- [ ] Store one JSON bundle per document under Application Support `SpeechRail/Teleprompter/documents/<document-id>.json`; create directories lazily, write a sibling temporary file, then atomically replace the destination. A failed write leaves the previous bundle intact.
- [ ] Add store tests using an injected temporary directory: create/load/list, active version update, run-state update, corrupt-file error, atomic replacement behavior, and Markdown/plain-text export without internal fields.
- [ ] Ensure store writes contain no PCM, transcript event stream, API key, LLM endpoint secret, or diagnostics payload.

## Task 3: Add non-persistent session ownership and the realtime follow reducer

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailApp/SessionDomain.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/SessionCoordinator.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterFollowController.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift`.
- Create `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterFollowControllerTests.swift`.
- Modify known exhaustive consumers: `SessionSurfaceViews.swift`, `SessionExporter.swift`, `ControlMenuView.swift`, and `App.swift` session starter/stopper switches.
- Modify SwiftPM/Xcode source maps for pure follow controller/test and App target files.

**Session ownership decision:**

- Add `SessionKind.teleprompter` with title `AI 提词器`, short title `AI 提词器`, system image `text.bubble`, and persistence policy `.ephemeral`.
- Change `SessionCoordinator.sessionDidStartRecording(id:)` to accept an optional ID with the existing persistent call sites unchanged. For teleprompter, call `sessionDidStartRecording(id: nil)` after the first successful realtime connection; the coordinator still enters `.recording`, owns the device lease and reports occupancy, but `finalize()` skips `SessionStore` writes when the ID is `nil`.
- Add a dedicated failure/cancel path for a `.preparing` teleprompter run that releases the lease without creating an `activeSessionID`; do not fake a `SessionRecord` or reuse captions semantics.
- Keep all existing persistent assistant/meeting/captions paths behaviorally unchanged and add regression assertions for the persistence policy decision.

**Follow reducer interface:**

```swift
public struct TeleprompterFollowController: Sendable {
    public private(set) var currentIndex: Int
    public private(set) var mode: TeleprompterRunMode
    public private(set) var uncertainty: Double?

    public init(currentIndex: Int = 0, mode: TeleprompterRunMode = .following)
    public mutating func receivePartial(_ text: String)
    public mutating func receiveCompleted(_ text: String, segments: [TeleprompterSegment], aligner: TeleprompterAligner)
    public mutating func pause()
    public mutating func resume()
    public mutating func move(to index: Int, segmentCount: Int)
    public mutating func resetFollowWindow()
}
```

**TeleprompterSession behavior:**

- [ ] Add `@MainActor @Observable TeleprompterSession` with phases `draft`, `analyzing`, `review`, `ready`, `preparing`, `following`, `paused`, `uncertain`, `manual`, `ended`, plus current bundle/version, current segment, partial preview, readiness/error message and stage settings.
- [ ] Expose `createDocument`, `importText`, `updateSourceText`, `analyzeDraft`, `useDeterministicFallback`, `acceptAnalysis`, `openStage`, `beginFollowing`, `pauseFollowing`, `resumeFollowing`, `moveToPrevious`, `moveToNext`, `resetFollow`, and `endFollowing`.
- [ ] `beginFollowing` validates an active version, calls `SessionCoordinator.begin(.teleprompter)`, then starts the existing `MicrophoneCapture`/`AudioChunkSource` and `RealtimeASRClient`; a failure at any point calls the coordinator’s preparing-cancel path and returns to `.manual` without a stored run.
- [ ] Consume realtime events through an internal task. `partial` updates preview only; `committed`/completed segment text goes to `TeleprompterFollowController`; `failed`/disconnect transitions to `.manual` or `.ended` according to whether the user can continue manually.
- [ ] Use the existing ASR client and microphone format; do not add TTS playback, output nodes, camera access, system audio tap, or a new audio route.
- [ ] On pause/manual movement, increment a follow-window epoch, clear pending completed text, and persist only the current segment/mode. On end/close/error, stop source, drain/close ASR, persist `TeleprompterRunState`, and call coordinator finalize exactly once.
- [ ] Do not write raw ASR text or event payloads to `TeleprompterStore`; only current segment ID, mode and timestamp are persisted.

**Deterministic runtime test shape:**

```swift
func testPartialDoesNotMoveAndManualMoveClearsOldDecision() {
    var controller = TeleprompterFollowController()
    controller.receivePartial("下一段的开头")
    XCTAssertEqual(controller.currentIndex, 0)
    controller.move(to: 1, segmentCount: 3)
    controller.receiveCompleted("上一段的尾巴", segments: segments, aligner: aligner)
    XCTAssertEqual(controller.currentIndex, 1)
}
```

## Task 4: Add preparation UI and token-calibrated stage preferences

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageSettings.swift`.
- Create `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageWindow.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift` only by small additive reuse hooks if the current file requires them; never replace its existing content.
- Modify Xcode project file references/build phases for the App target.

**Token contract:**

- [ ] First add a `SpeechRailDesignTokens.Teleprompter` namespace for values that cannot reuse existing `Spacing`, `Layout`, `Typography`, `Corner`, `Control`, `Toolbar` or `Motion` values. Each new token must have a semantic name and a comment describing its scope; the stage view must not contain the literal value.
- [ ] Reuse existing surface modifiers and system materials. Use `SpeechRailDesignTokens.Color` or system semantic colors; do not introduce custom RGB/hex colors, local shadows or local corner radii.
- [ ] Define `TeleprompterStageSettings` for width, font scale, opacity, line spacing and visible segment count. Persist settings in user defaults with bounded values; use token defaults, not arbitrary literals in the view.
- [ ] Apply `accessibilityReduceMotion`, dynamic type-aware text styles, `accessibilityLabel`, `accessibilityValue`, keyboard focus and contrast-safe status colors.

**Preparation page:**

- [ ] Add a session route page with recent稿件, new/import/paste actions, title and source editor, AI analysis button, analyzing/error states, original-versus-suggestion review, segment editing, accept/revert controls, active version ID/time, deterministic fallback and “打开舞台提词”.
- [ ] Disable active-version replacement while following; require pause/end, edit and confirmation to create a new version.
- [ ] Show the live-stream safety copy before stage start: “请在直播软件中选择摄像头或目标直播窗口，不要使用包含提词器的整屏采集。SpeechRail 不负责直播推流，也不会把提词器内容写入直播画面。”

**Stage view/window:**

- [ ] Use `TeleprompterStageWindowController` backed by a non-activating floating `NSPanel`, reusing the existing caption window strategy for cross-space/auxiliary/full-screen behavior and independent window identity, while keeping content layout independent from captions.
- [ ] Render previous/current/next segments with tokenized hierarchy, current segment centered, progress and state band visible, partial preview secondary, and pause/manual/uncertain status explicit.
- [ ] Add controls and key commands: `Space`, `←`, `→`, `R`, `Esc`; `Esc` invokes `endFollowing` and closes the panel. The panel close action also ends the run and releases resources.
- [ ] Remember window position with the existing window layout conventions and persist stage settings; never make screen-capture exclusion the sole safety guarantee.

## Task 5: Wire routing, app composition, menus and storage isolation

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift` to add `.teleprompter` to `CaseIterable`, session group/routes, title/subtitle/purpose/icon and `sessionKind`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift` to render `TeleprompterView`.
- Modify `macos/SpeechRailApp/SpeechRailApp/App.swift` to construct/inject `TeleprompterStore`, `TeleprompterSession` and stage controller, and to add the route menu item.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift` and any other exhaustive session switch found by `rg`.
- Modify `macos/SpeechRailApp/SpeechRailApp/SessionSurfaceViews.swift` and `SessionExporter.swift` only to handle the new enum exhaustively without exposing teleprompter as a transcript/export record.
- Modify `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` for every new App/test file.

**Routing decisions:**

- [ ] Put `.teleprompter` in the existing `sessionRoutes` after `.captions` and do not add a global shortcut.
- [ ] Change `SpeechRailCommands` route shortcut handling so routes without an entry render without `.keyboardShortcut`; preserve all existing shortcuts and do not assign a key to `.teleprompter`.
- [ ] Wire `SessionCoordinator.starter`/`stopper` with `.teleprompter`; keep `finisher` unchanged for meeting-only behavior.
- [ ] Do not start a teleprompter session merely by navigating to the route; only the explicit “开始跟读” action acquires devices.
- [ ] Mirror existing UI-test storage isolation by constructing the teleprompter store in the per-launch fixture directory when `--ui-test` is present; the live app uses the normal Application Support directory.
- [ ] Check every exhaustive switch over `SessionKind`/`AppRoute` with `rg` before compiling, including `SpeechRailDesignTokens.swift`, `WorkspaceComponents.swift`, `ControlAgentRegistration.swift`, `AssistantView.swift`, `SessionSurfaceViews.swift`, and `SessionExporter.swift`.

## Task 6: Documentation, static token audit and gated verification

**Files:**

- Create `docs/developers/macos-app-teleprompter.md` describing module boundaries, storage schema, ASR lifecycle, failure states, window-capture safety limitation, and token rules.
- Modify `docs/developers/README.md` to link the teleprompter developer document if the current index has a macOS feature list.
- Keep the existing formal spec as the product source; update its status/version only after implementation evidence exists, not merely after code is written.

**Verification commands to run only after explicit user authorization for automated verification:**

```bash
cd /Users/hrygo/.codex/worktrees/ai-teleprompter/SpeechRail
swift test --package-path macos/SpeechRailApp
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
git diff --check
```

**Static checks allowed before that authorization:**

- [ ] `git status --short` and `git diff --check` for the worktree.
- [ ] `rg -n 'Color\\(red:|Color\\(.*green:|#[0-9A-Fa-f]{6}|\\.cornerRadius\\(|shadow\\(' macos/SpeechRailApp/SpeechRailApp/Teleprompter*.swift` and inspect each match; permitted matches must be existing token modifiers or system APIs, not new local design values.
- [ ] `rg -n 'SessionKind|AppRoute'` over all modified Swift files to confirm exhaustive cases are intentional.
- [ ] Review staged diff for secrets, absolute model paths, full prompts/transcripts, audio/video artifacts and accidental edits outside the worktree.

## Workload Estimate

按一名熟悉 SwiftUI/AppKit 和现有 SpeechRail 会话层的工程师估算，不含等待外部产品决策：

| 阶段 | 预估 | 主要产出 |
|---|---:|---|
| 领域模型、分段、对齐与确定性测试 | 1.5–2 人日 | 值类型、规范化器、fallback、aligner、夹具 |
| AI 分析、版本快照、Store 与导出 | 1.5–2 人日 | 严格 decoder、LLM 边界、原子存储、错误回退 |
| 会话占用、ASR 跟读和释放路径 | 2–3 人日 | 非持久化 coordinator 路径、reducer、实时 session |
| 准备页、舞台窗口、快捷键和 token 校准 | 2–3 人日 | AppKit panel、SwiftUI UI、偏好、可访问性 |
| 路由接线、文档、静态审查与修复 | 1–1.5 人日 | Xcode/SwiftPM 接线、开发文档、token/隐私审查 |
| 授权后的构建、自动化测试和真机直播验收 | 1–2 人日 | 编译/测试、窗口采集、权限/多空间/VoiceOver 验证 |
| **合计** | **9–13.5 人日** | 以 v1 规格为边界，不含主题自动写稿、推流和 OBS 插件 |

最大风险是 `SessionCoordinator` 的新非持久化状态路径、Realtime 断连/权限释放以及真实直播软件的窗口采集行为；若屏幕共享排除属性在目标直播软件中不可靠，交付仍必须以用户选择摄像头/目标窗口为安全前提，不能把该属性升级为产品保证。

## Execution Handoff

本计划已在独立 worktree `/Users/hrygo/.codex/worktrees/ai-teleprompter/SpeechRail` 的
`feat/ai-teleprompter` 分支完成实施。对应提交为：

- `9b31c90` / `79410c3`：领域匹配、AI 分析与稿件存储；
- `d3874297`：会话、路由、准备页与独立舞台窗口；
- `759d7629`：准备页错误可见性与 Markdown 导入修正；
- `e18f5aa`：正式规格与开发文档；
- `743d6a2d`：为 Xcode 27 / Swift 6 编译所需的既有兼容修正。

已验证：提词器专项 SwiftPM 测试 24/24 通过；Debug App 编译通过。真实麦克风、Realtime 服务、OBS/直播软件窗口采集和 UI 自动化未执行，需要用户另行明确授权。
