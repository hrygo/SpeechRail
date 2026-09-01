# SpeechRail Agent 指南

> 本文件是 SpeechRail Agent 的入口规范，不是功能设计文档。它规定如何建立上下文、
> 选择开发/运维/测试模式、保护并行工作和给出可复核的交接结果。详细事实以当前代码、
> `contracts/` 和状态为 active 的文档为准。

## Agent 启动协议

收到任务后先完成以下步骤，再决定是否修改文件：

1. 读取本文件和任务对应的入口文档。
2. 执行 `git status --short`、`git log -5 --oneline`，确认分支、未提交改动和并行工作。
3. 把任务分类为开发、运维、测试、客户端集成或审查，并确定明确的写入范围。
4. 区分“当前代码已实现”“契约已定义但真实后端未验收”和“历史计划/目标设计”。
5. 先做只读检查，再执行有副作用的操作；操作前记录目标、风险和回退方式。
6. 完成后运行与风险相称的验证，并报告实测结果、未验证项和未触碰的并行改动。

如果当前环境提供 `codebase-memory`，结构探索优先使用 `list_projects`/`index_status`、
`get_architecture`、`search_graph`、`trace_path` 和 `get_code_snippet`；字符串、配置、
文档和日志搜索使用 `rg`。图谱覆盖是最佳努力信号，不能替代对标记为 partial 的源码
直接核对。

## 语言与沟通

- Agent 沟通、任务摘要、注释和项目文档默认使用简洁中文。
- 命令、路径、配置键、API 字段、协议事件、错误码、模型 ID、类名和函数名保留原文。
- 外部协议名和厂商名保持准确；用中文解释，不翻译标识符本身。
- 报告必须区分“已实测”“文档规定”“历史记录”和“推断”，不能把计划写成完成事实。

## 项目范围

SpeechRail 是供 QwenPaw、`voice-realtime`、Hermes Agent 及未来应用共享的
独立本地语音识别服务。它负责对外 ASR API、运行时生命周期、模型适配器、
队列、认证、可观测性和兼容性边界。

它不负责麦克风、扬声器、TTS、会议持久化、UI 状态、LM Studio 对话编排或
应用专属提示词；这些职责属于调用方应用。

## 系统地图

### 请求与运行时数据流

```text
QwenPaw / OpenAI SDK / 应用客户端
          │ HTTP REST 或 WebSocket
          ▼
FastAPI app（认证、request ID、输入校验、协议状态机、格式化）
          │
          ├─ REST 上传：有界读取 → 固定 ffmpeg → 16 kHz/单声道/PCM16
          ├─ Realtime：事件状态机 → PCM/文本边界 → Resource Governor
          └─ Jobs：owner-scoped 元数据 → 受信任 JobProcessor（仅显式注入时）
          │
          ├─ BatchTranscriber / RealtimeAsrFactory / SpeechSynthesizer
          ├─ 可选 DiarizationEngine（仅匿名 session state）
          └─ Qwen3 ASR/TTS worker 或外部 WLK streaming endpoint
```

主进程负责公共边界和调度；Qwen3/TTS 的模型 SDK 与权重留在隔离的专用 Python worker，
WLK 是明确配置的外部 sidecar。当前可选 NeMo diarization adapter 是例外：它由
`diarization` extra 提供依赖，并在服务进程中按需加载仓库外模型；它仍必须保持有界、
匿名且不进入 domain。请求路径不下载模型、不读取远程音频 URL，默认不持久化音频、PCM、
embedding 或完整转写正文。

### 目录职责

| 路径 | 责任 | 修改时先看 |
|---|---|---|
| `src/speechrail/__main__.py` | `speechrail` CLI，读取 `Settings` 并启动 Uvicorn | `pyproject.toml` |
| `src/speechrail/app.py` | FastAPI 路由、认证、上传解码、生命周期、WS 编排 | `contracts/` |
| `src/speechrail/config/` | `SPEECHRAIL_*` 环境配置和组合校验 | `configs/speechrail.example.env` |
| `src/speechrail/domain/` | vendor-neutral 结果、请求、事件和 port | 公共契约 |
| `src/speechrail/backends/` | Qwen3 ASR/TTS、WLK、NeMo Sortformer 适配器 | `domain/ports.py` |
| `src/speechrail/runtime/` | admission queue、Resource Governor、jobs、worker IPC、diarization 协调 | 资源限制 |
| `src/speechrail/realtime/` | Realtime v1/v2 状态机和事件生命周期 | `contracts/realtime*.md` |
| `src/speechrail/compatibility/` | OpenAI/WLK 等窄兼容呈现和归一化 | 兼容边界 |
| `contracts/` | OpenAPI 与 WebSocket 事实来源 | 任何公共接口变更前 |
| `tests/` | fake backend、契约、安全、边界和协议回归 | `docs/07-testing-acceptance.md` |
| `examples/` | 不含凭据的 curl、OpenAI SDK、Realtime、QwenPaw 示例 | `docs/04-integrations.md` |
| `deploy/macos/` | `launchd` 模板；不是自动安装器 | `docs/11-operations-runbook.md` |
| `docs/` | 产品、架构、API、开发、运维、迁移和 ADR | `docs/README.md` |

### 当前能力矩阵

| 能力 | 当前结论 | 不应作出的承诺 |
|---|---|---|
| `POST /v1/audio/transcriptions` | Qwen3-ASR batch REST 可用；配置外部 runtime 后可真实推理 | 不要绕过公共 API 直接调用 worker |
| `GET /health`、`/readyz`、`/v1/models` | 可用的进程、入口配置和模型清单检查 | `readyz=200` 不等于真实音频质量已验收 |
| `POST /v1/audio/speech` | 契约和隔离 TTS worker 已有；依赖单独外部 TTS runtime | 不要把 TTS runtime 当作 ASR 前置条件 |
| `POST/GET/DELETE /v1/jobs` | 可选 owner-scoped 元数据 spool；需受信任 `JobProcessor` 才会执行 | `input_ref` 默认不是路径/URL resolver，不会自动读取音频 |
| `WS /v1/realtime` | 收集 PCM，`commit` 后一次 batch final | 不是持续 partial streaming |
| `WS /v2/realtime` | ASR/TTS 状态机、背压和可选 WLK/diarization 部分实现 | 不是 LLM 对话、播放或会议状态；真实 backend 仍须 smoke |
| `WS /asr` | legacy 兼容骨架，当前只保留有限 config/EOF 行为 | 不具备 WLK parity，不得暴露到 LAN/公网 |
| `diarization` profile | 可选匿名 speaker label、overlap 和 finalize remap | 不提供实名身份、声纹库或跨会议持久身份 |
| QwenPaw `whisper_api` | 使用标准 OpenAI-compatible `/v1` 路径；`.webm`/`video/webm` 需兼容 | 不要修改聊天模型 endpoint 来排查 STT |

目标设计、实施计划和历史审查材料只说明意图；以当前代码、契约和能力矩阵为准。

## 不可妥协的边界

- Python 版本必须满足 `>=3.12,<3.13`；使用 `uv` 和 PEP 621 元数据。
- 对外文件转写 API 使用 OpenAI-compatible 的
  `/v1/audio/transcriptions`。
- 当前 `/v1/realtime` 是 commit 后 batch 转写协议；新的流式集成目标使用
  `/v2/realtime`，但必须先通过真实 backend 和客户端 smoke。
- `/asr` 只是 loopback 下的 legacy 兼容骨架；它不提供 WLK parity，不能替代旧客户端的
  真实转写路径。
- 默认绑定 loopback。绑定 LAN 时必须启用 API key，并明确配置允许的
  origin 策略。
- 模型快照使用外部绝对路径。请求处理期间不得下载模型或静默访问网络。
- 音频默认只在请求期间存在。不得持久化源音频，也不得在日志中记录原始
  转写正文。
- 对外模型名与具体模型实现解耦。`qwen3-asr-1.7b` 是后端 profile，不能
  因此重命名服务或 API。
- 不要把 `voice-realtime` 的会议、UI、TTS、LM Studio 或 PostgreSQL 职责
  移入本仓库。

## 契约规则

- 实现前先以 `contracts/openapi.yaml` 和 realtime 事件契约为准。
- 所有对外 endpoint 使用统一且稳定的错误 envelope，并包含 request ID。
- 优先采用向后兼容的增量变更。破坏性变更必须进入 `/v2`，并附带迁移说明；
  兼容 alias 必须明确废弃日期。
- 在 API 边界校验外部输入；在适配器中校验厂商响应，再生成领域事件。
- `/v1/audio/transcriptions` 遵循 OpenAI-compatible multipart 契约。支持
  `flac`、`mp3`、`mp4`、`mpeg`、`mpga`、`m4a`、`ogg`、`wav` 和 `webm`；
  `Content-Type` 与 filename 只是格式提示，不是内容真实性证明。必须使用
  固定的 `ffmpeg` 调用校验并解码字节，不能在 MIME gate 阶段拒绝 QwenPaw
  的 `video/webm` 等标准容器。
- QwenPaw 集成应通过标准 OpenAI client path，使用 SpeechRail 的 `/v1`
  `base_url` 和已登记的 `whisper-1` alias。兼容性问题应根据实际 multipart
  请求和稳定错误 envelope 诊断，不要依据客户端对 MIME 的假设判断。

### Realtime 约束

- `contracts/realtime.md` 描述当前 `/v1/realtime`：
  `transcription_session.update → append* → commit → completed → close`，不产生 delta。
- `contracts/realtime-v2.md` 描述 `/v2/realtime` 的 ASR/TTS 状态机、公共事件 envelope、
  `sequence`、背压、取消和不可恢复 session 规则；它是部分实现，真实 backend 验收另算。
- v2 只承载 ASR/TTS，不承载 LLM response、tool call、播放、会议和应用打断策略。
- 断线后创建新 session/source epoch；服务端不保存、不重放旧音频或事件。

### Diarization 约束

- `session.update.session.diarization` 是 transcription session 的可选能力；未启用时维持
  既有事件形状，启用但没有 profile 时必须返回 `diarization_not_available`。
- 输出只包含 session-scoped 的匿名 `spk_*` label、置信度、重叠信息和 finalize remap。
  `group_id` 只用于有界匿名声学状态，不得承载姓名、邮箱、手机号或凭据。
- `voice-realtime` 负责 `speaker_id → display_name`、人工修正、事务性 remap、会议和数据库。
  SpeechRail 不加载 CAM++、不管理声纹库、不保存 PCM/embedding、不伪造单一 speaker。

## 配置与运行前提

项目固定使用 Python `>=3.12,<3.13`、`uv`、PEP 621。主服务使用仓库 `.venv`；真实
Qwen3/TTS vendor runtime 使用外部专用 Python，diarization 依赖由 `diarization` extra
提供并由当前 adapter 在服务进程中按需加载模型。配置入口是被 Git 忽略的 `.env`，
示例是 `configs/speechrail.example.env`，不可提交真实值。

| 配置类别 | 关键键 | 规则 |
|---|---|---|
| 服务 | `SPEECHRAIL_HOST`、`SPEECHRAIL_PORT` | 默认 `127.0.0.1:8201`；不要与旧 WLK `8001` 混用 |
| ASR runtime | `SPEECHRAIL_QWEN3_MODEL_DIR`、`SPEECHRAIL_QWEN3_PYTHON` | 必须同时配置；均为仓库外绝对路径/可执行文件 |
| TTS runtime | `SPEECHRAIL_QWEN3_TTS_MODEL_DIR`、`SPEECHRAIL_QWEN3_TTS_PYTHON` | 可选；两条路径同时存在才启动 TTS worker |
| diarization | `SPEECHRAIL_DIARIZATION_MODEL_PATH`、`SPEECHRAIL_DIARIZATION_MAX_BUFFER_BYTES` | 可选；模型路径必须是仓库外绝对路径；未通过真实质量/资源门前不进默认配置 |
| 外部 streaming | `SPEECHRAIL_WLK_STREAMING_URL` | 只连接已运行的 credential-free `ws(s)` endpoint；SpeechRail 不启动 sidecar |
| 模型身份 | `SPEECHRAIL_MODEL_ID`、`SPEECHRAIL_COMPATIBILITY_MODEL_IDS` | 新配置使用 canonical ID；alias 只做兼容 |
| 设备与精度 | `SPEECHRAIL_DEVICE`、`SPEECHRAIL_DTYPE` | `mps/float16` 或 `cpu/float32`；禁止静默 CPU fallback |
| 限制 | `SPEECHRAIL_MAX_QUEUE_SIZE`、`SPEECHRAIL_MAX_UPLOAD_BYTES`、`SPEECHRAIL_MAX_REALTIME_*` | 必须有界；不要通过多 ASGI worker 复制模型 |
| 调度 | `SPEECHRAIL_RUNTIME_*`、`SPEECHRAIL_REALTIME_RESERVED_CAPACITY` | realtime 预留容量，batch 使用剩余容量并受 aging/队列限制 |
| 超时 | `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | worker/inference deadline；失败要映射稳定错误 |
| Jobs | `SPEECHRAIL_JOB_SPOOL_DIR`、`SPEECHRAIL_JOB_POLL_SECONDS` | 可选、仓库外绝对目录；只保存 opaque reference 和状态 |
| 安全 | `SPEECHRAIL_API_KEY`、`SPEECHRAIL_ALLOWED_ORIGINS` | 非 loopback 必须有 key；当前 CORS/legacy auth 能力不足，不能直接公网暴露 |
| 开关 | `SPEECHRAIL_ALLOW_MODEL_DOWNLOADS`、`SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS` | 必须为 `false`；服务不下载模型 |
| 测试模拟 | `SPEECHRAIL_BACKEND_READY` | 仅无真实 backend 的契约测试使用；真实部署不得用它掩盖配置问题 |

`SPEECHRAIL_MAX_AUDIO_SECONDS` 当前是配置字段，但尚未在解码后强制时长拒绝；不能把它
当作已启用的容量安全边界。上传字节上限、Realtime 帧/缓存上限和 worker timeout 也不能
替代真实性能、峰值内存与长音频基准。

## 开发模式

### 启动开发环境

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
cp configs/speechrail.example.env .env
# 仅在需要真实模型时，填写仓库外 snapshot 和专用 Python 的绝对路径。
uv run speechrail
```

未配置真实模型时，服务仍可启动，推理入口应返回 `503 backend_not_ready`；确定性测试
使用 fake backend，不应下载模型。真实服务一次只运行一个 SpeechRail 进程、一个 ASGI
worker 和每个 profile 一个隔离 worker。

### 变更流程

1. 先锁定 `contracts/`、实现文件、测试和文档的最小写入范围。
2. 公共行为先写失败的契约/回归测试，再做最小实现；适配器边界校验 vendor 响应。
3. 不把模型 SDK、会议业务、UI、数据库或客户端 prompt 引入公共 domain。
4. 更新受影响的 README、`docs/`、OpenAPI/WebSocket 契约和必要的 `CHANGELOG.md`。
5. 按单一主题检查 staged diff；不暂存 `.env`、模型、音频、缓存、日志或外部 runtime。
6. 使用短生命周期 feature branch/worktree；共享工作树中发现同文件并行改动时，只做不
   重叠的 hunk，无法安全分离就停下并报告，不覆盖或回退他人修改。

## 运维模式

### 启动与健康检查

```bash
cd <path-to-SpeechRail>
uv sync --extra dev
uv run speechrail
```

另开终端执行：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
```

`/health` 是进程存活信息；`/readyz` 是推理入口配置/就绪信息；`/v1/models` 是公共
模型身份清单。三者为 200 后，仍须使用操作者拥有的非敏感短音频完成 REST smoke，确认
HTTP 200、非空文本和 `X-Request-ID`。

前台服务使用 `Ctrl-C` 停止。不要用 `pkill` 或模糊进程匹配杀掉未知服务；先确认端口、
PID、工作目录和启动者。macOS 常驻服务只使用已审查的 `deploy/macos/` `LaunchAgent`
模板；不要把 MPS worker 安装成 `LaunchDaemon`。

### macOS `launchd`

详细步骤见 `docs/11-operations-runbook.md`。执行 `bootstrap`、`kickstart` 或 `bootout`
前，先确认 plist、label、项目路径、日志路径和当前用户；所有 `<...>` 占位符必须替换
为本机值，不能把本机路径回写到项目文档。

```bash
plutil -lint deploy/macos/com.speechrail.plist.example
launchctl print "gui/$(id -u)/com.speechrail"
```

停用常驻服务只针对已确认的 `com.speechrail` label；保留可回退的 plist、`.env` 和模型
snapshot，不删除外部资源。

### 运维边界

- 默认只监听 loopback。非 loopback 需要 API key；v2 LAN 暴露还必须有 TLS、WebSocket
  `Origin` allowlist、HTTP CORS、网段策略和限速。
- 当前 `/asr` 不具备认证和真实 WLK parity；不得暴露到 LAN/公网，也不得用它替代旧 WLK。
- `SPEECHRAIL_WLK_STREAMING_URL`、TTS 和 diarization 都是外部/可选 profile；SpeechRail
  不下载、安装、启动或移动这些 runtime/model。
- 升级按可回退版本目录/commit 执行：先测试和真实 smoke，再切换服务；不要覆盖旧 `.env`
  和 snapshot，不使用破坏性 Git 命令回滚配置。

## 测试模式

### 自动化测试

测试默认使用 fake backend、构造 PCM 和脱敏 fixture；不加载真实模型、不访问网络、不写入
真实音频。应覆盖 model alias、统一错误 envelope、request ID、上传/帧/缓存限制、队列与
Resource Governor、worker frame 协议、snapshot preflight、REST 响应格式、Realtime 事件
顺序、cancel/背压、legacy 边界以及 diarization fail-closed。

行为变更先跑针对性测试：

```bash
uv run --extra dev pytest tests/test_transcription_api.py -q --no-cov
uv run --extra dev pytest tests/test_realtime_v2_websocket.py -q --no-cov
```

### 真实模型与客户端 smoke

只有在外部 snapshot、专用 runtime 和授权均具备时才执行真实 smoke：

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
./examples/curl-transcribe.sh <path-to-short-audio>
```

QwenPaw 使用 `examples/qwenpaw.md`：provider 为 `whisper_api`，base URL 指向
`http://127.0.0.1:8201/v1`，新配置使用 `speechrail/qwen3-asr-1.7b`。修改 provider 后
必须完整重启 QwenPaw；不要改聊天模型 endpoint。QwenPaw 的录音可能以 `.webm`/`video/webm`
上传，SpeechRail 应让格式提示通过，再由 `ffmpeg` 做内容校验。

Realtime 客户端只发送 16 kHz、单声道、16-bit little-endian PCM。先验证事件顺序和
terminal event，再评估真实 partial、RTF、并发、峰值内存和断线重建。真实 diarization
还要单独验证 DER/JER、label 稳定性、overlap、finalize remap 和匿名数据清理。

## 项目级验证门禁

在声明改动完成前，先运行针对性测试，再执行以下项目级 gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

涉及运行时或 QwenPaw 的改动，还必须验证 `/health`、`/readyz` 和
`/v1/models`；本地模型可用时，再执行真实 multipart WebM smoke。如果本地
无法运行模型相关测试，必须明确说明限制，并使用 fake backend 保持测试确定性。
命令退出码不是唯一证据，还要核对 API 响应、客户端行为和日志脱敏。如果某个 gate
只在其他并行任务修改的文件中失败，不得回退、屏蔽或静默修复这些改动；应报告准确
路径、错误码，并将本任务的验证证据与其分开。

## 故障定位矩阵

| 现象 | 先确认 | 处理原则 |
|---|---|---|
| 连接被拒绝/无响应 | 进程、监听端口、启动命令、stderr/`launchctl print` | 只启动一个实例；修复服务状态后重试 |
| `/readyz` 为 503 | 两条 ASR 路径、snapshot 完整性、Python 可执行权限、worker 启动错误 | 修配置；不要用 `SPEECHRAIL_BACKEND_READY=true` 掩盖问题 |
| `422 unsupported_audio_type` | filename、multipart `Content-Type`、容器、`ffmpeg` PATH 和内容 | `webm` 的 `video/webm` 属于兼容输入；最终以固定解码结果为准 |
| `422 audio_decode_failed` | 文件是否损坏、容器是否支持、`ffmpeg` stderr | 更换/修复音频；不要只改 MIME 绕过内容校验 |
| `413 audio_too_large` | `SPEECHRAIL_MAX_UPLOAD_BYTES` 和实际文件大小 | 调整客户端切片/压缩或经授权调整上限；不要无界放大 |
| `429 queue_full` | admission queue、Resource Governor、并发和内存 | 尊重 `retryable`/`Retry-After`，不要复制模型进程 |
| `503 backend_timeout` | worker stderr、模型设备、请求时长、系统内存 | 保留 request ID，有限退避；不要无界重试 |
| MPS/dtype 不匹配 | `SPEECHRAIL_DEVICE`、`SPEECHRAIL_DTYPE`、worker ready identity | `mps/float16` 或 `cpu/float32` 成对修复；禁止静默 fallback |
| `diarization_not_available` | `SPEECHRAIL_DIARIZATION_MODEL_PATH`、NeMo runtime、session 是否 opt-in | fail-closed；不要生成伪造的 `speaker` |
| QwenPaw 失败 | SpeechRail 三个健康端点、REST curl、provider base URL/model、完整重启 | 先证明 REST，再检查 QwenPaw；不要改 LLM 配置 |
| `/asr` 不能转写 | 这是当前设计限制 | 使用 REST 或 `/v1/realtime`；不能据此宣布 WLK 迁移完成 |

排障记录只保留时间、版本、request ID、错误码、状态码、耗时、字节/时长摘要、
设备/dtype 和资源摘要。禁止收集 API key、Authorization、音频、Base64、完整 prompt、
完整转写、embedding、姓名和绝对模型路径。

## 文档导航与系统掌握顺序

按任务选择最小阅读集；遇到架构或跨服务问题再扩大范围：

1. `README.md`：当前能力矩阵、快速启动和 API 一览。
2. `docs/00-product-scope.md`、`docs/01-architecture.md`：所有权、数据流和边界。
3. `contracts/openapi.yaml`、`contracts/realtime.md`、`contracts/realtime-v2.md`：事实契约。
4. `docs/02-api-contract.md`、`docs/04-integrations.md`：客户端接入和错误语义。
5. `docs/05-runtime-deployment.md`、`docs/10-development-guide.md`：配置、开发和 runtime。
6. `docs/07-testing-acceptance.md`、`docs/11-operations-runbook.md`：验收和运维。
7. `docs/09-open-questions.md`、`docs/decisions/README.md`：风险、限制和 ADR 决策。
8. `docs/superpowers/specs/` 与 `docs/superpowers/plans/`：目标设计/历史计划，不能单独
   作为当前行为证据。

代码、契约、文档冲突时，先确认当前实测和 Git 状态，再最小范围修正；不要批量改写
无关文档或把未验收目标标成已完成。

## 提交与交接

- 一个 commit 只表达一个逻辑主题，提交信息使用 `<type>: <why>`，例如
  `fix: accept OpenAI audio container uploads`。
- 提交前检查 `git diff --staged`、`git diff --staged --check` 和敏感字段；仅暂存明确属于
  当前任务的文件/hunk。
- 同一文件存在并行改动时使用分块暂存；无法安全分块时不提交该文件，报告阻塞。
- 不 force-push，不覆盖他人分支，不提交 `.env`、模型、音频、日志或构建产物。

每次任务结束都要给出：

```text
结果：已完成 / 部分完成 / 阻塞
改动：文件路径 + 一句话说明
实测：命令、退出码、测试数量或 HTTP 状态
运行态：服务地址、健康端点、模型/设备身份（不含凭据和绝对路径）
未验证/风险：明确列出真实模型、客户端、性能或安全门的缺口
并行改动：已看到但未触碰的文件/分支
回退：如何恢复本次变更，不删除外部模型、配置或用户数据
```

## 敏感数据

严禁提交 API key、本地凭据文件、完整环境变量文件、音频、模型权重或未脱敏
的转写 fixture。示例中使用占位符。
