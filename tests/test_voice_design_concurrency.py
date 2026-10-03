"""Concurrent VoiceDesign results remain durable across competing transitions."""

from __future__ import annotations

import asyncio
import hashlib
import io
import threading
import wave
from collections.abc import AsyncIterator, Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx
import pytest

from speechrail.application.voice_design import (
    VoiceDesignCandidate,
    VoiceDesignRepository,
    VoiceDesignStoreUnavailableError,
    VoiceDesignValidationLimitError,
)
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest
from test_voice_design_workflow import (
    CONTROLLED_TEST_TEXT,
    EDITED_TEXT,
    SECOND_TEST_TEXT,
    confirm_candidate,
    create_candidate,
    human_review,
    make_client,
    validate_candidate,
)


@pytest.mark.parametrize("second_finishes_first", [False, True])
def test_concurrent_validations_both_persist_their_record(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    second_finishes_first: bool,
) -> None:
    """Two overlapping validations must not overwrite each other's record.

    Both requests read the candidate before either stores, which is exactly the
    interleaving a real user gets by double-submitting: the second writer used
    to persist its own copy of a stale ``validations`` list and silently drop
    the first result, leaving a returned validation id unreviewable.
    """

    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _created = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)

    # Each concurrent validation must own a distinct output: the fake backend
    # returns one fixed PCM today, which would collapse both results into a
    # single validation id and hide the lost update this test is about.
    spoken_text: dict[bytes, str] = {}
    syntheses = 0
    unsynthesized = synth.synthesize

    def distinct_synthesize(request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        nonlocal syntheses
        index = syntheses
        syntheses += 1
        source = unsynthesized(request)

        async def stream() -> AsyncIterator[AudioChunk]:
            async for chunk in source:
                # Two extra bytes keep the PCM16 parity the port contract needs.
                payload = chunk.audio + index.to_bytes(2, "big")
                spoken_text[payload] = request.text
                yield AudioChunk(
                    response_id=chunk.response_id,
                    chunk_index=chunk.chunk_index,
                    audio=payload,
                )

        return stream()

    synth.synthesize = distinct_synthesize  # type: ignore[method-assign]
    # The fake backend emits no real audio, so the 24k->16k quality resample
    # would only obscure which synthesis a transcript belongs to.
    monkeypatch.setattr(
        "speechrail.http.routes.voice_designs._resample_quality_pcm_24k_to_16k",
        lambda pcm: pcm,
    )

    async def transcribe(request: TranscriptionRequest) -> TranscriptResult:
        return TranscriptResult(
            request_id=request.request_id,
            model_id="fake-asr",
            text=spoken_text[bytes(request.audio)],
            duration_ms=0,
        )

    asr.transcribe = transcribe  # type: ignore[method-assign]

    async def scenario() -> list[httpx.Response]:
        from speechrail.http.routes import voice_designs

        texts = (CONTROLLED_TEST_TEXT, SECOND_TEST_TEXT)
        ready = {text: asyncio.Event() for text in texts}
        release = {text: asyncio.Event() for text in texts}
        original_transcribe = voice_designs._transcribe_pcm

        async def hold_after_transcription(services, pcm, *, language, expires_at):
            # Wait after the real helper releases its resource lane. Holding a
            # backend call itself would prevent the second request reaching ASR.
            transcript = await original_transcribe(
                services, pcm, language=language, expires_at=expires_at
            )
            text = spoken_text[pcm]
            ready[text].set()
            await release[text].wait()
            return transcript

        monkeypatch.setattr(voice_designs, "_transcribe_pcm", hold_after_transcription)
        transport = httpx.ASGITransport(app=client.app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://voice-design.test"
        ) as async_client:
            tasks = [
                asyncio.create_task(
                    async_client.post(
                        f"/v1/voice-designs/{candidate_id}/validate",
                        json={"test_text": text},
                    )
                )
                for text in texts
            ]
            try:
                await asyncio.wait_for(
                    asyncio.gather(*(event.wait() for event in ready.values())),
                    timeout=10,
                )
                first = int(second_finishes_first)
                release[texts[first]].set()
                first_response = await tasks[first]
                assert first_response.status_code == 200, first_response.text
                first_id = first_response.json()["candidate"]["validations"][-1][
                    "validation_id"
                ]
                review = await async_client.post(
                    f"/v1/voice-designs/{candidate_id}/validate",
                    json={
                        "human_review": {
                            "validation_id": first_id,
                            "identity": "pass",
                            "naturalness": "pass",
                        }
                    },
                )
                assert review.status_code == 200, review.text
                release[texts[1 - first]].set()
                return list(await asyncio.gather(*tasks))
            finally:
                for event in release.values():
                    event.set()
                await asyncio.gather(*tasks, return_exceptions=True)

    responses = asyncio.run(asyncio.wait_for(scenario(), timeout=20))

    assert [response.status_code for response in responses] == [200, 200]
    returned_ids = [
        response.json()["candidate"]["validations"][-1]["validation_id"]
        for response in responses
    ]
    assert returned_ids[0] != returned_ids[1]

    stored = client.get(f"/v1/voice-designs/{candidate_id}").json()["candidate"]
    assert {entry["validation_id"] for entry in stored["validations"]} == set(returned_ids)
    assert stored["state"] == "publishable"
    already_reviewed = returned_ids[int(second_finishes_first)]
    assert next(
        item for item in stored["validations"]
        if item["validation_id"] == already_reviewed
    )["identity_status"] == "pass"

    # A fresh repository instance reads durable JSON/WAV, rather than relying
    # on either response snapshot or the original repository's memory.
    reopened = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    durable = reopened.get(candidate_id)
    assert {item.validation_id for item in durable.validations} == set(returned_ids)
    expected_pcm = {text: pcm for pcm, text in spoken_text.items()}
    for text, validation_id in zip(
        (CONTROLLED_TEST_TEXT, SECOND_TEST_TEXT), returned_ids, strict=True
    ):
        audio = client.get(
            f"/v1/voice-designs/{candidate_id}/validations/{validation_id}/audio",
            headers={"SpeechRail-Expected-Candidate-Revision": durable.revision},
        )
        assert audio.status_code == 200, audio.text
        validation = next(
            item for item in durable.validations if item.validation_id == validation_id
        )
        assert hashlib.sha256(audio.content).hexdigest() == validation.output_wav_sha256
        with wave.open(io.BytesIO(audio.content), "rb") as wav:
            pcm = wav.readframes(wav.getnframes())
        assert pcm == expected_pcm[text]
        assert hashlib.sha256(pcm).hexdigest() == validation.output_audio_sha256

    for validation_id in returned_ids:
        reviewed = human_review(
            client, candidate_id, validation_id=validation_id, expect=200
        )
        assert any(
            entry["validation_id"] == validation_id and entry["status"] == "pass"
            for entry in reviewed["candidate"]["validations"]
        )

    published = client.get(f"/v1/voice-designs/{candidate_id}").json()["candidate"]
    assert published["state"] == "publishable"
    assert published["publishable"] is True


def test_repeating_a_machine_validation_keeps_the_human_verdict(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A re-run is idempotent for the fields it measured, not for the review.

    The validation id is derived from the output and the transcript, so an
    identical re-run lands on the same record.  Storing it again must not reset
    the verdict a human already recorded against that exact audio.
    """

    client, _registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _created = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    first = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    reviewed = human_review(
        client, candidate_id, validation_id=first["validation_id"], expect=200
    )["candidate"]
    assert reviewed["validations"][-1]["status"] == "pass"

    repeated = validate_candidate(client, asr, candidate_id)["candidate"]
    again = repeated["validations"][-1]

    assert again["validation_id"] == first["validation_id"]
    assert again["status"] == "pass"
    assert again["identity_status"] == "pass"
    assert again["naturalness_status"] == "pass"
    assert again["created_at"] == first["created_at"]
    assert len(repeated["validations"]) == 1


def test_failed_revalidation_preserves_the_reviewed_candidate_state(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _registry, synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    record = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    reviewed = human_review(client, candidate_id, validation_id=record["validation_id"])[
        "candidate"
    ]

    async def timed_out(request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        raise TimeoutError("controlled synthesis timeout")
        yield  # pragma: no cover

    monkeypatch.setattr(synth, "synthesize", timed_out)
    response = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={"test_text": SECOND_TEST_TEXT},
    )

    assert response.status_code == 503, response.text
    assert response.json()["error"]["code"] == "backend_timeout"
    stored = client.get(f"/v1/voice-designs/{candidate_id}").json()["candidate"]
    assert stored["state"] == "publishable"
    assert stored["validations"] == reviewed["validations"]


@pytest.mark.parametrize("terminal_state", ["published", "cancelled", "failed"])
@pytest.mark.parametrize("action", ["machine", "human"])
def test_validation_rechecks_terminal_state_inside_the_write_transaction(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    terminal_state: str,
    action: str,
) -> None:
    """A competing store writer must not be undone by a stale route snapshot."""

    client, registry, synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    record = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    request_count = len(synth.requests)
    original_update = VoiceDesignRepository.update
    injected = False

    def transition_before_update(
        self: VoiceDesignRepository,
        identity: str,
        updater: Callable[[VoiceDesignCandidate], VoiceDesignCandidate],
    ) -> VoiceDesignCandidate:
        nonlocal injected
        if not injected:
            injected = True
            original_update(
                self,
                identity,
                lambda current: current.model_copy(update={"state": terminal_state}),
            )
        return original_update(self, identity, updater)

    monkeypatch.setattr(VoiceDesignRepository, "update", transition_before_update)
    body = (
        {"test_text": SECOND_TEST_TEXT}
        if action == "machine"
        else {
            "human_review": {
                "validation_id": record["validation_id"],
                "identity": "pass",
                "naturalness": "pass",
            }
        }
    )
    response = client.post(f"/v1/voice-designs/{candidate_id}/validate", json=body)

    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "voice_design_revision_conflict"
    assert response.headers["x-request-id"]
    repository = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    stored = repository.get(candidate_id)
    assert stored.state == terminal_state
    assert stored.validations[0].identity_status == "not_reviewed"
    assert len(synth.requests) == request_count


def test_conflicting_machine_facts_for_one_validation_id_return_a_conflict(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from speechrail.http.routes import voice_designs

    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    first = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    original_validation = voice_designs._candidate_validation

    def conflicting_validation(**kwargs):
        return original_validation(**kwargs).model_copy(
            update={"machine_status": "reject", "failure_codes": ["output_invalid"]}
        )

    monkeypatch.setattr(voice_designs, "_candidate_validation", conflicting_validation)
    asr.text = CONTROLLED_TEST_TEXT
    response = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={"test_text": CONTROLLED_TEST_TEXT},
    )

    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "voice_design_revision_conflict"
    assert response.headers["x-request-id"]
    repository = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    assert len(repository.get(candidate_id).validations) == 1
    assert repository.get(candidate_id).validations[0].machine_status == "pass"
    assert repository.get(candidate_id).validations[0].validation_id == first["validation_id"]


def test_the_validation_limit_refuses_instead_of_evicting_a_returned_record(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A client holding 32 returned ids must never have one silently dropped."""

    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _created = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    validate_candidate(client, asr, candidate_id)

    repository = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    candidate = repository.get(candidate_id)
    template = candidate.validations[-1]
    filler = [
        template.model_copy(update={"validation_id": f"vv_{index:024x}"})
        for index in range(1, 32)
    ]
    repository.update(
        candidate_id,
        lambda current: current.model_copy(
            update={"validations": [*filler, template]}
        ),
    )
    fresh = template.model_copy(update={"validation_id": "vv_" + "f" * 24})
    wav = repository.read_validation_audio(
        candidate_id,
        template.validation_id,
        expected_revision=candidate.revision,
        max_bytes=8 * 1024 * 1024,
    )[1]

    with pytest.raises(VoiceDesignValidationLimitError):
        repository.update_with_validation_audio(
            candidate_id,
            expected_revision=candidate.revision,
            validation=fresh,
            audio_bytes=wav,
            max_bytes=8 * 1024 * 1024,
        )

    stored = repository.get(candidate_id)
    assert len(stored.validations) == 32
    assert template.validation_id in {item.validation_id for item in stored.validations}


@pytest.mark.parametrize("transition", ["cancel", "publish", "failed", "revision"])
def test_inflight_validation_cannot_undo_a_completed_transition(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    transition: str,
) -> None:
    from speechrail.http.routes import voice_designs

    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, created = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    first = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    human_review(client, candidate_id, validation_id=first["validation_id"])
    repository = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    assets_before = set(repository.assets_dir.rglob("*.wav"))
    original_transcribe = voice_designs._transcribe_pcm
    asr.text = SECOND_TEST_TEXT

    async def scenario() -> httpx.Response:
        ready = asyncio.Event()
        release = asyncio.Event()

        async def hold_after_transcription(services, pcm, *, language, expires_at):
            transcript = await original_transcribe(
                services, pcm, language=language, expires_at=expires_at
            )
            if not ready.is_set():
                ready.set()
                await release.wait()
            return transcript

        monkeypatch.setattr(voice_designs, "_transcribe_pcm", hold_after_transcription)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=client.app),
            base_url="http://voice-design.test",
        ) as async_client:
            pending = asyncio.create_task(
                async_client.post(
                    f"/v1/voice-designs/{candidate_id}/validate",
                    json={"test_text": SECOND_TEST_TEXT},
                )
            )
            try:
                await asyncio.wait_for(ready.wait(), timeout=10)
                if transition in {"cancel", "publish"}:
                    response = await async_client.post(
                        f"/v1/voice-designs/{candidate_id}/{transition}", json={}
                    )
                    assert response.status_code == (
                        201 if transition == "publish" else 200
                    ), response.text
                elif transition == "failed":
                    response = await async_client.post(
                        f"/v1/voice-designs/{candidate_id}/validate",
                        json={
                            "human_review": {
                                "validation_id": first["validation_id"],
                                "identity": "reject",
                                "naturalness": "pass",
                            }
                        },
                    )
                    assert response.status_code == 200, response.text
                    assert response.json()["candidate"]["state"] == "failed"
                else:
                    asr.text = EDITED_TEXT
                    response = await async_client.post(
                        f"/v1/voice-designs/{candidate_id}/confirm",
                        json={"reference_text": EDITED_TEXT},
                    )
                    assert response.status_code == 200, response.text
                release.set()
                return await pending
            finally:
                release.set()
                await asyncio.gather(pending, return_exceptions=True)

    response = asyncio.run(asyncio.wait_for(scenario(), timeout=20))

    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "voice_design_revision_conflict"
    assert response.headers["x-request-id"]
    stored = repository.get(candidate_id)
    if transition == "revision":
        assert stored.revision != created["revision"]
        assert stored.validations == []
    else:
        expected = {"cancel": "cancelled", "publish": "published", "failed": "failed"}
        assert stored.state == expected[transition]
        assert len(stored.validations) == 1
        assert stored.validations[0].validation_id == first["validation_id"]
    assert set(repository.assets_dir.rglob("*.wav")) == assets_before


def test_two_repository_instances_compete_for_the_last_validation_slot(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Independent RLocks must still share the durable store's file lock."""

    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    validate_candidate(client, asr, candidate_id)
    repositories = [
        VoiceDesignRepository(
            registry.storage_path.with_name("voice_design_candidates.json"),
            registry.storage_path.with_name("voice_design_candidates"),
        )
        for _ in range(2)
    ]
    candidate = repositories[0].get(candidate_id)
    template = candidate.validations[-1]
    wav = repositories[0].read_validation_audio(
        candidate_id,
        template.validation_id,
        expected_revision=candidate.revision,
        max_bytes=8 * 1024 * 1024,
    )[1]
    for index in range(30):
        repositories[0].update_with_validation_audio(
            candidate_id,
            expected_revision=candidate.revision,
            validation=template.model_copy(update={"validation_id": f"vv_{index:024x}"}),
            audio_bytes=wav,
            max_bytes=8 * 1024 * 1024,
        )
    before = repositories[0].get(candidate_id)
    start = threading.Barrier(2, timeout=10)
    attempts = [
        template.model_copy(update={"validation_id": f"vv_{index:024x}"})
        for index in (30, 31)
    ]

    def add_validation(index: int) -> str:
        start.wait()
        try:
            repositories[index].update_with_validation_audio(
                candidate_id,
                expected_revision=candidate.revision,
                validation=attempts[index],
                audio_bytes=wav,
                max_bytes=8 * 1024 * 1024,
            )
        except VoiceDesignValidationLimitError:
            return "full"
        return "stored"

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(executor.map(add_validation, range(2)))

    assert sorted(outcomes) == ["full", "stored"]
    stored = repositories[1].get(candidate_id)
    assert len(stored.validations) == 32
    before_ids = {item.validation_id for item in before.validations}
    assert before_ids <= {item.validation_id for item in stored.validations}
    winner = attempts[outcomes.index("stored")].validation_id
    loser = attempts[outcomes.index("full")].validation_id
    assert {item.validation_id for item in stored.validations} == before_ids | {winner}
    assets = {path.stem for path in (repositories[0].assets_dir / candidate_id).glob("*.wav")}
    assert assets == before_ids | {winner}
    assert loser not in assets
    for item in stored.validations:
        assert repositories[1].read_validation_audio(
            candidate_id,
            item.validation_id,
            expected_revision=stored.revision,
            max_bytes=8 * 1024 * 1024,
        )[1] == wav
    # Replaying a reviewed result remains allowed even when all slots are full.
    reviewed = human_review(client, candidate_id, validation_id=template.validation_id)[
        "candidate"
    ]
    repeated = repositories[1].update_with_validation_audio(
        candidate_id,
        expected_revision=stored.revision,
        validation=template,
        audio_bytes=wav,
        max_bytes=8 * 1024 * 1024,
    )
    assert repeated.state == "publishable"
    assert repeated.validations[-1].identity_status == "pass"
    assert len(repeated.validations) == 32
    assert repeated.updated_at >= reviewed["updated_at"]


@pytest.mark.parametrize("repeat_existing", [False, True])
def test_validation_save_failure_only_rolls_back_the_new_asset(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    repeat_existing: bool,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    validate_candidate(client, asr, candidate_id)
    repository = VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )
    before = repository.get(candidate_id)
    template = before.validations[-1]
    wav = repository.read_validation_audio(
        candidate_id,
        template.validation_id,
        expected_revision=before.revision,
        max_bytes=8 * 1024 * 1024,
    )[1]
    files_before = {
        path: path.read_bytes() for path in repository.assets_dir.rglob("*.wav")
    }
    json_before = repository.path.read_bytes()
    validation = (
        template
        if repeat_existing
        else template.model_copy(update={"validation_id": "vv_" + "f" * 24})
    )

    def refuse_save(records) -> None:
        raise VoiceDesignStoreUnavailableError("controlled persistence failure")

    monkeypatch.setattr(repository, "_save_locked", refuse_save)
    with pytest.raises(VoiceDesignStoreUnavailableError):
        repository.update_with_validation_audio(
            candidate_id,
            expected_revision=before.revision,
            validation=validation,
            audio_bytes=wav,
            max_bytes=8 * 1024 * 1024,
        )

    assert repository.path.read_bytes() == json_before
    assert repository.get(candidate_id) == before
    assert {
        path: path.read_bytes() for path in repository.assets_dir.rglob("*.wav")
    } == files_before


def test_machine_validation_refuses_a_conflicting_existing_audio_asset(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, registry, _synth, asr = make_client(tmp_path, monkeypatch)
    candidate_id, _ = create_candidate(client)
    confirm_candidate(client, asr, candidate_id)
    first = validate_candidate(client, asr, candidate_id)["candidate"]["validations"][-1]
    asset = (
        registry.storage_path.with_name("voice_design_candidates")
        / candidate_id
        / f"{first['validation_id']}.wav"
    )
    conflicting_audio = b"controlled-invalid-test-asset"
    asset.write_bytes(conflicting_audio)
    asr.text = CONTROLLED_TEST_TEXT

    response = client.post(
        f"/v1/voice-designs/{candidate_id}/validate",
        json={"test_text": CONTROLLED_TEST_TEXT},
    )

    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "validation_audio_unavailable"
    assert response.headers["x-request-id"]
    assert asset.read_bytes() == conflicting_audio
    stored = client.get(f"/v1/voice-designs/{candidate_id}").json()["candidate"]
    assert stored["validations"] == [first]
