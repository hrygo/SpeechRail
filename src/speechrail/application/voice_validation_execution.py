"""Bounded audio and ASR primitives for voice-validation application use-cases.

Candidate state and quality evidence commits belong to their separate use-cases.
Identity is observed before the producing reservation exits. HTTP projection and
error envelopes belong to HTTP adapters.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import io
import struct
import uuid
import wave
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from functools import partial, wraps
from typing import Any, cast

from speechrail.application.deadline import await_until
from speechrail.application.render_receipts import (
    observed_runtime_revision_for_voice,
)
from speechrail.application.tts_delivery import (
    PcmOutputCounter,
    TTSDeliveryError,
    iter_until,
    iter_validated_audio,
)
from speechrail.domain import voice_quality as vq
from speechrail.domain.ports import (
    BatchTranscriber,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.tts_errors import TtsBackendError
from speechrail.domain.tts_execution import TtsExecutionPorts, VoiceRuntimeIdentity
from speechrail.domain.voice_quality_metrics import compute_output_quality_metrics
from speechrail.runtime.admission import AdmissionQueue
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import ResourceGovernor, WorkPurpose

TRANSCRIPT_PASS_SCORE = 0.92
TRANSCRIPT_WARN_SCORE = 0.80
MAX_QUALITY_PROBE_PCM_BYTES = 30 * 24_000 * 2


def _owned_operation[**P, T](
    operation: Callable[P, Coroutine[Any, Any, T]],
) -> Callable[P, Coroutine[Any, Any, T]]:
    """Cancel a validation phase once, then join its cleanup before returning.

    The phase owns its deadline. Shielding its task prevents repeated caller
    cancellation from interrupting backend reclamation or releasing admission.
    No task outlives the call, including when a backend delays cancellation.
    """

    @wraps(operation)
    async def owned(*args: P.args, **kwargs: P.kwargs) -> T:
        async def capture() -> tuple[T | None, BaseException | None]:
            # The retained owner handles failures. A cancelled shield must not
            # send an already handled backend exception to the loop logger.
            try:
                return await operation(*args, **kwargs), None
            except BaseException as exc:
                return None, exc

        task = asyncio.create_task(capture(), name=operation.__name__)
        try:
            result, error = await asyncio.shield(task)
        except asyncio.CancelledError:
            if not task.done() and not task.cancelling():
                task.cancel()
            # Reclamation failures are handled at the phase's owner boundary;
            # cancellation must prevent the caller continuing into commit.
            with contextlib.suppress(BaseException):
                await join_cleanup(task)
            raise
        if error is not None:
            raise error
        return cast(T, result)

    return owned


# Failure-code aliases shared with the quality-runs report grading so routes
# never restate the domain code strings.
CLONE_SPEED_UNSUPPORTED_CODE = vq.VoiceQualityFailureCode.CLONE_SPEED_UNSUPPORTED.value
OUTPUT_INVALID_CODE = vq.VoiceQualityFailureCode.OUTPUT_INVALID.value
TRANSCRIPTION_UNAVAILABLE_CODE = vq.VoiceQualityFailureCode.TRANSCRIPTION_UNAVAILABLE.value


def grade_quality_status(
    *,
    attempted: int,
    ok: int,
    output_invalid: bool,
    probe_failure_codes: list[str],
    transcript_match: float | None,
    intelligibility_evaluated: bool,
    intelligibility_unavailable: bool,
) -> tuple[str, list[str]]:
    """Grade one quality run into (status, failure_codes).

    The quality-runs use-case owns synthesis metrics and durable persistence.
    """
    failure_codes = list(dict.fromkeys(probe_failure_codes))
    if output_invalid and OUTPUT_INVALID_CODE not in failure_codes:
        failure_codes.append(OUTPUT_INVALID_CODE)
    if intelligibility_unavailable:
        failure_codes.append(TRANSCRIPTION_UNAVAILABLE_CODE)
    if (
        ok != attempted
        or output_invalid
        or any(code != TRANSCRIPTION_UNAVAILABLE_CODE for code in failure_codes)
    ):
        status = vq.VoiceQualityStatus.REJECT.value
    elif not intelligibility_evaluated or transcript_match is None:
        status = vq.VoiceQualityStatus.UNEVALUATED.value
    elif transcript_match < TRANSCRIPT_WARN_SCORE:
        status = vq.VoiceQualityStatus.REJECT.value
        failure_codes.append(vq.VoiceQualityFailureCode.TRANSCRIPT_MISMATCH.value)
    elif transcript_match < TRANSCRIPT_PASS_SCORE:
        status = vq.VoiceQualityStatus.WARN.value
        failure_codes.append(vq.VoiceQualityFailureCode.TRANSCRIPT_MISMATCH.value)
    else:
        status = vq.VoiceQualityStatus.PASS.value
    return status, list(dict.fromkeys(failure_codes))


class VoiceValidationExecutionError(Exception):
    """Typed failure from a validation execution use-case (no HTTP)."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class SameRunEvidence:
    """Identity observed while the execution still held its resources."""

    model_runtime_revision: str | None


@dataclass(frozen=True)
class CandidateValidationResult:
    """Outcome of one candidate machine-validation execution."""

    output_pcm: bytes
    output_wav: bytes
    output_wav_sha256: str
    quality: vq.VoiceQualityReport
    transcript: str | None
    transcript_match: float | None
    evidence: SameRunEvidence


@dataclass(frozen=True)
class ValidationRuntime:
    """Execution dependencies; candidate and quality use-cases own their commits."""

    synthesizer: SpeechSynthesizer | None
    transcriber: BatchTranscriber | None
    governor: ResourceGovernor
    admission: AdmissionQueue
    tts_ready: bool
    asr_ready: bool
    tts_execution: TtsExecutionPorts


def grade_clone_audio(wav_bytes: bytes) -> vq.VoiceQualityReport:
    """Grade clone reference audio (shared by design + quality flows)."""
    with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
        sample_rate = wf.getframerate()
        channels = wf.getnchannels()
        pcm = wf.readframes(wf.getnframes())
    leading, trailing = vq.leading_trailing_silence_seconds(pcm, sample_rate)
    reference = vq.VoiceQualityReference(
        duration_seconds=vq.duration_seconds(pcm, sample_rate),
        sample_rate=sample_rate,
        channels=channels,
        speech_active_ratio=vq.speech_active_ratio(pcm, sample_rate),
        noise_floor_dbfs=vq.noise_floor_dbfs(pcm),
        estimated_snr_db=vq.estimated_snr_db(pcm, sample_rate),
        clipping_ratio=vq.clipping_ratio(pcm),
        leading_silence_seconds=leading,
        trailing_silence_seconds=trailing,
        transcript_match=None,
        # Measurement only: design pre-screening (#136). Never gates.
        f0_median_hz=vq.f0_median_hz(pcm, sample_rate),
    )
    return vq.make_quality_report(reference, empty_synthesis())


def empty_synthesis() -> vq.VoiceQualitySynthesis:
    """Zero-probe synthesis block for reference-only grading."""
    return vq.VoiceQualitySynthesis(
        probe_count=0,
        successful_probe_count=0,
        active_rms_dbfs=0.0,
        peak_dbfs=0.0,
        chunk_jump_p95_db=0.0,
        clipping_ratio=0.0,
        deterministic=False,
    )


def resample_quality_pcm_24k_to_16k(pcm: bytes) -> bytes:
    """Linearly resample mono PCM16 from the TTS 24 kHz rate to ASR 16 kHz."""
    if not pcm or len(pcm) % 2 != 0:
        raise ValueError("invalid PCM16 payload")
    count = len(pcm) // 2
    samples = struct.unpack(f"<{count}h", pcm)
    output_count = count * 2 // 3
    if output_count <= 0:
        raise ValueError("PCM16 payload is too short")
    output = bytearray(output_count * 2)
    for index in range(output_count):
        source_numerator = index * 3
        left = source_numerator // 2
        half_step = source_numerator % 2
        if left >= count - 1:
            value = samples[-1]
        elif half_step:
            value = round((samples[left] + samples[left + 1]) / 2.0)
        else:
            value = samples[left]
        struct.pack_into("<h", output, index * 2, max(-32768, min(32767, value)))
    return bytes(output)


def classify_probe_failure(exc: BaseException) -> str:
    """Map a probe synthesis failure to its structured failure code."""
    if isinstance(exc, TtsBackendError) and exc.code == "clone_speed_unsupported":
        return vq.VoiceQualityFailureCode.CLONE_SPEED_UNSUPPORTED.value
    if (
        isinstance(exc, TtsBackendError)
        and exc.public_code == vq.VoiceQualityFailureCode.OUTPUT_INVALID.value
    ):
        return vq.VoiceQualityFailureCode.OUTPUT_INVALID.value
    if isinstance(exc, (TTSDeliveryError, ValueError, TypeError)):
        return vq.VoiceQualityFailureCode.OUTPUT_INVALID.value
    return vq.VoiceQualityFailureCode.PROBE_FAILED.value


@_owned_operation
async def synthesize_probes(
    synthesizer: SpeechSynthesizer,
    voice_id: str,
    repetitions: int,
    *,
    voice_revision: str | None = None,
    expires_at: float | None = None,
    on_close_failure: Callable[[], None] | None = None,
) -> tuple[bytes, int, int, list[str], bool, dict[str, bytes]]:
    """Synthesize the fixed quality probe set (shared quality-runs execution)."""
    pcm = bytearray()
    ok = 0
    failure_codes: list[str] = []
    probes = vq.VOICE_QUALITY_V1_ZH_PROBES
    digests_by_probe: dict[str, list[bytes]] = {probe["id"]: [] for probe in probes}
    representative_pcm: dict[str, bytes] = {}
    close_failed = False

    def failed_close() -> None:
        nonlocal close_failed
        close_failed = True
        if on_close_failure is not None:
            on_close_failure()

    for probe in probes:
        for _ in range(repetitions):
            synthesis = SpeechRequest(
                text=probe["text"],
                voice=voice_id,
                output_format="pcm16",
                sample_rate=24_000,
                speed=1.0,
                expected_voice_revision=voice_revision,
            )
            probe_pcm = bytearray()
            try:
                source = iter_validated_audio(
                    synthesizer.synthesize(synthesis),
                    on_close_failure=failed_close,
                )
                bounded = iter_until(source, expires_at) if expires_at is not None else source
                try:
                    async for chunk in bounded:
                        if len(probe_pcm) + len(chunk.audio) > MAX_QUALITY_PROBE_PCM_BYTES:
                            raise ValueError("quality probe audio exceeds 30 seconds")
                        probe_pcm.extend(chunk.audio)
                finally:
                    close = getattr(bounded, "aclose", None)
                    if close is not None:
                        await close()
            except Exception as exc:
                if close_failed:
                    raise VoiceValidationExecutionError(
                        "backend_reclamation_failed",
                        "TTS resources could not be reclaimed",
                    ) from None
                if isinstance(exc, TimeoutError):
                    raise
                failure_codes.append(classify_probe_failure(exc))
                continue
            if not probe_pcm or len(probe_pcm) % 2 != 0:
                failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_INVALID.value)
                continue

            try:
                probe_metrics = compute_output_quality_metrics(
                    bytes(probe_pcm),
                    sample_rate=24_000,
                    probe_count=1,
                    successful_probe_count=1,
                    deterministic=True,
                )
            except ValueError, TypeError:
                failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_INVALID.value)
                continue

            if cast(float, probe_metrics["active_rms_dbfs"]) <= -45.0:
                failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_INVALID.value)
                continue
            if cast(float, probe_metrics["clipping_ratio"]) > 0.0:
                failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_PEAK_EXCEEDED.value)
                continue

            payload = bytes(probe_pcm)
            digests_by_probe[probe["id"]].append(hashlib.sha256(payload).digest())
            representative_pcm.setdefault(probe["id"], payload)
            pcm.extend(payload)
            ok += 1

    attempted = len(probes) * repetitions
    deterministic = repetitions >= 2 and all(
        len(digests) == repetitions and len(set(digests)) == 1
        for digests in digests_by_probe.values()
    )

    return (
        bytes(pcm),
        attempted,
        ok,
        failure_codes,
        deterministic,
        representative_pcm,
    )


def synthesis_report(
    pcm: bytes,
    attempted: int,
    ok: int,
    *,
    deterministic: bool,
    transcript_match: float | None = None,
    intelligibility_evaluated: bool = False,
    probe_scores: list[vq.VoiceQualityProbeScore] | None = None,
) -> vq.VoiceQualitySynthesis:
    """Aggregate probe audio into the synthesis evidence block."""
    if not pcm or ok == 0:
        return vq.VoiceQualitySynthesis(
            probe_count=attempted,
            successful_probe_count=0,
            active_rms_dbfs=-240.0,
            peak_dbfs=-240.0,
            chunk_jump_p95_db=0.0,
            clipping_ratio=0.0,
            deterministic=False,
            transcript_match=transcript_match,
            intelligibility_evaluated=intelligibility_evaluated,
            probe_scores=list(probe_scores or ()),
        )
    metrics = compute_output_quality_metrics(
        pcm,
        sample_rate=24_000,
        probe_count=attempted,
        successful_probe_count=ok,
        deterministic=deterministic,
    )
    return vq.VoiceQualitySynthesis(
        probe_count=cast(int, metrics["probe_count"]),
        successful_probe_count=cast(int, metrics["successful_probe_count"]),
        active_rms_dbfs=cast(float, metrics["active_rms_dbfs"]),
        peak_dbfs=cast(float, metrics["peak_dbfs"]),
        chunk_jump_p95_db=cast(float, metrics["chunk_jump_p95_db"]),
        clipping_ratio=cast(float, metrics["clipping_ratio"]),
        deterministic=cast(bool, metrics["deterministic"]),
        transcript_match=transcript_match,
        intelligibility_evaluated=intelligibility_evaluated,
        probe_scores=list(probe_scores or ()),
    )


@_owned_operation
async def evaluate_probe_intelligibility(
    *,
    governor: ResourceGovernor,
    admission: AdmissionQueue,
    transcriber: BatchTranscriber,
    representative_pcm: dict[str, bytes],
    request_id: str,
    expires_at: float,
) -> tuple[float, list[vq.VoiceQualityProbeScore]]:
    """Transcribe one valid sample per fixed probe (shared execution)."""
    from speechrail.runtime.resource_governor import WorkClass, WorkPurpose

    scores: list[float] = []
    probe_scores: list[vq.VoiceQualityProbeScore] = []
    async with governor.reserve(
        WorkClass.BATCH_ASR,
        expires_at=expires_at,
        purpose=WorkPurpose.QUALITY_VALIDATION,
    ):
        for probe in vq.VOICE_QUALITY_V1_ZH_PROBES:
            pcm = representative_pcm.get(probe["id"])
            if pcm is None:
                raise ValueError("missing representative quality probe audio")
            remaining = expires_at - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError
            request = TranscriptionRequest(
                request_id=f"{request_id}:intelligibility:{probe['id']}",
                audio=resample_quality_pcm_24k_to_16k(pcm),
                language="zh",
                prompt="",
                include_timestamps=False,
            )
            result = await admission.run(
                partial(transcriber.transcribe, request),
                deadline=remaining,
            )
            score = vq.transcript_match_score(probe["text"], result.text)
            scores.append(score)
            probe_scores.append(
                vq.VoiceQualityProbeScore(
                    probe_id=probe["id"],
                    transcript_match=score,
                    numbers_exact=(
                        vq.transcript_numbers_match(probe["text"], result.text)
                        if vq.probe_carries_digits(probe["text"])
                        else None
                    ),
                )
            )
    return (
        min(
            score if entry.numbers_exact is not False else 0.0
            for score, entry in zip(scores, probe_scores, strict=True)
        )
        if scores
        else 0.0
    ), probe_scores


@_owned_operation
async def collect_audio(
    synthesizer: SpeechSynthesizer,
    synthesis: SpeechRequest,
    *,
    expires_at: float,
    design: bool,
    max_bytes: int,
    on_close_failure: Callable[[], None] | None = None,
) -> bytes:
    """Collect one bounded synthesis stream (design lane or production lane)."""
    counter = PcmOutputCounter(max_bytes)
    pcm = bytearray()
    if design:
        method = getattr(synthesizer, "synthesize_design", None)
        source = method(synthesis) if callable(method) else synthesizer.synthesize(synthesis)
    else:
        source = synthesizer.synthesize(synthesis)
    close_failed = False

    def failed_close() -> None:
        nonlocal close_failed
        close_failed = True
        if on_close_failure is not None:
            on_close_failure()

    stream = iter_until(
        iter_validated_audio(source, on_close_failure=failed_close),
        expires_at,
    )
    try:
        try:
            async for chunk in stream:
                counter.accept(len(chunk.audio))
                pcm.extend(chunk.audio)
        finally:
            close = getattr(stream, "aclose", None)
            if close is not None:
                await close()
    except Exception:
        if close_failed:
            raise VoiceValidationExecutionError(
                "backend_reclamation_failed",
                "TTS resources could not be reclaimed",
            ) from None
        raise
    return bytes(pcm)


@_owned_operation
async def transcribe_pcm(
    *,
    transcriber: BatchTranscriber | None,
    governor: ResourceGovernor,
    admission: AdmissionQueue,
    pcm: bytes,
    language: str,
    expires_at: float,
    request_id_prefix: str,
    purpose: WorkPurpose = WorkPurpose.QUALITY_VALIDATION,
) -> str:
    """Transcribe validation audio under the shared deadline (raises typed error)."""
    if transcriber is None:
        raise VoiceValidationExecutionError(
            "transcription_unavailable",
            "Voice validation requires local Batch ASR",
            retryable=True,
        )
    from speechrail.runtime.admission import QueueFullError
    from speechrail.runtime.asr_mode import AsrModeBusy
    from speechrail.runtime.resource_governor import (
        GovernorQueueFullError,
        WorkClass,
    )

    request = TranscriptionRequest(
        request_id=f"{request_id_prefix}_{uuid.uuid4().hex}",
        audio=resample_quality_pcm_24k_to_16k(pcm),
        language=language,
        prompt="",
        include_timestamps=False,
    )
    try:
        async with governor.reserve(
            WorkClass.BATCH_ASR,
            expires_at=expires_at,
            purpose=purpose,
        ):
            remaining = expires_at - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError
            result = await admission.run(
                partial(transcriber.transcribe, request),
                deadline=remaining,
            )
    except GovernorQueueFullError, QueueFullError, AsrModeBusy, TimeoutError:
        raise
    except Exception as exc:
        raise VoiceValidationExecutionError(
            "transcription_unavailable",
            "Local Batch ASR failed during validation",
            retryable=True,
        ) from exc
    return result.text


@_owned_operation
async def evict_quality_tts_if_supported(
    synthesizer: SpeechSynthesizer,
    *,
    expires_at: float,
    on_reclamation_failure: Callable[[], None] | None = None,
) -> None:
    """Release the warm TTS capability between validation phases when supported."""
    evict = getattr(synthesizer, "evict_warm_capability", None)
    if callable(evict):
        try:
            await await_until(evict(), expires_at)
        except asyncio.CancelledError, TimeoutError:
            if on_reclamation_failure is not None:
                on_reclamation_failure()
            raise
        except Exception:
            if on_reclamation_failure is not None:
                on_reclamation_failure()
            raise VoiceValidationExecutionError(
                "backend_reclamation_failed",
                "TTS resources could not be reclaimed",
            ) from None


async def execute_candidate_validation(
    *,
    synthesizer: SpeechSynthesizer,
    runtime_identity: VoiceRuntimeIdentity | None,
    transcriber: BatchTranscriber | None,
    governor: ResourceGovernor,
    admission: AdmissionQueue,
    test_text: str,
    candidate_voice_id: str,
    candidate_language: str,
    candidate_revision: str,
    resource_key: str | None,
    expires_at: float,
    max_pcm_bytes: int,
) -> CandidateValidationResult:
    """Run one candidate machine validation and bind same-run evidence.

    The runtime identity is read while the producing reservation is still
    held. A later eviction or replacement cannot change the identity of audio
    already produced. Unknown remains unknown.
    """

    from speechrail.runtime.resource_governor import WorkClass, WorkPurpose

    synthesis = SpeechRequest(
        text=test_text,
        voice=candidate_voice_id,
        language=candidate_language,
        sample_rate=24_000,
        expected_voice_revision=candidate_revision,
    )
    async with governor.reserve(
        WorkClass.BATCH_TTS,
        expires_at=expires_at,
        resource_key=resource_key,
        purpose=WorkPurpose.VOICE_CREATION,
    ):
        output_pcm = await collect_audio(
            synthesizer,
            synthesis,
            expires_at=expires_at,
            design=False,
            max_bytes=max_pcm_bytes,
            on_close_failure=lambda: governor.quarantine_tts_lane(resource_key),
        )
        # Same-run binding: read the identity while the producing
        # reservation is still held, before the quality-phase eviction below
        # can retire this worker.
        execution_revision = observed_runtime_revision_for_voice(
            runtime_identity, candidate_voice_id
        )
    if not output_pcm:
        raise TTSDeliveryError("voice_validation_output_empty")
    async with governor.reserve(
        WorkClass.BATCH_TTS,
        expires_at=expires_at,
        resource_key=resource_key,
        purpose=WorkPurpose.VOICE_CREATION,
    ):
        await evict_quality_tts_if_supported(
            synthesizer,
            expires_at=expires_at,
            on_reclamation_failure=lambda: governor.quarantine_tts_lane(resource_key),
        )

    def _wav_from_pcm(raw: bytes, *, sample_rate: int = 24_000) -> bytes:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(raw)
        return buf.getvalue()

    output_wav = _wav_from_pcm(output_pcm)
    quality = grade_clone_audio(output_wav)
    transcript: str | None = None
    transcript_match: float | None = None
    try:
        transcript = await transcribe_pcm(
            transcriber=transcriber,
            governor=governor,
            admission=admission,
            pcm=output_pcm,
            language=candidate_language,
            expires_at=expires_at,
            request_id_prefix="req_validation",
            purpose=WorkPurpose.VOICE_CREATION,
        )
        transcript_match = vq.transcript_match_score(test_text, transcript)
    except VoiceValidationExecutionError as exc:
        if exc.code != "transcription_unavailable":
            raise
    return CandidateValidationResult(
        output_pcm=output_pcm,
        output_wav=output_wav,
        output_wav_sha256=hashlib.sha256(output_wav).hexdigest(),
        quality=quality,
        transcript=transcript,
        transcript_match=transcript_match,
        evidence=SameRunEvidence(model_runtime_revision=execution_revision),
    )
