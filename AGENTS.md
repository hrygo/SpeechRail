# SpeechRail Agent 指南

> 本文件是 SpeechRail Agent 的入口规范，不是功能设计文档。它规定如何建立上下文、
> 选择开发/运维/测试模式、保护并行工作和给出可复核的交接结果。详细事实以当前代码、
> `contracts/` 和状态为 active 的文档为准。

## 1. 项目画像与设计原则

SpeechRail 是供 QwenPaw、`sona`、Hermes Agent 及未来应用共享的
独立本地语音识别与合成服务。它提供稳定的 ASR/TTS 公共接口、运行时生命周期、模型适配器、
资源边界和兼容性边界；调用方仍拥有麦克风、播放、会议、UI、会话和应用编排。

本应用为本机单人使用，默认只有一个本机部署目标。架构设计需避免过度设计：优先可理解、可回退、
能被当前消费者验证的最小实现，不为假设的多用户、云部署或平台化需求预留复杂基础设施。

### 设计原则

- **本地优先**：默认 loopback、外部模型快照、请求期间处理音频，不把本机服务当作公网平台。
- **单人但允许有界并行**：队列、Resource Governor、超时和背压用于保护本机资源，不代表多租户或分布式需求。
- **能力按需启用**：TTS、`jobs`、diarization 和 LAN 暴露均须有明确消费者与验收证据，默认关闭或保持最小边界。
- **职责不外溢**：不把 `sona` 的会议、数据库、UI、播放或 LLM 编排移入 SpeechRail。

### 设计决策过滤器

新增组件、持久化、网络边界或调度机制前，依次确认：

1. 是否解决当前单人本机的真实需求；没有明确消费者时不新增能力。
2. 是否可以用现有进程、worker、配置和契约完成；优先最小、可回退的实现。
3. 是否引入了多租户、分布式队列、服务网格、HA、云控制面或跨服务编排；若是，必须先证明单人本机需求无法用更简单的方案满足。
4. 是否有契约、测试、观测和回退路径；没有就留在正式设计文档或归档材料，不进入实现。

## 2. 任务启动与证据规则

收到任务后先完成以下步骤，再决定是否修改文件：

1. 读取本文件和任务对应的入口文档。
2. 执行 `git status --short`、`git log -5 --oneline`，确认分支、未提交改动和并行工作。
3. 把任务分类为开发、运维、测试、客户端集成或审查，并确定明确的写入范围。
4. 区分“当前代码已实现”“契约已定义但真实后端未验收”和“历史计划/目标设计”。
5. 先做只读检查，再执行有副作用的操作；操作前记录目标、风险和回退方式。
6. 完成后运行与风险相称的验证，并报告实测结果、未验证项和未触碰的并行改动。

### 事实来源层级

1. 当前代码、测试和实际运行结果；
2. `contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/realtime-v2.md`；
3. 状态为 active 的架构、用户、开发者、运维文档和 ADR；
4. `docs/archive/` 中的计划、设计和审查材料只用于历史追溯。

发现代码、契约、文档和历史记录冲突时，报告差异并以当前实测为准；不要把计划、配置存在
或 `readyz=200` 当作真实模型质量验收。

### 沟通规则

- Agent 沟通、任务摘要、注释和项目文档默认使用简洁中文。
- 命令、路径、配置键、API 字段、协议事件、错误码、模型 ID、类名和函数名保留原文。
- 外部协议名和厂商名保持准确；用中文解释，不翻译标识符本身。
- 报告必须区分“已实测”“文档规定”“历史记录”和“推断”，不能把计划写成完成事实。

## 3. 服务边界与系统地图

### 服务职责

服务层负责对外 ASR/TTS API、运行时生命周期、模型适配器、队列、认证、可观测性和兼容性边界。

### 职责边界

它不负责麦克风、扬声器、播放、会议持久化、UI 状态、LM Studio 对话编排或
应用专属提示词；这些职责属于调用方应用。SpeechRail 负责公共 ASR/TTS 推理，
但不负责应用侧的语音交互编排或音频输出。

### 系统地图

#### 请求与运行时数据流

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
          └─ Qwen3 ASR/TTS worker
```

主进程负责公共边界和调度；Qwen3/TTS 的模型 SDK 与权重留在隔离的专用 Python worker。
当前可选 NeMo diarization adapter 是例外：它由
`diarization` extra 提供依赖，并在服务进程中按需加载仓库外模型；它仍必须保持有界、
匿名且不进入 domain。请求路径不下载模型、不读取远程音频 URL，默认不持久化音频、PCM、
embedding 或完整转写正文。

#### 目录职责

| 路径 | 责任 | 修改时先看 |
|---|---|---|
| `src/speechrail/__main__.py` | 模块入口，委派给 `speechrail.cli.main()` | `src/speechrail/cli.py` |
| `src/speechrail/cli.py` | `serve` 与 `service` 命令树；不承载服务平台细节 | `service/launchd.py` |
| `src/speechrail/service/` | macOS LaunchAgent 渲染、文件安装和 `launchctl` 适配 | `docs/operations/operations-runbook.md` |
| `src/speechrail/app.py` | 组合根、FastAPI middleware/route 注册和 lifespan | `application/`、`contracts/` |
| `src/speechrail/application/` | 用例依赖组装、worker 生命周期和跨传输交付校验 | `domain/ports.py`、运行时适配器 |
| `src/speechrail/config/` | `SPEECHRAIL_*` 环境配置和组合校验 | `configs/speechrail.example.env` |
| `src/speechrail/domain/` | vendor-neutral 结果、请求、事件和 port | 公共契约 |
| `src/speechrail/backends/` | Qwen3 ASR/TTS、NeMo Sortformer 适配器 | `domain/ports.py` |
| `src/speechrail/runtime/` | admission queue、Resource Governor、jobs、worker IPC、diarization 协调 | 资源限制 |
| `src/speechrail/realtime/` | Realtime v1/v2 状态机和事件生命周期 | `contracts/realtime*.md` |
| `src/speechrail/compatibility/` | OpenAI 等窄兼容呈现和归一化 | 兼容边界 |
| `contracts/` | OpenAPI 与 WebSocket 事实来源 | 任何公共接口变更前 |
| `tests/` | fake backend、契约、安全、边界和协议回归 | `docs/developers/testing-acceptance.md` |
| `examples/` | 不含凭据的 curl、OpenAI SDK、Realtime、QwenPaw 示例 | `docs/users/integrations.md` |
| `deploy/macos/` | `launchd` 模板；不是自动安装器 | `docs/operations/operations-runbook.md` |
| `docs/` | 架构、用户、开发者、运维正式文档、ADR 与归档过程材料 | `docs/README.md` |

#### 当前能力矩阵

| 能力 | 当前结论 | 不应作出的承诺 |
|---|---|---|
| `POST /v1/audio/transcriptions` | Qwen3-ASR batch REST 可用；配置外部 runtime 后可真实推理（本机已配置并 smoke） | 不要绕过公共 API 直接调用 worker |
| `GET /health`、`/readyz`、`/v1/models` | 可用的进程、入口配置和模型清单检查 | `readyz=200` 不等于真实音频质量已验收 |
| `POST /v1/audio/speech` | Qwen3-TTS VoiceDesign 整句 TTS 已实现；本机已配置外部 TTS runtime 并实测输出 24 kHz PCM16 | 不要把 TTS runtime 当作 ASR 前置条件 |
| `GET /v1/voices` | 当前代码应返回已登记的 TTS preset；TTS 未就绪时条目仍可返回但 `available=false`（本机当前全部 `available=true`） | 运行态 404 先核对服务进程、端口/base URL 和是否重启了当前代码；不能仅归因于缺少 TTS runtime |
| `POST/GET/DELETE /v1/jobs` | 可选 owner-scoped 元数据 spool；需受信任 `JobProcessor` 才会执行 | `input_ref` 默认不是路径/URL resolver，不会自动读取音频 |
| `WS /v1/realtime` | OpenAI Realtime 兼容端点（ASR/TTS 子集）；支持并发多会话共享单个 streaming worker（`SPEECHRAIL_REALTIME_MAX_SESSIONS`，默认 `3`）；标准 `openai` SDK 的 `client.realtime.connect(model="whisper-1")` 可接入 | 不伪装 LLM 对话/工具/历史；`turn_detection` 支持 `null`/`manual`/`server_vad`；Barge-in 打断严格限制于单会话内部；达到并发上限时新会话的 append 返回 `backend_busy`（session 保持可用） |
| `diarization` profile | 可选匿名 speaker label、overlap 和 finalize remap | 不提供实名身份、声纹库或跨会议持久身份 |
| `speechrail service` | macOS 用户级 LaunchAgent 的显式安装/启用/管理 CLI | 不自动安装、启用、下载模型或创建 root 服务 |
| QwenPaw `whisper_api` | 使用标准 OpenAI-compatible `/v1` 路径；`.webm`/`video/webm` 需兼容 | 不要修改聊天模型 endpoint 来排查 STT |

目标设计、实施计划和历史审查材料只说明意图；以当前代码、契约和能力矩阵为准。

## 4. 稳定契约与运行边界

- Python 版本必须满足 `>=3.12,<3.13`；使用 `uv` 和 PEP 621 元数据。
- 对外文件转写 API 使用 OpenAI-compatible 的
  `/v1/audio/transcriptions`。
- 对外流式接口 `/v1/realtime` 实现 OpenAI Realtime 兼容协议（ASR/TTS 子集）；标准
  OpenAI 客户端和 `sona` 可直接接入，均须先通过真实 backend 和客户端 smoke。
- 默认绑定 loopback。绑定 LAN 时必须启用 API key，并明确配置允许的
  origin 策略。
- 模型快照使用外部绝对路径。请求处理期间不得下载模型或静默访问网络。
- 音频默认只在请求期间存在。不得持久化源音频，也不得在日志中记录原始
  转写正文。
- 对外模型名与具体模型实现解耦。`qwen3-asr-1.7b` 是后端 profile，不能
  因此重命名服务或 API。
- 不要把 `sona` 的会议、UI、TTS、LM Studio 或 PostgreSQL 职责
  移入本仓库。

### 公共契约规则

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

#### Realtime 约束

- `contracts/realtime-openai.md` 描述 `/v1/realtime` 的 OpenAI Realtime 兼容子集；
  只承载 ASR/TTS，不伪装 LLM 对话/工具/历史，`turn_detection` 支持 `null`/`manual` 与
  `server_vad`（`{"type":"server_vad","threshold","prefix_padding_ms","silence_duration_ms"}`）。
- `/v1/realtime` 只承载 ASR/TTS，不承载 LLM response、tool call、播放、会议和应用打断策略；
  事件 envelope、背压、取消和不可恢复 session 规则以 `contracts/realtime-openai.md` 为准。
- 断线后创建新 session/source epoch；服务端不保存、不重放旧音频或事件。

#### Diarization 约束

- `session.update.session.diarization` 是 transcription session 的可选能力；未启用时维持
  既有事件形状，启用但没有 profile 时必须返回 `diarization_not_available`。
- 输出只包含 session-scoped 的匿名 `spk_*` label、置信度、重叠信息和 finalize remap。
  `group_id` 只用于有界匿名声学状态，不得承载姓名、邮箱、手机号或凭据。
- `sona` 负责 `speaker_id → display_name`、人工修正、事务性 remap、会议和数据库。
  SpeechRail 不加载 CAM++、不管理声纹库、不保存 PCM/embedding、不伪造单一 speaker。

## 5. 配置与运行前提

项目固定使用 Python `>=3.12,<3.13`、`uv`、PEP 621。主服务使用仓库 `.venv`；真实
Qwen3/TTS vendor runtime 使用外部专用 Python，diarization 依赖由 `diarization` extra
提供并由当前 adapter 在服务进程中按需加载模型。配置入口是被 Git 忽略的 `.env`，
示例是 `configs/speechrail.example.env`，不可提交真实值。

| 配置类别 | 关键键 | 规则 |
|---|---|---|
| 服务 | `SPEECHRAIL_HOST`、`SPEECHRAIL_PORT` | 默认 `127.0.0.1:8201`；不要与旧 WLK `8001` 混用 |
| ASR runtime | `SPEECHRAIL_QWEN3_MODEL_DIR`、`SPEECHRAIL_QWEN3_PYTHON` | 必须同时配置；均为仓库外绝对路径/可执行文件 |
| TTS runtime | `SPEECHRAIL_QWEN3_TTS_MODEL_DIR`、`SPEECHRAIL_QWEN3_TTS_PYTHON` | 可选；两条路径同时存在才启动 TTS worker；缺少配置时 `/v1/audio/speech` 返回 `503 backend_not_ready` |
| diarization | `SPEECHRAIL_DIARIZATION_MODEL_PATH`、`SPEECHRAIL_DIARIZATION_MAX_BUFFER_BYTES` | 可选；模型路径必须是仓库外绝对路径；未通过真实质量/资源门前不进默认配置 |
| 流式 ASR 后端 | `SPEECHRAIL_REALTIME_ASR_BACKEND`（`disabled`/`native`）、`SPEECHRAIL_QWEN3_STREAMING_MODE`、`SPEECHRAIL_REALTIME_MAX_SESSIONS` | 默认 `disabled`；`native` 复用现有 ASR runtime（`qwen3_python`）与 snapshot（`qwen3_model_dir`），不再单独配置 streaming Python；`causal` 模式仅英语；windowed 手动 flush 可能无 delta，须以 `commit` 终结；`realtime_max_sessions` 默认 `3`（范围 `1-8`，示例 env 设为 `2`），限制共享 streaming worker 上同时活跃的 backend ASR 会话数 |
| 模型身份 | `SPEECHRAIL_MODEL_ID`、`SPEECHRAIL_COMPATIBILITY_MODEL_IDS` | canonical ID 是配置事实来源；对外入口接受 OpenAI 标准名（`whisper-1`/`tts-1` 等）alias，`/v1/models` 列出 canonical 与 alias 并标注 `resolves_to` |
| 设备与精度 | `SPEECHRAIL_DEVICE`、`SPEECHRAIL_DTYPE` | `mps` (支持 `float16` 默认 / `int8` 优化) 或 `cpu` (支持 `float32` / `int8`)；禁止静默 CPU fallback。`SPEECHRAIL_DTYPE` 只控制**非预量化快照**的加载精度：`int8` 触发 ASR worker 内存即时量化，且仅作用于 ASR；TTS worker 不做运行时权重量化。预量化 `-8bit` 快照（`config.json` 声明 `quantization`）由 ASR 与 TTS 一律自动解析为 `int8` 直接加载，不二次量化 |
| 限制 | `SPEECHRAIL_MAX_QUEUE_SIZE`、`SPEECHRAIL_MAX_UPLOAD_BYTES`、`SPEECHRAIL_MAX_REALTIME_*` | 必须有界；不要通过多 ASGI worker 复制模型 |
| 调度 | `SPEECHRAIL_RUNTIME_*`、`SPEECHRAIL_REALTIME_RESERVED_CAPACITY` | realtime 预留容量，batch 使用剩余容量并受 aging/队列限制 |
| 超时 | `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` | worker/inference deadline；失败要映射稳定错误 |
| Jobs | `SPEECHRAIL_JOB_SPOOL_DIR`、`SPEECHRAIL_JOB_POLL_SECONDS` | 可选、仓库外绝对目录；只保存 opaque reference 和状态 |
| 安全 | `SPEECHRAIL_API_KEY`、`SPEECHRAIL_ALLOWED_ORIGINS` | 非 loopback 必须有 key；当前 CORS 能力不足，不能直接公网暴露 |
| 开关 | `SPEECHRAIL_ALLOW_MODEL_DOWNLOADS`、`SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS` | 必须为 `false`；服务不下载模型 |
| 测试模拟 | `SPEECHRAIL_BACKEND_READY` | 仅无真实 backend 的契约测试使用；真实部署不得用它掩盖配置问题 |

`SPEECHRAIL_MAX_AUDIO_SECONDS` 是配置字段，且已在解码后强制时长拒绝（超限返回 `400 audio_too_long`）。
上传字节上限、Realtime 帧/缓存上限和 worker timeout 也不能
替代真实性能、峰值内存与长音频基准。

### wheel 安装后的配置边界

- wheel 只包含 `speechrail` Python 包；模型 snapshot、ASR/TTS vendor Python 和
  `ffmpeg` 必须由本机单独准备。
- 本地安装器把私有配置放在 `<user-app-home>/config/.env`，权限应为 `0600`；已有配置
  不会被覆盖。LaunchAgent 的 `WorkingDirectory` 为 `<user-app-home>`，`speechrail serve`
  会优先发现该目录下的 `config/.env`，也可通过 `serve --env-file` 显式指定。
- Qwen3 worker 通过受控 `PYTHONPATH` 支持源码 checkout 和已安装 wheel 两种布局；外部
  vendor Python 只负责模型推理，不得依赖当前源码目录的隐式导入。
- 安装前的 preflight 只证明配置、snapshot、导入路径和运行时入口可用；它不替代真实
  ASR/TTS 音频质量、耗时或资源验收。

## 6. 按任务类型执行

### 开发

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

#### 变更流程

1. 先锁定 `contracts/`、实现文件、测试和文档的最小写入范围。
2. 公共行为先写失败的契约/回归测试，再做最小实现；适配器边界校验 vendor 响应。
3. 不把模型 SDK、会议业务、UI、数据库或客户端 prompt 引入公共 domain。
4. 更新受影响的 README、`docs/`、OpenAPI/WebSocket 契约和必要的 `CHANGELOG.md`。
5. 按单一主题检查 staged diff；不暂存 `.env`、模型、音频、缓存、日志或外部 runtime。
6. 单人本机的小范围低风险修改可留在当前分支；跨文件、高风险或明确并行的任务再使用短生命周期
   feature branch/worktree。共享工作树中发现同文件并行改动时，只做不重叠的 hunk，无法安全分离就停下并报告，
   不覆盖或回退他人修改。

### 运维

#### 启动与健康检查

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
PID、工作目录和启动者。macOS 常驻服务只使用已审查的 `speechrail service` CLI 和
`deploy/macos/` `LaunchAgent` 模板；不要把 MPS worker 安装成 `LaunchDaemon`。

#### macOS `launchd`

详细步骤见 `docs/operations/operations-runbook.md`。默认使用 `uv run speechrail service
install|enable|disable|restart|status|uninstall`；`install` 仅写入当前用户的 plist 和私有日志目录，
`enable`、`restart` 和 `uninstall` 会改变运行态。除非用户明确要求，Agent 只可实现或检查服务
能力，不得安装、启用、停用、重启或卸载本机服务。

执行有副作用的 service 命令前，先确认当前目录是目标部署目录、`.env` 已配置、当前 `.venv`
可用、目标 label 为 `com.speechrail`，并说明模型会在服务启动/重启时重新加载。`launchctl`
手工命令仅用于 CLI 无法提供足够诊断时的恢复排障；不得把本机路径或 `.env` 内容回写到项目文档。

```bash
plutil -lint deploy/macos/com.speechrail.plist.example
uv run speechrail --help
uv run speechrail service --help
```

停用或卸载常驻服务只针对已确认的 `com.speechrail` label；保留可回退的 plist、`.env` 和模型
snapshot，不删除外部资源。CLI 只支持 macOS 用户级 `LaunchAgent`；其他平台必须明确返回不支持，
不得伪造 systemd、root 或跨平台服务语义。

#### wheel 安装与切换

wheel 服务与源码前台服务共用 `com.speechrail` label，切换时必须先停用旧实例，再安装和启用
新 runtime；不要让两个实例同时争用 `8201`。标准流程如下：

```bash
uv build --no-sources --wheel
uv run speechrail service disable --app-home <user-app-home>
python3 tools/install_macos.py \
  --wheel <wheel-file> \
  --env-file <private-env-file> \
  --app-home <user-app-home> \
  --enable
```

安装器会在 `runtime/releases/` 下创建独立 virtualenv，先运行新 wheel 的 preflight，再原子切换
`runtime/current`；默认不下载模型、不写入 plist 环境变量、不要求 root。已有 `<user-app-home>/config/.env`
不会覆盖，因此升级时可将 `--env-file` 指向该现有配置，或在操作前确认配置迁移范围。

切换后必须核对 `speechrail service status --app-home <user-app-home>` 的 Python、工作目录和
label，再检查 `/health`、`/readyz`、`/v1/models`、`/v1/voices`。如果 preflight 或启动失败，
保持服务停用，检查 stderr 和当前 runtime，不要连续 `restart` 掩盖失败原因。

回退是恢复旧 release 和服务定义的组合操作，不等同于 `disable` 或 `uninstall`：

1. 先停用当前 `com.speechrail`，保留旧 `runtime/releases/`、配置和模型。
2. 将 `runtime/current` 恢复到上一份 release；必要时恢复切换前备份的 plist。
3. 用目标 runtime 执行 `speechrail service install --app-home <user-app-home>`，再显式 `enable`。
4. 重新核对服务状态和健康端点，并记录实际运行的 runtime 路径。

`disable` 只停止并保留 plist；`uninstall` 会卸载并删除 plist，都不是 release 回退。回退过程
不得删除外部模型、用户配置或日志目录。

#### 运维边界

- 默认只监听 loopback。非 loopback 需要 API key；v2 LAN 暴露还必须有 TLS、WebSocket
  `Origin` allowlist、HTTP CORS、网段策略和限速。
- TTS 和 diarization 都是外部/可选 profile；SpeechRail
  不下载、安装、启动或移动这些 runtime/model。
- 升级按可回退版本目录/commit 执行：先测试和真实 smoke，再切换服务；不要覆盖旧 `.env`
  和 snapshot，不使用破坏性 Git 命令回滚配置。

### 测试

#### 自动化测试

测试默认使用 fake backend、构造 PCM 和脱敏 fixture；不加载真实模型、不访问网络、不写入
真实音频。应覆盖 model alias、统一错误 envelope、request ID、上传/帧/缓存限制、队列与
Resource Governor、worker frame 协议、snapshot preflight、REST 响应格式、Realtime 事件
顺序、cancel/背压以及 diarization fail-closed。

行为变更先跑针对性测试：

```bash
uv run --extra dev pytest tests/test_transcription_api.py -q --no-cov
uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov
```

变更 CLI、LaunchAgent 或服务模板时，额外运行：

```bash
uv run --extra dev pytest tests/test_cli.py tests/test_launchd_service.py -q --no-cov
plutil -lint deploy/macos/com.speechrail.plist.example
uv run speechrail --help
uv run speechrail service --help
```

测试必须验证 plist 不写入 `EnvironmentVariables`、服务进程使用单一 Python module 入口、
`KeepAlive.SuccessfulExit=false`、重启节流、原子安装、`gui/<uid>` 域和非 macOS fail-closed。

#### 真实模型与客户端 smoke

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

## 7. 验证与交接

### 风险分级验证

验证强度与变更范围匹配，不因文档或规则文件变更强制执行运行态操作：

| 变更范围 | 必做验证 | 额外验证 |
|---|---|---|
| `AGENTS.md`、README 或正式文档 | 重新读取受影响文件；检查标题层级、仓库路径、Markdown 链接、敏感信息和 `git diff --check` | 文档中的命令或契约发生变化时，再执行对应命令/契约 gate |
| 代码或测试 | 先跑相关测试、`ruff` 和 `mypy` | 涉及公共行为或跨模块时执行完整代码 gate |
| OpenAPI/WebSocket 契约 | 契约测试和对应 lint | 影响实现时执行完整代码 gate |
| 配置、服务或客户端集成 | 配置/模板静态检查和帮助命令 | 只有具备外部 runtime、授权且用户要求时，才做服务、客户端或真实模型 smoke |

### 完整代码 gate

当变更涉及代码、测试、公共契约或多个运行模块时执行：

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

## 8. 运维排障与安全

| 现象 | 先确认 | 处理原则 |
|---|---|---|
| 连接被拒绝/无响应 | 进程、监听端口、启动命令、stderr/`launchctl print` | 只启动一个实例；修复服务状态后重试 |
| `/readyz` 为 503 | 两条 ASR 路径、snapshot 完整性、Python 可执行权限、worker 启动错误 | 修配置；不要用 `SPEECHRAIL_BACKEND_READY=true` 掩盖问题 |
| wheel 服务已启动但 ASR/TTS 为 false | LaunchAgent 的 `WorkingDirectory`、`<user-app-home>/config/.env`、两条 runtime 配置和 `service preflight` | 不要只检查源码仓库 `.env`；修复配置来源后重新安装/启用 |
| wheel worker 报 `worker_frame_invalid` | 当前 release 是否包含 worker 包、外部 Python 的导入路径、stderr 和 snapshot | 重新构建并安装完整 wheel；不要把源码目录硬编码进 plist |
| `422 unsupported_audio_type` | filename、multipart `Content-Type`、容器、`ffmpeg` PATH 和内容 | `webm` 的 `video/webm` 属于兼容输入；最终以固定解码结果为准 |
| `422 audio_decode_failed` | 文件是否损坏、容器是否支持、`ffmpeg` stderr | 更换/修复音频；不要只改 MIME 绕过内容校验 |
| `413 audio_too_large` | `SPEECHRAIL_MAX_UPLOAD_BYTES` 和实际文件大小 | 调整客户端切片/压缩或经授权调整上限；不要无界放大 |
| `429 queue_full` | admission queue、Resource Governor、并发和内存 | 尊重 `retryable`/`Retry-After`，不要复制模型进程 |
| `503 backend_timeout` | worker stderr、模型设备、请求时长、系统内存 | 保留 request ID，有限退避；不要无界重试 |
| MPS/dtype 不匹配 | `SPEECHRAIL_DEVICE`、`SPEECHRAIL_DTYPE`、worker ready identity | `mps/float16` 或 `cpu/float32` 成对修复；禁止静默 fallback |
| `diarization_not_available` | `SPEECHRAIL_DIARIZATION_MODEL_PATH`、NeMo runtime、session 是否 opt-in | fail-closed；不要生成伪造的 `speaker` |
| QwenPaw 失败 | SpeechRail 三个健康端点、REST curl、provider base URL/model、完整重启 | 先证明 REST，再检查 QwenPaw；不要改 LLM 配置 |

排障记录只保留时间、版本、request ID、错误码、状态码、耗时、字节/时长摘要、
设备/dtype 和资源摘要。禁止收集 API key、Authorization、音频、Base64、完整 prompt、
完整转写、embedding、姓名和绝对模型路径。

## 9. 文档与归档

按任务选择最小阅读集；遇到架构或跨服务问题再扩大范围：

1. `README.md`：当前能力矩阵、快速启动和 API 一览。
2. `docs/architecture/README.md`：产品范围、数据流、边界和 ADR 导航。
3. `contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/realtime-v2.md`：事实契约。
4. `docs/users/README.md`：客户端接入和错误语义。
5. `docs/developers/README.md`：开发、测试和契约变更。
6. `docs/operations/README.md`：配置、运行、验收和运维。
7. `docs/architecture/current-boundaries.md`、`docs/decisions/README.md`：风险、限制和 ADR 决策。
8. `docs/archive/README.md`：目标设计、实施计划、审查交接和其他过程材料；不能单独
   作为当前行为证据。

代码、契约、文档冲突时，先确认当前实测和 Git 状态，再最小范围修正；不要批量改写
无关文档或把未验收目标标成已完成。

正式文档 front-matter 中的 `version`/`date` 是文档自身的 metadata：`version` 表示该文档
最后一次实质更新的发布版本号，`date` 表示该次更新的日期。文档正文没有变化时，不随
服务版本或日历日期同步更新这两个字段；只有正文实质变更（内容、边界或契约描述改变）
才需要同步更新 metadata。历史版本号只说明文档最后一次更新的时点，不代表文档描述的能力
随每次发布自动升级。

## 10. 交付、并行与数据保护

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

### 敏感数据

严禁提交 API key、本地凭据文件、完整环境变量文件、音频、模型权重或未脱敏
的转写 fixture。示例中使用占位符。
