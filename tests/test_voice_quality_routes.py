"""Integration tests for the voice-clone quality gates and quality-run endpoints.

S1 validate clean pass; S2 reject matrix; S3 warn + idempotency dedup + tampered
revalidate; S4 log-privacy capture; S5 bounded quality-runs.  Uses the same
fake-backend client wiring as ``tests/test_tts_voice_clone.py`` (no real models).
"""

from __future__ import annotations

import io
import json
import logging
import subprocess
import wave
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    AudioChunk,
    BatchTranscriber,
    SpeechRequest,
    TranscriptionRequest,
)
from speechrail.domain.tts import VoiceRegistry

_SAMPLE_RATE = 24_000


def _wav_from_pcm(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(_SAMPLE_RATE)
        wf.writeframes(pcm)
    return buf.getvalue()


def _sine_pcm(duration: float, amplitude: float = 0.3) -> bytes:
    n = int(duration * _SAMPLE_RATE)
    t = np.arange(n, dtype=np.float32) / _SAMPLE_RATE
    samples = np.asarray(
        np.round(amplitude * np.sin(2 * np.pi * 220 * t) * 32767), dtype="<i2"
    )
    return samples.tobytes()


def _clean_wav(duration: float = 4.0) -> bytes:
    n = int(duration * _SAMPLE_RATE)
    t = np.arange(n, dtype=np.float32) / _SAMPLE_RATE
    amp = np.full(n, 0.4, dtype=np.float32)
    period = int(0.5 * _SAMPLE_RATE)
    dip = int(0.16 * _SAMPLE_RATE)
    for start in range(period, n, period):
        amp[start : start + dip] = 0.002
    samples = np.asarray(np.round(amp * np.sin(2 * np.pi * 220 * t) * 32767), dtype="<i2")
    return _wav_from_pcm(samples.tobytes())


def _clip_wav(duration: float = 4.0) -> bytes:
    n = int(duration * _SAMPLE_RATE)
    t = np.arange(n, dtype=np.float32) / _SAMPLE_RATE
    samples = np.clip(
        np.round(1.2 * np.sin(2 * np.pi * 220 * t) * 32767), -32768, 32767
    ).astype("<i2")
    return _wav_from_pcm(samples.tobytes())


def _short_wav(duration: float = 1.0) -> bytes:
    return _wav_from_pcm(_sine_pcm(duration, amplitude=0.4))


class SineSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="quality_probe", chunk_index=0, audio=_sine_pcm(0.5)
            )

        return chunks()


class SpeedUnsupportedSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            if len(self.requests) == 1:
                # Real parent-side shape: the worker raises
                # ValueError("clone_speed_unsupported") and the error-frame path
                # re-raises it as a RuntimeError embedding the stderr tail.
                raise RuntimeError(
                    "worker_inference_error; worker stderr tail:\n"
                    "Traceback (most recent call last):\n"
                    '  File "qwen3_tts_worker.py", line 473, in _generate\n'
                    '    raise ValueError("clone_speed_unsupported")\n'
                    "ValueError: clone_speed_unsupported"
                )
            yield AudioChunk(
                response_id="quality_probe", chunk_index=0, audio=_sine_pcm(0.5)
            )

        return chunks()


class MalformedAudioSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            if len(self.requests) == 1:
                yield AudioChunk(
                    response_id="quality_probe", chunk_index=0, audio=b"\x00\x00\x00"
                )
            else:
                yield AudioChunk(
                    response_id="quality_probe", chunk_index=0, audio=_sine_pcm(0.5)
                )

        return chunks()


class GenericFailureSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            if len(self.requests) == 1:
                raise OSError("synthetic backend failure")
            yield AudioChunk(
                response_id="quality_probe", chunk_index=0, audio=_sine_pcm(0.5)
            )

        return chunks()


class SilentSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="quality_probe",
                chunk_index=0,
                audio=b"\x00\x00" * int(0.5 * _SAMPLE_RATE),
            )

        return chunks()


class ClippedOutputSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="quality_probe",
                chunk_index=0,
                audio=(np.full(int(0.5 * _SAMPLE_RATE), 32767, dtype="<i2")).tobytes(),
            )

        return chunks()


class NondeterministicSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)
        amplitude = 0.25 if len(self.requests) % 2 else 0.30

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="quality_probe",
                chunk_index=0,
                audio=_sine_pcm(0.5, amplitude=amplitude),
            )

        return chunks()




class OutOfOrderSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="quality_probe",
                chunk_index=1,
                audio=_sine_pcm(0.5),
            )

        return chunks()


class EmptySynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            # The dead branch keeps this an async generator that yields zero chunks.
            if False:  # pragma: no cover
                yield AudioChunk(response_id="quality_probe", chunk_index=0, audio=b"")

        return chunks()


class ProbeEchoTranscriber:
    def __init__(self) -> None:
        self.requests: list[TranscriptionRequest] = []
        self._text_by_id = {probe["id"]: probe["text"] for probe in vq.VOICE_QUALITY_V1_ZH_PROBES}

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.requests.append(request)
        probe_id = request.request_id.rsplit(":", 1)[-1]
        return TranscriptResult(
            request_id=request.request_id,
            model_id="quality-asr",
            text=self._text_by_id[probe_id],
            language="zh",
            duration_ms=len(request.audio) * 1000 // 32_000,
        )


class MismatchTranscriber(ProbeEchoTranscriber):
    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await super().transcribe(request)
        return result.model_copy(update={"text": "完全错误的内容"})


_DEFAULT_TRANSCRIBER = object()


def _make_client(
    tmp_path: Path,
    synthesizer: SineSynthesizer | None = None,
    *,
    batch_transcriber: BatchTranscriber | object | None = _DEFAULT_TRANSCRIBER,
) -> tuple[TestClient, VoiceRegistry, SineSynthesizer, Path]:
    preset = load_catalog().preset("quality")
    storage_path = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    settings = Settings(
        qwen3_model_dir=tmp_path / preset.asr,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / preset.tts,
        qwen3_tts_clone_model_dir=(
            tmp_path / preset.tts_clone if preset.tts_clone is not None else None
        ),
        qwen3_tts_python=None,
    )
    if synthesizer is None:
        synthesizer = SineSynthesizer()
    resolved_transcriber = (
        ProbeEchoTranscriber()
        if batch_transcriber is _DEFAULT_TRANSCRIBER
        else batch_transcriber
    )
    app = create_app(
        settings,
        tts_synthesizer=synthesizer,
        batch_transcriber=resolved_transcriber,  # type: ignore[arg-type]
    )
    return TestClient(app), registry, synthesizer, voices_dir


def _patch(registry: VoiceRegistry, wav: bytes, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)
    monkeypatch.setattr(
        "speechrail.domain.tts.transcode_and_validate_clone_audio",
        lambda *args, **kwargs: (wav, 4.0),
    )


def _clone_payload(name: str = "我的数字分身", ref_text: str = "测试参考文本") -> dict[str, str]:
    return {"name": name, "ref_text": ref_text}


# ---------------------------------------------------------------------------
# S1 — validate clean pass, never persists
# ---------------------------------------------------------------------------


def test_s1_validate_clean_pass_and_no_profile_created(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, voices_dir = _make_client(tmp_path)
    wav = _clean_wav(4.0)
    _patch(registry, wav, monkeypatch)

    resp = client.post(
        "/v1/voices/clone/validate",
        data=_clone_payload(),
        files={"audio": ("sample.wav", wav, "audio/wav")},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pass"
    assert body["policy_version"] == "voice_quality_v1"
    assert body["run_id"].startswith("vqr_")
    assert body["reference"]["duration_seconds"] > 0
    assert body["synthesis"]["probe_count"] == 0

    assert [p for p in registry.list_profiles() if not p.is_system] == []
    assert not voices_dir.exists() or list(voices_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# S2 — reject matrix (clip / short): validate 200 reject + clone 4xx envelope
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("make_wav", "expected_code"),
    [
        (_clip_wav, "clipping"),
        (_short_wav, "audio_too_short"),
    ],
)
def test_s2_reject_matrix_validate_and_clone(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    make_wav: Callable[[], bytes],
    expected_code: str,
) -> None:
    client, registry, _synth, voices_dir = _make_client(tmp_path)
    wav = make_wav()
    _patch(registry, wav, monkeypatch)

    validate = client.post(
        "/v1/voices/clone/validate",
        data=_clone_payload(ref_text="白日依山尽"),
        files={"audio": ("sample.wav", wav, "audio/wav")},
    )
    assert validate.status_code == 200
    assert validate.json()["status"] == "reject"
    assert expected_code in validate.json()["failure_codes"]

    clone = client.post(
        "/v1/voices/clone",
        data=_clone_payload(ref_text="白日依山尽", name="拒绝克隆"),
        files={"audio": ("sample.wav", wav, "audio/wav")},
    )
    assert clone.status_code == 400
    body = clone.json()
    assert body["error"]["code"] == "voice_quality_reject"
    assert "quality_report" in body
    assert body["quality_report"]["status"] == "reject"
    assert expected_code in body["quality_report"]["failure_codes"]

    assert [p for p in registry.list_profiles() if not p.is_system] == []
    assert not voices_dir.exists() or list(voices_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# B3 — the quality gate (not the raw signal validator) is the authoritative
# classifier for clipped reference audio. This exercises the REAL transcode
# path (ffmpeg is stubbed, but signal validation is NOT monkeypatched away).
# ---------------------------------------------------------------------------


def test_clip_quality_gate_is_authoritative_over_signal_validation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)
    wav = _clip_wav()
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=wav, stderr=b""),
    )

    clone = client.post(
        "/v1/voices/clone",
        data=_clone_payload(name="真实削波", ref_text="白日依山尽"),
        files={"audio": ("clip.wav", wav, "audio/wav")},
    )
    assert clone.status_code == 400
    body = clone.json()
    assert body["error"]["code"] == "voice_quality_reject"
    assert "quality_report" in body
    assert body["quality_report"]["status"] == "reject"
    assert "clipping" in body["quality_report"]["failure_codes"]

    validate = client.post(
        "/v1/voices/clone/validate",
        data=_clone_payload(ref_text="白日依山尽"),
        files={"audio": ("clip.wav", wav, "audio/wav")},
    )
    assert validate.status_code == 200
    vbody = validate.json()
    assert vbody["status"] == "reject"
    assert "clipping" in vbody["failure_codes"]

    assert [p for p in registry.list_profiles() if not p.is_system] == []


# ---------------------------------------------------------------------------
# S3 — warn clone + idempotency dedup + tampered revalidate still rejects
# ---------------------------------------------------------------------------


def test_s3_warn_clone_and_idempotency_dedup(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    wav = _clean_wav(3.0)  # warn (duration 2-4s)
    _patch(registry, wav, monkeypatch)

    payload = _clone_payload(name="轻度告警克隆", ref_text="白日依山尽，黄河入海流。")
    files = {"audio": ("sample.wav", wav, "audio/wav")}
    headers = {"Idempotency-Key": "idem-warn-001"}

    first = client.post("/v1/voices/clone", data=payload, files=files, headers=headers)
    assert first.status_code == 201
    assert first.json()["quality"]["status"] == "warn"

    second = client.post("/v1/voices/clone", data=payload, files=files, headers=headers)
    assert second.status_code == 201
    assert second.json()["id"] == first.json()["id"]

    custom = [p for p in registry.list_profiles() if not p.is_system]
    assert len(custom) == 1


def test_clone_stale_idempotency_after_delete_re_registers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    wav = _clean_wav(4.0)
    _patch(registry, wav, monkeypatch)

    payload = _clone_payload(name="过期幂等克隆", ref_text="白日依山尽，黄河入海流。")
    files = {"audio": ("sample.wav", wav, "audio/wav")}
    headers = {"Idempotency-Key": "idem-stale-001"}

    first = client.post("/v1/voices/clone", data=payload, files=files, headers=headers)
    assert first.status_code == 201
    voice_id = first.json()["id"]

    deleted = client.delete(f"/v1/voices/{voice_id}")
    assert deleted.status_code == 200

    second = client.post("/v1/voices/clone", data=payload, files=files, headers=headers)
    assert second.status_code == 201
    assert second.json()["id"] != voice_id

    custom = [p for p in registry.list_profiles() if not p.is_system]
    assert len(custom) == 1


def test_s3_tampered_revalidate_still_rejects(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    _patch(registry, _clip_wav(), monkeypatch)

    clone = client.post(
        "/v1/voices/clone",
        data=_clone_payload(name="篡改后的参考", ref_text="白日依山尽"),
        files={"audio": ("sample.wav", _clip_wav(), "audio/wav")},
    )
    assert clone.status_code == 400
    assert clone.json()["error"]["code"] == "voice_quality_reject"
    assert "clipping" in clone.json()["quality_report"]["failure_codes"]


# ---------------------------------------------------------------------------
# B1 — idempotency: bounded store, hashed ref_text, no full-profile retention
# ---------------------------------------------------------------------------


def test_idempotency_key_hashes_ref_text_and_treats_as_new_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from speechrail.http.routes import system as system_routes

    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    wav = _clean_wav(4.0)
    _patch(registry, wav, monkeypatch)

    headers = {"Idempotency-Key": "idem-reftext-001"}
    files = {"audio": ("a.wav", wav, "audio/wav")}

    first = client.post(
        "/v1/voices/clone",
        data=_clone_payload(name="同一键甲", ref_text="第一种参考文本"),
        files=files,
        headers=headers,
    )
    second = client.post(
        "/v1/voices/clone",
        data=_clone_payload(name="同一键乙", ref_text="第二种参考文本"),
        files=files,
        headers=headers,
    )

    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] != second.json()["id"]

    custom = [p for p in registry.list_profiles() if not p.is_system]
    assert len(custom) == 2

    for key in system_routes._clone_idempotency:
        assert "第一种参考文本" not in key
        assert "第二种参考文本" not in key


def test_clone_idempotency_store_is_bounded() -> None:
    from speechrail.http.routes import system as system_routes

    with system_routes._clone_idempotency_lock:
        system_routes._clone_idempotency.clear()
        for index in range(150):
            cache_key = (f"idem-bound-{index}", f"{index:064x}", f"{index:064x}")
            system_routes._store_clone_idempotency_locked(cache_key, f"id-{index}")
        assert len(system_routes._clone_idempotency) <= 128
        system_routes._clone_idempotency.clear()


# ---------------------------------------------------------------------------
# S4 — log privacy: no PCM / base64 / text / path / key
# ---------------------------------------------------------------------------


def test_s4_no_sensitive_values_in_logs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    wav = _clean_wav(4.0)
    _patch(registry, wav, monkeypatch)

    ref_text = "这是一段敏感参考文本，不应出现在日志中"
    secret_key = "idem-secret-key-042"

    with caplog.at_level(logging.INFO):
        client.post(
            "/v1/voices/clone/validate",
            data=_clone_payload(ref_text=ref_text),
            files={"audio": ("a.wav", wav, "audio/wav")},
        )
        client.post(
            "/v1/voices/clone",
            data=_clone_payload(ref_text=ref_text, name="日志隐私"),
            files={"audio": ("a.wav", wav, "audio/wav")},
            headers={"Idempotency-Key": secret_key},
        )
        client.post(
            "/v1/voices/serena/quality-runs",
            json={"probe_set": "voice_quality_v1_zh", "runs": 1},
        )

    log_text = caplog.text
    assert ref_text not in log_text
    assert secret_key not in log_text
    assert "日志隐私" not in log_text
    assert "自我介绍" not in log_text
    assert "base64" not in log_text.lower()
    assert "pcm" not in log_text.lower()
    assert ".wav" not in log_text


# ---------------------------------------------------------------------------
# S5 — quality-runs: bounded runs + unknown probe_set
# ---------------------------------------------------------------------------


def test_s5_quality_runs_ok_and_bounded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pass"
    assert body["policy_version"] == "voice_quality_v1"
    assert body["synthesis"]["probe_count"] == 18
    assert body["synthesis"]["successful_probe_count"] == 18
    assert body["synthesis"]["deterministic"] is True
    assert body["synthesis"]["intelligibility_evaluated"] is True
    assert body["synthesis"]["transcript_match"] == pytest.approx(1.0)
    assert body["failure_codes"] == []
    assert len(synth.requests) == 18




def test_quality_runs_asr_phase_uses_one_16khz_sample_per_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transcriber = ProbeEchoTranscriber()
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path,
        batch_transcriber=transcriber,
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )

    assert resp.status_code == 200
    assert resp.json()["status"] == "pass"
    assert len(transcriber.requests) == len(vq.VOICE_QUALITY_V1_ZH_PROBES)
    assert all(request.language == "zh" for request in transcriber.requests)
    assert all(request.prompt == "" for request in transcriber.requests)
    # 0.5 s generated PCM: 24 kHz -> 16 kHz = 8000 PCM16 samples = 16000 bytes.
    assert all(len(request.audio) == 16_000 for request in transcriber.requests)


def test_quality_runs_rejects_transcript_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path,
        batch_transcriber=MismatchTranscriber(),
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 2},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["intelligibility_evaluated"] is True
    assert body["synthesis"]["transcript_match"] < 0.8
    assert "transcript_mismatch" in body["failure_codes"]


def test_quality_runs_is_unevaluated_without_asr(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path,
        batch_transcriber=None,
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 2},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "unevaluated"
    assert body["synthesis"]["intelligibility_evaluated"] is False
    assert body["synthesis"]["transcript_match"] is None
    assert body["failure_codes"] == ["transcription_unavailable"]


def test_s5_quality_runs_rejects_runs_out_of_range(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 5},
    )
    assert resp.status_code == 422


def test_s5_quality_runs_rejects_unknown_probe_set(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "unknown_set", "runs": 3},
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# B4 — include_audio is declared but not supported.
# ---------------------------------------------------------------------------


def test_s5_quality_runs_include_audio_unsupported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 1, "include_audio": True},
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "include_audio_unsupported"


def test_s5_quality_runs_include_audio_false_or_omitted_ok(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    for body in (
        {"probe_set": "voice_quality_v1_zh", "runs": 1, "include_audio": False},
        {"probe_set": "voice_quality_v1_zh", "runs": 1},
    ):
        resp = client.post("/v1/voices/serena/quality-runs", json=body)
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# B2 — quality-runs classifies per-probe failures into stable failure codes
# ---------------------------------------------------------------------------


def test_quality_runs_classifies_clone_speed_unsupported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path, SpeedUnsupportedSynthesizer()
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert "clone_speed_unsupported" in body["failure_codes"]
    assert body["synthesis"]["successful_probe_count"] == 17


def test_quality_runs_classifies_output_invalid(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path, MalformedAudioSynthesizer()
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert "output_invalid" in body["failure_codes"]
    assert body["synthesis"]["successful_probe_count"] == 17


def test_quality_runs_classifies_probe_failed_and_counts_ok(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path, GenericFailureSynthesizer()
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert "probe_failed" in body["failure_codes"]
    assert body["synthesis"]["successful_probe_count"] == 17


def test_quality_runs_empty_output_is_rejected_not_counted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, synth, _voices_dir = _make_client(tmp_path, EmptySynthesizer())
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["successful_probe_count"] == 0
    assert "output_invalid" in body["failure_codes"]
    assert len(synth.requests) == 18


def test_quality_runs_rejects_silent_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path, SilentSynthesizer())
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 2},
    )
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["successful_probe_count"] == 0
    assert "output_invalid" in body["failure_codes"]


def test_quality_runs_rejects_clipped_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(tmp_path, ClippedOutputSynthesizer())
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 2},
    )
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["successful_probe_count"] == 0
    assert "output_peak_exceeded" in body["failure_codes"]


def test_quality_runs_detects_repeated_output_nondeterminism(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, _synth, _voices_dir = _make_client(
        tmp_path, NondeterministicSynthesizer()
    )
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 2},
    )
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["successful_probe_count"] == 12
    assert body["synthesis"]["deterministic"] is False
    assert "output_nondeterministic" in body["failure_codes"]


def test_quality_runs_single_run_never_claims_determinism(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 1},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "pass"
    assert body["synthesis"]["probe_count"] == 6
    assert body["synthesis"]["successful_probe_count"] == 6
    assert body["synthesis"]["deterministic"] is False
    assert "output_nondeterministic" not in body["failure_codes"]
    assert len(synth.requests) == 6


def test_quality_runs_rejects_malformed_chunk_order(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    synth = OutOfOrderSynthesizer()
    client, registry, _synth, _voices_dir = _make_client(tmp_path, synth)  # type: ignore[arg-type]
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 1},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "reject"
    assert body["synthesis"]["successful_probe_count"] == 0
    assert "output_invalid" in body["failure_codes"]


def test_quality_runs_runs_every_fixed_probe_category(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, synth, _voices_dir = _make_client(tmp_path)
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 1},
    )
    assert resp.status_code == 200
    assert len(synth.requests) == 6
    assert {request.text for request in synth.requests} == {
        "请进行自我介绍",
        "今天天气真好，我们开个会吧。",
        "请先简要介绍你的工作经历和目前关注的项目，并告诉我你今天希望达成的目标，以及在执行过程中你会采用哪些优先级策略。",
        "你认为人工智能能否真正提升我们的工作效率？为什么？",
        "今天是2026年9月9日，温度是22.5℃，请你告诉我 3、6、9 的顺序。",
        "我们先来——先说第一点……然后我们再讨论第二点。",
    }


def test_quality_runs_returns_503_when_tts_not_ready(tmp_path: Path) -> None:
    preset = load_catalog().preset("quality")
    settings = Settings(
        qwen3_model_dir=tmp_path / preset.asr,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / preset.tts,
        qwen3_tts_python=None,
    )
    app = create_app(settings, tts_synthesizer=None)
    client = TestClient(app)

    resp = client.post(
        "/v1/voices/serena/quality-runs",
        json={"probe_set": "voice_quality_v1_zh", "runs": 3},
    )
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "backend_not_ready"


# ---------------------------------------------------------------------------
# The reject envelope keeps the X-SpeechRail-Error-Code header; asserted at the
# helper level because the metrics middleware consumes it before the client.
# ---------------------------------------------------------------------------


def test_reject_response_keeps_error_code_header() -> None:
    from speechrail.domain import voice_quality as vq
    from speechrail.http.routes.system import _quality_reject_response

    report = vq.make_quality_report(
        vq.VoiceQualityReference(
            duration_seconds=1.0,
            sample_rate=24_000,
            channels=1,
            speech_active_ratio=0.0,
            noise_floor_dbfs=0.0,
            estimated_snr_db=0.0,
            clipping_ratio=0.0,
            leading_silence_seconds=0.0,
            trailing_silence_seconds=0.0,
            transcript_match=None,
        ),
        vq.VoiceQualitySynthesis(
            probe_count=0,
            successful_probe_count=0,
            active_rms_dbfs=0.0,
            peak_dbfs=0.0,
            chunk_jump_p95_db=0.0,
            clipping_ratio=0.0,
            deterministic=False,
        ),
    )
    resp = _quality_reject_response("req_123", report)
    assert resp.status_code == 400
    assert resp.headers["X-SpeechRail-Error-Code"] == "voice_quality_reject"
    body = json.loads(resp.body)
    assert body["error"]["code"] == "voice_quality_reject"
    assert "quality_report" in body


@pytest.mark.anyio
async def test_oversized_probe_closes_source_before_next_probe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from speechrail.http.routes.system import _synthesize_probes

    class RetainedSynthesizer:
        def __init__(self) -> None:
            self.sources: list[AsyncIterator[AudioChunk]] = []
            self.closed = 0

        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            async def stream() -> AsyncIterator[AudioChunk]:
                try:
                    yield AudioChunk(response_id="large", chunk_index=0, audio=b"\0\0" * 8)
                finally:
                    self.closed += 1

            source = stream()
            self.sources.append(source)
            return source

    monkeypatch.setattr("speechrail.http.routes.system._MAX_QUALITY_PROBE_PCM_BYTES", 8)
    synth = RetainedSynthesizer()
    result = await _synthesize_probes(synth, "serena", 1)
    assert result[2] == 0
    assert synth.closed == len(vq.VOICE_QUALITY_V1_ZH_PROBES)


def test_asr_validation_error_does_not_log_backend_payload(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
) -> None:
    private = "private-transcript-DO-NOT-LOG /private/model/path"

    class FailingTranscriber(ProbeEchoTranscriber):
        async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
            raise RuntimeError(private)

    client, registry, _, _ = _make_client(tmp_path, batch_transcriber=FailingTranscriber())
    monkeypatch.setattr("speechrail.http.routes.system.get_voice_registry", lambda: registry)
    with caplog.at_level(logging.WARNING):
        response = client.post("/v1/voices/serena/quality-runs", json={"runs": 1})
    assert response.status_code == 200
    assert response.json()["status"] == "unevaluated"
    assert "transcription_unavailable" in response.json()["failure_codes"]
    assert private not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)


@pytest.mark.anyio
async def test_quality_eviction_obeys_request_deadline() -> None:
    import asyncio

    from speechrail.http.routes.system import _evict_quality_tts_if_supported

    class SlowEviction(SineSynthesizer):
        cancelled = False

        async def evict_warm_capability(self) -> None:
            try:
                await asyncio.sleep(0.3)
            except asyncio.CancelledError:
                self.cancelled = True
                raise

    synth = SlowEviction()
    with pytest.raises(TimeoutError):
        await _evict_quality_tts_if_supported(
            synth, expires_at=asyncio.get_running_loop().time() + 0.02,
        )
    assert synth.cancelled
