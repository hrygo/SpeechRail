"""Client commits preserve VAD leftovers before the resampler's final sample."""

from __future__ import annotations

import asyncio
import struct

import pytest

from realtime_wire import server_vad, session_update
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.alignment import AlignmentRequest, AlignmentResult
from speechrail.domain.audio_timeline import RationalResampler
from test_realtime_openai import FakeStreamingFactory, FakeTextAligner, _pcm16
from test_realtime_vad_bargein import _wire_speech_frame


@pytest.mark.parametrize("extra_samples", [1, 2, 7, 766, 767, 768])
@pytest.mark.parametrize("packet_samples", [37, 768])
def test_client_commit_keeps_resampler_tail_in_order_and_in_frozen_span(
    extra_samples: int, packet_samples: int,
) -> None:
    wire = _wire_speech_frame() * 6 + _wire_speech_frame()[:extra_samples * 2]
    reference = RationalResampler(24_000, 16_000)
    expected = reference.process(wire) + reference.flush()

    async def scenario() -> None:
        requests: list[AlignmentRequest] = []
        events: list[dict[str, object]] = []
        terminal = asyncio.Event()

        class Aligner(FakeTextAligner):
            async def align(self, request: AlignmentRequest) -> AlignmentResult:
                requests.append(request)
                return await super().align(request)

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event["type"] in {"speechrail.alignment.done", "speechrail.alignment.failed"}:
                terminal.set()
            return len(events)

        factory = FakeStreamingFactory()
        services = build_app_services(
            Settings(
                qwen3_model_dir=None, qwen3_python=None,
                realtime_speech_admission_enabled=True,
            ),
            AppOverrides(realtime_asr_factory=factory, text_aligner=Aligner()),
        )
        session = OpenAIRealtimeSession(services, session_id="commit-tail", send=send)
        await session.start()
        try:
            await session.handle(session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=100, silence_duration_ms=100,
                ),
                alignment={"enabled": True},
            ))
            for offset in range(0, len(wire), packet_samples * 2):
                await session.handle({
                    "type": "input_audio_buffer.append",
                    "audio": _pcm16(wire[offset:offset + packet_samples * 2]),
                })
            await session.handle({"type": "input_audio_buffer.commit", "event_id": "tail"})
            await asyncio.wait_for(terminal.wait(), timeout=1)
            failures = [e for e in events if e["type"] == "speechrail.alignment.failed"]
            assert failures == []
            assert len(factory.sessions) == len(requests) == 1
            # The ASR and aligner must hear the original order, including a
            # remainder that becomes a complete VAD frame only on flush.
            assert b"".join(factory.sessions[0].received) == expected
            assert requests[0].pcm16 == expected
            assert requests[0].span.start == 0
            assert requests[0].span.end == len(expected) // 2
        finally:
            await session.close()

    asyncio.run(scenario())


def test_two_client_commits_preserve_pcm_phase_and_total_duration() -> None:
    first_samples = 24_002
    source = [(n * 37) % 20_000 - 10_000 for n in range(48_006)]
    wire = struct.pack(f"<{len(source)}h", *source)
    first_target = (first_samples * 2 + 2) // 3
    total_target = len(source) * 2 // 3

    def expected_pcm(start: int, stop: int, source_end: int) -> bytes:
        samples = []
        for index in range(start, stop):
            position = index * 3 // 2
            first = source[position]
            second = source[min(position + 1, source_end - 1)]
            samples.append(first if index % 2 == 0 else round((first + second) / 2))
        return struct.pack(f"<{len(samples)}h", *samples)

    async def scenario() -> None:
        terminal = asyncio.Event()
        factory = FakeStreamingFactory()
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                terminal.set()
            return len(events)

        services = build_app_services(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            AppOverrides(realtime_asr_factory=factory),
        )
        session = OpenAIRealtimeSession(services, session_id="continued-phase", send=send)
        await session.start()
        try:
            await session.handle(session_update())
            for packet in (wire[:first_samples * 2], wire[first_samples * 2:]):
                terminal.clear()
                await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(packet)})
                await session.handle({"type": "input_audio_buffer.commit"})
                await asyncio.wait_for(terminal.wait(), timeout=5)
            assert not [event for event in events if event["type"] == "error"]
            assert len(factory.sessions) == 2
            assert b"".join(factory.sessions[0].received) == expected_pcm(
                0, first_target, first_samples,
            )
            assert b"".join(factory.sessions[1].received) == expected_pcm(
                first_target, total_target, len(source),
            )
        finally:
            await session.close()

    asyncio.run(scenario())
