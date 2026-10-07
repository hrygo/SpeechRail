"""Offline vectors for loaded observations, distinct from snapshot declarations."""

from __future__ import annotations

import subprocess
import sys
from types import SimpleNamespace

import pytest

from speechrail.backends.loader_metadata import (
    MISSING,
    LoaderSource,
    identity_quantization,
    loader_quantization,
    loader_value,
)
from speechrail.backends.model_identity import read_quantization
from speechrail.config.model_catalog import QuantizationSpec


@pytest.mark.parametrize("as_object", [False, True])
def test_value_uses_explicit_source_and_field_order_without_guessing(as_object: bool) -> None:
    values = {"dtype": None, "alias": "bf16", "enabled": False}
    first = SimpleNamespace(**values) if as_object else values
    sources = (LoaderSource("primary", first), LoaderSource("fallback", {"dtype": "float16"}))
    assert loader_value(sources, ("dtype", "alias")) == "bf16"
    assert loader_value(sources, ("enabled",)) is False
    assert loader_value(sources, ("absent",)) is MISSING
    assert loader_value((LoaderSource("empty", None),), ("dtype",)) is MISSING
    assert loader_value((LoaderSource("unknown", {"dtype": "unknown"}),), ("dtype",)) == "unknown"


@pytest.mark.parametrize("as_object", [False, True])
@pytest.mark.parametrize(
    ("metadata", "expected"),
    [
        ({}, None),
        ({"quantization": None}, None),
        ({"quantization_config": None}, None),
        ({"quantization": {"bits": None, "group_size": None}}, (None, None)),
        ({"quantization_bits": None, "quantization_group_size": None}, (None, None)),
        ({"quantization_bits": 8, "quantization_group_size": 64}, (8, 64)),
        ({"quantization_config": {"bits": 4, "group_size": 32}}, (4, 32)),
        (
            {
                "quantization": {"bits": 8, "group_size": 64, "format": "affine"},
                "quantization_config": {"bits": 8, "group_size": 64, "format": "mlx"},
                "quantization_bits": 8,
                "quantization_group_size": 64,
            },
            (8, 64),
        ),
    ],
)
def test_loaded_observations_keep_absent_and_explicit_unquantized_separate(
    as_object: bool, metadata: dict[str, object], expected: tuple[int | None, int | None] | None
) -> None:
    source = SimpleNamespace(**metadata) if as_object else metadata
    result = loader_quantization((LoaderSource("loader", source),))
    assert (None if result is None else (result.bits, result.group_size)) == expected


def test_snapshot_requires_full_agreement_while_loaded_only_compares_observed_pair() -> None:
    declarations = {
        "quantization": {"bits": 8, "group_size": 64, "format": "mlx"},
        "quantization_config": {"bits": 8, "group_size": 64, "format": "affine"},
    }
    with pytest.raises(ValueError, match="consistent"):
        read_quantization(declarations)
    loaded = loader_quantization((LoaderSource("model_info", declarations),))
    assert loaded is not None and loaded.bits == 8
    assert read_quantization({"quantization": None}).bits is None
    assert loader_quantization((LoaderSource("model_info", {"quantization": None}),)) is None


@pytest.mark.parametrize(
    "metadata",
    [
        {"quantization": "unknown"},
        {"quantization": {}},
        {"quantization": {"bits": 8, "group_size": 64, "surprise": True}},
        {"quantization_bits": 8},
        {"quantization_group_size": 64},
        {"quantization_bits": 8, "quantization_group_size": None},
        {"quantization_bits": None, "quantization_group_size": 64},
        {"quantization": QuantizationSpec(bits=16, group_size=64, format="affine")},
        {"quantization": QuantizationSpec(bits=8, group_size=None, format="affine")},
        {"quantization": QuantizationSpec(bits=None, group_size=64, format="none")},
    ],
)
def test_invalid_loaded_declarations_fail_closed_with_source_not_payload(
    metadata: dict[str, object],
) -> None:
    with pytest.raises(RuntimeError, match="backend_identity_mismatch") as error:
        loader_quantization((LoaderSource("model_info", metadata),))
    assert "model_info" in str(error.value)
    assert "surprise" not in str(error.value)


@pytest.mark.parametrize(
    ("bits", "group_size"),
    [(True, 64), (8.0, 64), (3, 64), (16, 64), (8, 0), (8, -1), (8, True), (8, 64.0)],
)
def test_one_pair_rule_rejects_bad_snapshot_loaded_and_ready_identity(
    bits: object, group_size: object,
) -> None:
    with pytest.raises(ValueError):
        read_quantization({"quantization": {"bits": bits, "group_size": group_size}})
    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        loader_quantization((LoaderSource("ready", {
            "quantization_bits": bits, "quantization_group_size": group_size,
        }),))
    with pytest.raises(ValueError):
        identity_quantization(SimpleNamespace(
            quantization_bits=bits, quantization_group_size=group_size,
        ))


@pytest.mark.parametrize("second", [
    {"quantization": {"bits": 4, "group_size": 64}},
    {"quantization_bits": 8, "quantization_group_size": 32},
    {"quantization": {"bits": None, "group_size": None}},
])
def test_conflicts_across_sources_are_not_hidden_by_priority(second: dict[str, object]) -> None:
    with pytest.raises(RuntimeError, match="loader quantization conflict"):
        loader_quantization((
            LoaderSource("first", {"quantization": {"bits": 8, "group_size": 64}}),
            LoaderSource("second", second),
        ))


def test_new_collector_shape_uses_the_same_rules_and_preserves_caller_priority() -> None:
    sources = (
        LoaderSource("new_vendor.info", SimpleNamespace(variant="first", quantization=None)),
        LoaderSource("new_vendor.metadata", {"variant": "second", "quantization_bits": 8,
                                            "quantization_group_size": 64}),
    )
    assert loader_value(sources, ("variant",)) == "first"
    result = loader_quantization(sources)
    assert result is not None and (result.bits, result.group_size) == (8, 64)


def test_pure_metadata_import_does_not_load_vendor_or_touch_model_files() -> None:
    code = """
import sys
def guard(event, args):
    if (event == "open" and isinstance(args[0], str)
            and args[0].endswith(("config.json", ".safetensors"))):
        raise AssertionError("metadata import attempted model IO")
sys.addaudithook(guard)
import speechrail.backends.loader_metadata
assert not any(name == "mlx" or name.startswith(("mlx.", "mlx_qwen3_asr", "mlx_audio"))
               for name in sys.modules)
"""
    subprocess.run([sys.executable, "-c", code], check=True)
