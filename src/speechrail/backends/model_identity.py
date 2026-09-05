"""离线读取本地模型身份和 safetensors 结构。"""

from __future__ import annotations

import hashlib
import json
import struct
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from speechrail.config.model_catalog import ModelArtifact, QuantizationSpec

_MAX_HEADER_BYTES: Final = 16 * 1024 * 1024
_HEADER_PREFIX_BYTES: Final = 8
_ALLOWED_BITS: Final = frozenset({4, 8})
_DTYPE_BYTES: Final = {
    "BOOL": 1,
    "U8": 1,
    "I8": 1,
    "F8_E4M3": 1,
    "F8_E5M2": 1,
    "U16": 2,
    "I16": 2,
    "F16": 2,
    "BF16": 2,
    "U32": 4,
    "I32": 4,
    "F32": 4,
    "U64": 8,
    "I64": 8,
    "F64": 8,
}
_SCALE_DTYPES: Final = frozenset({"F16", "F32", "BF16"})
_SINGLE_WEIGHT_FILE: Final = "model.safetensors"
_SHARDED_WEIGHT_FILES: Final = (
    "model-00001-of-00002.safetensors",
    "model-00002-of-00002.safetensors",
)
_WEIGHT_INDEX_FILE: Final = "model.safetensors.index.json"
_QUANTIZATION_KEYS: Final = frozenset({"bits", "group_size", "mode", "format"})
_QUANTIZATION_FORMATS: Final = frozenset({"none", "unquantized", "affine", "mlx"})
_MAX_INDEXED_WEIGHT_FILES: Final = 2


@dataclass(frozen=True, slots=True)
class SnapshotIdentity:
    """本地可验证的模型身份和混合精度摘要。"""

    family: str
    variant: str
    quantization: QuantizationSpec
    weight_fingerprint: str
    mixed_precision: tuple[tuple[str, str], ...] = ()
    model_size: str | None = None


@dataclass(frozen=True, slots=True)
class _TensorHeader:
    name: str
    dtype: str
    shape: tuple[int, ...]
    start: int
    end: int


def _strict_bits(value: object) -> int | None:
    if value is None:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value not in _ALLOWED_BITS:
        raise ValueError("quantization bits must be 4, 8, or null")
    return value


def _strict_group_size(value: object, *, bits: int | None) -> int | None:
    if value is None:
        if bits is not None:
            raise ValueError("quantized models require group_size")
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError("group_size must be a positive integer or null")
    if bits is None:
        raise ValueError("unquantized models must not declare group_size")
    return value


def _quantization_declaration(raw: object, *, field_name: str) -> QuantizationSpec:
    if raw is None:
        return QuantizationSpec(bits=None, group_size=None, format="none")
    if not isinstance(raw, Mapping):
        raise ValueError(f"{field_name} must be an object or null")
    unknown_keys = set(raw) - _QUANTIZATION_KEYS
    if unknown_keys:
        raise ValueError(f"{field_name} contains unknown keys")
    if not raw:
        raise ValueError(f"{field_name} must not be empty")

    bits = _strict_bits(raw.get("bits"))
    group_size = _strict_group_size(raw.get("group_size"), bits=bits)
    mode = raw.get("mode")
    declared_format = raw.get("format")
    if mode is not None and not isinstance(mode, str):
        raise ValueError(f"{field_name}.mode must be a string")
    if declared_format is not None and not isinstance(declared_format, str):
        raise ValueError(f"{field_name}.format must be a string")
    if mode is not None and declared_format is not None and mode != declared_format:
        raise ValueError(f"{field_name}.mode and format conflict")

    if mode is not None:
        selected = mode
        if bits is None:
            if selected not in {"none", "unquantized"}:
                raise ValueError(f"{field_name}.mode must be none for unquantized models")
            return QuantizationSpec(bits=None, group_size=None, format="none")
        if selected != "affine":
            raise ValueError(f"{field_name}.mode must be affine")
        return QuantizationSpec(bits=bits, group_size=group_size, format="affine")

    if declared_format is None:
        selected = "affine" if bits is not None else "none"
    else:
        selected = declared_format
    if selected not in _QUANTIZATION_FORMATS:
        raise ValueError(f"{field_name}.format is unsupported")
    if bits is None:
        if selected not in {"none", "unquantized"}:
            raise ValueError(f"{field_name}.format must be none for unquantized models")
        return QuantizationSpec(bits=None, group_size=None, format="none")
    if selected not in {"affine", "mlx"}:
        raise ValueError(f"{field_name}.format must be affine or mlx")
    return QuantizationSpec(bits=bits, group_size=group_size, format=selected)


def read_quantization(config: dict[str, object]) -> QuantizationSpec:
    """读取 quantization 声明并拒绝冲突或未知量化模式。"""
    if not isinstance(config, dict):
        raise ValueError("model config must be an object")
    declarations: list[QuantizationSpec] = []
    for field_name in ("quantization", "quantization_config"):
        if field_name in config:
            declarations.append(
                _quantization_declaration(config[field_name], field_name=field_name)
            )
    if not declarations:
        return QuantizationSpec(bits=None, group_size=None, format="none")
    first = declarations[0]
    if any(item != first for item in declarations[1:]):
        raise ValueError("quantization and quantization_config must be consistent")
    return first


def _read_bounded(path: Path, *, limit: int, label: str) -> bytes:
    try:
        with path.open("rb") as handle:
            payload = handle.read(limit + 1)
    except OSError as exc:
        raise ValueError(f"could not read {label}") from exc
    if len(payload) > limit:
        raise ValueError(f"{label} exceeds the bounded read limit")
    return payload


def _read_config(model_dir: Path) -> dict[str, object]:
    config_path = model_dir / "config.json"
    if not config_path.is_file():
        raise ValueError("config.json is missing")
    raw = _read_bounded(config_path, limit=_MAX_HEADER_BYTES, label="config.json")
    try:
        config = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("config.json is invalid JSON") from exc
    if not isinstance(config, dict):
        raise ValueError("config.json must contain an object")
    return config


def _read_safetensors_header(
    path: Path, *, label: str = "model.safetensors"
) -> tuple[dict[str, object], int]:
    if not path.is_file():
        raise ValueError(f"{label} is missing")
    try:
        file_size = path.stat().st_size
    except OSError as exc:
        raise ValueError(f"could not stat {label}") from exc
    if file_size < _HEADER_PREFIX_BYTES:
        raise ValueError(f"{label} safetensors header is truncated")
    try:
        with path.open("rb") as handle:
            prefix = handle.read(_HEADER_PREFIX_BYTES)
            header_size = struct.unpack("<Q", prefix)[0]
            if header_size == 0 or header_size > _MAX_HEADER_BYTES:
                raise ValueError(f"{label} safetensors header size is invalid")
            if _HEADER_PREFIX_BYTES + header_size > file_size:
                raise ValueError(f"{label} safetensors header exceeds file size")
            raw_header = handle.read(header_size)
    except OSError as exc:
        raise ValueError(f"could not read {label} safetensors header") from exc
    if len(raw_header) != header_size:
        raise ValueError(f"{label} safetensors header is truncated")
    try:
        header = json.loads(raw_header)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label} safetensors header is invalid JSON") from exc
    if not isinstance(header, dict):
        raise ValueError(f"{label} safetensors header must contain an object")
    return header, file_size - _HEADER_PREFIX_BYTES - header_size


def _shape(raw: object, *, tensor_name: str) -> tuple[int, ...]:
    if not isinstance(raw, list):
        raise ValueError(f"tensor {tensor_name} has an invalid shape")
    if any(not isinstance(item, int) or isinstance(item, bool) or item < 0 for item in raw):
        raise ValueError(f"tensor {tensor_name} has an invalid shape")
    return tuple(raw)


def _offsets(raw: object, *, tensor_name: str, payload_size: int) -> tuple[int, int]:
    if not isinstance(raw, list) or len(raw) != 2:
        raise ValueError(f"tensor {tensor_name} has invalid data_offsets")
    if any(not isinstance(item, int) or isinstance(item, bool) for item in raw):
        raise ValueError(f"tensor {tensor_name} has invalid data_offsets")
    start, end = raw
    if start < 0 or end < start or end > payload_size:
        raise ValueError(f"tensor {tensor_name} data_offsets exceed file size")
    return start, end


def _element_count(shape: tuple[int, ...]) -> int:
    count = 1
    for dimension in shape:
        count *= dimension
    return count


def _parse_tensors(header: Mapping[str, object], *, payload_size: int) -> tuple[_TensorHeader, ...]:
    tensors: list[_TensorHeader] = []
    intervals: list[tuple[int, int, str]] = []
    for tensor_name, raw in header.items():
        if tensor_name == "__metadata__":
            if not isinstance(raw, Mapping):
                raise ValueError("safetensors metadata must be an object")
            continue
        if not isinstance(raw, Mapping):
            raise ValueError(f"tensor {tensor_name} must be an object")
        dtype = raw.get("dtype")
        if not isinstance(dtype, str) or not dtype:
            raise ValueError(f"tensor {tensor_name} has an invalid dtype")
        shape = _shape(raw.get("shape"), tensor_name=tensor_name)
        start, end = _offsets(
            raw.get("data_offsets"), tensor_name=tensor_name, payload_size=payload_size
        )
        expected_bytes = _DTYPE_BYTES.get(dtype)
        if expected_bytes is None:
            raise ValueError(f"tensor {tensor_name} has an unsupported dtype")
        if end - start != _element_count(shape) * expected_bytes:
            raise ValueError(f"tensor {tensor_name} data_offsets do not match shape")
        tensors.append(_TensorHeader(tensor_name, dtype, shape, start, end))
        intervals.append((start, end, tensor_name))

    previous_end = 0
    previous_name = ""
    for start, end, tensor_name in sorted(intervals):
        if start < previous_end:
            raise ValueError(f"tensor {tensor_name} overlaps {previous_name}")
        previous_end = end
        previous_name = tensor_name
    if not tensors:
        raise ValueError("safetensors header contains no tensors")
    return tuple(tensors)


def _read_weight_index(path: Path) -> dict[str, str]:
    raw = _read_bounded(path, limit=_MAX_HEADER_BYTES, label=_WEIGHT_INDEX_FILE)
    try:
        index = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{_WEIGHT_INDEX_FILE} is invalid JSON") from exc
    if not isinstance(index, dict):
        raise ValueError(f"{_WEIGHT_INDEX_FILE} must contain an object")
    if set(index) - {"metadata", "weight_map"}:
        raise ValueError(f"{_WEIGHT_INDEX_FILE} contains unknown keys")
    metadata = index.get("metadata")
    if metadata is not None and not isinstance(metadata, Mapping):
        raise ValueError(f"{_WEIGHT_INDEX_FILE}.metadata must be an object")
    raw_weight_map = index.get("weight_map")
    if not isinstance(raw_weight_map, Mapping) or not raw_weight_map:
        raise ValueError(f"{_WEIGHT_INDEX_FILE}.weight_map must not be empty")

    weight_map: dict[str, str] = {}
    for tensor_name, weight_name in raw_weight_map.items():
        if not isinstance(tensor_name, str) or not tensor_name:
            raise ValueError(f"{_WEIGHT_INDEX_FILE} has an invalid tensor name")
        if not isinstance(weight_name, str) or not weight_name:
            raise ValueError(f"{_WEIGHT_INDEX_FILE} has an invalid weight path")
        if (
            "\x00" in weight_name
            or "/" in weight_name
            or "\\" in weight_name
            or Path(weight_name).is_absolute()
            or Path(weight_name).name != weight_name
            or not weight_name.endswith(".safetensors")
        ):
            raise ValueError(f"{_WEIGHT_INDEX_FILE} contains an unsafe weight path")
        weight_map[tensor_name] = weight_name

    files = set(weight_map.values())
    if len(files) > _MAX_INDEXED_WEIGHT_FILES:
        raise ValueError(f"{_WEIGHT_INDEX_FILE} lists too many weight files")
    return weight_map


def _resolved_weight_path(model_dir: Path, name: str) -> Path:
    root = model_dir.resolve()
    candidate = model_dir / name
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"weight file {name} is missing") from exc
    if not resolved.is_file() or not resolved.is_relative_to(root):
        raise ValueError(f"weight file {name} escapes model directory")
    return resolved


def _root_weight_names(model_dir: Path) -> set[str]:
    try:
        return {
            entry.name
            for entry in model_dir.iterdir()
            if entry.is_file() and entry.name.endswith(".safetensors")
        }
    except OSError as exc:
        raise ValueError("could not list model weight files") from exc


def _weight_paths(
    model_dir: Path,
) -> tuple[tuple[tuple[str, Path], ...], dict[str, str] | None]:
    index_path = model_dir / _WEIGHT_INDEX_FILE
    try:
        has_index = index_path.exists()
    except OSError as exc:
        raise ValueError(f"could not inspect {_WEIGHT_INDEX_FILE}") from exc

    direct_names = _root_weight_names(model_dir)
    if has_index:
        if not index_path.is_file():
            raise ValueError(f"{_WEIGHT_INDEX_FILE} is not a file")
        weight_map = _read_weight_index(index_path)
        expected_names = set(weight_map.values())
        if direct_names != expected_names:
            raise ValueError("indexed weight files do not match the snapshot layout")
        ordered_names = tuple(sorted(expected_names))
    elif direct_names == {_SINGLE_WEIGHT_FILE}:
        weight_map = None
        ordered_names = (_SINGLE_WEIGHT_FILE,)
    elif direct_names == set(_SHARDED_WEIGHT_FILES):
        weight_map = None
        ordered_names = _SHARDED_WEIGHT_FILES
    elif direct_names & ({_SINGLE_WEIGHT_FILE, *_SHARDED_WEIGHT_FILES}):
        raise ValueError("snapshot weight files are missing a required shard")
    else:
        raise ValueError("snapshot weights are missing (model.safetensors or known shards)")

    paths = tuple((name, _resolved_weight_path(model_dir, name)) for name in ordered_names)
    return paths, weight_map


def _read_weight_tensors(
    model_dir: Path,
) -> tuple[tuple[_TensorHeader, ...], dict[str, str] | None]:
    paths, weight_map = _weight_paths(model_dir)
    tensors: list[_TensorHeader] = []
    names: set[str] = set()
    for name, path in paths:
        header, payload_size = _read_safetensors_header(path, label=name)
        shard_tensors = _parse_tensors(header, payload_size=payload_size)
        for tensor in shard_tensors:
            if tensor.name in names:
                raise ValueError(f"duplicate tensor {tensor.name} across weight files")
            if weight_map is not None and weight_map.get(tensor.name) != name:
                raise ValueError(f"weight index does not match tensor {tensor.name}")
            names.add(tensor.name)
        tensors.extend(shard_tensors)

    if weight_map is not None and names != set(weight_map):
        raise ValueError("weight index does not cover every tensor")
    return tuple(tensors), weight_map


def _quantized_pairs(
    tensors: tuple[_TensorHeader, ...], *, group_size: int
) -> tuple[tuple[_TensorHeader, _TensorHeader, int], ...]:
    packed_weights = {
        tensor.name: tensor
        for tensor in tensors
        if tensor.name.endswith(".weight") and tensor.dtype == "U32"
    }
    all_u32 = [tensor for tensor in tensors if tensor.dtype == "U32"]
    if len(packed_weights) != len(all_u32):
        raise ValueError("quantized tensors must use U32 .weight tensors")
    scales = {
        tensor.name: tensor
        for tensor in tensors
        if tensor.name.endswith(".scales")
    }
    pairs: list[tuple[_TensorHeader, _TensorHeader, int]] = []
    for weight_name, weight in packed_weights.items():
        scales_name = f"{weight_name[:-len('.weight')]}.scales"
        scale = scales.get(scales_name)
        if scale is None:
            raise ValueError(f"quantized weight {weight_name} is missing scales")
        if scale.dtype not in _SCALE_DTYPES:
            raise ValueError(f"quantized scales {scales_name} must use a float dtype")
        if len(weight.shape) < 2 or len(scale.shape) != len(weight.shape):
            raise ValueError(f"quantized weight {weight_name} has incompatible shapes")
        if weight.shape[:-1] != scale.shape[:-1] or scale.shape[-1] <= 0:
            raise ValueError(f"quantized weight {weight_name} has incompatible shapes")
        numerator = weight.shape[-1] * 32
        denominator = scale.shape[-1] * group_size
        if numerator % denominator:
            raise ValueError(f"quantized weight {weight_name} shape does not prove bit width")
        bits = numerator // denominator
        if bits not in _ALLOWED_BITS:
            raise ValueError(f"quantized weight {weight_name} proves unsupported bits")
        pairs.append((weight, scale, bits))
    paired_scale_names = {
        f"{weight.name[:-len('.weight')]}.scales" for weight in packed_weights.values()
    }
    if set(scales) != paired_scale_names:
        raise ValueError("quantized scales do not match packed weights")
    if not pairs:
        raise ValueError("quantized model is missing U32 weight and float scales")
    return tuple(pairs)


def _family_variant(config: Mapping[str, object]) -> tuple[str, str]:
    family = config.get("model_type")
    if family == "qwen3_asr":
        variant = config.get("variant", "asr")
        if variant != "asr":
            raise ValueError("qwen3_asr has an unsupported variant")
        return family, variant
    if family == "qwen3_tts":
        variant = config.get("tts_model_type", config.get("variant"))
        if variant not in {"voice_design", "custom_voice"}:
            raise ValueError("qwen3_tts has an unsupported variant")
        return family, variant
    raise ValueError("model config has an unsupported family")


def _model_size(config: Mapping[str, object]) -> str | None:
    for field_name in ("parameter_size", "parameter_count", "num_parameters", "hidden_size"):
        value = config.get(field_name)
        if isinstance(value, str) and value:
            return f"{field_name}={value}"
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            return f"{field_name}={value}"
    return None


def _mixed_precision(tensors: tuple[_TensorHeader, ...]) -> tuple[tuple[str, str], ...]:
    summary: dict[str, str] = {}
    for tensor in tensors:
        lowered = tensor.name.lower()
        if tensor.dtype == "U32" and tensor.name.endswith(".weight"):
            summary["packed_weight"] = tensor.dtype
        if tensor.name.endswith(".scales"):
            summary["scales"] = tensor.dtype
        if tensor.dtype == "BF16" and (
            "codec" in lowered or "speech_tokenizer" in lowered
        ):
            summary["codec"] = tensor.dtype
        elif tensor.dtype == "BF16" and "embed" in lowered:
            summary["embedding"] = tensor.dtype
        elif tensor.dtype == "BF16":
            summary.setdefault("weights", tensor.dtype)
    return tuple(sorted(summary.items()))


def _fingerprint(
    family: str,
    variant: str,
    quantization: QuantizationSpec,
    tensors: tuple[_TensorHeader, ...],
    model_size: str | None,
) -> str:
    structure = {
        "family": family,
        "variant": variant,
        "model_size": model_size,
        "quantization": {
            "bits": quantization.bits,
            "group_size": quantization.group_size,
            "format": quantization.format,
        },
        "tensors": [
            {
                "name": tensor.name,
                "dtype": tensor.dtype,
                "shape": tensor.shape,
                "bytes": tensor.end - tensor.start,
            }
            for tensor in sorted(tensors, key=lambda item: item.name)
        ],
    }
    encoded = json.dumps(structure, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return f"shape:{hashlib.sha256(encoded).hexdigest()}"


def inspect_model(model_dir: Path) -> SnapshotIdentity:
    """有界读取 config 和主 safetensors header 生成本地身份。"""
    if not model_dir.is_dir():
        raise ValueError("model directory is missing")
    config = _read_config(model_dir)
    family, variant = _family_variant(config)
    quantization = read_quantization(config)
    tensors, _ = _read_weight_tensors(model_dir)

    u32_weights = [
        tensor for tensor in tensors if tensor.dtype == "U32" and tensor.name.endswith(".weight")
    ]
    if quantization.bits is None:
        if u32_weights:
            raise ValueError("unquantized config conflicts with U32 weight tensors")
    else:
        pairs = _quantized_pairs(tensors, group_size=quantization.group_size or 0)
        actual_bits = {bits for _, _, bits in pairs}
        if actual_bits != {quantization.bits}:
            raise ValueError("declared quantization bits do not match tensor shapes")

    model_size = _model_size(config)
    return SnapshotIdentity(
        family=family,
        variant=variant,
        quantization=quantization,
        weight_fingerprint=_fingerprint(
            family, variant, quantization, tensors, model_size
        ),
        mixed_precision=_mixed_precision(tensors),
        model_size=model_size,
    )


def _actual_quantization(actual: Mapping[str, object]) -> QuantizationSpec:
    declared: list[QuantizationSpec] = []
    raw_quantization = actual.get("quantization")
    if raw_quantization is not None:
        if isinstance(raw_quantization, QuantizationSpec):
            declared.append(raw_quantization)
        elif isinstance(raw_quantization, Mapping):
            declared.append(
                _quantization_declaration(raw_quantization, field_name="quantization")
            )
        else:
            raise ValueError("actual quantization must be an object")

    if "quantization_bits" in actual or "quantization_group_size" in actual:
        bits = _strict_bits(actual.get("quantization_bits"))
        group_size = _strict_group_size(actual.get("quantization_group_size"), bits=bits)
        declared.append(QuantizationSpec(bits=bits, group_size=group_size, format="actual"))

    if not declared:
        return QuantizationSpec(bits=None, group_size=None, format="none")
    first = declared[0]
    if any((item.bits, item.group_size) != (first.bits, first.group_size) for item in declared[1:]):
        raise ValueError("actual quantization declarations are inconsistent")
    return first


def verify_loaded_identity(expected: ModelArtifact, actual: dict[str, object]) -> None:
    """校验已加载身份与 catalog 制品的 family、variant 和量化字段。"""
    if not isinstance(actual, dict):
        raise ValueError("actual identity must be an object")
    if actual.get("family") != expected.family:
        raise ValueError("loaded identity family mismatch")
    missing = object()
    variant = actual.get("variant", missing)
    model_variant = actual.get("model_variant", missing)
    if variant is not missing and model_variant is not missing and variant != model_variant:
        raise ValueError("loaded identity variant mismatch")
    loaded_variant = model_variant if model_variant is not missing else variant
    if loaded_variant != expected.variant:
        raise ValueError("loaded identity variant mismatch")
    if "artifact_key" in actual and actual["artifact_key"] != expected.key:
        raise ValueError("loaded identity artifact mismatch")

    actual_quantization = _actual_quantization(actual)
    expected_quantization = expected.quantization
    if (actual_quantization.bits, actual_quantization.group_size) != (
        expected_quantization.bits,
        expected_quantization.group_size,
    ):
        raise ValueError("loaded identity quantization mismatch")


__all__ = [
    "SnapshotIdentity",
    "inspect_model",
    "read_quantization",
    "verify_loaded_identity",
]
