"""One render execution and its validated PCM, delivery and cleanup owners."""

from __future__ import annotations

import asyncio
import contextlib
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field

from speechrail.application.deadline import await_until
from speechrail.application.render_receipts import (
    RenderReceiptRegistry,
    bind_observed_runtime_revision,
    bind_observed_sampling,
)
from speechrail.application.tts_admission import tts_resource_key
from speechrail.application.tts_delivery import (
    PcmOutputCounter,
    TTSDeliveryError,
    iter_until,
    iter_validated_audio,
)
from speechrail.application.tts_timings import TtsTimingRegistry
from speechrail.application.voice_validation_gate import prepare_validated_speech
from speechrail.config.model_catalog import ModelArtifact
from speechrail.domain.ports import SpeechRequest, SpeechSynthesizer
from speechrail.domain.tts import (
    VoiceRevisionConflictError,
    VoiceRevokedError,
    VoiceStoreUnavailableError,
)
from speechrail.domain.tts_execution import TtsExecutionPorts
from speechrail.domain.voice_ports import ValidatedVoiceDirectory
from speechrail.observability.metrics import Metrics
from speechrail.runtime.busy import BusyReason, infer_backend_busy_reason
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
    ResourceGovernor,
    WorkClass,
    WorkPurpose,
)


def _tts_backend_failure_code(exc: BaseException) -> str:
    if infer_backend_busy_reason(exc) == BusyReason.BACKEND_UNAVAILABLE:
        return "backend_busy"
    return "backend_error"


async def close_render_stream(source: AsyncIterator[bytes]) -> None:
    close = getattr(source, "aclose", None)
    if close is not None:
        await join_cleanup(asyncio.create_task(close(), name="render-stream-close"))


@dataclass(slots=True)
class RenderOperation:
    request: SpeechRequest
    synthesizer: SpeechSynthesizer
    execution: TtsExecutionPorts
    voices: ValidatedVoiceDirectory
    governor: ResourceGovernor
    artifact: ModelArtifact | None
    capability_key: str | None
    expires_at: float
    work_class: WorkClass
    work_purpose: WorkPurpose
    receipts: RenderReceiptRegistry
    timings: TtsTimingRegistry
    receipt_id: str | None
    timing_id: str | None
    metrics: Metrics
    voice_class: str
    raw_character_count: int
    sample_rate: int
    reclamation_failed: bool = field(default=False, init=False)
    resource_key: str | None = field(init=False)
    _execution_started: bool = field(default=False, init=False)
    _started_at: float = field(default_factory=time.monotonic, init=False)
    _delivery_source: AsyncIterator[bytes] | None = field(default=None, init=False)
    _delivery_body: AsyncIterator[bytes] | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        self.resource_key = tts_resource_key(self.execution.lanes, self.request.voice)

    def quarantine_backend(self) -> None:
        self.reclamation_failed = True
        self.governor.quarantine_tts_lane(self.resource_key)

    def start_delivery(self) -> None:
        self._started_at = time.monotonic()

    def record_metrics(self, pcm_bytes: int) -> None:
        self.metrics.record_tts(
            voice_class=self.voice_class,
            char_count=self.raw_character_count,
            audio_duration_sec=pcm_bytes / 2 / self.sample_rate,
            inference_duration_sec=time.monotonic() - self._started_at,
        )

    def complete_delivery(self) -> None:
        if self.receipt_id is not None and not self.reclamation_failed:
            self.receipts.complete(self.receipt_id)

    def fail_delivery(self, code: str) -> None:
        if self.receipt_id is not None and not self.reclamation_failed:
            self.receipts.fail(self.receipt_id, code)

    def deliver(
        self,
        source: AsyncIterator[bytes],
        first: bytes,
        *,
        counter: PcmOutputCounter,
    ) -> AsyncIterator[bytes]:
        if self._delivery_source is not None:
            raise RuntimeError("render delivery already has an owner")
        self._delivery_source = source

        async def body() -> AsyncIterator[bytes]:
            cancelled = False
            failed = False
            try:
                yield first
                async for chunk in iter_until(source, self.expires_at):
                    yield chunk
                self.record_metrics(counter.total_bytes)
                self.complete_delivery()
            except asyncio.CancelledError, GeneratorExit:
                cancelled = True
                raise
            except BaseException:
                failed = True
                raise
            finally:

                async def finish() -> None:
                    await close_render_stream(source)
                    if self.receipt_id is not None and not self.reclamation_failed:
                        if cancelled:
                            self.receipts.cancel(self.receipt_id)
                        elif failed:
                            self.receipts.fail(self.receipt_id, "stream_delivery_error")

                await join_cleanup(asyncio.create_task(finish(), name="render-delivery-close"))

        self._delivery_body = body()
        return self._delivery_body

    async def close_delivery(self) -> None:
        if self._delivery_source is None or self._delivery_body is None:
            return
        try:
            await close_render_stream(self._delivery_body)
        finally:
            await close_render_stream(self._delivery_source)
        if not self.reclamation_failed:
            if self.receipt_id is not None:
                self.receipts.cancel(self.receipt_id)
            if self.timing_id is not None:
                self.timings.cancel(self.timing_id)

    async def pcm(self, *, counter: PcmOutputCounter | None = None) -> AsyncIterator[bytes]:
        if self._execution_started:
            raise RuntimeError("render execution already has an owner")
        self._execution_started = True
        # Integrity and timing are measured over validated PCM16 before encoding.
        backend_response_id: str | None = None
        emitted_samples = 0
        runtime_revision_checked = False
        try:
            async with self.governor.reserve(
                self.work_class,
                expires_at=self.expires_at,
                resource_key=self.resource_key,
                purpose=self.work_purpose,
            ):
                admitted_synthesis = await await_until(
                    prepare_validated_speech(
                        self.request,
                        preparer=self.execution.preparer,
                        artifact=self.artifact,
                        capability_key=self.capability_key,
                        registry=self.voices,
                    ),
                    self.expires_at,
                )
                # Closing the response must join the backend iterator before
                # leaving its Governor reservation, including at a yield.
                validated = iter_until(
                    iter_validated_audio(
                        self.synthesizer.synthesize(admitted_synthesis),
                        on_close_failure=self.quarantine_backend,
                    ),
                    self.expires_at,
                )
                async with contextlib.aclosing(validated) as chunks:
                    async for chunk in chunks:
                        if backend_response_id is None:
                            backend_response_id = chunk.response_id
                        emitted_samples += len(chunk.audio) // 2
                        if counter is not None:
                            counter.accept(len(chunk.audio))
                        if self.receipt_id is not None and not self.reclamation_failed:
                            if not runtime_revision_checked:
                                runtime_revision_checked = True
                                if admitted_synthesis.expected_runtime_revision is not None:
                                    self.receipts.bind_model_runtime_revision(
                                        self.receipt_id,
                                        admitted_synthesis.expected_runtime_revision,
                                    )
                                else:
                                    bind_observed_runtime_revision(
                                        self.receipts,
                                        self.receipt_id,
                                        runtime_identity=self.execution.runtime_identity,
                                        voice=self.request.voice,
                                    )
                            self.receipts.accept_pcm(
                                self.receipt_id,
                                chunk.audio,
                            )
                        yield chunk.audio
            if (
                self.receipt_id is not None
                and backend_response_id is not None
                and emitted_samples > 0
            ):
                # The sampler is only knowable once the worker has finished:
                # a request can ask for a seed and still run unseeded.
                bind_observed_sampling(
                    self.receipts,
                    self.receipt_id,
                    sampling=self.execution.sampling,
                    response_id=backend_response_id,
                )
            if self.timing_id is not None and not self.reclamation_failed:
                if emitted_samples <= 0 or backend_response_id is None:
                    self.timings.fail(self.timing_id, "empty_audio")
                else:
                    take_timing = getattr(
                        self.synthesizer,
                        "take_timing_sidecar",
                        None,
                    )
                    sidecar = take_timing(backend_response_id) if callable(take_timing) else None
                    if sidecar is None:
                        self.timings.unavailable(
                            self.timing_id,
                            "backend_timing_metadata_unavailable",
                        )
                    else:
                        self.timings.complete(
                            self.timing_id,
                            sidecar,
                            actual_samples=emitted_samples,
                        )
        except asyncio.CancelledError:
            if not self.reclamation_failed:
                if self.receipt_id is not None:
                    self.receipts.cancel(self.receipt_id)
                if self.timing_id is not None:
                    self.timings.cancel(self.timing_id)
            raise
        except TTSDeliveryError as exc:
            self._fail_execution(exc.code)
            raise
        except VoiceRevisionConflictError:
            self._fail_execution("voice_revision_conflict")
            raise
        except VoiceRevokedError:
            self._fail_execution("voice_revoked")
            raise
        except VoiceStoreUnavailableError:
            self._fail_execution("voice_store_unavailable")
            raise
        except GovernorQueueFullError as exc:
            self._fail_execution(
                "backend_reclamation_failed"
                if isinstance(exc, GovernorLaneIsolatedError)
                else "queue_full"
            )
            raise
        except TimeoutError:
            self._fail_execution("backend_timeout")
            raise
        except OverflowError:
            self._fail_execution("audio_encode_failed")
            raise
        except RuntimeError as exc:
            self._fail_execution(_tts_backend_failure_code(exc))
            raise

    def _fail_execution(self, code: str) -> None:
        if self.reclamation_failed:
            return
        if self.receipt_id is not None:
            self.receipts.fail(self.receipt_id, code)
        if self.timing_id is not None:
            self.timings.fail(self.timing_id, code)
