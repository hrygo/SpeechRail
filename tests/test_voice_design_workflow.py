"""Voice-design candidate lifecycle: confirmed Base validation then publication.

The candidate never appears in the production voice list; publication is the
only transition that creates an immutable, routable voice revision.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import VOICE_DESIGN_ARTIFACT_KEY
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyStoreUnavailableError,
)
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest
from speechrail.domain.tts import VoiceRegistry

REFERENCE_TEXT = "这是用于音色设计的参考语句，请保持自然清晰的表达方式。"
EDITED_TEXT = "重新确认之后的参考文本，语气依旧自然清晰并且停顿合理。"
CONTROLLED_TEST_TEXT = "今天的天气很适合在公园里慢慢散步，听听周围自然的声音。"
RUNTIME_REVISION = "rt_" + "a" * 64
VOICE_ID = "designed_base"


def speech_like_pcm(seconds: float = 4.0, sample_rate: int = 24_000) -> bytes:
    """Speech-shaped synthetic PCM that passes the reference quality gate."""

    timeline = np.arange(int(seconds * sample_rate), dtype=np.float32) / sample_rate
    amplitude = np.where((timeline % 0.5) < 0.16, 0.002, 0.4)
    samples = np.round(amplitude * np.sin(2 * np.pi * 220 * timeline) * 32767)
    return samples.astype("<i2").tobytes()


class DesignSynth:
    """Fake VoiceDesign + Base backend that records every synthesis request."""

    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []
        self.events: list[str] = []
        self.pcm = speech_like_pcm()
        self.runtime_revision: str | None = RUNTIME_REVISION
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

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        return self.runtime_revision

    async def evict_warm_capability(self) -> None:
        self.events.append("tts.evicted")


class DesignAsr:
    """Fake Batch ASR whose transcript is chosen per test step."""

    def __init__(self, synth: DesignSynth) -> None:
        self.synth = synth
        self.text = REFERENCE_TEXT
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
    with_design: bool = True,
    api_key: str | None = None,
) -> tuple[TestClient, VoiceRegistry, DesignSynth, DesignAsr]:
    asr_key = required_spec_artifact(tier, "asr")
    tts_key = required_spec_artifact(tier, "tts_custom_voice")
    base_key = required_spec_artifact(tier, "tts_base")
    # VoiceDesign 是与档位无关的按需制品: 任何 tier 都用同一份设计权重。
    design_key = VOICE_DESIGN_ARTIFACT_KEY if with_design else None
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
        "name": "Designed voice",
        "instruction": "清晰自然的中文声音",
        "reference_text": REFERENCE_TEXT,
        "seed": 123,
    }
    body.update(overrides)
    return body


def create_candidate(client: TestClient, **overrides: object) -> tuple[str, dict]:
    response = client.post("/v1/voice-designs", json=payload(**overrides))
    assert response.status_code == 201, response.text
    candidate = response.json()["candidate"]
    return candidate["id"], candidate


def confirm_candidate(
    client: TestClient,
    asr: DesignAsr,
    candidate_id: str,
    *,
    reference_text: str | None = None,
    transcript: str | None = None,
) -> dict:
    asr.text = transcript if transcript is not None else (reference_text or REFERENCE_TEXT)
    body: dict[str, object] = {}
    if reference_text is not None:
        body["reference_text"] = reference_text
    response = client.post(f"/v1/voice-designs/{candidate_id}/confirm", json=body)
    assert response.status_code == 200, response.text
    return response.json()["candidate"]


def validate_candidate(
    client: TestClient,
    asr: DesignAsr,
    candidate_id: str,
    *,
    test_text: str | None = CONTROLLED_TEST_TEXT,
    transcript: str | None = None,
    capability_key: str | None = None,
    expect: int = 200,
) -> dict:
    if test_text is not None:
        asr.text = transcript if transcript is not None else test_text
    body: dict[str, object] = {}
    if test_text is not None:
        body["test_text"] = test_text
    if capability_key is not None:
        body["capability_key"] = capability_key
    response = client.post(f"/v1/voice-designs/{candidate_id}/validate", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def human_review(
    client: TestClient,
    candidate_id: str,
    *,
    validation_id: str,
    identity: str = "pass",
    naturalness: str = "pass",
    expect: int = 200,
) -> dict:
    response = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={
            "human_review": {
                "validation_id": validation_id,
                "identity": identity,
                "naturalness": naturalness,
            }
        },
    )
    assert response.status_code == expect, response.text
    return response.json()


def published_voice_ids(client: TestClient) -> set[str]:
    return {entry["id"] for entry in client.get("/v1/voices").json()["data"]}


def test_candidate_lifecycle_publishes_only_after_base_and_human_review(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)

    candidate_id, created = create_candidate(client)
    assert created["state"] == "generated"
    assert created["publishable"] is False
    assert created["revision"].startswith("vr_")
    assert created["reference"]["quality"]["transcript_match"] == 1.0
    assert created["reference"]["quality"]["synthesis"]["probe_count"] == 0

    # The safe projection never exposes reference text or private paths.
    blob = json.dumps(created, ensure_ascii=False)
    assert REFERENCE_TEXT not in blob
    assert str(tmp_path) not in blob
    assert VOICE_ID not in published_voice_ids(client)

    assert synth.requests[0].instruction == "清晰自然的中文声音"
    assert synth.requests[0].seed == 123
    assert asr.requests and asr.requests[0].prompt == ""
    assert Path(registry.storage_path).parent.joinpath(
        "voice_design_candidates", f"{candidate_id}.wav"
    ).is_file()

    # A generated candidate cannot be validated or published yet.
    early = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={"test_text": CONTROLLED_TEST_TEXT},
    )
    assert early.status_code == 409
    assert early.json()["error"]["code"] == "voice_design_state_conflict"
    unpublished = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert unpublished.status_code == 409
    assert unpublished.json()["error"]["code"] == "voice_design_state_conflict"

    confirmed = confirm_candidate(client, asr, candidate_id)
    assert confirmed["state"] == "confirmed"
    assert confirmed["confirmed_at"] is not None

    # The Base reproduction must use a text that differs from the reference.
    same_text = validate_candidate(
        client,
        asr,
        candidate_id,
        test_text=REFERENCE_TEXT,
        expect=422,
    )
    assert same_text["error"]["code"] == "test_text_matches_reference"

    validated = validate_candidate(client, asr, candidate_id)
    machine = validated["candidate"]
    assert machine["state"] == "validating"
    assert machine["publishable"] is False
    record = machine["validations"][-1]
    assert record["machine_status"] == "pass"
    assert record["status"] == "warn"
    assert record["identity_status"] == "not_reviewed"
    assert record["naturalness_status"] == "not_reviewed"
    assert record["failure_codes"] == []
    assert record["capability_key"] == "reference.render"
    assert record["transcript_match"] == 1.0

    # The Base role synthesizes the new text; the candidate is not registered.
    assert synth.requests[-1].text == CONTROLLED_TEST_TEXT
    assert synth.requests[-1].voice == VOICE_ID
    assert synth.requests[-1].instruction is None
    assert VOICE_ID not in published_voice_ids(client)

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert blocked.json()["error"]["code"] == "voice_design_validation_required"

    reviewed = human_review(
        client,
        candidate_id,
        validation_id=record["validation_id"],
    )["candidate"]
    assert reviewed["state"] == "publishable"
    assert reviewed["publishable"] is True
    assert VOICE_ID not in published_voice_ids(client)

    published = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert published.status_code == 201, published.text
    assert published.json()["candidate"]["state"] == "published"
    voice = published.json()["voice"]
    assert voice["id"] == VOICE_ID
    assert voice["mode"] == "clone"
    assert voice["variant"] == "base"
    assert voice["capabilities"]["supports_clone"] is True
    assert voice["capabilities"]["supports_instruction"] is False
    assert VOICE_ID in published_voice_ids(client)

    profile = registry.get_profile(VOICE_ID)
    assert profile.mode == "clone"
    assert profile.revision == reviewed["revision"]
    assert profile.ref_text == REFERENCE_TEXT

    # Re-publishing the same candidate is idempotent, not a second revision.
    again = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert again.status_code == 200, again.text
    assert again.json()["candidate"]["state"] == "published"
    assert len(list((tmp_path / "voices").glob("*.wav"))) == 1


def test_publish_requires_exact_candidate_revision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    validated = validate_candidate(client, asr, candidate_id)["candidate"]
    human_review(client, candidate_id, validation_id=validated["validations"][-1]["validation_id"])

    stale = client.post(
        f"/v1/voice-designs/{candidate_id}/publish",
        json={"expected_candidate_revision": "vr_" + "0" * 32},
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "voice_design_revision_conflict"


def test_base_transcript_mismatch_never_publishes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)

    mismatched = validate_candidate(
        client,
        asr,
        candidate_id,
        transcript="完全无关的另一句话，与测试文本没有任何关系。",
    )["candidate"]
    assert mismatched["state"] == "failed"
    assert mismatched["validations"][-1]["machine_status"] == "reject"
    assert "transcript_mismatch" in mismatched["validations"][-1]["failure_codes"]

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert all(profile.is_system for profile in registry.list_profiles())
    # Failed validation preserves the candidate assets for a retry.
    assert list((registry.storage_path.parent / "voice_design_candidates").glob("*.wav"))


def test_base_invalid_audio_never_publishes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)

    synth.pcm = b"\0\0" * 96_000
    rejected = validate_candidate(client, asr, candidate_id, transcript=None)["candidate"]
    assert rejected["state"] == "failed"
    assert rejected["validations"][-1]["machine_status"] == "reject"
    assert "output_invalid" in rejected["validations"][-1]["failure_codes"]

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert all(profile.is_system for profile in registry.list_profiles())


def test_unknown_runtime_identity_blocks_publication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)

    synth.runtime_revision = None
    warned = validate_candidate(client, asr, candidate_id)["candidate"]
    record = warned["validations"][-1]
    assert record["machine_status"] == "warn"
    assert "model_runtime_identity_unknown" in record["failure_codes"]
    assert warned["publishable"] is False

    # Automatic metrics can never substitute for an unobserved runtime identity.
    review = human_review(
        client,
        candidate_id,
        validation_id=record["validation_id"],
        expect=409,
    )
    assert review["error"]["code"] == "voice_design_machine_validation_required"

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert all(profile.is_system for profile in registry.list_profiles())


def test_editing_the_reference_text_revokes_earlier_validation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, created = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    validated = validate_candidate(client, asr, candidate_id)["candidate"]
    assert validated["publishable"] is False

    edited = confirm_candidate(
        client,
        asr,
        candidate_id,
        reference_text=EDITED_TEXT,
        transcript=EDITED_TEXT,
    )
    assert edited["state"] == "confirmed"
    assert edited["revision"] != created["revision"]
    assert edited["validations"] == []
    assert edited["reference"]["text_sha256"] != created["reference"]["text_sha256"]
    assert edited["publishable"] is False

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert blocked.json()["error"]["code"] == "voice_design_state_conflict"


def test_edited_reference_text_publishes_matching_voice_revision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    edited = confirm_candidate(
        client,
        asr,
        candidate_id,
        reference_text=EDITED_TEXT,
        transcript=EDITED_TEXT,
    )
    validated = validate_candidate(client, asr, candidate_id)["candidate"]
    reviewed = human_review(
        client,
        candidate_id,
        validation_id=validated["validations"][-1]["validation_id"],
    )["candidate"]
    assert reviewed["publishable"] is True

    published = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert published.status_code == 201, published.text
    profile = registry.get_profile(VOICE_ID)
    assert profile.ref_text == EDITED_TEXT
    assert profile.revision == edited["revision"]
    assert published.json()["candidate"]["published_voice_revision"] == edited["revision"]


def test_confirm_requires_reference_transcript_match(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    asr.text = "与参考文本完全无关的内容，无法通过确认门禁。"

    response = client.post(f"/v1/voice-designs/{candidate_id}/confirm", json={})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "transcript_mismatch"
    assert all(profile.is_system for profile in registry.list_profiles())
    assert list((registry.storage_path.parent / "voice_design_candidates").glob("*.wav"))


def test_cancel_blocks_publication_without_touching_other_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    other = registry.create_custom_profile("Keep", "Keep me", "keep_me")
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)

    cancelled = client.post(f"/v1/voice-designs/{candidate_id}/cancel")
    assert cancelled.status_code == 200
    assert cancelled.json()["candidate"]["state"] == "cancelled"

    blocked = client.post(f"/v1/voice-designs/{candidate_id}/publish", json={})
    assert blocked.status_code == 409
    assert registry.get_profile("keep_me") == other
    assert VOICE_ID not in published_voice_ids(client)


def test_candidate_generation_is_idempotent_without_duplicate_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, synth, asr = make_client(tmp_path, monkeypatch)
    headers = {"Idempotency-Key": "voice-design-replay"}

    first = client.post("/v1/voice-designs", headers=headers, json=payload())
    second = client.post("/v1/voice-designs", headers=headers, json=payload())

    assert first.status_code == 201, first.text
    assert second.status_code == 200, second.text
    assert second.json()["candidate"]["id"] == first.json()["candidate"]["id"]
    assert second.json()["candidate"]["revision"] == first.json()["candidate"]["revision"]
    assert len(synth.requests) == 1
    assert len(asr.requests) == 1

    conflict = client.post(
        "/v1/voice-designs",
        headers=headers,
        json=payload(name="Different name"),
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"
    assert len(synth.requests) == 1


def test_candidate_replay_survives_completion_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, synth, asr = make_client(tmp_path, monkeypatch)
    headers = {"Idempotency-Key": "voice-design-completion-failure"}

    def fail_complete(*args: object, **kwargs: object) -> str:
        raise IdempotencyStoreUnavailableError("synthetic journal failure")

    monkeypatch.setattr(DurableIdempotencyJournal, "complete", fail_complete)

    first = client.post("/v1/voice-designs", headers=headers, json=payload())
    assert first.status_code == 503
    assert first.json()["error"]["code"] == "idempotency_store_unavailable"
    assert len(synth.requests) == 1
    assert len(asr.requests) == 1

    # The pending journal plus stored candidate recover the exact result without
    # regenerating audio or relying on a second publish path.
    second = client.post("/v1/voice-designs", headers=headers, json=payload())
    assert second.status_code == 200, second.text
    assert second.json()["candidate"]["state"] == "generated"
    assert len(synth.requests) == 1
    assert len(asr.requests) == 1


def test_candidate_works_on_any_tier_and_only_needs_design_and_batch_asr(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # quality 档也应支持音色设计: VoiceDesign 不绑定档位 (修复 tier 绑定缺陷)。
    supported, _registry, supported_synth, _asr = make_client(
        tmp_path / "quality", monkeypatch, tier="quality"
    )
    response = supported.post("/v1/voice-designs", json=payload())
    assert response.status_code == 201
    assert supported_synth.requests

    # 设计供货快照缺失才是 unsupported。
    no_design, _registry, design_synth, _asr = make_client(
        tmp_path / "no_design", monkeypatch, with_design=False
    )
    response = no_design.post("/v1/voice-designs", json=payload())
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_design_unsupported"
    assert not design_synth.requests

    no_asr, _registry, synth, _asr = make_client(
        tmp_path / "no_asr", monkeypatch, with_asr=False
    )
    response = no_asr.post("/v1/voice-designs", json=payload())
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "transcription_unavailable"
    assert not synth.requests


def test_base_unavailable_is_reported_before_any_validation_work(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, _synth, asr = make_client(
        tmp_path, monkeypatch, with_base=False
    )
    candidate_id, _ = create_candidate(client)

    # Confirmation only needs the reference transcript, so it still succeeds.
    confirm_candidate(client, asr, candidate_id)
    response = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={"test_text": CONTROLLED_TEST_TEXT},
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "voice_design_base_unavailable"


def test_candidate_list_and_read_are_safe_and_scoped(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, _synth, _asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)

    listed = client.get("/v1/voice-designs")
    assert listed.status_code == 200
    entries = listed.json()["data"]
    assert [entry["id"] for entry in entries] == [candidate_id]
    assert REFERENCE_TEXT not in listed.text
    assert "reference_audio_path" not in listed.text

    detail = client.get(f"/v1/voice-designs/{candidate_id}")
    assert detail.status_code == 200
    assert detail.json()["candidate"]["id"] == candidate_id
    assert client.get("/v1/voice-designs/vd_" + "0" * 24).status_code == 404


def test_design_routes_require_authentication(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, synth, _asr = make_client(
        tmp_path, monkeypatch, api_key="test-key-only"
    )

    assert client.post("/v1/voice-designs", json=payload()).status_code == 401
    assert client.get("/v1/voice-designs").status_code == 401
    assert not synth.requests
