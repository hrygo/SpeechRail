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
    StrictBool,
    StrictInt,
    StrictStr,
    field_validator,
    model_validator,
)

Family = Literal["qwen3_asr", "qwen3_tts", "qwen3_forced_aligner"]
Variant = Literal["asr", "voice_design", "custom_voice", "aligner"]
PresetId = Literal["quality", "balanced", "light"]

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

    @field_validator("bits", "group_size")
    @classmethod
    def validate_positive(cls, value: int | None) -> int | None:
        if value is not None and value <= 0:
            raise ValueError("quantization values must be positive or null")
        return value


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


class ModelPreset(BaseModel):
    """只引用 ASR、TTS 与可选 aligner 制品的预设。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: PresetId
    asr: StrictStr = Field(min_length=1)
    tts: StrictStr = Field(min_length=1)
    aligner: StrictStr | None
    diarization: StrictBool


class TierPrecision(BaseModel):
    """单个档位的 ASR/TTS/aligner 量化精度约束。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    asr: StrictInt = Field(gt=0)
    tts: StrictInt = Field(gt=0)
    aligner: StrictInt | Literal["bf16"] | None

    @field_validator("aligner")
    @classmethod
    def validate_aligner(cls, value: int | Literal["bf16"] | None) -> int | Literal["bf16"] | None:
        if isinstance(value, int) and value <= 0:
            raise ValueError("aligner precision must be positive, 'bf16', or null")
        return value


class RuntimeLock(BaseModel):
    """全档共享且带哈希依赖的 runtime 锁定清单。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: StrictStr = Field(min_length=1)
    python: StrictStr = Field(min_length=1)
    asr_requirements: tuple[StrictStr, ...] = Field(min_length=1)
    tts_requirements: tuple[StrictStr, ...] = Field(min_length=1)
    ffmpeg_artifact: StrictStr = Field(min_length=1)
    file_hashes: Mapping[str, StrictStr] = Field(min_length=1)

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


class ModelCatalog(BaseModel):
    """完整不可变的三档模型目录。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: StrictInt
    artifacts: tuple[ModelArtifact, ...] = Field(min_length=1)
    presets: tuple[ModelPreset, ...] = Field(min_length=3)
    precision_policy: Mapping[PresetId, TierPrecision]

    @field_validator("precision_policy")
    @classmethod
    def freeze_precision_policy(
        cls, value: Mapping[PresetId, TierPrecision]
    ) -> Mapping[PresetId, TierPrecision]:
        return MappingProxyType(dict(value))

    @model_validator(mode="after")
    def validate_catalog(self) -> Self:
        if self.schema_version != _SCHEMA_VERSION:
            raise ValueError(f"schema_version must be {_SCHEMA_VERSION}")

        artifacts: dict[str, ModelArtifact] = {}
        for artifact in self.artifacts:
            if artifact.key in artifacts:
                raise ValueError(f"duplicate artifact key: {artifact.key}")
            artifacts[artifact.key] = artifact

        presets: dict[PresetId, ModelPreset] = {}
        for item in self.presets:
            if item.id in presets:
                raise ValueError(f"duplicate preset id: {item.id}")
            presets[item.id] = item
        expected_ids = {"quality", "balanced", "light"}
        if set(presets) != expected_ids:
            raise ValueError("catalog must contain exactly quality, balanced, and light presets")
        if set(self.precision_policy) != expected_ids:
            raise ValueError(
                "precision_policy must define exactly quality, balanced, and light"
            )

        for preset_id, item in presets.items():
            asr = artifacts.get(item.asr)
            tts = artifacts.get(item.tts)
            if asr is None:
                raise ValueError(f"preset {preset_id} references unknown ASR artifact")
            if tts is None:
                raise ValueError(f"preset {preset_id} references unknown TTS artifact")
            if asr.family != "qwen3_asr" or asr.variant != "asr":
                raise ValueError(f"preset {preset_id} ASR reference has invalid variant")
            if tts.family != "qwen3_tts" or tts.variant == "asr":
                raise ValueError(f"preset {preset_id} TTS reference has invalid variant")

            policy = self.precision_policy[preset_id]
            if asr.quantization.bits != policy.asr:
                raise ValueError(f"preset {preset_id} ASR bits do not match precision_policy")
            if tts.quantization.bits != policy.tts:
                raise ValueError(f"preset {preset_id} TTS bits do not match precision_policy")

            if policy.aligner is None:
                if item.aligner is not None:
                    raise ValueError(
                        f"preset {preset_id} declares an aligner but precision_policy has none"
                    )
                continue
            if item.aligner is None:
                raise ValueError(f"preset {preset_id} is missing its aligner artifact")
            aligner = artifacts.get(item.aligner)
            if aligner is None:
                raise ValueError(f"preset {preset_id} references unknown aligner artifact")
            if aligner.family != "qwen3_forced_aligner" or aligner.variant != "aligner":
                raise ValueError(f"preset {preset_id} aligner reference has invalid variant")
            if policy.aligner == "bf16":
                if aligner.quantization.bits is not None:
                    raise ValueError(
                        f"preset {preset_id} aligner bits do not match precision_policy"
                    )
            elif aligner.quantization.bits != policy.aligner:
                raise ValueError(
                    f"preset {preset_id} aligner bits do not match precision_policy"
                )

        quality = presets["quality"]
        balanced = presets["balanced"]
        light = presets["light"]
        if quality.asr != balanced.asr:
            raise ValueError("quality and balanced presets must share the ASR artifact")
        if artifacts[quality.tts].variant != "voice_design":
            raise ValueError("quality preset must use a voice_design artifact")
        if artifacts[balanced.tts].variant != "custom_voice":
            raise ValueError("balanced preset must use a custom_voice artifact")
        if artifacts[light.tts].variant != "custom_voice":
            raise ValueError("light preset must use a custom_voice artifact")
        return self

    def preset(self, preset_id: str) -> ModelPreset:
        """按 ID 返回模型预设。"""
        for item in self.presets:
            if item.id == preset_id:
                return item
        raise KeyError(preset_id)


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
    return ModelCatalog.model_validate(_load_json(_CATALOG_PATH))


def preset(preset_id: str) -> ModelPreset:
    """读取并返回指定模型预设。"""
    return load_catalog().preset(preset_id)


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
    return lock


__all__ = [
    "ArtifactFile",
    "Family",
    "ModelArtifact",
    "ModelCatalog",
    "ModelPreset",
    "PresetId",
    "QuantizationSpec",
    "RuntimeLock",
    "SourceLocation",
    "TierPrecision",
    "Variant",
    "load_catalog",
    "load_runtime_lock",
    "preset",
]
