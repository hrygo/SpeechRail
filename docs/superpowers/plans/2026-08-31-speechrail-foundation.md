# SpeechRail Foundation Implementation Plan

> **Status:** historical foundation plan. The ASR/TTS target architecture, Realtime v2 contract and
> `voice-realtime` migration details are superseded by the final runtime design, ADR-0006 and
> `contracts/realtime-v2.md`; do not execute future-integration wording here as the current plan.

> **For agentic workers:** Execute the tasks in order. Keep the public contract and the
> application ownership boundaries in the design spec. Do not modify the original
> `voice-realtime` working tree during this plan; its integration patch is a separately
> reviewed change set.

**Goal:** 将 `Qwen3-ASR-1.7B` 从 `voice-realtime` 的综合运行时提取为 SpeechRail 独立服务，
以 OpenAI-compatible REST、现代 Realtime WS 和 WLK legacy WS 同时服务 QwenPaw、Hermes
Agent 与 `voice-realtime`。

**Architecture:** 一个 supervisor 管理 FastAPI/ASGI、有限队列、Qwen3 batch worker 和
realtime worker/sidecar。所有后端输出先进入 SpeechRail 领域模型，再由 REST formatter、
Realtime event mapper 或 WLK compatibility serializer 输出。模型快照在仓库外，默认离线、
MPS fail-fast，调用方不 import `voice_realtime`。

**Tech Stack:** Python 3.12、FastAPI、Pydantic v2、Uvicorn、`uv`、Qwen3-ASR native
runtime、WhisperLiveKit compatibility adapter、pytest、Ruff、mypy、OpenAPI 3.1。

**Spec:** `docs/superpowers/specs/2026-08-31-speechrail-design.md`

## Global Constraints

- 公共模型 ID 使用 `speechrail/qwen3-asr-1.7b`；旧模型名只能作为登记 alias。
- 默认监听 `127.0.0.1:8201`，切换到 `8001` 前必须停止旧 WLK 并完成 parity 验收。
- 请求不下载模型、不接受远程音频 URL、不写入原始音频和完整 transcript 日志。
- 不把 `AudioHub`、会议状态、Sortformer、PostgreSQL、UI、TTS、LLM 或 Agent 编排迁入。
- 不使用多个 ASGI worker 复制模型；队列、worker slot、临时文件和取消路径必须可测试。
- 每个任务先写失败测试，再写最小实现；每个任务结束都执行该任务列出的命令并记录证据。
- `voice-realtime` 的修改只在其独立 feature branch 中进行，SpeechRail 仓库不直接复制或
  import 原项目包。

---

## Task 1: 提取 ASR 领域模型与 runtime profiles

**Files:**

- Create `src/speechrail/domain/contracts.py`。
- Create `src/speechrail/domain/errors.py`。
- Create `src/speechrail/config/profiles.py`。
- Create `src/speechrail/runtime/registry.py`。
- Create `tests/test_domain_contracts.py`。

**Implementation:**

1. 从 `voice-realtime` ASR contracts 提取 `TranscriptSegment`、`TranscriptWord`、
   `TranscriptResult`、`TranscriptWindow`，去除会议数据库字段和应用 import。
2. 为时间戳、`source_epoch`、partial/final、language 和 model alias 添加 Pydantic 校验。
3. 为 batch/realtime/legacy 声明能力 profile；未实现 word timestamp、diarization 或
   translation 时由 registry 返回明确 unsupported capability。
4. 实现 canonical model ID 与 alias 的单向解析；响应永远返回 canonical ID。

**Tests:**

- 无效时间戳、空文本和负 duration 被拒绝。
- alias 解析稳定且未知 model 返回 `model_not_found`。
- partial 不能被当成 final；同一 source epoch 的序号单调。

**Run:** `uv run pytest tests/test_domain_contracts.py -q --no-cov`。

## Task 2: 搬迁 Qwen3 batch worker 与隔离握手

**Files:**

- Create `src/speechrail/backends/qwen3_worker.py`。
- Create `src/speechrail/backends/qwen3_native.py`。
- Create `src/speechrail/runtime/worker_protocol.py`。
- Create `tests/test_worker_protocol.py`。
- Create `tests/test_qwen3_backend.py`。

**Implementation:**

1. 将 `voice_realtime.asr.workers.qwen3_native_worker` 改为 SpeechRail 私有 worker module；
   只接收 framed request，不接收 shell command 或任意 import path。
2. 在启动前校验模型目录、必要文件、runtime Python、snapshot 指纹和离线环境。
3. 保留 Qwen3 native 的 MPS identity 检查；`PYTORCH_ENABLE_MPS_FALLBACK=0` 时 device
   不符直接返回 `backend_identity_mismatch`。
4. supervisor 只启动一个长生命周期 worker；request ID、取消、超时、stderr 脱敏和优雅
   SIGTERM 都通过 adapter 管理。

**Tests:**

- framed protocol 的版本、长度、request ID、EOF、畸形帧和 worker error。
- 无模型、错误 snapshot、CPU fallback 和超时均映射为稳定 error code。
- fake backend 可证明同一模型不会为每个请求重复加载。

**Run:**

```bash
uv run pytest tests/test_worker_protocol.py tests/test_qwen3_backend.py -q --no-cov
uv run mypy src/speechrail/runtime src/speechrail/backends
```

## Task 3: 搬迁 realtime/WLK adapter 与领域事件映射

**Files:**

- Create `src/speechrail/backends/wlk_streaming.py`。
- Create `src/speechrail/realtime/events.py`。
- Create `src/speechrail/compatibility/wlk.py`。
- Create `src/speechrail/compatibility/presenters.py`。
- Create `tests/fixtures/wlk_full_snapshot.json`。
- Create `tests/test_realtime_events.py`。
- Create `tests/test_wlk_compatibility.py`。

**Implementation:**

1. 从 WLK adapter/events 中只提取 PCM window、partial、confirmed、EOF 和 timestamp
   语义；内部统一转成 `TranscriptWindow`。
2. `/v1/realtime` 使用明确 session state machine，校验 update/append/commit 顺序、
   Base64、单帧/连接上限和 commit exactly-once。
3. `/asr` serializer 重建旧 `config`、`lines`、`buffer_transcription` 和
   `ready_to_stop`；WLK raw JSON 不穿过 domain boundary。
4. legacy token 仅在兼容开关打开时接受；现代 WS 使用 Authorization header。

**Tests:**

- 固定 snapshot 的字段、顺序、时间戳和空 PCM EOF parity。
- 非法 Base64、越序事件、重复 commit、断线和超限释放资源。
- partial 被替换而不是累积为多条 final transcript。

**Run:** `uv run pytest tests/test_realtime_events.py tests/test_wlk_compatibility.py -q --no-cov`。

## Task 4: 完成 REST API 与媒体生命周期

**Files:**

- Modify `src/speechrail/app.py`。
- Create `src/speechrail/http/errors.py`。
- Create `src/speechrail/http/formatters.py`。
- Create `src/speechrail/runtime/admission.py`。
- Create `src/speechrail/media/temp_audio.py`。
- Create `tests/test_transcription_api.py`。

**Implementation:**

1. 保持 `/v1/audio/transcriptions` 的 multipart/OpenAI-compatible shape，支持
   `json`、`verbose_json`、`text`、`srt`、`vtt` 和 segment timestamps。
2. 用有界 streaming upload 和固定 argv 的 `ffmpeg` 处理容器格式；禁止 shell 拼接和
   URL 下载。限制文件大小、duration、prompt 长度、MIME 和 decode 失败。
3. 通过 admission queue 调用 batch adapter；队列满返回 `429 queue_full` + `Retry-After`，
   backend 未 ready 返回 `503 backend_not_ready`，超时释放 slot/临时文件。
4. 所有分支使用统一 error envelope 和 request ID；未知字段按兼容策略忽略或显式拒绝，
   不把 vendor traceback 暴露给客户端。

**Tests:**

- 每种 response format 的 content type、timestamp 和空 transcript 行为。
- 认证、未知模型、过大文件、非法 MIME、队列满、timeout、cancel 后文件清理。
- OpenAPI operationId/response schema 与真实路由一致。

**Run:**

```bash
uv run pytest tests/test_transcription_api.py tests/test_app_contract.py -q --no-cov
uv run ruff check src tests
```

## Task 5: 接通 Realtime 与 legacy HTTP/WS 路由

**Files:**

- Modify `src/speechrail/app.py`。
- Create `tests/test_websocket_contract.py`。

**Implementation:**

1. `/v1/realtime` 在握手后返回 session created，接入 realtime adapter，按契约发 delta、
   completed/error，并对慢客户端施加有界 buffer。
2. `/asr` 调用 compatibility adapter；保持当前 `voice-realtime` 对首帧、裸 PCM、full
   snapshot、空 PCM EOF 的可观察行为。
3. 对 SIGTERM、WebSocket disconnect、worker cancel 和 commit error 做幂等资源清理。

**Tests:**

- 正常事件顺序、断线、重连 source epoch、超限关闭和 exactly-once completed。
- legacy 首帧/EOF/parity fixture 与新 Realtime 领域结果的一致性。

**Run:** `uv run pytest tests/test_websocket_contract.py -q --no-cov`。

## Task 6: 为三个客户端准备独立接入变更

**Files in this repository:**

- Maintain `docs/04-integrations.md`。
- Maintain `docs/08-migration-runbook.md`。
- Maintain `examples/qwenpaw.md`。
- Maintain `examples/hermes.env.example`。
- Maintain `examples/voice-realtime.migration.env.example`。

**Separate `voice-realtime` branch changes:**

- Add `VR_SUBTITLE_EXTERNAL_URL` and `VR_SUBTITLE_MANAGED` to subtitle settings.
- Add a shared `SpeechRailRealtimeClient`, a meeting/subtitle `SpeechRailStreamingTranscriber`, and
  a voice-assistant `SpeechRailConversationSTTFactory`; keep `SubtitleProxy` as application coordinator.
- Make `run-all.sh` skip the child WLK server when `VR_SUBTITLE_MANAGED=false`.
- Keep `/asr` mode as rollback until full modern Realtime acceptance passes.

**Validation:**

- QwenPaw: `base_url=http://127.0.0.1:8201/v1`, canonical model, full app restart, REST smoke。
- Hermes: `STT_OPENAI_BASE_URL`/`STT_OPENAI_MODEL` only; global `OPENAI_BASE_URL` remains unchanged。
- `voice-realtime`: legacy parity, modern WS, meeting/SRT/DB flow and rollback。

**Run:** follow `docs/08-migration-runbook.md`; do not claim integration success from config-only checks。

## Task 7: 完成配置、安全和观测

**Files:**

- Modify `src/speechrail/config.py`。
- Create `src/speechrail/observability/logging.py`。
- Create `src/speechrail/observability/metrics.py`。
- Create `tests/test_security_boundaries.py`。
- Maintain `configs/speechrail.example.env` and `configs/speechrail.example.yaml`。

**Implementation:**

1. 将示例配置中的 queue、upload、duration、origin、auth、model snapshot 和 runtime
   profile 正式纳入 Settings，并在启动时 fail fast。
2. 结构化日志只包含 request/session/client/model/backend/duration/error 指纹，不含音频、
   key、完整 transcript、完整 prompt 或隐私路径。
3. 暴露低基数指标；不把 request ID、文件名、用户文本放入 label。
4. 为 loopback、LAN、无 key、错误 Bearer、CORS/origin、SSRF 和路径边界写测试。

**Run:**

```bash
uv run pytest tests/test_security_boundaries.py -q --no-cov
uv run mypy src
```

## Task 8: 发布验收、旁路切换与回滚

**Files:**

- Maintain `CHANGELOG.md`。
- Maintain `docs/05-runtime-deployment.md` through `docs/09-open-questions.md`。
- Maintain `contracts/openapi.yaml` and `contracts/realtime.md`。
- Create `docs/evidence/.gitkeep` only after evidence storage policy is approved; do not commit
  audio, model weights, API keys or full transcripts。

**Acceptance:**

1. `uv run pytest`、`uv run ruff check src tests`、`uv run mypy src` 全部通过。
2. OpenAPI 3.1 parser/linter 通过，且 `/health`、`/readyz`、`/v1/models`、
   `/v1/audio/transcriptions` 与代码响应一致。
3. 本机真实 Qwen3 MPS smoke 记录 snapshot、device/dtype、RTF、峰值内存和错误统计。
4. 8201 旁路 → 8001 切换 → 旧 WLK 回滚均完成，保留命令、时间、版本和未验证风险。
5. Git diff 不包含模型、音频、凭据、私有环境变量或无关仓库修改。

**Run:**

```bash
uv run pytest
uv run ruff check src tests
uv run mypy src
npx @redocly/cli lint contracts/openapi.yaml
```
