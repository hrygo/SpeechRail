"""离线模型目录与 runtime lock 数据结构。"""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Mapping
from functools import lru_cache
from pathlib import Path, PurePosixPath, PureWindowsPath
from types import MappingProxyType
from typing import Literal, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictInt,
    StrictStr,
    field_validator,
    model_validator,
)

Family = Literal["qwen3_asr", "qwen3_tts", "qwen3_forced_aligner"]
Variant = Literal["asr", "voice_design", "custom_voice", "base", "aligner"]
SpecTier = Literal["fast", "quality", "reference"]
ModelRole = Literal[
    "asr",
    "tts_base",
    "tts_custom_voice",
    "voice_design",
    "alignment",
    "diarization",
]
# 未量化制品的权重数值格式。有了它, 目录里的每一份权重都能在同一个维度上说清
# 精度: 量化制品用 `bits`, 未量化制品用 `dtype` (用户 2026-09-23)。
WeightDtype = Literal["bf16", "fp16", "fp32"]

# 目标三档与角色的唯一绑定表。缺失的制品绝不能由规格名字推断补齐。
REQUIRED_SPEC_BINDINGS: Mapping[tuple[SpecTier, ModelRole], str] = MappingProxyType(
    {
        ("fast", "asr"): "asr-0.6b-q8",
        ("quality", "asr"): "asr-1.7b-q8",
        ("reference", "asr"): "asr-1.7b-bf16",
        ("fast", "tts_base"): "tts-0.6b-base-q8",
        ("quality", "tts_base"): "tts-1.7b-base-q8",
        ("reference", "tts_base"): "tts-1.7b-base-bf16",
        ("fast", "tts_custom_voice"): "tts-0.6b-custom-q8",
        ("quality", "tts_custom_voice"): "tts-1.7b-custom-q8",
        ("reference", "tts_custom_voice"): "tts-1.7b-custom-bf16",
        ("reference", "voice_design"): "tts-1.7b-design-bf16",
        ("fast", "alignment"): "aligner-q8",
        ("quality", "alignment"): "aligner-bf16",
        ("reference", "alignment"): "aligner-bf16",
    }
)

_ROLE_VARIANTS: Mapping[ModelRole, tuple[Family, Variant]] = MappingProxyType(
    {
        "asr": ("qwen3_asr", "asr"),
        "tts_base": ("qwen3_tts", "base"),
        "tts_custom_voice": ("qwen3_tts", "custom_voice"),
        "voice_design": ("qwen3_tts", "voice_design"),
        "alignment": ("qwen3_forced_aligner", "aligner"),
    }
)

_SCHEMA_VERSION = 2
_REVISION_RE = re.compile(r"[0-9a-fA-F]{40}")
_SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")
_PINNED_REQUIREMENT_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]*==[A-Za-z0-9][A-Za-z0-9!+._~-]*"
    r"(?:\s+--hash=sha256:[0-9a-fA-F]{64})+$"
)
_ASSET_DIR = Path(__file__).resolve().parents[1] / "assets"
_CATALOG_PATH = _ASSET_DIR / "model-catalog.json"
_RUNTIME_LOCK_PATH = _ASSET_DIR / "runtime-lock.json"


def _relative_path(value: str, *, field_name: str) -> str:
    """规范化并校验相对路径。"""
    if not value or "\x00" in value:
        raise ValueError(f"{field_name} must be a safe relative path")

    posix = PurePosixPath(value.replace("\\", "/"))
    windows = PureWindowsPath(value)
    if (
        posix.is_absolute()
        or windows.is_absolute()
        or windows.drive
        or any(part == ".." for part in posix.parts)
    ):
        raise ValueError(f"{field_name} contains an absolute or traversal path")

    parts = tuple(part for part in posix.parts if part not in {"", "."})
    if not parts:
        raise ValueError(f"{field_name} must name a file")
    return "/".join(parts)


def _artifact_key(value: str) -> str:
    if (
        value in {".", ".."}
        or "/" in value
        or "\\" in value
        or "\x00" in value
        or PureWindowsPath(value).drive
    ):
        raise ValueError("key must be a safe artifact key")
    return value


def _revision(value: str, *, field_name: str = "revision") -> str:
    if _REVISION_RE.fullmatch(value) is None:
        raise ValueError(f"{field_name} must be a 40-character hexadecimal revision")
    return value.lower()


def _sha256(value: str, *, field_name: str = "sha256") -> str:
    if _SHA256_RE.fullmatch(value) is None:
        raise ValueError(f"{field_name} must be a 64-character hexadecimal hash")
    return value.lower()


def _is_codec_file(path: str) -> bool:
    lowered = path.lower()
    return lowered == "speech_tokenizer/config.json" or (
        lowered.startswith("speech_tokenizer/") and lowered.endswith(".safetensors")
    )


class ArtifactFile(BaseModel):
    """模型制品中的一个已校验文件。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    path: StrictStr = Field(min_length=1)
    size: StrictInt = Field(ge=0)
    sha256: StrictStr = Field(min_length=64, max_length=64)

    @field_validator("path")
    @classmethod
    def validate_path(cls, value: str) -> str:
        return _relative_path(value, field_name="path")

    @field_validator("sha256")
    @classmethod
    def validate_hash(cls, value: str) -> str:
        return _sha256(value)


class QuantizationSpec(BaseModel):
    """模型量化元数据。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    bits: StrictInt | None
    group_size: StrictInt | None
    format: StrictStr = Field(min_length=1)
    # 与 `bits` 互斥: 一个制品只用一个维度说精度。「未量化」本身不是精度,
    # 只有补上 dtype 之后, UI 才不必对同一列里的某一行说另一种话。
    dtype: WeightDtype | None = None

    @field_validator("bits", "group_size")
    @classmethod
    def validate_positive(cls, value: int | None) -> int | None:
        if value is not None and value <= 0:
            raise ValueError("quantization values must be positive or null")
        return value

    @model_validator(mode="after")
    def validate_precision_encoding(self) -> Self:
        if self.bits is not None and self.dtype is not None:
            raise ValueError("quantization must declare either bits or dtype, not both")
        if self.dtype is not None and (self.group_size is not None or self.format != "none"):
            raise ValueError("unquantized dtype requires group_size=null and format='none'")
        return self


class SourceLocation(BaseModel):
    """模型制品的不可变来源记录。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    provider: StrictStr = Field(min_length=1)
    repository: StrictStr = Field(min_length=1)
    revision: StrictStr = Field(min_length=40, max_length=40)

    @field_validator("revision")
    @classmethod
    def validate_revision(cls, value: str) -> str:
        return _revision(value)


class ModelArtifact(BaseModel):
    """一个带文件哈希和来源证明的模型制品。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    key: StrictStr = Field(min_length=1)
    model_id: StrictStr = Field(min_length=1)
    revision: StrictStr = Field(min_length=40, max_length=40)
    family: Family
    variant: Variant
    quantization: QuantizationSpec
    files: tuple[ArtifactFile, ...] = Field(min_length=1)
    sources: tuple[SourceLocation, ...] = Field(min_length=1)

    @field_validator("key")
    @classmethod
    def validate_key(cls, value: str) -> str:
        return _artifact_key(value)

    @field_validator("revision")
    @classmethod
    def validate_revision(cls, value: str) -> str:
        return _revision(value)

    @model_validator(mode="after")
    def validate_identity(self) -> Self:
        if self.family == "qwen3_asr" and self.variant != "asr":
            raise ValueError("qwen3_asr artifacts must use variant=asr")
        if self.family == "qwen3_tts" and self.variant == "asr":
            raise ValueError("qwen3_tts artifacts cannot use variant=asr")
        if self.family == "qwen3_forced_aligner" and self.variant != "aligner":
            raise ValueError("qwen3_forced_aligner artifacts must use variant=aligner")
        # 没有量化的制品也必须能回答「这份权重是多少位」: 只写「未量化」会让
        # 界面在同一列里对某一行说不出精度 (用户 2026-09-23)。
        if self.quantization.bits is None and self.quantization.dtype is None:
            raise ValueError("unquantized artifact must declare quantization.dtype")

        file_paths = tuple(file.path for file in self.files)
        if len(set(file_paths)) != len(file_paths):
            raise ValueError("artifact files must not contain duplicate paths")
        file_path_set = set(file_paths)
        if not {"config.json", "model.safetensors"}.issubset(file_path_set):
            raise ValueError("artifact is missing config.json or model.safetensors")
        split_tokenizer = {"tokenizer_config.json", "vocab.json", "merges.txt"}
        if not (split_tokenizer.issubset(file_path_set) or "tokenizer.json" in file_path_set):
            raise ValueError("artifact is missing tokenizer files")
        if self.family == "qwen3_tts" and not {
            "speech_tokenizer/config.json"
        }.issubset(file_path_set):
            raise ValueError("qwen3_tts artifact is missing codec configuration")
        if self.family == "qwen3_tts" and not any(
            _is_codec_file(path) and path.endswith(".safetensors") for path in file_paths
        ):
            raise ValueError("qwen3_tts artifact is missing codec weights")

        source_ids = tuple(
            (source.provider, source.repository, source.revision) for source in self.sources
        )
        if len(set(source_ids)) != len(source_ids):
            raise ValueError("artifact sources must not contain duplicates")
        if not any(source.revision == self.revision for source in self.sources):
            raise ValueError("artifact sources must include a canonical revision match")
        return self


class ModelSpecBinding(BaseModel):
    """一个档位与角色的显式制品绑定, 不做名字推断。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    tier: SpecTier
    role: ModelRole
    artifact_key: StrictStr = Field(min_length=1)


class EngineWheelPin(BaseModel):
    """受控引擎 wheel 的构建 provenance.

    目标架构不再向 site-packages 覆盖 vendor 源文件: 语音引擎只能以唯一 wheel
    交付, 且必须能由固定上游源码 + 补丁 + 构建输入重建. 这里记录 wheel 与重建
    输入的哈希; 未登记时为 ``None`` (尚未通过构建门), 此时 runtime 不安装任何
    overlay, 也不凭空声称 wheel 身份.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    filename: StrictStr = Field(min_length=1)
    sha256: StrictStr
    source_repository: StrictStr = Field(min_length=1)
    source_revision: StrictStr
    patch_sha256: StrictStr
    build_inputs_sha256: StrictStr

    @field_validator("sha256", "patch_sha256", "build_inputs_sha256")
    @classmethod
    def validate_hashes(cls, value: str) -> str:
        return _sha256(value)

    @field_validator("source_revision")
    @classmethod
    def validate_source_revision(cls, value: str) -> str:
        return _revision(value)

    @field_validator("filename")
    @classmethod
    def validate_filename(cls, value: str) -> str:
        if Path(value).name != value or not value.endswith(".whl"):
            raise ValueError("engine wheel filename must be a bare .whl name")
        return value


class RuntimeLock(BaseModel):
    """全档共享且带哈希依赖的 runtime 锁定清单。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: StrictStr = Field(min_length=1)
    python: StrictStr = Field(min_length=1)
    asr_requirements: tuple[StrictStr, ...] = Field(min_length=1)

    @field_validator("python")
    @classmethod
    def validate_python(cls, value: str) -> str:
        if re.fullmatch(r"3\.14\.\d+", value) is None:
            raise ValueError("runtime Python must be a 3.14.x release")
        return value
    tts_requirements: tuple[StrictStr, ...] = Field(min_length=1)
    ffmpeg_artifact: StrictStr = Field(min_length=1)
    file_hashes: Mapping[str, StrictStr] = Field(min_length=1)
    engine_wheel: EngineWheelPin | None = None

    @field_validator("asr_requirements", "tts_requirements")
    @classmethod
    def validate_requirements(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        for requirement in value:
            if _PINNED_REQUIREMENT_RE.fullmatch(requirement) is None:
                raise ValueError(
                    "runtime requirements must be package==version followed only by sha256 hashes"
                )
        return value

    @field_validator("file_hashes", mode="after")
    @classmethod
    def freeze_file_hashes(cls, value: Mapping[str, str]) -> Mapping[str, str]:
        normalized: dict[str, str] = {}
        for path, digest in value.items():
            normalized_path = _relative_path(path, field_name="file_hashes key")
            if normalized_path in normalized:
                raise ValueError("file_hashes contains duplicate normalized paths")
            normalized[normalized_path] = _sha256(digest, field_name="file_hashes value")
        return MappingProxyType(normalized)

def runtime_wheel_source(filename: str) -> Path:
    """Resolve the pinned engine wheel from the asset dir or the build checkout."""
    if Path(filename).name != filename or not filename.endswith(".whl"):
        raise ValueError("engine wheel filename must be a bare .whl name")
    asset_root = _ASSET_DIR / "vendor" / "engine" / "dist"
    source_root = _ASSET_DIR.parents[2] / "vendor" / "engine-build" / "dist"
    for root in (asset_root, source_root):
        if not root.is_dir():
            continue
        candidate = (root.resolve() / filename).resolve()
        try:
            candidate.relative_to(root.resolve())
        except ValueError as exc:
            raise ValueError("engine wheel path escapes its source root") from exc
        if candidate.is_file():
            return candidate
    raise ValueError(f"engine wheel asset is missing: {filename}")


class ModelCatalog(BaseModel):
    """完整不可变的模型目录。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: StrictInt
    artifacts: tuple[ModelArtifact, ...] = Field(min_length=1)
    specs: tuple[ModelSpecBinding, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_catalog(self) -> Self:
        if self.schema_version != _SCHEMA_VERSION:
            raise ValueError(f"schema_version must be {_SCHEMA_VERSION}")

        artifacts: dict[str, ModelArtifact] = {}
        for artifact in self.artifacts:
            if artifact.key in artifacts:
                raise ValueError(f"duplicate artifact key: {artifact.key}")
            artifacts[artifact.key] = artifact

        bindings: dict[tuple[SpecTier, ModelRole], str] = {}
        for binding in self.specs:
            key = (binding.tier, binding.role)
            if key in bindings:
                raise ValueError(f"duplicate spec binding: {binding.tier}/{binding.role}")
            bindings[key] = binding.artifact_key
        # The catalog is the source of truth for which artifact serves a
        # tier/role; the exact *target* matrix is enforced on load and by the
        # catalog builder so synthetic catalogs in tests stay usable.
        if set(bindings) != set(REQUIRED_SPEC_BINDINGS):
            missing = sorted(set(REQUIRED_SPEC_BINDINGS) - set(bindings))
            extra = sorted(set(bindings) - set(REQUIRED_SPEC_BINDINGS))
            raise ValueError(
                "catalog specs must cover the required matrix: "
                f"missing={missing} extra={extra}"
            )
        for (tier, role), artifact_key in bindings.items():
            bound_artifact = artifacts.get(artifact_key)
            if bound_artifact is None:
                raise ValueError(f"spec {tier}/{role} references unknown artifact")
            expected_family, expected_variant = _ROLE_VARIANTS[role]
            if (bound_artifact.family, bound_artifact.variant) != (
                expected_family,
                expected_variant,
            ):
                raise ValueError(f"spec {tier}/{role} references an incompatible artifact")

        return self

    def binding(self, tier: SpecTier, role: ModelRole) -> str:
        """按档位与角色返回显式制品 key。"""
        for item in self.specs:
            if item.tier == tier and item.role == role:
                return item.artifact_key
        raise KeyError(f"{tier}/{role}")

    def artifact_for(self, tier: SpecTier, role: ModelRole) -> ModelArtifact | None:
        """返回绑定的制品; 未绑定或缺失时返回 None, 绝不按名字推断。"""
        try:
            artifact_key = self.binding(tier, role)
        except KeyError:
            return None
        for artifact in self.artifacts:
            if artifact.key == artifact_key:
                return artifact
        return None


def _load_json(path: Path) -> Mapping[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not read asset JSON: {path.name}") from exc
    if not isinstance(payload, Mapping):
        raise ValueError(f"{path.name} must contain a JSON object")
    return payload


@lru_cache(maxsize=1)
def load_catalog() -> ModelCatalog:
    """读取并校验仓库内的模型目录。"""
    catalog = ModelCatalog.model_validate(_load_json(_CATALOG_PATH))
    assert_target_spec_bindings(catalog)
    return catalog


def assert_target_spec_bindings(catalog: ModelCatalog) -> None:
    """Reject a shipped catalog that does not bind the frozen target matrix.

    ``ModelCatalog`` keeps tier/role bindings data-driven so a synthetic
    catalog can be validated in isolation. The artifact file that ships with
    the service must still resolve every tier/role to the exact artifact the
    target architecture names, so that gate lives here.
    """

    mismatched = sorted(
        (tier, role)
        for (tier, role), expected_key in REQUIRED_SPEC_BINDINGS.items()
        if catalog.binding(tier, role) != expected_key
    )
    if mismatched:
        raise ValueError(
            "shipped catalog spec bindings must match the target matrix: "
            f"mismatched={mismatched}"
        )


def load_runtime_lock() -> RuntimeLock:
    """读取并校验全档共享 runtime lock。"""
    lock = RuntimeLock.model_validate(_load_json(_RUNTIME_LOCK_PATH))
    asset_root = _ASSET_DIR.resolve()
    for relative_path, expected_hash in lock.file_hashes.items():
        asset_path = (asset_root / relative_path).resolve()
        try:
            asset_path.relative_to(asset_root)
        except ValueError as exc:
            raise ValueError("runtime lock asset path escapes assets directory") from exc
        if not asset_path.is_file():
            raise ValueError(f"runtime lock asset is missing: {relative_path}")
        actual_hash = hashlib.sha256(asset_path.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            raise ValueError(f"runtime lock asset hash mismatch: {relative_path}")
    if lock.engine_wheel is not None:
        try:
            wheel_path = runtime_wheel_source(lock.engine_wheel.filename)
        except ValueError as exc:
            raise ValueError(
                f"engine wheel asset is missing: {lock.engine_wheel.filename}"
            ) from exc
        if hashlib.sha256(wheel_path.read_bytes()).hexdigest() != lock.engine_wheel.sha256:
            raise ValueError(f"engine wheel hash mismatch: {lock.engine_wheel.filename}")
    return lock


__all__ = [
    "REQUIRED_SPEC_BINDINGS",
    "ArtifactFile",
    "EngineWheelPin",
    "Family",
    "ModelArtifact",
    "ModelCatalog",
    "ModelSpecBinding",
    "QuantizationSpec",
    "RuntimeLock",
    "SourceLocation",
    "Variant",
    "assert_target_spec_bindings",
    "load_catalog",
    "load_runtime_lock",
    "runtime_wheel_source",
]
