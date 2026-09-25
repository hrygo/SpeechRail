"""Application-level lifecycle for one incremental TTS utterance.

These tests use a fake vendor session so the admission, delivery, receipt and
terminal rules of ``application.tts_stream`` are verified deterministically,
without a model, a worker process or a public transport.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable

import pytest

from speechrail.application.render_receipts import RenderReceiptRegistry
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.application.tts_stream import (
    TtsStreamAdmissionError,
    TtsStreamReceipt,
    TtsStreamService,
)
from speechrail.config import Settings
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.domain.tts import VoiceRevokedError
from speechrail.domain.tts_stream import (
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.runtime.resource_governor import (
    ResourceGovernor,
    WorkClass,
    WorkPurpose,
)
from speechrail.runtime.worker_lease import WorkerIdleEvictor, WorkerLifecycleState

_PCM = b"\x01\x00\x02\x00"
_REVISION = "rt_" + ("a" * 64)


def _options(voice: str = "serena") -> TtsStreamOptions:
    return TtsStreamOptions(request_id="req-1", response_id="resp-1", voice=voice)


def _audio_event(index: int = 0, pcm: bytes = _PCM) -> TtsStreamEvent:
    return TtsStreamEvent(
        kind=TtsStreamEventKind.AUDIO,
        response_id="resp-1",
        pcm16=pcm,
        chunk_index=index,
        sample_offset=index * (len(pcm) // 2),
    )


def _terminal_event(
    outcome: TtsStreamTerminal,
    *,
    error_code: str | None = None,
) -> TtsStreamEvent:
    kind = {
        TtsStreamTerminal.COMPLETED: TtsStreamEventKind.COMPLETED,
        TtsStreamTerminal.CANCELLED: TtsStreamEventKind.CANCELLED,
        TtsStreamTerminal.FAILED: TtsStreamEventKind.FAILED,
    }[outcome]
    return TtsStreamEvent(
        kind=kind,
        response_id="resp-1",
        terminal=outcome,
        error_code=error_code,
    )


class _FakeSession:
    """Minimal ``IncrementalSpeechSession`` driven directly by one test."""

    def __init__(self, options: TtsStreamOptions) -> None:
        self._options = options
        self.queued: asyncio.Queue[TtsStreamEvent | None] = asyncio.Queue()
        self.appends: list[tuple[int, str]] = []
        self.finishes: list[int] = []
        self.cancels = 0
        self.closes = 0
        self.order: list[str] = []

    @property
    def options(self) -> TtsStreamOptions:
        return self._options

    async def append_text(self, sequence: int, text: str) -> None:
        self.appends.append((sequence, text))

    async def finish_text(self, last_sequence: int) -> None:
        self.finishes.append(last_sequence)

    async def events(self) -> AsyncIterator[TtsStreamEvent]:
        while True:
            item = await self.queued.get()
            if item is None:
                return
            yield item

    async def cancel(self) -> None:
        self.cancels += 1
        self.queued.put_nowait(None)

    async def close(self) -> None:
        if self.closes == 0:
            self.order.append("session-close")
        self.closes += 1
        self.queued.put_nowait(None)

    def push(self, event: TtsStreamEvent) -> None:
        self.queued.put_nowait(event)


class _FakeSynthesizer:
    """One capability router stand-in exposing lane and identity hints."""

    def __init__(self, *, failures: dict[str, BaseException] | None = None) -> None:
        self.failures = dict(failures or {})
        self.opened: list[TtsStreamOptions] = []
        self.sessions: list[_FakeSession] = []
        self.runtime_revision: str | None = None

    def resource_key_for_voice(self, voice: str) -> str:
        return f"lane:{voice}"

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        return self.runtime_revision

    async def open_incremental_stream(self, options: TtsStreamOptions) -> _FakeSession:
        failure = self.failures.pop(options.voice, None)
        if failure is not None:
            raise failure
        session = _FakeSession(options)
        self.opened.append(options)
        self.sessions.append(session)
        return session


class _Sink:
    """Downstream transport stand-in that records every delivered event."""

    def __init__(self) -> None:
        self.events: list[TtsStreamEvent] = []
        self.fail_audio = False

    async def __call__(self, event: TtsStreamEvent) -> None:
        if self.fail_audio and event.kind is TtsStreamEventKind.AUDIO:
            raise RuntimeError("transport is gone")
        self.events.append(event)

    @property
    def terminals(self) -> list[TtsStreamEvent]:
        return [event for event in self.events if event.terminal is not None]


def _governor(total_capacity: int = 3) -> ResourceGovernor:
    return ResourceGovernor(
        GovernorLimits(
            total_capacity=total_capacity,
            realtime_reserved_capacity=1,
            max_pending_per_class=4,
        )
    )


def _service(
    synthesizer: object,
    *,
    governor: ResourceGovernor | None = None,
    receipts: RenderReceiptRegistry | None = None,
    worker_lease: Callable | None = None,
    admission_timeout_seconds: float = 1.0,
) -> TtsStreamService:
    return TtsStreamService(
        synthesizer=synthesizer,
        governor=governor or _governor(),
        receipts=receipts or RenderReceiptRegistry(),
        worker_lease=worker_lease,
        admission_timeout_seconds=admission_timeout_seconds,
    )


def test_finish_and_cancel_race_emits_exactly_one_terminal() -> None:
    async def run() -> None:
        for yields in range(4):
            synth = _FakeSynthesizer()
            receipts = RenderReceiptRegistry()
            service = _service(synth, receipts=receipts)
            sink = _Sink()
            controller = await service.open(
                options=_options(), sink=sink, receipt=TtsStreamReceipt()
            )
            session = synth.sessions[0]
            await controller.append_text(0, "你好")
            await controller.finish_text(0)
            session.push(_audio_event())
            session.push(_terminal_event(TtsStreamTerminal.COMPLETED))
            for _ in range(yields):
                await asyncio.sleep(0)
            await controller.cancel()
            await asyncio.wait_for(controller.wait_closed(), timeout=2.0)

            assert len(sink.terminals) == 1, yields
            assert sink.terminals[0].terminal is controller.terminal
            assert controller.terminal in {
                TtsStreamTerminal.COMPLETED,
                TtsStreamTerminal.CANCELLED,
            }
            receipt_id = controller.receipt_id
            assert receipt_id is not None
            receipt = receipts.get(receipt_id)
            expected = (
                "completed"
                if controller.terminal is TtsStreamTerminal.COMPLETED
                else "cancelled"
            )
            assert receipt["status"] == expected, yields

    asyncio.run(run())


def test_cancel_never_delivers_audio_after_the_terminal() -> None:
    async def run() -> None:
        synth = _FakeSynthesizer()
        service = _service(synth)
        sink = _Sink()
        controller = await service.open(options=_options(), sink=sink)
        session = synth.sessions[0]
        await controller.append_text(0, "你好")
        session.push(_audio_event())
        await controller.cancel()
        session.push(_audio_event(index=1))
        await asyncio.wait_for(controller.wait_closed(), timeout=2.0)

        assert controller.terminal is TtsStreamTerminal.CANCELLED
        assert sink.events[-1].terminal is TtsStreamTerminal.CANCELLED
        assert all(
            event.kind is not TtsStreamEventKind.AUDIO for event in sink.events
        )
        assert controller.delivered_samples == 0
        assert session.cancels == 1
        assert session.closes == 1

    asyncio.run(run())


def test_receipt_counts_only_pcm_that_left_the_process() -> None:
    async def run() -> None:
        delivered = _FakeSynthesizer()
        receipts = RenderReceiptRegistry()
        delivered.runtime_revision = _REVISION
        sink = _Sink()
        service = _service(delivered, receipts=receipts)
        controller = await service.open(
            options=_options(), sink=sink, receipt=TtsStreamReceipt(voice_revision="vr_" + "b" * 32)
        )
        session = delivered.sessions[0]
        for index in range(2):
            session.push(_audio_event(index=index))
        session.push(_terminal_event(TtsStreamTerminal.COMPLETED))
        await asyncio.wait_for(controller.wait_closed(), timeout=2.0)

        receipt_id = controller.receipt_id
        assert receipt_id is not None
        receipt = receipts.get(receipt_id)
        assert controller.delivered_samples == 4
        assert receipt["audio"]["sample_count"] == 4
        assert receipt["status"] == "completed"
        assert receipt["model"]["runtime_revision"] == _REVISION
        assert receipt["audio"]["integrity_boundary"] == "pcm16_after_transport_send"
        assert receipt["voice"]["revision"] == "vr_" + "b" * 32

        undelivered = _FakeSynthesizer()
        receipts = RenderReceiptRegistry()
        sink = _Sink()
        sink.fail_audio = True
        service = _service(undelivered, receipts=receipts)
        controller = await service.open(
            options=_options(), sink=sink, receipt=TtsStreamReceipt()
        )
        session = undelivered.sessions[0]
        session.push(_audio_event())
        session.push(_terminal_event(TtsStreamTerminal.COMPLETED))
        await asyncio.wait_for(controller.wait_closed(), timeout=2.0)

        receipt_id = controller.receipt_id
        assert receipt_id is not None
        receipt = receipts.get(receipt_id)
        assert controller.delivered_samples == 0
        assert receipt["audio"]["sample_count"] == 0
        assert receipt["status"] == "error"
        assert controller.terminal is TtsStreamTerminal.FAILED

    asyncio.run(run())


def test_slow_consumer_is_reported_as_backpressure() -> None:
    async def run() -> None:
        synth = _FakeSynthesizer()
        receipts = RenderReceiptRegistry()
        service = _service(synth, receipts=receipts)
        gate = asyncio.Event()

        class _StalledSink(_Sink):
            async def __call__(self, event: TtsStreamEvent) -> None:
                if event.kind is TtsStreamEventKind.AUDIO:
                    await gate.wait()
                await super().__call__(event)

        sink = _StalledSink()
        limits = TtsStreamLimits(slow_consumer_seconds=0.05)
        controller = await service.open(
            options=_options(), sink=sink, receipt=TtsStreamReceipt(), limits=limits
        )
        synth.sessions[0].push(_audio_event())
        await asyncio.wait_for(controller.wait_closed(), timeout=3.0)

        assert controller.terminal is TtsStreamTerminal.FAILED
        assert controller.terminal_detail == "tts_backpressure"
        assert controller.delivered_samples == 0
        receipt_id = controller.receipt_id
        assert receipt_id is not None
        assert receipts.get(receipt_id)["error_code"] == "tts_backpressure"

    asyncio.run(run())


def test_input_starvation_terminates_the_utterance() -> None:
    async def run() -> None:
        synth = _FakeSynthesizer()
        receipts = RenderReceiptRegistry()
        service = _service(synth, receipts=receipts)
        sink = _Sink()
        limits = TtsStreamLimits(input_wait_seconds=0.05, utterance_wall_clock_seconds=5.0)
        controller = await service.open(
            options=_options(), sink=sink, receipt=TtsStreamReceipt(), limits=limits
        )
        await asyncio.wait_for(controller.wait_closed(), timeout=3.0)

        assert controller.terminal is TtsStreamTerminal.FAILED
        assert controller.terminal_detail == "tts_input_timeout"
        assert [event.terminal for event in sink.terminals] == [TtsStreamTerminal.FAILED]
        assert sink.terminals[0].error_code == "tts_input_timeout"
        assert synth.sessions[0].closes == 1
        receipt_id = controller.receipt_id
        assert receipt_id is not None
        assert receipts.get(receipt_id)["error_code"] == "tts_input_timeout"

    asyncio.run(run())


def test_waiting_text_holds_the_lease_against_idle_eviction() -> None:
    async def run() -> None:
        worker = _EvictableWorker()
        evictor = WorkerIdleEvictor(
            (worker,),
            warm_standby_timeout_seconds=0.02,
            idle_timeout_seconds=0.05,
            check_interval_seconds=0.01,
        )
        service = _service(
            _FakeSynthesizer(),
            worker_lease=evictor.lease_lock_of(worker).lease,
        )
        await evictor.start()
        try:
            controller = await service.open(options=_options(), sink=_Sink())
            await asyncio.sleep(0.12)
            assert worker.closed is False
            assert evictor.state_of(worker) is WorkerLifecycleState.ACTIVE

            await controller.cancel()
            await asyncio.sleep(0.12)
            assert worker.closed is True
            assert evictor.state_of(worker) is WorkerLifecycleState.COLD_EVICTED
        finally:
            await evictor.close()

    asyncio.run(run())


def test_reclamation_stops_generation_before_releasing_the_admission() -> None:
    async def run() -> None:
        order: list[str] = []

        class _Lease:
            async def __aenter__(self) -> object:
                order.append("lease-enter")
                return object()

            async def __aexit__(self, *exc_info: object) -> None:
                order.append("lease-exit")

        synth = _FakeSynthesizer()
        governor = _governor()
        service = _service(synth, governor=governor, worker_lease=_Lease)
        controller = await service.open(options=_options(), sink=_Sink())
        session = synth.sessions[0]
        session.order = order
        assert governor.snapshot().active_tts == 1
        assert order == ["lease-enter"]

        await controller.cancel()
        await asyncio.wait_for(controller.wait_closed(), timeout=2.0)

        assert order == ["lease-enter", "session-close", "lease-exit"]
        assert governor.snapshot().active_tts == 0

    asyncio.run(run())


def test_cross_lane_over_budget_fails_closed() -> None:
    async def run() -> None:
        synth = _FakeSynthesizer()
        governor = _governor(total_capacity=2)
        service = _service(synth, governor=governor, admission_timeout_seconds=0.05)
        other_lane = await service.open(options=_options("other"), sink=_Sink())
        async with governor.reserve(
            WorkClass.BATCH_TTS,
            resource_key="lane:batch",
            purpose=WorkPurpose.DEFAULT,
        ):
            with pytest.raises(TtsStreamAdmissionError) as raised:
                await service.open(options=_options("third"), sink=_Sink())
            assert raised.value.code == "backend_timeout"
            assert raised.value.busy_reason == "backend_transition"
            assert [options.voice for options in synth.opened] == ["other"]
        await other_lane.cancel()
        assert governor.snapshot().active_tts == 0

    asyncio.run(run())


def test_revoked_reference_fails_the_open_and_releases_admission() -> None:
    async def run() -> None:
        synth = _FakeSynthesizer(failures={"cloned": VoiceRevokedError("revoked")})
        governor = _governor()
        service = _service(synth, governor=governor)
        with pytest.raises(VoiceRevokedError):
            await service.open(options=_options("cloned"), sink=_Sink())
        assert governor.snapshot().active_tts == 0
        assert governor.snapshot().pending_realtime == 0

    asyncio.run(run())


def test_unsupported_synthesizer_fails_closed() -> None:
    async def run() -> None:
        service = _service(object())
        assert service.supported is False
        with pytest.raises(TtsStreamError) as raised:
            await service.open(options=_options(), sink=_Sink())
        assert raised.value.code == "tts_streaming_unsupported"

    asyncio.run(run())


def test_composition_shares_one_receipt_registry_with_the_stream_service() -> None:
    settings = Settings(qwen3_model_dir=None, qwen3_python=None, _env_file=None)
    synth = _FakeSynthesizer()
    services = build_app_services(settings, AppOverrides(tts_synthesizer=synth))

    assert services.tts_streams is not None
    assert services.tts_streams.receipts is services.render_receipts
    assert services.tts_streams.synthesizer is synth
    assert services.tts_streams.supported is True
    assert services.tts_streams.worker_lease is None


class _EvictableWorker:
    """One resident worker that only the idle evictor may close."""

    def __init__(self) -> None:
        self.alive = True
        self.closed = False
        self.last_active = 0.0

    async def close(self) -> None:
        self.closed = True
        self.alive = False
