"""Safe, path-free model catalog and status payloads."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from speechrail.config.model_catalog import load_catalog
from speechrail.domain.model_spec import required_spec_bindings
from speechrail.service.diarization_assets import inspect_diarization_assets
from speechrail.service.model_commands import model_catalog_payload, model_status_payload
from speechrail.service.model_store import model_store_root


def test_model_catalog_payload_has_required_by_and_no_local_path() -> None:
    payload = model_catalog_payload(catalog=load_catalog())

    assert {item["id"] for item in payload["profiles"]} == {
        "fast",
        "quality",
        "reference",
    }
    assert all(item["required_by"] for item in payload["artifacts"])
    assert all("path" not in item for item in payload["artifacts"])
    assert all("url" not in item for item in payload["artifacts"])
    row = next(item for item in payload["profiles"] if item["id"] == "fast")
    assert row["asr"] == "asr-0.6b-q8"
    assert row["tts"] == "tts-0.6b-custom-q8"
    assert row["tts_base"] == "tts-0.6b-base-q8"


def test_model_catalog_lists_only_spec_bound_artifacts() -> None:
    payload = model_catalog_payload(catalog=load_catalog())
    bound = {
        artifact_key for _tier, _role, artifact_key in required_spec_bindings()
    }

    listed = {
        item["key"]
        for item in payload["artifacts"]
        if item["key"] != "diarization-coreml"
    }
    assert listed <= bound
    # The retired Design Q8 artifact is not bound to any spec tier any more.
    assert "tts-1.7b-design-q8" not in listed
    rows = {item["key"]: item for item in payload["artifacts"]}
    assert rows["asr-0.6b-q8"]["required_by"] == ["fast"]
    assert rows["asr-1.7b-bf16"]["required_by"] == ["reference"]


def test_model_catalog_payload_lists_the_locked_coreml_asset() -> None:
    """分人的 CoreML 资产不在目录里, 但同样是任务可选的文件: 表里要有一行。

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
    # 分人是任务 opt-in, 不再绑定档位。
    assert coreml["required_by"] == ["diarization"]
    assert "path" not in coreml
    assert "url" not in coreml


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


def test_model_status_counts_files_under_canonical_model_root(tmp_path: Path) -> None:
    app_home = tmp_path / "SpeechRail Home"
    model_root = model_store_root(app_home)
    model_root.mkdir(parents=True)
    (model_root / "sentinel.bin").write_bytes(b"abc123")

    payload = model_status_payload(
        app_home,
        catalog=load_catalog(),
        disk_usage=lambda _: SimpleNamespace(free=1234),
    )

    assert payload["disk"]["model_bytes"] == 6


def test_diarization_status_is_separate_and_path_free(tmp_path: Path) -> None:
    statuses = inspect_diarization_assets(
        tmp_path,
        aligner_key="aligner-q8",
        catalog=load_catalog(),
    )

    assert {item.key for item in statuses} == {
        "diarization-coreml",
        "aligner-q8",
    }
    assert all(item.state == "not_downloaded" for item in statuses)
