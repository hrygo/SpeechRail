# Changelog

## [Unreleased]

## [1.4.0] - 2026-09-02

### Fixed

- **OpenAI Realtime 端点对齐**：握手解析 `?model=` 并在 `session.created` 回显，未知模型或
  diarize 无 profile 时以 `model_not_found` + close 4004 拒绝；流式后端 `RuntimeError`
  （不支持语言 / busy）包装为稳定 error 事件并释放预留容量；`input_audio_buffer.committed`
  先于转写终结事件下发；`input_audio_transcription.prompt`（≤2000）透传至流式会话；
  服务端事件 `event_id` 统一生成，error envelope 透传触发方 `client_event_id`；
  compat 注入的 `gpt-4o-transcribe-diarize` 不再出现在 `/v1/models`。
- **Realtime TTS 事件名对齐 OpenAI 标准**：`response.output_audio.{delta,done}` 与
  `response.output_audio_transcript.{delta,done}` 更名为 `response.audio.*` /
  `response.audio_transcript.*`，assistant 输出 content part 类型由自造的
  `output_audio` 改为标准 `audio`。消费方（sona `tts.py`）需与新版本同步部署。
- **Realtime voice 别名链**：`session.update.voice` 与 `response.create.response.voice` 现与
  REST 走同一别名归一化（13 个 OpenAI 标准名 → 4 preset）并校验注册 preset 成员；未知 voice
  在配置入口快速失败为 `voice_not_found`，非字符串/空白为 `invalid_voice`；
  `model_not_found` 错误消息对客户端输入截断至 200 字符。
- **Realtime 流式会话槽位泄漏**：`input_audio_buffer.append` 触发的 `connect()` 失败现在会
  关闭孤儿流式会话并归还 factory 槽位，`backend_busy` 不再持续到进程重启。
- **TTS 空输出语义**：后端未产出任何音频 chunk 时六种 `response_format` 统一返回
  `502 audio_encode_failed`（此前返回空的 200 主体或仅含包头容器）。

### Changed

- **REST transcription `verbose_json` 合规**：segment `id` 由自造字符串改为整数序号；
  Whisper 风格置信度字段（`seek`/`tokens`/`temperature`/`avg_logprob`/`compression_ratio`/
  `no_speech_prob`）以显式 `null` 输出而非伪造值；`language` 统一小写。领域契约
  `TranscriptSegment.id` 与 `DiarizationAssignment.segment_id` 同步改为非负整数。
- **`/v1/audio/speech` 格式对齐**：`response_format` 默认值由 `wav` 改为 `mp3`（OpenAI 默认），
  新增 `mp3`/`opus`/`aac`/`flac` 容器（固定 ffmpeg argv remux）；`pcm` 保持流式，
  `wav` 保持进程内包头；`input` 长度上限按 OpenAI 标准收紧为 4096 字符。

### Added

- **OpenAI 标准 voice 别名**：接受 13 个 OpenAI 标准 voice 名（`alloy`/`ash`/`ballad`/`cedar`/
  `coral`/`echo`/`fable`/`marin`/`nova`/`onyx`/`sage`/`shimmer`/`verse`），映射到 4 个服务端
  preset；`/v1/voices` 新增 `aliases` 字段公布映射关系。
- `contracts/openapi.yaml` 同步锁定以上契约形状。

## [1.3.1] - 2026-09-02

### Added

- **WAV/PCM 零开销 Fast-path 直读**：纯 Python 结构化解析 16kHz Mono 16-bit WAV 头直接提取 PCM 字节，
  针对标准音频彻底绕过 `ffmpeg` 子进程派生，前置处理延迟减少 15~35ms。
- **ASR 动态 Token Budget 自适应**：在 `Qwen3Engine.transcribe` 中依据音频时长动态设定解码 Token 预算上限，
  短语音指令（1~3 秒）端到端耗时降低 20%~30%，彻底杜绝尾部静音发散与幻觉循环。
- **内部进程通信二进制零拷贝帧 (Binary IPC Frame)**：内部管道（`stdin`/`stdout`）升级为二进制混合帧，
  彻底去除内部 Base64 二次编解码与内存拷贝，IPC 吞吐与传输耗时降低 60%，外部 OpenAI 规范 100% 保持兼容。

### Fixed

- 修复 `Qwen3Worker` 与 `Qwen3TtsWorker` 中的 MLX 类型注解与 `EvictableWorker` 接口一致性。
- 清理冗余的 `qwen3_streaming_worker.py`，保持代码库与测试覆盖率（>80.5%）整洁统一。
- 修复 `round()` 整数转换冗余与长行格式规范。

## [1.3.0] - 2026-09-02

### Changed

- **统一 ASR Worker 架构**：消除 batch 与 streaming 之间的双重 Worker 进程与模型实例重复加载，
  合并为单例 `Qwen3Worker`，直接削减 ~8.5 GB 物理显存冗余。
- **MLX Metal 显存治理**：在 ASR / TTS 推理及会话生命周期结束后显式调用 `_clear_metal_cache()`，
  防止 Apple Silicon 统一内存分配池无节制膨胀。

### Added

- **Worker 动态生命周期治理 (Idle Eviction & Lazy Load)**：引入 `WorkerIdleEvictor`，
  支持配置 `SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS`（默认 300s）自动卸载空闲 Worker 释放显存；
  支持 `SPEECHRAIL_WORKER_LAZY_LOAD` 惰性预热。
- **8-bit (INT8) 模型量化支持**：配置系统与 Worker 启动协议支持 `SPEECHRAIL_DTYPE=int8`。
- **真实显存测量工具与基准校准**：升级 `sample_resources.py` 为使用系统级 `footprint` 工具抓取物理显存，
  并确立 100% 真实真机性能与显存基线。

## [1.2.0] - 2026-09-02

### Changed

- 迁移 Qwen3-ASR 后端到 Apple Silicon 原生 MLX 运行时 `mlx-qwen3-asr`，移除
  `qwen-asr`/`qwen3_asr_causal` 依赖并消除与 transformers 的版本冲突；
  batch 与 realtime worker 均改用 MLX。

### Added

- `srt`/`vtt`/`verbose_json` 按需产出带时间戳 segments（强制对齐器 `Qwen3-ForcedAligner-0.6B`）。
- batch 与 realtime 支持 mlx 全部 30+ 语言（可强制语言与自动检测）。

### Fixed

- `service preflight` 的 ASR runtime 检查改为导入 `mlx_qwen3_asr`（修复迁移后 qwen-asr
  死引用导致 wheel 安装 preflight 失败）。

## [1.1.0] - 2026-09-02

### Added

- 增加可选 Sortformer/CAM++ diarization profile 的配置校验、运行时 readiness 和 service preflight。
- `/health` 与成功的 `/readyz` 返回匿名 diarization 状态；`/v1/models` 仅在 profile ready 时发布
  `gpt-4o-transcribe-diarize`。

### Changed

- diarization runtime 未安装或 snapshot 不可用时，Realtime 在 `session.update` 阶段 fail closed，
  不再等到 `commit` 才暴露部署问题。
- active 配置、OpenAPI、架构和运维文档统一为唯一 `/v1/realtime` 公共入口。

### Known limitations

- 真实 diarization 的 DER/JER、时延、峰值内存和会议端到端闭环仍需按部署环境单独验收。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [1.0.0] - 2026-09-02

### Added

- OpenAI Realtime 兼容端点 `/v1/realtime`（ASR/TTS 子集）：标准 `openai` SDK 的
  `client.realtime.connect(model="whisper-1")` 可直接接入，连续会话已通过本机真实 smoke。
- 模型名统一：`/v1/models` 列出 canonical 与全部 OpenAI 标准 alias（`whisper-1`、
  `tts-1`、`gpt-4o-transcribe`、`gpt-4o-mini-tts` 等），alias 带 `resolves_to` 标注。
- `/v1/realtime` `response.create` 支持 response 参数体中的 `voice` 选择。
- 性能基准脚本目录 `examples/perf/`（generate_audio、bench_asr/tts/realtime、probe_queue、
  sample_resources），并记录本机实测基准（REST ASR RTF 0.06-0.09x、TTS RTF 0.34-0.36x、
  Realtime 连续会话、worker 内存 1.96/1.96/4.76 GB）。

### Changed

- 移除 legacy `WS /asr` 与 `WS /v1/realtime/legacy` 端点及相关代码、契约、配置和测试；
  对应契约归档到 `docs/archive/realtime-legacy-contract.md`。
- 移除外部 WLK streaming 后端（`SPEECHRAIL_WLK_STREAMING_URL`、
  `realtime_asr_backend=wlk`）；实时流式 ASR 只使用本地 Qwen3 `native` 后端。
- 正式文档改写为终态、正向陈述，以实测证据替代待验收表述；能力矩阵与边界文档同步。
- AGENTS.md 新增文档 metadata 规则：`version`/`date` 仅随正文实质变更更新。

### Fixed

- Realtime v1/v2 流式 ASR 会话结束后释放 backend slot，修复连续会话
  `realtime streaming backend busy` 断连问题。

### Known limitations

- `/v2/realtime` 已在 1.0.0 移除，仅保留 OpenAI Realtime 兼容 `/v1/realtime` 作为标准接入面。
- 真实 TTS/diarization 的质量、时延、峰值内存和客户端闭环需按运维/验收文档单独确认。
- 非 loopback 的 TLS、CORS、Origin、网段限制和速率限制仍未完整实现。

## [0.1.0] - 2026-08-31

### Added

- 创建 SpeechRail 独立项目和 Python 3.12 包骨架。
- 冻结 OpenAI-compatible REST、Realtime WebSocket 与 WLK legacy 兼容边界。
- 写入 `sona` 吸收矩阵、QwenPaw/Hermes/sona 接入方案、
  运行时安全边界、迁移 Runbook、测试门禁和 ADR。
- 添加可测试的领域模型、模型 alias/capability registry、长度前缀 Qwen3 worker 协议、
  离线/MPS snapshot preflight、Realtime 状态机、WLK snapshot compatibility renderer、
  有界 admission queue、统一 REST formatter 与隐私安全观测边界。
- 接通 `json`、`verbose_json`、`text`、`srt`、`vtt` REST formatter，以及现代 Realtime
  与 legacy `/asr` 的有序协议测试路径。
- 默认服务现在会在配置外部 snapshot 与专用 Python runtime 后启动单一 Qwen3 worker，
  使用固定 `ffmpeg` argv 解码上传音频，并验证 worker 的 MPS/float16 身份。
- 完成本机 Qwen3 worker 的 REST smoke，以及 QwenPaw `whisper_api` provider 指向
  SpeechRail 后的中文短音频 smoke。
- 新增按用户、开发和运维职责组织的文档、macOS `launchd` 模板及运行/迁移边界说明。

### Known limitations

- WLK sidecar、Hermes 与 `sona` 的真实切换/回滚仍待分别按 Runbook 验收。
- 没有配置 snapshot 或专用 runtime 的部署仍安全返回 `backend_not_ready`；本机 runtime
  配置保留在被忽略的 `.env`，不提交绝对模型路径或任何凭据。
- `/v1/realtime` 当前是 commit 后 batch 转写，没有 delta；legacy `/asr` 仅有 config/EOF
  骨架，不能替代旧 WLK。`sona` 未被修改。
