---
title: "SpeechRail macOS App 开发与测试"
status: active
version: "0.6.6"
date: 2026-10-05
---

# SpeechRail macOS App 开发与测试

界面开发必须先遵循 [macOS App 设计系统与 Token](macos-app-design-system.md)。该文档规定
macOS 26-only 的特性优先级、服务侧独立 target 的边界，以及 SwiftUI 页面可使用的统一
token；新页面不得自行定义颜色、间距、圆角和字体层级。

## 工具链

- 当前本机工具链为 Xcode 27.0（build 27A266）、Swift 6.4；Native targets（`SpeechRailApp`、ControlKit、ControlAgent、CaptureHelper 与服务侧 worker）统一使用 macOS deployment target 26.0，首期只构建 `arm64`。
- Python 仍固定为 `>=3.14,<3.15`，使用仓库现有 `uv` 环境。
- 运行 App 前，首次安装 Xcode 的管理员需要在本机接受 Apple 许可；不要把管理员密码写入脚本或仓库。
- 当前本机不依赖 Apple Developer ID；Debug/Release 可用 ad hoc 本地签名且关闭 Hardened Runtime。无 Team ID 时，Debug/Release 使用 App bundle 内的 XPC service，避免把 ad hoc helper 交给 macOS 的 `SMAppService` Launch Constraint；Distribution 才启用 Hardened Runtime 并使用签名的 `SMAppService`。

## 边界

`SpeechRail` 是控制面，不是 ASR/TTS runtime。它不加载模型，也不直接执行 `launchctl`。音频只在用户主动启用的功能会话里进出：音色克隆仍在「开始录制 → 停止」之间采集参考音频并关闭 AEC / AGC / 降噪；语音助手使用共享的 `AudioEngineSession` 做采集与 TTS 播放，会议助手/实时字幕使用会话级采集链，按功能启用、离开即释放。会话 PCM 不落盘，文本与记录才写入本机 SQLite；助手默认使用实时对讲（耳机）并请求系统 voice processing，设备不支持时显式失败并建议切换半双工。完整的音频线程、格式、XPC process tap 与未验收声学边界见 [音频采集最佳实践](macos-app-audio-capture.md)。Distribution 的 `SpeechRailControlAgent` 由 `SMAppService` 管理；本机 Debug/Release 则使用 `Contents/XPCServices/com.speechrail.desktop.local-control.xpc` 按需启动同一控制代码，通过 XPC 接收固定命令，再委托现有 managed Python CLI。实际服务仍由唯一的 `com.speechrail` user LaunchAgent 运行。

App 只连接 loopback；健康/目录读取保持公开状态语义，创作 REST 请求通过进程环境或受管
`Application Support/SpeechRail/config/.env` 发现 Bearer key。模型目录、`.env`、日志、原始音频、完整转写和 API key 均留在 App bundle 之外，key 只在请求内存中使用。

`ServiceAPIClient` 通过 `ServiceDiagnosticsClient` 抽象读取 `/health` 和带
`Accept: application/json` 的 `/metrics`；UI 测试用 fake client 返回 typed snapshot，不能
因为测试参数而访问 loopback。`model.status` 另外返回分人 CoreML/aligner 状态，避免只看
`models/` 快照就误判 diarization 已就绪。

能力结论只认服务声明：`ServiceModelCapabilityClient` 读取 `GET /v1/models` 的
`capabilities`（`supports_preview` / `supports_clone` / `supports_instruction`），服务只在对应
capability 真正解析成功时才置为 `true`。服务状态页的能力矩阵与音色创作门禁仍读这一份
快照。服务另提供 `GET /v1/speechrail/capabilities`（`effective_capabilities_v1`）和
`/v1/speechrail/voices*` 安全发现投影；跨模型、音色和操作参数需要同代一致性时使用前者，
不要把多次读取 `/v1/models`、`/v1/voices` 拼成原子结果。音色列表（`/v1/voices`）是用户数据，
可以为空，「还没有克隆音色」不能推出「服务没有克隆能力」；用列表反推能力会报出假的「未就绪」。

App 的 TTS 请求必须把这个快照当作 revision pin 的来源：Realtime 仅在
`speechrail.tts.start` 的 `voice`、`voice_revision`/`expected_model_revision` 上绑定本次
音色与 TTS 模型，并在切换音色时同时更新这些值。`SpeechRailSessionUpdate` 只接受
`expectedASRRevision`，不接受 TTS pin；旧 `session.speechrail.expected_tts_revision`
已移除，服务端明确拒绝。REST creator 通过 `SpeechRail-Expected-Voice-Revision` 和
`SpeechRail-Expected-Model-Revision` 传递同代约束。匹配不到可用 voice、对应 operation 或
revision 时显式保持 `nil`，走服务端普通协商，不从 voice 名称、模型名或本地时间推断版本。

### Native Realtime ASR/TTS 编排边界

`SpeechRailApp` 的 `RealtimeASRClient` 只发当前契约：先发一次 `session.update`
（`session.type=transcription`、24 kHz mono PCM16、`session.audio.input.transcription.model` 与
`session.speechrail.{task,tts,alignment,diarization,endpointing}`），再发
`input_audio_buffer.append/commit/clear`。语音助手会在本地 Responses 流中完成 LLM、历史、记忆、
人设和工具编排，把稳定句子按连续 `sequence` 用 `speechrail.tts.append_text` 追加到同一个
utterance，再用 `speechrail.tts.finish_text` 关闭文本侧；同一 WebSocket 同时只允许一个服务端 TTS
utterance，收到匹配 `request_id` 的 terminal（`completed`/`cancelled`/`failed`）后才提交下一句。

每个可验证的 caller-owned TTS request 都带当前 voice revision；Realtime 建连和会话内换音色都从
同一份 effective snapshot 重新解析。revision 不可用时不伪造 pin；服务端返回 revision conflict
时由调用方重新发现并决定是否继续，不自动改用最新音色。

当前 wire 没有 `input_audio_buffer.speech_started`/`speech_stopped`：服务端只回 ASR
hypothesis（`speechrail.transcription.hypothesis`，按 `utterance_id` + 严格递增 `revision` 替换全文）与
text final，alignment 和匿名分人归属随后独立到达。实时对讲模式由 `AssistantSession` 在出现首个非空
hypothesis 时清空本地播放队列并显式发送 `speechrail.tts.cancel`；服务端不自动替 App 做 barge-in。
旧 `transcription_session.update`、`conversation.item.create`、`response.create/cancel` 和
`response.audio.*` 不会被 Native 或服务端翻译。

## 当前控制面 surface

`Window("SpeechRail 管理控制台", id: "control-center")` 承载同一个 `AppModel` 下的三类一级 surface：

- 创作：配音台、音色创作、音色克隆、音色库、我的作品。音色创作保留 VoiceDesign 的描述、候选、试听和保存主线；音色克隆在应用内读服务端下发的提词稿、录制参考音频，经 `validate` 预检后注册成新音色（录音只落系统临时目录、应用收下即删，采集链关闭 AEC / AGC / 降噪；入口按服务当前明确声明的 VoiceDesign 与 Base 能力开放，不由档位名称推断）；配音与试听通过统一的本机 Bearer 凭据接入服务，音色库提供服务端列表、详情、更新和删除，失败时保留用户输入并解释稳定错误。
- 会话：语音助手、会议助手、实时字幕、AI 提词器。四类功能共享会话层的启停与资源占用边界，但各自拥有不同的来源、转写和本机记录；空闲时不持有麦克风、系统音频 tap 或播放引擎。
- 服务：服务状态、运行监控、模型组合、诊断、开发者文档。服务状态解释健康状态和能力，监控读取 `/metrics`，模型组合通过 XPC Agent 调用锁定目录的 `model catalog/status/prepare`，诊断显示可操作的失败原因；开发者文档把接入信息（服务地址 / 鉴权 / 运行档位 / 已发布能力）与 8 个主题的最小示例放进应用，事实仍以 `contracts/` 与 `docs/users/` 为准。

模型页明确区分“下载并校验”和“应用此档位”：前者执行逐文件大小/SHA-256 校验和原子发布，可显示 JSONL 进度并取消；后者才改变当前 profile。App 不直接访问模型源、不把本地路径或 hash 返回给页面，也不把模型下载放进请求路径。

### 语音助手的会话与回看布局

`AssistantView` 的 live/ready 状态可使用右侧 inspector；窗口进入 compact tier 时，右栏响应式收起，主内容仍保持可操作。`review` 状态是独立的记录阅读布局：只显示记录列表与转写正文，不再显示右侧 inspector；复制、继续、重命名、移除动作固定在正文底部，并通过 `ViewThatFits` 在一行或两行之间适配。继续会话从原记录预填人设、音色和会话偏好并建立新会话，原记录保持不变；移除记录仍是明确的破坏性操作。

这段是当前代码行为说明，不替代会话层技术方案；真实声学 AEC、双讲收敛和各种设备组合仍以音频文档中的未验收项为准。

### 语音助手的续接、重播与试听（2026-10-04）

**基于旧记录继续是建新场，不是改旧记录。** `AssistantSession.continueFromRecord(parentID:)` 从旧记录读一致快照，只取选定的完整 user/assistant 轮次建新记录，冻结选定文字为 `continuationSeed`（自包含：删父后子场仍可用）。旧记录原文不动，不自动开麦，不复制密钥与旧 route 同意。回看页的「继续这一轮」走同一路径：活跃场先明确结束，再建新场。新场 history 只含选定完整轮次。schema v2（`assistant_reply_state` / `assistant_playback_invocation` / `assistant_continuation` / `assistant_memory_provenance`）未实施，续接不依赖迁移。

**重播是独立播放调用。** `replayingTurnID` 绑定原始 turnID：旧 TTS 轮仍活跃时先经统一中断收尾，再开新重播；停止重播只记本次播放（`interruptedReplayTurnIDs` + `playbackDeliveryNotes`），不改被重播轮的生成状态与正文。完整生成但未播完时原文全文保留，界面挂「朗读未完成」。下一次请求的上下文正文仍是原文，生成状态与播放状态另由应用说明绑定到条目 ID，不推算用户听到了哪些字。

**试听不经文字提问。** 「测试朗读语速与音色效果」走现有 `previewSelectedVoice` 试听协调；无 TTS 通道（纯文字场）时播放按钮给出明确原因，不静默返回。

### 语音助手的接收、保存与请求预算（2026-10-04）

唯一 receiver 同步登记插话意图、用户保存命令和音频准入。取消确认、SQLite 保存及播放预算等待均由有句柄的任务承担；匹配终态仍由 receiver 消费。远端归属未知或旧 outbound 任务尚未退出时拒绝同连接新 TTS，不把“取消已发送”视为确认；超时解除等待但保留旧任务归属，直到任务实际退出。ACK 超时不重发 append。

打字与语音输入共用 `AssistantInputPersistenceQueue` 单消费者保序保存，默认最多 32 个在途命令、64,000 Unicode scalar，失败命令仍计预算。保存成功才投影正式对话与提交回答；partial 只归档。前序保存失败时，后续已接纳输入返回 blocked 并保留命令，恢复后按原顺序保存，不由草稿重复发送；本句保存失败仍明确报错。结束等待本记录已经接纳的保存（含正常、partial、draining 与打字在途保存），未完成或失败时保留恢复入口并避免宣称封存成功。主动关闭语音先收尾已有回复，保留文字上下文与待保存正文。恢复按固定行 ID 核对，不直接把唯一键冲突当成功。首条正式用户行在 Store 条件命名，partial 不占命名资格，人工标题不被迟到自动命名覆盖。

实时对话展示同时读取已保存行与当前记录中已接纳的输入，按固定行 ID 去重。输入接纳后立即显示正文和“正在保存”，保存完成原位切换为正式行；失败时保留正文并标记“未保存”，不计入已保存行或模型上下文。队列状态可观察，首轮字幕定稿与保存之间不会重新显示聆听空态；保存上一句不清掉下一句字幕，准入拒绝时保留当前字幕。滚动仅跟随展示行 ID 的变化，保存状态切换不重复触发滚动。

音频使用唯一 FIFO 消费任务。每次 start 默认声明 `audio_window_bytes=1_440_000`（30 秒 PCM，约 1.4 MB），started 必须回显相同窗口；接收事件流、FIFO、在途待入队 PCM 与播放器共享该 request 的未消费额度，不因数据已入播放器而归还。服务端窗口耗尽时暂停音频发送，本代渲染完成回调释放容量后才通过 `speechrail.tts.audio_ack.sample_offset` 归还累计额度。发送由一个有句柄的任务合并水位；取消后的旧回调和旧发送不能给新 request 归还额度。`limits.max_pending_audio_bytes` 仅约束 worker/传输与单块大小，不再用作客户端累计待播预算。单块仍限 48,000 bytes，播放 ledger 默认仍限 24,000 个 Int16 samples（48,000 bytes）；FIFO 吸收提前合成的音频。服务端 completed 不结束 playback waiter，待 FIFO、入队和播放器全部排空后才报告整轮完成。上游事件流原有 4 MiB decoded PCM 限额是额外保护。

服务端完成终态、FIFO/在途与播放账本全部排空才表示播放完成；completed 不要求最后一块已发消费 ACK。保留 2 秒播放/消费停滞上限；5 秒文本 ACK 按无进展期限判断，健康的本代播放进度可以续期，但不能确认文本或提前 finish。服务端在 backend 接受 append 后独立发送文本 ACK，避免排在等待消费额度的音频后面。真实设备播放与用户听到的证据仍按既有回调边界区分。

音色选择按版本保留最新意图，同一 client 串行写入 voice 与 revision pins。当前 request 固定音色，下一 request 等最新写入后启动；在真实 started 与回复库 ordinal 已知后，才按明确 sessionID 记录变更。记录失败报告已用于朗读但未保存，不回滚已启动 request。

`runReply` 使用 `AssistantContextPolicy` 构造真实 provider 请求：最多 12 个历史 user/reply turn、16,000 历史 scalar、4,000 记忆 scalar、24,000 总请求 scalar（包括 instructions、人设、状态说明及当前问题），输出 `maxOutputTokens=1_024`。历史按完整 turn 裁剪，当前问题只出现一次，原 SQLite 与续接种子不改写。必要内容自身超限时给出明确错误并保留已保存问题。界面显示实际省略范围。这些是产品预算，不代表模型 token window、质量或费用保证。

生成失败与朗读未完成在本场内存中分开记录；已收到正文保留。重新打开旧库记录时，现有 interrupted 字段不能恢复失败原因或播放细节，因此原因与交付状态记为未知。本次没有 schema 迁移；自动摘要、长期内存分页、设备切换续播及启动并行优化另行评估。定向 fake、构建和真实设备验证结果分别记录在 [本轮验收记录](../plans/2026-10-04-assistant-e2e-followups-acceptance.md)，不互相替代。

### 语音助手的对话状态、文字降级与回复行（2026-09-28）

**"这一场还在"和"正在跑"是两个状态。** 静音和断线都不再把会话退回"未开始"：
`AssistantSession.hasActiveConversation` 表示对话仍然存在（可以继续说话、继续打字、结束），
`isActivelyRunning` 表示此刻确实在跑。`AssistantView` 用前者决定 live 投影、用后者决定是否
盖住受阻结论——断线之后用户要看见的是"识别中断了"和重试出口，而不是退回 ready。
静音只关掉麦克风上行，状态标题显示"麦克风已静音"；静音期间同样可以结束会话，
WebSocket 关闭也照常走清理。新的对话重置静音，同一会话的重连保留用户的选择。

**打字降级不经过麦克风。** 输入框里的文字走 `AssistantSession.ask(typed:)`：
没有会话时用 `SessionCoordinator.createSession` 建一条纯文字记录——这条路不碰设备占用，
既不抢 `activeSessionID`，也不会打断正在占用设备的会议；因此麦克风被拒或会议占着设备时
文字照样能发出去（不建音频档位，`engineProfile` 记 `unknown` 而不是编一个）。
纯文字提问不朗读回复。`AssistantView` 侧有单飞门闩：发送中按钮显示"发送中…"并禁用，
双击只发一次；成功后**只在草稿未被改动时**清空，晚到的成功不会抹掉用户等待期间新输入的字；
失败时草稿原样保留，并用 `NoticeBar` 给出可读原因和「重试」，不吞字。

**一轮回复就是一个行身份。** `AssistantReplyState` 让一轮回复的 `id` 同时是 `line.id` 和
`Turn.id`：第一段非空正文即以该 id 建 `partial` 行，之后只 UPDATE，不再每段插一行。
`finalizeReply(_:reply:)` 是唯一收尾入口并按 `isFinalized` 幂等——正常说完、用户打断
（Esc 或 barge-in）、provider 失败、连接断开、结束对话都经它收尾；它接收值类型快照，
跨过 `await` 之后即使新的一轮已经接管也不会写错会话。打断标记只能从 false 推向 true，
迟到的"正常完成"可以补全正文但擦不掉打断标记。落库失败显示为失败，不假装"已保存"。
异常退出时 `sealAbandonedSessions` 在同一个事务里封存会话，并把该记录中助手自己的 partial 行
收成 final + interrupted，保留已写下的正文；用户行和其他功能的说话人 partial 不受影响。

**取消要等服务端确认。** `AssistantTTSStreamCoordinator.cancel()` 返回的是"服务端是否已确认
这一轮终止"，等的是匹配 `request_id` 的**终态**而不是"取消命令发出去"；闩在 Realtime 接收层
的 `handleTerminal` 上解锁，避免自己等自己。确认了就回聆听态；没确认则关闭连接、释放设备并
记一次**可重试**的语音中断，不靠 sleep 或自动重发正文盖住竞态。

**没有精确时间就不写时间。** 助手记录的用户行不再拿会话起点冒充发言起点：每个 item 按
**首条证据到达的时刻**（`itemObservedAt`，按 itemID 记，重连不清）与每个连接建立的时钟锚点
计算，`t_start` / `t_end` 存 NULL，`timingQuality = .unavailable`。精确声学时轴仍以服务端的
`sample_span` 为准，不与本地观测时刻混为一类；历史记录不做批量回填。

## 发布与运行态关系

- `com.speechrail` 是实际服务 owner，必须由服务发布/安装流程负责登录常驻；`SpeechRail.app` 只是按需打开的控制面，不是登录启动项。
- `com.speechrail.desktop.control` 是 Distribution 中由 App 通过 `SMAppService` 管理的独立 XPC helper；它不拥有 8201、不加载模型、不创建第二个服务实例。
- `com.speechrail.desktop.local-control` 是 Debug/Release 内嵌的 XPC service，仅在 App 需要控制操作时由系统按需启动；它不注册登录项、不依赖 Developer ID，也不拥有 8201。两种模式都复用同一个 `SpeechRailControlAgentCore` 和 XPC 协议。
- 签名 Distribution App 只读取 `SMAppService` 的 status snapshot：`enabled` 允许 mutation，`notRegistered` 由用户明确点击启用后调用 `register()`，`requiresApproval` 只打开 Login Items，`notFound` 和未知状态 fail closed。本机 Debug/Release 只使用内嵌 XPC，不触碰 Distribution 的登录项记录；App 启动不会隐式 `unregister()` 或吞掉注册错误。
- `service-only`、`app-only` 和 `combined` release 允许独立回滚。联合发布必须先验收 service wheel，再验收 App 的 `status`/`preflight` 控制链路；发布、安装、清理和回滚统一见 [macOS App 分发与签名](macos-app-release.md) 与 [版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)。

## 本地开发

1. 在 Xcode 中打开 `macos/SpeechRailApp/SpeechRailApp.xcodeproj`，选择 `SpeechRailApp` scheme。
2. Debug/Release 默认使用 `Sign to Run Locally` 的 ad hoc 本地签名；测试脚本默认保留签名，以满足当前 Xcode UI test runner 的 `Testing.framework` 运行库要求。只有明确需要未签名 bundle 时才设置 `SPEECHRAIL_MACOS_SIGNED_TESTS=0`。
3. 修改 Python 服务后先执行 `uv sync --extra dev`，再运行 Python 定向测试（`uv run --extra dev pytest`）。`scripts/macos_app_test.sh` 属于 XCTest/UI test，会接管前台窗口、焦点和输入，仅在当前用户明确要求时运行（见根目录 [AGENTS.md](../../AGENTS.md) 硬约束），不因开发或验收流程自动触发。
4. UI test 通过 `--ui-test` 使用 fake transport；不会注册生产 helper、启动 `com.speechrail` 或访问真实模型。Debug build 和 UI test 使用一次性临时 DerivedData，命令结束会注销本次构建 App 的 LaunchServices 注册并清理 App/runner；不会留下可搜索的测试 App。

## 测试隔离

- Swift unit tests 只使用 in-process fake runner/transport。
- UI/integration tests 使用 fake transport、临时 app home、端口和 helper label；测试结束必须注销临时 LaunchAgent 并清理临时目录。
- 任何会接管前台窗口、焦点或输入的 UI 自动化都需要当前用户当次明确授权；文档、发布流程或历史记录本身不构成运行许可。
- 真实 `SMAppService` register/unregister 只在签名 Distribution 验收中执行；本机 Debug/Release 走内嵌 XPC service。真实 `com.speechrail` smoke 仍只在单独、明确授权的本机验收中执行。
- profile apply 仍由 Python transaction journal、preflight、public smoke 和 rollback 决定成功与否；App 不自行推断模型能力。
- `model prepare` 是独立的可取消 mutation；Agent 仅转发已确认的档位、进度和终态，取消后不会把部分 staging 目录当作可用模型。
- 模型 progress 的 `phase` 使用 `download`、`verifying`、`publishing` 等受控值；文件名、字节数可以显示给用户，但不携带 URL、绝对路径或凭据。
- `model prepare` 的 active operation 会在 managed app home 的受控 journal 中保存脱敏元数据；App/Agent 重启后只恢复 active/interrupted 的解释状态，不承诺续传。`model.status` 的 manifest 校验仍是模型可用性的最终事实来源，终态 operation 会清理 active journal。
- 运行监控的实时档只保留最近 60 个采样点（App 会话级，每 5 秒一个），页面关闭不改变服务；无数据时显示「还没有运行数据」并说明这不代表服务异常，不显示虚构的 0 值或容量。
- 运行监控的「服务落盘」档（最近 1 小时 / 24 小时 / 7 天 / 30 天）读 `{app_home}/state/metrics-rollup/*.jsonl`：App 直接读文件而不是走 HTTP，所以服务重启、换版甚至停服期间历史仍然可见，也不新增公共接口。目录按 `SPEECHRAIL_METRICS_ROLLUP_DIR`（环境变量或 `{app_home}/config/.env`）解析，日志目录同理。聚合口径必须与页面说明一致：次数与音频秒数求和、耗时按样本量加权（不是把各区间均值再平均）、`p95` 取区间内最大值、内存峰值只取完整读数；读到坏行计入「读不动的行数」，空档与重启分开计数，缺数据不能显示成 0。
- 运行监控首屏只数语音接口（`/v1/audio/speech`、`/v1/voices/previews`、`/v1/audio/transcriptions`）：控制面轮询（`/health`、`/metrics`、`/v1/models`、`/v1/voices`）同样计入 `speechrail_http_requests_total`，本机实测占累计请求的 97.6%，不能用来表达「用户请求了多少」。`rate` 与直方图累计口径保留在开发者详情与复制摘要里。

## 控制操作错误契约

- managed CLI 在成功和失败时都必须优先输出 `schema_version=1` 的 JSON envelope；非零退出码不能替代 envelope 中的 `error_code`、`message` 和 `status`。
- Agent 调用 managed Python 时必须使用 `python -m speechrail ...`，不能把 CLI 的第一个子命令直接作为 Python 脚本路径；参数数组保持逐项传递，不经过 shell。
- `SpeechRailControlAgent` 即使子进程退出码非零，也先解析 stdout 的机器输出；只有输出无效时才使用限长、脱敏后的 stderr 尾行作为兜底，不把路径、凭据或完整 traceback 传给 UI。
- 异步 profile operation 的 `OperationSnapshot` 必须保留 `phase`、`errorCode` 和 `message`，并由 `operationStatus` 返回；App 收到 `failed`/`cancelled` 终态必须显示可读原因和错误码，不能只显示 `managed command failed`。
- 每个 XPC 请求都有有限超时；helper 无法启动或无响应时，App 显示可恢复的控制面错误，不得无限等待。切换类 mutation 不在未知提交状态下自动重放，避免重复执行。
- UI 测试中的 fake transport 必须覆盖一次失败终态；真实安装包验收仍需额外执行一次 App → XPC → managed CLI → `com.speechrail` 的切档往返，不能把 fake UI test 视为生产链路证明。
- 档位选择器首次显示以服务返回的 active profile 为准；切档失败回滚后重新同步 active profile，避免把默认 `quality` 当成用户选择。

## 常见恢复

- Distribution Agent 显示为 disabled 或 requires approval：打开 System Settings 的 Login Items & Extensions，检查 `SpeechRailControlAgent` 的用户批准状态，然后回到 App 重试。
- 本机 Debug/Release 不依赖 Login Items 中的 control helper，也不会清理或注销用户已有的 Distribution 注册；如果本地 XPC 不可用，运行预检并重新构建受控 bundle，不手工复制 plist 或直接启动第二个 Agent。
- 替换签名 Distribution App 后，先看 App 展示的 `enabled`/`requiresApproval`/`notFound` 状态；只有用户明确启用时才注册，不通过隐式注销/重注册修复授权。
- 如果模型准备在 Agent 重启后显示“上次准备被中断”，重新执行“下载并校验”；不要把 journal 的进度当作可续传证明，也不要直接把 staging 文件当作 verified 模型。
- managed runtime 缺失：先运行 `speechrail service preflight --app-home "$SPEECHRAIL_APP_HOME"`，不要让 App 下载模型或创建第二个 runtime。
- 服务不 ready：检查现有 `com.speechrail` 状态、端口和 `/health`/`/readyz`；App 退出不会自动停止服务。

## 验收命令

```bash
scripts/macos_app_build.sh --configuration Debug
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
# scripts/macos_app_test.sh  # XCTest/UI test：接管前台窗口/输入，仅在当前用户明确要求时运行
```

`scripts/macos_app_test.sh` 是 UI 自动化测试，仅在当前用户明确要求时逐次运行（见根目录 [AGENTS.md](../../AGENTS.md)）；默认不执行，未执行时在结果中记为未验证项而非通过。

分发签名、archive、notarization 和回滚流程见 `docs/developers/macos-app-release.md`。
