# SpeechRail UI/UX 与功能接线修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按审查结果逐项消除管理控制台的创作空壳、异步操作风险和全局 UI/UX 不一致，使普通用户和开发者都能看懂当前状态、动作边界与结果。

**Architecture:** 保持现有 SwiftUI App → `SpeechRailControlKit` → XPC control agent → managed Python CLI 的管理边界。创作能力通过 loopback `ServiceAPIClient` 访问既有 REST 契约；音频播放由 App 负责，作品元数据与音频保存到仓库外的用户 Application Support 目录。管理操作继续以 Control Agent 的 typed operation snapshot 为唯一事实源。

**Tech Stack:** Swift 6、SwiftUI macOS 26、AVFoundation、URLSession、XPC、Swift Charts、既有 SpeechRail REST/OpenAPI。

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md`、`docs/superpowers/specs/2026-09-13-speechrail-global-interaction-language-design.md`、`contracts/openapi.yaml`

## Global Constraints

- App target 仅支持 macOS 26，不增加 macOS 14 兼容 fallback。
- 不修改公开 HTTP 路由和 `ControlConstants.schemaVersion == 1`；Swift client 必须按现有 OpenAPI 字段解码。
- App 不直接执行 `launchctl`、不读取模型路径/日志/凭据；模型管理仍只走 XPC。
- 作品音频、作品元数据和用户音色只写入仓库外的 Application Support；日志不得写入原始音频、完整 prompt 或 Authorization。
- 用户已要求暂停自动化测试；本轮只做源码检查、Debug/Release 编译和手工 UI/AX 验证，不运行 XCTest/XCUITest/Python pytest/ruff/mypy。
- 每项修复保持独立 diff 和回退点；不覆盖工作树中已有修改，不删除 legacy 文件。

---

### Task 1: 建立创作 REST client、typed models 与音频播放边界

**Files:**

- Create: `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/AudioPlaybackController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**

- `SpeechRailCreatorClient.fetchVoices() async throws -> [CreatorVoice]`
- `SpeechRailCreatorClient.createSpeech(text:voice:speed:) async throws -> Data`
- `SpeechRailCreatorClient.createVoicePreview(text:instruction:speed:seed:) async throws -> Data`
- `SpeechRailCreatorClient.registerVoiceDesign(id:name:instruction:referenceText:seed:) async throws -> CreatorVoice`
- `AudioPlaybackController.play(data:) throws`, `stop()`, `isPlaying`
- 所有 REST 错误统一解码 `ErrorBody` 的 `error.code/message/retryable`，未知响应使用用户可理解的 fallback。

- [x] 从 `contracts/openapi.yaml` 固化 VoiceProfile、VoiceList、VoicePreviewRequest、SpeechRequest、VoiceDesignRegistrationResponse 的 Swift 解码模型。
- [x] 为 `ServiceAPIClient` 增加 Accept/Content-Type、HTTP status 和 audio MIME 校验；不把服务端原始错误或路径直接展示给用户。
- [x] 在 AppModel 注入 creator client 和 playback controller。
- [x] 加载创作页时刷新真实音色列表，所有请求具备 loading、取消、失败和恢复状态。
- [x] 通过 Xcode 工程文件加入新源文件，并执行 Debug 编译验证。

### Task 2: 接通配音台与作品保存

**Files:**

- Create: `macos/SpeechRailApp/SpeechRailApp/CreativeWorkStore.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**

- `CreativeWorkStore.list() throws -> [CreativeWork]`
- `CreativeWorkStore.save(_:) throws`
- `CreativeWorkStore.loadAudio(for:) throws -> Data`
- `CreativeWork` 只保存 voice ID、显示名、文稿、创建时间、音频文件引用和可选耗时；不保存 request Authorization。

- [x] Picker 数据来自真实 `/v1/voices`，只显示 `available == true` 的音色，并在服务不可用时保留明确的恢复动作。
- [x] “生成并试听”调用 `/v1/audio/speech`，成功后播放 WAV/MP3 数据并保存作品；按钮在请求中显示“生成中”，停止只停止播放，不伪造取消服务请求。
- [x] 失败时保留文稿和选择，显示稳定中文错误与重试入口；成功提示文案与动作名称一致。
- [x] `WorksView` 从 `CreativeWorkStore` 加载和试听真实作品，空状态提供“去配音台”入口；移除 `mockWorks`。

### Task 3: 接通音色创作、音色库与试听/保存

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`

- [x] “生成候选音色”调用 `/v1/voices/previews`，将同一 instruction 的候选请求用稳定 seed 区分；候选进入 loading/成功/失败状态。
- [x] 候选试听使用 `AudioPlaybackController`，同一时间只允许一个候选播放，并给出停止反馈。
- [x] 保存动作调用 `/v1/voices/designs`，生成唯一合法 ID，展示质量/档位限制和冲突错误；不把本地候选标记冒充持久化成功。
- [x] 音色库从 `/v1/voices` 加载真实列表，系统音色和自定义音色分别表达；“试听”调用 `/v1/audio/speech`，不再使用空闭包。

### Task 4: 修复模型操作终态与取消锁

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`

- [x] 增加 `cancelling` 内部阶段；调用 terminate 后保持 `activeMutation`，直到 runner 明确返回并完成 journal 处理。
- [x] operation status 在停止期间返回可表达“正在停止”的状态，不提前伪造终态；迟到 progress 不能重新打开终态。
- [x] AppModel 在取消确认、停止中、取消完成和取消失败四个阶段分别显示用户可理解的反馈。
- [x] 模型状态暂时不可读时保留正在进行的 operation，并在恢复后重新对账 catalog/status。

### Task 5: 补齐服务启停/重启的异步反馈

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`

- [x] 将 service mutation 的 command/phase 映射为“正在启动/正在停止/正在重启/健康检查中”。
- [x] 服务页和菜单使用同一 `OperationBar`/状态提示；操作期间不继续显示旧的“服务可用”结论。
- [x] 终态成功、失败和控制 Agent 不可用分别给出结果、恢复动作和诊断入口。

### Task 6: 固化全局设计 token、icon、选中态与点击反馈

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`

- [x] 统一 route icon：`waveform.and.mic`、`waveform.badge.plus`、`music.note.list`、`square.stack.3d.up`、`server.rack`、`chart.xyaxis.line`、`shippingbox`、`stethoscope`。
- [x] 所有标题、侧栏、菜单复用 route token，不在页面内重复写旧 SF Symbol。
- [x] 移除手工 selected label foreground，使用 macOS List selection/tint；检查浅色、暗色和增强对比度 token。
- [x] 自定义可点击行保留 hover/pressed/focus/cursor；静态区域不显示指针，不增加伪交互。

### Task 7: 收口顶部标题、模型文案与诊断可读性

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`

- [x] 标题自适应顺序固定为完整标题 → 隐藏上下文 → 标题尾部截断，始终单行且不溢出。
- [x] 模型警告按实际缺失 artifact 展示，如 `aligner-q8`，不把 aligner 错报为 CoreML 分人资产。
- [x] 下载确认明确说明只下载、不重启、不切换档位、不删除模型、不上传音频或作品。
- [x] 诊断清单在最小窗口下保证检查项全名可读，必要时局部滚动，不牺牲一屏结论。

### Task 8: 修复 AppModel 状态生命周期与 wire decoder

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/XPCControlTransport.swift`

- [x] service/monitoring 刷新使用 generation/cancellation 机制，防止旧 health 响应覆盖新快照。
- [x] 成功读取后清理对应旧错误，不让 model message 跨页面残留。
- [x] CLI decoder 校验 schema、command、result event 和 progress event，拒绝错配输出。
- [x] XPC 成功返回时取消 timeout work item，避免无意义的延迟任务累积。

### Task 9: 逐项验收和交付记录

**Files:**

- Modify: `docs/developers/macos-app-design-system.md` only when the verification record needs a factual update.
- Modify: `CHANGELOG.md` only after the user requests a release/version bump.

- [x] 本轮收口执行了 `git diff --check`、相关源码检索和 Debug/Release 编译；自动化测试按用户要求未执行。
- [ ] 手工验证顶部标题、静态/可操作鼠标指针、pressed/focus、浅色/暗色、最小窗口和 VoiceOver AX labels。
- [ ] 手工验证真实创作请求只在用户明确触发时执行；本计划默认不自动下载模型、不重启服务。
- [x] 已记录本轮实际验证时间、未验证事项和回退点；未完成的人工验收项保持 unchecked。

## Verification record

- 2026-09-13 21:40 +0800 — `git diff --check`: passed；源码检索未发现 `mockWorks`、`模拟生成`、空的“试听”闭包或已淘汰的导航图标。
- 2026-09-13 21:40 +0800 — `scripts/macos_app_build.sh --configuration Debug`: passed (`** BUILD SUCCEEDED **`)。
- 2026-09-13 21:40 +0800 — `scripts/macos_app_build.sh --configuration Release`: passed (`** BUILD SUCCEEDED **`)。
- 2026-09-13 21:59 +0800 — 已按军规退出并将旧 `SpeechRail.app` 移入废纸篓，安装 Release archive 到唯一用户路径；新 App 为 `2.6.0 (2)`，bundle identifier 为 `com.speechrail.desktop`，签名结构校验通过。
- 2026-09-13 21:59 +0800 — 新构建 wheel SHA-256 为 `e99a22c504b14a13d60ddbd5bbd5d2b0eca5d8d2a4ac198d241547a12340f5fb`，与当前 managed `runtime/current` release 标识一致，因此未做无意义的服务停启替换；安装后 preflight、health、ready、models、voices 和唯一 listener 均通过。
- 2026-09-13 22:13 +0800 — 针对模型展示与实情一致性完成 live 核对：catalog、model status、profile status、`/health`、`/readyz` 与 preflight 均已读取。发现 `aligner-bf16`/`aligner-q8` 同时出现在 generic 与 dedicated diarization 检查 lane；App 已改为以 dedicated lane 为权威，避免把已存在的分人资源误报为未下载。
- 2026-09-13 22:13 +0800 — 新 Release archive 已重新构建并安装；旧 App 已按军规退出后移入废纸篓，新 App 为 `2.6.0 (2)`，新安装包二进制 SHA-256 为 `55302e77b2cf8a6423cf88014db755878c04ee807d2bf705fe81e0ee92df69e6`，deep codesign 校验通过。模型页已手工通过 AX 核对 Quality、Balanced、Light 三个目标档位，分别能区分“存在”与“使用”，并单独标记 catalog 未登记的旧制品。
- 2026-09-13 22:13 +0800 — 当前服务实情为 Quality：`asr-1.7b-q8` 10/10、`tts-1.7b-design-q8` 13/13、`tts-1.7b-base-q8` 12/12、`aligner-bf16` 10/10、`diarization-coreml` 10/10 均已验证；ASR/TTS/streaming 为 `cold_evicted`，表示可按需加载，不表示缺失或当前常驻。Balanced/Light 目标档位资源已存在但未应用，因此展示为“当前档位未使用”。
- 自动化测试、服务重启、模型下载、真实创作请求均未执行；原因是本轮遵守用户“暂停自动化测试”的边界，且服务已在目标 wheel 上。
- 待用户验收：新构建的完整 UI/AX 手工检查（标题、指针、pressed/focus、浅色/暗色、最小窗口、VoiceOver），以及明确触发后的真实创作链路。
- 回退点：旧 App bundle 已保留在废纸篓，当前归档保留在 `build/SpeechRail.xcarchive`；未提交 Git，服务 app home、runtime、selection、模型和配置均未删除或覆盖。

## Definition of Done

- 配音、音色创作、音色库试听/保存和作品历史不再使用 mock 或空闭包。
- 模型下载取消不会在进程退出前释放 mutation 锁，服务/模型操作都能显示进行中和终态。
- 全局 icon、选中态、标题、对比度、指针和点击反馈遵循同一套 token。
- 所有失败与空状态都给出下一步动作；普通用户与开发者详情边界清晰。
- 本轮自动化测试仍保持暂停，报告只声明实际执行过的验证。
