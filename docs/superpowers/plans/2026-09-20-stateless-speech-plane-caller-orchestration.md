# Stateless Speech Plane and Caller-Orchestrated Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 SpeechRail、Native App、MCP 和项目文档统一到 current-only 的无状态 Speech Plane 契约，由调用方实现完整语音助手编排，不引入任何服务端 LLM 或旧版本兼容路径。

**Architecture:** SpeechRail `/v1/realtime` 只提供当前 OpenAI transcription session wire、ASR/VAD/匿名分人和 `speechrail.tts.*` 文本到音频 render。Native App 保留 `LLMProvider`、history、memory、tool calling、播放和 barge-in 决策；`speechrail-mcp` 保持独立的无状态 REST proxy，不持有 Realtime WebSocket。

**Tech Stack:** Python `>=3.12,<3.13`、FastAPI/Starlette WebSocket、Pydantic v2、asyncio、现有 ASR/TTS ports、Swift 6.x/SwiftUI、macOS 26.0、MCP Python SDK `>=2.1,<3`、现有 fake backend 与契约测试。

**Spec:** `docs/superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md`

## Execution status (2026-09-20, Asia/Shanghai)

已完成并提交 current-only 的无状态 Speech Plane：服务端不持有 LLM、conversation history、memory、tools、播放或 barge-in 决策；Native 负责调用方编排；MCP 继续只代理请求级 REST。没有加入 alias、双 wire、旧事件翻译、隐式降级或 /v2 兼容层。

本次最终复核补充了 tests/test_realtime_openai.py::test_fake_loopback_caller_orchestration_can_cancel_and_restart_tts，覆盖 ASR completed → speechrail.tts.create → audio delta → speechrail.tts.cancel → response.done(cancelled) → next TTS completed，并验证 input_audio_buffer.clear barrier。

| surface | declared | unit-tested | fake-loopback | native-contract | real-runtime | known-gap |
|---|---|---|---|---|---|---|
| Python Realtime | current-only ASR/VAD/匿名分人 + caller TTS | full pytest | pass | n/a | 未运行真实模型/音频 | 质量、长时稳定性 |
| Native App | AssistantSession 持有 LLM/history/memory/tools/playback/barge-in | n/a | n/a | selected pure Swift tests pass | 未安装/运行 App | UI/XCUITest |
| MCP | 无状态 REST proxy，不持有 WebSocket | full pytest MCP coverage | n/a | n/a | 未连接外部 MCP client | 第三方 client 互操作 |
| Contracts/release | 3.0.0 breaking release，无兼容模式 | OpenAPI/version checks pass | covered by Python tests | covered by Swift tests | n/a | 发布签名/notarization |

Fresh verification at 2026-09-20 11:42 Asia/Shanghai:

- uv run --extra dev pytest → 2073 passed, 1 skipped, 1 warning; coverage 81.77%.
- uv run --extra dev ruff check src tests、uv run --extra dev mypy src、npx @redocly/cli lint contracts/openapi.yaml、uv run python scripts/check_version_consistency.py、plutil -lint deploy/macos/com.speechrail.plist.example → pass.
- xcodebuild ... test -only-testing:SpeechRailAppTests/RealtimeContractTests -only-testing:SpeechRailAppTests/LLMProviderTests -only-testing:SpeechRailAppTests/AgentCoreTests → exit 0.
- scripts/macos_app_build.sh --configuration Debug → BUILD SUCCEEDED.
- 未运行 UI automation、真实模型/音频 smoke、服务安装/启停、外部发布；这些不属于本次 fake/contract acceptance。

## Global Constraints

- Python 固定为 `>=3.12,<3.13`；使用 `uv` 与 PEP 621。
- `/v1/realtime` 仍是唯一 Realtime 入口；不新增 `/v2/realtime`。
- 只接受 current transcription session wire 与 `speechrail.*` 扩展；不得实现旧字段、旧事件或 alias。
- 服务端不引入 LLM、provider、conversation history、prompt history、tool registry 或 provider 网络访问。
- 服务端只保留连接级 ephemeral state；断线后释放 audio buffer、ASR item、TTS response、sequence 和 receipt state。
- `speechrail.tts.create` 和 `speechrail.tts.cancel` 是唯一 Realtime TTS 控制事件；`conversation.item.create`、`response.create`、`response.cancel` 不得作为 TTS 入口。
- 每个连接同一时刻只允许一个 active TTS response；调用方负责队列、LLM、播放和 barge-in 策略。
- 不记录 API key、`Authorization`、原始音频、Base64、完整 prompt、完整转写、embedding、实名 speaker 或绝对模型路径。
- MCP 只代理请求级 REST 能力，不持有 Realtime WebSocket，不保存实时音频流。
- 破坏性公共契约按 major release 交付；目标版本为 `3.0.0`，更新 Python 与 Native App 的版本一致性来源。
- 除非用户另外明确授权，不运行 UI 自动化、完整 gate、benchmark 或真实音频验收；计划中的验证命令在实施阶段按授权执行。

## Review Focus

- 旧客户端事件必须失败而不是被转换：由 Task 1 的 rejection matrix 和 Task 2 的 WebSocket tests 覆盖。
- `transcription_session.update`、音频格式、VAD 和 `speechrail.tts` 协商必须原子生效：由 Task 1 的 parser tests 与 Task 2 的 session tests 覆盖。
- TTS 在 worker、audio send 或 cancel 任一阶段都只能产生一个终态：由 Task 2 的 lifecycle tests 覆盖。
- Native 必须继续由 `AssistantSession` 拥有 LLM/history/memory，且新 TTS wire 不进入 Caption/Meeting：由 Task 3 的 Swift contract tests 覆盖。
- MCP 不得被误用为 Realtime session：由 Task 4 的 tool/resource/schema tests 和 Task 5 的文档检查覆盖。

## 文件地图

| 责任 | 主要文件 |
|---|---|
| 当前 Realtime 契约 | `contracts/realtime-openai.md`、`src/speechrail/compatibility/openai_realtime.py` |
| Realtime 会话状态机 | `src/speechrail/application/realtime_openai.py`、`src/speechrail/http/routes/realtime_openai.py` |
| Native wire 与调用方编排 | `macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift`、`macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`、`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift` |
| Native 纯逻辑测试 | `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`、`macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift` |
| MCP proxy | `src/speechrail/mcp/models.py`、`src/speechrail/mcp/server.py`、`src/speechrail/mcp/tools.py`、`src/speechrail/mcp/client.py` |
| MCP tests | `tests/mcp/test_server.py`、`tests/mcp/test_resources.py`、`tests/mcp/test_sdk_contract.py` |
| 架构与用户文档 | `docs/architecture/`、`docs/users/`、`docs/developers/` |

---

### Task 1: Freeze the current-only contract and rejection matrix

**Files:**
- Modify: `contracts/realtime-openai.md`
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`

**Interfaces:**
- Consumes: the approved event list in `docs/superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md`.
- Produces: one canonical `TranscriptionSessionUpdate`, `SpeechRailTTSCreate`, `SpeechRailTTSCancel` representation in Swift tests and one Python rejection matrix.
- `SpeechRailTTSCreate` fields are `request_id: String`, `text: String`, `voice: String?`, `speed: Double?`, and `expectedVoiceRevision: String?`.
- `SpeechRailTTSCancel` fields are `request_id: String` and `response_id: String?`.

- [x] **Step 1: Record the Python rejection matrix in the contract**

Add a normative table to `contracts/realtime-openai.md` stating that
`transcription_session.update`, `input_audio_buffer.*`, `speechrail.tts.create`, and
`speechrail.tts.cancel` are the only supported client control families. The same table must
state that `session.update`, `conversation.item.create`, `response.create`, `response.cancel`,
and `response.audio.*` are rejected with `unsupported_operation`.

- [x] **Step 2: Add canonical Swift contract values and encoding tests**

Define typed event factories in `RealtimeContractTypes.swift`. The factories must emit only the canonical event names and omit optional keys when their value is `nil`; no factory may emit a compatibility alias.

Add tests:

```swift
func testCallerTTSCreateUsesSpeechRailNamespace() throws {
    let event = SpeechRailTTSCreate(
        requestID: "tts_req_001",
        text: "你好",
        voice: "serena",
        speed: 1.0,
        expectedVoiceRevision: "vr_abc"
    )
    XCTAssertEqual(event.type, "speechrail.tts.create")
    XCTAssertEqual(event.requestID, "tts_req_001")
}
```

- [x] **Step 3: Replace the active contract prose with target semantics**

Rewrite `contracts/realtime-openai.md` so it describes `transcription_session.update`, the six canonical client event families, `speechrail.tts.*`, current output events, error codes, connection state, and the explicit absence of server-side LLM and legacy aliases. Keep implementation-only facts out of the contract until Task 2 proves them.

- [x] **Step 4: Run the Swift pure contract tests**

Run: `xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailMacControlTests -destination 'platform=macOS' test -only-testing:SpeechRailMacControlTests/RealtimeContractTests`

Expected: PASS after the shared factories are added. Python parser tests are intentionally owned by Task 2 so this documentation/types commit remains independently green.

- [x] **Step 5: Commit the contract fixture and shared types**

```bash
git add contracts/realtime-openai.md macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift
git commit -m "docs: freeze caller orchestrated realtime contract"
```

### Task 2: Implement the stateless server Realtime state machine

**Files:**
- Modify: `src/speechrail/compatibility/openai_realtime.py`
- Modify: `src/speechrail/application/realtime_openai.py`
- Modify: `src/speechrail/http/routes/realtime_openai.py`
- Modify: `src/speechrail/realtime/turn_collection.py` when the current collector needs event-name updates
- Test: `tests/test_realtime_openai.py`
- Test: `tests/test_websocket_contract.py`
- Test: `tests/test_realtime_vad_bargein.py`
- Test: `tests/test_realtime_admission_commits.py`

**Interfaces:**
- Consumes: Task 1 canonical client event types and existing ASR/TTS ports, admission queue, render receipt and clear barrier.
- Produces: connection-scoped `RealtimeSession` with `transcription_session_update`, `tts_create`, `tts_cancel`, `handle_disconnect` and a single finalizer per TTS response.
- The session state must not contain a conversation list, pending cross-request text, LLM provider, prompt history or provider configuration.

- [x] **Step 1: Add failing parser tests for current-only input and old-event rejection**

```python
def test_transcription_session_update_is_the_only_session_update_wire() -> None:
    event = {
        "type": "transcription_session.update",
        "session": {
            "input_audio_format": "pcm16",
            "input_audio_transcription": {"model": "speechrail/qwen3-asr-1.7b"},
            "turn_detection": {"type": "server_vad"},
            "speechrail": {"tts": {"enabled": True}},
        },
    }
    assert parse_client_event(event).kind == "transcription_session_update"


def test_old_tts_events_are_rejected() -> None:
    for event_type in (
        "session.update",
        "conversation.item.create",
        "response.create",
        "response.cancel",
        "response.audio.delta",
    ):
        with pytest.raises(RealtimeAdapterError) as exc_info:
            parse_client_event({"type": event_type})
        assert exc_info.value.code == "unsupported_operation"


def test_session_update_does_not_accept_legacy_flat_fields() -> None:
    with pytest.raises(RealtimeAdapterError, match="unsupported_operation"):
        apply_transcription_session_update(
            base_session(),
            {"type": "transcription_session.update", "session": {"modalities": ["audio"]}},
        )


def test_tts_create_requires_caller_tts_negotiation() -> None:
    with pytest.raises(RealtimeAdapterError) as exc_info:
        parse_tts_create({"type": "speechrail.tts.create", "request_id": "r", "text": "hi"}, enabled=False)
    assert exc_info.value.code == "tts_not_enabled"
```

- [x] **Step 2: Run the parser tests and verify they fail**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py::test_session_update_does_not_accept_legacy_flat_fields tests/test_realtime_openai.py::test_tts_create_requires_caller_tts_negotiation -q`

Expected: FAIL because current parsing is based on the old session and TTS event model.

- [x] **Step 3: Implement current-only session parsing**

In `compatibility/openai_realtime.py`, remove the legacy/current branch and accept only the Task 1 session shape. Validate input format, transcription model, language, VAD, diarization and caller TTS opt-in at the WebSocket boundary. Reject unknown legacy keys instead of ignoring them.

- [x] **Step 4: Replace `_pending_text` and conversation-shaped TTS with one request state**

In `application/realtime_openai.py`, make `speechrail.tts.create` create a request-scoped TTS task. Copy only validated text, voice binding, speed, expected revision, request ID and response ID into ephemeral state. Do not append a conversation item and do not retain the text after the response finalizer completes.

- [x] **Step 5: Implement TTS output and receipt metadata**

Emit the response lifecycle in this order:

```text
response.created
response.output_item.added
response.content_part.added
response.output_audio_transcript.delta/done
response.output_audio.delta/done
response.content_part.done
response.output_item.done
response.done
```

Attach `speechrail.kind=tts`, `speechrail.orchestration=caller`, `request_id`, voice revision and the existing render receipt. Keep the current sequence and send budget rules.

- [x] **Step 6: Implement explicit cancel and disconnect finalization**

`speechrail.tts.cancel` must stop queued audio before cancelling the worker, emit one cancelled `response.done`, release admission, and allow the next request. A second cancel returns `tts_not_active`; a second create while active returns `tts_in_progress`. Disconnect must cancel tasks and release resources without writing state to disk.

- [x] **Step 7: Remove server-side LLM design surfaces**

Do not add `RealtimeLanguageModel`, provider settings, provider readiness, external URL configuration, secret references, or provider network calls. If an implementation branch contains any of these artifacts from the superseded plan, remove them in this task and add a test that the Realtime composition root has no LLM provider dependency.

- [x] **Step 8: Run the focused Realtime regression**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_websocket_contract.py tests/test_realtime_vad_bargein.py tests/test_realtime_admission_commits.py -q`

Expected: PASS for current-only parser, ASR item completion, TTS lifecycle, cancel during admission/planner/send, clear barrier, VAD facts, worker release and stable errors; no old event name is emitted.

- [x] **Step 9: Commit the server state machine**

```bash
git add src/speechrail/compatibility/openai_realtime.py src/speechrail/application/realtime_openai.py src/speechrail/http/routes/realtime_openai.py src/speechrail/realtime/turn_collection.py tests/test_realtime_openai.py tests/test_websocket_contract.py tests/test_realtime_vad_bargein.py tests/test_realtime_admission_commits.py
git commit -m "feat: make realtime a stateless speech plane"
```

### Task 3: Align Native with caller-owned orchestration

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift` only for types not completed in Task 1
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`

**Interfaces:**
- Consumes: Task 1 Swift event factories and Task 2 server event lifecycle.
- Produces: `RealtimeASRClient` methods `sendTranscriptionSessionUpdate`, `sendTTSCreate`, `cancelTTS`, and unchanged public AssistantSession LLM ownership.

- [x] **Step 1: Add failing tests for Native wire output**

```swift
func testRealtimeClientUsesTranscriptionSessionUpdate() throws {
    let event = RealtimeClientEvent.transcriptionSessionUpdate(.callerTTS)
    XCTAssertEqual(event.type, "transcription_session.update")
}

func testAssistantOwnsLLMProviderAndHistory() {
    let session = makeAssistantSession()
    XCTAssertNotNil(session.llmProvider)
    XCTAssertTrue(session.history.isEmpty)
}
```

- [x] **Step 2: Run pure Swift tests and verify the wire test fails**

Run: `xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailMacControlTests -destination 'platform=macOS' test -only-testing:SpeechRailMacControlTests/RealtimeContractTests -only-testing:SpeechRailMacControlTests/LLMProviderTests`

Expected: FAIL for the old `session.update` / `conversation.item.create` / `response.create` sender path.

- [x] **Step 3: Change `RealtimeASRClient` to canonical events**

Replace `speak()` with `sendTTSCreate(text:voice:speed:expectedVoiceRevision:)`; replace `cancelResponse()` with `cancelTTS(requestID:responseID:)`. Keep one serial writer, event sequence validation, clear barrier and render receipt checks.

- [x] **Step 4: Keep LLM and assistant state inside `AssistantSession`**

Do not move history, persona, memory, tool calls or `LLMProvider` into the service. The session must generate caller text, call `sendTTSCreate`, and call `cancelTTS` when its own barge-in policy decides to interrupt playback.

- [x] **Step 5: Keep Caption and Meeting ASR-only**

Add a pure test that Caption and Meeting session construction does not enable caller TTS and that their event handlers ignore TTS-only state without opening a playback task.

- [x] **Step 6: Run Swift contract tests**

Run: `xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailMacControlTests -destination 'platform=macOS' test -only-testing:SpeechRailMacControlTests/RealtimeContractTests -only-testing:SpeechRailMacControlTests/LLMProviderTests -only-testing:SpeechRailMacControlTests/AgentCoreTests`

Expected: PASS with no UI automation and no real audio/network provider.

- [x] **Step 7: Commit Native alignment**

```bash
git add macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift
git commit -m "feat: route assistant orchestration through native caller"
```

### Task 4: Publish truthful capabilities and align MCP

**Files:**
- Modify: `src/speechrail/application/capability_snapshot.py`
- Modify: `src/speechrail/http/routes/system.py`
- Modify: `src/speechrail/mcp/models.py`
- Modify: `src/speechrail/mcp/server.py`
- Modify: `src/speechrail/mcp/tools.py`
- Modify: `src/speechrail/mcp/client.py` only if the capability response needs a new typed projection
- Test: `tests/test_capability_snapshot.py`
- Test: `tests/test_app_contract.py`
- Test: `tests/mcp/test_server.py`
- Test: `tests/mcp/test_resources.py`
- Test: `tests/mcp/test_sdk_contract.py`

**Interfaces:**
- Consumes: Task 2 capability names and Task 1 canonical Realtime contract.
- Produces: `DescribeResult.realtime` fields `orchestration="caller"`, `server_llm=false`, `conversation_state=false`, `websocket_path="/v1/realtime"`, and `mcp_realtime=false`.

- [x] **Step 1: Add failing capability tests**

```python
def test_realtime_capabilities_advertise_caller_orchestration() -> None:
    snapshot = make_capability_snapshot()
    realtime = snapshot["realtime"]
    assert realtime["orchestration"] == "caller"
    assert realtime["server_llm"] is False
    assert realtime["conversation_state"] is False
    assert realtime["mcp_realtime"] is False
```

- [x] **Step 2: Remove any server-LLM readiness projection**

Capabilities may expose ASR, TTS, VAD, diarization, voice revision and receipt support. They must not expose provider model, provider URL, provider readiness or secret-related fields.

- [x] **Step 3: Preserve the nine MCP tools and three resources**

Keep the existing tool names and request-level REST behavior. Update structured output descriptions and `_INSTRUCTIONS` to say: call `describe()` first; use `transcribe`/`synthesize`/jobs for bounded operations; direct-connect to `/v1/realtime` for caller-owned realtime speech; MCP never manages a realtime session.

- [x] **Step 4: Add MCP schema assertions**

Assert that `tools/list` contains the existing nine tools, `resources/list` contains the existing three read-only resources, and no tool named `realtime_session`, `start_realtime`, or `stream_audio` is registered.

- [x] **Step 5: Run MCP and capability tests**

Run: `uv run --extra dev pytest tests/test_capability_snapshot.py tests/test_app_contract.py tests/mcp/test_server.py tests/mcp/test_resources.py tests/mcp/test_sdk_contract.py -q`

Expected: PASS with unchanged request-level MCP operations, truthful caller orchestration metadata, and no WebSocket handle.

- [x] **Step 6: Commit MCP and capability alignment**

```bash
git add src/speechrail/application/capability_snapshot.py src/speechrail/http/routes/system.py src/speechrail/mcp/models.py src/speechrail/mcp/server.py src/speechrail/mcp/tools.py src/speechrail/mcp/client.py tests/test_capability_snapshot.py tests/test_app_contract.py tests/mcp/test_server.py tests/mcp/test_resources.py tests/mcp/test_sdk_contract.py
git commit -m "feat: expose caller owned speech capabilities"
```

### Task 5: Complete project documentation and integration examples

**Files:**
- Modify: `docs/architecture/architecture.md`
- Modify: `docs/architecture/current-boundaries.md`
- Modify: `docs/architecture/speechrail-mcp-proxy.md`
- Modify: `docs/users/integrations.md`
- Modify: `docs/users/mcp-agent-integration.md`
- Modify: Native Realtime integration documentation under `docs/developers/`
- Modify: `README.md` only for capability summary and links
- Modify: `docs/superpowers/README.md`
- Modify: `docs/decisions/README.md`

**Interfaces:**
- Consumes: the accepted ADR, the implemented contract, capability snapshot and MCP schema from Tasks 1–4.
- Produces: one consistent user-facing explanation of ASR → caller LLM → TTS, MCP boundaries, unsupported server-side LLM behavior and the breaking release.

- [x] **Step 1: Replace architecture diagrams and responsibility tables**

Show the caller-owned flow:

```text
input PCM → SpeechRail ASR → caller LLM/tools/memory → speechrail.tts.create → SpeechRail TTS → caller playback
```

State that connection-scoped buffers are ephemeral and that service-side conversation state does not exist.

- [x] **Step 2: Update MCP documentation without adding a realtime tool**

Keep `stdio` and `streamable-http`, local path-first audio references, capability discovery, bounded job guidance and security notes. Add a direct WebSocket example for callers and explicitly say that MCP cannot hold the realtime PCM stream.

- [x] **Step 3: Add Native caller orchestration example**

Document one complete turn: receive transcription completed, call `LLMProvider`, submit one sentence using `speechrail.tts.create`, play deltas, send `speechrail.tts.cancel` on the App’s own interruption decision, then use the clear barrier before the next recording turn.

- [x] **Step 4: Remove stale external-LLM commitments**

Search the active documentation for `RealtimeLanguageModel`, `external LLM`, provider readiness, `conversation history` in SpeechRail, and old TTS aliases. Replace active claims with the accepted design; keep the two superseded documents as historical records with their superseded banners.

- [x] **Step 5: Run documentation consistency checks**

Run: `rg -n "RealtimeLanguageModel|external LLM|response\.audio\.|conversation\.item\.create|response\.create|response\.cancel" docs contracts README.md`

Expected: matches remain only in superseded historical documents or explicit “rejected/unsupported” sections; no active user guide instructs callers to use them.

- [x] **Step 6: Commit documentation closure**

```bash
git add docs/architecture docs/users docs/developers README.md docs/superpowers/README.md docs/decisions/README.md
git commit -m "docs: close caller orchestrated speech integration"
```

### Task 6: Run the fake loopback, release, and evidence gates

**Files:**
- Modify: `pyproject.toml`
- Modify: `src/speechrail/__init__.py`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Modify: release/changelog documentation if present
- Create: a deterministic fake loopback test module under `tests/` only if the existing fixtures cannot compose the full path
- Test: all Realtime, Native contract, capability and MCP tests changed by Tasks 1–5

**Interfaces:**
- Consumes: implemented Python server, Native event factories, MCP schema and user-facing docs.
- Produces: a `3.0.0` breaking release candidate with recorded evidence and no compatibility mode.

- [x] **Step 1: Add a fake loopback end-to-end test**

The test must drive:

```text
transcription_session.update
→ input_audio_buffer.append
→ input_audio_buffer.commit
→ transcription completed
→ speechrail.tts.create
→ response.output_audio.delta
→ speechrail.tts.cancel
→ response.done(cancelled)
→ next speechrail.tts.create succeeds
```

Use fake ASR/TTS backends, bounded PCM fixtures and an in-memory transport. The test must not call a cloud provider or write raw audio to the repository.

- [x] **Step 2: Run the focused end-to-end tests**

Run: `uv run --extra dev pytest tests/test_realtime_openai.py tests/test_websocket_contract.py tests/test_realtime_vad_bargein.py tests/test_realtime_admission_commits.py tests/test_capability_snapshot.py tests/mcp/test_server.py tests/mcp/test_resources.py -q`

Expected: PASS for current-only events, stateless TTS, cancel/restart, Native-facing receipts, capabilities and MCP boundaries.

- [x] **Step 3: Update the breaking version**

Set the authoritative Python version and the Native App `MARKETING_VERSION` to `3.0.0`, update any generated/version consistency fixtures, and add a changelog entry under `Breaking`/`Changed` that states old Realtime events and server-side LLM expectations are removed. Do not add a compatibility flag.

- [x] **Step 4: Run authorized static and contract gates**

Only when the user has authorized automated acceptance, run:

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

For Native code, the separately authorized build/test commands are:

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
```

Do not run UI automation without a separate user message explicitly authorizing it.

- [x] **Step 5: Record the evidence matrix**

Record `surface | declared | unit-tested | fake-loopback | native-contract | real-runtime | known-gap`, verification timestamps, exact commands and unverified real-runtime/UI items. Do not include API keys, raw audio, Base64 or full transcript text.

- [x] **Step 6: Inspect staged diff and commit the release candidate metadata**

Run: `git diff --staged --check` and inspect `git diff --staged` for secrets, stale aliases and accidental runtime/config changes.

```bash
git add pyproject.toml src/speechrail/__init__.py macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj docs
git commit -m "feat: release stateless speech plane contract"
```

## Continuous Calibration Rule

每次修改 Realtime event、TTS cancellation、VAD、voice binding、MCP schema 或 Native parser，都必须：

1. 先更新 `contracts/realtime-openai.md` 和对应测试；
2. 运行 fake loopback；
3. 运行 Native pure contract tests；
4. 运行 MCP schema tests（若 MCP surface 受影响）；
5. 更新 evidence matrix；
6. 不通过增加 alias、双读或隐式降级来掩盖契约漂移。
