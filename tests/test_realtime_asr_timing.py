"""Client timing observations must not invent acoustic speech-end latency."""
import hashlib
import json
import math
import queue
import struct
import sys
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import realtime_asr_benchmark as benchmark


def timings(**overrides):
    evidence = benchmark.ASREvidence(require_boundaries=True)
    evidence.first_preview_at = 1000.2
    evidence.last_terminal_at = 1001.4
    evidence.receipt_at = 1002.2
    observations = {
        "started": 1000.0,
        "last_upload_started": 1000.9,
        "last_upload_completed": 1001.2,
        "playback_wait_completed": 1001.25,
        "committed_at": 1001.5,
        "commit_send_completed": 1001.6,
        "wire_samples": 24000,
    }
    for key, value in overrides.items():
        if key in {"first_preview_at", "last_terminal_at", "receipt_at"}:
            setattr(evidence, key, value)
        else:
            observations[key] = value
    return benchmark._timing_metrics(evidence, **observations)


def test_terminal_before_commit_keeps_signed_difference():
    result = timings()
    assert result["commit_to_last_terminal_seconds"] == pytest.approx(-0.1)
    assert result["last_upload_to_last_terminal_seconds"] == pytest.approx(0.2)
    assert result["nominal_playback_end_to_last_terminal_seconds"] == pytest.approx(0.4)
    assert result["barrier_seconds"] == pytest.approx(0.7)
    assert "last_audio_to_final_seconds" not in result


def test_terminal_during_last_upload_keeps_signed_difference():
    result = timings(last_terminal_at=1001.0)
    assert result["last_upload_to_last_terminal_seconds"] == pytest.approx(-0.2)
    assert result["commit_to_last_terminal_seconds"] == pytest.approx(-0.5)


def test_offsets_retain_zero_timestamps_and_no_preview_is_optional():
    result = timings(
        started=0.0, last_upload_started=0.0, last_upload_completed=0.0,
        playback_wait_completed=0.1, committed_at=0.2, commit_send_completed=0.2,
        first_preview_at=0.0, last_terminal_at=0.0, receipt_at=0.3,
        wire_samples=2400,
    )
    assert result["first_preview_seconds"] == 0.0
    assert result["commit_to_last_terminal_seconds"] == pytest.approx(-0.2)
    assert result["nominal_playback_end_to_last_terminal_seconds"] == pytest.approx(-0.1)
    assert timings(first_preview_at=None)["first_preview_seconds"] is None


def test_observations_are_relative_and_keep_acoustic_end_unobserved():
    result = timings()
    observed = result["timing_observations"]
    assert observed["clock"] == "monotonic"
    assert observed["origin"] == "paced_playback_start"
    assert observed["acoustic_speech_end"] == "not_observed"
    assert observed["last_upload_completed_seconds"] == pytest.approx(1.2)
    assert observed["nominal_playback_end_seconds"] == pytest.approx(1.0)
    assert observed["last_terminal_received_seconds"] == pytest.approx(1.4)
    assert all(
        math.isfinite(value)
        for key, value in observed.items()
        if key.endswith("_seconds")
    )
    assert "speech_end_to_final_seconds" not in result
    assert "transcript" not in json.dumps(result)


@pytest.mark.parametrize(
    "overrides",
    [
        {"last_terminal_at": None},
        {"receipt_at": None},
        {"last_upload_completed": None},
        {"committed_at": float("inf")},
        {"first_preview_at": float("nan")},
        {"last_terminal_at": True},
        {"wire_samples": True},
        {"wire_samples": 0},
    ],
)
def test_missing_or_invalid_timing_observations_fail_closed(overrides):
    with pytest.raises(ValueError, match="ASR timing"):
        timings(**overrides)


@pytest.mark.parametrize(
    "overrides",
    [
        {"last_upload_completed": 1000.8},
        {"playback_wait_completed": 1001.1},
        {"commit_send_completed": 1001.4},
        {"last_terminal_at": 999.9},
        {"receipt_at": 1001.3},
    ],
)
def test_impossible_clock_order_fails_closed(overrides):
    with pytest.raises(ValueError, match="ASR timing order"):
        timings(**overrides)


def test_run_records_actual_last_packet_and_explicit_timing_names(monkeypatch):
    class Connection:
        def __init__(self):
            self.inbound = queue.Queue()
            self.inbound.put({"type": "session.created"})
            self.sent = []

        def send(self, event):
            self.sent.append(event)
            if event["type"] == "session.update":
                self.inbound.put({
                    "type": "session.updated",
                    "session": {"speechrail": {"asr": {
                        "preview_interval_ms": 1000, "max_segment_ms": 20000,
                        "effective_max_segment_ms": 20000,
                        "finalization": "full_segment",
                        "final_deadline_ms": 120000, "rollback_tokens": 5,
                    }}},
                })
            elif event["type"] == "input_audio_buffer.commit":
                for message in [
                    {"type": "speechrail.transcription.segment_closed",
                     "item_id": "only", "sample_span": {"start": 0, "end": 2501}},
                    {"type": "conversation.item.input_audio_transcription.completed",
                     "item_id": "only", "transcript": "PRIVATE_TRANSCRIPT"},
                    {"type": "speechrail.input_audio_buffer.committed",
                     "commit_event_id": "benchmark-final", "accepted_samples": 2501},
                ]:
                    self.inbound.put(message)

        def recv(self):
            message = self.inbound.get(timeout=2)
            if message is None:
                raise RuntimeError("fake connection closed")
            return message

        def close(self):
            self.inbound.put(None)

    connection = Connection()

    class Realtime:
        def connect(self, *, model):
            return self

        def enter(self):
            return connection

    class Client:
        realtime = Realtime()

    monkeypatch.setattr(benchmark.time, "sleep", lambda _: None)
    result = benchmark._run_asr(
        Client(), b"\0\0" * 2501, language="zh", reference=None,
        policy=None, resource_only=True,
    )
    assert result["last_upload_sample_span"] == {"start": 2400, "end": 2501}
    observed = result["timing_observations"]
    assert observed["last_upload_started_seconds"] <= observed["last_upload_completed_seconds"]
    assert result["commit_to_last_terminal_seconds"] == pytest.approx(
        observed["last_terminal_received_seconds"] - observed["commit_send_started_seconds"],
    )
    assert result["last_upload_to_last_terminal_seconds"] == pytest.approx(
        observed["last_terminal_received_seconds"] - observed["last_upload_completed_seconds"],
    )
    assert "last_audio_to_final_seconds" not in result
    assert "PRIVATE_TRANSCRIPT" not in json.dumps(result)


@pytest.mark.parametrize("wire", [b"", b"\0"])
def test_empty_or_odd_wire_fails_before_opening_transport(wire):
    with pytest.raises(ValueError, match="nonempty PCM16"):
        benchmark._run_asr(
            object(), wire, language="zh", reference=None,
            policy=None, resource_only=True,
        )


def test_manifest_report_versions_timing_and_preserves_signed_values(monkeypatch, tmp_path):
    audio = tmp_path / "synthetic.wav"
    with wave.open(str(audio), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(16000)
        stream.writeframes(b"\0\0" * 16000)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({
        "schema_version": 1,
        "fixtures": [{
            "id": "synthetic", "kind": "asr", "path": str(audio),
            "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
            "language": "zh",
        }],
    }))

    class Monitor:
        def __init__(self, **_kwargs):
            pass

        def start(self):
            pass

        def stop(self):
            return {}

    monkeypatch.setattr(benchmark, "OpenAI", lambda **_kwargs: object())
    monkeypatch.setattr(benchmark, "resolve_api_key", lambda **_kwargs: None)
    monkeypatch.setattr(benchmark, "ProcessResourceMonitor", Monitor)
    monkeypatch.setattr(benchmark, "_normalise_resources", lambda _: {"sampling_complete": True})
    monkeypatch.setattr(benchmark, "_run_asr", lambda *_args, **_kwargs: {
        "audio_seconds": 1.0, "commit_to_last_terminal_seconds": -0.1,
        "last_upload_to_last_terminal_seconds": 0.2,
        "nominal_playback_end_to_last_terminal_seconds": 0.4,
        "barrier_seconds": 0.7, "quality_gate": "unset",
        "resource_evidence": {"accepted_samples": 24000},
    })
    output = tmp_path / "result.json"
    result = benchmark.run_manifest_asr_benchmark(
        manifest, profile="quality", output=output, sessions=1,
        warmup=False, app_home=None, base_url="http://127.0.0.1:8201/v1",
        resource_only=True,
    )
    assert result["schema_version"] == 2
    assert result["timing_definitions"]["acoustic_speech_end"] == "not_observed"
    assert "signed" in result["timing_definitions"]["commit_to_last_terminal_seconds"]
    assert "last_audio_to_final_seconds" not in result["timing_definitions"]
    assert json.loads(output.read_text())["sessions"][0]["commit_to_last_terminal_seconds"] == -0.1


@pytest.mark.parametrize("missing_bytes", [1, 2, 12])
def test_wire_audio_rejects_truncated_pcm_even_when_header_is_readable(tmp_path, missing_bytes):
    audio = tmp_path / "truncated.wav"
    with wave.open(str(audio), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(16000)
        stream.writeframes(b"\0\0" * 160)
    audio.write_bytes(audio.read_bytes()[:-missing_bytes])
    with pytest.raises(ValueError, match="PCM length differs from its declared frame count"):
        benchmark._wire_audio(audio)


def test_wire_audio_rejects_declared_half_sample(tmp_path):
    audio = tmp_path / "half-sample.wav"
    with wave.open(str(audio), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(16000)
        stream.writeframes(b"\0\0" * 160)
    malformed = bytearray(audio.read_bytes()) + b"\0"
    assert malformed[36:40] == b"data"
    struct.pack_into("<I", malformed, 4, len(malformed) - 8)
    struct.pack_into("<I", malformed, 40, 321)
    audio.write_bytes(malformed)
    with pytest.raises(ValueError, match="PCM length differs from its declared frame count"):
        benchmark._wire_audio(audio)
