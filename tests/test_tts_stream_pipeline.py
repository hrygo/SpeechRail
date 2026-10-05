"""Production stream layers over real pipes, with only the model replaced."""

from __future__ import annotations

import asyncio
import os
import threading
from collections.abc import Mapping

from speechrail.application.render_receipts import RenderReceiptRegistry
from speechrail.application.tts_audio_window import TtsAudioWindow
from speechrail.application.tts_stream import TtsStreamService
from speechrail.backends.qwen3_tts_stream_client import Qwen3TtsIncrementalSynthesizer
from speechrail.backends.qwen3_tts_stream_host import ModelStepEvent, StreamPump, TtsStreamHost
from speechrail.backends.qwen3_tts_worker import _drive_stream
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.domain.tts_stream import (
    IncrementalSpeechSession,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.worker_protocol import read_frame, write_frame


class _Model:
    sample_rate = 24_000
    generation_identity = "gen-pipe"
    prefill_target_tokens = 1

    def __init__(self) -> None:
        self.accepted = False
        self.finished = False
        self.remaining = 80
        self.closed = 0

    def append_text(self, text: str) -> tuple[int, ...]:
        self.accepted = True
        return (1,)

    def finish_input(self) -> None:
        self.finished = True

    def step(self, *, max_steps: int) -> ModelStepEvent:
        if not self.accepted:
            return ModelStepEvent(kind="waiting_for_text")
        if self.remaining:
            self.remaining -= 1
            return ModelStepEvent(kind="pcm", pcm16=b"\x01\x00" * 1_920)
        return ModelStepEvent(kind="finished" if self.finished else "waiting_for_text")

    def cancel(self) -> None:
        pass

    def close(self) -> None:
        self.closed += 1


class _PipeTransport:
    """No delivery shortcuts: serialization, reader, writer and callbacks are real."""

    def __init__(self, options: TtsStreamOptions, limits: TtsStreamLimits) -> None:
        in_read, in_write = os.pipe()
        out_read, out_write = os.pipe()
        self._parent_write = os.fdopen(in_write, "wb", buffering=0)
        self._parent_read = os.fdopen(out_read, "rb", buffering=0)
        self._worker_read = os.fdopen(in_read, "rb", buffering=0)
        self._worker_write = os.fdopen(out_write, "wb", buffering=0)
        self.pump = StreamPump(self._worker_read, self._worker_write)
        self.model = _Model()
        self.host = TtsStreamHost(self.model, options, limits=limits)
        self.faults: list[BaseException] = []
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        try:
            self.pump.start()
            assert self.pump.poll(timeout=1) is not None  # start envelope
            _drive_stream(self.pump, self.host)
        except BaseException as exc:
            self.faults.append(exc)
        finally:
            self.host.close()
            self.pump.stop(join_timeout_seconds=0.5)
            self._worker_write.close()

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        await asyncio.to_thread(
            write_frame, self._parent_write, payload, binary_payload=binary_payload
        )

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, object]:
        frame = await asyncio.to_thread(read_frame, self._parent_read)
        if frame is None:
            raise EOFError
        return frame

    async def abort(self) -> None:
        self._parent_write.close()

    async def close(self) -> None:
        self._parent_write.close()
        await asyncio.to_thread(self._thread.join, 2)
        assert not self._thread.is_alive()
        self._parent_read.close()
        self._worker_read.close()
        assert not self.faults


def test_real_pipe_pipeline_survives_healthy_consumption_longer_than_deadline() -> None:
    async def run() -> None:
        options = TtsStreamOptions(request_id="pipe", response_id="pipe-response", voice="serena")
        limits = TtsStreamLimits(max_pending_audio_bytes=7_680, slow_consumer_seconds=0.2)
        transport = _PipeTransport(options, limits)
        client = Qwen3TtsIncrementalSynthesizer(transport, stream_protocol=1)

        class Synthesizer:
            async def open_incremental_stream(
                self, options: TtsStreamOptions, *, limits: TtsStreamLimits
            ) -> IncrementalSpeechSession:
                return await client.open_stream(options, limits=limits)

        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=2)
        )
        window = TtsAudioWindow(7_680, inactivity_seconds=0.2)
        playback: asyncio.Queue[int | None] = asyncio.Queue(maxsize=2)
        received: list[TtsStreamEvent] = []
        max_unconsumed = 0

        async def consume() -> None:
            offset = 0
            while (samples := await playback.get()) is not None:
                await asyncio.sleep(0.01)
                offset += samples
                window.acknowledge(offset)

        async def sink(event: TtsStreamEvent) -> None:
            nonlocal max_unconsumed
            received.append(event)
            if event.kind is TtsStreamEventKind.AUDIO:
                max_unconsumed = max(
                    max_unconsumed, 2 * (window.sent_samples - window.consumed_samples)
                )
                playback.put_nowait(len(event.pcm16) // 2)

        consumer = asyncio.create_task(consume())
        service = TtsStreamService(
            synthesizer=Synthesizer(), governor=governor, receipts=RenderReceiptRegistry()
        )
        controller = None
        try:
            controller = await service.open(
                options=options, limits=limits, sink=sink, audio_admission=window.reserve
            )
            await controller.append_text(0, "synthetic")
            await controller.finish_text(0)
            await asyncio.wait_for(controller.wait_closed(), timeout=5)
            assert controller.terminal is TtsStreamTerminal.COMPLETED
            audio = [event for event in received if event.kind is TtsStreamEventKind.AUDIO]
            pcm = b"".join(event.pcm16 for event in audio)
            assert len(pcm) == 80 * 1_920 * 2
            assert pcm[:-240] == b"\x01\x00" * (80 * 1_920 - 120)
            assert pcm[-2:] == b"\x00\x00"
            offset = 0
            for event in audio:
                assert event.sample_offset == offset
                offset += len(event.pcm16) // 2
            assert max_unconsumed <= 7_680
            assert sum(event.terminal is not None for event in received) == 1
            # Production has ended while some local audio may still be playing.
            await playback.put(None)
            await asyncio.wait_for(consumer, timeout=1)
            assert window.sent_samples == window.consumed_samples
        finally:
            window.close()
            if controller is not None:
                await controller.aclose()
            consumer.cancel()
            await asyncio.gather(consumer, return_exceptions=True)
            await transport.close()

    asyncio.run(run())
