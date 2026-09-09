# SpeechRail TTS Delivery Refactor Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task, with a review checkpoint after each commit.

**Goal:** 在 REST TTS 与 Realtime v2 TTS 之间复用 public `AudioChunk` 流的顺序、response 边界、PCM16 和异步清理校验，并删除未被任何内部或公共调用方使用的 `SpeechRequest.instructions` 字段。

**Architecture:** `application/tts_delivery.py` 校验 `SpeechSynthesizer` port 输出；REST route 继续负责 PCM/WAV HTTP rendering，Realtime v2 route 继续负责 public response ID、event envelope、backpressure 和 session state。Qwen private IPC 与 `SpeechSession.audio_delta()` 仍保留各自防御性校验。

**Tech Stack:** Python 3.12、Pydantic v2、asyncio、FastAPI、pytest、Ruff、mypy。

---

## 执行边界

- 工作目录：`<path-to-SpeechRail>`
- 前置：完成 `2026-09-01-speechrail-app-composition-refactor.md`，确认 `http/routes/audio.py` 与 `http/routes/realtime_v2.py` 已存在。
- `SpeechRequest` 是内部 domain port，不出现在 `contracts/openapi.yaml` 或 Realtime wire contract；当前源码和测试除字段声明外没有 `instructions` 使用点。
- 本计划不改 `/v1/audio/speech` body、`session.update` 字段、voice ID、24 kHz mono PCM16、WAV rendering 或 error envelope。
- 不删除 `Qwen3TtsWorker` 的 private frame 顺序校验，也不删除 `SpeechSession.audio_delta()` 的 public event 顺序校验。
- voice catalog 继续以 `domain/tts.py::VOICE_PROFILES` 为唯一来源；当前没有第二份 voice instruction 常量需要删除。

## 目标文件

- Create: `src/speechrail/application/tts_delivery.py`
- Modify: `src/speechrail/application/__init__.py`
- Modify: `src/speechrail/domain/ports.py`
- Modify: `src/speechrail/http/routes/audio.py`
- Modify: `src/speechrail/http/routes/realtime_v2.py`
- Create: `tests/test_tts_delivery.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_realtime_v2_websocket.py`
- Modify: `tests/test_realtime_v2_session.py`
- Modify: `tests/test_qwen3_tts.py`
- Modify: `tests/test_tts_voices_api.py`

## Task 1: 固化三层校验职责与现有行为

**Files:**

- Create: `tests/test_tts_delivery.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_realtime_v2_websocket.py`
- Modify: `tests/test_realtime_v2_session.py`
- Modify: `tests/test_qwen3_tts.py`

- [ ] **Step 1: 增加 application stream 的失败测试**

覆盖：首 chunk 非 0、gap、duplicate、backend response ID 中途变化、奇数字节 PCM、source 抛错、consumer cancel、显式 `aclose()` 与空流。空流保持当前可完成语义，不在结构重构中新增“必须至少一块”的规则。

```python
async def test_rejects_backend_response_switch() -> None:
    source = chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-b", chunk_index=1, audio=b"\x00\x00"),
    )
    with pytest.raises(TTSDeliveryError, match="tts_response_id_invalid"):
        async for _ in iter_validated_audio(source):
            pass
```

- [ ] **Step 2: 锁定 REST 与 Realtime 的不同输出**

REST 测试断言 PCM raw stream/WAV header；Realtime 测试断言 public response ID 由 `SpeechSession` 生成、backend response ID 不泄漏、`response.audio.completed` 与 `session.completed` 顺序不变。

- [ ] **Step 3: 运行红灯**

```bash
uv run --extra dev pytest tests/test_tts_delivery.py tests/test_speech_api.py \
  tests/test_realtime_v2_websocket.py tests/test_realtime_v2_session.py tests/test_qwen3_tts.py \
  -q --no-cov
```

预期：现有测试通过，新 application helper 测试因模块尚不存在而失败。

## Task 2: 实现 public port 输出校验器

**Files:**

- Create: `src/speechrail/application/tts_delivery.py`
- Modify: `src/speechrail/application/__init__.py`
- Modify: `tests/test_tts_delivery.py`

- [ ] **Step 1: 定义稳定 application error 与 iterator**

```python
class TTSDeliveryError(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


async def iter_validated_audio(
    source: AsyncIterator[AudioChunk],
) -> AsyncIterator[AudioChunk]:
    expected_index = 0
    backend_response_id: str | None = None
    try:
        async for chunk in source:
            backend_response_id = backend_response_id or chunk.response_id
            if chunk.response_id != backend_response_id:
                raise TTSDeliveryError("tts_response_id_invalid")
            if chunk.chunk_index != expected_index:
                raise TTSDeliveryError("tts_chunk_order_invalid")
            if len(chunk.audio) % 2:
                raise TTSDeliveryError("tts_audio_invalid")
            expected_index += 1
            yield chunk
    finally:
        close = getattr(source, "aclose", None)
        if close is not None:
            await close()
```

`SpeechSynthesizer` 当前只承诺 `AsyncIterator`，并不保证 `aclose`；因此这里的可选 capability check 是有意的，不要为了消除一个局部 `getattr` 扩大 public port。若 source 暴露 `aclose` 就等待一次，否则只完成迭代器正常退出；不得捕获并改写 `CancelledError`。

- [ ] **Step 2: 验证 iterator cleanup**

用可观察 fake generator 证明完整消费、异常和下游取消都会运行一次 `finally`；不启动 Qwen worker。

- [ ] **Step 3: 运行并提交 helper**

```bash
uv run --extra dev pytest tests/test_tts_delivery.py -q --no-cov
uv run --extra dev ruff check src/speechrail/application/tts_delivery.py tests/test_tts_delivery.py
uv run --extra dev mypy src/speechrail/application/tts_delivery.py
git add src/speechrail/application/tts_delivery.py src/speechrail/application/__init__.py tests/test_tts_delivery.py
git commit -m "refactor: validate speechrail tts delivery"
```

## Task 3: 接入 REST 与 Realtime v2，保留 defense in depth

**Files:**

- Modify: `src/speechrail/http/routes/audio.py`
- Modify: `src/speechrail/http/routes/realtime_v2.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_realtime_v2_websocket.py`
- Modify: `tests/test_realtime_v2_session.py`

- [ ] **Step 1: 替换 REST 的局部计数器**

REST route 使用 `iter_validated_audio(synthesizer.synthesize(request))`，继续只 yield `chunk.audio`；WAV 路径继续有界收集后调用现有 PCM16 WAV renderer。保持 backend error 到既有 HTTP error 的映射。

- [ ] **Step 2: 在 Realtime event rendering 前验证**

Realtime v2 route 先经过 `iter_validated_audio`，再把 `chunk_index/audio` 交给 `SpeechSession.audio_delta(response_id=public_response_id, ...)`。backend response ID 只用于 application 内部一致性，不写入 wire event。

- [ ] **Step 3: 保留下游校验测试**

`Qwen3TtsWorker` 仍测试 private frame；`SpeechSession` 仍测试 public response/chunk 状态。若删除其中任一层后测试仍通过，补充能区分三层责任的 fixture，而不是合并实现。

- [ ] **Step 4: 运行并提交 route 接入**

```bash
uv run --extra dev pytest tests/test_tts_delivery.py tests/test_speech_api.py \
  tests/test_realtime_v2_websocket.py tests/test_realtime_v2_session.py tests/test_qwen3_tts.py \
  -q --no-cov
uv run --extra dev ruff check src/speechrail/application/tts_delivery.py \
  src/speechrail/http/routes/audio.py src/speechrail/http/routes/realtime_v2.py
uv run --extra dev mypy src
git add src/speechrail/http/routes/audio.py src/speechrail/http/routes/realtime_v2.py \
  tests/test_speech_api.py tests/test_realtime_v2_websocket.py tests/test_realtime_v2_session.py
git commit -m "refactor: share speechrail tts delivery checks"
```

## Task 4: 删除未使用的内部 `instructions` 字段

**Files:**

- Modify: `src/speechrail/domain/ports.py`
- Modify: `tests/test_tts_delivery.py`
- Modify: `tests/test_speech_api.py`

- [ ] **Step 1: 写额外字段拒绝测试**

```python
def test_speech_request_rejects_unknown_instructions() -> None:
    with pytest.raises(ValidationError):
        SpeechRequest(
            text="hello",
            voice="vivian",
            instructions="must not cross the internal port",
        )
```

- [ ] **Step 2: 收紧内部模型**

把 `SpeechRequest.model_config` 改为 `ConfigDict(frozen=True, extra="forbid")` 并删除 `instructions`。不要在 HTTP 或 Realtime schema 增加 replacement field；当前公共契约从未暴露该字段。

- [ ] **Step 3: 证明 voice catalog 未复制**

`tests/test_tts_voices_api.py` 断言 `/v1/voices` 的 ID 集合来自 `VOICE_PROFILES`，`SpeechRequest.voice` 的 allowlist 仍由 adapter/session 使用同一 catalog；不新增配置常量。

- [ ] **Step 4: 运行并提交 domain 清理**

```bash
uv run --extra dev pytest tests/test_tts_delivery.py tests/test_speech_api.py tests/test_tts_voices_api.py -q --no-cov
uv run --extra dev ruff check src/speechrail/domain/ports.py tests/test_tts_delivery.py tests/test_tts_voices_api.py
uv run --extra dev mypy src
git add src/speechrail/domain/ports.py tests/test_tts_delivery.py tests/test_speech_api.py tests/test_tts_voices_api.py
git commit -m "refactor: remove unused speech request field"
```

## Task 5: 项目门禁与闭环

- [ ] **Step 1: 运行 TTS 聚焦矩阵**

```bash
uv run --extra dev pytest \
  tests/test_tts_delivery.py tests/test_speech_api.py \
  tests/test_realtime_v2_websocket.py tests/test_realtime_v2_session.py \
  tests/test_qwen3_tts.py tests/test_qwen3_tts_worker.py tests/test_tts_voices_api.py \
  -q --no-cov
```

- [ ] **Step 2: 运行项目门禁**

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

- [ ] **Step 3: 记录真实 smoke 状态**

只有在外部 TTS runtime、snapshot 和用户授权均具备时，才验证 REST PCM/WAV、Realtime response cancel、slow consumer 与 24 kHz mono PCM16。缺少条件时明确标为 `unverified`，不以 fake backend 替代真实质量验收。

## 完成标准

- [ ] REST 与 Realtime v2 共用 application-level `AudioChunk` stream 校验。
- [ ] backend response ID 不泄漏到 public Realtime response ID。
- [ ] private IPC、application port、wire state 三层校验均有独立测试。
- [ ] `SpeechRequest.instructions` 已删除且未知字段 fail-closed，公共契约无变化。
- [ ] voice catalog 仍只有 `VOICE_PROFILES` 一个事实源。
- [ ] 全量质量门禁通过，真实 runtime 状态单独记录。
