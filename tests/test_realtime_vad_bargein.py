"""Tests for Server VAD and caller-owned barge-in on the current Realtime wire.

The current wire has no ``input_audio_buffer.speech_started`` /
``speech_stopped`` server acknowledgement.  Server VAD is negotiated on
``session.update`` (``session.speechrail.endpointing``) and only feeds the ASR
side; barge-in policy stays with the caller, which cancels TTS explicitly with
``speechrail.tts.cancel``.  These tests pin that policy and the VAD detector
itself.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from realtime_wire import (
    server_vad,
    session_update,
    tts_append_text,
    tts_cancel,
    tts_finish_text,
    tts_start,
)
from speechrail.backends.vad import VadConfig, VoiceActivityDetector
from test_realtime_openai import _client, _pcm16

_TERMINALS = {
    "speechrail.tts.completed",
    "speechrail.tts.cancelled",
    "speechrail.tts.failed",
}


def _sine_pcm(frequency: float = 440.0, duration_ms: int = 32, amplitude: float = 8000.0) -> bytes:
    """Generate 16 kHz mono PCM16 sine wave audio for the detector unit tests."""

    sample_rate = 16_000
    num_samples = int((sample_rate * duration_ms) / 1000)
    t = np.linspace(0, duration_ms / 1000.0, num_samples, endpoint=False)
    samples = (amplitude * np.sin(2 * np.pi * frequency * t)).astype(np.int16)
    return samples.tobytes()


def _silence_pcm(duration_ms: int = 32) -> bytes:
    sample_rate = 16_000
    num_samples = int((sample_rate * duration_ms) / 1000)
    return b"\x00\x00" * num_samples


def _wire_speech_frame(
    frequency: float = 440.0, duration_ms: int = 32, amplitude: float = 8000.0
) -> bytes:
    """One 24 kHz wire frame that resamples to a single 16 kHz VAD frame."""

    sample_rate = 24_000
    num_samples = int((sample_rate * duration_ms) / 1000)
    t = np.linspace(0, duration_ms / 1000.0, num_samples, endpoint=False)
    return (amplitude * np.sin(2 * np.pi * frequency * t)).astype(np.int16).tobytes()


def _wire_silence_frame(duration_ms: int = 32) -> bytes:
    return b"\x00\x00" * int((24_000 * duration_ms) / 1000)


def _drain_tts(socket: Any, *, limit: int = 40) -> list[dict[str, Any]]:
    """Read up to one namespaced TTS terminal, ignoring ASR side events."""

    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] in _TERMINALS or event["type"] == "error":
            break
    return events


def _tts_settings() -> dict[str, Any]:
    from test_realtime_tts_incremental import _tier_kwargs

    return {
        key: value
        for key, value in _tier_kwargs().items()
        if key not in {"qwen3_python", "qwen3_tts_python"}
    }


def test_vad_detector_debounce_and_silence() -> None:
    config = VadConfig(threshold=0.3, debounce_frames=3, silence_duration_ms=96)
    vad = VoiceActivityDetector(config)

    # 1. Feed silence -> no events
    events = vad.process_chunk(_silence_pcm(32))
    assert len(events) == 0
    assert not vad.in_speech

    # 2. Feed 2 active frames -> debouncing, not yet speech_started
    frame = _sine_pcm(440, 32, 10000.0)
    events = vad.process_chunk(frame)
    assert len(events) == 0
    assert not vad.in_speech

    events = vad.process_chunk(frame)
    assert len(events) == 0
    assert not vad.in_speech

    # 3. Feed 3rd active frame -> speech_started triggered
    events = vad.process_chunk(frame)
    assert len(events) == 1
    assert events[0].speech_started
    assert vad.in_speech

    # 4. Feed silence for 3 frames (96ms) -> speech_ended triggered
    vad.process_chunk(_silence_pcm(32))
    vad.process_chunk(_silence_pcm(32))
    events = vad.process_chunk(_silence_pcm(32))
    assert len(events) == 1
    assert events[0].speech_ended
    assert not vad.in_speech


def test_vad_hysteresis_mid_band_frames_stay_in_speech() -> None:
    """Legacy scorer hysteresis: frames scoring between the exit and entry
    thresholds keep an ongoing utterance alive but never start one."""
    config = VadConfig(threshold=0.5, debounce_frames=3, silence_duration_ms=96)
    # RMS ~209 -> sigmoid score ~0.40: below the 0.5 entry, above the 0.35 exit.
    mid = _sine_pcm(200, 32, 296.0)
    loud = _sine_pcm(200, 32, 5000.0)
    quiet = _silence_pcm(32)

    vad = VoiceActivityDetector(config)
    for _ in range(3):
        # The third loud frame emits the debounced speech_started event.
        assert all(not e.speech_ended for e in vad.process_chunk(loud))
    assert vad.in_speech

    # Mid-band frames do not advance the silence counter mid-utterance
    # (they emit plain is_speech events without boundary transitions).
    for _ in range(10):
        assert all(not e.speech_ended and not e.speech_started for e in vad.process_chunk(mid))
        assert vad.in_speech

    # From silence the same frames stay below the entry threshold.
    idle = VoiceActivityDetector(config)
    for _ in range(5):
        assert idle.process_chunk(mid) == []
        assert not idle.in_speech

    # True silence (below the exit threshold) still ends the utterance.
    events: list[object] = []
    for _ in range(3):
        events = vad.process_chunk(quiet)
    assert any(getattr(event, "speech_ended", False) for event in events)


def test_realtime_server_vad_session_update_accepted() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.5, prefix_padding_ms=300, silence_duration_ms=400
                )
            )
        )
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        assert updated["session"]["audio"]["input"]["turn_detection"] is None
        assert updated["session"]["speechrail"]["endpointing"] == {
            "mode": "server_vad",
            "threshold": 0.5,
            "prefix_padding_ms": 300,
            "silence_duration_ms": 400,
        }


def test_realtime_vad_speech_commit_produces_one_text_final() -> None:
    """Speech then silence under server_vad drives the ASR turn to one final."""

    client, factory = _client(completed_text="你好")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=0, silence_duration_ms=100
                )
            )
        )
        assert socket.receive_json()["type"] == "session.updated"
        for _ in range(6):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_speech_frame())}
            )
        # Silence past the 100 ms stop debounce ends the turn and commits.
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_silence_frame())}
            )
        finals: list[dict[str, Any]] = []
        for _ in range(64):
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                finals.append(event)
                break
            assert event["type"] != "error", event
        assert finals, "server VAD must drive the utterance to one text final"
        assert finals[0]["transcript"] == "你好"
        assert len(factory.sessions) == 1


def test_realtime_vad_fact_does_not_cancel_tts_without_caller_command() -> None:
    """Loud frames never cancel TTS: cancellation is an explicit caller command.

    These frames stay below the three-frame server-VAD debounce so they do not
    open an ASR turn.  A server-VAD admission needs the (serialized) ASR lane and
    therefore cannot run concurrently with an active TTS utterance on the same
    session; that resource model is exercised by the cross-session isolation
    test below, which feeds full admitted speech.
    """

    from test_realtime_tts_incremental import FakeIncrementalSynthesizer

    client, _ = _client(
        tts_synthesizer=FakeIncrementalSynthesizer(),
        settings_kwargs=_tts_settings(),
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=100, silence_duration_ms=200
                ),
                tts={"enabled": True},
            )
        )
        assert socket.receive_json()["type"] == "session.updated"

        socket.send_json(tts_start(request_id="vad_cancel_001"))
        assert socket.receive_json()["type"] == "speechrail.tts.started"
        socket.send_json(
            tts_append_text(request_id="vad_cancel_001", sequence=0, text="你好")
        )

        # Loud, speech-like frames must not cancel or fail the utterance.
        for _ in range(2):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_speech_frame())}
            )

        socket.send_json(tts_finish_text(request_id="vad_cancel_001", last_sequence=0))
        event_types = [event["type"] for event in _drain_tts(socket)]
        assert "speechrail.tts.cancelled" not in event_types
        assert event_types[-1] == "speechrail.tts.completed"

        # Cancellation is explicit and owned by the caller.
        socket.send_json(tts_start(request_id="vad_cancel_002"))
        assert socket.receive_json()["type"] == "speechrail.tts.started"
        socket.send_json(tts_cancel(request_id="vad_cancel_002"))
        assert _drain_tts(socket)[-1]["type"] == "speechrail.tts.cancelled"


def test_bargein_session_isolation() -> None:
    """Speech in Session A never cancels another session's caller-owned TTS."""

    from test_realtime_tts_incremental import FakeIncrementalSynthesizer

    client, _ = _client(
        tts_synthesizer=FakeIncrementalSynthesizer(),
        settings_kwargs=_tts_settings(),
    )
    with (
        client.websocket_connect("/v1/realtime") as socket_a,
        client.websocket_connect("/v1/realtime") as socket_b,
    ):
        socket_a.receive_json()
        socket_b.receive_json()

        socket_a.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=100, silence_duration_ms=200
                )
            )
        )
        assert socket_a.receive_json()["type"] == "session.updated"

        socket_b.send_json(session_update(tts={"enabled": True}))
        assert socket_b.receive_json()["type"] == "session.updated"
        socket_b.send_json(tts_start(request_id="isolation_001"))
        assert socket_b.receive_json()["type"] == "speechrail.tts.started"
        socket_b.send_json(
            tts_append_text(request_id="isolation_001", sequence=0, text="保持播放")
        )

        for _ in range(6):
            socket_a.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_speech_frame())}
            )

        # Session B keeps its own utterance; the caller cancels it explicitly.
        socket_b.send_json(tts_finish_text(request_id="isolation_001", last_sequence=0))
        b_types = [event["type"] for event in _drain_tts(socket_b)]
        assert "speechrail.tts.cancelled" not in b_types
        assert b_types[-1] == "speechrail.tts.completed"
