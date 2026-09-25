"""Application-level ownership of one incremental TTS utterance.

The controller is the single place where an incremental utterance reaches a
terminal state.  It reserves governor capacity, owns the vendor session (which in
turn holds the model worker slot and the voice lease) and keeps the bounded
render receipt, so that a ``complete``/``cancel``/``error`` race has exactly one
winner.  Appended text is never retained: each bounded packet is forwarded to the
model and dropped, therefore no whole-utterance prompt survives in this process.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Awaitable, Callable
from contextlib import AbstractAsyncContextManager, AsyncExitStack
from dataclasses import dataclass
from typing import cast

from speechrail.application.render_receipts import (
    RenderReceiptRegistry,
    bind_observed_runtime_revision,
)
from speechrail.application.tts_admission import (
    supports_incremental_stream,
    tts_resource_key,
)
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    IncrementalSpeechSession,
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.runtime.busy import BusyReason
from speechrail.runtime.resource_governor import (
    GovernorQueueFullError,
    ResourceGovernor,
    WorkClass,
    WorkPurpose,
)

logger = logging.getLogger(__name__)

_BACKEND_FAILURE_CODE = "tts_backend_failed"
_INPUT_TIMEOUT_CODE = "tts_input_timeout"
_CANCELLED_CODE = "cancelled"

TtsStreamSink = Callable[[TtsStreamEvent], Awaitable[None]]
WorkerLeaseFactory = Callable[[], AbstractAsyncContextManager[object]]


class TtsStreamAdmissionError(RuntimeError):
    """One incremental utterance never reached its starting state."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        busy_reason: BusyReason | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        if busy_reason is not None:
            self.busy_reason = busy_reason


@dataclass(frozen=True, slots=True)
class TtsStreamReceipt:
    """Static receipt metadata the caller resolved before generation started."""

    voice_revision: str | None = None
    model_artifact: str | None = None
    model_source: str | None = None
    model_variant: str | None = None
    model_catalog_revision: str | None = None
    sample_rate: int = 24_000
    channels: int = 1
    boundary: str = "pcm16_after_transport_send"


class StreamController:
    """One incremental utterance with exactly one downstream terminal event.

    Terminal claims are synchronous on the single event loop, and only this
    controller's own task writes to the sink, so a race between a vendor
    ``completed`` event, a caller ``cancel`` and a deadline can never emit audio
    after the terminal, emit two terminals, or finalize the receipt twice.
    """

    def __init__(
        self,
        *,
        session: IncrementalSpeechSession,
        options: TtsStreamOptions,
        limits: TtsStreamLimits,
        sink: TtsStreamSink,
        admission: AsyncExitStack,
        receipts: RenderReceiptRegistry | None = None,
        receipt_id: str | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._session = session
        self._options = options
        self._limits = limits
        self._sink = sink
        self._admission = admission
        self._receipts = receipts if receipt_id is not None else None
        self._receipt_id = receipt_id
        self._clock = clock or time.monotonic
        self._terminal: TtsStreamTerminal | None = None
        self._terminal_detail: str | None = None
        self._delivered_samples = 0
        self._input_open = True
        self._closed = False
        self._failure: BaseException | None = None
        self._send_lock = asyncio.Lock()
        self._activity = asyncio.Event()
        self._opened_at = self._clock()
        self._last_activity = self._opened_at
        self._watchdog: asyncio.Task[None] | None = None
        self._task: asyncio.Task[None] | None = None

    @property
    def options(self) -> TtsStreamOptions:
        return self._options

    @property
    def limits(self) -> TtsStreamLimits:
        return self._limits

    @property
    def receipt_id(self) -> str | None:
        return self._receipt_id

    @property
    def terminal(self) -> TtsStreamTerminal | None:
        return self._terminal

    @property
    def terminal_detail(self) -> str | None:
        return self._terminal_detail

    @property
    def delivered_samples(self) -> int:
        """Return the number of PCM samples that left this process."""

        return self._delivered_samples

    @property
    def failure(self) -> BaseException | None:
        """Return the unexpected backend fault, when the stream did not finish."""

        return self._failure

    @property
    def active(self) -> bool:
        return self._terminal is None

    @property
    def closed(self) -> bool:
        return self._closed

    def start(self) -> None:
        """Begin the single controller task; opening never waits for generation."""

        if self._task is not None:
            return
        self._watchdog = asyncio.create_task(self._watch(), name="tts-stream-deadline")
        self._task = asyncio.create_task(self._run(), name="tts-stream-controller")
        self._task.add_done_callback(self._log_unexpected_task_failure)

    async def append_text(self, sequence: int, text: str) -> None:
        """Forward one bounded text packet without retaining it."""

        if self._terminal is not None:
            raise TtsStreamError(
                "tts_input_closed", "the incremental utterance already terminated"
            )
        await self._session.append_text(sequence, text)
        self._touch()

    async def finish_text(self, last_sequence: int) -> None:
        """Close the text side; generation continues until its terminal event."""

        if self._terminal is not None:
            raise TtsStreamError(
                "tts_input_closed", "the incremental utterance already terminated"
            )
        await self._session.finish_text(last_sequence)
        self._input_open = False
        self._touch()

    async def cancel(self, *, reason: str = _CANCELLED_CODE) -> None:
        """Stop generation cooperatively and settle the utterance as cancelled."""

        if self._claim(TtsStreamTerminal.CANCELLED, reason):
            with contextlib.suppress(Exception):
                await self._session.cancel()
        await self.wait_closed()

    async def aclose(self, *, reason: str = _CANCELLED_CODE) -> None:
        """Release every resource; an active utterance is cancelled first."""

        if self._task is None:
            self._claim(TtsStreamTerminal.CANCELLED, reason)
            self._finish_receipt(TtsStreamTerminal.CANCELLED, self._terminal_detail)
            await self._shutdown()
            return
        if self._terminal is None:
            await self.cancel(reason=reason)
            return
        await self.wait_closed()

    async def wait_closed(self) -> None:
        """Await the controller task without letting a caller cancel it."""

        task = self._task
        if task is None:
            return
        await asyncio.shield(task)

    def _touch(self) -> None:
        self._last_activity = self._clock()
        self._activity.set()

    def _claim(self, outcome: TtsStreamTerminal, detail: str | None) -> bool:
        """Record the first terminal outcome; the check and the write never interleave."""

        if self._terminal is not None:
            return False
        self._terminal = outcome
        if outcome is TtsStreamTerminal.FAILED:
            self._terminal_detail = detail or _BACKEND_FAILURE_CODE
        elif outcome is TtsStreamTerminal.CANCELLED:
            self._terminal_detail = detail or _CANCELLED_CODE
        else:
            self._terminal_detail = None
        self._activity.set()
        return True

    async def _run(self) -> None:
        try:
            async for event in self._session.events():
                if self._terminal is not None:
                    break
                await self._deliver(event)
                if self._terminal is not None:
                    break
            if self._terminal is None:
                # A vendor stream must end with exactly one terminal event.
                self._claim(TtsStreamTerminal.FAILED, _BACKEND_FAILURE_CODE)
        except TtsStreamError as exc:
            self._failure = exc
            self._claim(TtsStreamTerminal.FAILED, exc.code)
        except Exception as exc:
            self._failure = exc
            logger.warning("incremental TTS stream failed: code=%s", _BACKEND_FAILURE_CODE)
            self._claim(TtsStreamTerminal.FAILED, _BACKEND_FAILURE_CODE)
        finally:
            await self._settle()

    async def _deliver(self, event: TtsStreamEvent) -> None:
        if event.terminal is not None:
            self._claim(event.terminal, event.error_code)
            return
        if event.kind is TtsStreamEventKind.AUDIO:
            pcm16 = event.pcm16
            if await self._send(event):
                self._record_delivered(pcm16)
            return
        if event.kind is TtsStreamEventKind.TEXT_ACCEPTED:
            self._touch()
        await self._send(event)

    async def _send(self, event: TtsStreamEvent) -> bool:
        """Deliver one event downstream; late non-terminal events are dropped."""

        async with self._send_lock:
            if event.terminal is None and self._terminal is not None:
                return False
            try:
                async with asyncio.timeout(self._limits.slow_consumer_seconds):
                    await self._sink(event)
            except TimeoutError as exc:
                raise TtsStreamError(
                    "tts_backpressure", "the downstream consumer is not draining audio"
                ) from exc
        return True

    def _record_delivered(self, pcm16: bytes) -> None:
        """Count PCM that already left this process; unsent PCM is never counted."""

        self._delivered_samples += len(pcm16) // 2
        if self._receipts is None or self._receipt_id is None:
            return
        with contextlib.suppress(RuntimeError):
            self._receipts.accept_pcm(self._receipt_id, pcm16)

    async def _watch(self) -> None:
        """Cancel an utterance that starves for text or outlives its wall clock."""

        while self._terminal is None:
            now = self._clock()
            remaining = self._deadline() - now
            if remaining <= 0:
                self._claim(TtsStreamTerminal.FAILED, self._expiry_code())
                with contextlib.suppress(Exception):
                    await self._session.cancel()
                return
            self._activity.clear()
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._activity.wait(), timeout=remaining)

    def _deadline(self) -> float:
        wall_clock = self._opened_at + self._limits.utterance_wall_clock_seconds
        if self._input_open:
            return min(wall_clock, self._last_activity + self._limits.input_wait_seconds)
        return wall_clock

    def _expiry_code(self) -> str:
        return _INPUT_TIMEOUT_CODE if self._input_open else _BACKEND_FAILURE_CODE

    async def _settle(self) -> None:
        """Finalize the receipt, then emit the single downstream terminal event."""

        if self._terminal is None:
            self._claim(TtsStreamTerminal.FAILED, _BACKEND_FAILURE_CODE)
        outcome = self._terminal
        assert outcome is not None  # the claim above always records one
        self._finish_receipt(outcome, self._terminal_detail)
        try:
            await self._send(self._terminal_event(outcome, self._terminal_detail))
        except Exception:
            logger.warning("incremental TTS terminal event was not delivered")
        await self._shutdown()

    def _terminal_event(self, outcome: TtsStreamTerminal, detail: str | None) -> TtsStreamEvent:
        if outcome is TtsStreamTerminal.FAILED:
            return TtsStreamEvent(
                kind=TtsStreamEventKind.FAILED,
                response_id=self._options.response_id,
                terminal=outcome,
                error_code=detail or _BACKEND_FAILURE_CODE,
            )
        kind = (
            TtsStreamEventKind.COMPLETED
            if outcome is TtsStreamTerminal.COMPLETED
            else TtsStreamEventKind.CANCELLED
        )
        return TtsStreamEvent(
            kind=kind,
            response_id=self._options.response_id,
            terminal=outcome,
        )

    def _finish_receipt(self, outcome: TtsStreamTerminal, detail: str | None) -> None:
        """Collapse the render receipt exactly once, from the delivered facts."""

        if self._receipts is None or self._receipt_id is None:
            return
        with contextlib.suppress(Exception):
            if outcome is TtsStreamTerminal.COMPLETED:
                self._receipts.complete(self._receipt_id)
            elif outcome is TtsStreamTerminal.CANCELLED:
                self._receipts.cancel(self._receipt_id, error_code=detail or _CANCELLED_CODE)
            else:
                self._receipts.fail(self._receipt_id, detail or _BACKEND_FAILURE_CODE)

    async def _shutdown(self) -> None:
        """Stop generation, confirm reclamation, then release references and resources."""

        if self._closed:
            return
        self._closed = True
        watchdog = self._watchdog
        self._watchdog = None
        if watchdog is not None and watchdog is not asyncio.current_task():
            watchdog.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await watchdog
        with contextlib.suppress(Exception):
            await self._session.close()
        await self._admission.aclose()

    def _log_unexpected_task_failure(self, task: asyncio.Task[None]) -> None:
        with contextlib.suppress(asyncio.CancelledError):
            error = task.exception()
        if error is None:
            return
        logger.warning(
            "incremental TTS controller ended with an error: type=%s", type(error).__name__
        )


class TtsStreamService:
    """Open application-owned incremental utterances for one service instance."""

    def __init__(
        self,
        *,
        synthesizer: object | None,
        governor: ResourceGovernor,
        receipts: RenderReceiptRegistry,
        worker_lease: WorkerLeaseFactory | None = None,
        limits: TtsStreamLimits = DEFAULT_TTS_STREAM_LIMITS,
        admission_timeout_seconds: float = 10.0,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self.synthesizer = synthesizer
        self.governor = governor
        self.receipts = receipts
        self.worker_lease = worker_lease
        self.limits = limits
        self.admission_timeout_seconds = admission_timeout_seconds
        self._clock = clock or time.monotonic

    @property
    def supported(self) -> bool:
        """Whether the configured synthesizer negotiated the incremental port."""

        return supports_incremental_stream(self.synthesizer)

    async def open(
        self,
        *,
        options: TtsStreamOptions,
        sink: TtsStreamSink,
        receipt: TtsStreamReceipt | None = None,
        limits: TtsStreamLimits | None = None,
    ) -> StreamController:
        """Admit one utterance and return a controller that is already running."""

        if not self.supported:
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the configured synthesizer exposes no incremental stream",
            )
        effective = limits or self.limits
        resource_key = tts_resource_key(self.synthesizer, options.voice)
        admission = AsyncExitStack()
        session: IncrementalSpeechSession | None = None
        receipt_id: str | None = None
        try:
            await admission.enter_async_context(
                self.governor.reserve(
                    WorkClass.REALTIME_TTS,
                    deadline=self.admission_timeout_seconds,
                    resource_key=resource_key,
                    purpose=WorkPurpose.INTERACTIVE,
                )
            )
            if self.worker_lease is not None:
                await admission.enter_async_context(self.worker_lease())
            session = await self._open_session(options)
            if receipt is not None:
                try:
                    receipt_id = self._begin_receipt(options, receipt)
                except RuntimeError as exc:
                    raise TtsStreamAdmissionError(
                        "render_receipt_store_full",
                        "render receipt store has no safe capacity",
                    ) from exc
        except GovernorQueueFullError as exc:
            await self._abort_open(session, admission)
            raise TtsStreamAdmissionError(
                "queue_full",
                "TTS stream admission queue is full",
                busy_reason=BusyReason.GOVERNOR_QUEUE_FULL,
            ) from exc
        except TimeoutError as exc:
            await self._abort_open(session, admission)
            raise TtsStreamAdmissionError(
                "backend_timeout",
                "TTS stream admission timed out",
                busy_reason=BusyReason.BACKEND_TRANSITION,
            ) from exc
        except BaseException:
            await self._abort_open(session, admission)
            raise
        assert session is not None  # a controller is only built after the session opened
        controller = StreamController(
            session=session,
            options=options,
            limits=effective,
            sink=sink,
            admission=admission,
            receipts=self.receipts,
            receipt_id=receipt_id,
            clock=self._clock,
        )
        controller.start()
        return controller

    async def _open_session(self, options: TtsStreamOptions) -> IncrementalSpeechSession:
        opener = getattr(self.synthesizer, "open_incremental_stream", None)
        if not callable(opener):
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the configured synthesizer exposes no incremental stream",
            )
        return cast(IncrementalSpeechSession, await opener(options))

    def _begin_receipt(self, options: TtsStreamOptions, receipt: TtsStreamReceipt) -> str:
        receipt_id = self.receipts.begin(
            request_id=options.request_id,
            response_id=options.response_id,
            voice_id=options.voice,
            voice_revision=receipt.voice_revision or options.expected_voice_revision,
            model_artifact=receipt.model_artifact,
            model_source=receipt.model_source,
            model_variant=receipt.model_variant,
            model_catalog_revision=receipt.model_catalog_revision,
            model_runtime_revision=None,
            output_format="pcm16",
            sample_rate=receipt.sample_rate,
            channels=receipt.channels,
            boundary=receipt.boundary,
        )
        bind_observed_runtime_revision(
            self.receipts,
            receipt_id,
            synthesizer=self.synthesizer,
            voice=options.voice,
        )
        return receipt_id

    @staticmethod
    async def _abort_open(
        session: IncrementalSpeechSession | None,
        admission: AsyncExitStack,
    ) -> None:
        if session is not None:
            with contextlib.suppress(Exception):
                await session.close()
        with contextlib.suppress(Exception):
            await admission.aclose()


__all__ = [
    "StreamController",
    "TtsStreamAdmissionError",
    "TtsStreamReceipt",
    "TtsStreamService",
    "TtsStreamSink",
]
