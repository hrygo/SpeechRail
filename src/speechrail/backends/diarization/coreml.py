"""FluidAudio CoreML FP16 adapter for the streaming Sortformer port.

The adapter owns no inference model in Python.  It starts the one private Swift
worker only when a diarization session is active and validates every worker
message before it reaches the domain layer.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable
from hashlib import sha256
from pathlib import Path

from speechrail.domain.diarization import (
    DiarizationError,
    DiarizationReadiness,
)
from speechrail.domain.diarization.ports import ActivitySession
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, Span
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

MODEL_REVISION = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
FLUIDAUDIO_COMMIT = "5c19d5e12320e22bbfb7a1877b089d2665a69add"
MODEL_BUNDLE_NAME = "SortformerNvidiaLow_v2.1.mlmodelc"
MODEL_FILE_SHA256 = {
    "analytics/coremldata.bin": "70bd26bbe2113b3d3f99ecd7190bac9752f372e42fe2700a2e660f5d8a9cac66",
    "coremldata.bin": "7a075630dbbe73008832a3bd063090ddb9ab330300234efbd2089737b17b3894",
    "model0/analytics/coremldata.bin": (
        "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"
    ),
    "model0/coremldata.bin": "756388544ce428450e8e11aa18528b12c10a3b5efd85a13223c7ab62cbfbfd79",
    "model0/model.mil": "edb8a3b2ecb63a02918edee790e780f74a22f1a475484142be3c35c9b884e2dc",
    "model0/weights/0-weight.bin": (
        "88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4"
    ),
    "model1/analytics/coremldata.bin": (
        "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"
    ),
    "model1/coremldata.bin": "51f7543d79af345a1af42feb9a0dcf0527e11293ba97c84f55f525032eb1e4e8",
    "model1/model.mil": "ae2931b75d1b44eea18accc9a9c3dc24212c8a5310af149c2dae158e9773ace3",
    "model1/weights/1-weight.bin": (
        "1e362707e5db14efdf2bf2900a511b8343bf10c7f8fe463b58d370d0ba2a34ff"
    ),
}
MODEL_MIL_SIGNATURES = {
    "model0/model.mil": (
        "tensor<fp32, [1, 112, 128]> chunk",
        "tensor<fp32, [1, 188, 512]> fifo",
        "tensor<fp32, [1, 188, 512]> spkcache",
        "tensor<fp32, [1, 390, 512]> pre_encoder_embs",
    ),
    "model1/model.mil": (
        "tensor<fp32, [1, 390, 512]> pre_encoder_embs",
        "tensor<fp32, [1, 390, 4]> speaker_preds",
    ),
}
_ACTIVITY_THRESHOLD = 0.25


class CoreMLSortformerEngine:
    """The only production implementation of the streaming activity port."""

    supports_stream = True

    def __init__(
        self,
        *,
        model_path: Path,
        executable: Path,
        worker_factory: Callable[[], CoreMLWorkerProcess] | None = None,
        required_hashes: dict[str, str] | None = None,
        required_signatures: dict[str, tuple[str, ...]] | None = None,
    ) -> None:
        self._model_path = model_path
        self._executable = executable
        self._worker_factory = worker_factory
        self._required_hashes = (
            MODEL_FILE_SHA256 if required_hashes is None else required_hashes
        )
        self._required_signatures = (
            MODEL_MIL_SIGNATURES if required_signatures is None else required_signatures
        )
        self._readiness = self._check_readiness()

    @property
    def readiness(self) -> DiarizationReadiness:
        return self._readiness

    def open(self, *, epoch: str) -> ActivitySession:
        """Open one session-scoped activity stream with an opaque epoch."""

        if not epoch:
            raise ValueError("diarization epoch must not be empty")
        if not self._readiness.ready:
            raise DiarizationError(
                self._readiness.message,
                code=self._readiness.code or "diarization_not_available",
            )
        factory = self._worker_factory
        worker = (
            factory()
            if factory is not None
            else CoreMLWorkerProcess(executable=self._executable, model_path=self._model_path)
        )
        return CoreMLActivitySession(worker=worker, epoch=epoch)

    def _check_readiness(self) -> DiarizationReadiness:
        if self._model_path.name != MODEL_BUNDLE_NAME or not self._model_path.is_dir():
            return DiarizationReadiness(
                configured=True,
                ready=False,
                code="diarization_not_available",
                message="the required compiled CoreML diarization bundle is unavailable",
                profile="coreml-sortformer-fp16",
            )
        for relative_path, expected_hash in self._required_hashes.items():
            artifact = self._model_path / relative_path
            if not artifact.is_file() or _sha256(artifact) != expected_hash:
                return DiarizationReadiness(
                    configured=True,
                    ready=False,
                    code="diarization_not_available",
                    message="the CoreML diarization bundle does not match the pinned artifact",
                    profile="coreml-sortformer-fp16",
                )
        for relative_path, expected_signatures in self._required_signatures.items():
            artifact = self._model_path / relative_path
            if not artifact.is_file() or not _has_signatures(artifact, expected_signatures):
                return DiarizationReadiness(
                    configured=True,
                    ready=False,
                    code="diarization_not_available",
                    message="the CoreML diarization bundle has an unexpected model signature",
                    profile="coreml-sortformer-fp16",
                )
        if not self._executable.is_file():
            return DiarizationReadiness(
                configured=True,
                ready=False,
                code="diarization_not_available",
                message="the CoreML diarization worker executable is unavailable",
                profile="coreml-sortformer-fp16",
            )
        return DiarizationReadiness(
            configured=True,
            ready=True,
            code=None,
            message="CoreML Sortformer FP16 is configured",
            profile="coreml-sortformer-fp16",
        )


def _sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _has_signatures(path: Path, signatures: tuple[str, ...]) -> bool:
    data = path.read_bytes()
    return all(signature.encode() in data for signature in signatures)


class CoreMLActivitySession:
    """Validated bridge from the private Swift process to ``ActivityUpdate``."""

    def __init__(self, *, worker: CoreMLWorkerProcess, epoch: str) -> None:
        self._worker = worker
        self._epoch = epoch
        self._next_start = 0
        self._processed = 0
        self._stable = 0
        self._step_id = 0
        self._closed = False
        self._started = False
        self._updates: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        if self._closed or len(pcm16) % 2:
            raise DiarizationError("invalid PCM for CoreML diarization", code="invalid_audio")
        if start_sample != self._next_start:
            raise DiarizationError("diarization sample continuity broken", code="invalid_audio")
        await self._start()
        samples = len(pcm16) // 2
        response, _ = await self._request(
            {
                "epoch": self._epoch,
                "operation": "append",
                "audio_start": start_sample,
                "audio_samples": samples,
            },
            pcm16,
        )
        self._next_start += samples
        await self._publish(response, operation="append")

    async def updates(self) -> AsyncIterator[ActivityUpdate]:
        while update := await self._updates.get():
            yield update

    async def finish(self, *, through_sample: int) -> None:
        if self._closed:
            raise DiarizationError("diarization stream is closed", code="invalid_audio")
        if through_sample != self._next_start:
            raise DiarizationError(
                "finish watermark does not match accepted audio", code="invalid_audio"
            )
        try:
            await self._start()
            response, _ = await self._request(
                {"epoch": self._epoch, "operation": "finish", "through_sample": through_sample}
            )
            await self._publish(response, operation="finish")
        finally:
            # A CoreML worker belongs to exactly one continuous session.  EOF
            # must release the same child after its final snapshot so the model
            # cannot survive as an untracked resident process.
            await self._worker.close()
            await self._close_updates()

    async def cancel(self) -> None:
        if self._closed:
            return
        self._closed = True
        await self._worker.close()
        await self._close_updates()

    async def _start(self) -> None:
        if not self._started:
            try:
                await self._worker.start()
            except RuntimeError as exc:
                raise DiarizationError(
                    "CoreML diarization worker failed", code="diarization_invalid_output"
                ) from exc
            self._started = True

    async def _request(
        self, header: dict[str, object], audio: bytes = b""
    ) -> tuple[dict[str, object], bytes]:
        try:
            return await self._worker.request(header, audio)
        except RuntimeError as exc:
            raise DiarizationError(
                "CoreML diarization worker failed", code="diarization_invalid_output"
            ) from exc

    async def _publish(self, response: dict[str, object], *, operation: str) -> None:
        if response.get("epoch") != self._epoch or response.get("operation") != operation:
            raise DiarizationError(
                "CoreML diarization response does not match its request",
                code="diarization_invalid_output",
            )
        update = _update_from_response(
            response,
            epoch=self._epoch,
            step_id=self._step_id,
            replace_start=self._processed,
            accepted=self._next_start,
        )
        self._step_id += 1
        self._processed = update.processed_through
        self._stable = update.stable_through
        await self._updates.put(update)

    async def _close_updates(self) -> None:
        if not self._closed:
            self._closed = True
        await self._updates.put(None)


def _update_from_response(
    response: dict[str, object],
    *,
    epoch: str,
    step_id: int,
    replace_start: int,
    accepted: int,
) -> ActivityUpdate:
    if response.get("ok") is not True:
        raise DiarizationError(
            "CoreML diarization worker rejected the request", code="diarization_invalid_output"
        )
    processed = response.get("processed_through")
    stable = response.get("stable_through")
    raw_frames = response.get("frames", [])
    if (
        not isinstance(processed, int)
        or not isinstance(stable, int)
        or not isinstance(raw_frames, list)
    ):
        raise DiarizationError(
            "invalid CoreML diarization response", code="diarization_invalid_output"
        )
    if not 0 <= stable <= processed <= accepted:
        raise DiarizationError(
            "invalid CoreML diarization watermark", code="diarization_invalid_output"
        )
    frames: list[ActivityFrame] = []
    for raw in raw_frames:
        if not isinstance(raw, dict):
            raise DiarizationError(
                "invalid CoreML activity frame", code="diarization_invalid_output"
            )
        start, end, scores = raw.get("start"), raw.get("end"), raw.get("scores")
        if (
            not isinstance(start, int)
            or not isinstance(end, int)
            or not isinstance(scores, list)
            or len(scores) != 4
        ):
            raise DiarizationError(
                "invalid CoreML activity frame", code="diarization_invalid_output"
            )
        for _slot, score in enumerate(scores):
            if not isinstance(score, (int, float)) or not 0 <= float(score) <= 1:
                raise DiarizationError(
                    "invalid CoreML activity score", code="diarization_invalid_output"
                )
        if start < replace_start or end > processed:
            raise DiarizationError(
                "CoreML activity frame is outside its replacement range",
                code="diarization_invalid_output",
            )
        frames.append(
            ActivityFrame(
                span=Span(start, min(end, accepted)),
                scores=tuple(float(score) for score in scores),  # type: ignore[arg-type]
                active_slots=frozenset(
                    slot for slot, score in enumerate(scores) if float(score) >= _ACTIVITY_THRESHOLD
                ),
            )
        )
    return ActivityUpdate(
        epoch=epoch,
        step_id=step_id,
        replace_span=Span(replace_start, processed),
        frames=tuple(frames),
        processed_through=processed,
        stable_through=stable,
    )
