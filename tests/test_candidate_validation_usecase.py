"""Candidate state/evidence commits can run independently of HTTP."""

from __future__ import annotations

import asyncio
import hashlib
import io
import wave
from types import SimpleNamespace

import pytest

from speechrail.application import candidate_validation as usecase
from speechrail.application.voice_design import (
    VoiceDesignCandidate,
    VoiceDesignConflictError,
    VoiceDesignStoreUnavailableError,
)
from speechrail.application.voice_validation_execution import (
    CandidateValidationResult,
    SameRunEvidence,
    ValidationRuntime,
    empty_synthesis,
)
from speechrail.config.model_catalog import load_catalog
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.voice_creation import VoiceCreation


@pytest.mark.anyio
@pytest.mark.parametrize("known_identity", [True, False])
@pytest.mark.parametrize("commit_outcome", ["saved", "cancelled", "unavailable"])
async def test_candidate_usecase_owns_binding_and_revision_commit(
    monkeypatch: pytest.MonkeyPatch,
    known_identity: bool,
    commit_outcome: str,
) -> None:
    base = next(artifact for artifact in load_catalog().artifacts if artifact.variant == "base")
    reference_text, test_text = usecase.CONTROLLED_TEST_TEXTS[:2]
    text_sha = hashlib.sha256(reference_text.encode()).hexdigest()
    pcm = b"\x01\x00" * 24
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24_000)
        wav.writeframes(pcm)
    audio = buffer.getvalue()
    audio_sha = hashlib.sha256(audio).hexdigest()
    candidate = VoiceDesignCandidate(
        candidate_id="vd_" + "a" * 24,
        target_voice_id="candidate_test",
        name="test",
        seed=0,
        instruction_sha256="a" * 64,
        reference_text=reference_text,
        reference_text_sha256=text_sha,
        transcript=reference_text,
        transcript_sha256=text_sha,
        reference_audio_path="reference.wav",
        reference_audio_sha256=audio_sha,
        duration_seconds=4,
        quality={"status": "pass"},
        source_model_artifact=base.key,
        source_model_revision=base.revision,
        creation=VoiceCreation(
            model_artifact=base.key,
            model_revision=base.revision,
            seed=0,
            instruction_sha256="a" * 64,
            reference_text_sha256=text_sha,
            reference_audio_sha256=audio_sha,
        ),
        revision="vr_" + "b" * 32,
        request_fingerprint="c" * 64,
        state="confirmed",
        created_at=0,
        updated_at=0,
    )
    producing_revision = "rt_" + "a" * 64 if known_identity else None
    commits = []

    class Repository:
        current = candidate

        def get(self, candidate_id):
            assert candidate_id == candidate.candidate_id
            return self.current

        def update(self, candidate_id, mutation):
            assert candidate_id == candidate.candidate_id
            self.current = mutation(self.current)
            return self.current

        def update_with_validation_audio(
            self,
            candidate_id,
            *,
            expected_revision,
            validation,
            audio_bytes,
            max_bytes,
        ):
            assert candidate_id == candidate.candidate_id
            self.current.require_validation_writable(expected_revision=expected_revision)
            if commit_outcome == "unavailable":
                raise VoiceDesignStoreUnavailableError("fake unavailable")
            assert audio_bytes == audio and len(audio_bytes) <= max_bytes
            commits.append(validation)
            self.current = self.current.model_copy(update={"validations": [validation]})
            return self.current

    repository = Repository()

    async def execute(**kwargs):
        assert kwargs["candidate_revision"] == candidate.revision
        if commit_outcome == "cancelled":
            repository.current = repository.current.model_copy(update={"state": "cancelled"})
        return CandidateValidationResult(
            output_pcm=pcm,
            output_wav=audio,
            output_wav_sha256=audio_sha,
            quality=vq.VoiceQualityReport(
                policy_version=vq.POLICY_VERSION,
                status="pass",
                run_id=vq.new_run_id(),
                tested_at=vq.now_iso8601_z(),
                reference=None,
                synthesis=empty_synthesis(),
                failure_codes=[],
            ),
            transcript=test_text,
            transcript_match=1,
            evidence=SameRunEvidence(model_runtime_revision=producing_revision),
        )

    monkeypatch.setattr(usecase, "execute_candidate_validation", execute)
    synthesizer = SimpleNamespace(runtime_revision_for_voice=lambda _: "rt_" + "f" * 64)

    async def run():
        return await usecase.validate_candidate(
            repository=repository,
            candidate_id=candidate.candidate_id,
            active=ActiveModelCatalog(
                profile="quality",
                asr=None,
                tts=None,
                tts_clone=base,
                aligner=None,
                diarization=False,
                tts_spec="quality",
            ),
            runtime=ValidationRuntime(
                synthesizer=synthesizer,
                transcriber=None,
                governor=None,
                admission=None,
                tts_ready=True,
                asr_ready=True,
            ),
            selected_capability_key="quality.render",
            requested_capability_key=None,
            test_text=test_text,
            human_review=None,
            expires_at=asyncio.get_running_loop().time() + 30,
        )

    if commit_outcome == "saved":
        result = await run()
        validation = result.validations[0]
        assert validation.model_runtime_revision == producing_revision
        assert (validation.runtime_fingerprint is not None) == known_identity
        assert validation.machine_status == ("pass" if known_identity else "warn")
        assert validation.identity_status == validation.naturalness_status == "not_reviewed"
        assert validation.status == "warn"
        assert len(commits) == 1
    else:
        with pytest.raises(
            VoiceDesignConflictError
            if commit_outcome == "cancelled"
            else VoiceDesignStoreUnavailableError
        ):
            await run()
        assert commits == []
