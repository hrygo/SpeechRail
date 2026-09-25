"""VoiceDesign reference generation creates a private candidate, not a voice.

These tests cover the generation stage: the canonical reference asset, the
quality/ASR self-check, store safety, and the guarantees that nothing is
published and no existing voice is touched. The confirm/validate/publish
lifecycle is covered by ``test_voice_design_workflow.py``.
"""

from __future__ import annotations

import hashlib
import io
import json
import wave
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.application import voice_design as voice_design_application
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest
from speechrail.domain.tts import VoiceRegistry
from speechrail.http.routes import voice_designs as voice_designs_module

TEXT = "这是用于音色注册的测试语句，请保持自然清晰的表达。"
VOICE_ID = "designed_base"


def speech_like_pcm(seconds: float = 4.0, sample_rate: int = 24_000) -> bytes:
    timeline = np.arange(int(seconds * sample_rate), dtype=np.float32) / sample_rate
    amplitude = np.where((timeline % 0.5) < 0.16, 0.002, 0.4)
    samples = np.round(amplitude * np.sin(2 * np.pi * 220 * timeline) * 32767)
    return samples.astype("<i2").tobytes()


class DesignSynth:
    """Fake VoiceDesign/Base backend recording every synthesis request."""

    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []
        self.events: list[str] = []
        self.pcm = speech_like_pcm()
        self.closed = 0

    def _stream(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)
        payload = self.pcm

        async def stream() -> AsyncIterator[AudioChunk]:
            self.events.append("tts")
            try:
                yield AudioChunk(response_id="design", chunk_index=0, audio=payload)
            finally:
                self.closed += 1
                self.events.append("tts.closed")

        return stream()

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        return self._stream(request)

    def synthesize_design(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        return self._stream(request)

    async def evict_warm_capability(self) -> None:
        self.events.append("tts.evicted")


class DesignAsr:
    def __init__(self, synth: DesignSynth) -> None:
        self.synth = synth
        self.text = TEXT
        self.requests: list[TranscriptionRequest] = []
        self.fail = False

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.requests.append(request)
        self.synth.events.append("asr")
        if self.fail:
            raise RuntimeError("private-backend-payload-must-not-leak")
        return TranscriptResult(
            request_id=request.request_id,
            model_id="fake-asr",
            text=self.text,
            duration_ms=0,
        )


def make_client(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    tier: str = "reference",
    with_asr: bool = True,
    with_base: bool = True,
    api_key: str | None = None,
) -> tuple[TestClient, VoiceRegistry, DesignSynth, DesignAsr]:
    asr_key = required_spec_artifact(tier, "asr")
    tts_key = required_spec_artifact(tier, "tts_custom_voice")
    base_key = required_spec_artifact(tier, "tts_base")
    design_key = required_spec_artifact(tier, "voice_design")
    assert asr_key is not None and tts_key is not None
    registry = VoiceRegistry(
        storage_path=tmp_path / "voices.json",
        voices_dir=tmp_path / "voices",
    )
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", registry)
    synth = DesignSynth()
    asr = DesignAsr(synth)
    settings = Settings(
        qwen3_model_dir=tmp_path / asr_key,
        asr_resident_bytes=1 * 1024**3,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / tts_key,
        tts_resident_bytes=1 * 1024**3,
        qwen3_tts_clone_model_dir=(
            tmp_path / base_key if with_base and base_key is not None else None
        ),
        qwen3_tts_design_model_dir=tmp_path / design_key if design_key else None,
        qwen3_tts_python=None,
        selection_schema_version=2,
        selection_asr_spec=tier,
        selection_tts_spec=tier,
        asr_artifact_key=asr_key,
        tts_artifact_key=tts_key,
        tts_base_artifact_key=base_key if with_base else None,
        voice_design_artifact_key=design_key,
        api_key=api_key,
    )
    app = create_app(
        settings,
        tts_synthesizer=synth,
        batch_transcriber=asr if with_asr else None,
    )
    return TestClient(app), registry, synth, asr


def payload(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "voice_id": VOICE_ID,
        "name": "Test voice",
        "instruction": "清晰自然的中文声音",
        "reference_text": TEXT,
        "seed": 123,
    }
    body.update(overrides)
    return body


def candidate_assets(registry: VoiceRegistry) -> Path:
    return registry.storage_path.with_name("voice_design_candidates")


def test_create_candidate_keeps_reference_private_and_unpublished(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    original = registry.create_custom_profile("Original", "原始音色描述", "original")
    before = original.to_dict()

    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 201, response.text
    candidate = response.json()["candidate"]
    assert candidate["state"] == "generated"
    assert candidate["publishable"] is False
    assert candidate["reference"]["quality"]["transcript_match"] == 1.0
    assert candidate["reference"]["quality"]["synthesis"]["probe_count"] == 0
    assert VOICE_ID not in {
        entry["id"] for entry in client.get("/v1/voices").json()["data"]
    }
    assert registry.get_profile("original").to_dict() == before

    # Only safe metadata is projected: no text, no private paths.
    assert TEXT not in response.text
    assert str(tmp_path) not in response.text

    asset = candidate_assets(registry) / f"{candidate['id']}.wav"
    assert asset.is_file()
    assert asset.stat().st_mode & 0o777 == 0o600
    assert (
        candidate["reference"]["audio_sha256"]
        == hashlib.sha256(asset.read_bytes()).hexdigest()
    )
    with wave.open(io.BytesIO(asset.read_bytes()), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (
            1,
            2,
            24_000,
        )

    assert synth.events == ["tts", "tts.closed", "tts.evicted", "asr"]
    assert synth.requests[0].instruction == "清晰自然的中文声音"
    assert synth.requests[0].seed == 123
    assert asr.requests[0].prompt == ""

    reloaded = voice_designs_module._repository().get(candidate["id"])
    assert reloaded.target_voice_id == VOICE_ID
    assert reloaded.reference_text == TEXT
    assert reloaded.revision == candidate["revision"]


@pytest.mark.parametrize("tier", ["fast", "quality"])
def test_create_requires_voice_design_selection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    tier: str,
) -> None:
    client, registry, synth, _asr = make_client(tmp_path, monkeypatch, tier=tier)
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_design_unsupported"
    assert not synth.requests
    assert all(profile.is_system for profile in registry.list_profiles())
    assert not candidate_assets(registry).exists()


def test_create_requires_batch_asr_before_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, _asr = make_client(tmp_path, monkeypatch, with_asr=False)
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "transcription_unavailable"
    assert not synth.requests
    assert all(profile.is_system for profile in registry.list_profiles())


@pytest.mark.parametrize(
    "kind",
    ["silence", "clipping", "short", "oversize", "malformed"],
)
def test_create_invalid_audio_stores_no_candidate(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    kind: str,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    synth.pcm = {
        "silence": b"\0\0" * 96_000,
        "clipping": b"\xff\x7f" * 96_000,
        "short": synth.pcm[:1000],
        "oversize": synth.pcm * 8,
        "malformed": b"\0\0\0",
    }[kind]
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code in (400, 502), response.text
    assert all(profile.is_system for profile in registry.list_profiles())
    assert not asr.requests
    assert synth.closed == 1
    assert not list(candidate_assets(registry).glob("*.wav"))
    assert not list((tmp_path / "voices").glob("*.wav"))


def test_create_asr_failure_is_private_and_stores_no_candidate(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    asr.fail = True
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "transcription_unavailable"
    assert "private-backend-payload" not in response.text + caplog.text
    assert all(profile.is_system for profile in registry.list_profiles())
    assert not list(candidate_assets(registry).glob("*.wav"))


@pytest.mark.parametrize(
    "change",
    [
        {"voice_id": "../escape"},
        {"voice_id": "alloy"},
        {"voice_id": "serena"},
        {"seed": True},
        {"seed": -1},
        {"seed": 2**32},
        {"instruction": " "},
        {"reference_text": " "},
        {"reference_text": "a" * 241},
        {"audio_url": "https://invalid.example/audio"},
        {"language": "en"},
        {"name": ""},
    ],
)
def test_create_rejects_invalid_fields_before_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    change: dict[str, object],
) -> None:
    client, _registry, synth, _asr = make_client(tmp_path, monkeypatch)
    response = client.post("/v1/voice-designs", json=payload(**change))
    assert response.status_code in (400, 409, 422), response.text
    assert not synth.requests


@pytest.mark.parametrize("text", ["*" * 20, "a" * 240])
def test_create_rejects_out_of_bounds_normalized_text(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    text: str,
) -> None:
    client, _registry, synth, _asr = make_client(tmp_path, monkeypatch)
    response = client.post("/v1/voice-designs", json=payload(reference_text=text))
    assert response.status_code == 422
    assert not synth.requests


def test_create_conflict_preserves_existing_voice(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, _asr = make_client(tmp_path, monkeypatch)
    original = registry.create_custom_profile("Keep", "Keep", VOICE_ID)
    stored = (tmp_path / "voices.json").read_bytes()

    response = client.post("/v1/voice-designs", json=payload())

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "voice_already_exists"
    assert registry.get_profile(original.id) == original
    assert (tmp_path / "voices.json").read_bytes() == stored
    assert not synth.requests


def test_create_that_loses_a_race_stays_private_and_keeps_the_competitor(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    original_transcribe = asr.transcribe

    async def competing_registration(request: TranscriptionRequest) -> TranscriptResult:
        result = await original_transcribe(request)
        registry.create_custom_profile("Concurrent", "Keep this", VOICE_ID)
        return result

    monkeypatch.setattr(asr, "transcribe", competing_registration)
    response = client.post("/v1/voice-designs", json=payload())

    # Generation never takes the publication lock, so the concurrent voice is
    # never overwritten and the candidate stays private until an explicit
    # publish that will refuse the revision mismatch.
    assert response.status_code == 201, response.text
    candidate_id = response.json()["candidate"]["id"]
    assert registry.get_profile(VOICE_ID).instruction == "Keep this"
    stored = voice_designs_module._repository().get(candidate_id)
    assert stored.target_voice_id == VOICE_ID
    assert stored.state == "generated"


def test_create_store_failure_removes_candidate_audio(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, _asr = make_client(tmp_path, monkeypatch)

    def fail_write(_path: object, _payload: object) -> None:
        raise OSError("private-write-path")

    monkeypatch.setattr(
        voice_design_application, "_atomic_write_json", fail_write
    )
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "voice_design_store_unavailable"
    assert "private-write-path" not in response.text
    assert not list(candidate_assets(registry).glob("*.wav"))
    assert all(profile.is_system for profile in registry.list_profiles())


def test_create_authentication_precedes_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, synth, _asr = make_client(
        tmp_path, monkeypatch, api_key="test-key-only"
    )
    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 401
    assert not synth.requests


def test_create_openapi_response_matches_published_schema(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import jsonschema
    import yaml

    client, _registry, _synth, _asr = make_client(tmp_path, monkeypatch)
    contract = yaml.safe_load(
        (Path(__file__).parents[1] / "contracts/openapi.yaml").read_text()
    )
    path = contract["paths"]["/v1/voice-designs"]["post"]
    response_ref = path["responses"]["201"]["content"]["application/json"]["schema"]
    schema = {**response_ref, "components": contract["components"]}
    jsonschema.Draft202012Validator.check_schema(schema)

    response = client.post("/v1/voice-designs", json=payload())
    assert response.status_code == 201
    jsonschema.Draft202012Validator(schema).validate(response.json())
    assert "201" in client.app.openapi()["paths"]["/v1/voice-designs"]["post"]["responses"]


def test_design_store_projection_hides_reference_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, _synth, _asr = make_client(tmp_path, monkeypatch)
    assert client.post("/v1/voice-designs", json=payload()).status_code == 201

    listed = client.get("/v1/voice-designs")
    assert listed.status_code == 200
    rendered = json.dumps(listed.json(), ensure_ascii=False)
    assert TEXT not in rendered
    assert "reference_audio_path" not in rendered
    assert "instruction_sha256" not in rendered


def test_registry_create_only_is_atomic_in_concurrent_calls(tmp_path: Path) -> None:
    from concurrent.futures import ThreadPoolExecutor

    from speechrail.domain.tts import VoiceAlreadyExistsError

    registry = VoiceRegistry(
        storage_path=tmp_path / "voices.json",
        voices_dir=tmp_path / "voices",
    )

    def create(index: int) -> bool:
        try:
            registry.create_cloned_profile(
                name=f"Candidate {index}",
                ref_text=TEXT,
                audio_bytes=b"synthetic",
                voice_id="unique",
                duration_seconds=4.0,
                create_only=True,
            )
        except VoiceAlreadyExistsError:
            return False
        return True

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(create, [1, 2]))
    assert sum(results) == 1
    assert len(list((tmp_path / "voices").glob("*.wav"))) == 1
