# SpeechRail Agent 指南

本文件只保留项目级、稳定且不能低成本从代码推断出的约束与导航。当前行为以代码、测试、公共契约和实测为准；详细设计、运行手册与历史证据放在 `docs/`，不要把本文件扩写成能力百科。

## 作用域与任务边界

- 本文件适用于仓库根目录。`native/diarization/.build/checkouts/FluidAudio/AGENTS.md` 仅约束该第三方 checkout，不把它的内容当作 SpeechRail 规则，也不要在无明确授权时修改生成的 checkout。
- 用户的当前请求决定写入范围。回答、解释、审查和诊断默认只读；修改、构建、部署、发布、发送消息、下载模型或改变运行态不因“顺手验证”而自动获得授权。
- 只修改完成任务必需的文件，保留未提交改动和并行改动；遇到同文件无法安全分离的改动先报告。

## 事实来源

按以下顺序解决冲突：

1. 当前代码、测试与实际运行结果；
2. `contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/diarization/v1/`；
3. 标记为 `active` 的 `docs/` 文档与 ADR；
4. `docs/archive/` 仅用于历史追溯，不能证明当前能力。

报告必须区分“契约声明”“当前实测”“历史记录”和“推断”。`/readyz=200`、配置存在、计划完成或单次 smoke 通过，都不等于模型质量、性能、长时稳定性或发布验收通过。

## 项目定位与公共边界

SpeechRail 是面向单人 Apple Silicon Mac 的本地共享 ASR/TTS 服务，为 OpenAI SDK、Sona、LiveKit/Pipecat、Open-WebUI、OpenClaw 等客户端提供协议兼容的语音入口。服务负责协议转换、模型适配、worker 生命周期、资源准入和能力诊断；调用方负责麦克风、播放、会议/UI、业务数据库与 LLM 编排。

当前公共入口包括：

- REST：`/health`、`/readyz`、`/metrics`、`/v1/models`、`/v1/audio/transcriptions`、`/v1/audio/speech`、`/v1/voices`，以及可选的 owner-scoped `/v1/jobs`。
- WebSocket：唯一的 `/v1/realtime`，只实现 OpenAI Realtime 的 ASR/TTS 子集与 SpeechRail 命名空间扩展，不承载 LLM response、tool call、播放、会议或应用级打断策略。
- `speechrail-mcp`：无状态 REST 代理，支持 `stdio` 与 `streamable-http`；它不导入 FastAPI 应用、不加载模型，Realtime 仍直接使用 `/v1/realtime`。
- `macos/SpeechRailApp`：SwiftUI 控制面，通过受约束的 XPC 委托现有 Python CLI 和唯一的 `com.speechrail` user `LaunchAgent`；不采集/播放音频、不加载模型、不直接执行 `launchctl`。

## 必须保持的约束

- Python 固定为 `>=3.12,<3.13`，使用 `uv` 与 PEP 621；运行目标为 macOS Apple Silicon，原生控制面 deployment target 为 macOS 14.0。
- 默认只绑定 loopback。非 loopback 暴露必须配置 `SPEECHRAIL_API_KEY`、Bearer 鉴权和明确的 origin 策略；禁止把 key 放在 URL query 中。
- 请求路径不得下载模型、读取远程音频 URL 或静默访问网络。模型 snapshot、vendor Python、私有 `.env`、音频、日志、custom voice 数据和 benchmark 原始制品放在仓库外。
- 日志、fixture 与报告不得记录 API key、`Authorization`、原始音频、Base64、完整 prompt、完整转写、embedding、实名 speaker 或绝对模型路径。
- 一次只运行一个 SpeechRail 服务和一个 ASGI worker；不得复制模型进程来提高吞吐。batch ASR 与 streaming ASR 不作为同机并行产品场景，模式冲突稳定返回 `backend_busy`。
- 通用重计算重叠由 `SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto` 根据声明的 `*_RESIDENT_BYTES` 与 `max(4 GiB, 物理内存 // 2)` 预算判定；任一启用组件缺少非零峰值或总量超预算时必须 fail-closed 串行。Quality 额外允许独立的 VoiceDesign∥Base TTS capability lane 并发，同一 lane 仍串行，Light/Balanced 与未知 lane 保持单 worker；ASR∥ASR 仍受共享 worker 约束，不复制进程。
- 三档共享 API 形状、worker 协议和调度架构，但必须按活动档位如实发布能力：`light` 无 aligner/分人；`balanced` 使用 `aligner-q8` 并可分人；`quality` 使用 `aligner-bf16` 并可分人。当前活动 ASR/TTS 权重均为 8-bit；Quality 同时管理 VoiceDesign（`tts-1.7b-design-q8`）与 Base（`tts-1.7b-base-q8`）两个独立 TTS capability worker，允许双常驻、跨 lane 并发，并在配置的空闲冷却后 trim/close、下次请求惰性恢复；词级时间戳由 ASR 原生提供，不依赖 aligner。
- 生产分人运行时为 FluidAudio CoreML FP16 worker，并只输出 session-scoped 匿名 label；不管理实名、声纹库、跨会话身份、持久化 PCM 或 embedding。`gpt-4o-transcribe-diarize` 只在分人档位且 profile ready 时声明。
- 公共错误使用稳定 envelope 并包含 request ID；输入在 API 边界校验，vendor 输出在 adapter 边界校验。破坏性公共变更进入 `/v2` 并提供迁移说明，兼容 alias 必须有明确废弃计划。

## 每次任务先做

1. 阅读本文件和任务对应的入口文档；执行 `git status --short`、`git log -5 --oneline`，确认分支、未提交和并行改动。
2. 判断任务是只读、代码/文档修改、契约变更还是运行态操作，明确写入范围、公共影响、运行态影响和回退方式。
3. 先查当前实现、契约、测试与配置；公共行为变更先补失败的契约或回归测试，再实现。
4. 不替用户下载/加载/卸载模型，不把真实配置、音频、日志、benchmark 原始数据或 secrets 写入仓库。
5. 同一文件的多个 edit 必须串行；并行工作只能使用互不重叠的写入范围，不得用全文件覆盖掩盖他人改动。

## 代码与文档地图

| 路径 | 责任 | 相关事实来源 |
|---|---|---|
| `src/speechrail/app.py` | FastAPI 组合根、middleware、lifespan、路由组装 | `contracts/`、`application/` |
| `src/speechrail/application/` | 跨传输用例、Realtime、音频/TTS/分人交付 | `domain/ports.py` |
| `src/speechrail/domain/` | vendor-neutral 类型、ports、timeline 与 attribution ledger | 公共契约 |
| `src/speechrail/backends/` | Qwen3 ASR/TTS 适配器、VAD、FluidAudio CoreML 分人适配器 | 对应 port 与 worker 协议 |
| `src/speechrail/runtime/` | 队列、Resource Governor、worker IPC、jobs、准入 | 资源与超时配置 |
| `src/speechrail/realtime/` | Realtime 状态机与 speech admission | `contracts/realtime-openai.md` |
| `src/speechrail/config/` | settings、catalog、profile selection | `configs/`、`src/speechrail/assets/` |
| `src/speechrail/service/` | managed runtime、LaunchAgent、profile/preflight | `docs/operations/` |
| `src/speechrail/mcp/` | stateless MCP server/client/tools | `docs/users/mcp-agent-integration.md` |
| `macos/SpeechRailApp/` | SwiftUI/XPC 控制面与本地 fake transport 测试 | `docs/developers/macos-app-*.md` |
| `contracts/` | OpenAPI、Realtime、diarization schema | 任何公共接口修改前 |
| `tests/` | fake backend、契约、安全、边界与运行时回归 | `docs/developers/testing-acceptance.md` |

入口文档：架构 `docs/architecture/README.md`；用户与 API `docs/users/README.md`；开发与测试 `docs/developers/README.md`；运维 `docs/operations/README.md`；ADR `docs/decisions/README.md`；历史 `docs/archive/README.md`。

## 开发与验证

源代码开发使用：

```bash
uv sync --extra dev
uv run speechrail serve
```

没有真实 backend 时服务可以启动，推理入口应返回 `503 backend_not_ready`；确定性测试使用 fake backend，不下载模型、不访问云端、不使用真实音频。

代码、测试、契约或跨模块变更完成后执行完整 gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

服务、profile 或运行时变更还需按授权执行：

```bash
plutil -lint deploy/macos/com.speechrail.plist.example
uv run speechrail service --help
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
```

macOS 控制面变更补充运行 `scripts/macos_app_build.sh --configuration Debug`、`scripts/macos_app_test.sh` 和对应的 `plutil` 检查。健康端点通过后，只有在本机已有外部 runtime 且任务明确授权运行态操作时，才使用非敏感短音频完成公共 ASR/TTS smoke；性能/质量测试遵循 `.agents/skills/speechrail-perf-benchmark/SKILL.md`，发布遵循 `.agents/skills/speechrail-release/SKILL.md`。

## 服务、档位与发布操作

- macOS 常驻服务只使用当前用户的 `LaunchAgent` 和已审查的 `speechrail service`/installer 流程。执行启停、替换或回滚前确认 app home、label `com.speechrail`、PID、端口与 active runtime；禁止 `pkill`、模糊进程匹配和手工 plist 修改。
- `speechrail setup`/`profile apply` 由 profile selection、受管制品、preflight、public API smoke 和 rollback 共同决定结果；失败必须保持原服务配置或明确报告状态，不把“命令返回”当作成功。
- wheel 替换必须先停旧实例，在隔离 release 目录完成 preflight，再原子切换 `runtime/current`。保留上一 release、私有配置、selection 和模型，便于回退；`disable`/`uninstall` 不等于版本回退。
- 真实签名、notarization、外部发布、远端分支和删除操作都需要明确授权；不提交 `.env`、模型、音频、日志、benchmark 原始数据、构建产物或凭据。

## 文档与 Git 交付

- 根 `README.md` 只保留价值、当前公共能力、快速开始和文档入口；实现细节、基准与操作步骤进入专业文档。除非用户明确要求，不因发布、接口或普通实现变化自动同步 `README.zh-CN.md`。
- OpenAPI/WebSocket 行为变化必须同步契约、测试与用户文档；正式文档 front matter 的 `version`/`date` 仅在正文实质变化时更新；归档材料不改写成当前承诺。
- 持久化命令使用可移植的原生命令，不写入本机 wrapper、RTK 缓存绝对路径、真实配置值或秘密。
- 一个 commit 表达一个逻辑主题，消息使用 `<type>: <why>`；提交前检查 staged diff、`git diff --staged --check` 和敏感字段。不 force-push，不覆盖他人分支。
- 合并到受保护 `main`/`master` 前先确认远程保护规则和线性历史要求；需要线性历史时使用 rebase 与 `--ff-only`/合适的 fast-forward 策略，不默认制造 merge commit。

结束时报告：结果、实际改动、实测与验证时间、运行态动作、未验证事项/风险、并行改动和回退方式。结论范围必须与证据一致。
