# SpeechRail

<p align="center">
  <img src="docs/assets/logo.png" alt="SpeechRail Logo" width="128" height="128" />
</p>

<p align="center">
  <strong>面向 Apple Silicon macOS 的本地优先共享 ASR / TTS 基础设施</strong><br>
  <em>一个本地服务 · OpenAI 兼容 HTTP 与 WebSocket · 有界 Worker 运行时</em>
</p>

<p align="center">
  <a href="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml"><img src="https://github.com/hrygo/SpeechRail/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI 状态" /></a>
  <a href="https://github.com/hrygo/SpeechRail/releases"><img src="https://img.shields.io/github/v/release/hrygo/SpeechRail?label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-000000.svg?logo=apple&logoColor=white" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python&logoColor=white" alt="Python 3.12" />
  <img src="https://img.shields.io/badge/API-OpenAI%20compatible-412991.svg?logo=openai" alt="OpenAI 兼容" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#当前能力">当前能力</a> ·
  <a href="#模型-profile">模型 profile</a> ·
  <a href="#文档导航">文档导航</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a> ·
  <a href="https://github.com/hrygo/SpeechRail/discussions">讨论区</a>
</p>

SpeechRail 是面向桌面 Agent、会议工具、内容生产流程和其他语音应用的
单用户本地语音服务。它在一个本地端点后托管共享 ASR/TTS Worker，并只暴露
经过 SpeechRail 验证的 OpenAI 兼容子集。

服务负责协议转换、模型适配、Worker 生命周期、资源准入和能力报告；调用方
负责麦克风采集、音频播放、会议数据、UI 与 LLM 编排。

> [!NOTE]
> `/readyz` 和成功的 smoke 请求只能确认服务就绪，
> 不代表普遍适用的质量、延迟或性能保证。

## 为什么选择 SpeechRail

SpeechRail 面向由多款本地客户端共享的一台 Apple Silicon Mac。它在同一个有界运行时中
管理模型执行和请求调度，让各应用无需各自加载语音模型，也无需重复实现 OpenAI 兼容适配层。

适合需要以下能力的场景：

- 普通 ASR/TTS 请求在本机处理；
- 多个桌面应用共用一个 HTTP/WebSocket 服务；
- 范围明确、可检查的 OpenAI 兼容接口；
- 可选的 Realtime ASR/TTS、会话级匿名分人或 MCP 接入。

## 当前能力

| 入口 | 能力 | 说明 |
|---|---|---|
| `GET /health`、`/readyz`、`/metrics` | 服务诊断 | 查看进程、子系统、就绪状态和指标。 |
| `POST /v1/audio/transcriptions` | 文件 ASR | OpenAI 兼容 multipart 输入；支持 `json`、`verbose_json`、`text`、`srt`、`vtt`，以及可选的 `diarized_json`。 |
| `POST /v1/audio/speech` | TTS | 流式输出 `mp3`、`opus`、`aac`、`flac`、`wav` 或原始 `pcm`；请从 `/v1/voices` 选择 `available=true` 的音色。 |
| `GET /v1/models`、`GET /v1/voices` | 能力发现 | 当前 profile 与可用音色的发现投影。 |
| `GET /v1/speechrail/capabilities`、`/v1/speechrail/voices*` | 安全能力发现 | `effective_capabilities_v1` 返回同一代有效能力快照；命名空间音色发现不返回来源正文，也不启动 worker。 |
| `WS /v1/realtime` | 实时 ASR/TTS | current-only 无状态 Speech Plane：转写 session wire、服务端语音事实、显式 `speechrail.tts.*`，以及可选的命名空间分人扩展。 |
| `/v1/jobs` | 异步任务元数据 | 可选的 owner-scoped 持久任务记录；调用方提供不透明引用，不传原始音频或转写文本。 |
| `speechrail-mcp` | Agent 接入 | 支持 `stdio` 或 `streamable-http` 的无状态 MCP 代理；它调用本地 REST 服务，不托管模型。 |

讲话人分离仅在当前 `balanced`、`quality` 或候选 `extreme` profile 的本地 CoreML 资源就绪时
可用。它只返回会话范围内的匿名标签，不识别人名，也不维护跨会话讲话人数据库。

仓库还包含 `macos/SpeechRailApp` SwiftUI macOS 控制面。它读取服务状态，
并将 profile/服务操作委托给现有 Python CLI；它不加载模型，也不替代用户级
`com.speechrail` LaunchAgent。它的语音助手、会议助手、实时字幕会话，以及音色克隆和
试听流程，只在用户主动启用对应功能期间采集或播放音频；会话 PCM 不落盘，文本与记录保存在
App 本机存储中。

## 范围与边界

SpeechRail 是语音运行时，不是完整的语音 Agent 应用。它不负责：

- SpeechRail 服务本身不负责麦克风采集、扬声器播放、会议管理或 UI；随附 App 只在明确启用的
  功能会话内提供这些客户端能力；
- LLM response、tool call 或应用级打断策略；
- 实名讲话人识别、声纹库或跨会话归属；
- 云端推理、多租户隔离、高可用或分布式队列。

Realtime 是唯一的公共 WebSocket 入口，仅实现 ASR/TTS 事件。调用方拥有 LLM、历史、工具、
播放队列和 barge-in 策略；SpeechRail 不翻译旧 Realtime 事件，也不提供 legacy wire。依赖未列出的
OpenAI 能力前，请先阅读对应契约。

## 环境要求

- 受管运行时仅支持 Apple Silicon Mac 和 macOS 26.0 或更高版本；Intel Mac 与 Ubuntu/Linux 不是支持目标。Linux 可用于平台无关的开发检查。
- 随附的 `SpeechRailApp` 同样以 macOS 26.0+、`arm64` 为目标。
- 源码开发和 Python 服务 CLI 使用 `>=3.12,<3.13`。
- 使用 [`uv`](https://docs.astral.sh/uv/) 管理依赖和环境。
- 本地安装流程及部分音频格式需要 `ffmpeg` 解码/转码。受管安装器会在隔离运行时中附带固定版本的
  `imageio-ffmpeg`，因此执行 `speechrail install` 不要求系统预装 `ffmpeg`。
- 模型 snapshot 与 vendor runtime 存放在仓库之外。

推理请求不会下载模型、读取远程音频 URL 或静默访问云端。显式的安装和运维
命令可能会供给本地制品；执行前请阅读对应运维指南。

## 快速开始

### 从 Release wheel 安装

从 [Releases](https://github.com/hrygo/SpeechRail/releases) 下载 wheel 与 `SHA256SUMS`，
先校验制品，再只用 `uv` 和 wheel 自带的 managed installer 安装，无需检出源码：

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
uvx --python 3.12 --from ./speechrail-*.whl \
  speechrail install \
  --preset balanced \
  --yes \
  --enable
```

wheel 提供 `speechrail install` 入口。它会暂存 release、准备并校验所选档位的模型制品、执行
preflight、原子切换 `runtime/current`，并在 `--enable` 下注册、启动 `com.speechrail`。
如果 wheel 版本与 installer 版本不一致，安装会拒绝执行，避免 installer 与它安装的代码版本漂移。
重复运行可升级现有安装；请先停止正在运行的服务，因为当端口 8201 正被占用时，installer 会拒绝替换
`runtime/current`。已校验的本地模型 snapshot 会复用，不会重新下载；命令会在开始前报告将要获取的内容。
`--from` glob 在所在目录中必须且只能匹配一个 `speechrail-*.whl`。推理请求不会下载模型。完整安装说明见
[安装与首次使用](docs/users/installing-speechrail.md)。

### 从仓库首装

如果全新的 Apple Silicon Mac 还需要安装前置依赖，可使用仓库提供的引导流程；它会安装前置依赖、准备
所选本地模型制品，并注册 `com.speechrail` LaunchAgent。该流程会执行外部设置操作，因此必须明确传入
`--yes` 确认：

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh --yes --preset balanced
```

受管流程会准备隔离运行时、校验所选本地制品，并注册用户级 `LaunchAgent`。
使用该入口前请阅读 [`speechrail-zero-setup`](.agents/skills/speechrail-zero-setup/SKILL.md)，了解磁盘需求、
profile 选择、模型校验和恢复行为。

[安装与首次使用指南](docs/users/installing-speechrail.md)说明各 Release 制品的用途、安装顺序和常见失败状态。
未签名 DMG 仅包含 App 控制面，不安装服务。

安装后检查服务状态，不要启动第二个实例：

```bash
SPEECHRAIL_APP_HOME="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_CLI="$SPEECHRAIL_APP_HOME/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" service status --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" diagnose --app-home "$SPEECHRAIL_APP_HOME"
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
```

### 源码开发

此路径适合确定性的契约和应用开发。即使没有真实模型 snapshot，也可以启动
HTTP 接口；在配置本地 ASR/TTS runtime 前，推理请求会返回
`503 backend_not_ready`。

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
uv sync --extra dev
cp configs/speechrail.example.env .env
chmod 600 .env
uv run speechrail serve
```

如需真实本地推理，请在私有 `.env` 中填写文档要求的 ASR/TTS snapshot 与解释器
路径，并在启动服务前运行 `speechrail service preflight`。snapshot、`.env`、
音频、日志和 benchmark 原始数据必须留在仓库之外。

常用只读检查：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
uv run speechrail diagnose
```

`/health` 报告进程和子系统状态；`/readyz` 报告 ASR/TTS runtime 是否可以
接受推理。就绪成功不代表模型质量或性能验收通过。

## OpenAI 兼容调用示例

标准 OpenAI Python 客户端只需修改 `base_url` 即可访问文档声明的 REST 语音子集。默认
loopback 访问使用占位 key；只有在有意将服务暴露到 loopback 之外时才使用真实 Bearer key。
Realtime 是 current-only 协议，完整语音助手由调用方编排。

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local",
)

with open("speech.wav", "rb") as audio:
    result = client.audio.transcriptions.create(
        model="whisper-1",
        file=audio,
        response_format="verbose_json",
    )
    print(result.text)

speech = client.audio.speech.create(
    model="tts-1",
    voice="serena",
    input="SpeechRail 正在本地运行。",
    response_format="wav",
)
speech.stream_to_file("speech-output.wav")
```

Realtime 客户端连接：

```text
ws://127.0.0.1:8201/v1/realtime
```

当前 Realtime 为 current-only 语义：`delta` partial 只能追加；可选的 `snapshot` 扩展按同一 item
的单调递增 `revision` 替换完整文本。`partial_mode` 与 `chunk_duration_ms` 必须先收到
`transcription_session.updated` 的实际回显，再发送首个 PCM；首个 PCM 后不能修改。具体事件顺序见
[`contracts/realtime-openai.md`](contracts/realtime-openai.md)。
SDK、cURL、Sona、Open-WebUI、LiveKit/Pipecat 和 OpenClaw 示例见
[`docs/users/integrations.md`](docs/users/integrations.md)。

## 模型 profile

不同 profile 共享公共 API 形状，但对外声明的能力取决于当前 catalog selection。
profile 枚举包含候选 `extreme`；其正式启用仍受质量、资源和延迟证据门槛限制。BF16 权重类型
本身不代表质量更高。

| Profile | ASR | TTS | 分人与音色能力 |
|---|---|---|---|
| `light` | `asr-0.6b-q8` | `tts-0.6b-custom-q8` | 无 aligner、无分人；固定 CustomVoice 角色。 |
| `balanced` | `asr-1.7b-q8` | `tts-0.6b-custom-q8` | `aligner-q8`，可选匿名分人；固定 CustomVoice 角色。 |
| `quality` | `asr-1.7b-q8` | `tts-1.7b-design-q8` + `tts-1.7b-base-q8` | `aligner-bf16`，可选匿名分人、VoiceDesign 试听/设计和质量门控 Base 克隆。 |
| `extreme`（候选） | `asr-1.7b-bf16` | `tts-1.7b-design-bf16` + `tts-1.7b-base-bf16` | 复用 `aligner-bf16`；候选 catalog 配置了分人与两种 TTS 能力；质量、资源和延迟证据仍待补齐。 |

当前活动 profile 的 ASR/TTS 权重均为 8-bit；`quality` 使用 `aligner-bf16`，候选 `extreme` 的权重与 aligner 为 bf16。
`quality` 与候选 `extreme` 将 VoiceDesign 和 Base 作为独立 TTS capability lane，可双 worker 常驻，
不同 lane 可并发、同一 lane 仍串行；能力组仍会在配置的空闲冷却后关闭 worker，并按需惰性恢复。

![四档模型与 TTS capability 关系图](docs/architecture/diagrams/four-tier-model-architecture.svg)

上图展示 profile 路由、模型共享、TTS capability 与共享资源/生命周期边界；旧版三档图仅作历史基线。

CLI 的 `setup` 会根据物理内存给出起始建议，但这不是硬件保证。使用 CLI 查看
或切换受管 selection：

```bash
SPEECHRAIL_APP_HOME="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_CLI="$SPEECHRAIL_APP_HOME/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" profile list --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" profile status --app-home "$SPEECHRAIL_APP_HOME"
"$SPEECHRAIL_CLI" profile apply balanced --app-home "$SPEECHRAIL_APP_HOME" --yes
"$SPEECHRAIL_CLI" profile rollback --app-home "$SPEECHRAIL_APP_HOME" --yes
```

请先从 `/v1/voices` 选择音色，不要假设已注册的自定义音色在所有 profile 上都
可用。VoiceDesign 试听/设计和 Base 克隆能力由当前有效能力决定；候选 catalog 为
`quality` 和 `extreme` 配置了这些能力，但 Extreme 正式启用所需的质量、资源与延迟证据仍待补齐。
详见
[`docs/users/api-contract.md`](docs/users/api-contract.md)。

## 安全与数据处理

- 默认绑定 `127.0.0.1`；loopback 开发不需要 API key。
- 任何非 loopback 暴露都必须配置 `SPEECHRAIL_API_KEY`、Bearer 鉴权和明确的
  origin 策略。不要把 key 放进 URL query。
- 普通 ASR/TTS 请求在本地处理，不发送到云端。显式的音色注册与克隆是持久化
  能力，可能在仓库之外写入受管 custom voice 数据。
- 日志、fixture 和报告不得包含凭据、Authorization header、原始音频、Base64、
  完整 prompt、完整转写、embedding、姓名或绝对模型路径。

## 文档导航

| 需求 | 推荐入口 |
|---|---|
| 安装与首次运行 | [`docs/users/installing-speechrail.md`](docs/users/installing-speechrail.md) |
| 文档总览 | [`docs/README.md`](docs/README.md) |
| API 与客户端接入 | [`docs/users/README.md`](docs/users/README.md)、[`docs/users/api-contract.md`](docs/users/api-contract.md)、[`contracts/openapi.yaml`](contracts/openapi.yaml) |
| Realtime 协议 | [`contracts/realtime-openai.md`](contracts/realtime-openai.md) |
| MCP Agent 接入 | [`docs/users/mcp-agent-integration.md`](docs/users/mcp-agent-integration.md) |
| 运维与回滚 | [`docs/operations/README.md`](docs/operations/README.md)、[`docs/operations/operations-runbook.md`](docs/operations/operations-runbook.md) |
| 开发与测试 | [`docs/developers/README.md`](docs/developers/README.md)、[`docs/developers/testing-acceptance.md`](docs/developers/testing-acceptance.md) |
| macOS 控制面 | [`docs/developers/macos-app-development.md`](docs/developers/macos-app-development.md)、[`docs/developers/macos-app-release.md`](docs/developers/macos-app-release.md) |
| 架构与边界 | [`docs/architecture/README.md`](docs/architecture/README.md)、[`docs/architecture/current-boundaries.md`](docs/architecture/current-boundaries.md)、[`docs/decisions/README.md`](docs/decisions/README.md) |
| 版本历史 | [`CHANGELOG.md`](CHANGELOG.md) |

## 参与贡献

提交 Pull Request 前，请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)，并运行确定性质量门禁：

```bash
uv sync --extra dev
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

CI 还会构建 wheel 并测试 SwiftUI macOS 控制面。Bug 报告和功能请求请使用仓库的 issue 模板；
问题与集成讨论请前往 [GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions)。
参与项目时也请遵守 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。

## 支持与安全

使用问题和故障排查请先查看 [`SUPPORT.md`](SUPPORT.md) 或前往
[GitHub Discussions](https://github.com/hrygo/SpeechRail/discussions)。确认的 bug 请使用
[issue 模板](https://github.com/hrygo/SpeechRail/issues/new/choose)。

安全漏洞请按 [`SECURITY.md`](SECURITY.md) 中的流程报告，不要公开创建 issue。

## 许可证

SpeechRail 采用 [MIT License](LICENSE) 授权。
