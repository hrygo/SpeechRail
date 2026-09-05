"""本地模型身份与量化元数据检查测试。"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import pytest

from speechrail.backends.model_identity import (
    inspect_model,
    read_quantization,
    verify_loaded_identity,
)
from speechrail.config.model_catalog import ModelArtifact

REVISION = "a" * 40
SHA256 = "b" * 64


def _product(shape: list[int]) -> int:
    result = 1
    for dimension in shape:
        result *= dimension
    return result


def _write_safetensors(
    path: Path,
    tensors: list[tuple[str, str, list[int]]],
    *,
    padding: int = 16,
) -> None:
    dtype_sizes = {
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
    header: dict[str, object] = {}
    offset = 0
    for name, dtype, shape in tensors:
        size = _product(shape) * dtype_sizes.get(dtype, 1)
        header[name] = {
            "dtype": dtype,
            "shape": shape,
            "data_offsets": [offset, offset + size],
        }
        offset += size
    header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
    payload = struct.pack("<Q", len(header_bytes)) + header_bytes + (b"\0" * (offset + padding))
    path.write_bytes(payload)


def _write_snapshot(
    root: Path,
    config: dict[str, object],
    tensors: list[tuple[str, str, list[int]]],
    *,
    padding: int = 16,
) -> None:
    (root / "config.json").write_text(json.dumps(config), encoding="utf-8")
    _write_safetensors(root / "model.safetensors", tensors, padding=padding)


def _write_weight_index(root: Path, weight_map: dict[str, str]) -> None:
    index = {"metadata": {"total_size": 1}, "weight_map": weight_map}
    (root / "model.safetensors.index.json").write_text(
        json.dumps(index), encoding="utf-8"
    )


def _quantized_tensors(bits: int) -> list[tuple[str, str, list[int]]]:
    weight_last_dimension = 512 if bits == 8 else 256
    return [
        ("model.embed_tokens.weight", "U32", [2, weight_last_dimension]),
        ("model.embed_tokens.scales", "BF16", [2, 32]),
    ]


def _artifact() -> ModelArtifact:
    file_entry = {"path": "config.json", "size": 1, "sha256": SHA256}
    files = [
        file_entry,
        {"path": "model.safetensors", "size": 1, "sha256": SHA256},
        {"path": "tokenizer_config.json", "size": 1, "sha256": SHA256},
        {"path": "vocab.json", "size": 1, "sha256": SHA256},
        {"path": "merges.txt", "size": 1, "sha256": SHA256},
    ]
    return ModelArtifact(
        key="asr-1.7b-q8",
        model_id="fixture/asr",
        revision=REVISION,
        family="qwen3_asr",
        variant="asr",
        quantization={"bits": 8, "group_size": 64, "format": "mlx"},
        files=files,
        sources=[
            {"provider": "fixture", "repository": "fixture/asr", "revision": REVISION}
        ],
    )


def test_quantized_does_not_mean_int8() -> None:
    quantization = read_quantization({"quantization": {"bits": 4, "group_size": 64}})

    assert quantization.bits == 4
    assert quantization.group_size == 64


def test_read_quantization_supports_unquantized_and_eight_bit() -> None:
    assert read_quantization({}).bits is None
    quantization = read_quantization(
        {"quantization": {"bits": 8, "group_size": 64, "mode": "affine"}}
    )
    assert quantization.bits == 8
    assert quantization.format == "affine"


@pytest.mark.parametrize(
    "config",
    [
        {"quantization": {}},
        {"quantization": {"bits": 8, "group_size": 64, "mode": "affine", "extra": 1}},
        {
            "quantization": {
                "bits": 8,
                "group_size": 64,
                "mode": "affine",
                "format": "mlx",
            }
        },
        {"quantization": []},
    ],
)
def test_malformed_quantization_is_rejected(config: dict[str, object]) -> None:
    with pytest.raises(ValueError, match=r"quantization|mode|format|bits"):
        read_quantization(config)


def test_quantization_declarations_must_match() -> None:
    with pytest.raises(ValueError, match=r"consistent|match"):
        read_quantization(
            {
                "quantization": {"bits": 8, "group_size": 64, "mode": "affine"},
                "quantization_config": {"bits": 4, "group_size": 64, "mode": "affine"},
            }
        )


@pytest.mark.parametrize(
    "config",
    [
        {"quantization": {"bits": 16, "group_size": 64, "mode": "affine"}},
        {"quantization": {"bits": 8, "group_size": 64, "mode": "mystery"}},
    ],
)
def test_unknown_bits_or_mode_is_rejected(config: dict[str, object]) -> None:
    with pytest.raises(ValueError, match=r"bits|mode"):
        read_quantization(config)


def test_inspect_model_proves_eight_bit_from_tensor_shapes(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr", "quantization": {"bits": 8, "group_size": 64}},
        _quantized_tensors(8),
    )

    identity = inspect_model(tmp_path)

    assert identity.family == "qwen3_asr"
    assert identity.variant == "asr"
    assert identity.quantization.bits == 8
    assert identity.quantization.group_size == 64
    assert identity.weight_fingerprint.startswith("shape:")


def test_inspect_model_accepts_four_bit_tts_with_bfloat_codec(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {
            "model_type": "qwen3_tts",
            "tts_model_type": "custom_voice",
            "quantization_config": {"bits": 4, "group_size": 64, "mode": "affine"},
        },
        [*_quantized_tensors(4), ("codec.weight", "BF16", [2, 8])],
    )

    identity = inspect_model(tmp_path)

    assert identity.family == "qwen3_tts"
    assert identity.variant == "custom_voice"
    assert identity.quantization.bits == 4
    assert ("codec", "BF16") in identity.mixed_precision


@pytest.mark.parametrize("scale_dtype", ["F16", "F32", "BF16"])
def test_inspect_model_accepts_float_scales(tmp_path: Path, scale_dtype: str) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr", "quantization": {"bits": 8, "group_size": 64}},
        [
            ("model.embed_tokens.weight", "U32", [2, 512]),
            ("model.embed_tokens.scales", scale_dtype, [2, 32]),
        ],
    )

    identity = inspect_model(tmp_path)

    assert identity.quantization.bits == 8
    assert ("scales", scale_dtype) in identity.mixed_precision


def test_inspect_model_rejects_unknown_tensor_dtype(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr"},
        [("model.embed_tokens.weight", "UNKNOWN_DTYPE", [2, 8])],
    )

    with pytest.raises(ValueError, match="dtype"):
        inspect_model(tmp_path)


def test_inspect_model_accepts_indexed_two_shard_unquantized_snapshot(
    tmp_path: Path,
) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8"
    )
    first_name = "model-00001-of-00002.safetensors"
    second_name = "model-00002-of-00002.safetensors"
    first_tensor = "model.embed_tokens.weight"
    second_tensor = "model.layers.0.weight"
    _write_safetensors(tmp_path / first_name, [(first_tensor, "F16", [2, 8])])
    _write_safetensors(tmp_path / second_name, [(second_tensor, "F16", [2, 8])])
    _write_weight_index(
        tmp_path,
        {first_tensor: first_name, second_tensor: second_name},
    )

    identity = inspect_model(tmp_path)

    assert identity.quantization.bits is None
    assert identity.weight_fingerprint.startswith("shape:")


def test_inspect_model_accepts_known_two_shard_layout_without_index(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8"
    )
    _write_safetensors(
        tmp_path / "model-00001-of-00002.safetensors",
        [("model.embed_tokens.weight", "F16", [2, 8])],
    )
    _write_safetensors(
        tmp_path / "model-00002-of-00002.safetensors",
        [("model.layers.0.weight", "F16", [2, 8])],
    )

    assert inspect_model(tmp_path).family == "qwen3_asr"


def test_inspect_model_rejects_missing_indexed_shard(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8"
    )
    first_name = "model-00001-of-00002.safetensors"
    second_name = "model-00002-of-00002.safetensors"
    tensor_name = "model.embed_tokens.weight"
    _write_safetensors(tmp_path / first_name, [(tensor_name, "F16", [2, 8])])
    _write_weight_index(tmp_path, {tensor_name: first_name, "other": second_name})

    with pytest.raises(ValueError, match=r"shard|weight|missing"):
        inspect_model(tmp_path)


def test_inspect_model_rejects_duplicate_tensor_across_shards(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8"
    )
    tensor_name = "model.embed_tokens.weight"
    first_name = "model-00001-of-00002.safetensors"
    second_name = "model-00002-of-00002.safetensors"
    for name in (first_name, second_name):
        _write_safetensors(tmp_path / name, [(tensor_name, "F16", [2, 8])])
    _write_weight_index(tmp_path, {tensor_name: first_name, "other": second_name})

    with pytest.raises(ValueError, match=r"duplicate|multiple|tensor"):
        inspect_model(tmp_path)


def test_inspect_model_rejects_index_path_escape(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8"
    )
    _write_weight_index(tmp_path, {"model.weight": "../outside.safetensors"})

    with pytest.raises(ValueError, match=r"index|path|weight"):
        inspect_model(tmp_path)


def test_inspect_model_accepts_unquantized_bfloat_weights(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr"},
        [("model.embed_tokens.weight", "BF16", [2, 8])],
    )

    assert inspect_model(tmp_path).quantization.bits is None


def test_inspect_model_rejects_declared_bits_that_shape_does_not_prove(
    tmp_path: Path,
) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr", "quantization": {"bits": 8, "group_size": 64}},
        _quantized_tensors(4),
    )

    with pytest.raises(ValueError, match=r"bits|shape"):
        inspect_model(tmp_path)


def test_inspect_model_rejects_quantization_without_weight_and_scales(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr", "quantization": {"bits": 8, "group_size": 64}},
        [("model.embed_tokens.weight", "BF16", [2, 8])],
    )

    with pytest.raises(ValueError, match=r"quant|weight|scales"):
        inspect_model(tmp_path)


@pytest.mark.parametrize(
    "config",
    [{"model_type": "unknown"}, {"model_type": "qwen3_tts", "tts_model_type": "bad"}],
)
def test_inspect_model_rejects_unknown_family_or_variant(
    tmp_path: Path, config: dict[str, object]
) -> None:
    _write_snapshot(tmp_path, config, [("model.embed_tokens.weight", "BF16", [2, 8])])

    with pytest.raises(ValueError, match=r"family|variant"):
        inspect_model(tmp_path)


def test_inspect_model_rejects_corrupt_header(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8")
    (tmp_path / "model.safetensors").write_bytes(b"\x01\x02")

    with pytest.raises(ValueError, match="header"):
        inspect_model(tmp_path)


def test_inspect_model_rejects_missing_paths(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="config"):
        inspect_model(tmp_path)

    (tmp_path / "config.json").write_text(json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8")
    with pytest.raises(ValueError, match=r"model\.safetensors"):
        inspect_model(tmp_path)


def test_snapshot_identity_is_frozen(tmp_path: Path) -> None:
    _write_snapshot(
        tmp_path,
        {"model_type": "qwen3_asr"},
        [("model.embed_tokens.weight", "BF16", [2, 8])],
    )
    identity = inspect_model(tmp_path)

    with pytest.raises(AttributeError):
        identity.family = "qwen3_tts"  # type: ignore[misc]


def test_verify_loaded_identity_accepts_matching_ready_data() -> None:
    verify_loaded_identity(
        _artifact(),
        {
            "family": "qwen3_asr",
            "variant": "asr",
            "quantization_bits": 8,
            "quantization_group_size": 64,
            "artifact_key": "asr-1.7b-q8",
        },
    )


def test_verify_loaded_identity_accepts_model_variant_ready_field() -> None:
    verify_loaded_identity(
        _artifact(),
        {
            "family": "qwen3_asr",
            "model_variant": "asr",
            "quantization_bits": 8,
            "quantization_group_size": 64,
        },
    )


def test_verify_loaded_identity_rejects_conflicting_variant_fields() -> None:
    with pytest.raises(ValueError, match="variant"):
        verify_loaded_identity(
            _artifact(),
            {
                "family": "qwen3_asr",
                "variant": "asr",
                "model_variant": "voice_design",
                "quantization_bits": 8,
                "quantization_group_size": 64,
            },
        )


@pytest.mark.parametrize(
    "actual",
    [
        {
            "family": "qwen3_tts",
            "variant": "asr",
            "quantization_bits": 8,
            "quantization_group_size": 64,
        },
        {
            "family": "qwen3_asr",
            "variant": "asr",
            "quantization_bits": 4,
            "quantization_group_size": 64,
        },
        {
            "family": "qwen3_asr",
            "variant": "asr",
            "quantization_bits": 8,
            "quantization_group_size": 32,
        },
        {
            "family": "qwen3_asr",
            "variant": "asr",
            "quantization_bits": 8,
            "quantization_group_size": 64,
            "artifact_key": "wrong",
        },
    ],
)
def test_verify_loaded_identity_rejects_mismatch(actual: dict[str, object]) -> None:
    with pytest.raises(ValueError, match=r"identity|family|variant|bits|group|artifact"):
        verify_loaded_identity(_artifact(), actual)
