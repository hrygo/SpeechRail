# Voice Management and Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 SpeechRail macOS 控制面的统一 pointing-hand、配音/试听鉴权失败，并补齐音色详情读取与更新，使音色管理形成真实服务端 CRUD 闭环。

**Architecture:** 复用现有的服务端 API key 发现语义，在 `ServiceAPIClient` 的统一请求构造处注入 Bearer；在 `VoiceRegistry` 增加受约束的原子 metadata 更新，并由 system route 提供单条读取和 PATCH；App 通过 `SpeechRailCreatorClient`、`AppModel` 和 `VoiceLibraryView` 串起编辑、刷新、试听和删除。所有 action/selection controls 由一个可布局的 AppKit cursor region 统一提供 pointing hand，文本输入保留 I-beam。

**Tech Stack:** Python 3.12、FastAPI、Pydantic v2、OpenAPI YAML、SwiftUI、AppKit、Xcode/macOS 26 SDK。

**Spec:** `docs/design/voice-management-and-interaction-contract.md`

## Global Constraints

- 不下载、加载、卸载或替换模型，不执行真实模型推理验收，不删除现有用户音色。
- 自动化测试暂停：不运行 XCTest/XCUITest、Python pytest、ruff 或 mypy；仅编写回归测试、执行静态检查、契约核对和 App 构建。
- API key 只从 `SPEECHRAIL_API_KEY` 或受管 `config/.env` 读取到内存，不写日志、URL、错误文案或仓库。
- 系统音色、alias、clone reference audio、来源证明和 voice ID 不可被 PATCH 修改。
- `TextField`、`TextEditor` 和文本选择区保留 I-beam；操作/选择控件使用 pointing hand。
- 每个 commit 只表达一个逻辑主题；完成前执行 `git diff --check` 和敏感字段检查。

---

### Task 1: Add safe voice metadata update contract

**Files:**
- Modify: `src/speechrail/domain/tts.py:568-1110`
- Modify: `src/speechrail/http/routes/system.py:1-225,668-785,1202-1240`
- Modify: `contracts/openapi.yaml:224-520,1080-1445,1840-1920`
- Test: `tests/test_tts_voices_api.py`
- Test: `tests/test_voice_quality_gates.py`

**Interfaces:**
- Consumes: `VoiceProfile`, `VoiceRegistry._commit_candidate`, `http_auth_error`, `_voice_entry`。
- Produces: `VoiceRegistry.update_custom_profile(voice_id: str, *, name: str | None = None, instruction: str | None = None, seed: int | None = None) -> VoiceProfile`; `GET /v1/voices/{voice_id}`; `PATCH /v1/voices/{voice_id}`。

- [ ] **Step 1: Write regression tests for registry update semantics**

Add tests that create an instruction profile, update name/instruction/seed, reload the registry, and assert the update persisted. Add tests that clone profiles reject instruction/seed changes but accept a name-only update, system voices reject updates, empty PATCH bodies reject, and failed validation leaves the previous record unchanged.

```python
updated = registry.update_custom_profile(
    "custom_voice", name="新名称", instruction="更温暖、更慢", seed=2026
)
assert (updated.name, updated.instruction, updated.seed) == ("新名称", "更温暖、更慢", 2026)
assert VoiceRegistry(storage, audio_dir).get_profile("custom_voice") == updated
```

- [ ] **Step 2: Write route contract tests**

Extend the voice API tests with authenticated `GET /v1/voices/{id}` and authenticated PATCH cases. Assert the response is a complete `VoiceProfile`, `voice_not_found` is 404, protected voices are rejected, and a clone name-only PATCH does not change `ref_text` or quality metadata.

```python
response = client.patch(
    "/v1/voices/custom_voice",
    json={"name": "更新后的名称", "instruction": "沉稳", "seed": 2026},
    headers=AUTH_HEADERS,
)
assert response.status_code == 200
assert response.json()["name"] == "更新后的名称"
```

- [ ] **Step 3: Implement atomic registry update**

Validate the ID and protected/system boundary before entering the registry lock. Reload the current profile under the lock, apply only supplied fields, reuse the existing name/instruction/seed validation, reject instruction/seed for clone mode, create a new frozen `VoiceProfile` preserving all immutable fields, and commit with `_commit_candidate`.

```python
candidate_profile = replace(
    profile,
    name=validated_name,
    instruction=validated_instruction,
    seed=validated_seed,
)
candidate = dict(self._custom_voices)
candidate[vid] = candidate_profile
self._commit_candidate(candidate)
return candidate_profile
```

- [ ] **Step 4: Implement GET/PATCH routes with stable errors**

Register `GET /v1/voices/{voice_id}` and `PATCH /v1/voices/{voice_id}` beside the existing dynamic voice route. Use explicit validation matching the existing voice-create route and the `UpdateVoiceRequest` OpenAPI schema: reject unknown fields, require one non-null mutable field, and validate name/instruction/seed before the registry call. Return `_voice_entry` for success and stable `voice_not_found`, `voice_update_unsupported`, `voice_update_failed`, `voice_store_unavailable` errors. Ensure the PATCH route always checks `http_auth_error`.

- [ ] **Step 5: Update OpenAPI and run focused static contract checks**

Document the two operations, request schema, mutable-field rules, 200/400/401/403/404/503 responses, and `voice_update_unsupported` response. Validate YAML parsing and inspect the changed route/schema anchors without executing pytest.

- [ ] **Step 6: Commit the server contract slice**

```bash
git add src/speechrail/domain/tts.py src/speechrail/http/routes/system.py contracts/openapi.yaml tests/test_tts_voices_api.py tests/test_voice_quality_gates.py
git commit -m "feat: complete voice metadata updates"
```

### Task 2: Repair App authentication and expose voice update operations

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift:1-245`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift:25-190`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift:100-285`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`

**Interfaces:**
- Consumes: `GET/PATCH /v1/voices/{voice_id}`, existing `SpeechRailCreatorClient`, existing service managed app-home convention。
- Produces: `updateVoice(id:name:instruction:seed:) async throws -> CreatorVoice`; authenticated `createSpeech`, `createVoicePreview`, `registerVoiceDesign`, `deleteVoice`, and voice reads。

- [ ] **Step 1: Add client seam tests before implementation**

Add deterministic URL loading tests or the existing test transport seam to assert that a configured injected key produces exactly one `Authorization: Bearer …` header for speech, preview, and PATCH requests, while the test only uses a synthetic key and never logs it. Add decoding coverage for a full updated `CreatorVoice` response.

- [ ] **Step 2: Implement an in-memory credential provider**

Add a private provider in `ServiceAPIClient.swift` that reads only `SPEECHRAIL_API_KEY`, then `SPEECHRAIL_APP_HOME/config/.env`, then the default Application Support app home. Parse only the existing `KEY=value` convention, trim optional matching quotes, reject empty/CR/LF values, and never expose source contents in errors. Allow an injected key in initializers for deterministic tests.

- [ ] **Step 3: Attach credentials in the single request builder**

Store the resolved key in `ServiceAPIClient` and add the Bearer header in `makeRequest`. Keep public endpoint behavior unchanged when no key is available; do not add query parameters or log headers.

- [ ] **Step 4: Add PATCH request and response decoding**

Add a private `UpdateVoiceRequestBody` with optional `name`, `instruction`, and `seed`; add `updateVoice` to `SpeechRailCreatorClient`, `UnavailableCreatorClient`, and `ServiceAPIClient`; issue `PATCH /v1/voices/{id}` and decode the returned `CreatorVoice`.

```swift
public func updateVoice(
    id: String,
    name: String?,
    instruction: String?,
    seed: Int?
) async throws -> CreatorVoice
```

- [ ] **Step 5: Add AppModel mutation state and refresh behavior**

Add `isUpdatingVoice`, validate the trimmed fields before the request, map stable server codes to user-facing Chinese copy, refresh the list after success, and preserve the current selection. Do not clear the form on failure.

- [ ] **Step 6: Commit the client wiring slice**

```bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift macos/SpeechRailApp/SpeechRailApp/AppModel.swift macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift
git commit -m "fix: authenticate creator service requests"
```

### Task 3: Unify pointing hand and complete the Voice Library UX

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift:1-215`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift:120-170`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift:1116-1460`

**Interfaces:**
- Consumes: `SpeechRailDesignTokens`, `SpeechRailCreatorClient.updateVoice`, `AppModel.updateVoice`, current VoiceDesign registration flow。
- Produces: one layout-backed `speechRailPointerCursor()` modifier for action/selection controls; Voice Library new/edit/read/delete/preview states。

- [ ] **Step 1: Define the cursor coverage matrix**

Audit every `Button`, `NavigationLink`, `Menu`, `Picker`, `Slider`, `DisclosureGroup`, and clickable list row in the App. Keep `TextField`/`TextEditor` out of the pointing-hand modifier. The left navigation row must receive the modifier on its outer full-width hit target, not only its label.

- [ ] **Step 2: Repair the cursor region layout**

Change `SpeechRailCursorRegion` from a zero-size background dependency to a full-size overlay/region with an explicit max frame and `resetCursorRects()` invalidation. Apply the modifier to shared button appearance, interactive row style, navigation rows, Picker, Slider, DisclosureGroup, and other action controls. Disabled controls pass `isEnabled=false` and reset to the normal arrow.

- [ ] **Step 3: Add Voice Library create/edit affordances**

Expose “新建音色” in the library header and keep it connected to VoiceDesign. Add an “编辑音色” action in the inspector only for custom voices. Present a compact sheet with name, instruction, and seed fields according to mode; for clone voices show name editing and a read-only provenance explanation.

- [ ] **Step 4: Wire save, preview, delete, and refresh feedback**

Use `AppModel.updateVoice` on save, disable only the relevant controls while the request is running, show success/critical banners, and keep selected voice state after refreshing. Ensure every preview action uses the authenticated client and retains the existing audio playback stop behavior.

- [ ] **Step 5: Perform a source-level UX review**

Search for remaining interactive controls that lack the shared modifier, confirm all navigation labels have sufficient contrast tokens, and inspect the changed SwiftUI hierarchy for overlapping hit regions. Do not launch automation or perform real audio calls.

- [ ] **Step 6: Commit the interaction and Voice Library slice**

```bash
git add macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift
git commit -m "refine: complete creator interaction states"
```

### Task 4: Static verification and handoff

**Files:**
- Modify: `docs/developers/macos-app-development.md` only if the credential discovery behavior is not already documented.
- Review: all files changed by Tasks 1–3.

**Interfaces:**
- Consumes: completed server contract, client wiring, cursor coverage, and Voice Library flows。
- Produces: evidence-backed static/build review with automation explicitly marked not run。

- [ ] **Step 1: Run non-automation source checks**

Run only bounded checks such as OpenAPI YAML parsing, `python -m compileall` over changed Python packages if needed, `git diff --check`, and repository secret-pattern scans that do not print private config contents.

- [ ] **Step 2: Build the macOS App without running tests**

Run `scripts/macos_app_build.sh --configuration Debug` and inspect compiler output. Do not run `scripts/macos_app_test.sh`, XCTest/XCUITest, pytest, ruff, or mypy while the user’s automation pause remains active.

- [ ] **Step 3: Review the final diff and route matrix**

Confirm no key, audio, model artifact, log, build output, or user voice data entered the repository; confirm API and Swift method signatures match; confirm no destructive runtime action was performed.

- [ ] **Step 4: Final logical commit or report existing commits**

If all changes are already represented by the three logical commits, report their hashes. Otherwise stage only the remaining documentation/static-review changes and commit them with a `<type>: <why>` message.

- [ ] **Step 5: Handoff**

Report changed files, static/build verification and timestamp, automation intentionally not run, runtime/model actions not performed, known residual risks, and rollback as reverting the logical commits while retaining existing user data.
