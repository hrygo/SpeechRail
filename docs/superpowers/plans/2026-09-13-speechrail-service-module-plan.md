# SpeechRail 服务模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 SpeechRail macOS App 实现可解释、可确认、可回退的服务管理、运行监控、预检诊断和独立模型下载/校验能力，并让普通用户与开发者在同一页面获得不同深度的有效信息。

**Architecture:** Python 侧新增 catalog/status/prepare 的受控模型命令，复用 `model_store` 和现有分人资产校验；Swift `SpeechRailControlKit` 扩展固定的 schema v1 数据类型，`SpeechRailControlAgent` 负责唯一 mutation、JSONL 进度转发和安全取消；App 通过 loopback `/health`、`/metrics` 读取诊断，通过 XPC 读取服务和模型 operation，控制中心只消费已脱敏的 typed state。模型“下载并校验”和“应用此档位”保持两个独立动作。

**Tech Stack:** Python 3.12、`uv`、Pydantic catalog、`model_store`、ModelScope downloader、现有 FluidAudio diarization asset path、Swift 6、SwiftUI、Observation、Swift Charts、XCTest/XCUITest、XPC、URLSession。

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md`

## Execution status (2026-09-13, Asia/Shanghai)

核心实现已落地并拆成两个主提交：`c174581`（模型目录、状态、准备、JSONL 进度、取消、ControlKit/Agent 协议）和 `ecd70a2`（macOS 26-only 控制中心、服务总览、运行监控、模型管理、预检诊断、音色创作保留、fake UI 场景和文档）；随后以 `47eab12` 收紧趋势图的最小采样门槛。原始设计包及图稿已在更早提交中归档到 `docs/design/archive/2026-09-12-macos-app-design-package/`。

已验证：Python 全量测试 `1761 passed, 1 skipped`，ruff、mypy、OpenAPI lint、plist lint、App build、App unit tests 和 UI `build-for-testing` 通过。真正启动 XCUITest 尚未完成：当前 Mac 锁屏，且此前启动还遇到 Xcode LLDB debugger-version store 错误；不能把构建通过表述为 UI 运行通过。

实现偏差是有意的：模型 `prepare` 保持独立，不接入 `profile_commands.py` 的 apply 事务；“下载并校验”不会切换 active profile，profile apply 仍走既有切换/回退链路。`ServicePayloadTests.swift` 未单独创建，diagnostics/sampler 的编译与行为由现有 App/ControlKit 构建、fake UI 场景和 Python/协议测试覆盖。解除锁屏后应优先执行 `scripts/macos_app_test.sh`，再做真实模型下载验收；真实模型、音频、日志和 runtime 仍不进入仓库。

## Global Constraints

- Python 固定为 `>=3.12,<3.13`，运行目标为 macOS Apple Silicon；服务模块的 SwiftUI 页面只在 `SpeechRailApp` GUI target 中实现，该 target 使用 macOS 26.0，不为 macOS 14 编写 UI fallback。
- 默认只绑定 loopback；不新增远程管理入口，不把 API key 放入 URL 或 UI 文案。
- App 不直接访问模型源、模型目录、日志或音频；模型下载只由 control agent 委托 managed Python CLI 执行。
- 下载目标只能来自仓库内锁定的 model catalog、revision、文件大小和 SHA-256；不接受任意 URL、repository、revision、路径或 shell 参数。
- `quality`、`balanced`、`light` 继续使用固定 profile enum；现有 profile list/status/apply/rollback 外部行为保持兼容。
- 模型准备使用既有 staging、磁盘空间检查、流式写入、单文件校验、完整快照校验、原子发布和 registry；失败不得覆盖已验证旧快照。
- 同一时刻只允许一个服务或模型 mutation；不得复制 ASGI worker 或模型进程；ASR/TTS 运行态资源边界不因 App 功能改变。
- `/health` 和 `/metrics` 只读复用现有公共接口；metrics 只接收 JSON、低基数的 active/pending、worker、health、counter 和 histogram，不新增 HTTP 管理 API。
- App 监控仅在运行监控页面可见时每 5 秒采样，内存最多保留最近 60 个样本，离开页面或进程退出不写历史数据库。
- 默认显示“现在是否可用、影响什么、下一步做什么”的解释层；profile、health、metrics、operation phase、revision 和 hash 结果放在可展开的技术详情中，不设置开发者模式开关。
- 状态同时使用图标、文字和形状标记；缺失数据不渲染为零，服务不可达不渲染为正常，没有足够样本不绘制趋势。
- 不显示 API key、`Authorization`、绝对模型路径、完整异常、原始日志、原始音频、完整转写、prompt、Base64 或实名 speaker。
- 真实模型下载、真实服务启停、真实音频和真实网络不进入 Swift unit test/UI test；测试使用 fake downloader、fake runner、fake transport 和 fake diagnostics。
- 本计划依赖 `2026-09-13-speechrail-app-framework-plan.md` 产出的 `AppRoute`、`AppNavigationState`、`SurfaceHeaderView` 和 `ControlCenterView`，但服务 Python/ControlKit/Agent 数据层可以先独立测试。

---

## 1. 范围、顺序与完成定义

本计划覆盖四条完整链路：

```text
模型目录/校验事实
    ├── Python model.catalog / model.status / model.prepare
    ├── ControlKit modelCatalog / modelStatus / modelPrepare
    └── Swift 模型管理页

/health + /metrics
    ├── ServiceAPIClient typed decoder
    ├── 60 点内存采样与 counter/histogram 派生
    └── Swift 总览/运行监控页

服务 mutation
    └── XPC → AgentOperationStore → managed CLI → LaunchAgent/profile store

模型 mutation
    └── XPC → AgentOperationStore → JSONL progress → model_store → 原子发布
```

建议按以下顺序执行：先完成 Python 模型事实与命令，再完成 ControlKit 协议和 Agent operation，随后完成 ServiceAPIClient/AppModel，最后接入页面和 UI tests。每个 Task 都有独立测试和独立 commit；只有 Task 8 的完整 gate 通过后，才宣称服务模块完成。

本计划不提供模型删除动作，不把模型下载自动绑定为 profile 应用，不通过 App 直接执行 `launchctl`，也不实现配音或音色生成后端。

## 2. 文件地图

### Python 服务层

- Create: `src/speechrail/service/model_commands.py`：模型 catalog/status/prepare 的安全 DTO、payload 和准备编排。
- Modify: `src/speechrail/service/model_store.py`：增加不暴露路径的 artifact inspector，并补齐 verifying/publishing progress event。
- Modify: `src/speechrail/service/diarization_assets.py`：为 aligner/CoreML 分人资产增加进度、取消检查和安全状态 inspector。
- Modify: `src/speechrail/service/profile_commands.py`：让 profile apply 复用模型准备编排，同时保留现有 profile switch、配置更新和 rollback 事务。
- Modify: `src/speechrail/service/__init__.py`：导出新模型命令类型（若当前模块使用显式 `__all__`）。
- Modify: `src/speechrail/cli.py`：增加 `model catalog/status/prepare` parser、JSONL machine output、确认和 SIGTERM 取消。
- Create: `tests/test_model_commands.py`：模型目录、状态、磁盘摘要、准备编排和取消测试。
- Modify: `tests/test_model_store.py`：新增 inspector、阶段事件、取消保留旧快照测试。
- Modify: `tests/test_profile_commands.py`：确认 profile apply 与独立 model prepare 不重复破坏状态。
- Modify: `tests/test_cli_machine_output.py`：新增 model 命令 JSON/JSONL、无路径和确认测试。

### Swift 公共控制协议与 Agent

- Create: `macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift`：health、metrics、model、operation progress typed state。
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift`：扩展 command、response、profile summary、error code 和 validation。
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift`：新增模型 command、JSONL progress parser、受控 process cancel。
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`：统一 profile/model mutation、阶段更新和 model cancel。
- Modify: `macos/SpeechRailApp/SpeechRailControlAgent/main.swift`：保持同一 Agent 入口，接入更新后的 runner/store。
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`：协议类型、确认和编码回归。
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`：progress、cancel、串行 mutation 和 CLI JSONL 回归。

### Swift App 数据、页面与测试

- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`：详细 health/metrics decoder、Accept header 和错误语义。
- Create: `macos/SpeechRailApp/SpeechRailApp/RuntimeMetricsSampler.swift`：counter/histogram 派生和 60 点采样规则。
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`：overview、model、monitoring refresh、operation progress 和生命周期。
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`：fake diagnostics、fake model catalog/status/progress，保持真实入口不变。
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`：把服务 route preview 替换为真实页面。
- Create: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`：服务健康脉冲、能力矩阵和服务 mutation。
- Create: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`：监控看板和最近 60 点样本。
- Create: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`：三档目录、制品状态、下载确认和 operation 阶段。
- Create: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`：预检结果、恢复动作和技术详情。
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift`、`ProfilePickerView.swift`：复用服务页面状态组件和统一确认文案。
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`：菜单栏状态和控制中心入口复用详细 health 摘要。
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`：加入新 App/ControlKit/AgentCore source 和 unit test source。
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/ServicePayloadTests.swift`：新增 ServiceAPIClient 与 sampler 测试，必要时把纯 Foundation 文件加入现有 unit test target。
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`：服务页、模型下载、监控空状态、菜单栏入口和失败恢复。
- Modify: `docs/developers/macos-app-development.md`、`docs/users/README.md`：记录服务模块边界、模型下载行为、监控含义和测试命令。

## 3. 跨层数据契约

### 3.1 Python machine output

`model catalog --json` 输出一行最终结果：

```json
{"schema_version":1,"command":"model.catalog","status":"ok","artifacts":[{"key":"tts-1.7b-base-q8","model_id":"mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit","family":"qwen3_tts","variant":"base","revision":"0123456789abcdef0123456789abcdef01234567","provider":"modelscope","repository":"mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit","quantization":{"bits":8,"group_size":64,"format":"mlx"},"size_bytes":123456,"file_count":12,"required_by":["quality"]}],"profiles":[]}
```

`model status --json` 输出一行最终结果：

```json
{"schema_version":1,"command":"model.status","status":"ok","artifacts":[{"key":"tts-1.7b-base-q8","state":"verified","integrity":"verified","verified_file_count":12,"total_file_count":12}],"disk":{"model_bytes":0,"free_bytes":0}}
```

上面示例中的数值仅表示字段形状；实现和测试必须从 fake catalog 派生实际值，不能在 UI 或命令中硬编码容量。`model prepare` 在 `--json` 下按 JSONL 输出 progress，最后输出且只输出一个 result：

```json
{"schema_version":1,"event":"progress","command":"model.prepare","phase":"download","artifact":"tts-1.7b-base-q8","file":"model.safetensors","bytes":123,"expected_bytes":456}
{"schema_version":1,"event":"result","command":"model.prepare","status":"committed","prepared_id":"prepared_0123456789abcdef"}
```

取消、下载失败、完整性错误和磁盘不足的 result 必须带稳定 `error_code` 和 path-free `message`；progress 不带绝对路径、URL、token 或异常详情。

### 3.2 Swift ControlKit 类型

在 `ServiceDiagnosticsTypes.swift` 固定以下类型和字段：

```swift
public struct DiarizationStatusSnapshot: Codable, Equatable, Sendable {
    public let configured: Bool
    public let ready: Bool
    public let code: String?
    public let message: String
    public let profile: String?
}

public struct RealtimeVADStatusSnapshot: Codable, Equatable, Sendable {
    public let configuredEngine: String
    public let resolvedEngine: String
    public let speechAdmissionEnabled: Bool
    public let ready: Bool
    public let code: String?
    public let message: String
}

public struct HealthSnapshot: Codable, Equatable, Sendable {
    public let status: String?
    public let service: String?
    public let version: String?
    public let backend: String?
    public let profile: SpeechRailProfile?
    public let asrReady: Bool?
    public let ttsReady: Bool?
    public let ttsWarm: Bool?
    public let diarizationReady: Bool?
    public let diarization: DiarizationStatusSnapshot?
    public let asrState: String?
    public let ttsState: String?
    public let streamingState: String?
    public let realtimeVAD: RealtimeVADStatusSnapshot?
    public let ready: Bool?
    public let jobSpoolReady: Bool?
}

public struct RuntimeRequestCounts: Codable, Equatable, Sendable {
    public let realtime: Int
    public let batch: Int
}

public struct RuntimeHistogramSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let sum: Double
    public let average: Double
}

public struct RuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    public let activeRequests: RuntimeRequestCounts
    public let pendingRequests: RuntimeRequestCounts
    public let workers: [String: String]
    public let health: [String: Bool]
    public let counters: [String: Double]
    public let gauges: [String: Double]
    public let histograms: [String: [String: RuntimeHistogramSummary]]
    public let capturedAt: Date
}

public enum ModelArtifactState: String, Codable, Sendable {
    case notDownloaded = "not_downloaded"
    case downloading
    case verified
    case invalid
    case unknown
}

public enum ModelIntegrityState: String, Codable, Sendable {
    case verified
    case mismatch
    case notChecked = "not_checked"
}

public struct ModelQuantizationSnapshot: Codable, Equatable, Sendable {
    public let bits: Int?
    public let groupSize: Int?
    public let format: String
}

public struct ModelArtifactSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let modelID: String
    public let family: String
    public let variant: String
    public let revision: String
    public let provider: String
    public let repository: String
    public let quantization: ModelQuantizationSnapshot
    public let sizeBytes: Int64
    public let fileCount: Int
    public let requiredBy: [SpeechRailProfile]
}

public struct ModelArtifactStatusSnapshot: Codable, Equatable, Sendable {
    public let key: String
    public let state: ModelArtifactState
    public let integrity: ModelIntegrityState
    public let verifiedFileCount: Int
    public let totalFileCount: Int
}

public struct ModelDiskSnapshot: Codable, Equatable, Sendable {
    public let modelBytes: Int64
    public let freeBytes: Int64
}

public struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
    public let artifacts: [ModelArtifactSnapshot]
    public let profiles: [ProfileSummary]
}

public struct ModelStatusSnapshot: Codable, Equatable, Sendable {
    public let artifacts: [ModelArtifactStatusSnapshot]
    public let disk: ModelDiskSnapshot
}

public struct OperationProgressSnapshot: Codable, Equatable, Sendable {
    public let artifactKey: String?
    public let file: String?
    public let completedBytes: Int64?
    public let expectedBytes: Int64?
}
```

每个 `public struct` 都显式提供 `public init`，参数顺序与属性顺序一致；不能依赖 Swift 默认的 internal memberwise initializer。所有 optional 字段的默认值按现有 fake 调用点提供，新增 model/diagnostics 字段不要求旧 response 携带它们。

`OperationSnapshot` 增加 `progress: OperationProgressSnapshot?`；`ProfileSummary` 增加可选 `ttsClone: String?`；`ControlResponse` 增加可选 `modelCatalog` 和 `modelStatus`。现有字段和 schema v1 保持兼容，CLI decoder 对 snake_case 做显式 `CodingKeys` 映射，XPC wire 不改已有字段名称。

## 4. 实施任务

### Task 1: 建立模型目录、状态 inspector 与统一准备编排

**Files:**
- Create: `src/speechrail/service/model_commands.py`
- Modify: `src/speechrail/service/model_store.py:282-295,425-460,1079-1243`
- Modify: `src/speechrail/service/diarization_assets.py:78-195`
- Modify: `src/speechrail/service/profile_commands.py:16-35,150-169,322-335`
- Modify: `src/speechrail/service/__init__.py`
- Create: `tests/test_model_commands.py`
- Modify: `tests/test_model_store.py`
- Modify: `tests/test_profile_commands.py`

**Interfaces:**
- `model_store.py` 产生以下不含路径的 DTO 和 inspector：

```python
ModelIntegrity = Literal["verified", "mismatch", "not_checked"]
ModelState = Literal["not_downloaded", "verified", "invalid"]

@dataclass(frozen=True, slots=True)
class PreparedArtifactStatus:
    key: str
    state: ModelState
    integrity: ModelIntegrity
    verified_file_count: int
    total_file_count: int
```

`inspect_prepared_artifacts(app_home: Path, *, catalog: ModelCatalog | None = None, runtime_lock: RuntimeLock | None = None) -> tuple[PreparedArtifactStatus, ...]` 的实现必须执行本任务上文规定的 registry、manifest、size 和 SHA-256 判定；返回值中的 variadic tuple 只表示 artifact 数量由 catalog 决定。

- `diarization_assets.py` 产生与上面字段相同的 `DiarizationArtifactStatus` 和 `inspect_diarization_assets(app_home: Path, *, preset_id: str, catalog: ModelCatalog | None = None) -> tuple[DiarizationArtifactStatus, ...]`；`diarization-coreml` 与 aligner 都使用锁定的文件 manifest。
- `model_commands.py` 产生 `model_catalog_payload(*, catalog: ModelCatalog | None = None) -> dict[str, object]`、`model_status_payload(app_home: Path, *, catalog: ModelCatalog | None = None, runtime_lock: RuntimeLock | None = None, disk_usage: DiskUsage | None = None) -> dict[str, object]` 和 `prepare_profile_models(preset: PresetId, app_home: Path, *, progress: ProgressCallback | None = None, cancel_event: asyncio.Event | None = None, downloader: Downloader | None = None, catalog: ModelCatalog | None = None, runtime_lock: RuntimeLock | None = None) -> str`。
- `prepare_profile_models` 先调用现有 `prepare_models()` 处理 ASR/TTS/可选 clone，再对 `catalog.preset(preset).diarization` 为真的档位调用现有 `prepare_diarization_assets()` 处理 aligner 与 FluidAudio CoreML；它只准备制品，不写 active profile 和私有配置。

- [ ] **Step 1: 写 inspector 和 progress 的失败测试**

在现有 `tests/test_model_store.py` 复用 `_catalog()`、`_runtime_lock()`、`_prepare()` 和 `FakeDownloader`，覆盖三种 artifact 结果；在新建的 `tests/test_model_commands.py` 只测试 catalog payload 的安全字段和 `required_by`：

```python
from speechrail.config.model_catalog import load_catalog
from speechrail.service.model_commands import model_catalog_payload


def test_model_catalog_payload_has_required_by_and_no_local_path() -> None:
    payload = model_catalog_payload(catalog=load_catalog())

    assert {item["id"] for item in payload["profiles"]} == {"quality", "balanced", "light"}
    assert all(item["required_by"] for item in payload["artifacts"])
    assert all("path" not in item for item in payload["artifacts"])
    assert all("url" not in item for item in payload["artifacts"])
```

```python
@pytest.mark.anyio
async def test_model_status_distinguishes_missing_verified_and_invalid(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    lock = _runtime_lock()
    await _prepare(tmp_path, catalog, lock, FakeDownloader(payloads), preset="quality")
    (tmp_path / "models" / "design" / "config.json").write_bytes(b"corrupt")

    payload = model_status_payload(tmp_path, catalog=catalog, runtime_lock=lock)

    states = {item["key"]: item["state"] for item in payload["artifacts"]}
    assert states["asr"] == "verified"
    assert states["design"] == "invalid"
    assert states["custom"] == "not_downloaded"
    integrity = {item["key"]: item["integrity"] for item in payload["artifacts"]}
    assert integrity["asr"] == "verified"
    assert integrity["design"] == "mismatch"
    assert all("path" not in item for item in payload["artifacts"])
```

在 `tests/test_model_store.py` 增加：

```python
async def test_prepare_emits_verifying_and_publishing_before_commit(tmp_path: Path) -> None:
    catalog, payloads = _catalog()
    events: list[dict[str, object]] = []
    prepared_id = await _prepare(
        tmp_path,
        catalog,
        _runtime_lock(),
        FakeDownloader(payloads),
        preset="light",
        progress=events.append,
    )

    assert prepared_id.startswith("prepared_")
    phases = [str(event["phase"]) for event in events]
    assert "download" in phases
    assert phases.index("verifying") < phases.index("publishing") < phases.index("verified")
```

- [ ] **Step 2: 运行定向测试确认新接口尚不存在**

运行：

```bash
uv run --extra dev pytest tests/test_model_commands.py tests/test_model_store.py -q
```

预期：失败在 import 或缺少 inspector/progress phase，而不是因为网络访问；测试不得创建真实模型下载请求。

- [ ] **Step 3: 实现 `inspect_prepared_artifacts` 和 model payload**

Inspector 的判定顺序固定为：读取 catalog artifact 清单；读取现有 registry；若存在匹配当前 `model_id`、revision、source、文件 manifest、quantization 且 `_verify_snapshot` 全部通过，返回 `verified`；若 registry 或目录存在但 manifest/大小/hash 不匹配，返回 `invalid` 并统计通过校验的文件数；既无可验证 registry 也无对应快照时返回 `not_downloaded`。任何返回对象都不能包含 `Path`。

`model_catalog_payload` 从 catalog 和 profile 引用反向计算 `required_by`；除当前 catalog 中的安全字段外不输出 source URL、token、绝对路径或文件 hash。`model_status_payload` 把 `models` 和 `diarization` 下通过 manifest 校验的文件大小汇总为 `model_bytes`，用 `shutil.disk_usage(app_home).free` 提供 `free_bytes`，磁盘查询异常返回明确的 `ModelStoreError`。

- [ ] **Step 4: 为 model_store 和 diarization asset 增加阶段与取消检查**

在 `prepare_models()` 中加入以下阶段事件：

```python
_emit(progress, {"phase": "verifying", "prepared_id": prepared_id})
_check_cancel(cancel_event)
_emit(progress, {"phase": "publishing", "prepared_id": prepared_id})
```

事件必须位于完整 staged snapshot 校验之后、原子 publish 之前；publish 内部的 rollback 保持现有 `BaseException` 语义。`diarization_assets.py` 的 `_write_file()` 对每个块执行 cancel check，并以 artifact key `diarization-coreml` 或 aligner key 发出 `download`；`_publish_bundle()` 在已校验目标返回 `cache_hit`，在原子 replace 前发出 `publishing`，成功后发出 `verified`。取消只清理 staging，不删除已有 verified bundle。

- [ ] **Step 5: 实现 `prepare_profile_models` 并接入 profile apply**

`prepare_profile_models()` 使用注入的 `Downloader` 时不创建或关闭外部 client；未注入时创建现有 timeout 配置的 `httpx.Client` 和 `ModelScopeDownloader`。它把同一个 `progress`、`cancel_event` 传入两个准备层，并在 `diarization_assets` 失败时保留 path-free `ProfileCommandError` 映射。`profile_commands.apply_profile()` 继续执行 VAD、分人配置更新和 `switch`，但准备阶段通过统一函数复用既有校验路径；重复执行时只能命中已校验缓存，不重复覆盖当前 profile。

- [ ] **Step 6: 运行测试确认模型事实和取消语义通过**

运行：

```bash
uv run --extra dev pytest tests/test_model_commands.py tests/test_model_store.py tests/test_profile_commands.py -q
```

预期：通过 missing/verified/invalid 判定、catalog required_by、阶段顺序、磁盘不足、取消清理和 profile apply 兼容测试；断言中不能出现绝对模型路径或真实下载 URL。

- [ ] **Step 7: 提交模型事实层**

```bash
git add src/speechrail/service/model_commands.py src/speechrail/service/model_store.py src/speechrail/service/diarization_assets.py src/speechrail/service/profile_commands.py src/speechrail/service/__init__.py tests/test_model_commands.py tests/test_model_store.py tests/test_profile_commands.py
git commit -m "feat: expose safe SpeechRail model state"
```

### Task 2: 增加 `model catalog/status/prepare` CLI 和 JSONL operation 输出

**Files:**
- Modify: `src/speechrail/cli.py:65-151,197-236,274-395,755-794`
- Modify: `tests/test_cli_machine_output.py`
- Create: `tests/test_cli_model_commands.py`

**Interfaces:**
- Parser 固定提供 `speechrail model catalog --app-home PATH [--json]`、`speechrail model status --app-home PATH [--json]` 和 `speechrail model prepare {quality,balanced,light} --app-home PATH [--yes] [--json]`。
- `model catalog/status` 是只读命令；`model prepare` 没有 `--yes` 或在非交互 stdin 下不能开始下载。
- `model prepare --json` 的 stdout 只包含 progress JSONL 和一个 final result JSON；stderr 只允许短、脱敏的人类诊断。
- `_machine_command()` 对 model 子命令返回字符串 `"model." + args.model_command`；`_machine_error_code()` 为 `insufficient_disk_space`、`integrity_mismatch`、`source_unavailable`、`cancelled` 和 `unsupported` 提供稳定映射。

- [ ] **Step 1: 写 CLI parser、JSON 和确认失败测试**

在 `tests/test_cli_model_commands.py` 先加入 `json`、`pytest`、`from speechrail import cli`、`from speechrail.cli import main` 和 `from speechrail.service import model_commands` imports，再加入以下测试：

```python
def test_model_prepare_without_yes_does_not_start_download(monkeypatch: pytest.MonkeyPatch) -> None:
    called = False

    async def fake_prepare(*args: object, **kwargs: object) -> str:
        nonlocal called
        called = True
        return "prepared_test"

    monkeypatch.setattr(model_commands, "prepare_profile_models", fake_prepare)
    exit_code = main(["model", "prepare", "light", "--json"])

    assert exit_code == 1
    assert called is False
```

```python
def test_model_catalog_json_contains_only_safe_fields(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["model", "catalog", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "model.catalog"
    assert payload["schema_version"] == 1
    assert all("path" not in artifact for artifact in payload["artifacts"])
```

- [ ] **Step 2: 运行新 CLI 测试确认 parser 尚不存在**

运行：

```bash
uv run --extra dev pytest tests/test_cli_model_commands.py tests/test_cli_machine_output.py -q
```

预期：失败在 `model` subparser 或输出分支不存在。

- [ ] **Step 3: 增加 model parser 和只读输出**

在 `_parser()` 增加 `model` subparser；`catalog/status` 都接受 `--app-home`、`--json`，`prepare` 接受位置 profile、`--app-home`、`--yes`、`--json`。`_run_model()` 调用 Task 1 的 payload 函数，以 `_print_machine()` 保持 `schema_version=1`；非 JSON 输出解释用途、估算容量、当前 profile 和本机状态，但不输出绝对路径。

- [ ] **Step 4: 实现 prepare 确认、progress JSONL 和 SIGTERM 取消**

`_run_model()` 在确认前只读取 catalog 和磁盘摘要；确认通过后创建 `asyncio.Event`，为当前 event loop 注册 `SIGTERM` handler，将 event 设为 true，再调用 `prepare_profile_models()`。progress callback 只投影允许字段：`phase`、`artifact`、`file`、`bytes`、`expected_bytes`；file 使用 manifest-relative path。任务结束后移除 signal handler。

成功、失败和取消分别输出 `status=committed`、`status=failed`、`status=cancelled`。捕获 `asyncio.CancelledError` 时等待 staging cleanup 完成后输出取消 result，不输出 Python traceback；`_machine_message()` 继续执行 key/token/path 脱敏和 240 字符上限。

- [ ] **Step 5: 运行 CLI 定向测试**

运行：

```bash
uv run --extra dev pytest tests/test_cli_model_commands.py tests/test_cli_machine_output.py -q
```

预期：通过只读命令、`--yes` 门槛、progress/result JSONL、取消和无绝对路径测试；现有 profile/service machine output 测试保持通过。

- [ ] **Step 6: 提交 CLI 命令**

```bash
git add src/speechrail/cli.py tests/test_cli_machine_output.py tests/test_cli_model_commands.py
git commit -m "feat: add SpeechRail model CLI"
```

### Task 3: 扩展 ControlKit 的模型、诊断和 operation progress 协议

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift:17-47,69-80,82-119,134-154,187-280`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- `ControlCommand` 增加 `modelCatalog`、`modelStatus`、`modelPrepare`，raw value 分别为 `model.catalog`、`model.status`、`model.prepare`。
- `modelPrepare` 的 `requiresConfirmation` 和 `isMutation` 为 true；`ControlRequest.validate()` 要求 `profile != nil`。
- `ControlErrorCode` 增加 `insufficientDiskSpace = "insufficient_disk_space"`、`integrityMismatch = "integrity_mismatch"`、`sourceUnavailable = "source_unavailable"`、`cancelled`。
- `ControlResponse` 增加 `modelCatalog: ModelCatalogSnapshot?` 和 `modelStatus: ModelStatusSnapshot?`；`ProfileSummary` 增加 `ttsClone`；`OperationSnapshot` 增加 `progress`。

- [ ] **Step 1: 写协议失败测试**

在 `ControlKitTests.swift` 增加：

```swift
func testModelPrepareRequiresProfileAndConfirmation() throws {
    XCTAssertThrowsError(try ControlRequest(command: .modelPrepare).validate()) { error in
        XCTAssertEqual(error as? ControlProtocolError, .confirmationRequired)
    }

    XCTAssertThrowsError(
        try ControlRequest(command: .modelPrepare, confirmation: true).validate()
    ) { error in
        XCTAssertEqual(error as? ControlProtocolError, .profileRequired)
    }

    XCTAssertNoThrow(
        try ControlRequest(
            command: .modelPrepare,
            profile: .balanced,
            confirmation: true
        ).validate()
    )
}
```

再增加一个 `ModelStatusSnapshot` 和带 `OperationProgressSnapshot` 的 `OperationSnapshot` round-trip，断言 `completedBytes`、`expectedBytes`、`ttsClone` 和 `state=.cancelled` 在编码解码后保持一致。

- [ ] **Step 2: 运行 ControlKit 测试确认新 command/type 尚不存在**

运行：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' -only-testing:SpeechRailAppTests/SpeechRailMacControlTests test
```

预期：失败在新 command/type 或 initializer 不存在。

- [ ] **Step 3: 写入 typed types 和 validation**

按本计划第 3.2 节的字段实现 `ServiceDiagnosticsTypes.swift`，所有 collection 使用 `Codable, Equatable, Sendable`，构造器参数顺序与字段名保持一致。修改 `ControlTypes.swift` 时保持既有 schema version、既有 response 字段和 profile raw value；新字段全部可选，旧 Agent/旧 CLI 响应缺少新字段时仍能被 App 读取。

- [ ] **Step 4: 更新 protocol 编解码和 target membership**

为 `ControlResponse.rebound(to:)` 传递 `modelCatalog`、`modelStatus`、`operation.progress`；为 `ProfileSummary` 的 `ttsClone` 设置默认值，避免现有 fake/调用点被迫提供 clone。把 `ServiceDiagnosticsTypes.swift` 加入 ControlKit group 和 sources phase。不得把 App 专属 View 或 URLSession 类型放入 ControlKit。

- [ ] **Step 5: 运行协议测试并检查 project**

运行：

```bash
scripts/macos_app_test.sh
```

预期：ControlKit round-trip、request validation 和现有服务/profile 协议通过；`git diff --check` 无空白错误。

- [ ] **Step 6: 提交 ControlKit 协议**

```bash
git add macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj
git commit -m "feat: extend SpeechRail control protocol"
```

### Task 4: 让 Agent 转发 JSONL progress、串行模型 mutation 并支持安全取消

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift:12-200,275-400`
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift:4-216`
- Modify: `macos/SpeechRailApp/SpeechRailControlAgent/main.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`

**Interfaces:**
- `ManagedCommand` 增加 `.modelCatalog`、`.modelStatus`、`.modelPrepare(SpeechRailProfile, operationID: String)`。
- `ManagedCommandProgressEvent` 固定为：

```swift
public struct ManagedCommandProgressEvent: Sendable {
    public let command: ControlCommand
    public let phase: String
    public let artifactKey: String?
    public let file: String?
    public let completedBytes: Int64?
    public let expectedBytes: Int64?
}

public typealias ManagedCommandProgressHandler =
    @Sendable (ManagedCommandProgressEvent) -> Void
```

- `ManagedCommandRunner` 固定增加：

```swift
public protocol ManagedCommandRunner: Sendable {
    func run(
        _ command: ManagedCommand,
        progress: ManagedCommandProgressHandler?
    ) async throws -> ManagedCommandResult

    func cancel(operationID: String) async
}

public extension ManagedCommandRunner {
    func run(_ command: ManagedCommand) async throws -> ManagedCommandResult {
        try await run(command, progress: nil)
    }

    func cancel(operationID: String) async {}
}
```

- 测试使用下面的 actor fake；它只在 `run` 收到模型 command 后保存 progress handler，`cancel` 时返回一个确定性的 cancelled response：

```swift
private actor RecordingManagedCommandRunner: ManagedCommandRunner {
    private var progressHandler: ManagedCommandProgressHandler?
    private var continuation: CheckedContinuation<ManagedCommandResult, Never>?
    private(set) var cancelledOperationID: String?

    func run(
        _ command: ManagedCommand,
        progress: ManagedCommandProgressHandler?
    ) async throws -> ManagedCommandResult {
        progressHandler = progress
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReady() async {
        for _ in 0..<100 where progressHandler == nil {
            await Task.yield()
        }
    }

    func emit(_ event: ManagedCommandProgressEvent) {
        progressHandler?(event)
    }

    func cancel(operationID: String) {
        cancelledOperationID = operationID
        continuation?.resume(
            returning: ManagedCommandResult(
                exitCode: 0,
                response: ControlResponse(
                    requestID: UUID(),
                    command: .modelPrepare,
                    status: .cancelled,
                    errorCode: .cancelled,
                    message: "model preparation cancelled"
                )
            )
        )
        continuation = nil
    }
}
```

- [ ] **Step 1: 写 runner/store 的失败测试**

在 `AgentCoreTests.swift` 增加 fake runner progress 和 cancel 记录：

```swift
func testModelPrepareProgressIsStoredAndCanBeCancelled() async throws {
    let runner = RecordingManagedCommandRunner()
    let store = AgentOperationStore(runner: runner)
    let accepted = await store.handle(
        ControlRequest(command: .modelPrepare, profile: .quality, confirmation: true)
    )
    let operationID = try XCTUnwrap(accepted.operation?.operationID)
    await runner.waitUntilReady()

    await runner.emit(
        ManagedCommandProgressEvent(
            command: .modelPrepare,
            phase: "download",
            artifactKey: "tts-1.7b-design-q8",
            file: "model.safetensors",
            completedBytes: 4,
            expectedBytes: 8
        )
    )
    try await Task.sleep(for: .milliseconds(20))

    let running = await store.handle(
        ControlRequest(command: .operationStatus, operationID: operationID)
    )
    XCTAssertEqual(running.operation?.phase, "downloading")
    XCTAssertEqual(running.operation?.progress?.completedBytes, 4)

    _ = await store.handle(ControlRequest(command: .operationCancel, operationID: operationID))
    let cancelledOperationID = await runner.cancelledOperationID
    XCTAssertEqual(cancelledOperationID, operationID)
}
```

另测 profile apply 与 model prepare 同时提交时，第二个请求得到 `.operationInProgress`；model catalog/status 只读请求不占用 mutation slot。

- [ ] **Step 2: 运行 AgentCore 测试确认接口尚不存在**

运行：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' -only-testing:SpeechRailAppTests/SpeechRailMacControlTests test
```

预期：失败在 runner progress、model command 或 store 分支不存在。

- [ ] **Step 3: 增加固定 model command arguments 和 CLI decoder**

`ManagedCommand.arguments(appHome:)` 使用固定参数：

```text
model catalog --app-home /private/speechrail-app-home --json
model status --app-home /private/speechrail-app-home --json
model prepare balanced --yes --app-home /private/speechrail-app-home --json
```

`CLIEnvelope` 增加 `event`、`prepared_id`、`artifacts`、`disk` 和 `profiles` 字段；单独增加 `CLIProgressEnvelope`。decoder 对每行验证 `schema_version == 1`、`command` 与当前 command 匹配、`event` 为 `progress` 或 `result`，拒绝未知 final result、负 bytes、`completed_bytes > expected_bytes` 和 profile/artifact 无法解析的输出。原有 stderr collector 继续限长和 path/secret redaction。

- [ ] **Step 4: 实现 Process JSONL 读取和受控 cancel**

将 stdout 改为逐行消费，stderr 继续并行 drain，避免模型下载期间 pipe 填满；每个合法 progress line 调用 `ManagedCommandProgressHandler`，回调只提交 actor 更新任务，不阻塞 pipe reader。新增受线程安全保护的 process registry，key 为 operation ID；`ProcessManagedCommandRunner.cancel(operationID:)` 只向已登记的该 process 发送 `SIGTERM`。

Python CLI 收到 SIGTERM 后通过 cancel event 退出到现有 model_store cleanup；如果原子 publish 已进入不可中断的 commit point，Agent 等待 final result，并以真实 `committed` 或 `failed` 为准，不抢先伪造 `cancelled`。operation cancel 的最终状态只能来自 result 或明确的 process termination failure。

- [ ] **Step 5: 泛化 AgentOperationStore**

保留 `activeMutation` 单槽和现有 profile apply operation；新增 `acceptModelPrepare()`：生成由 `control_` 前缀和去掉连字符的 UUID 组成的 operation ID，写入 `accepted`，用 `.modelPrepare(profile, operationID:)` 启动后台 Task，并把 progress 事件映射为：

```text
cache_hit / download / retry → downloading
verifying                    → verifying
publishing                   → publishing
result=committed             → committed
result=cancelled             → cancelled
result=failed                → failed
```

`operationCancel` 只允许取消 `.modelPrepare`；profile apply 返回 `unsupported` 并说明提交后不能取消。取消请求发送后保持 operation 为 `running` 或 `cancelling` 的可读阶段，直到 managed process 返回终态；不得清空 active mutation 造成第二个下载并行。

- [ ] **Step 6: 运行 AgentCore 全量定向测试**

运行：

```bash
scripts/macos_app_test.sh
```

预期：旧服务/profile runner 测试、模型 JSONL progress、错误脱敏、mutation 串行和 cancel 测试通过；没有真实 managed runtime 或模型下载。

- [ ] **Step 7: 提交 Agent operation 链路**

```bash
git add macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift macos/SpeechRailApp/SpeechRailControlAgent/main.swift macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift
git commit -m "feat: stream SpeechRail model operations"
```

### Task 5: 实现 health/metrics typed decoder 和 60 点采样器

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift:4-65`
- Create: `macos/SpeechRailApp/SpeechRailApp/RuntimeMetricsSampler.swift`
- Create: `macos/SpeechRailApp/SpeechRailMacControlTests/ServicePayloadTests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- 新增协议：

```swift
public protocol ServiceDiagnosticsClient: Sendable {
    func fetchHealthDetails() async throws -> HealthSnapshot
    func fetchMetrics() async throws -> RuntimeMetricsSnapshot
}
```

- `ServiceAPIClient` 实现该协议，并保留 `fetchHealth() async throws -> ServiceSnapshot` 兼容方法；兼容方法的 `ready` 直接使用服务返回的 `ready`，不重新用 ASR/TTS 做 AND 推导。
- `RuntimeMetricsSample` 固定为：

```swift
public struct RuntimeMetricsSample: Equatable, Sendable {
    public let capturedAt: Date
    public let metrics: RuntimeMetricsSnapshot
    public let httpRequestsPerSecond: Double?
    public let asrInferenceAverage: Double?
    public let ttsInferenceAverage: Double?
    public let ttsTTFAverage: Double?
    public let queueRejectionsTotal: Double?
}
```

- `RuntimeMetricsSampler.sample(previous:current:capturedAt:) -> RuntimeMetricsSample` 在 counter 回退或时间间隔非正时返回 nil rate；histogram 平均值按所有低基数 label series 的 `sum/count` 计算；`RuntimeMetricsSampler.append(_:to:) -> [RuntimeMetricsSample]` 最多保留 60 点。

- [ ] **Step 1: 写 decoder 和 sampler 失败测试**

在 `ServicePayloadTests.swift` 顶部加入下面的 URLProtocol 和 metrics fixture；它们只在内存中响应，不建立网络连接：

```swift
private final class StubURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: ServiceAPIClientError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClientReturning(_ body: String) -> ServiceAPIClient {
    StubURLProtocol.responseData = Data(body.utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return ServiceAPIClient(session: URLSession(configuration: configuration))
}

private func makeMetrics(
    counters: [String: Double],
    histogramCount: Int,
    histogramSum: Double
) -> RuntimeMetricsSnapshot {
    RuntimeMetricsSnapshot(
        activeRequests: RuntimeRequestCounts(realtime: 0, batch: 0),
        pendingRequests: RuntimeRequestCounts(realtime: 0, batch: 0),
        workers: [:],
        health: [:],
        counters: counters,
        gauges: [:],
        histograms: [
            "speechrail_asr_inference_duration_seconds": [
                "": RuntimeHistogramSummary(
                    count: histogramCount,
                    sum: histogramSum,
                    average: histogramCount == 0 ? 0 : histogramSum / Double(histogramCount)
                )
            ]
        ],
        capturedAt: Date(timeIntervalSince1970: 100)
    )
}
```

在 `ServicePayloadTests.swift` 使用 `URLProtocol` fake response，验证完整 `/health` payload：

```swift
func testHealthUsesServerReadyAndKeepsOptionalReadiness() async throws {
    let client = makeClientReturning("""
    {
      "status":"running",
      "service":"speechrail",
      "profile":"balanced",
      "asr_ready":true,
      "tts_ready":false,
      "ready":true,
      "asr_state":"active",
      "tts_state":"cold_evicted",
      "unknown_field":"ignored"
    }
    """)

    let health = try await client.fetchHealthDetails()

    XCTAssertEqual(health.ready, true)
    XCTAssertEqual(health.asrReady, true)
    XCTAssertEqual(health.ttsReady, false)
    XCTAssertEqual(health.ttsState, "cold_evicted")
}
```

再测试：

```swift
func testCounterRateAndHistogramAverageNeedValidSamples() throws {
    let first = makeMetrics(counters: ["speechrail_http_requests_total": 10], histogramCount: 2, histogramSum: 1)
    let second = makeMetrics(counters: ["speechrail_http_requests_total": 16], histogramCount: 4, histogramSum: 3)
    let sample = RuntimeMetricsSampler.sample(
        previous: first,
        current: second,
        capturedAt: second.capturedAt.addingTimeInterval(5)
    )

    XCTAssertEqual(try XCTUnwrap(sample.httpRequestsPerSecond), 1.2, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(sample.asrInferenceAverage), 0.75, accuracy: 0.001)
}
```

- [ ] **Step 2: 运行测试确认 decoder/sampler 尚不存在**

运行：

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' -only-testing:SpeechRailAppTests/SpeechRailMacControlTests test
```

预期：失败在 `fetchHealthDetails`、`RuntimeMetricsSampler` 或新 typed payload 不存在。

- [ ] **Step 3: 实现 ServiceAPIClient typed decoding**

health decoder 覆盖当前 `/health` 已发布的 `status`、`service`、`version`、`backend`、`profile`、`asr_ready`、`tts_ready`、`tts_warm`、`diarization_ready`、`diarization`、`asr_state`、`tts_state`、`streaming_state`、`realtime_vad`、`ready` 和 `job_spool_ready`。使用显式 `CodingKeys` 映射 snake_case；未知字段默认忽略；已知字段类型错误抛出 `ServiceAPIClientError.decodingFailed`，不把原始解码异常放入 UI。

metrics 请求必须设置 `Accept: application/json`，解码 `active_requests`、`pending_requests`、`workers`、`health`、`counters`、`gauges`、`histograms`；histogram 的 wire key `avg` 映射到 `average`。每次成功 metrics response 用当前 `Date` 生成 `capturedAt`；服务返回缺失对象时抛出解码错误而不是创建空零值。

- [ ] **Step 4: 实现 RuntimeMetricsSampler**

计数器聚合允许 exact key 或带 label suffix 的 key：例如 `speechrail_http_requests_total` 与 `speechrail_http_requests_total{status="200"}`；只对当前值不小于前值、时间间隔大于零的 counter 计算 delta/time。histogram 将同一 metric 下所有 series 的 count/sum 相加；count 为零时 average 为 nil。`append(_:to:)` 只保留最后 60 个样本，顺序保持从旧到新。

不得在 sampler 中把不可用值转为 0；View 根据 Optional 决定显示“暂无数据”“等待采样”或隐藏对应摘要。

- [ ] **Step 5: 运行 decoder/sampler 测试**

运行：

```bash
scripts/macos_app_test.sh
```

预期：完整/旧版本缺字段/未知字段/已知类型错误、server ready 语义、counter 回退、样本不足、histogram 平均值和 60 点上限测试通过。

- [ ] **Step 6: 提交诊断数据层**

```bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift macos/SpeechRailApp/SpeechRailApp/RuntimeMetricsSampler.swift macos/SpeechRailApp/SpeechRailMacControlTests/ServicePayloadTests.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj
git commit -m "feat: add typed SpeechRail diagnostics"
```

### Task 6: 扩展 AppModel 的服务、模型和监控生命周期

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift:5-113`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift:5-115`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift:4-31`
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `AppModel` initializer 接受 `apiClient: any ServiceDiagnosticsClient`，保留现有 `transport`、`registration` 参数和 `refresh()`/`execute()` 兼容入口。
- 新增公开状态：

```swift
public private(set) var health: HealthSnapshot?
public private(set) var metrics: RuntimeMetricsSnapshot?
public private(set) var modelCatalog: ModelCatalogSnapshot?
public private(set) var modelStatus: ModelStatusSnapshot?
public private(set) var preflightChecks: [PreflightCheckSnapshot] = []
public private(set) var monitoringSamples: [RuntimeMetricsSample] = []
public private(set) var lastHealthRefresh: Date?
public private(set) var lastMetricsRefresh: Date?
public private(set) var refreshError: String?
```

- 新增 `refreshOverview() async`、`refreshModels() async`、`refreshMetrics() async`、`startMonitoring()`、`stopMonitoring()`、`prepareModels(for:) async`、`runPreflight() async` 和 `cancel(operationID:) async`。

- [ ] **Step 1: 写 AppModel 状态和 fake diagnostics 失败测试**

在 UI test fake 中提供固定、可解释的 payload：`quality/balanced/light` 三档 catalog；`balanced` 当前 profile；health 为 `asrReady=true`、`ttsReady=false`、`ready=true`；metrics 首次为空样本，第二次返回 active/pending 和一个 worker。加入 UI test 对“ASR 可用但 TTS 尚未准备”的断言，确保不会把 server ready 错误显示为完整能力正常。

- [ ] **Step 2: 运行 UI test 确认 fake diagnostics 尚未接入**

运行：

```bash
scripts/macos_app_test.sh
```

预期：服务页仍只能看到旧 `ServiceSnapshot`，模型/metrics 状态为空或不存在。

- [ ] **Step 3: 实现 refresh 分层和错误保留**

`refreshOverview()` 并行读取 health 和现有 XPC profile/service snapshot；成功时写入 `health`、兼容 `service`、`lastHealthRefresh`，失败时写 `refreshError` 为可读短消息并把 service state 标为 `unavailable`，不把已有 metrics/model snapshot 伪造为空。`refreshModels()` 分别请求 `modelCatalog`、`modelStatus`、profile list/status；某次 command 返回 `.unsupported` 时模型状态为 unknown 语义并保留错误，不猜测未下载。

`refresh()` 调用 overview 与 models，不调用 metrics；总览手动刷新和菜单栏刷新都复用它。

- [ ] **Step 4: 实现 operation polling、model prepare 和 monitoring task**

将现有 `waitForOperation()` 抽成可复用路径：收到 progress 时更新 `operation`；收到 terminal `.committed/.failed/.cancelled` 时停止轮询并保留 message/error code。`prepareModels(for:)` 发送带 confirmation 的 `.modelPrepare`，等待 operation，同时不修改 `profile` 或 active service snapshot；终态后调用 `refreshModels()`。

`runPreflight()` 发送 `.preflight`，将 response.checks 写入 `preflightChecks`，并把失败的 error code/message 放进 `refreshError`；它不触发 model catalog、model status 或 model prepare。

`startMonitoring()` 只创建一个可取消 Task：立即执行一次 `refreshMetrics()`，之后每 5 秒执行一次；`stopMonitoring()` cancel task 并清空 task 引用。每次 metrics 成功使用 `RuntimeMetricsSampler.sample` 和 `append`，失败只更新 `refreshError` 与最近成功时间，不清空可信样本。所有轮询在 `@MainActor` 更新状态，View 不创建 URLSession、Process 或 XPC 连接。

- [ ] **Step 5: 运行 AppModel/UI fake 测试**

运行：

```bash
scripts/macos_app_test.sh
```

预期：partial readiness、model prepare operation 阶段、download 不改变 active profile、metrics 失败保留最近样本、start/stop monitoring 不重叠等测试通过。

- [ ] **Step 6: 提交 AppModel 生命周期**

```bash
git add macos/SpeechRailApp/SpeechRailApp/AppModel.swift macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat: connect SpeechRail service state"
```

### Task 7: 实现总览、运行监控、模型管理和预检诊断页面

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Create: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Delete: `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `ControlCenterView` 的 `.overview`、`.monitoring`、`.models`、`.diagnostics` 分别渲染四个真实页面；不再使用 `ServiceRoutePreviewView`。
- `ServiceOverviewView`、`RuntimeMonitoringView`、`ModelManagementView`、`PreflightDiagnosticsView` 均从 `@Environment(AppModel.self)` 读取状态，从 `@Environment(AppNavigationState.self)` 发起页面跳转。
- 所有服务 mutation 在 View 内显示 `confirmationDialog`，模型下载确认文案必须明确“只下载、不启动/重启、不切换 profile、不删除已有模型、不上传音频或作品”。

- [ ] **Step 1: 写四个服务页面的 UI 失败测试**

```swift
func testModelManagementShowsSeparateDownloadAndApplyActions() {
    let app = launchSpeechRail()
    openControlCenter(app)
    app.buttons["app-route-models"].click()

    XCTAssertTrue(app.staticTexts["模型管理"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["准备 SpeechRail 需要的本地语音能力"].exists)
    XCTAssertTrue(app.buttons["下载并校验"].exists)
    XCTAssertTrue(app.buttons["应用此档位"].exists)
    XCTAssertFalse(app.buttons["删除模型"].exists)
}

func testMonitoringShowsEmptyStateWithoutInventedTrend() {
    let app = launchSpeechRail()
    openControlCenter(app)
    app.buttons["app-route-monitoring"].click()

    XCTAssertTrue(app.staticTexts["等待采样"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["0.00 秒"].exists)
}
```

再覆盖 health partial readiness、下载确认 sheet、operation phase、预检失败和“当前 profile 保持不变”。

- [ ] **Step 2: 运行 UI test 确认真实服务页面尚不存在**

运行：

```bash
scripts/macos_app_test.sh
```

预期：失败在模型管理/监控真实文案或按钮不存在。

- [ ] **Step 3: 实现 ServiceOverviewView**

页面顶部使用 `SurfaceHeaderView`：

```text
总览
让 SpeechRail 在这台 Mac 上准备好
管理本机语音服务、能力档位和运行状态。
下一步：查看服务健康脉冲，确认是否可以开始创作。
```

服务健康脉冲显示 `health.ready` 的服务事实、`health.profile`/兼容 profile、version 和能力矩阵。ASR、TTS、streaming、diarization、realtime VAD 逐项显示 ready、lifecycle state 和 message；`ready=true` 不能替代能力矩阵，`asr_ready=true`/`tts_ready=false` 必须展示“部分能力可用”。技术详情使用 `DisclosureGroup` 展示安全字段和 operation phase。

启动、停止、重启、profile 应用和 profile rollback 均先出现确认对话框；确认内容写清对正在处理请求、已下载模型和作品的影响。profile 应用继续调用 `.profileApply`，回退调用现有 `.profileRollback`，模型页的“下载并校验”不调用这两个 command。control agent 未注册、未批准或 transport 不可用时，页面显示 Login Items & Extensions 的恢复指引，不把按钮错误解释成服务故障。

页面结构保持在 AppModel 之上，服务 mutation 只从确认后的 action closure 发出：

```swift
public struct ServiceOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingMutation: ServiceMutation?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SurfaceHeaderView(
                    title: "总览",
                    purpose: "让 SpeechRail 在这台 Mac 上准备好。",
                    nextAction: "查看服务健康脉冲，确认是否可以开始创作。"
                )
                GroupBox("服务健康脉冲") {
                    LabeledContent("状态", value: model.health?.status ?? "暂时无法读取")
                    LabeledContent("当前档位", value: model.health?.profile?.rawValue ?? "未配置")
                    LabeledContent("服务 ready", value: model.health?.ready == true ? "是" : "否或未知")
                }
                HStack {
                    Button("启动") { pendingMutation = .start }
                    Button("停止") { pendingMutation = .stop }
                    Button("重启") { pendingMutation = .restart }
                }
                ServiceStatusView()
                ProfilePickerView()
            }
            .padding(32)
        }
        .confirmationDialog(
            pendingMutation?.title ?? "确认服务操作",
            isPresented: Binding(
                get: { pendingMutation != nil },
                set: { if !$0 { pendingMutation = nil } }
            ),
            presenting: pendingMutation
        ) { mutation in
            Button(mutation.confirmTitle, role: mutation.isStop ? .destructive : nil) {
                pendingMutation = nil
                Task { await model.execute(mutation.command) }
            }
            Button("取消", role: .cancel) { pendingMutation = nil }
        } message: { mutation in
            Text(mutation.message)
        }
    }
}

private enum ServiceMutation: String, Identifiable {
    case start, stop, restart

    var id: String { rawValue }
    var command: ControlCommand { ControlCommand(rawValue: rawValue)! }
    var title: String { "确认\(rawValue)服务" }
    var confirmTitle: String { "确认\(rawValue)" }
    var isStop: Bool { self == .stop }
    var message: String { "该操作可能让正在处理的请求等待或重新开始；不会删除模型或作品。" }
}
```

- [ ] **Step 4: 实现 RuntimeMonitoringView**

页面显示：服务整体状态；realtime/batch active 与 pending；queue rejection counter；每个 worker 的 lifecycle state；HTTP request 累计、ASR/TTS inference average、TTS TTFA average 和 realtime active sessions。worker 状态允许 `active`、`warm_standby`、`cold_evicted`、`inactive`、`unconfigured`，未知值用“未知状态”并保留技术字段。

使用 Swift Charts 展示 `monitoringSamples` 中有足够数据的 rate/latency 曲线；样本少于 2 点时显示 `ContentUnavailableView("等待采样", systemImage: "chart.xyaxis.line")`。页面 `.task`/`.onAppear` 启动采样，`.onDisappear` 停止采样；刷新按钮不能创建第二个 task。endpoint 失败显示“暂时无法读取”和最近成功时间，不把失败转成零。

监控页面的采样生命周期使用结构化 task：

```swift
public struct RuntimeMonitoringView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SurfaceHeaderView(
                    title: "运行监控",
                    purpose: "确认本机语音服务最近是否稳定。",
                    nextAction: "先看服务负载和能力状态，再展开技术详情。"
                )
                RuntimeLoadSummary(metrics: model.metrics)
                WorkerStateSummary(metrics: model.metrics)
                if model.monitoringSamples.count < 2 {
                    ContentUnavailableView("等待采样", systemImage: "chart.xyaxis.line")
                } else {
                    RuntimeTrendChart(samples: model.monitoringSamples)
                }
            }
            .padding(32)
        }
        .task {
            model.startMonitoring()
            await Task.yield()
        }
        .onDisappear {
            model.stopMonitoring()
        }
    }
}
```

`RuntimeLoadSummary`、`WorkerStateSummary` 和 `RuntimeTrendChart` 在同一个新文件中定义为纯展示 View，输入分别为 `RuntimeMetricsSnapshot?`、`RuntimeMetricsSnapshot?` 和 `[RuntimeMetricsSample]`；它们不发请求，不自行存储样本。

- [ ] **Step 5: 实现 ModelManagementView**

顶部显示 `modelBytes`、`freeBytes`；主体按 profile 展示 `quality`、`balanced`、`light`，每个 profile 下列出 ASR、TTS、optional clone、aligner 和 `diarization-coreml`。artifact 行展示用途、family/variant、量化、估算总容量、file count、provider/repository 简化名、revision 短标识和本机状态。

本机状态映射为 `notDownloaded`、`downloading`、`verified`、`invalid`、`unknown`。`verified` 只表示当前 catalog/revision/hash 完整，不标记为“当前正在使用”；使用状态另读 `health.profile`。当前 operation 的目标 artifact 显示 `downloading`，但没有可靠 bytes 时不显示百分比。

“下载并校验”确认对话框至少包含：用途、所选 profile、artifact 数量/估算容量、可用空间、来源简化名，以及“不启动/重启服务、不切换 profile、不删除已有模型、不上传音频或作品”。确认后调用 `prepareModels(for:)`；operation 显示 `accepted → downloading → verifying → publishing → committed/failed/cancelled`。下载失败显示磁盘不足、来源不可用或完整性错误的可读恢复动作。页面不提供删除按钮。

模型页用 catalog 驱动行内容，不以 `SpeechRailProfile` 或 artifact key 写死容量：

```swift
public struct ModelManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var isDownloadConfirmationPresented = false
    @State private var isProfileConfirmationPresented = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SurfaceHeaderView(
                    title: "模型管理",
                    purpose: "准备 SpeechRail 需要的本地语音能力。",
                    nextAction: "选择一个档位，查看制品状态后决定只下载还是应用。"
                )
                ModelDiskSummary(disk: model.modelStatus?.disk)
                Picker("目标档位", selection: $selectedProfile) {
                    ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                ProfileArtifactList(
                    profile: selectedProfile,
                    catalog: model.modelCatalog,
                    status: model.modelStatus,
                    activeProfile: model.health?.profile
                )
                HStack {
                    Button("下载并校验") { isDownloadConfirmationPresented = true }
                    Button("应用此档位") { isProfileConfirmationPresented = true }
                }
            }
            .padding(32)
        }
        .confirmationDialog(
            "准备 \(selectedProfile.rawValue) 模型",
            isPresented: $isDownloadConfirmationPresented
        ) {
            Button("开始下载") {
                Task { await model.prepareModels(for: selectedProfile) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只下载并校验，不启动或重启服务，不切换 profile，不删除已有模型，也不上传音频或作品。")
        }
        .confirmationDialog(
            "应用 \(selectedProfile.rawValue) 档位",
            isPresented: $isProfileConfirmationPresented
        ) {
            Button("检查并应用") {
                Task { await model.execute(.profileApply, profile: selectedProfile) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会执行 profile 切换和 public API smoke；正在处理的请求可能等待或重新开始，已下载模型和作品不会被删除。")
        }
        .task { await model.refreshModels() }
    }
}
```

`RuntimeLoadSummary(metrics:)`、`WorkerStateSummary(metrics:)`、`RuntimeTrendChart(samples:)`、`ProfileArtifactList(profile:catalog:status:activeProfile:)` 和 `ModelDiskSummary(disk:)` 都定义在对应页面文件中，参数只接收 typed snapshot；它们不创建副作用。`ProfileArtifactList` 用 `catalog.artifacts.filter { $0.requiredBy.contains(profile) }` 取得行，使用 `status.artifacts.first(where: { $0.key == artifact.key })` 取得状态，缺少任一项时显示“暂时无法读取”。

- [ ] **Step 6: 实现 PreflightDiagnosticsView**

执行 `.preflight` 前显示其用途：“检查受管 runtime、服务配置和能力准备，不会下载模型或改变当前 profile。”结果按 `PreflightCheckSnapshot` 列表写入 `AppModel.preflightChecks`，显示 ok/失败图标、文字和恢复动作；技术详情只显示安全检查名、error code、profile、readiness 和 operation，不展示日志路径。失败时提供“重试预检”“打开模型管理”“启动服务/重启服务”的页面动作。

```swift
public struct PreflightDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SurfaceHeaderView(
                title: "预检与诊断",
                purpose: "定位服务、runtime 和能力准备问题。",
                nextAction: "先运行预检；失败时按检查项给出的恢复动作处理。"
            )
            Button("运行预检") { Task { await model.runPreflight() } }
            ForEach(model.preflightChecks, id: \.name) { check in
                LabeledContent(check.name, value: check.ok ? "通过" : check.message)
            }
            Button("打开模型管理") { navigation.request(.models) }
        }
        .padding(32)
    }
}
```

- [ ] **Step 7: 更新 ControlCenterView、旧组件和 target membership**

把 service route switch 替换为四个页面；删除 `ServiceRoutePreviewView.swift` 及其 PBX file reference/build file；`ServiceStatusView` 改为总览可复用的简化状态组件，`ProfilePickerView` 保留 profile 选择并复用总览确认文案。新文件加入 App group 和 App Sources，不改 ControlKit/Agent 的 embed 规则。

- [ ] **Step 8: 运行四页 UI test**

运行：

```bash
scripts/macos_app_test.sh
```

预期：普通用户可从每页说明功能定位、当前状态和下一步；开发者展开技术详情可看到 health/metrics/operation/catalog 证据；下载确认与 profile apply 确认互不混淆。

- [ ] **Step 9: 提交服务页面**

```bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat: add SpeechRail service console"
```

### Task 8: 完善 fake 覆盖、用户/开发者文档并执行完整 gate

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift:60-115`
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Modify: `docs/developers/macos-app-development.md`
- Modify: `docs/users/README.md`
- Modify: `docs/design/README.md`（仅在计划链接或服务模块入口仍缺失时更新）

**Interfaces:**
- `UITestControlTransport` 对 `modelCatalog`、`modelStatus`、`modelPrepare`、`operationStatus` 返回确定性 response；fake 进度必须经过与生产相同的 `OperationSnapshot.progress` 形状。
- `UITestServiceDiagnosticsClient` 实现 `ServiceDiagnosticsClient`，不打开 loopback、不访问模型源、不写磁盘。
- 用户文档解释“下载并校验”不等于“应用 profile”，监控指标不等于语音质量评分；开发者文档解释 XPC/CLI/API 边界和兼容失败行为。

- [ ] **Step 1: 增加 fake model/diagnostics 场景**

在 `App.swift` 中根据现有 `--ui-test` 参数注入 fake diagnostics；增加可选参数 `--ui-test-model-failure` 和 `--ui-test-metrics-unavailable`。fake model prepare 返回 accepted operation，并在 operation status 中依次返回 downloading/verifying/committed 或 failed；失败 fixture 的 message 只使用 `model preparation failed` 等 path-free 文案。

- [ ] **Step 2: 补齐 UI acceptance tests**

覆盖以下场景：

1. 控制中心显示四个 service route 和四个 creator route；
2. health partial readiness 明确显示影响范围；
3. 模型管理显示三档、容量、来源简化名和状态；
4. “下载并校验”确认明确只下载，确认后显示 operation phase；
5. 下载失败后 active profile 和服务状态不变，并显示重试/预检；
6. 运行监控显示 active/pending、worker 和等待采样空状态；
7. metrics 暂时不可用时保留最近成功时间，不显示零趋势；
8. 预检失败可以跳转模型管理或重试；
9. 菜单栏可以打开控制中心和音色创作；
10. Settings 没有服务启停、profile apply、模型下载按钮。

- [ ] **Step 3: 更新 project/test target 和文档**

确认 `ServicePayloadTests.swift`、新页面和 ControlKit types 均进入正确 target；文档写明以下开发命令：

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

`docs/users/README.md` 只描述普通用户可见的用途、确认和恢复；`docs/developers/macos-app-development.md` 描述 typed health/metrics、XPC model operation、JSONL progress、单 mutation 和 fake 测试。不得把真实 app home、模型目录、token、API key 或下载原始数据写入文档。

- [ ] **Step 4: 执行 macOS 验证**

运行：

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

预期：Debug 构建、unit/UI tests 和 plist lint 全部通过；Distribution 验证仍拒绝 local XPC service，符合当前发布边界。

- [ ] **Step 5: 执行 Python 与契约 gate**

运行：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

预期：全量 Python 测试、ruff、mypy、OpenAPI lint 和 diff check 通过。由于本计划不新增 HTTP endpoint，OpenAPI 应保持不需要新增管理路径；如果已有 `/health`/`/metrics` 契约与实测不一致，先报告差异，不通过 App 侧猜测修复。

- [ ] **Step 6: 执行安全和兼容性检查**

运行：

```bash
rtk rg -n "api[_-]?key|Authorization|token|password|/Users/|models/.staging|model prepare" macos/SpeechRailApp src/speechrail tests docs/users docs/developers
```

人工核对：UI fixture 不含凭据/原始音频/完整转写/绝对模型路径；model command 不接受任意 URL；旧 profile/service machine output 测试仍通过；旧 Agent/CLI 缺少新字段时 UI 显示 unsupported/unknown 而不是正常。

- [ ] **Step 7: 提交服务模块验收文档和测试**

```bash
git add macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj docs/developers/macos-app-development.md docs/users/README.md docs/design/README.md
git commit -m "docs: finish SpeechRail service module"
```

## 5. 最终验收矩阵

| 能力 | 普通用户可回答 | 开发者可核对 | 不应发生 |
|---|---|---|---|
| 总览 | 现在能不能开始创作、下一步做什么 | `ready`、profile、各 capability readiness 和最近 operation | 把 `ready` 误当成所有能力 ready |
| 运行监控 | 服务是否稳定、是否繁忙 | active/pending、worker state、counter/histogram、采样时间 | 缺失值变成 0、指标被解释成质量评分 |
| 模型管理 | 模型用途、预计空间、下载是否安全 | catalog key、family/variant、revision、provider、文件计数和校验状态 | 打开页面自动下载、任意 URL、误删模型 |
| 下载 operation | 当前阶段、是否可重试、是否影响服务 | JSONL phase、bytes、error code、publish state | 下载自动切换 profile、失败覆盖旧快照 |
| 预检诊断 | 失败原因和恢复动作 | check name、safe message、readiness、runtime 状态 | 显示完整日志路径或 secret |
| 音色创作 | 创作入口仍在产品一级区域 | 服务依赖状态可跳转模型管理 | 管理控制台替换或清空音色/作品 |

只有所有矩阵项和 Task 8 gate 同时满足，才可把设计规格从“已批准”推进为实现完成；真实下载验收仍必须单独记录目标 profile、来源、磁盘和网络影响，不把模型、runtime、日志或原始下载数据提交到仓库。

## 6. 回退与交接

- App 页面或 decoder 回退只恢复 App release，不覆盖 managed Python runtime、模型目录、profile journal 或 LaunchAgent。
- 模型准备失败或取消只影响该次 staging/operation；既有 verified snapshot 和当前 active profile 保持不变。
- 新增 `model.catalog/status/prepare` 是 helper/CLI 能力；旧 helper 不认识新 command 时，App 显示 `unsupported`，不猜测模型状态、不触发 profile apply。
- `operationCancel` 只有模型准备支持安全终止；profile apply 的既有不可取消语义保持不变。
