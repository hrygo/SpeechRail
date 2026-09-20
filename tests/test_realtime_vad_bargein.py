"""Tests for Server VAD and Barge-in full-duplex cancellation in OpenAI Realtime."""

from __future__ import annotations

import numpy as np

from speechrail.backends.vad import VadConfig, VoiceActivityDetector
from test_realtime_openai import BlockingSpeechSynthesizer, _client, _pcm16


def _sine_pcm(frequency: float = 440.0, duration_ms: int = 32, amplitude: float = 8000.0) -> bytes:
    """Generate 16kHz mono PCM16 sine wave audio."""
    sample_rate = 16_000
    num_samples = int((sample_rate * duration_ms) / 1000)
    t = np.linspace(0, duration_ms / 1000.0, num_samples, endpoint=False)
    samples = (amplitude * np.sin(2 * np.pi * frequency * t)).astype(np.int16)
    return samples.tobytes()


def _silence_pcm(duration_ms: int = 32) -> bytes:
    sample_rate = 16_000
    num_samples = int((sample_rate * duration_ms) / 1000)
    return b"\x00\x00" * num_samples


def _receive_audio_delta(socket):
    """Consume the contract-defined TTS prelude until PCM audio starts."""
    for _ in range(16):
        event = socket.receive_json()
        if event["type"] == "response.output_audio.delta":
            return event
    raise AssertionError("TTS response did not emit response.output_audio.delta")


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


def test_realtime_server_vad_session_update_accepted() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 400,
                    }
                },
            }
        )
        updated = socket.receive_json()
        assert updated["type"] == "transcription_session.updated"
        assert updated["session"]["turn_detection"]["type"] == "server_vad"


def test_realtime_vad_fact_does_not_cancel_tts_without_caller_command() -> None:
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()

        # Negotiate server VAD and caller-owned TTS.
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 100,
                        "silence_duration_ms": 200,
                    },
                    "speechrail": {"tts": {"enabled": True}},
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        # The caller submits text directly; there is no conversation item.
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "vad_cancel_001",
                "text": "你好",
            }
        )

        # The transcript echo precedes PCM audio in the current TTS event sequence.
        _receive_audio_delta(socket)

        # Now simulate user speaking (Barge-in!) -> Send 4 frames of active speech
        active_speech = _sine_pcm(440, 32, 10000.0)
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(active_speech)}
            )

        events_received = []
        for _ in range(8):
            e = socket.receive_json()
            events_received.append(e["type"])
            if e["type"] == "input_audio_buffer.speech_started":
                break

        assert "input_audio_buffer.speech_started" in events_received
        assert "response.done" not in events_received

        # Barge-in policy belongs to the caller, so cancellation is explicit.
        socket.send_json(
            {"type": "speechrail.tts.cancel", "request_id": "vad_cancel_001"}
        )
        while True:
            event = socket.receive_json()
            if event["type"] == "response.done":
                assert event["response"]["status"] == "cancelled"
                break


def test_bargein_session_isolation() -> None:
    """Verify that Barge-in interruption in Session A does NOT cancel Session B."""
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with (
        client.websocket_connect("/v1/realtime") as socket_a,
        client.websocket_connect("/v1/realtime") as socket_b,
    ):
        socket_a.receive_json()
        socket_b.receive_json()

        # Enable server_vad on Session A
        socket_a.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 100,
                        "silence_duration_ms": 200,
                    }
                },
            }
        )
        assert socket_a.receive_json()["type"] == "transcription_session.updated"

        # Start caller-owned TTS on Session B.
        socket_b.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket_b.receive_json()["type"] == "transcription_session.updated"
        socket_b.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "isolation_001",
                "text": "保持播放",
            }
        )

        _receive_audio_delta(socket_b)

        # Speak into Session A -> Barge-in on Session A
        active_speech = _sine_pcm(440, 32, 10000.0)
        for _ in range(4):
            socket_a.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(active_speech)}
            )

        a_event = socket_a.receive_json()
        assert a_event["type"] == "input_audio_buffer.speech_started"

        # Verify Session B is still active; the caller may cancel it explicitly.
        socket_b.send_json(
            {"type": "speechrail.tts.cancel", "request_id": "isolation_001"}
        )
        while socket_b.receive_json()["type"] != "response.done":
            pass


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
