# OpenAI Realtime 交割实现计划

> 状态：已完成（2026-09-02）。`/v2/realtime` 保留条款已由 ADR-0009 supersede；当前唯一
> 实时入口为 `/v1/realtime`。

> **For agentic workers:** REQUIRED SUB-SKILL: Use inline execution with this plan task-by-task. Each step is tracked with checkbox syntax and must complete its own test cycle.

**Goal:** 将 `WS /v1/realtime` 补齐为带实时匿名分人、可对账事件元数据、完整 EOF/取消语义的 OpenAI-compatible ASR/TTS 协议，并同步批量 diarized 输出。

**Architecture:** 复用现有 `RealtimeAsrFactory`、`StreamingAsrEvent.segments`、`DiarizationCoordinator` 和 `TranscriptResult`，由 `compatibility` 负责协议呈现、`application` 负责连接级生命周期管理，HTTP route 只负责传输边界；不把会议身份、音频持久化或 LLM 编排引入 SpeechRail。

**Tech Stack:** Python 3.12、FastAPI WebSocket、Pydantic v2、pytest、ruff、mypy、OpenAPI 3.1。

**Spec:** `docs/superpowers/specs/2026-09-02-openai-realtime-handover-design.md`；需求基线为 `../sona/docs/operations/SpeechRail-OpenAI标准协议功能需求交割单.md`。

## Global Constraints

- Python 版本必须满足 `>=3.12,<3.13`，使用 `uv` 和 PEP 621 元数据。
- OpenAI realtime 输入固定为 16 kHz、单声道、16-bit little-endian PCM；TTS 输出为 24 kHz、单声道、PCM16。
- 未启用或不可用 diarization profile 时返回 `diarization_not_available`，不得伪造 speaker 或回退本地模型。
- 不持久化音频、PCM、embedding、完整转写、已知说话人身份或凭据。
- 保留 loopback、API key、队列、超时和现有资源边界；不启动外部 runtime，不下载模型。
- 既有未提交改动属于用户/并行工作，只修改本计划列出的本任务文件和不重叠 hunk。

---

### Task 1: OpenAI 事件适配器与 session 参数

**Files:**
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Test: `tests/test_realtime_openai.py`

**Interfaces:**
- Produces `transcription_segment(...)`、`response_cancelled(...)` 或等价的窄 formatter，以及 `parse_openai_session(...)` 返回的已验证连接配置。
- 保持现有 `RealtimeAdapterError`、`apply_session_update`、`validate_append` 的兼容调用方式。

- [ ] **Step 1: Write failing tests**

  在 `tests/test_realtime_openai.py` 增加以下行为断言：segment payload 使用标准事件名并包含 `id/text/speaker/start/end/content_index`；session update 可接受 transcription 内 diarization 与 `languages/keywords/timestamp_granularities/known_speaker_*`；非法类型返回 `invalid_session` 或专用稳定错误；每个 formatter 不再依赖固定 event id。

- [ ] **Step 2: Run focused tests to verify RED**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: 新增 segment/参数/唯一事件元数据断言失败，既有测试失败数保持可定位。

- [ ] **Step 3: Implement minimal adapter changes**

  增加标准 segment 与 cancelled payload；让 session parser 严格校验对象、字符串列表和 `word/segment` 粒度，并把已知说话人字段留在内存配置中。保留已有 alias 解析，新增 `gpt-4o-transcribe-diarize` 的窄映射，不在 adapter 中生成任何 speaker。

- [ ] **Step 4: Run focused tests to verify GREEN**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: `tests/test_realtime_openai.py` 全部通过。

- [ ] **Step 5: Commit**

  Stage only adapter and its test; run `git diff --staged --check`; commit with `feat: align OpenAI realtime event adapter`.

### Task 2: `/v1/realtime` 实时分人与事件序

**Files:**
- Modify: `src/speechrail/http/routes/realtime_openai.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Test: `tests/test_realtime_openai.py`

**Interfaces:**
- Consumes `AppServices.diarization_engine`, `DiarizationCoordinator`, `StreamingAsrEvent.segments`。
- Produces server events with top-level `event_id`, `session_id`, `sequence`; emits segment events before transcription completed.

- [ ] **Step 1: Write failing integration tests**

  扩展 fake streaming session 使 commit 返回多个带 `TranscriptSegment` 的结果，并新增 fake diarization engine/session。测试启用 diarization 后得到至少两个匿名 `spk_*` segment、相同标签保持一致、时间戳来自 segment；关闭时不出现 speaker segment；无 profile 时返回 `diarization_not_available`。另测连接内所有服务端事件的 `sequence == range(1, n+1)`、event ids 唯一且带 session id。

- [ ] **Step 2: Run focused tests to verify RED**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: 新增 diarization、sequence、唯一 id 断言失败。

- [ ] **Step 3: Implement connection-scoped event sender**

  在 `realtime_openai` 内用 `asyncio.Lock` 包住统一发送 helper：分配单调 sequence、生成 UUID event id、补充 session id，并让主循环、ASR reader、TTS task、错误处理全部经 helper 发送。`session.update` 创建并验证 `DiarizationCoordinator`；append/commit/finalize 按设计接线；只在真实标注 segment 存在时发标准 segment event。

- [ ] **Step 4: Run focused tests to verify GREEN**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: OpenAI realtime 测试全部通过，既有 ASR/TTS alias 测试无回归。

- [ ] **Step 5: Commit**

  Stage本任务涉及的 route、adapter hunk 和测试；运行 staged diff check；commit with `feat: add ordered realtime diarization events`。

### Task 3: EOF、TTS cancel 与资源释放

**Files:**
- Modify: `src/speechrail/http/routes/realtime_openai.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Test: `tests/test_realtime_openai.py`

**Interfaces:**
- Consumes existing TTS `iter_validated_audio` and `RealtimeAsrSession.close/release` lifecycle。
- Produces final completed/segment ordering, cancelled response terminal event, and no post-cancel audio delta。

- [ ] **Step 1: Write failing tests**

  增加可控的 blocking TTS fake，验证 `response.cancel` 后没有新的 `response.output_audio.delta`，response 状态为 cancelled，随后可重新提交新的文本；验证 commit 的 terminal event 在所有 segment 后到达；断线释放 ASR 与 diarization session。

- [ ] **Step 2: Run focused tests to verify RED**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: 取消测试发现当前 `finally` 仍发送 completed 生命周期或无法证明新响应；EOF/资源测试至少有一项失败。

- [ ] **Step 3: Implement minimal lifecycle fix**

  为 TTS task 区分 completed/cancelled/error，取消时关闭迭代器并抑制后续 audio delta，发送稳定 cancelled terminal payload；清理 pending text 和旧 response 状态。commit 时先 drain ASR，再按 segment → completed 顺序发送；finally 关闭并 release ASR、diarization、TTS 资源。

- [ ] **Step 4: Run focused tests to verify GREEN**

  Run: `uv run --extra dev pytest tests/test_realtime_openai.py -q --no-cov`

  Expected: focused realtime tests 全部通过。

- [ ] **Step 5: Commit**

  Stage route/adapter/test changes only; commit with `fix: make OpenAI realtime EOF and cancel terminal`。

### Task 4: 批量 diarized JSON 与模型发现

**Files:**
- Modify: `src/speechrail/http/routes/audio.py`
- Modify: `src/speechrail/http/routes/system.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Modify: `src/speechrail/compatibility/presenters.py` or `src/speechrail/http/formatters.py` only if current response shape requires it
- Test: `tests/test_transcription_api.py`, `tests/test_app_contract.py`

**Interfaces:**
- Consumes `AppServices.diarization_engine` and existing validated `TranscriptResult`/`TranscriptSegment`。
- Produces stable verbose/diarized JSON with anonymous `speaker`/`speakers` and advertises the diarize alias only when profile is available.

- [ ] **Step 1: Write failing tests**

  新增批量请求 `response_format=diarized_json` 与 `model=gpt-4o-transcribe-diarize` 的成功响应测试；无 diarization profile 时断言 `diarization_not_available`；`/v1/models` 断言 alias 的 `resolves_to` 与可用能力一致；普通 JSON/verbose_json 既有形状保持不变。

- [ ] **Step 2: Run focused tests to verify RED**

  Run: `uv run --extra dev pytest tests/test_transcription_api.py tests/test_app_contract.py -q --no-cov`

  Expected: 新增 response format/alias/profile 测试失败。

- [ ] **Step 3: Implement batch path**

  仅在请求明确选择 diarize model/format 时创建有界 diarization session、把解码后的 PCM 交给 coordinator，并用现有 formatter 输出已验证 segments；不改变普通转写的默认行为，不持久化输入。系统模型列表按当前 profile 可用性输出 alias。

- [ ] **Step 4: Run focused tests to verify GREEN**

  Run: `uv run --extra dev pytest tests/test_transcription_api.py tests/test_app_contract.py -q --no-cov`

  Expected: 批量与系统契约测试全部通过。

- [ ] **Step 5: Commit**

  Stage batch route/system/formatter and tests; commit with `feat: expose batch diarized transcription compatibility`。

### Task 5: 公共契约与迁移文档

**Files:**
- Modify: `contracts/realtime-openai.md`
- Modify: `contracts/openapi.yaml`
- Modify: `docs/users/api-contract.md` and/or `docs/users/integrations.md` only for directly affected claims
- Test: `tests/test_websocket_contract.py` and relevant contract tests

- [ ] **Step 1: Update contract tests or assertions**

  补充 segment schema、sequence/event_id/session_id、cancelled terminal 和 diarization unavailable 的契约断言；v2 移除由 ADR-0009 断言。

- [ ] **Step 2: Run contract tests to verify RED where behavior is not yet documented**

  Run: `uv run --extra dev pytest tests/test_websocket_contract.py -q --no-cov`

  Expected: 只在新行为断言尚未实现/文档未同步处失败；已有 legacy contract 保持通过。

- [ ] **Step 3: Update docs and OpenAPI**

  明确 client/server event 全量清单、segment 字段单位、手动 commit EOF、取消后资源/上下文语义、alias 可用性和 v2 迁移边界；不声称真实 TTFT/TTFA/DER 已由 fake 测试验收。

- [ ] **Step 4: Run contract and lint checks**

  Run: `uv run --extra dev pytest tests/test_websocket_contract.py -q --no-cov` and `npx @redocly/cli lint contracts/openapi.yaml`。

  Expected: tests pass and Redocly exits 0。

- [ ] **Step 5: Commit**

  Stage only contract/docs files and tests; commit with `docs: document OpenAI realtime diarization handover`。

### Task 6: Full verification and handoff

**Files:**
- No planned source changes; only fix regressions in their owning task before this gate.

- [ ] **Step 1: Run complete code gate**

  Run: `uv run --extra dev pytest`; `uv run --extra dev ruff check src tests`; `uv run --extra dev mypy src`; `npx @redocly/cli lint contracts/openapi.yaml`; `rtk git diff --check`。

- [ ] **Step 2: Inspect evidence and dirty worktree**

  核对测试数量/失败数、lint/typecheck 退出码、OpenAPI lint 输出和 `git status --short`；确认未暂存 `.env`、音频、模型、日志或并行文件。

- [ ] **Step 3: Run read-only runtime checks when available**

  只读取当前服务状态并检查 `/health`、`/readyz`、`/v1/models`；不安装/重启/停用服务，不改变外部 runtime。若真实模型或服务不可用，报告为未验证，不用 `SPEECHRAIL_BACKEND_READY` 掩盖。

- [ ] **Step 4: Final handoff**

  汇总实际改动文件、commit、测试结果、运行态、未验证风险、未触碰的并行改动及可恢复回退路径。
