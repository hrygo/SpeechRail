"""Regression tests for admission-path commit sequencing (2026-09 VAD review).

Covers three review findings that reproduce only in interaction paths:

1. An explicit ``input_audio_buffer.commit`` arriving while the admission
   state machine is mid-utterance must produce exactly one committed
   sequence (no nested commit, no phantom empty item).
2. Auto-commit rollover on ``max_realtime_buffer_bytes`` behaves the same.
3. The legacy path's pre-speech buffer is bounded to the prefix window, so
   long silence neither grows memory nor reaches ASR at speech onset.
"""

from __future__ import annotations

import asyncio
import base64
import math
from typing import Any

from realtime_wire import server_vad, session_update
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from test_realtime_openai import FakeSpeechSynthesizer, FakeStreamingFactory, FakeTranscriber

_VAD_UPDATE: dict[str, Any] = session_update(endpointing=server_vad())


def _sine_frame_16k() -> bytes:
    """One 32 ms 24 kHz wire frame that resamples to a 512-sample ASR frame.

    Scores ~1.0 on the legacy energy scorer (RMS ~3536, ZCR ~0.025) and is a
    realistic speech surrogate for the Silero runner stub.
    """
    return b"".join(
        int(5000 * math.sin(2 * math.pi * 200.0 * i / 24_000)).to_bytes(
            2, "little", signed=True
        )
        for i in range(768)
    )


def _b64(pcm: bytes) -> str:
    return base64.b64encode(pcm).decode("ascii")


def _build(**settings_overrides: Any) -> tuple[Any, FakeStreamingFactory]:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
        **settings_overrides,
    )
    factory = FakeStreamingFactory()
    services = build_app_services(
        settings,
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=factory,
            diarization_engine=None,
        ),
    )
    return services, factory


async def _stream_speech_then_commit(**settings_overrides: Any) -> list[dict[str, Any]]:
    """Enable server_vad, stream 12 admitted speech frames, then commit explicitly."""
    services, _ = _build(**settings_overrides)
    sent: list[dict[str, Any]] = []

    async def send(event: dict[str, Any]) -> int | None:
        sent.append(event)
        return len(sent)

    session = OpenAIRealtimeSession(services, session_id="s", send=send)
    await session._update_session(_VAD_UPDATE)
    frame = _sine_frame_16k()
    for _ in range(12):
        await session._append_audio(
            {"type": "input_audio_buffer.append", "audio": _b64(frame)}
        )
    await session._commit_audio("client")
    await session.close()
    return sent


def _completed_events(sent: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        event
        for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    ]


def test_commit_during_admitted_utterance_produces_single_sequence() -> None:
    """Finding: commit mid-utterance used to nest via admission.finish() and
    emit a duplicate committed + phantom empty item after the real transcript."""
    sent = asyncio.run(
        _stream_speech_then_commit(realtime_speech_admission_enabled=True)
    )
    types = [event["type"] for event in sent]
    completed = _completed_events(sent)
    assert len(completed) == 1
    assert completed[0]["transcript"] == "你好"
    assert types.count("error") == 0, types


def test_rollover_during_admitted_utterance_produces_single_sequence_per_item() -> None:
    """Finding: each rollover commit used to duplicate the empty close-out.
    A small buffer cap forces several rollovers inside one continuous utterance."""
    sent = asyncio.run(
        _stream_speech_then_commit(
            realtime_speech_admission_enabled=True,
            max_realtime_buffer_bytes=4096,
        )
    )
    types = [event["type"] for event in sent]
    completed = _completed_events(sent)
    assert len(completed) >= 2, f"rollover never triggered: {types}"
    assert all(event["transcript"] == "你好" for event in completed)


def test_legacy_vad_pending_silence_is_bounded() -> None:
    """Finding: the legacy path buffered every silent chunk without a cap and
    flushed the whole backlog into ASR at speech onset (61s ≈ 983KB measured)."""
    services, factory = _build(realtime_speech_admission_enabled=False)
    sent: list[dict[str, Any]] = []

    async def send(event: dict[str, Any]) -> int | None:
        sent.append(event)
        return len(sent)

    async def run() -> None:
        session = OpenAIRealtimeSession(services, session_id="s", send=send)
        await session._update_session(_VAD_UPDATE)
        silence = bytes(1024)
        # 200 x 32ms = 6.4s of pure silence
        for _ in range(200):
            await session._append_audio(
                {"type": "input_audio_buffer.append", "audio": _b64(silence)}
            )
        for _ in range(3):  # confirm speech
            await session._append_audio(
                {"type": "input_audio_buffer.append", "audio": _b64(_sine_frame_16k())}
            )
        await session.close()

    asyncio.run(run())
    received = [chunk for s in factory.sessions for chunk in s.received]
    total = sum(len(chunk) for chunk in received)
    # prefix_padding_ms=300 → 9600 bytes window + confirming frames
    assert total <= 9600 + 4 * 1024, f"{total} bytes of silence reached ASR"
    assert factory.creates == 1
