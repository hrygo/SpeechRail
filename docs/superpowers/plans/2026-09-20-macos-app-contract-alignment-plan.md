# SpeechRail macOS App Contract Alignment Implementation Plan

> 状态：`superseded`（2026-09-20）。本计划原本包含 legacy fallback 与旧 Realtime wire；当前实现不保留
> 任何旧版本兼容。请改用 [Stateless Speech Plane and Caller-Orchestrated Assistant Implementation Plan](2026-09-20-stateless-speech-plane-caller-orchestration.md)。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 将 SpeechRail macOS App 的 REST 与 Realtime 控制面适配完整迁移到当前公共契约，同时保留 legacy 入口、现有 UI 行为和 control-plane 边界。

**Architecture:** 先把公共 JSON、HTTP metadata、错误和 Realtime envelope 放入现有 SpeechRailControlKit，形成可由 Swift Package tests 直接验证的纯契约层；再让 ServiceAPIClient 通过可测试的 request/response adapter 访问服务。AppModel 只保存原子 capability snapshot 与 safe Voice catalog，Creator 和三类 Realtime session 通过 typed application methods 消费它们，避免 UI 自行拼装或推断契约字段。

**Tech Stack:** Swift 6、Foundation Codable、URLSession/URLProtocol、URLSessionWebSocketTask、Observation、Swift Package Manager、XCTest、现有 Xcode macOS App target。

**Spec:** docs/superpowers/specs/2026-09-20-macos-app-contract-alignment-design.md

## Global Constraints

- 不修改 Python 服务、OpenAPI、Realtime 文档或服务端路由；服务端契约同步若有必要必须作为独立变更。
- 不下载、加载、卸载模型，不改变 active profile 或 LaunchAgent。
- App 继续是 control plane：不加载模型、不直接执行 launchctl；音频只存在于会话生命周期，PCM 不落盘。
- 不把 reference text、instruction、文件路径、完整质量原始数据、PCM、Base64、Authorization、API key 或完整用户输入写入日志、App 持久化或 UI 安全目录。
- 遵守 macOS 26.0+ App 基线，不增加旧 macOS 兼容 UI。
- 未经当前用户逐次授权，不运行 UI automation、XCUITest、录屏、窗口接管或其他前台自动化。
- /v1/speechrail/capabilities 是跨对象发现的主入口；不得用多个非原子 GET 拼造伪 snapshot。
- 旧服务只允许在发现接口 404/405 或明确不识别新 schema 时降级 legacy capability 展示；401/403、revision conflict、服务端明确错误不得静默降级。
- 所有实施提交只暂存本任务目标文件；当前工作区已有并行未提交改动，禁止回退、覆盖或整文件替换。

## Review Focus

1. **304 无缓存与旧快照保留：** 304 命中缓存必须保留同一资源的完整旧值；无缓存的 304 必须成为明确 contract error。测试归 Task 2。
2. **鉴权错误不降级：** 401/403 和 invalid API key 必须保留错误分类，不能显示 legacy capability 成功。测试归 Task 3。
3. **未知枚举与缺少关键字段：** 未知 availability reason/operation 状态可安全解码；缺少 schema version 或 snapshot ID 等关键字段必须进入 invalidContract。测试归 Task 1。
4. **音频 MIME 与响应 headers：** 非 WAV 的合法音频响应不能被拒绝；receipt/timing ID 必须从 headers 传到 typed response。测试归 Task 5。
5. **Realtime 顺序完整性：** sequence 跳号/回退必须可观测；关闭必须按 commit、已提交 item 终态、clear、close 顺序执行。测试归 Task 6 与 Task 7。

## File Map

### Shared contract and testable transport

- Create: macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift
  - 稳定错误、HTTP metadata、conditional response、effective capability、safe Voice、Voice revision、receipt/timing、transcription、job 和 request header 类型。
- Create: macos/SpeechRailApp/SpeechRailControlKit/ServiceHTTPTransport.swift
  - request builder、URLSession transport、status/error/ETag/304 处理；不包含 SwiftUI 或 AppModel。
- Create: macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift
  - Realtime event envelope、sequence validator、busy error、render receipt 和 close barrier 的纯值类型。
- Modify: macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift
  - HealthSnapshot 增加契约要求的 asr_runtime_revision，并保持旧字段的 additive decode。
- Create: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
- Create: macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift

### App transport and application surfaces

- Modify: macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift
  - 复用 shared transport，补齐 readiness、atomic discovery、safe Voice、speech headers、receipt/timing、transcription、job 和 Voice management API。
- Modify: macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift
  - 扩展 CreatorVoice/quality/detail DTO；为新 management 操作提供兼容 default methods。
- Modify: macos/SpeechRailApp/SpeechRailApp/AppModel.swift
  - 保存 discovery snapshot/catalog 状态，执行 ETag 刷新，保留 legacy capability 兼容视图。
- Modify: macos/SpeechRailApp/SpeechRailApp/App.swift
  - 注入新的 discovery/readiness client，更新 available voice 来源和 UI fixture fake。
- Modify: macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift
  - 协商 model revision/render receipt，发出 clear，解析 envelope/sequence/busy/receipt。
- Modify: macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift
  - 使用统一的 Realtime drain-and-clear 关闭顺序。

不在本计划中直接编辑当前并行改动的 README、docs/developers/*.md、docs/users/README.md、AssistantView.swift、DeveloperDocsContent.swift、SessionDesignSurface.swift。若 AppModel/App 的接线需要触及这些文件，先读取并以最小局部 patch 合并，不得覆盖其现有内容。

## Execution Order and Commit Boundaries

REST 与 Realtime 共用错误、metadata、revision 和 capability 类型，因此保留一个计划；两条传输线在 shared contract 完成后分别实施，每个任务都有自己的 fixture/test cycle 和 commit。执行时每个任务开始前运行 git status --short，确认只处理本任务目标；已有 dirty 文件不加入暂存区。

## Task 1: 建立公共契约值类型与诊断字段

**Files:**

- Create: macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift
- Modify: macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift
- Create: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

**Interfaces:**

- Produces ServiceAPIClientError、ServiceContractDecodingError、ServiceResponseDecoder、ServiceResponseMetadata、ServiceConditionalResponse<Value>、ReadySnapshot、ConfiguredModelIdentity、EffectiveCapabilitySnapshot、SafeVoiceList、SafeVoiceEntry、VoiceRevision、VoiceQualityReportSnapshotV2、SpeechRequest、SpeechAudioResponse、RenderReceipt、TtsTimingResource、TranscriptionRequest、JobCreateRequest、Job、JobList。
- Produces CapabilityDiscoveryState and CapabilitySnapshotStore for AppModel to consume in Task 3.
- Produces HTTPHeaderNames and SpeechRailRequestOptions so Task 2 and Task 5 use one spelling for headers.
- Produces ServiceErrorCategory and ServiceErrorClassifier.category(for:) so AppModel and package tests use the same stable error mapping.

- [ ] **Step 1: Write the failing fixture tests for required fields and unknown values**

Add tests to ServiceContractTests.swift:

~~~swift
import XCTest
@testable import SpeechRailControlKit

final class ServiceContractTests: XCTestCase {
    func testEffectiveSnapshotKeepsAtomicIdentityAndUnknownAvailabilityReason() throws {
        let data = Data("""
        {
          "schema_version": "effective_capabilities_v1",
          "service_instance_epoch": "epoch-1",
          "catalog_revision": "catalog-7",
          "snapshot_id": "snap-9",
          "profile": "quality",
          "models": [],
          "voices": [{
            "id": "voice_demo",
            "name": "Demo",
            "mode": "base",
            "available": false,
            "availability_reason": "future_reason",
            "operations": ["synthesize"]
          }],
          "operations": {},
          "guarantees": {}
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(EffectiveCapabilitySnapshot.self, from: data)

        XCTAssertEqual(snapshot.schemaVersion, "effective_capabilities_v1")
        XCTAssertEqual(snapshot.snapshotID, "snap-9")
        XCTAssertEqual(snapshot.voices[0].availabilityReason.rawValue, "future_reason")
    }

    func testMissingSnapshotIDIsInvalidContract() {
        let data = Data(#"{"schema_version":"effective_capabilities_v1"}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(EffectiveCapabilitySnapshot.self, from: data)
        ) { error in
            XCTAssertEqual(error as? ServiceContractDecodingError, .missingRequiredField("snapshot_id"))
        }
    }

    func testErrorPreservesStatusAndRequestID() {
        let error = ServiceAPIClientError.http(
            statusCode: 409,
            code: "voice_revision_mismatch",
            message: "stale revision",
            requestID: "req-1",
            retryable: false
        )

        XCTAssertEqual(error.statusCode, 409)
        XCTAssertEqual(error.requestID, "req-1")
        XCTAssertFalse(error.isRetryable)
    }
}
~~~

- [ ] **Step 2: Run the focused package test and verify the fixture fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: the new types or required decoding behavior are not available yet, so the focused test target fails to compile or fails the assertions. Do not run this command during the planning stage; run it during implementation only after the user authorizes automated validation.

- [ ] **Step 3: Add the Codable contract types**

Implement the following exact semantics in ServiceContractTypes.swift:

~~~swift
public struct ServiceResponseMetadata: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let requestID: String?
    public let etag: String?
}

public struct ServiceConditionalResponse<Value: Sendable>: Sendable {
    public let value: Value?
    public let metadata: ServiceResponseMetadata
    public let notModified: Bool

    public static func notModified(metadata: ServiceResponseMetadata) -> Self
}

public enum ServiceAPIClientError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case requestFailed
    case requestTimedOut
    case notModifiedWithoutCache
    case invalidContract(String)
    case http(
        statusCode: Int,
        code: String,
        message: String,
        requestID: String?,
        retryable: Bool
    )
}

public enum ServiceErrorCategory: Equatable, Sendable {
    case conflict
    case notReady
    case busy
    case unauthorized
    case unsupported
    case invalidContract
    case connection
}

public enum ServiceErrorClassifier {
    public static func category(for error: ServiceAPIClientError) -> ServiceErrorCategory
}
~~~

Use snake_case CodingKeys for every wire field. Required identity fields are non-optional and throw ServiceContractDecodingError.missingRequiredField when absent. Availability reason, operation, voice mode, assurance and quality status use raw-value wrappers with an unknown(String) case. Preserve service_instance_epoch, catalog_revision, snapshot_id, voice_revision and runtime_revision without deriving replacements from model names or timestamps.

- [ ] **Step 4: Add the capability snapshot store and health revision**

Make CapabilitySnapshotStore retain the last complete response until a newer complete response is applied. Its public operations are:

~~~swift
public mutating func beginRefresh() -> UInt64
public mutating func apply(
    _ response: ServiceConditionalResponse<EffectiveCapabilitySnapshot>,
    requestToken: UInt64
)
public mutating func markUnauthorized(_ error: ServiceAPIClientError, requestToken: UInt64)
public mutating func markUnsupported(requestToken: UInt64)
public static func loaded(
    snapshot: EffectiveCapabilitySnapshot,
    etag: String?
) -> CapabilitySnapshotStore
~~~

Add asrRuntimeRevision: String? to HealthSnapshot, encode it as asr_runtime_revision, and leave all existing initializer arguments source-compatible by giving the new argument a nil default.

- [ ] **Step 5: Run the focused tests and commit the shared contract**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: PASS for required-field validation, unknown-value preservation, error metadata and snapshot state transitions.

Commit:

~~~bash
git add macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
git commit -m "feat: add shared SpeechRail service contract types"
~~~

## Task 2: 建立 HTTP request/response adapter

**Files:**

- Create: macos/SpeechRailApp/SpeechRailControlKit/ServiceHTTPTransport.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

**Interfaces:**

- Produces ServiceRequestBuilder.make(path:method:query:headers:body:) -> URLRequest.
- Produces ServiceHTTPTransport.execute(_:) -> ServiceRawHTTPResponse.
- Produces ServiceCapabilityDiscoveryClient with fetchEffectiveCapabilities(ifNoneMatch:), fetchSafeVoices(ifNoneMatch:) and fetchReadiness().
- ServiceAPIClient keeps fetchHealthSnapshot(), fetchMetrics(), fetchModelCapabilities(), fetchVoices(), fetchVoice(id:) and all existing Creator methods source-compatible.
- New conditional methods return ServiceConditionalResponse rather than discarding ETag/304 metadata.

- [ ] **Step 1: Add failing request and response tests**

~~~swift
func testRequestBuilderAddsBearerAndConditionalHeaders() throws {
    let request = try ServiceRequestBuilder(
        baseURL: URL(string: "http://127.0.0.1:8201")!,
        apiKey: "secret"
    ).make(
        path: "/v1/speechrail/capabilities",
        method: "GET",
        query: [],
        headers: ["If-None-Match": "\"snap-1\""],
        body: nil
    )

    XCTAssertEqual(request.url?.path, "/v1/speechrail/capabilities")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"snap-1\"")
}

func test304WithoutCachedValueThrowsCacheMiss() {
    XCTAssertThrowsError(
        try ServiceResponseDecoder.decode(
            Data(),
            statusCode: 304,
            headers: ["ETag": "\"snap-2\""],
            cachedValue: nil
        )
    ) { error in
        XCTAssertEqual(error as? ServiceAPIClientError, .notModifiedWithoutCache)
    }
}
~~~

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests.testRequestBuilderAddsBearerAndConditionalHeaders
~~~

Expected: FAIL because ServiceRequestBuilder and ServiceResponseDecoder are not implemented.

- [ ] **Step 3: Implement request construction and raw transport**

ServiceRequestBuilder must reject absolute or query-injected paths, add Accept/Content-Type/Bearer/If-None-Match exactly once, preserve caller-provided SpeechRail-* headers, and never add API keys to query parameters. ServiceHTTPTransport must expose raw body plus ServiceResponseMetadata, map URLSession timeout to requestTimedOut, map non-HTTP results to invalidResponse, decode the stable error envelope on non-2xx, and treat 304 as a conditional response.

~~~swift
public struct ServiceRawHTTPResponse: Sendable {
    public let data: Data
    public let metadata: ServiceResponseMetadata
}

public protocol ServiceTransporting: Sendable {
    func execute(_ request: URLRequest) async throws -> ServiceRawHTTPResponse
}
~~~

- [ ] **Step 4: Route existing ServiceAPIClient methods through the adapter**

Replace the private execute/get/postJSON path in ServiceAPIClient.swift with the shared transport while preserving existing public method signatures. Update CreatorServiceClient.swift to import SpeechRailControlKit if it now refers to the shared ServiceAPIClientError. Keep current user-facing LocalizedError strings; request ID and status remain typed diagnostic data.

- [ ] **Step 5: Add conditional discovery methods and verify 200/304/error paths**

Add:

~~~swift
public func fetchEffectiveCapabilities(
    ifNoneMatch: String?
) async throws -> ServiceConditionalResponse<EffectiveCapabilitySnapshot>

public func fetchSafeVoices(
    ifNoneMatch: String?
) async throws -> ServiceConditionalResponse<SafeVoiceList>

public func fetchReadiness() async throws -> ReadySnapshot
~~~

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: PASS for auth, conditional headers, 200 decoding, cached 304 reuse, uncached 304 rejection, non-JSON error preservation and timeout classification.

- [ ] **Step 6: Commit the adapter**

~~~bash
git add macos/SpeechRailApp/SpeechRailControlKit/ServiceHTTPTransport.swift macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
git commit -m "feat: preserve SpeechRail HTTP contract metadata"
~~~

## Task 3: 接入 atomic discovery、readiness 与 legacy capability

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/AppModel.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/App.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

**Interfaces:**

- Adds ServiceCapabilityDiscoveryClient with fetchEffectiveCapabilities(ifNoneMatch:), fetchSafeVoices(ifNoneMatch:) and fetchReadiness().
- Adds AppModel.effectiveCapabilities, safeVoiceCatalog, discoveryState and refreshDiscovery().
- Keeps AppModel.serviceCapabilities and refreshServiceCapabilities() for the legacy standalone capability view.

- [ ] **Step 1: Add failing state transition tests**

~~~swift
func testSnapshotStoreKeepsPreviousCompleteValueWhenRefreshIsLoading() {
    var store = CapabilitySnapshotStore.loaded(snapshot: fixtureSnapshot("snap-1"), etag: "\"snap-1\"")
    let token = store.beginRefresh()

    XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
    XCTAssertEqual(store.state, .loading)

    store.apply(
        .notModified(metadata: fixtureMetadata(status: 304, etag: "\"snap-1\"")),
        requestToken: token
    )

    XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
    XCTAssertEqual(store.state, .loaded)
}

func testUnauthorizedDoesNotBecomeLegacySuccess() {
    var store = CapabilitySnapshotStore.loaded(snapshot: fixtureSnapshot("snap-1"), etag: "\"snap-1\"")
    let token = store.beginRefresh()

    store.markUnauthorized(
        .http(
            statusCode: 401,
            code: "invalid_api_key",
            message: "redacted",
            requestID: "req-7",
            retryable: false
        ),
        requestToken: token
    )

    XCTAssertEqual(store.state, .unauthorized)
    XCTAssertEqual(store.snapshot?.snapshotID, "snap-1")
}
~~~

- [ ] **Step 2: Run the focused state test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests.testSnapshotStoreKeepsPreviousCompleteValueWhenRefreshIsLoading
~~~

Expected: FAIL because AppModel has no atomic discovery state and the store transition API is not implemented.

- [ ] **Step 3: Add discovery state to AppModel**

Add:

~~~swift
public private(set) var effectiveCapabilities: EffectiveCapabilitySnapshot?
public private(set) var safeVoiceCatalog: SafeVoiceList?
public private(set) var discoveryState: CapabilityDiscoveryState = .idle
public private(set) var discoveryMetadata: ServiceResponseMetadata?

public func refreshDiscovery() async
~~~

Use a refresh generation/token exactly as the existing health refresh code does. A newer refresh invalidates older results. Keep the previous complete snapshot while loading. Apply safe Voice catalog independently without treating it as a replacement for effective capabilities.

- [ ] **Step 4: Add readiness and legacy mapping**

Implement ReadySnapshot decoding for /readyz and make App.swift session readiness closures use fetchReadiness() rather than an untyped /health-only decision. Keep HealthSnapshot for diagnostics. Change refreshServiceCapabilities() to prefer atomic snapshot operations when available and to call /v1/models only after 404/405 or unknown-schema results. Do not fallback after authorization, revision or server errors.

Update UITestServiceDiagnosticsClient with deterministic readiness and atomic discovery fixtures through default protocol methods; existing fixture tests must compile without implementing every new method.

- [ ] **Step 5: Use safe Voice data for selection**

Change App.swift availableVoiceNames to read available entries from safeVoiceCatalog. Keep CreatorVoice detail data for the editor and do not expose instruction/refText/duration in the safe selection path. Preserve current empty/loading/failed UI states.

- [ ] **Step 6: Run state tests and commit**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: PASS for snapshot retention, 304 reuse, stale generation rejection, legacy fallback boundary and unauthorized isolation.

~~~bash
git add macos/SpeechRailApp/SpeechRailApp/AppModel.swift macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
git commit -m "feat: use atomic capabilities for macOS discovery"
~~~

## Task 4: 对齐 Voice detail、revision、quality 与 pronunciation 管理

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

**Interfaces:**

- CreatorVoice gains optional revision, revoked, availabilityReason, quality and creation values without removing editor-only instruction/refText fields.
- Adds typed VoiceRevision and PronunciationSet DTOs.
- Adds ServiceAPIClient methods createVoice, fetchVoiceRevisions, updateVoice with expectedRevision, rollbackVoice, revokeVoiceRevision, fetch/upsert/revoke/delete PronunciationSet and runVoiceQuality.

- [ ] **Step 1: Add failing DTO and revision conflict tests**

~~~swift
func testCreatorVoiceDecodesRevisionAndRevokedAdditively() throws {
    let voice = try JSONDecoder().decode(
        CreatorVoice.self,
        from: Data(#"{"id":"v1","name":"Demo","revision":"vr_0123456789abcdef0123456789abcdef","revoked":false,"future_field":true}"#.utf8)
    )

    XCTAssertEqual(voice.revision, "vr_0123456789abcdef0123456789abcdef")
    XCTAssertFalse(voice.revoked)
}

func testVoicePatchEncodesExpectedRevision() throws {
    let data = try JSONEncoder().encode(
        VoicePatch(
            name: "Updated",
            instruction: nil,
            seed: nil,
            expectedRevision: "vr_0123456789abcdef0123456789abcdef"
        )
    )

    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(object?["expected_revision"] as? String, "vr_0123456789abcdef0123456789abcdef")
}
~~~

- [ ] **Step 2: Run the DTO test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests.testCreatorVoiceDecodesRevisionAndRevokedAdditively
~~~

Expected: FAIL because CreatorVoice and VoicePatch do not yet carry the new fields.

- [ ] **Step 3: Extend Creator DTOs with custom additive decoding**

Update CreatorVoice custom CodingKeys/decoder to preserve existing defaults while decoding revision, revoked, availability_reason, quality and creation. Extend VoiceQualityReportSnapshot with run_id, tested_at, synthesis and the current reference measurement fields as optionals when the service can return unevaluated data. An unevaluated synthesis report must not appear as pass.

- [ ] **Step 4: Implement revision/CAS and pronunciation requests**

Use the namespaced routes as the primary routes:

~~~text
PATCH  /v1/speechrail/voices/{voice_id}
GET    /v1/speechrail/voices/{voice_id}/revisions
POST   /v1/speechrail/voices/{voice_id}/rollback
POST   /v1/speechrail/voices/{voice_id}/revisions/{revision}/revoke
GET    /v1/speechrail/pronunciation-sets/{set_id}/revisions/{revision}
PUT    /v1/speechrail/pronunciation-sets/{set_id}
POST   /v1/speechrail/pronunciation-sets/{set_id}/revisions/{revision}/revoke
DELETE /v1/speechrail/pronunciation-sets/{set_id}
~~~

Send expected revision only when supplied. Map 409 voice_revision_mismatch to ServiceAPIClientError.http without retrying or overwriting local state. Quality run uses /v1/speechrail/voices/{id}/quality-runs first and retries the legacy /v1/voices/{id}/quality-runs only on route-not-found status 404/405; it does not fallback on auth, validation or backend errors.

- [ ] **Step 5: Keep Creator protocol and UI fakes source-compatible**

Add new protocol methods with default unsupported implementations. Update ServiceAPIClient and UnavailableCreatorClient. Existing UITestCreatorClient remains valid without fabricated revision data. Existing Creator method signatures remain unchanged.

- [ ] **Step 6: Run focused tests and commit**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: PASS for additive detail decode, expected-revision encoding, quality status preservation, namespaced route selection and legacy quality-route fallback boundaries.

~~~bash
git add macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
git commit -m "feat: align Voice revision and quality contracts"
~~~

## Task 5: 对齐 Speech、receipt、timing、transcription 与 jobs

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

**Interfaces:**

- Adds ServiceAPIClient.synthesize(_:) -> SpeechAudioResponse while retaining createSpeech(...) -> Data as a compatibility wrapper.
- Adds fetchReceipt(id:), fetchReceipt(byRequestID:), fetchTiming(id:), transcribe(_:) and typed job methods.
- SpeechAudioResponse contains audioData, contentType, receiptID, timingID and metadata.
- Existing preview/clone multipart builder is reused; transcription multipart uses contract field names and never logs text/audio.

- [ ] **Step 1: Add failing response/header and job tests**

~~~swift
func testAudioResponseAcceptsNonWavAndCarriesReceiptHeaders() throws {
    let response = try ServiceResponseDecoder.decodeAudio(
        Data([0x01, 0x02]),
        statusCode: 200,
        headers: [
            "Content-Type": "audio/mpeg",
            "SpeechRail-Receipt-Id": "rr_0123456789abcdef0123456789abcdef",
            "SpeechRail-Timing-Id": "tm_0123456789abcdef0123456789abcdef"
        ]
    )

    XCTAssertEqual(response.contentType, "audio/mpeg")
    XCTAssertEqual(response.receiptID, "rr_0123456789abcdef0123456789abcdef")
    XCTAssertEqual(response.timingID, "tm_0123456789abcdef0123456789abcdef")
}

func testSpeechRequestEncodesObjectVoice() throws {
    let request = SpeechRequest(
        input: "hello",
        voice: .id("voice_demo"),
        model: "tts-1.7b-base",
        responseFormat: "mp3",
        language: "en",
        instructions: nil,
        streamFormat: nil,
        speed: 1.0
    )

    let body = try JSONEncoder().encode(request)
    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual((object?["voice"] as? [String: String])?["id"], "voice_demo")
    XCTAssertEqual(object?["response_format"] as? String, "mp3")
}
~~~

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests.testAudioResponseAcceptsNonWavAndCarriesReceiptHeaders
~~~

Expected: FAIL because postAudio currently requires audio/wav and discards receipt/timing headers.

- [ ] **Step 3: Implement SpeechRequest, header options and audio response**

Add SpeechRailRequestOptions with expectedVoiceRevision, expectedModelRevision, pronunciationSet, receiptMode, timingMode, purpose and latencyBudgetMs. Encode only non-nil options. Change postAudio to accept any audio/* Content-Type, preserve the MIME in SpeechAudioResponse, and extract SpeechRail-Receipt-Id and SpeechRail-Timing-Id. Keep createSpeech as a compatibility wrapper returning audioData.

- [ ] **Step 4: Add typed receipt, timing and transcription methods**

Decode receipt and timing states pending/completed/unavailable/cancelled/error, preserve reason/planner/coordinate fields, and reject missing required response fields as invalidContract. Build transcription multipart with language/languages, prompt, timestamps and diarized options.

- [ ] **Step 5: Add typed jobs without speculative UI**

Implement POST/GET/DELETE/GET-result for /v1/jobs. Keep job status and result data typed in ServiceAPIClient; do not add a new AppModel page or persist remote job payloads. Mutation calls use Idempotency-Key only where request types expose it and never automatically replay a non-idempotent mutation.

- [ ] **Step 6: Run focused tests and commit**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
~~~

Expected: PASS for non-WAV audio, all SpeechRail headers, receipt/timing extraction, transcription multipart fields, job decoding and stable non-JSON errors.

~~~bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift
git commit -m "feat: expose SpeechRail audio receipts and jobs"
~~~

## Task 6: 建立 Realtime envelope、sequence integrity 与 clear barrier

**Files:**

- Create: macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift
- Create: macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift

**Interfaces:**

- RealtimeASRClient.events() changes to AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>>; the envelope carries metadata and the existing payload event.
- RealtimeASRClient initializer gains expectedModelRevision: String? and renderReceiptsEnabled: Bool with nil/false defaults.
- Adds clear() async throws and drainAndClear(timeout:) async throws.
- Existing Event cases remain available as payload cases; responseDone carries optional RenderReceipt and serverError carries retryable, busyReason and retryHint.

- [ ] **Step 1: Add failing envelope and sequence tests**

~~~swift
func testSequenceValidatorReportsGapAndRegression() {
    var validator = RealtimeSequenceValidator()

    XCTAssertEqual(
        validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 1)),
        .first
    )
    XCTAssertEqual(
        validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1", sequence: 3)),
        .gap(expected: 2, received: 3)
    )
    XCTAssertEqual(
        validator.accept(RealtimeEventMetadata(eventID: "e3", sessionID: "s1", sequence: 2)),
        .regression(last: 3, received: 2)
    )
}

func testCloseBarrierOnlyAllowsClearAfterEveryCommittedItemIsTerminal() {
    var barrier = RealtimeCloseBarrier()
    barrier.committed(itemID: "item-1")
    XCTAssertFalse(barrier.isReadyToClear)
    barrier.completed(itemID: "item-1")
    XCTAssertTrue(barrier.isReadyToClear)
}
~~~

- [ ] **Step 2: Run the focused Realtime test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
~~~

Expected: FAIL because the envelope, validator and barrier do not exist.

- [ ] **Step 3: Implement pure Realtime metadata and barrier types**

Define:

~~~swift
public struct RealtimeEventMetadata: Codable, Equatable, Sendable {
    public let eventID: String?
    public let sessionID: String?
    public let sequence: Int?
}

public struct RealtimeEventEnvelope<Payload: Sendable>: Sendable {
    public let metadata: RealtimeEventMetadata
    public let payload: Payload
}

public enum RealtimeSequenceStatus: Equatable, Sendable {
    case first
    case contiguous
    case gap(expected: Int, received: Int)
    case regression(last: Int, received: Int)
    case sessionChanged(expected: String?, received: String?)
    case missing
}
~~~

Keep client-specific payload cases in the App target if they refer to nested client types; the shared validator and close barrier remain pure and testable. The barrier tracks committed item IDs and removes them only on completed/failed terminal events.

- [ ] **Step 4: Update RealtimeASRClient configuration and event decoding**

Add model as a query parameter and keep it in session.update. Add session.speechrail.model_revision.expected only for a non-nil expected revision. Add session.speechrail.render_receipts.enabled only when enabled. Parse event_id, session_id and sequence before the type switch. Emit an envelope for every recognized event and expose integrity status when sequence is absent, jumps or regresses.

Decode both response.audio.delta and response.output_audio.delta. Decode response.done receipt from the current response shape and keep a compatibility parser for the nested/legacy literal. Decode error.retryable, error.speechrail.busy_reason and error.speechrail.retry_hint.

- [ ] **Step 5: Implement commit completion and clear**

Track committed item IDs from input_audio_buffer.committed and terminal transcription events. drainAndClear(timeout:) must:

~~~swift
try await commit()
try await waitForCommittedItems(timeout: timeout)
try await clear()
~~~

It must report a stage-specific timeout and never treat clear or WebSocket close as a completed receipt. clear() sends exactly input_audio_buffer.clear and is idempotent only within the current connection.

- [ ] **Step 6: Run Realtime tests and commit**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
~~~

Expected: PASS for envelope decoding, sequence first/contiguous/gap/regression behavior, busy fields, receipt decoding and close barrier state transitions.

~~~bash
git add macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift
git commit -m "feat: enforce Realtime event and clear contract"
~~~

## Task 7: 将三类 session 迁移到统一 drain-and-clear 顺序

**Files:**

- Modify: macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/App.swift
- Modify: macos/SpeechRailApp/SpeechRailApp/AppModel.swift
- Modify: macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift

**Interfaces:**

- AssistantSession, CaptionSession and MeetingSession keep their public start/stop/pause methods.
- Every session passes expected model revision and render receipt preference from the discovery snapshot when the operation supports them.
- Every logical recording uses RealtimeASRClient.drainAndClear(timeout:) before close.

- [ ] **Step 1: Add a close-order test at the pure barrier boundary**

~~~swift
func testDrainPlanOrdersCommitCompletionClearAndClose() {
    XCTAssertEqual(
        RealtimeClosePlan.steps,
        [.commit, .waitForTerminalItems, .clear, .close]
    )
}
~~~

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests.testDrainPlanOrdersCommitCompletionClearAndClose
~~~

Expected: FAIL because the close plan is not represented by the client contract.

- [ ] **Step 3: Update AssistantSession stopCapture**

Preserve the existing order that stops audio capture before sending commit. Replace the current commit, waitForFinalTurn, close sequence with drainAndClear(timeout:) followed by close. On a stage-specific failure, keep the existing local reset path and expose the failure as session diagnostics; do not claim the remote item completed.

- [ ] **Step 4: Update CaptionSession and MeetingSession**

For caption and meeting, keep finishDiarization before final drain completion when diarization is active:

~~~text
stop source
commit and wait for committed items
finish diarization when negotiated
wait for diarization drain
clear audio buffer
close WebSocket
~~~

The implementation must use one RealtimeASRClient barrier so an extra clear cannot race with a pending final transcription. Update event switches to consume envelope.payload and use envelope.metadata only for non-sensitive sequence diagnostics. Do not persist event IDs, raw audio or full event JSON.

- [ ] **Step 5: Pass negotiated revisions from App wiring**

When starting AssistantSession, CaptionSession or MeetingSession, read the current complete effective capability snapshot. Pass expected model revision only when the snapshot declares the model and operation. If discovery is unavailable, preserve optional negotiation behavior and let the service return a typed mismatch/not-ready error; do not infer revision from the model name.

- [ ] **Step 6: Run Realtime tests and commit**

Run:

~~~bash
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
~~~

Expected: PASS for close plan order and the three session files compile against envelope events and drainAndClear. No UI automation is run.

~~~bash
git add macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailApp/AppModel.swift macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift
git commit -m "feat: close Realtime recordings with a clear barrier"
~~~

## Task 8: 兼容 fake、错误展示与最终验证

**Files:**

- Modify only files already listed in Tasks 1-7 if a verification finding requires a minimal correction.
- Do not stage existing unrelated dirty files.

- [ ] **Step 1: Add failing error mapping coverage**

~~~swift
func testErrorMappingDistinguishesRevisionConflictFromUnavailableBackend() {
    XCTAssertEqual(
        ServiceErrorClassifier.category(
            for: ServiceAPIClientError.http(
                statusCode: 409,
                code: "voice_revision_mismatch",
                message: "redacted",
                requestID: "req-1",
                retryable: false
            )
        ),
        .conflict
    )
    XCTAssertEqual(
        ServiceErrorClassifier.category(
            for: ServiceAPIClientError.http(
                statusCode: 503,
                code: "backend_not_ready",
                message: "redacted",
                requestID: "req-2",
                retryable: true
            )
        ),
        .notReady
    )
}
~~~

- [ ] **Step 2: Update fake clients and stable user-facing categories**

Give new protocol methods default unsupported implementations and update UITestServiceDiagnosticsClient/UITestCreatorClient only where a deterministic fixture is needed. Do not synthesize a ready or capability snapshot from an empty fixture. Map invalidContract, unauthorized, conflict, backendBusy, notReady, voiceRevoked and unsupported separately; keep request IDs in diagnostics only. Do not alter AssistantView.swift or other parallel UI files unless a compiler error proves a minimal call-site update is required.

- [ ] **Step 3: Run the authorized deterministic tests**

Run only when the implementation turn has explicit automated-validation authorization:

~~~bash
swift test --package-path macos/SpeechRailApp
~~~

Expected: PASS for SpeechRailMacControlTests. If authorization is absent, report this command as not run rather than executing it.

- [ ] **Step 4: Run the authorized App build**

Run only with explicit validation authorization:

~~~bash
scripts/macos_app_build.sh --configuration Debug
~~~

Expected: the Debug build completes without changing runtime configuration. Do not run scripts/macos_app_test.sh because this project requires per-message authorization for UI automation.

- [ ] **Step 5: Perform code review against the five Review Focus items**

Use the code-review-and-quality skill to inspect 304 cache behavior, unauthorized/no-fallback behavior, unknown enum and missing-key behavior, audio MIME/receipt/timing metadata, and Realtime sequence/close barrier. Record actionable inline comments only when a concrete line-level issue remains. Do not mark the implementation complete from a green compile alone.

- [ ] **Step 6: Inspect the final diff and report evidence**

Run:

~~~bash
git status --short
git diff origin/main...HEAD --check
git diff origin/main...HEAD --stat
git diff origin/main...HEAD -- macos/SpeechRailApp
~~~

Expected: every changed file belongs to Tasks 1-7; no API key, Authorization value, PCM, Base64 payload, full prompt, full transcript, absolute model path or unrelated parallel edit appears in the diff. Final report must list changed files, commit list, commands actually run with verification time, commands intentionally not run, runtime actions, remaining risks, preserved parallel changes and commit-level rollback path.

## Handoff

Plan complete and saved to docs/superpowers/plans/2026-09-20-macos-app-contract-alignment-plan.md. The plan is intentionally native-execution oriented because its tasks share Swift interfaces and AppModel/Realtime session state, so an independent subagent per task would increase merge risk. Please review the plan and confirm it captures the intended implementation before code changes begin.
