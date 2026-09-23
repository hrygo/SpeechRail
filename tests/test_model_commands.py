"""Safe, path-free model catalog and status payloads."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from speechrail.config.model_catalog import load_catalog
from speechrail.service.diarization_assets import inspect_diarization_assets
from speechrail.service.model_commands import model_catalog_payload, model_status_payload


def test_model_catalog_payload_has_required_by_and_no_local_path() -> None:
    payload = model_catalog_payload(catalog=load_catalog())

    assert {item["id"] for item in payload["profiles"]} == {
        "extreme",
        "quality",
        "balanced",
        "light",
    }
    assert all(item["required_by"] for item in payload["artifacts"])
    assert all("path" not in item for item in payload["artifacts"])
    assert all("url" not in item for item in payload["artifacts"])


def test_model_catalog_payload_lists_the_locked_coreml_asset() -> None:
    """分人的 CoreML 资产不在目录里, 但同样是这一档要用的文件: 表里要有一行。

    这一行按 catalog 制品的字段形状给出 (App 的解码要求每个字段都在), 精度与
    `aligner-bf16` 同一个维度——没有量化, 写权重本身的 FP16。
    """
    payload = model_catalog_payload(catalog=load_catalog())
    rows = {item["key"]: item for item in payload["artifacts"]}
    coreml = rows["diarization-coreml"]

    assert payload["artifacts"][-1]["key"] == "diarization-coreml"
    assert set(coreml) == {
        "key",
        "model_id",
        "family",
        "variant",
        "revision",
        "provider",
        "repository",
        "quantization",
        "size_bytes",
        "file_count",
        "required_by",
    }
    assert coreml["provider"] == "huggingface"
    assert coreml["quantization"] == {
        "bits": None,
        "group_size": None,
        "format": "none",
        "dtype": "fp16",
    }
    assert coreml["file_count"] == 10
    assert set(coreml["required_by"]) == {"balanced", "quality", "extreme"}
    assert "path" not in coreml
    assert "url" not in coreml


def test_model_catalog_payload_omits_the_coreml_row_without_diarization() -> None:
    catalog = load_catalog()
    without_diarization = catalog.model_copy(
        update={
            "presets": tuple(
                preset.model_copy(update={"diarization": False})
                for preset in catalog.presets
            )
        }
    )

    payload = model_catalog_payload(catalog=without_diarization)

    assert all(item["key"] != "diarization-coreml" for item in payload["artifacts"])


def test_model_status_marks_missing_artifacts_without_exposing_paths(tmp_path: Path) -> None:
    payload = model_status_payload(
        tmp_path,
        catalog=load_catalog(),
        disk_usage=lambda _: SimpleNamespace(free=1234),
    )

    assert payload["status"] == "ok"
    assert payload["disk"] == {"model_bytes": 0, "free_bytes": 1234}
    assert all(item["state"] == "not_downloaded" for item in payload["artifacts"])
    assert all(item["state"] == "not_downloaded" for item in payload["diarization"])
    assert all("path" not in item for item in payload["artifacts"])


def test_diarization_status_is_separate_and_path_free(tmp_path: Path) -> None:
    statuses = inspect_diarization_assets(
        tmp_path,
        preset_id="balanced",
        catalog=load_catalog(),
    )

    assert {item.key for item in statuses} == {
        "diarization-coreml",
        "aligner-q8",
    }
    assert all(item.state == "not_downloaded" for item in statuses)
