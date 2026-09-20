# OpenAI Realtime Current Wire + External LLM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `/v1/realtime` 收敛到 current OpenAI wire，并接入可选的 OpenAI-compatible 外部 LLM，同时用官方 `openai-node` WebSocket 客户端对真实 loopback 服务完成兼容性验收。

**Architecture:** 保留 ADR-0009 的唯一 `/v1/realtime` 入口，删除 legacy/current 双 wire；协议解析和事件构造留在 `compatibility`，会话编排留在 `application`，外部语言模型通过独立 domain port 注入。`transcription` 会话只做 ASR，`realtime` 会话通过外部 LLM 生成文本，再按 output modality 走文本或现有 TTS。

**Tech Stack:** Python 3.12、FastAPI/Starlette WebSocket、Pydantic v2、asyncio、现有 ASR/TTS ports、OpenAI-compatible Responses streaming、Node.js 22、`openai@7.19.0`、官方 `OpenAIRealtimeWebSocket`。

**Spec:** `docs/superpowers/specs/2026-09-20-openai-realtime-current-wire-external-llm-design.md`

## Global Constraints

- Python 固定为 `>=3.12,<3.13`；不新增模型下载、远程音频读取或隐藏网络访问。
- `/v1/realtime` 是唯一公共 Realtime 入口；不保留旧事件 alias，不新增 `/v2/realtime`。
- 外部 LLM 默认关闭；secret value 不进入仓库、Settings repr、日志、fixture 或错误消息。
- 不记录 API key、Authorization、原始 PCM、Base64、完整 prompt 或完整转写正文。
- ASR/TTS 继续遵守单 worker、Resource Governor、队列上限和 cancel/backpressure 约束。
- SpeechRail 独有的 `/v1/voices*`、VoiceDesign、Base clone、preview、quality-runs、voice revision、voice binding、render receipt 与 `speechrail.*` 扩展不得因 Realtime wire 重构删除或降级。
- 单元和 loopback 测试使用 fake ASR/LLM/TTS；不下载模型、不访问云端。
- 未通过官方 SDK 黑盒测试，不得在文档或 capability 中宣称 OpenAI SDK compatible。

## Review Focus

- 当前 SDK 发送嵌套 `session.audio` 与 `output_modalities` 时，服务必须返回当前 session schema，而不是旧 flat 字段；由 Task 1/Task 2 的 parser 和 Node harness 覆盖。
- 音频 commit 后没有额外文本 item 时，`response.create` 仍必须能够消费已完成的 user conversation item；由 Task 4/Task 5 覆盖。
- `response.cancel` 在 LLM token、句子 planner 或 TTS 已启动的三个时点都必须产生单一 cancelled 终态；由 Task 5 覆盖。
- 外部 provider 返回 malformed SSE、超时或未配置时，必须返回稳定 error，不泄漏 provider 响应正文；由 Task 4/Task 6 覆盖。
- 官方 SDK 不应看到 `conversation.item.created` 或 `response.audio.*`，且 `response.done` 必须带非空、可解析的 output/status；由 Task 1/Task 7 覆盖。

---

### Task 1: Freeze the current Realtime contract and event vocabulary

**Files:**
- Modify: `contracts/realtime-openai.md`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Test: `tests/test_realtime_openai.py`
- Test: `tests/test_websocket_contract.py`

**Interfaces:**
- Consumes: existing `apply_session_update`, `session_created`, `session_updated`, response event builders, and existing `RealtimeAdapterError`.
- Produces: `RealtimeSessionConfig`, `build_audio_response_events(text: str, audio: bytes) -> list[dict[str, object]]`, current-only parsed session state, and event builders that emit `conversation.item.added/done`, `response.output_audio.*`, `response.output_audio_transcript.*`, `response.output_text.*`, and non-empty `response.done` output.
- `RealtimeSessionConfig` fields are `session_type: Literal["realtime", "transcription"]`, `output_modalities: tuple[Literal["text", "audio"], ...]`, `input_sample_rate: int`, `output_sample_rate: int`, `output_voice: str | None`, `languages: tuple[str, ...]`, `prompt: str`, and `turn_detection: TurnDetectionConfig | None`; `TurnDetectionConfig` is the validated discriminated union for `manual`, `server_vad`, and rejected `semantic_vad`.
- Test helpers defined in this task: `base_config() -> RealtimeSessionConfig` and `current_session(*, languages: list[str] | None = None, turn_type: str = "server_vad") -> dict[str, object]`.

- [ ] **Step 1: Write failing current-wire tests**

```python
def test_current_session_uses_nested_audio_and_output_modalities() -> None:
    updated = apply_session_update(
        base_config(),
        {
            "type": "session.update",
            "session": {
                "type": "realtime",
                "output_modalities": ["audio"],
                "audio": {
                    "input": {"format": {"type": "audio/pcm", "rate": 24_000}},
                    "output": {"format": {"type": "audio/pcm"}, "voice": "alloy"},
                },
            },
        },
    )
    assert updated.output_modalities == ("audio",)
    assert updated.output_voice == "alloy"


def test_legacy_audio_events_are_not_emitted() -> None:
    events = build_audio_response_events(text="hello", audio=b"\\x00\\x00")
    assert all(event["type"] != "response.audio.delta" for event in events)
    assert any(event["type"] == "response.output_audio.delta" for event in events)
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_websocket_contract.py -q`

Expected: FAIL because the existing parser ignores `output_modalities`, nested output voice, and still exposes legacy event builders.

- [ ] **Step 3: Replace the dual wire with typed current-only parsing**

Implement the smallest current schema in `openai_realtime.py`: `session.type`, `output_modalities`, nested input/output audio format, nested voice, response-level output modality/voice, and current event names. Remove the public `wire_profile` branch and make unsupported fields return `RealtimeAdapterError` instead of being silently ignored.

- [ ] **Step 4: Make `response.done` describe the actual output**

Build one assistant output item with the emitted content part, final text/transcript, status, and usage fields. A completed response must not contain `output: []` when text or audio was produced.

- [ ] **Step 5: Run the focused tests and update the contract document**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_websocket_contract.py -q`

Expected: PASS with no legacy event literal in emitted server events; update `contracts/realtime-openai.md` to match the tested event sequence and supported subset.

- [ ] **Step 6: Commit the contract-only change**

```bash
git add contracts/realtime-openai.md src/speechrail/compatibility/openai_realtime.py tests/test_realtime_openai.py tests/test_websocket_contract.py
git commit -m "refactor: make realtime wire current-only"
```

### Task 2: Align ASR language and VAD ports with the current session contract

**Files:**
- Modify: `src/speechrail/domain/ports.py`
- Modify: `src/speechrail/backends/qwen3_streaming.py`
- Modify: `src/speechrail/application/realtime_openai.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Test: `tests/test_backend_ports.py`
- Test: `tests/test_realtime_openai.py`
- Test: `tests/test_realtime_vad_bargein.py`

**Interfaces:**
- Consumes: current session `audio.input.transcription.languages`, `transcription.delay`, and `audio.input.turn_detection`.
- Produces: `RealtimeAsrFactory.create(*, languages: tuple[str, ...] | None, prompt: str)`, explicit VAD capability errors, and unchanged `StreamingAsrEvent` terminal semantics.
- Test helper consumed from Task 1: `current_session(...)`.

- [ ] **Step 1: Add failing tests for language preservation and unsupported semantic VAD**

```python
def test_realtime_keeps_all_transcription_languages() -> None:
    config = apply_session_update(base_config(), current_session(languages=["zh", "en"]))
    assert config.languages == ("zh", "en")


def test_semantic_vad_is_rejected_until_implemented() -> None:
    with pytest.raises(RealtimeAdapterError, match="semantic_vad"):
        apply_session_update(base_config(), current_session(turn_type="semantic_vad"))
```

- [ ] **Step 2: Run the ASR/VAD tests and verify they fail**

Run: `uv run --extra dev pytest tests/test_backend_ports.py tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py -q`

Expected: FAIL because the factory accepts only one `language` and the parser currently allows only `manual/server_vad` without preserving current transcription hints.

- [ ] **Step 3: Change the port and native adapter to carry a language tuple**

Update `RealtimeAsrFactory.create` and `NativeRealtimeFactory.create` to accept `languages`. Do not select `languages[0]` in the compatibility layer. If the Qwen adapter cannot honor multiple hints, pass automatic language mode or return a stable `language_not_supported` error according to the adapter capability; never silently claim multi-language support.

- [ ] **Step 4: Add explicit current VAD parameter validation**

Keep existing `SpeechAdmission` and `server_vad` defaults. Validate `threshold`, `prefix_padding_ms`, `silence_duration_ms`, `create_response`, and `interrupt_response` at the boundary. Reject `semantic_vad` with `unsupported_operation` until a semantic detector exists.

- [ ] **Step 5: Run VAD and ASR regression tests**

Run: `uv run --extra dev pytest tests/test_backend_ports.py tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py -q`

Expected: PASS, including barge-in, empty commit, rollover, and no duplicated terminal item events.

- [ ] **Step 6: Commit the ASR contract change**

```bash
git add src/speechrail/domain/ports.py src/speechrail/backends/qwen3_streaming.py src/speechrail/application/realtime_openai.py src/speechrail/compatibility/openai_realtime.py tests/test_backend_ports.py tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py
git commit -m "refactor: align realtime asr hints with current wire"
```

### Task 3: Add the external language-model port and OpenAI-compatible adapter

**Files:**
- Create: `src/speechrail/domain/realtime_llm.py`
- Create: `src/speechrail/backends/openai_compatible_llm.py`
- Modify: `src/speechrail/config/__init__.py`
- Modify: `src/speechrail/application/services.py`
- Test: `tests/test_realtime_llm.py`
- Test: `tests/test_application_composition.py`

**Interfaces:**
- Consumes: validated text conversation items and non-secret provider settings.
- Produces:

```python
class RealtimeLanguageModel(Protocol):
    async def stream(
        self, request: RealtimeLLMRequest
    ) -> AsyncIterator[RealtimeLLMDelta]: ...

    async def cancel(self, response_id: str) -> None: ...

    def readiness(self) -> ProviderReadiness: ...
```

- Test helpers defined in this task: `request(response_id: str) -> RealtimeLLMRequest`,
  `mock_sse_client(body: str) -> httpx.AsyncClient`, and
  `collect(stream: AsyncIterator[RealtimeLLMDelta]) -> Awaitable[list[RealtimeLLMDelta]]`.

- [ ] **Step 1: Write fake-provider contract tests**

```python
async def test_openai_compatible_llm_yields_only_text_deltas() -> None:
    provider = OpenAICompatibleLanguageModel(client=mock_sse_client(
        '{"type":"response.output_text.delta","delta":"hello"}\n'
        '{"type":"response.completed","response":{"status":"completed"}}\n'
    ))
    assert [delta.text async for delta in provider.stream(request("resp_1"))] == ["hello"]


async def test_malformed_provider_event_is_sanitized() -> None:
    with pytest.raises(ExternalProviderError, match="provider_response_invalid"):
        await collect(OpenAICompatibleLanguageModel(client=mock_sse_client("not-json")))
```

- [ ] **Step 2: Run the provider tests and verify they fail**

Run: `uv run --extra dev pytest tests/test_realtime_llm.py -q`

Expected: FAIL because the provider port and adapter do not exist.

- [ ] **Step 3: Implement the port and validated SSE adapter**

Use an injected async HTTP client. Send only text conversation, instructions, configured model, and `store:false`; parse `response.output_text.delta`, terminal status, and provider errors. Bound response body size, apply `request_timeout_seconds`, and map network/HTTP/malformed responses to stable `ExternalProviderError` codes without including response body content.

- [ ] **Step 4: Add opt-in configuration and composition**

Add `realtime_llm_provider`, `realtime_llm_base_url`, `realtime_llm_model`, `realtime_llm_api_key_ref`, and `realtime_llm_timeout_seconds` to `Settings`. Resolve the secret at composition time; ensure `model_dump`, logs, diagnostics, and capability snapshots contain only provider/model/readiness, never the secret.

- [ ] **Step 5: Run provider and composition tests**

Run: `uv run --extra dev pytest tests/test_realtime_llm.py tests/test_application_composition.py -q`

Expected: PASS for disabled provider, configured provider, malformed SSE, timeout, cancellation, and secret redaction.

- [ ] **Step 6: Commit the provider boundary**

```bash
git add src/speechrail/domain/realtime_llm.py src/speechrail/backends/openai_compatible_llm.py src/speechrail/config/__init__.py src/speechrail/application/services.py tests/test_realtime_llm.py tests/test_application_composition.py
git commit -m "feat: add optional realtime external llm port"
```

### Task 4: Connect conversation state, external LLM, and TTS

**Files:**
- Modify: `src/speechrail/application/realtime_openai.py`
- Modify: `src/speechrail/http/routes/realtime_openai.py`
- Modify: `src/speechrail/realtime/turn_collection.py`
- Test: `tests/test_realtime_openai.py`
- Test: `tests/test_realtime_vad_bargein.py`
- Test: `tests/test_tts_streaming_splitter.py`

**Interfaces:**
- Consumes: `RealtimeLanguageModel.stream/cancel`, completed ASR conversation items, current output modality, and existing `SpeechSynthesizer` port.
- Produces: one response task per active response, deterministic event ordering, sentence-buffered TTS, and one terminal `response.done` status.
- Test helpers defined in this task: `run_fake_realtime_turn(*, session_type: str, output_modalities: list[str], audio: bytes, llm_deltas: list[str]) -> Awaitable[list[dict[str, object]]]`, `run_cancel_during_tts() -> Awaitable[list[dict[str, object]]]`, `event_types(events) -> list[str]`, `joined_text(events) -> str`, and `count_type(events, event_type: str) -> int`.

- [ ] **Step 1: Write failing conversation-path tests**

```python
async def test_audio_commit_can_create_response_without_pending_text() -> None:
    events = await run_fake_realtime_turn(
        session_type="realtime",
        output_modalities=["text"],
        audio=b"pcm",
        llm_deltas=["hello", " world"],
    )
    assert event_types(events)[-1] == "response.done"
    assert "hello world" in joined_text(events)


async def test_cancel_stops_llm_and_tts_and_emits_one_cancelled_response() -> None:
    events = await run_cancel_during_tts()
    assert count_type(events, "response.done") == 1
    assert events[-1]["response"]["status"] == "cancelled"
```

- [ ] **Step 2: Run the conversation tests and verify they fail**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py -q`

Expected: FAIL because `_create_response` currently requires `_pending_text`, no LLM task is started, and `response.done.output` is empty.

- [ ] **Step 3: Add conversation state and response task ownership**

Store committed user items in session order. Allow explicit `response.create` to use the conversation; when `server_vad.create_response=true`, start the same response path automatically. Reject a second active response with stable `invalid_state` unless it is an explicit cancel/restart sequence.

- [ ] **Step 4: Stream text modality and audio modality separately**

For `text`, emit `response.output_text.delta/done`. For `audio`, retain the LLM text internally, emit `response.output_audio_transcript.delta/done`, split text with the existing bounded sentence planner, and pass each sentence to TTS as ordered PCM chunks. Do not emit audio before `response.output_item.added` and `response.content_part.added`.

- [ ] **Step 5: Implement cancellation and failure finalization**

Make `response.cancel`, WebSocket disconnect, LLM error, and TTS error converge on one response finalizer. The finalizer cancels the provider task, closes the TTS iterator, emits exactly one `response.done`, and releases the existing admission slot.

- [ ] **Step 6: Run the full Realtime unit regression**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py tests/test_tts_streaming_splitter.py -q`

Expected: PASS for text/audio output, automatic/manual response creation, barge-in, cancel during each pipeline stage, slow consumer, and provider failure.

- [ ] **Step 7: Commit the conversation integration**

```bash
git add src/speechrail/application/realtime_openai.py src/speechrail/http/routes/realtime_openai.py src/speechrail/realtime/turn_collection.py tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py tests/test_tts_streaming_splitter.py
git commit -m "feat: connect realtime conversation to external llm"
```

### Task 5: Publish truthful capabilities and update the public contract

**Files:**
- Modify: `src/speechrail/application/capability_snapshot.py`
- Modify: `src/speechrail/http/routes/system.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Modify: `contracts/realtime-openai.md`
- Modify: `docs/users/README.md`
- Test: `tests/test_capability_snapshot.py`
- Test: `tests/test_app_contract.py`

**Interfaces:**
- Consumes: provider readiness, current ASR/TTS/VAD capabilities, and configured output modalities.
- Produces: model/session capability responses that distinguish transcription-only from full realtime conversation.
- Test helpers defined in this task: `settings_without_llm() -> Settings` and `capability_snapshot(settings: Settings) -> dict[str, object]`.

- [ ] **Step 1: Write failing capability tests**

```python
def test_unconfigured_external_llm_is_not_advertised_as_full_realtime() -> None:
    snapshot = capability_snapshot(settings_without_llm())
    assert snapshot["realtime"]["conversation"]["ready"] is False
    assert snapshot["realtime"]["transcription"]["ready"] is True
```

- [ ] **Step 2: Implement truthful readiness and model listing**

Expose provider/model readiness without secrets. Do not list a full conversation model when no external LLM is configured. Keep `gpt-live-transcribe`/transcription capabilities separate from the virtual conversation capability.

- [ ] **Step 3: Remove stale contract claims**

Delete docs that say `response.create` only synthesizes a preceding text item, list old event names, or imply LLM/tool support that is not implemented. Document explicit unsupported errors and the provider privacy boundary.

- [ ] **Step 4: Run capability and contract tests**

Run: `uv run --extra dev pytest tests/test_capability_snapshot.py tests/test_app_contract.py -q`

Expected: PASS with disabled/enabled provider snapshots and no stale legacy event claims in the checked contract text.

- [ ] **Step 5: Commit the public contract update**

```bash
git add src/speechrail/application/capability_snapshot.py src/speechrail/http/routes/system.py src/speechrail/compatibility/openai_realtime.py contracts/realtime-openai.md docs/users/README.md tests/test_capability_snapshot.py tests/test_app_contract.py
git commit -m "docs: publish truthful realtime capabilities"
```

### Task 6: Protect SpeechRail-owned voice management and rendering semantics

**Files:**
- Modify: `src/speechrail/application/realtime_openai.py`
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Modify: `contracts/realtime-openai.md`
- Test: `tests/test_voice_revision_contract.py`
- Test: `tests/test_voice_design_registration.py`
- Test: `tests/test_voice_safe_listing.py`
- Test: `tests/test_tts_voices_api.py`
- Test: `tests/test_tts_voice_clone.py`
- Test: `tests/test_realtime_openai.py`

**Interfaces:**
- Consumes: current `/v1/voices*` REST contract, `resolve_binding`, active TTS capability router, `voice_revision`, render receipt registry, and opt-in `speechrail.*` Realtime extensions.
- Produces: unchanged voice catalog CRUD/preview/clone behavior and Realtime audio responses that use the selected SpeechRail voice without exposing private asset paths or reference audio.
- Test helpers defined in this task: `render_receipt_for_voice(voice_id: str, expected_revision: str) -> RenderReceipt` and `openapi_paths() -> set[str]`.

- [ ] **Step 1: Add regression assertions before changing Realtime code**

```python
def test_realtime_voice_selection_keeps_resolved_revision() -> None:
    result = render_receipt_for_voice("custom-voice", expected_revision="vr_" + "a" * 32)
    assert result.voice_id == "custom-voice"
    assert result.voice_revision == "vr_" + "a" * 32


def test_voice_management_routes_remain_available() -> None:
    paths = openapi_paths()
    assert "/v1/voices" in paths
    assert "/v1/voices/clone" in paths
    assert "/v1/voices/previews" in paths
```

- [ ] **Step 2: Run the voice regression tests and record the baseline**

Run: `uv run --extra dev pytest tests/test_voice_revision_contract.py tests/test_voice_design_registration.py tests/test_voice_safe_listing.py tests/test_tts_voices_api.py tests/test_tts_voice_clone.py tests/test_realtime_openai.py -q`

Expected: PASS before current-wire edits; any pre-existing failure is recorded separately and is not hidden by this plan.

- [ ] **Step 3: Keep voice binding below the OpenAI wire layer**

Ensure current `session.audio.output.voice` and response-level voice resolve through the existing catalog and `resolve_binding`; do not copy clone paths, reference audio, or internal model IDs into standard events. Keep `voice_revision` and `render_receipt` as SpeechRail metadata only.

- [ ] **Step 4: Preserve namespaced extensions as opt-in additions**

Keep `speechrail.diarization`, `speechrail.render_receipts`, and capability metadata namespaced and independently negotiated. Standard OpenAI SDK tests must ignore them; SpeechRail extension tests must continue to validate them.

- [ ] **Step 5: Re-run the voice and Realtime regressions after current-wire changes**

Run: `uv run --extra dev pytest tests/test_voice_revision_contract.py tests/test_voice_design_registration.py tests/test_voice_safe_listing.py tests/test_tts_voices_api.py tests/test_tts_voice_clone.py tests/test_realtime_openai.py -q`

Expected: PASS with unchanged voice CRUD, clone/VoiceDesign gates, revision pinning, render receipt identity, and current OpenAI event names.

- [ ] **Step 6: Commit the voice-boundary regression**

```bash
git add src/speechrail/application/realtime_openai.py src/speechrail/compatibility/openai_realtime.py contracts/realtime-openai.md tests/test_voice_revision_contract.py tests/test_voice_design_registration.py tests/test_voice_safe_listing.py tests/test_tts_voices_api.py tests/test_tts_voice_clone.py tests/test_realtime_openai.py
git commit -m "test: preserve speechrail voice capabilities"
```

### Task 7: Build the official OpenAI SDK black-box harness

**Files:**
- Modify: `tests/openai-sdk-node/package.json`
- Modify: `tests/openai-sdk-node/package-lock.json`
- Create: `tests/openai-sdk-node/realtime.test.mjs`
- Create: `tests/fixtures/openai_sdk_realtime_server.py`
- Modify: `tests/openai-sdk-node/README.md`
- Test: `tests/openai-sdk-node/realtime.test.mjs`

**Interfaces:**
- Consumes: a real loopback SpeechRail WebSocket endpoint backed by deterministic fake ASR/LLM/TTS.
- Produces: an executable SDK compatibility gate using `OpenAIRealtimeWebSocket` from `openai@7.19.0`.
- Test helpers defined in this task: `connectToLoopback() -> Promise<OpenAIRealtimeWebSocket>`, `userText(text: string) -> object`, and `collectUntilResponseDone(rt: OpenAIRealtimeWebSocket) -> Promise<Array<Record<string, unknown>>>`.

- [ ] **Step 1: Add the deterministic loopback server fixture**

Expose a module runnable with `uv run uvicorn --app-dir tests/fixtures openai_sdk_realtime_server:app --host 127.0.0.1 --port 18201`. Compose `create_app` with fake ASR, fake TTS, fake external LLM, API key `sdk-test-key`, and no network provider. The fixture must return deterministic text/audio and must not read or write real audio/model files.

- [ ] **Step 2: Pin the official SDK and add the SDK test script**

Pin `openai` to `7.19.0`, add the required `ws` peer dependency if the package requires it, and add:

```json
{
  "scripts": {
    "test": "node --test *.test.mjs",
    "test:realtime": "node --test realtime.test.mjs"
  }
}
```

- [ ] **Step 3: Write the black-box tests**

```javascript
test("official Node SDK completes a current text response", async () => {
  const rt = await connectToLoopback();
  rt.send({ type: "session.update", session: {
    type: "realtime", output_modalities: ["text"]
  }});
  rt.send({ type: "conversation.item.create", item: userText("hello") });
  rt.send({ type: "response.create" });
  const events = await collectUntilResponseDone(rt);
  assert.equal(events.find((event) => event.type === "response.done").response.status, "completed");
  assert.ok(events.some((event) => event.type === "response.output_text.delta"));
  assert.ok(!events.some((event) => event.type === "response.audio.delta"));
});
```

Add separate cases for nested session, PCM append/commit, audio output, cancellation, provider error, and legacy event absence. The test must fail when `SPEECHRAIL_SDK_BASE_URL` or `SPEECHRAIL_API_KEY` is missing; it must not silently skip the gate.

- [ ] **Step 4: Run the SDK harness against the loopback fixture**

Run in one terminal: `SPEECHRAIL_API_KEY=sdk-test-key uv run uvicorn --app-dir tests/fixtures openai_sdk_realtime_server:app --host 127.0.0.1 --port 18201`

Run in another terminal: `SPEECHRAIL_SDK_BASE_URL=http://127.0.0.1:18201/v1 SPEECHRAIL_API_KEY=sdk-test-key npm --prefix tests/openai-sdk-node run test:realtime`

Expected: PASS for all current-wire cases. Any `Unknown parameter`, unrecognized event type, missing response status/output, or unexpected legacy event is a compatibility failure.

- [ ] **Step 5: Record the evidence and commit the harness**

Record SDK version, Node version, test command, commit, and pass/fail summary in `tests/openai-sdk-node/README.md`; do not record API keys, full transcript, or audio payloads.

```bash
git add tests/openai-sdk-node/package.json tests/openai-sdk-node/package-lock.json tests/openai-sdk-node/realtime.test.mjs tests/fixtures/openai_sdk_realtime_server.py tests/openai-sdk-node/README.md
git commit -m "test: verify realtime with official openai sdk"
```

### Task 8: Run the project gates and maintain the calibration matrix

**Files:**
- Modify: `docs/superpowers/specs/2026-09-20-openai-realtime-current-wire-external-llm-design.md`
- Modify: `contracts/realtime-openai.md`
- Modify: `tests/openai-sdk-node/README.md`
- Test: all files changed by Tasks 1–7

**Interfaces:**
- Consumes: unit, fake-loopback, and official SDK results.
- Produces: an evidence matrix that distinguishes declared, tested, SDK-verified, and real-runtime behavior.

- [ ] **Step 1: Run deterministic Python checks**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_realtime_vad_bargein.py tests/test_realtime_llm.py tests/test_capability_snapshot.py -q`

Expected: PASS with no network or real model access.

- [ ] **Step 2: Run the official SDK gate**

Run: `npm --prefix tests/openai-sdk-node ci`

Then run the loopback server and `npm --prefix tests/openai-sdk-node run test:realtime` exactly as specified in Task 6.

Expected: PASS; otherwise keep the feature status as under test and do not claim compatibility.

- [ ] **Step 3: Run static and contract checks**

Run: `uv run --extra dev ruff check src tests`; `uv run --extra dev mypy src`; `npx @redocly/cli lint contracts/openapi.yaml`; `git diff --check`

Expected: no new diagnostics. Do not run macOS UI automation as part of this gate.

- [ ] **Step 4: Update the evidence matrix**

For each surface, fill `declared`, `unit-tested`, `fake-loopback`, `official-sdk`, `real-runtime`, and `known-gap`. Include the exact verification time (`2026-09-20` or the actual run time) and distinguish fake-loopback evidence from real managed runtime evidence.

- [ ] **Step 5: Commit only the evidence update**

```bash
git add docs/superpowers/specs/2026-09-20-openai-realtime-current-wire-external-llm-design.md contracts/realtime-openai.md tests/openai-sdk-node/README.md
git commit -m "docs: record realtime compatibility evidence"
```

## Continuous Calibration Rule

每次修改 Realtime wire、SDK 版本、外部 LLM adapter、VAD 或 TTS event ordering，都必须：

1. 先更新 spec 中的 capability/evidence matrix；
2. 增加或调整对应 Python contract test；
3. 运行 fake-loopback；
4. 运行官方 SDK harness；
5. 再更新 `contracts/realtime-openai.md` 和用户文档。

若官方 SDK 或官方文档出现事件/字段变化，旧测试失败视为契约漂移信号，不通过增加兼容 alias
来掩盖；先判断是否接受新的 current wire，再修改 ADR、spec 和实现。
