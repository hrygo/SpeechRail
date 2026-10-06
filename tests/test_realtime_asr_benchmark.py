"""ASR evidence rejects plausible transcripts with broken audio ownership."""

import base64
import json
import queue
import sys
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_realtime_json as realtime_json_cli
from examples.perf import realtime_asr_benchmark as asr_benchmark
from examples.perf.realtime_asr_benchmark import (
    ASREvidence,
    _session_update,
    _validated_policy_echo,
    _wire_audio,
    run_manifest_asr_benchmark,
)

from speechrail.compatibility.openai_realtime import apply_session_update


def boundary(item, start, end):
    return {
        "type": "speechrail.transcription.segment_closed", "item_id": item,
        "sample_span": {"start": start, "end": end},
    }


def terminal(item, text):
    return {
        "type": "conversation.item.input_audio_transcription.completed",
        "item_id": item, "transcript": text,
    }


def receipt(samples):
    return {
        "type": "speechrail.input_audio_buffer.committed",
        "commit_event_id": "benchmark-final", "accepted_samples": samples,
    }


def test_out_of_order_finals_are_scored_in_audio_order_and_empty_final_is_success():
    evidence = ASREvidence(require_boundaries=True)
    evidence.consume(boundary("first", 0, 2), 1)
    evidence.consume(boundary("empty", 2, 3), 2)
    evidence.consume(boundary("last", 3, 5), 3)
    evidence.consume(terminal("last", "乙"), 4)
    evidence.consume(terminal("first", "甲"), 5)
    evidence.consume(terminal("empty", ""), 6)
    evidence.consume(receipt(5), 7)
    result = evidence.score("甲乙", expected_wire_samples=5)
    assert result["cer"] == 0
    assert result["terminal_count"] == 3
    assert result["sample_coverage_gate"] == "pass"
    assert "甲" not in json.dumps(result, ensure_ascii=False)


@pytest.mark.parametrize("bad_span", [(3, 4), (1, 4)])
def test_gap_or_overlap_fails_even_with_correct_text(bad_span):
    evidence = ASREvidence(require_boundaries=True)
    evidence.consume(boundary("first", 0, 2), 1)
    evidence.consume(boundary("last", *bad_span), 2)
    evidence.consume(terminal("first", "甲"), 3)
    evidence.consume(terminal("last", "乙"), 4)
    evidence.consume(receipt(4), 5)
    with pytest.raises(ValueError, match="gap"):
        evidence.score("甲乙", expected_wire_samples=4)


@pytest.mark.parametrize("resource_only", [False, True])
def test_contiguous_coverage_rejects_a_boundary_shifted_past_the_segment_budget(resource_only):
    evidence = ASREvidence(require_boundaries=True, resource_only=resource_only)
    evidence.consume(boundary("first", 0, 482_400), 1)
    evidence.consume(boundary("last", 482_400, 960_000), 2)
    evidence.consume(terminal("first", "甲"), 3)
    evidence.consume(terminal("last", "乙"), 4)
    evidence.consume(receipt(960_000), 5)
    with pytest.raises(ValueError, match="segment budget"):
        evidence.score(
            None if resource_only else "甲乙",
            expected_wire_samples=960_000,
            effective_max_segment_ms=20_000,
        )


@pytest.mark.parametrize("tail_samples", [0, 1, 2])
def test_segment_budget_allows_only_one_wire_sample_of_resampler_rounding(tail_samples):
    evidence = ASREvidence(require_boundaries=True, resource_only=True)
    end = 480_000 + tail_samples
    evidence.consume(boundary("item", 0, end), 1)
    evidence.consume(terminal("item", ""), 2)
    evidence.consume(receipt(end), 3)
    if tail_samples > 1:
        with pytest.raises(ValueError, match="segment budget"):
            evidence.score(
                None, expected_wire_samples=end, effective_max_segment_ms=20_000,
            )
        return
    result = evidence.score(
        None, expected_wire_samples=end, effective_max_segment_ms=20_000,
    )
    assert result["segment_budget_gate"] == "pass"


def test_duplicate_terminal_and_terminal_before_boundary_fail():
    evidence = ASREvidence(require_boundaries=True)
    with pytest.raises(ValueError, match="precedes"):
        evidence.consume(terminal("item", ""), 1)
    evidence.consume(boundary("item", 0, 1), 2)
    evidence.consume(terminal("item", ""), 3)
    with pytest.raises(ValueError, match="duplicate"):
        evidence.consume(terminal("item", ""), 4)


def test_legacy_delta_mirror_does_not_inflate_snapshot_revision_statistics():
    evidence = ASREvidence(require_boundaries=False)
    evidence.consume({
        "type": "speechrail.transcription.hypothesis",
        "utterance_id": "item", "text": "old",
    }, 1)
    evidence.consume({
        "type": "conversation.item.input_audio_transcription.delta",
        "item_id": "item", "delta": "old",
    }, 2)
    evidence.consume({
        "type": "speechrail.transcription.hypothesis",
        "utterance_id": "item", "text": "new",
    }, 3)
    assert evidence.preview_count == 2
    assert evidence.revised_characters == 3
    assert evidence.previews["item"] == "new"


def test_wire_resampling_preserves_source_duration_and_tail(tmp_path: Path):
    path = tmp_path / "sample.wav"
    pcm = (1000).to_bytes(2, "little", signed=True) * 16000
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(pcm)
    wire, duration = _wire_audio(path)
    assert duration == 1
    assert len(wire) == 48000
    assert wire == (1000).to_bytes(2, "little", signed=True) * 24000


@pytest.mark.parametrize("policy", [None, {
    "preview_interval_ms": 500, "max_segment_ms": 8000, "finalization": "full_segment",
}])
def test_benchmark_session_update_matches_production_contract(policy):
    _, config = apply_session_update(
        _session_update("zh", policy),
        session_id="test", asr_model="speechrail/qwen3-asr-1.7b",
        registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        request_timeout_ms=120000,
    )
    assert config["language"] == "zh"
    assert config["asr_policy"].max_segment_ms == (8000 if policy else 20000)


@pytest.mark.parametrize("override", [
    {"preview_interval_ms": True},
    {"preview_interval_ms": 600},
    {"effective_max_segment_ms": 8001},
    {"effective_max_segment_ms": 999},
    {"final_deadline_ms": None},
    {"final_deadline_ms": 5000},
    {"finalization": "streaming_finalize"},
])
def test_policy_echo_cannot_silently_change_the_measured_preset(override):
    requested = {
        "preview_interval_ms": 500, "max_segment_ms": 8000,
        "finalization": "full_segment", "final_deadline_ms": 10000,
    }
    echo = {**requested, "effective_max_segment_ms": 4000, **override}
    with pytest.raises(ValueError):
        _validated_policy_echo({"session": {"speechrail": {"asr": echo}}}, requested)


def test_policy_echo_records_a_valid_effective_resource_budget():
    requested = {
        "preview_interval_ms": 500, "max_segment_ms": 8000,
        "finalization": "full_segment",
    }
    echo = {**requested, "effective_max_segment_ms": 4000, "final_deadline_ms": 120000}
    assert _validated_policy_echo(
        {"session": {"speechrail": {"asr": echo}}}, requested,
    ) == echo


def test_benchmark_rejects_remote_origin_before_loading_audio_or_credentials(tmp_path):
    with pytest.raises(ValueError, match="loopback"):
        run_manifest_asr_benchmark(
            tmp_path / "unused.json", profile="quality", output=tmp_path / "new.json",
            sessions=1, warmup=True, app_home=None, base_url="https://remote.example/v1",
        )


def _reference_free_manifest(tmp_path: Path) -> Path:
    audio = tmp_path / "meeting.wav"
    audio.write_bytes(b"not decoded by manifest validation")
    manifest = tmp_path / "meeting.json"
    manifest.write_text(json.dumps({
        "fixtures": [{
            "id": "meeting-01", "kind": "asr", "path": str(audio), "language": "zh",
        }],
    }))
    return manifest


def test_manifest_without_references_remains_strict_by_default(tmp_path: Path):
    manifest = _reference_free_manifest(tmp_path)
    with pytest.raises(ValueError, match="human references"):
        run_manifest_asr_benchmark(
            manifest, profile="quality", output=tmp_path / "strict.json",
            sessions=1, warmup=False, app_home=None, base_url="http://127.0.0.1:8201/v1",
        )


def test_resource_only_evidence_keeps_spans_and_skips_all_quality_scores(monkeypatch):
    evidence = ASREvidence(require_boundaries=False, resource_only=True)
    monkeypatch.setattr(
        asr_benchmark, "character_error_metrics",
        lambda *_args, **_kwargs: pytest.fail("resource-only mode must not calculate CER"),
    )
    evidence.consume(boundary("first", 0, 2), 1)
    evidence.consume(boundary("last", 2, 5), 2)
    evidence.consume(terminal("last", "PRIVATE_TRANSCRIPT"), 3)
    evidence.consume(terminal("first", ""), 4)
    evidence.consume(receipt(5), 5)

    result = evidence.score(None, expected_wire_samples=5)

    assert result["quality_gate"] == "unset"
    assert result["sample_coverage_gate"] == "pass"
    assert result["accepted_samples"] == 5
    assert result["sample_spans"] == [
        {"item_id": "first", "start_sample": 0, "end_sample": 2},
        {"item_id": "last", "start_sample": 2, "end_sample": 5},
    ]
    assert result["terminal_count"] == result["boundary_count"] == 2
    assert "cer" not in result
    assert "PRIVATE_TRANSCRIPT" not in json.dumps(result)


def test_resource_only_evidence_still_rejects_failed_terminal():
    evidence = ASREvidence(require_boundaries=True, resource_only=True)
    evidence.consume(boundary("item", 0, 1), 1)

    with pytest.raises(RuntimeError, match="failed"):
        evidence.consume(
            {
                "type": "conversation.item.input_audio_transcription.failed",
                "item_id": "item",
                "error": {"code": "backend_timeout"},
            },
            2,
        )


def test_resource_only_manifest_keeps_resources_without_quality_claims(
    monkeypatch, tmp_path: Path,
):
    manifest = _reference_free_manifest(tmp_path)
    output = tmp_path / "resource-only.json"
    calls = []

    class FakeMonitor:
        def __init__(self, *, interval_seconds):
            assert interval_seconds == 0.25

        def start(self):
            pass

        def stop(self):
            return {"fake_resource_sample": True}

    def fake_run(_client, wire, *, language, reference, policy, resource_only):
        calls.append({
            "wire": wire, "language": language, "reference": reference,
            "policy": policy, "resource_only": resource_only,
        })
        return {
            "effective_policy": {
                "preview_interval_ms": 1_000,
                "max_segment_ms": 20_000,
                "effective_max_segment_ms": 10_000,
                "finalization": "full_segment",
                "final_deadline_ms": 120_000,
            },
            "quality_gate": "unset",
            "resource_evidence": {
                "terminal_count": 1,
                "boundary_count": 1,
                "accepted_samples": 4_800,
                "sample_coverage_gate": "pass",
            },
        }

    monkeypatch.setattr(asr_benchmark, "OpenAI", lambda **_kwargs: object())
    monkeypatch.setattr(asr_benchmark, "resolve_api_key", lambda **_kwargs: None)
    monkeypatch.setattr(asr_benchmark, "_wire_audio", lambda _path: (b"\x00" * 9_600, 0.2))
    monkeypatch.setattr(asr_benchmark, "_run_asr", fake_run)
    monkeypatch.setattr(asr_benchmark, "ProcessResourceMonitor", FakeMonitor)
    monkeypatch.setattr(
        asr_benchmark,
        "_normalise_resources",
        lambda _raw: {
            "simultaneous_peak": {"phys_footprint_bytes": 12_345},
            "sampling_complete": True,
        },
    )

    payload = run_manifest_asr_benchmark(
        manifest, profile="quality", output=output, sessions=1, warmup=False,
        app_home=None, base_url="http://127.0.0.1:8201/v1", resource_only=True,
    )

    assert calls == [{
        "wire": b"\x00" * 9_600, "language": "zh", "reference": None,
        "policy": None, "resource_only": True,
    }]
    assert payload["evidence_mode"] == "real"
    assert payload["measurement_mode"] == "resource_only"
    assert payload["quality_gate"] == "unset"
    assert payload["sessions"][0]["quality_gate"] == "unset"
    assert "quality_metrics" not in payload["sessions"][0]
    assert "cer" not in json.dumps(payload)
    resources = payload["resources"]
    assert resources["simultaneous_peak"]["phys_footprint_bytes"] == 12_345
    assert json.loads(output.read_text()) == payload


def test_resource_only_asr_run_keeps_pacing_policy_echo_and_exact_barrier(monkeypatch):
    class FakeConnection:
        def __init__(self):
            self.inbound = queue.Queue()
            self.sent = []
            self.inbound.put({"type": "session.created"})

        def send(self, event):
            self.sent.append(event)
            if event["type"] == "session.update":
                self.inbound.put({
                    "type": "session.updated",
                    "session": {
                        "speechrail": {
                            "asr": {
                                "preview_interval_ms": 1_000,
                                "max_segment_ms": 20_000,
                                "effective_max_segment_ms": 10_000,
                                "finalization": "full_segment",
                                "final_deadline_ms": 120_000,
                            },
                        },
                    },
                })
            elif event["type"] == "input_audio_buffer.commit":
                for result in (
                    boundary("first", 0, 2_400),
                    boundary("last", 2_400, 4_800),
                    terminal("last", "PRIVATE_TRANSCRIPT"),
                    terminal("first", ""),
                    receipt(4_800),
                ):
                    self.inbound.put(result)

        def recv(self):
            event = self.inbound.get(timeout=2)
            if event is None:
                raise RuntimeError("fake connection closed")
            return event

        def close(self):
            self.inbound.put(None)

    connection = FakeConnection()

    class FakeRealtime:
        def connect(self, *, model):
            assert model == "whisper-1"
            return self

        def enter(self):
            return connection

    class FakeClient:
        realtime = FakeRealtime()

    sleeps = []
    monkeypatch.setattr(asr_benchmark.time, "sleep", sleeps.append)
    wire = b"\x01\x02" * 4_800

    result = asr_benchmark._run_asr(
        FakeClient(), wire, language="zh", reference=None, policy=None, resource_only=True,
    )

    appends = [
        event for event in connection.sent
        if event["type"] == "input_audio_buffer.append"
    ]
    assert [len(base64.b64decode(event["audio"])) for event in appends] == [4_800, 4_800]
    assert b"".join(base64.b64decode(event["audio"]) for event in appends) == wire
    assert any(delay >= 0.05 for delay in sleeps)
    assert result["effective_policy"]["effective_max_segment_ms"] == 10_000
    assert result["quality_gate"] == "unset"
    assert "quality_metrics" not in result
    assert result["resource_evidence"]["sample_spans"] == [
        {"item_id": "first", "start_sample": 0, "end_sample": 2_400},
        {"item_id": "last", "start_sample": 2_400, "end_sample": 4_800},
    ]
    assert result["resource_evidence"]["accepted_samples"] == 4_800
    assert result["resource_evidence"]["segment_budget_gate"] == "pass"
    assert "PRIVATE_TRANSCRIPT" not in json.dumps(result)


def test_cli_resource_only_requires_asr_manifest(monkeypatch, capsys, tmp_path: Path):
    monkeypatch.setattr(
        realtime_json_cli,
        "run_realtime_benchmark",
        lambda *_args, **_kwargs: pytest.fail("resource-only must not run the PCM/TTS benchmark"),
    )

    result = realtime_json_cli.main([
        "unused.pcm",
        "--profile", "quality",
        "--output", str(tmp_path / "unused.json"),
        "--asr-resource-only",
    ])

    assert result == 2
    assert "--asr-manifest" in capsys.readouterr().err


def test_cli_resource_only_dispatches_to_manifest_runner(monkeypatch, capsys, tmp_path: Path):
    calls = []

    def fake_manifest(*args, **kwargs):
        calls.append((args, kwargs))
        return {"resources": {"sampling_complete": True}, "sessions": [{}]}

    monkeypatch.setattr(asr_benchmark, "run_manifest_asr_benchmark", fake_manifest)

    result = realtime_json_cli.main([
        "--asr-manifest", str(tmp_path / "manifest.json"),
        "--asr-resource-only",
        "--profile", "quality",
        "--output", str(tmp_path / "resource-only.json"),
    ])

    assert result == 0
    assert calls[0][1]["resource_only"] is True
    assert capsys.readouterr().err.startswith("wrote ")
