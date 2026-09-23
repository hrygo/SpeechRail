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
