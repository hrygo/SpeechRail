"""Prompt -> canonical reference -> Base binding, without real model downloads."""

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
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest
from speechrail.domain.tts import VoiceRegistry

TEXT = "这是用于音色注册的测试语句，请保持自然清晰的表达。"


class DesignSynth:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []
        self.events: list[str] = []
        t = np.arange(4 * 24_000, dtype=np.float32) / 24_000
        amplitude = np.where((t % 0.5) < 0.16, 0.002, 0.4)
        self.pcm = np.round(amplitude * np.sin(2 * np.pi * 220 * t) * 32767).astype("<i2").tobytes()
        self.closed = 0

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def stream() -> AsyncIterator[AudioChunk]:
            self.events.append("tts")
            try:
                yield AudioChunk(response_id="design", chunk_index=0, audio=self.pcm)
            finally:
                self.closed += 1
                self.events.append("tts.closed")

        return stream()

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
        assert self.synth.events[-2] == "tts.evicted"
        if self.fail:
            raise RuntimeError("private-backend-payload-must-not-leak")
        return TranscriptResult(
            request_id=request.request_id,
            model_id="fake-asr",
            text=self.text,
            duration_ms=len(request.audio) * 1000 // 32_000,
        )


def make_client(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    tier: str = "quality",
    with_asr: bool = True,
    api_key: str | None = None,
) -> tuple[TestClient, VoiceRegistry, DesignSynth, DesignAsr]:
    preset = load_catalog().preset(tier)
    registry = VoiceRegistry(tmp_path / "voices.json", tmp_path / "voices")
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", registry)
    synth = DesignSynth()
    asr = DesignAsr(synth)
    app = create_app(
        Settings(
            qwen3_model_dir=tmp_path / preset.asr,
            qwen3_python=None,
            qwen3_tts_model_dir=tmp_path / preset.tts,
            qwen3_tts_python=None,
            qwen3_tts_clone_model_dir=tmp_path / preset.tts_clone if preset.tts_clone else None,
            api_key=api_key,
        ),
        tts_synthesizer=synth,
        batch_transcriber=asr if with_asr else None,
    )
    return TestClient(app), registry, synth, asr


def payload() -> dict[str, object]:
    return {
        "id": "designed_base",
        "name": "Test voice",
        "instruction": "清晰自然的中文声音",
        "reference_text": TEXT,
        "seed": 123,
    }


def test_design_registers_base_voice_with_verified_reference(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    original = registry.create_custom_profile("Original", "原始音色描述", "original")
    before = original.to_dict()
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 201, response.text
    data = response.json()
    assert data["synthesis_validation"] == "unevaluated"
    voice = data["voice"]
    assert voice["mode"] == "clone" and voice["variant"] == "base"
    assert voice["quality"]["reference"]["transcript_match"] == 1.0
    assert voice["quality"]["synthesis"]["probe_count"] == 0
    assert "audio_path" not in voice
    assert synth.events == ["tts", "tts.closed", "tts.evicted", "asr"]
    assert synth.requests[0].instruction == payload()["instruction"]
    assert synth.requests[0].seed == 123
    assert asr.requests[0].prompt == ""
    profile = registry.get_profile("designed_base")
    binding = resolve_binding("base", profile.id, profile=profile)
    assert binding.is_clone and binding.ref_text == TEXT
    reference = Path(binding.ref_audio_path or "")
    assert reference.stat().st_mode & 0o777 == 0o600
    assert (
        voice["creation"]["reference_audio_sha256"]
        == hashlib.sha256(reference.read_bytes()).hexdigest()
    )
    assert voice["creation"]["origin"] == "generated"
    assert voice["creation"]["seed"] == 123
    with wave.open(io.BytesIO(reference.read_bytes()), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 24_000)
    reloaded = VoiceRegistry(tmp_path / "voices.json", tmp_path / "voices")
    assert reloaded.get_profile(profile.id).to_dict() == profile.to_dict()
    assert registry.get_profile("original").to_dict() == before


@pytest.mark.parametrize("tier", ["balanced", "light"])
def test_design_requires_quality_before_any_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    tier: str,
) -> None:
    client, registry, synth, _ = make_client(tmp_path, monkeypatch, tier=tier)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_design_registration_unsupported"
    assert not synth.requests
    assert all(p.is_system for p in registry.list_profiles())


def test_design_requires_asr_before_generation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, _, synth, _ = make_client(tmp_path, monkeypatch, with_asr=False)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "transcription_unavailable"
    assert not synth.requests


@pytest.mark.parametrize("kind", ["silence", "clipping", "short", "oversize", "malformed"])
def test_design_invalid_audio_does_not_publish(
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
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code in (400, 502), response.text
    assert all(p.is_system for p in registry.list_profiles())
    assert not asr.requests
    assert synth.closed == 1
    assert not list((tmp_path / "voices").glob("*.wav"))


@pytest.mark.parametrize("text", ["", "完全错误的内容"])
def test_design_transcript_mismatch_does_not_publish(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    text: str,
) -> None:
    client, registry, _, asr = make_client(tmp_path, monkeypatch)
    asr.text = text
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "transcript_mismatch"
    assert all(p.is_system for p in registry.list_profiles())
    assert not list((tmp_path / "voices").glob("*.wav"))


def test_design_asr_failure_private_and_no_partial_voice(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    client, registry, _, asr = make_client(tmp_path, monkeypatch)
    asr.fail = True
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "transcription_unavailable"
    assert "private-backend-payload" not in response.text + caplog.text
    assert all(p.is_system for p in registry.list_profiles())


def test_design_conflict_preserves_existing_voice(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, registry, synth, _ = make_client(tmp_path, monkeypatch)
    original = registry.create_custom_profile("Keep", "Keep", "designed_base")
    stored = (tmp_path / "voices.json").read_bytes()
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "voice_already_exists"
    assert registry.get_profile(original.id) == original
    assert (tmp_path / "voices.json").read_bytes() == stored
    assert not synth.requests


@pytest.mark.parametrize(
    "change",
    [
        {"id": "../escape"},
        {"id": "alloy"},
        {"seed": True},
        {"seed": -1},
        {"seed": 2**32},
        {"instruction": " "},
        {"reference_text": " "},
        {"reference_text": "a" * 241},
        {"audio_url": "https://invalid.example/audio"},
        {"language": "en"},
    ],
)
def test_design_request_rejects_invalid_fields(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    change: dict[str, object],
) -> None:
    client, _, synth, _ = make_client(tmp_path, monkeypatch)
    response = client.post("/v1/voices/designs", json=payload() | change)
    assert response.status_code in (400, 409, 422)
    assert not synth.requests


def test_design_authentication_precedes_work(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client, _, synth, _ = make_client(tmp_path, monkeypatch, api_key="test-key-only")
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 401
    assert not synth.requests


def test_design_concurrent_target_creation_cannot_overwrite(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _, asr = make_client(tmp_path, monkeypatch)
    original_transcribe = asr.transcribe

    async def competing_registration(request: TranscriptionRequest) -> TranscriptResult:
        result = await original_transcribe(request)
        registry.create_custom_profile("Concurrent", "Keep this", "designed_base")
        return result

    monkeypatch.setattr(asr, "transcribe", competing_registration)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 409
    assert registry.get_profile("designed_base").instruction == "Keep this"
    assert not list((tmp_path / "voices").glob("*.wav"))


def test_design_failed_commit_removes_candidate_audio(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _, _ = make_client(tmp_path, monkeypatch)

    def fail_save() -> None:
        raise OSError("private-write-path")

    monkeypatch.setattr(registry, "_save_custom_voices", fail_save)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "voice_store_unavailable"
    assert "private-write-path" not in response.text
    assert not list((tmp_path / "voices").glob("*.wav"))
    assert all(p.is_system for p in registry.list_profiles())


@pytest.mark.anyio
async def test_design_cancelled_generation_closes_source() -> None:
    import asyncio

    from speechrail.http.routes.voice_designs import _generate_reference

    entered = asyncio.Event()
    finished = asyncio.Event()

    class BlockingSynth(DesignSynth):
        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            async def stream() -> AsyncIterator[AudioChunk]:
                try:
                    entered.set()
                    await asyncio.sleep(5)
                    yield AudioChunk(response_id="blocked", chunk_index=0, audio=self.pcm)
                finally:
                    finished.set()

            return stream()

    task = asyncio.create_task(
        _generate_reference(
            BlockingSynth(),
            SpeechRequest(text=TEXT, voice="serena"),
            expires_at=asyncio.get_running_loop().time() + 10,
        )
    )
    await asyncio.wait_for(entered.wait(), 1)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert finished.is_set()


def test_design_eviction_deadline_prevents_asr_and_publication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import asyncio

    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    client.app.state.settings.request_timeout_seconds = 0.1
    cancelled = []

    async def slow_eviction() -> None:
        try:
            await asyncio.sleep(5)
        finally:
            cancelled.append(True)

    monkeypatch.setattr(synth, "evict_warm_capability", slow_eviction)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_timeout"
    assert cancelled
    assert not asr.requests
    assert all(p.is_system for p in registry.list_profiles())


def test_design_queue_rejection_does_not_start_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from contextlib import asynccontextmanager

    from speechrail.runtime.resource_governor import GovernorQueueFullError, ResourceGovernor

    @asynccontextmanager
    async def full(*args: object, **kwargs: object) -> AsyncIterator[None]:
        raise GovernorQueueFullError
        yield  # pragma: no cover - makes this an async context manager.

    client, registry, synth, _ = make_client(tmp_path, monkeypatch)
    monkeypatch.setattr(ResourceGovernor, "reserve", full)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 429
    assert response.headers["Retry-After"] == "1"
    assert not synth.requests
    assert all(p.is_system for p in registry.list_profiles())


def test_design_provenance_tampering_fails_closed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:

    from speechrail.domain.tts import VoiceStoreUnavailableError

    client, registry, _, _ = make_client(tmp_path, monkeypatch)
    assert client.post("/v1/voices/designs", json=payload()).status_code == 201
    file = tmp_path / "voices.json"
    data = json.loads(file.read_text())
    data[0]["creation"]["reference_audio_sha256"] = "not-a-sha256"
    file.write_text(json.dumps(data))
    with pytest.raises(VoiceStoreUnavailableError):
        registry.get_profile("designed_base")


def test_design_provenance_rejects_reference_mismatch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _, _ = make_client(tmp_path, monkeypatch)
    assert client.post("/v1/voices/designs", json=payload()).status_code == 201
    source = registry.get_profile("designed_base")
    with pytest.raises(ValueError, match="provenance"):
        registry.create_cloned_profile(
            name="Mismatch",
            ref_text=TEXT,
            audio_bytes=b"not-the-reference",
            voice_id="other",
            duration_seconds=4.0,
            creation=source.creation,
            create_only=True,
        )
    assert len(list((tmp_path / "voices").glob("*.wav"))) == 1


def test_design_openapi_response_matches_published_schema(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import jsonschema
    import yaml

    client, _, _, _ = make_client(tmp_path, monkeypatch)
    contract = yaml.safe_load((Path(__file__).parents[1] / "contracts/openapi.yaml").read_text())
    path = contract["paths"]["/v1/voices/designs"]["post"]
    response_ref = path["responses"]["201"]["content"]["application/json"]["schema"]
    schema = {**response_ref, "components": contract["components"]}
    jsonschema.Draft202012Validator.check_schema(schema)
    response = client.post("/v1/voices/designs", json=payload())
    assert response.status_code == 201
    jsonschema.Draft202012Validator(schema).validate(response.json())
    assert "201" in client.app.openapi()["paths"]["/v1/voices/designs"]["post"]["responses"]


@pytest.mark.parametrize("text", ["*" * 20, "a" * 240])
def test_design_rejects_out_of_bounds_normalized_text(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    text: str,
) -> None:
    client, _, synth, _ = make_client(tmp_path, monkeypatch)
    response = client.post("/v1/voices/designs", json=payload() | {"reference_text": text})
    assert response.status_code == 422
    assert not synth.requests


def test_design_new_voice_works_through_existing_tts_api(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _, synth, _ = make_client(tmp_path, monkeypatch)
    assert client.post("/v1/voices/designs", json=payload()).status_code == 201
    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "tts-1",
            "voice": "designed_base",
            "input": "正常朗读。",
            "response_format": "wav",
        },
    )
    assert response.status_code == 200
    assert synth.requests[-1].voice == "designed_base"
    assert synth.requests[-1].instruction is None
    voices = client.get("/v1/voices").json()["data"]
    created = next(v for v in voices if v["id"] == "designed_base")
    assert created["capabilities"]["supports_clone"] is True
    assert created["capabilities"]["supports_instruction"] is False
    assert created["creation"]["origin"] == "generated"


def test_registry_create_only_is_atomic_in_concurrent_calls(tmp_path: Path) -> None:
    from concurrent.futures import ThreadPoolExecutor

    from speechrail.domain.tts import VoiceAlreadyExistsError

    registry = VoiceRegistry(tmp_path / "voices.json", tmp_path / "voices")

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
