# Changelog

## [Unreleased]

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
