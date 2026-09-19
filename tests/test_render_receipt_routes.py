from __future__ import annotations

import hashlib
from collections.abc import AsyncIterator
from pathlib import Path

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import VoiceRegistry

_PCM = b"\x01\x00\x02\x00\x03\x00"


class ReceiptSynthesizer:
    def __init__(self, *, fail: bool = False, runtime_revision: str | None = None) -> None:
        self.requests: list[SpeechRequest] = []
        self.fail = fail
        self.runtime_revision = runtime_revision

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return self.runtime_revision

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            if self.fail:
                raise RuntimeError("synthetic receipt failure")
            yield AudioChunk(
                response_id="backend-response",
                chunk_index=0,
                audio=_PCM,
            )

        return chunks()


def _client(
    tmp_path: Path,
    monkeypatch,
    *,
    fail: bool = False,
    runtime_revision: str | None = None,
) -> tuple[TestClient, ReceiptSynthesizer, str]:
    preset = load_catalog().preset("quality")
    registry = VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )
    profile = registry.create_custom_profile(
        name="Narrator",
        instruction="stable narrator",
        voice_id="narrator",
        seed=7,
    )
    assert profile.revision is not None
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY",
        registry,
    )
    synth = ReceiptSynthesizer(fail=fail, runtime_revision=runtime_revision)
    app = create_app(
        Settings(
            qwen3_model_dir=tmp_path / preset.asr,
            qwen3_python=None,
            qwen3_tts_model_dir=tmp_path / preset.tts,
            qwen3_tts_clone_model_dir=(
                tmp_path / preset.tts_clone
                if preset.tts_clone is not None
                else None
            ),
            qwen3_tts_python=None,
        ),
        tts_synthesizer=synth,
    )
    return TestClient(app), synth, profile.revision


def _payload() -> dict[str, object]:
    return {
        "model": "speechrail/qwen3-tts",
        "input": "测试渲染回执。",
        "voice": "narrator",
        "response_format": "wav",
    }


def test_v1_speech_returns_negotiated_receipt_bound_to_revision(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, revision = _client(tmp_path, monkeypatch)

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    assert response.status_code == 200
    receipt_id = response.headers["SpeechRail-Receipt-Id"]
    assert receipt_id.startswith("rr_")
    assert len(synth.requests) == 1
    assert synth.requests[0].expected_voice_revision == revision

    receipt_response = client.get(f"/v1/speechrail/audio/receipts/{receipt_id}")
    assert receipt_response.status_code == 200
    receipt = receipt_response.json()
    assert receipt["status"] == "completed"
    assert receipt["voice"] == {
        "id": "narrator",
        "revision": revision,
    }
    assert receipt["audio"]["sample_count"] == len(_PCM) // 2
    assert receipt["audio"]["pcm_sha256"] == hashlib.sha256(_PCM).hexdigest()
    assert receipt["audio"]["integrity_boundary"] == "pcm16_pre_transport"
    assert receipt["model"]["runtime_revision"] is None
    assert "测试渲染回执" not in receipt_response.text


def test_v1_receipt_binds_observed_runtime_revision(
    tmp_path: Path,
    monkeypatch,
) -> None:
    runtime_revision = "rt_" + ("d" * 64)
    client, _synth, _revision = _client(
        tmp_path,
        monkeypatch,
        runtime_revision=runtime_revision,
    )

    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    receipt_id = response.headers["SpeechRail-Receipt-Id"]

    receipt = client.get(f"/v1/speechrail/audio/receipts/{receipt_id}").json()
    assert receipt["model"]["runtime_revision"] == runtime_revision


def test_v1_accepts_namespaced_revision_pin_header(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, revision = _client(tmp_path, monkeypatch)
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Expected-Voice-Revision": revision},
    )
    assert response.status_code == 200
    assert len(synth.requests) == 1
    assert synth.requests[0].expected_voice_revision == revision
    assert "SpeechRail-Receipt-Id" not in response.headers


def test_failed_negotiated_speech_keeps_error_receipt_queryable_by_request(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, _synth, _revision = _client(tmp_path, monkeypatch, fail=True)
    response = client.post(
        "/v1/audio/speech",
        json=_payload(),
        headers={"SpeechRail-Receipt-Mode": "integrity"},
    )
    assert response.status_code == 502
    request_id = response.json()["error"]["request_id"]

    receipt_response = client.get(
        f"/v1/speechrail/audio/receipts/by-request/{request_id}"
    )
    assert receipt_response.status_code == 200
    receipt = receipt_response.json()
    assert receipt["status"] == "error"
    assert receipt["error_code"] == "backend_error"
    assert receipt["audio"]["sample_count"] == 0


def test_openai_custom_voice_object_is_accepted_on_v1_speech(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _revision = _client(tmp_path, monkeypatch)
    payload = _payload()
    payload["voice"] = {"id": "narrator"}

    response = client.post("/v1/audio/speech", json=payload)

    assert response.status_code == 200
    assert len(synth.requests) == 1
    assert synth.requests[0].voice == "narrator"
    assert "SpeechRail-Receipt-Id" not in response.headers
