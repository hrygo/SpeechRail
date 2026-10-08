"""Select explicit ASR fixtures before credentials, warmup or inference."""

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_realtime_json as cli
from examples.perf import realtime_asr_benchmark as benchmark


def fixture_manifest(tmp_path):
    rows = []
    for fixture_id in ("first", "middle", "last"):
        audio = tmp_path / f"{fixture_id}.wav"
        audio.write_bytes(b"synthetic audio; decoded by fake")
        rows.append({
            "id": fixture_id, "kind": "asr", "path": str(audio),
            "language": "zh", "reference_text": f"synthetic-{fixture_id}",
        })
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"fixtures": rows}))
    return path


def install_fake(monkeypatch):
    calls = []

    class Monitor:
        def __init__(self, **kwargs):
            pass

        def start(self):
            pass

        def stop(self):
            return {}

    def run(_client, wire, **kwargs):
        calls.append((wire, kwargs["reference"]))
        return {"quality_metrics": {"character_errors": 0}}

    monkeypatch.setattr(benchmark, "OpenAI", lambda **kwargs: object())
    monkeypatch.setattr(benchmark, "resolve_api_key", lambda **kwargs: None)
    monkeypatch.setattr(benchmark, "ProcessResourceMonitor", Monitor)
    monkeypatch.setattr(benchmark, "_normalise_resources", lambda raw: {})
    monkeypatch.setattr(benchmark, "_wire_audio", lambda path: (path.stem.encode() * 2, 1))
    monkeypatch.setattr(benchmark, "_run_asr", run)
    return calls


def run(manifest, output, **kwargs):
    return benchmark.run_manifest_asr_benchmark(
        manifest, output=output, profile="quality", sessions=1, warmup=True,
        app_home=None, base_url="http://127.0.0.1:8201/v1", **kwargs,
    )


def test_explicit_selection_preserves_source_order_warmup_and_wire_identity(monkeypatch, tmp_path):
    manifest = fixture_manifest(tmp_path)
    calls = install_fake(monkeypatch)

    payload = run(manifest, tmp_path / "focused.json", fixture_ids=["last", "first"])

    assert [row["id"] for row in payload["sessions"]] == ["first", "last"]
    assert [reference for _, reference in calls] == [
        "synthetic-first", "synthetic-first", "synthetic-last",
    ]
    assert payload["fixture_selection"] == {
        "requested_ids": ["last", "first"],
        "executed_order": ["first", "last"],
        "warmup_fixture_id": "first",
        "source_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "scope": "selected_fixtures",
        "frozen_v4_matrix_scope": False,
    }
    assert [row["wire_pcm_sha256"] for row in payload["sessions"]] == [
        hashlib.sha256(b"firstfirst").hexdigest(),
        hashlib.sha256(b"lastlast").hexdigest(),
    ]
    encoded = json.dumps(payload)
    assert "synthetic-first" not in encoded
    assert str(tmp_path) not in encoded


@pytest.mark.parametrize("ids", [
    [], ["missing"], ["first", "first"], "first", [True],
    {"first": True}, {"first"}, True, 1,
])
def test_bad_selection_fails_before_client_credentials_and_audio(monkeypatch, tmp_path, ids):
    manifest = fixture_manifest(tmp_path)
    for name in ("OpenAI", "resolve_api_key", "_wire_audio"):
        monkeypatch.setattr(
            benchmark, name,
            lambda *args, **kwargs: pytest.fail("invalid selection must not begin execution"),
        )

    with pytest.raises(ValueError):
        run(manifest, tmp_path / "unused.json", fixture_ids=ids)


def test_default_remains_all_fixtures_without_focused_scope(monkeypatch, tmp_path):
    manifest = fixture_manifest(tmp_path)
    calls = install_fake(monkeypatch)

    payload = run(manifest, tmp_path / "full.json")

    assert [row["id"] for row in payload["sessions"]] == ["first", "middle", "last"]
    assert len(calls) == 4
    assert "fixture_selection" not in payload
    assert all("wire_pcm_sha256" not in row for row in payload["sessions"])


def test_changed_manifest_cannot_report_a_digest_for_different_loaded_inputs(
    monkeypatch, tmp_path,
):
    manifest = fixture_manifest(tmp_path)
    original_load = benchmark.load_manifest

    def changed(path):
        payload = json.loads(path.read_text())
        payload["fixtures"][0]["reference_text"] = "changed during load"
        path.write_text(json.dumps(payload))
        return original_load(path)

    monkeypatch.setattr(benchmark, "load_manifest", changed)
    monkeypatch.setattr(
        benchmark, "OpenAI",
        lambda **kwargs: pytest.fail("changed manifest must not create client"),
    )

    with pytest.raises(ValueError, match="manifest changed"):
        run(manifest, tmp_path / "unused.json", fixture_ids=["first"])


def test_selection_without_warmup_records_that_it_was_not_run(monkeypatch, tmp_path):
    manifest = fixture_manifest(tmp_path)
    calls = install_fake(monkeypatch)

    payload = benchmark.run_manifest_asr_benchmark(
        manifest, output=tmp_path / "focused.json", profile="quality", sessions=1,
        warmup=False, app_home=None, base_url="http://127.0.0.1:8201/v1",
        fixture_ids=["middle"],
    )

    assert len(calls) == 1
    assert payload["fixture_selection"]["warmup_fixture_id"] is None


def test_cli_selection_requires_asr_manifest(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(
        cli, "run_realtime_benchmark",
        lambda *args, **kwargs: pytest.fail("selection must not run PCM/TTS benchmark"),
    )

    assert cli.main([
        "unused.pcm", "--asr-fixture-id", "first",
        "--profile", "quality", "--output", str(tmp_path / "unused.json"),
    ]) == 2
    assert "--asr-fixture-id requires --asr-manifest" in capsys.readouterr().err


def test_cli_passes_only_explicitly_requested_fixture_ids(monkeypatch, tmp_path):
    calls = []

    def fake(*args, **kwargs):
        calls.append(kwargs)
        return {"sessions": [], "resources": {}}

    monkeypatch.setattr(benchmark, "run_manifest_asr_benchmark", fake)

    assert cli.main([
        "--asr-manifest", str(tmp_path / "manifest.json"),
        "--asr-fixture-id", "first", "--asr-fixture-id", "last",
        "--sessions", "1", "--profile", "quality",
        "--output", str(tmp_path / "focused.json"),
    ]) == 0
    assert calls[0]["fixture_ids"] == ["first", "last"]
