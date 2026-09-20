---
title: "SpeechRail macOS App 开发与测试"
status: active
version: "0.5.7"
date: 2026-09-20
---

# SpeechRail macOS App 开发与测试

界面开发必须先遵循 [macOS App 设计系统与 Token](macos-app-design-system.md)。该文档规定
macOS 26-only 的特性优先级、服务侧独立 target 的边界，以及 SwiftUI 页面可使用的统一
token；新页面不得自行定义颜色、间距、圆角和字体层级。

## 工具链

- 当前本机工具链为 Xcode 27.0（build 27A266）、Swift 6.4；Native targets（`SpeechRailApp`、ControlKit、ControlAgent、CaptureHelper 与服务侧 worker）统一使用 macOS deployment target 26.0，首期只构建 `arm64`。
- Python 仍固定为 `>=3.12,<3.13`，使用仓库现有 `uv` 环境。
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

App 的 TTS 请求必须把这个快照当作 revision pin 的来源：Realtime 通过
`speechrail.tts.create.expected_voice_revision` 绑定当前 voice，并在切换音色时同时更新 voice
与 revision；REST creator 通过 `SpeechRail-Expected-Voice-Revision` 和
`SpeechRail-Expected-Model-Revision` 传递同代约束。匹配不到可用 voice、对应 operation 或
revision 时显式保持 `nil`，走服务端普通协商，不从 voice 名称、模型名或本地时间推断版本。

### Native Realtime 编排边界（current-only）

`SpeechRailApp` 的 `RealtimeASRClient` 只发当前契约：先发
`transcription_session.update`，再发 `input_audio_buffer.append/commit/clear`。语音助手会在本地
Responses 流中完成 LLM、历史、记忆、人设和工具编排，把句子放入本地 `pendingTTS` 队列，逐条发送
`speechrail.tts.create`；同一 WebSocket 同时只允许一个服务端 TTS render，收到 `response.done` 后才
提交下一句。

每个可验证的 caller-owned TTS request 都带当前 voice revision；Realtime 建连和会话内换音色都从
同一份 effective snapshot 重新解析。revision 不可用时不伪造 pin；服务端返回 revision conflict
时由调用方重新发现并决定是否继续，不自动改用最新音色。

服务端的 `input_audio_buffer.speech_started` 只是 VAD 事实。实时对讲模式由 `AssistantSession` 根据
播放状态清空本地播放队列并显式发送 `speechrail.tts.cancel`；服务端不自动替 App 做 barge-in。旧
`session.update`、`conversation.item.create`、`response.create/cancel` 和 `response.audio.*` 不会被
Native 或服务端翻译。

## 当前控制面 surface

`WindowGroup(id: "control-center")` 承载同一个 `AppModel` 下的三类一级 surface：

- 创作：配音台、音色创作、音色克隆、音色库、我的作品。音色创作保留 VoiceDesign 的描述、候选、试听和保存主线；音色克隆在应用内读服务端下发的提词稿、录制参考音频，经 `validate` 预检后注册成新音色（录音只落系统临时目录、应用收下即删，采集链关闭 AEC / AGC / 降噪，注册需要 `quality` 档位）；配音与试听通过统一的本机 Bearer 凭据接入服务，音色库提供服务端列表、详情、更新和删除，失败时保留用户输入并解释稳定错误。
- 会话：语音助手、会议助手、实时字幕。三类功能共享会话层的启停与资源占用边界，但各自拥有不同的来源、转写和本机记录；空闲时不持有麦克风、系统音频 tap 或播放引擎。
- 服务：本机服务总览、运行监控、模型管理、预检与诊断、开发者文档。总览解释健康状态和能力，监控读取 `/metrics`，模型管理通过 XPC Agent 调用锁定目录的 `model catalog/status/prepare`，预检显示可操作的失败原因；开发者文档把接入信息（服务地址 / 鉴权 / 运行档位 / 已发布能力）与 8 个主题的最小示例放进应用，事实仍以 `contracts/` 与 `docs/users/` 为准。

模型页明确区分“下载并校验”和“应用此档位”：前者执行逐文件大小/SHA-256 校验和原子发布，可显示 JSONL 进度并取消；后者才改变当前 profile。App 不直接访问模型源、不把本地路径或 hash 返回给页面，也不把模型下载放进请求路径。

### 语音助手的会话与回看布局

`AssistantView` 的 live/ready 状态可使用右侧 inspector；窗口进入 compact tier 时，右栏响应式收起，主内容仍保持可操作。`review` 状态是独立的记录阅读布局：只显示记录列表与转写正文，不再显示右侧 inspector；复制、继续、重命名、移除动作固定在正文底部，并通过 `ViewThatFits` 在一行或两行之间适配。继续会话从原记录预填人设、音色和会话偏好并建立新会话，原记录保持不变；移除记录仍是明确的破坏性操作。

这段是当前代码行为说明，不替代会话层技术方案；真实声学 AEC、双讲收敛和各种设备组合仍以音频文档中的未验收项为准。

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
- 档位选择器首次显示以服务返回的 active profile 为准；切档失败回滚后重新同步 active profile，避免把默认 `balanced` 当成用户选择。

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
