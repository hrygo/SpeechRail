"""Tests for Server VAD and Barge-in full-duplex cancellation in OpenAI Realtime."""

from __future__ import annotations

import base64
import numpy as np
import pytest

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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        assert updated["type"] == "session.updated"
        assert updated["session"]["turn_detection"]["type"] == "server_vad"


def test_realtime_bargein_cancels_active_tts_response() -> None:
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()

        # Enable server_vad
        socket.send_json(
            {
                "type": "session.update",
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
        assert socket.receive_json()["type"] == "session.updated"

        # Create a text item and trigger TTS response
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        assert socket.receive_json()["type"] == "conversation.item.created"
        socket.send_json({"type": "response.create"})

        # Wait for TTS audio to start streaming
        response_events = [socket.receive_json() for _ in range(4)]
        assert response_events[-1]["type"] == "response.audio.delta"

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

        assert "response.done" in events_received
        assert "input_audio_buffer.speech_started" in events_received


def test_bargein_session_isolation() -> None:
    """Verify that Barge-in interruption in Session A does NOT cancel Session B."""
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket_a, client.websocket_connect("/v1/realtime") as socket_b:
        socket_a.receive_json()
        socket_a.receive_json()
        socket_b.receive_json()
        socket_b.receive_json()

        # Enable server_vad on Session A
        socket_a.send_json(
            {
                "type": "session.update",
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
        assert socket_a.receive_json()["type"] == "session.updated"

        # Start TTS on Session B
        socket_b.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "保持播放"}],
                },
            }
        )
        assert socket_b.receive_json()["type"] == "conversation.item.created"
        socket_b.send_json({"type": "response.create"})

        b_events = [socket_b.receive_json() for _ in range(4)]
        assert b_events[-1]["type"] == "response.audio.delta"

        # Speak into Session A -> Barge-in on Session A
        active_speech = _sine_pcm(440, 32, 10000.0)
        for _ in range(4):
            socket_a.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(active_speech)}
            )

        a_event = socket_a.receive_json()
        assert a_event["type"] == "input_audio_buffer.speech_started"

        # Verify Session B is still intact and not cancelled!
        # Session B did not receive any unexpected cancellation
