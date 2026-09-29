# 外部模型位置绑定（oMLX / SpeechRail 共用）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 SpeechRail 支持把指定 catalog 制品的权重放在 operator 自选的外部目录（本机用途：由 `~/.omlx/models/` 统一管理 3 个 bf16 TTS + 1 个 bf16 ASR），未绑定的制品与所有默认值行为完全不变。

**Architecture:** 新增 app home 级配置 `config/model_locations.json`，把 `artifact_key → 外部根目录` 声明为一条显式绑定。路径解析统一走 `resolve_artifact_dir(app_home, key, locations)`：有绑定用绑定根，无绑定回落 `app_home/models/<key>`。模型库对绑定制品改为**只读外部**语义——不下载、不删除、不计入托管库磁盘占用，完整性仍按 catalog 清单校验；托管库继续保持"零软链"安全策略不变。

**Tech Stack:** Python 3.14（`>=3.14,<3.15`）、`uv`、PEP 621、pydantic v2、pytest；macOS 26+ / Apple silicon。

**Spec:** 本计划实现 2026-09-29 与用户确认的方案 B；行为基线来自 `docs/superpowers/specs/2026-09-24-model-store-closed-loop.md`（模型库闭环不变量）与 `docs/decisions/0015-tier-user-positioning-and-precision-policy.md`（档位与制品身份）。oMLX 侧能力已实测：`model_discovery.py` 自动识别 `qwen3_tts` / `qwen3_asr`，`engine/tts.py` 通用支持 Base/CustomVoice/VoiceDesign，`engine/stt.py:976` 支持 `qwen3_asr`。

## Global Constraints

- 默认行为必须逐字节不变：未出现在 `model_locations.json` 的制品，其解析路径、准备流程、状态判定、磁盘统计与今天完全一致。
- 托管模型库 `app_home/models` 保持**零软链**策略：`_validate_model_store_paths()`（`model_store.py:1202`）对根软链、目录软链、文件软链一律 `ModelStoreError`，本计划不得放宽该策略；外部位置必须是真实目录。
- 外部绑定是**只读**的：SpeechRail 不得向外部目录写入、下载、替换或删除任何文件。
- 状态与 CLI JSON 输出不得泄露绝对路径（沿用 `PreparedArtifactStatus` 的 path-free 契约，`model_store.py:58`）。
- 不保留旧行为兼容层；但持久化注册表 `state/model-preparations.json` 的 7 字段条目属于既有数据格式，读取时必须继续接受（缺省按 `app_home` 解析），这是数据迁移必需而非兼容 alias。
- 契约、测试、文档同步更新；破坏性变更需在交付报告说明影响范围与回退方式（删除 `config/model_locations.json` 即回滚）。
- 持久化文档中的路径示例使用 `~/...` 形式，不写本机绝对路径；命令使用可移植原生命令。
- 本计划涉及的运行态动作（迁移权重目录、重启 oMLX/SpeechRail）只在 Task 7 执行，且需要用户当次明确授权。

## Review Focus

以下五类输入/失败模式在任何任务的自测里都必须被覆盖，最可能咬人的排在前面：

1. **绑定根目录不存在或被移动** — `model status` 报 `invalid`、`profile apply`/启动失败并给出可执行提示，而不是静默回落下载或报成 `not_downloaded`。
2. **绑定制品同时存在托管副本** — 必须 fail-closed 报 `invalid` + `duplicate=true`，绝不能"两个都能用"而让用户不知道该保留哪个。
3. **绑定路径非法**（相对路径、软链、位于 `app_home/models` 或 `app_home/diarization` 内部、含 `.staging`）— 加载即拒绝并指出具体字段，不接受"先跑起来再说"。
4. **绑定 key 不在当前 catalog** — 配置写错 key 时必须报错，而不是静默忽略导致用户以为绑定生效了。
5. **旧 7 字段 prepared 注册表条目** — 迁移后仍按 `app_home` 解析并可验证通过，不得因为新增字段把现有制品全判成 `invalid`。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `src/speechrail/config/model_locations.py`（新建） | 绑定配置的数据模型、加载、路径校验与 `resolve_artifact_dir()` 解析入口。只做配置与路径，不碰下载与状态机。 |
| `src/speechrail/config/selection.py`（改） | 选档解析时按绑定解析每个角色的目录，产出 `Settings` 里的 4 个绝对路径。 |
| `src/speechrail/service/model_store.py`（改） | 状态巡检支持外部只读制品；准备流程对绑定制品 fail-closed；新增 `location` / `duplicate` 字段。 |
| `src/speechrail/service/model_commands.py`（改） | `model status` 汇报外部位置与外部占用；`model prepare` 透传绑定。 |
| `src/speechrail/service/managed_install.py`（改） | `.env` 渲染改用解析后的目录；绑定缺失时安装器提前失败。 |
| `src/speechrail/service/preflight.py` / `src/speechrail/cli.py`（改） | 两个 `resolve_selection()` 调用点加载并传入绑定。 |
| `tests/test_model_locations.py`（新建） | 配置模型、校验规则、解析回落。 |
| `tests/test_spec_selection.py`、`tests/test_model_store.py`、`tests/test_model_commands.py`、`tests/test_installer.py`（改） | 各任务的行为回归。 |

---

### Task 1: 绑定配置模型与路径解析

**Files:**
- Create: `src/speechrail/config/model_locations.py`
- Test: `tests/test_model_locations.py`

**Interfaces:**
- Consumes: 无
- Produces:
  - `MODEL_LOCATIONS_FILENAME: str = "model_locations.json"`
  - `class ModelLocationError(ValueError)`
  - `@dataclass(frozen=True, slots=True) class ModelLocations`：`bindings: Mapping[str, Path]`（键为 artifact key，值为已 `expanduser()` 的绝对根目录）；方法 `root_for(key: str) -> Path | None`
  - `load_model_locations(app_home: Path) -> ModelLocations`（文件缺失返回空绑定）
  - `resolve_artifact_dir(app_home: Path, key: str, locations: ModelLocations | None) -> Path`（无绑定时返回未 resolve 的 `app_home/"models"/key`，由调用方沿用现有 `_require_directory()` 解析）

- [ ] **Step 1: 写失败测试**

```python
# tests/test_model_locations.py
from __future__ import annotations

import json
from pathlib import Path

import pytest

from speechrail.config.model_locations import (
    ModelLocationError,
    load_model_locations,
    resolve_artifact_dir,
)


def _write(app_home: Path, payload: dict[str, object]) -> None:
    config = app_home / "config"
    config.mkdir(parents=True, exist_ok=True)
    (config / "model_locations.json").write_text(
        json.dumps(payload), encoding="utf-8"
    )


def test_missing_file_yields_no_bindings(tmp_path: Path) -> None:
    assert load_model_locations(tmp_path).bindings == {}


def test_binding_resolves_to_external_root(tmp_path: Path) -> None:
    external = tmp_path / "omlx" / "mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16"
    external.mkdir(parents=True)
    _write(tmp_path, {"schema_version": 1, "bindings": {"tts-1.7b-base-bf16": str(external)}})

    locations = load_model_locations(tmp_path)

    assert locations.root_for("tts-1.7b-base-bf16") == external
    assert resolve_artifact_dir(tmp_path, "tts-1.7b-base-bf16", locations) == external


def test_unbound_artifact_keeps_managed_default(tmp_path: Path) -> None:
    resolved = resolve_artifact_dir(tmp_path, "tts-1.7b-custom-q8", None)
    assert resolved == tmp_path / "models" / "tts-1.7b-custom-q8"


@pytest.mark.parametrize(
    "root",
    [
        "relative/dir",
        "~/nowhere",
    ],
)
def test_relative_or_missing_root_is_rejected(tmp_path: Path, root: str) -> None:
    _write(tmp_path, {"schema_version": 1, "bindings": {"asr-1.7b-bf16": root}})
    with pytest.raises(ModelLocationError):
        load_model_locations(tmp_path)


def test_root_inside_managed_store_is_rejected(tmp_path: Path) -> None:
    _write(
        tmp_path,
        {"schema_version": 1, "bindings": {"asr-1.7b-bf16": str(tmp_path / "models" / "asr-1.7b-bf16")}},
    )
    with pytest.raises(ModelLocationError):
        load_model_locations(tmp_path)


def test_symlink_root_is_rejected(tmp_path: Path) -> None:
    real = tmp_path / "elsewhere"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real)
    _write(tmp_path, {"schema_version": 1, "bindings": {"asr-1.7b-bf16": str(link)}})
    with pytest.raises(ModelLocationError):
        load_model_locations(tmp_path)


def test_unknown_schema_version_is_rejected(tmp_path: Path) -> None:
    _write(tmp_path, {"schema_version": 99, "bindings": {}})
    with pytest.raises(ModelLocationError):
        load_model_locations(tmp_path)
```

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run pytest tests/test_model_locations.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'speechrail.config.model_locations'`

- [ ] **Step 3: 写最小实现**

```python
# src/speechrail/config/model_locations.py
"""Operator-owned external model roots for selected catalog artifacts."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

MODEL_LOCATIONS_FILENAME = "model_locations.json"
_SCHEMA_VERSION = 1
_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_MANAGED_SUBDIRS = ("models", "diarization")


class ModelLocationError(ValueError):
    """A declared model location is unusable."""


@dataclass(frozen=True, slots=True)
class ModelLocations:
    """Read-only map from artifact key to an external snapshot root."""

    bindings: Mapping[str, Path]

    def root_for(self, key: str) -> Path | None:
        """Return the declared external root for one artifact key."""
        return self.bindings.get(key)


def _reject(message: str) -> None:
    raise ModelLocationError(f"model location config invalid: {message}")


def _validate_root(app_home: Path, raw: object, key: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        _reject(f"{key} must be a non-empty path string")
    assert isinstance(raw, str)
    if not Path(raw).is_absolute():
        _reject(f"{key} must be an absolute path: {raw}")
    root = Path(raw).expanduser()
    if not root.exists() or not root.is_dir():
        _reject(f"{key} external root is missing: {root}")
    if root.is_symlink():
        _reject(f"{key} external root must not be a symlink: {root}")
    if ".staging" in root.parts:
        _reject(f"{key} external root must not be a staging directory")
    managed = app_home.resolve() / "models"
    try:
        root.resolve().relative_to(managed)
    except ValueError:
        pass
    else:
        _reject(f"{key} external root must live outside the managed model store")
    for name in _MANAGED_SUBDIRS:
        if root.name == name and root.parent == app_home.resolve():
            _reject(f"{key} external root must not be an app-home managed directory")
    return root


def load_model_locations(app_home: Path) -> ModelLocations:
    """Load `config/model_locations.json`; an absent file means no bindings."""
    path = app_home / "config" / MODEL_LOCATIONS_FILENAME
    if not path.is_file():
        return ModelLocations(bindings={})
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        _reject(f"{path.name} is unreadable: {exc}")
    if not isinstance(payload, Mapping):
        _reject("payload must be an object")
    if payload.get("schema_version") != _SCHEMA_VERSION:
        _reject(f"unsupported schema_version {payload.get('schema_version')!r}")
    raw_bindings = payload.get("bindings", {})
    if not isinstance(raw_bindings, Mapping):
        _reject("bindings must be an object")
    resolved: dict[str, Path] = {}
    for key, raw in raw_bindings.items():
        if not isinstance(key, str) or not _KEY_RE.match(key):
            _reject(f"invalid artifact key {key!r}")
        resolved[key] = _validate_root(app_home, raw, key)
    return ModelLocations(bindings=MappingProxyType(resolved))


def resolve_artifact_dir(
    app_home: Path, key: str, locations: ModelLocations | None
) -> Path:
    """Return the directory holding one artifact: external binding or managed default."""
    if locations is not None:
        bound = locations.root_for(key)
        if bound is not None:
            return bound
    return app_home / "models" / key


__all__ = [
    "MODEL_LOCATIONS_FILENAME",
    "ModelLocationError",
    "ModelLocations",
    "load_model_locations",
    "resolve_artifact_dir",
]
```

实现时补上 `from types import MappingProxyType` 导入，并为 `test_symlink_root_is_rejected` 确认 `Path.is_symlink()` 在 `expanduser()` 之后仍然为真（`~` 已在前面被拒绝，此处路径已是绝对路径）。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run pytest tests/test_model_locations.py -q`
Expected: PASS（8 passed）

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/config/model_locations.py tests/test_model_locations.py
git commit -m "feat: declare operator-owned external model roots"
```

---

### Task 2: 选档解析使用绑定目录

**Files:**
- Modify: `src/speechrail/config/selection.py:143-165`（`_require_directory` / `_optional_directory` 保持不变）、`:168-250`（`resolve_selection`）
- Modify: `src/speechrail/cli.py:69`、`src/speechrail/service/preflight.py:341`（调用点）
- Test: `tests/test_spec_selection.py`

**Interfaces:**
- Consumes: Task 1 的 `load_model_locations()`、`resolve_artifact_dir()`、`ModelLocations`
- Produces: `resolve_selection(settings, selection, catalog, app_home, *, runtime_lock=None, locations: ModelLocations | None = None) -> Settings`（新增关键字参数，默认 `None` = 纯旧行为）

- [ ] **Step 1: 写失败测试**

```python
# append to tests/test_spec_selection.py
def test_bound_artifact_directory_is_used(tmp_path: Path) -> None:
    external = tmp_path / "omlx" / "Qwen3-ASR-1.7B-bf16"
    external.mkdir(parents=True)
    (external / "config.json").write_text("{}", encoding="utf-8")
    _write_locations(tmp_path, {"asr-1.7b-bf16": external})

    settings = _resolved_settings(tmp_path, spec="reference")

    assert settings["qwen3_model_dir"] == external.resolve()


def test_binding_key_absent_from_catalog_is_rejected(tmp_path: Path) -> None:
    external = tmp_path / "omlx" / "whatever"
    external.mkdir(parents=True)
    _write_locations(tmp_path, {"tts-9.9b-imaginary": external})

    with pytest.raises(ModelLocationError, match="unknown artifact key"):
        _resolved_settings(tmp_path, spec="reference")
```

其中 `_write_locations()` 写 `config/model_locations.json`（`{"schema_version": 1, "bindings": {...}}`），`_resolved_settings()` 复用文件内既有的“按 spec 解析 Settings”辅助函数（若无，参照 `tests/test_spec_selection.py` 现有 fixture 写法新建）。

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run pytest tests/test_spec_selection.py -q -k bound_artifact`
Expected: FAIL — 断言得到 `app_home/models/asr-1.7b-bf16` 而非外部目录

- [ ] **Step 3: 写最小实现**

在 `selection.py` 中：

```python
from speechrail.config.model_locations import (
    ModelLocationError,
    ModelLocations,
    resolve_artifact_dir,
)


def resolve_selection(
    settings: Settings,
    selection: Mapping[str, object] | None,
    catalog: ModelCatalog,
    app_home: Path,
    *,
    runtime_lock: RuntimeLock | None = None,
    locations: ModelLocations | None = None,
) -> Settings:
    """Overlay one v2 selection while preserving unrelated user configuration."""
    # ...（既有参数校验保持不变）
    if locations is not None:
        known = {artifact.key for artifact in catalog.artifacts}
        unknown = sorted(set(locations.bindings) - known)
        if unknown:
            raise ModelLocationError(
                f"model location config references unknown artifact keys: {unknown}"
            )
    models_dir = (resolved_app_home / "models").resolve()
    asr_dir = _require_directory(
        resolve_artifact_dir(resolved_app_home, asr.key, locations), label="ASR model"
    )
    tts_dir = _require_directory(
        resolve_artifact_dir(resolved_app_home, tts.key, locations), label="TTS model"
    )
    clone_dir = (
        _require_directory(
            resolve_artifact_dir(resolved_app_home, tts_base.key, locations),
            label="TTS clone model",
        )
        if tts_base is not None
        else None
    )
    design_dir = (
        _optional_directory(
            resolve_artifact_dir(resolved_app_home, voice_design.key, locations)
        )
        if voice_design is not None
        else None
    )
```

`models_dir` 变量若在函数内不再被其它逻辑使用则一并删除（先确认引用点）。

两个调用点改为：

```python
# src/speechrail/cli.py:69 与 src/speechrail/service/preflight.py:341 同形
settings = resolve_selection(
    settings,
    selection,
    load_catalog(),
    layout.app_home,
    locations=load_model_locations(layout.app_home),
)
```

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run pytest tests/test_spec_selection.py tests/test_profile_selection.py -q`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/config/selection.py src/speechrail/cli.py src/speechrail/service/preflight.py tests/test_spec_selection.py
git commit -m "feat: resolve selection model dirs through external bindings"
```

---

### Task 3: 模型库把外部制品当作只读

**Files:**
- Modify: `src/speechrail/service/model_store.py:58-66`（`PreparedArtifactStatus`）、`:670-750`（`inspect_prepared_artifacts`）、`:993-1019`（`_strict_prepared_path` 保持不变）、`:786-800`（`covered` 计算）、`prepare_spec_models()` 所在函数
- Test: `tests/test_model_store.py`

**Interfaces:**
- Consumes: Task 1 的 `ModelLocations`、`resolve_artifact_dir()`
- Produces:
  - `PreparedArtifactStatus` 新增字段 `location: Literal["app_home", "external"] = "app_home"`、`duplicate: bool = False`
  - `inspect_prepared_artifacts(app_home, *, catalog=None, runtime_lock=None, locations: ModelLocations | None = None) -> tuple[PreparedArtifactStatus, ...]`
  - `prepare_spec_models(..., locations: ModelLocations | None = None)`：绑定制品不下载，目录缺失或存在托管副本时抛 `ModelStoreError`

- [ ] **Step 1: 写失败测试**

```python
# append to tests/test_model_store.py
def test_external_binding_reports_verified_without_prepared_entry(tmp_path: Path) -> None:
    external = _seed_external_artifact(tmp_path, "tts-1.7b-base-bf16")
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": external})

    (status,) = _status_for(tmp_path, "tts-1.7b-base-bf16")

    assert status.state == "verified"
    assert status.location == "external"
    assert status.duplicate is False


def test_external_binding_with_managed_copy_is_invalid(tmp_path: Path) -> None:
    external = _seed_external_artifact(tmp_path, "tts-1.7b-base-bf16")
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": external})
    _seed_managed_artifact(tmp_path, "tts-1.7b-base-bf16")

    (status,) = _status_for(tmp_path, "tts-1.7b-base-bf16")

    assert (status.state, status.duplicate) == ("invalid", True)


def test_missing_external_root_is_invalid_not_not_downloaded(tmp_path: Path) -> None:
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": tmp_path / "omlx" / "gone"})

    (status,) = _status_for(tmp_path, "tts-1.7b-base-bf16")

    assert status.state == "invalid"


def test_legacy_seven_field_entry_still_resolves(tmp_path: Path) -> None:
    _seed_managed_artifact(tmp_path, "tts-1.7b-base-bf16")
    _write_legacy_prepared_entry(tmp_path, "tts-1.7b-base-bf16")

    (status,) = _status_for(tmp_path, "tts-1.7b-base-bf16")

    assert status.state == "verified"
    assert status.location == "app_home"
```

`_seed_external_artifact()` 按 catalog 中该制品的 `files` 清单写入占位权重并使哈希匹配；`_write_legacy_prepared_entry()` 写不含 `location` 字段的既有 7 字段结构。辅助函数沿用文件内既有 fixture 风格。

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run pytest tests/test_model_store.py -q -k "external or legacy_seven"`
Expected: FAIL — 外部绑定场景当前仍按托管目录判定为 `not_downloaded`；`PreparedArtifactStatus` 无 `location` 字段

- [ ] **Step 3: 写最小实现**

1) `PreparedArtifactStatus`：

```python
ModelLocation = Literal["app_home", "external"]


@dataclass(frozen=True, slots=True)
class PreparedArtifactStatus:
    """Path-free integrity state for one catalog artifact."""

    key: str
    state: ModelState
    integrity: ModelIntegrity
    verified_file_count: int
    total_file_count: int
    location: ModelLocation = "app_home"
    duplicate: bool = False
```

2) `inspect_prepared_artifacts()` 签名加 `locations`，循环内把

```python
        destination = models_root / artifact.key
```

替换为

```python
        bound_root = locations.root_for(artifact.key) if locations is not None else None
        managed_destination = models_root / artifact.key
        destination = bound_root if bound_root is not None else managed_destination
        duplicate = (
            bound_root is not None
            and (managed_destination.exists() or managed_destination.is_symlink())
        )
```

并把状态判定改为：绑定制品不看 prepared 证据，`state = "verified" if integrity == "verified" and not duplicate else "invalid"`；`duplicate` 为真时 `integrity` 记为 `mismatch`。绑定目录不存在时 `_artifact_integrity` 返回 `mismatch`/`not_checked`，落到 `invalid` 分支。

3) `prepare_spec_models()` 增加 `locations` 关键字参数；对每个被选中且已绑定的制品：

```python
        if bound_root is not None:
            if (models_root / artifact.key).exists():
                raise ModelStoreError(
                    f"{artifact.key} is bound to an external location but a managed "
 f"copy still exists at {models_root / artifact.key}"
                )
            if not bound_root.is_dir():
                raise ModelStoreError(
                    f"{artifact.key} external model directory is missing: {bound_root}"
                )
            integrity, _ = _artifact_integrity(bound_root, artifact, persistent_cache=None)
            if integrity != "verified":
                raise ModelStoreError(
                    f"{artifact.key} external model directory failed integrity: {bound_root}"
                )
            continue
```

4) `covered` 计算（`:786` 附近）保持跳过软链的现状；外部制品本就不在 `models_root` 下，天然不参与，无需改动。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run pytest tests/test_model_store.py -q`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/service/model_store.py tests/test_model_store.py
git commit -m "feat: inspect and prepare externally bound artifacts as read-only"
```

---

### Task 4: `model status` / `model prepare` 面向用户的表述

**Files:**
- Modify: `src/speechrail/service/model_commands.py:151-243`（`_model_bytes` / `model_status_payload`）、`:245-282`（`prepare_selected_models`）
- Test: `tests/test_model_commands.py`

**Interfaces:**
- Consumes: Task 3 的 `PreparedArtifactStatus.location/duplicate` 与 `prepare_spec_models(locations=...)`
- Produces:
  - `model_status_payload(app_home, *, catalog=None, runtime_lock=None, disk_usage=None, locations: ModelLocations | None = None) -> dict[str, object]`，新增顶层 `external_bytes: int`，每个 artifact 行新增 `location`、`duplicate`
  - `prepare_selected_models(..., locations: ModelLocations | None = None)`

- [ ] **Step 1: 写失败测试**

```python
# append to tests/test_model_commands.py
def test_status_reports_external_location_and_bytes(tmp_path: Path) -> None:
    external = _seed_external_artifact(tmp_path, "tts-1.7b-base-bf16")
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": external})

    payload = model_status_payload(tmp_path, locations=load_model_locations(tmp_path))

    row = next(r for r in payload["artifacts"] if r["key"] == "tts-1.7b-base-bf16")
    assert row["location"] == "external"
    assert row["duplicate"] is False
    assert payload["external_bytes"] > 0
    assert "external_root" not in json.dumps(payload)  # 状态负载不得泄露绝对路径


def test_status_never_counts_external_bytes_into_managed_store(tmp_path: Path) -> None:
    external = _seed_external_artifact(tmp_path, "tts-1.7b-base-bf16")
    _write_locations(tmp_path, {"tts-1.7b-base-bf16": external})

    payload = model_status_payload(tmp_path, locations=load_model_locations(tmp_path))

    assert payload["model_bytes"] == 0
    assert payload["external_bytes"] == sum(
        f.stat().st_size for f in external.rglob("*") if f.is_file()
    )
```

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run pytest tests/test_model_commands.py -q -k external`
Expected: FAIL — `KeyError: 'external_bytes'`

- [ ] **Step 3: 写最小实现**

```python
def _external_bytes(locations: ModelLocations | None) -> int:
    """Sum real-directory bytes behind external bindings without following symlinks."""
    if locations is None:
        return 0
    total = 0
    for root in locations.bindings.values():
        if root.is_symlink() or not root.is_dir():
            continue
        for current, directories, files in os.walk(root, followlinks=False):
            current_path = Path(current)
            directories[:] = [
                name for name in directories if not (current_path / name).is_symlink()
            ]
            for name in files:
                path = current_path / name
                if path.is_symlink():
                    continue
                try:
                    total += path.stat().st_size
                except OSError:
                    continue
    return total
```

在 `model_status_payload()` 中把 `inspect_prepared_artifacts(...)` 的结果映射为行时补 `location` / `duplicate`，并在返回 dict 中加入 `"external_bytes": _external_bytes(locations)`；`model_bytes` 仍由 `_model_bytes(models_root)` 计算，语义不变。`prepare_selected_models()` 增加 `locations` 关键字参数并透传给 `prepare_spec_models()`。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run pytest tests/test_model_commands.py -q`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/service/model_commands.py tests/test_model_commands.py
git commit -m "feat: surface external model locations in model status"
```

---

### Task 5: 安装器按解析后的目录渲染 `.env`

**Files:**
- Modify: `src/speechrail/service/managed_install.py:236-265`（`_render_env`）、`:442-460`（`_prepare_models_for_install`）、`:600-620`（安装主流程调用点）
- Test: `tests/test_installer.py`

**Interfaces:**
- Consumes: Task 1 `resolve_artifact_dir()` / `load_model_locations()`；Task 3 `prepare_spec_models(locations=...)`
- Produces: `_render_env(*, layout, asr_dir: Path, tts_dir: Path, runtime_lock, vendor_python, vendor_ffmpeg, host, port, diarization_assets=None) -> str`（`asr_dir` / `tts_dir` 由调用方解析后传入，函数内不再拼 `models_root`）

- [ ] **Step 1: 写失败测试**

```python
# append to tests/test_installer.py
def test_env_uses_bound_external_dirs(tmp_path: Path) -> None:
    asr_external = _seed_external_artifact(tmp_path, "asr-1.7b-bf16")
    tts_external = _seed_external_artifact(tmp_path, "tts-1.7b-custom-bf16")
    _write_locations(
        tmp_path,
        {"asr-1.7b-bf16": asr_external, "tts-1.7b-custom-bf16": tts_external},
    )

    env_text = _render_env_for_install(tmp_path, asr_spec="reference", tts_spec="reference")

    assert f"SPEECHRAIL_QWEN3_MODEL_DIR={asr_external}" in env_text
    assert f"SPEECHRAIL_QWEN3_TTS_MODEL_DIR={tts_external}" in env_text


def test_install_fails_when_bound_root_missing(tmp_path: Path) -> None:
    _write_locations(tmp_path, {"asr-1.7b-bf16": tmp_path / "omlx" / "absent"})

    with pytest.raises(InstallerError, match="external model directory"):
        _install_plan(tmp_path, asr_spec="reference", tts_spec="reference")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `uv run pytest tests/test_installer.py -q -k "bound or external"`
Expected: FAIL — `.env` 仍写托管目录

- [ ] **Step 3: 写最小实现**

`_render_env()` 改为接收已解析目录：

```python
    lines: tuple[str, ...] = (
        f"SPEECHRAIL_HOST={host}",
        f"SPEECHRAIL_PORT={port}",
        f"SPEECHRAIL_QWEN3_MODEL_DIR={asr_dir}",
        f"SPEECHRAIL_QWEN3_TTS_MODEL_DIR={tts_dir}",
        f"SPEECHRAIL_QWEN3_PYTHON={vendor_python}",
        f"SPEECHRAIL_QWEN3_TTS_PYTHON={vendor_python}",
        f"SPEECHRAIL_FFMPEG_PATH={vendor_ffmpeg}",
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false",
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false",
    )
```

安装主流程在渲染前加载绑定并解析目录，缺失即 fail-closed：

```python
    locations = load_model_locations(layout.app_home)
    asr_dir = resolve_artifact_dir(layout.app_home, asr_key, locations)
    tts_dir = resolve_artifact_dir(layout.app_home, tts_key, locations)
    for label, directory in (("ASR", asr_dir), ("TTS", tts_dir)):
        if not directory.is_dir():
            raise InstallerError(
                f"{label} external model directory is missing: {directory}"
            )
```

`_prepare_models_for_install()` 把 `locations=locations` 传给 `prepare_spec_models()`。

- [ ] **Step 4: 运行测试确认通过**

Run: `uv run pytest tests/test_installer.py tests/test_cli_install.py -q`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add src/speechrail/service/managed_install.py tests/test_installer.py
git commit -m "feat: render managed env from resolved model directories"
```

---

### Task 6: 文档与契约同步

**Files:**
- Modify: `docs/operations/runtime-deployment.md:57`（`app_home/models/<artifact_key>` 表述）、`:106` 起的环境变量表、同文档新增"外部模型位置绑定"小节
- Modify: `docs/operations/operations-runbook.md`（新增排查条目：绑定缺失、绑定与托管副本并存）
- Modify: `contracts/openapi.yaml` — 仅当实现改变了 `/v1/models` 或诊断响应字段才修改；按 Task 1-5 的设计，HTTP 契约**不变**（`PreparedArtifactStatus` 不出现在 `/v1/models`），此步只需确认并记录"无契约变更"
- Test: 无（文档任务，随 Task 1-5 的测试一起验证）

**Interfaces:**
- Consumes: Task 1-5 的最终行为
- Produces: 无代码接口

- [ ] **Step 1: 更新部署文档**

在 `docs/operations/runtime-deployment.md` 把

```markdown
`app_home/models/<artifact_key>`；`voice_design` 与 aligner 不在准备集合内
```

改为说明默认仍是 `app_home/models/<artifact_key>`，并追加：

```markdown
### 外部模型位置绑定

`config/model_locations.json` 可以把指定 `artifact_key` 的权重声明到 operator 自选的
外部目录（例如由 oMLX 统一管理的 `~/.omlx/models/<leaf>`）。规则：

- 未声明的制品行为完全不变，仍由 SpeechRail 下载、校验与清理；
- 声明后的制品**只读**：SpeechRail 不下载、不删除、不写入，也不计入托管库磁盘占用；
- 外部根必须是绝对路径下的真实目录，不能是软链，不能位于 `app_home/models`、
  `app_home/diarization` 或任何 `.staging` 路径内；
- 外部制品的完整性仍按 catalog 的 `files` 清单逐文件哈希校验；
- 同一 key 同时存在外部绑定与托管副本时，状态判为 `invalid`（`duplicate=true`），
  需人工删除托管副本；
- 删除 `config/model_locations.json` 即完全回滚到默认行为。
```

- [ ] **Step 2: 更新运维排障表**

在 `docs/operations/operations-runbook.md` 的故障表增加两行：

```markdown
| 启动报 `external model directory is missing` | 绑定目录被移动或删除 | 恢复目录，或删除 `config/model_locations.json` 回滚 |
| `model status` 报 `invalid` 且 `duplicate=true` | 同一制品同时存在外部绑定与托管副本 | 删除 `app_home/models/<artifact_key>` 托管副本 |
```

- [ ] **Step 3: 确认契约无变更**

Run: `rg -n "PreparedArtifactStatus|model_status" contracts/openapi.yaml` → 预期无命中；同时 `uv run pytest tests/test_model_commands.py -q -k "no_path or json"` 通过，证明状态负载不含绝对路径。

- [ ] **Step 4: 提交**

```bash
git add docs/operations/runtime-deployment.md docs/operations/operations-runbook.md
git commit -m "docs: document external model location bindings"
```

---

### Task 7: 本机落地（运行态，需当次明确授权后执行）

**Files:**
- 本机数据，不进仓库：`~/Library/Application Support/SpeechRail/config/model_locations.json`
- 本机数据：`~/.omlx/models/` 下的 4 个 bf16 制品目录
- 文档：`/Users/hrygo/Documents/本机优化配置/docs/models/oMLX最佳实践.md`、`/Users/hrygo/Documents/本机优化配置/docs/system/本机环境与模型配置.md`

**Interfaces:**
- Consumes: Task 1-6 的代码与文档
- Produces: 本机共享模型布局

> 本任务会移动约 17.7G 权重目录、触发 oMLX 与 SpeechRail 的模型重新加载，并改变本机 oMLX 客户端可见的模型列表。执行前必须取得用户当次明确授权；每步失败即停止并保持现状。

- [ ] **Step 1: 迁移前核对（只读）**

对 4 个制品逐个比对 `app_home/models/<key>` 与目标 oMLX 目录名下的文件清单、每文件尺寸、`config.json` 归一化 JSON 与 `model.safetensors.index.json` 哈希；任一不一致即停止。

- [ ] **Step 2: 移动权重**

```bash
mv "$HOME/Library/Application Support/SpeechRail/models/tts-1.7b-base-bf16" \
   "$HOME/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16"
mv "$HOME/Library/Application Support/SpeechRail/models/tts-1.7b-custom-bf16" \
   "$HOME/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
mv "$HOME/Library/Application Support/SpeechRail/models/tts-1.7b-design-bf16" \
   "$HOME/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
mv "$HOME/Library/Application Support/SpeechRail/models/asr-1.7b-bf16" \
   "$HOME/.omlx/models/mlx-community--Qwen3-ASR-1.7B-bf16"
```

移动后立刻确认 oMLX 未在 HF 缓存留下同 ID 副本（`~/.cache/huggingface/hub/models--mlx-community--Qwen3-TTS-*`、`models--mlx-community--Qwen3-ASR-1.7B-bf16`），避免 `get_effective_model_dirs()` 的"HF 缓存优先"规则造成同 ID 遮蔽。

- [ ] **Step 3: 写绑定配置**

`~/Library/Application Support/SpeechRail/config/model_locations.json`：

```json
{
  "schema_version": 1,
  "bindings": {
    "asr-1.7b-bf16": "/Users/hrygo/.omlx/models/mlx-community--Qwen3-ASR-1.7B-bf16",
    "tts-1.7b-base-bf16": "/Users/hrygo/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16",
    "tts-1.7b-custom-bf16": "/Users/hrygo/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16",
    "tts-1.7b-design-bf16": "/Users/hrygo/.omlx/models/mlx-community--Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
  }
}
```

- [ ] **Step 4: 验证 oMLX 侧**

`GET /v1/models` 应新增 4 条且 `engine_type` 分别为 `audio_tts`（3 条）与 `audio_stt`（1 条）；对 3 个 TTS 变体各做一次 `POST /v1/audio/speech` 合成、对 ASR 做一次 `POST /v1/audio/transcriptions` 转写。若 `engine_type` 不符预期，在 `~/.omlx/model_settings.json` 对应条目补 `model_type_override`（`audio_tts` / `audio_stt`）后重测。

- [ ] **Step 5: 验证 SpeechRail 侧**

```bash
uv run speechrail model status --app-home "$HOME/Library/Application Support/SpeechRail" --json
uv run speechrail profile apply --asr-spec reference --tts-spec reference --yes
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8201/readyz
curl -s http://127.0.0.1:8201/v1/models | jq '.data[].id'
```

预期：4 个绑定制品 `state=verified` 且 `location=external`；`/readyz` 200；`/v1/models` 暴露 reference 档的 ASR/TTS 身份。随后跑一次真实 TTS→ASR 冒烟。

- [ ] **Step 6: 复核 oMLX 客户端白名单**

`/v1/models` 从 9 条增至 13 条，按本机 SSOT 规则复核 CLIProxyAPI、OpenCode/OMO、QwenPaw 的显式白名单不需要为音频模型新增条目（它们不应把音频模型当对话目标）。

- [ ] **Step 7: 更新本机 SSOT**

在 `oMLX最佳实践.md` 的模型清单中补 4 行音频模型并注明"与 SpeechRail 共用，权重由 SpeechRail 绑定引用，oMLX 只读加载"；在 `本机环境与模型配置.md` §5.2 把"oMLX 不管理音频模型"改为"oMLX 与 SpeechRail 共用同一份 bf16 音频权重，绑定文件为 `~/Library/Application Support/SpeechRail/config/model_locations.json`"，并更新两处核验日期。

- [ ] **Step 8: 提交（仅仓库内文档）**

本机 SSOT 位于另一个目录，不在本仓库；本任务不产生仓库提交。

---

## Self-Review

**Spec 覆盖**：目标 1/2（3 个 bf16 TTS + 1 个 bf16 ASR 由 oMLX 目录管理并可用）→ Task 7 Step 2/4；目标 3（SpeechRail 支持指定目录、默认不变）→ Task 1/2/3/4/5；目标 4（共用且不影响其他用户）→ Task 3 的只读语义 + Task 7 Step 6 的白名单复核。

**占位符扫描**：无 TBD/TODO；每个代码步骤都给出可粘贴的代码与命令。

**类型一致性**：`ModelLocations.root_for()` 在 Task 1/2/3/4 中签名一致；`resolve_artifact_dir(app_home, key, locations)` 参数顺序在所有任务一致；`PreparedArtifactStatus.location/duplicate` 在 Task 3 定义、Task 4 消费；`prepare_spec_models(..., locations=...)` 在 Task 3 定义、Task 5 调用。

**Review Focus 覆盖**：1→Task 3 `test_missing_external_root_is_invalid_not_not_downloaded` + Task 5 `test_install_fails_when_bound_root_missing`；2→Task 3 `test_external_binding_with_managed_copy_is_invalid`；3→Task 1 的参数化校验测试（相对路径/软链/托管库内部）；4→Task 2 `test_binding_key_absent_from_catalog_is_rejected`（`resolve_selection` 对 bindings 与 catalog 做键交叉校验）；5→Task 3 `test_legacy_seven_field_entry_still_resolves`。
