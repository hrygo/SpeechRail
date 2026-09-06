"""Unit tests for bounded SpeechAdmission state machine (R1)."""

from __future__ import annotations

import os
from unittest.mock import patch

import pytest

from speechrail.config import Settings
from speechrail.realtime.speech_admission import SpeechAdmission


def test_silence_has_no_admission() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=2,
        stop_frames=3,
        prefix_samples=512,
        frame_samples=512,
    )
    silence = bytes(1024)
    for index in range(40):
        assert gate.push(silence, start_sample=index * 512, probability=0.0) == ()
    assert gate.finish() == ()


def test_candidate_debounce_and_activation() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=3,
        stop_frames=3,
        prefix_samples=1024,  # 2 frames prefix
        frame_samples=512,
    )

    # 1. Feed 2 prefix silence frames
    p1 = b"\x01\x00" * 512
    p2 = b"\x02\x00" * 512
    assert gate.push(p1, start_sample=0, probability=0.1) == ()
    assert gate.push(p2, start_sample=512, probability=0.1) == ()
    assert gate.state == "IDLE"

    # 2. Feed 2 speech frames (start_frames=3, so debouncing in CANDIDATE)
    s1 = b"\x10\x00" * 512
    s2 = b"\x20\x00" * 512
    assert gate.push(s1, start_sample=1024, probability=0.9) == ()
    assert gate.state == "CANDIDATE"
    assert gate.push(s2, start_sample=1536, probability=0.9) == ()
    assert gate.state == "CANDIDATE"

    # 3. Feed 3rd speech frame -> activation!
    s3 = b"\x30\x00" * 512
    decisions = gate.push(s3, start_sample=2048, probability=0.9)
    assert gate.state == "ACTIVE"
    assert len(decisions) == 2

    start_d, audio_d = decisions
    assert start_d.kind == "start"
    # Pre-roll had 2 frames starting at 0, candidate frames go up to 2560
    assert start_d.start_sample == 0
    assert start_d.end_sample == 2560

    assert audio_d.kind == "audio"
    assert audio_d.start_sample == 0
    assert audio_d.end_sample == 2560
    # Audio must concatenate p1 + p2 + s1 + s2 + s3
    expected_pcm = p1 + p2 + s1 + s2 + s3
    assert audio_d.pcm == expected_pcm


def test_candidate_drop_on_transient_noise() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=3,
        stop_frames=3,
        prefix_samples=512,
        frame_samples=512,
    )
    frame = bytes(1024)

    # 1 speech frame -> CANDIDATE
    assert gate.push(frame, start_sample=0, probability=0.8) == ()
    assert gate.state == "CANDIDATE"

    # 1 silence frame -> drops back to IDLE
    assert gate.push(frame, start_sample=512, probability=0.1) == ()
    assert gate.state == "IDLE"

    # EOF while IDLE -> no decisions
    assert gate.finish() == ()


def test_hangover_and_speech_end() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,  # immediate activation
        stop_frames=3,  # 3 silence frames to end
        prefix_samples=512,
        frame_samples=512,
    )
    frame = bytes(1024)

    # Frame 1: speech -> start & audio
    d1 = gate.push(frame, start_sample=0, probability=0.9)
    assert gate.state == "ACTIVE"
    assert len(d1) == 2

    # Frame 2: silence -> HANGOVER 1 (emits audio)
    d2 = gate.push(frame, start_sample=512, probability=0.1)
    assert gate.state == "HANGOVER"
    assert len(d2) == 1
    assert d2[0].kind == "audio"

    # Frame 3: silence -> HANGOVER 2 (emits audio)
    d3 = gate.push(frame, start_sample=1024, probability=0.1)
    assert gate.state == "HANGOVER"
    assert len(d3) == 1
    assert d3[0].kind == "audio"

    # Frame 4: silence -> HANGOVER 3 -> reaches stop_frames (emits audio + end)
    d4 = gate.push(frame, start_sample=1536, probability=0.1)
    assert gate.state == "IDLE"
    assert len(d4) == 2
    assert d4[0].kind == "audio"
    assert d4[1].kind == "end"
    assert d4[1].start_sample == 0
    assert d4[1].end_sample == 2048


def test_intra_utterance_short_pause() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=3,
        prefix_samples=0,
        frame_samples=512,
    )
    frame = bytes(1024)

    # Speech -> ACTIVE
    gate.push(frame, start_sample=0, probability=0.9)
    # Pause 1 frame -> HANGOVER
    gate.push(frame, start_sample=512, probability=0.1)
    assert gate.state == "HANGOVER"

    # Resume speech before stop_frames -> back to ACTIVE, no end decision
    d = gate.push(frame, start_sample=1024, probability=0.9)
    assert gate.state == "ACTIVE"
    assert len(d) == 1
    assert d[0].kind == "audio"


def test_repeated_finish_idempotence() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=3,
        prefix_samples=0,
        frame_samples=512,
    )
    frame = bytes(1024)
    gate.push(frame, start_sample=0, probability=0.9)

    first_finish = gate.finish()
    assert len(first_finish) == 1
    assert first_finish[0].kind == "end"

    second_finish = gate.finish()
    assert second_finish == ()


def test_reset_clears_state_and_updates_offset() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=2,
        stop_frames=2,
        prefix_samples=512,
        frame_samples=512,
    )
    frame = bytes(1024)
    gate.push(frame, start_sample=0, probability=0.9)
    assert gate.state == "CANDIDATE"

    gate.reset(next_sample=10_000)
    assert gate.state == "IDLE"

    # Next push from 10_000
    gate.push(frame, start_sample=10_000, probability=0.9)
    assert gate.state == "CANDIDATE"


def test_invalid_odd_pcm_length_rejected() -> None:
    gate = SpeechAdmission()
    with pytest.raises(ValueError, match="even number of bytes"):
        gate.push(b"\x00\x01\x02", start_sample=0, probability=0.5)


def test_sub_frame_chunking_and_leftover_eof() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=2,
        prefix_samples=0,
        frame_samples=512,
    )
    # Push 300 bytes (150 samples) -> sub-frame leftover
    assert gate.push(bytes(300), start_sample=0, probability=0.9) == ()

    # Push 724 bytes (362 samples) -> total 1024 bytes = 512 samples (1 frame)
    d = gate.push(bytes(724), start_sample=150, probability=0.9)
    assert len(d) == 2  # start and audio
    assert d[0].kind == "start"
    assert d[1].kind == "audio"
    assert len(d[1].pcm) == 1024

    # Push another 100 bytes during active speech, then finish()
    gate.push(bytes(100), start_sample=512, probability=0.9)
    fin = gate.finish()
    # Should emit leftover 100 bytes audio, then end
    assert len(fin) == 2
    assert fin[0].kind == "audio"
    assert len(fin[0].pcm) == 100
    assert fin[1].kind == "end"


def test_config_setting_from_env() -> None:
    with patch.dict(os.environ, {"SPEECHRAIL_REALTIME_SPEECH_ADMISSION_ENABLED": "true"}):
        settings = Settings()
        assert settings.realtime_speech_admission_enabled is True

    with patch.dict(os.environ, {"SPEECHRAIL_REALTIME_SPEECH_ADMISSION_ENABLED": "false"}):
        settings = Settings()
        assert settings.realtime_speech_admission_enabled is False


def test_dual_threshold_hysteresis_keeps_utterance_alive() -> None:
    """Mid-band frames (below entry, at/above exit) must not chop an active
    utterance, and must never open a new one from silence (Silero-style)."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=3,
        prefix_samples=0,
        frame_samples=512,
    )
    frame = bytes(1024)

    # Activate with a clear-speech frame.
    gate.push(frame, start_sample=0, probability=0.9)
    assert gate.state == "ACTIVE"

    # Mid-band probability inside an utterance: speech continues, audio flows.
    decisions = gate.push(frame, start_sample=512, probability=0.42)
    assert gate.state == "ACTIVE"
    assert len(decisions) == 1
    assert decisions[0].kind == "audio"

    # The same mid-band probability never opens an utterance from IDLE.
    idle_gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=3,
        prefix_samples=0,
        frame_samples=512,
    )
    assert idle_gate.push(frame, start_sample=0, probability=0.42) == ()
    assert idle_gate.state == "IDLE"

    # Below the exit threshold the hangover still closes the utterance.
    gate.push(frame, start_sample=1024, probability=0.1)
    gate.push(frame, start_sample=1536, probability=0.1)
    closing = gate.push(frame, start_sample=2048, probability=0.1)
    assert gate.state == "IDLE"
    assert closing[-1].kind == "end"


def test_stop_threshold_defaults_and_validation() -> None:
    gate = SpeechAdmission(threshold=0.5)
    assert gate.stop_threshold == pytest.approx(0.35)
    explicit = SpeechAdmission(threshold=0.5, stop_threshold=0.2)
    assert explicit.stop_threshold == pytest.approx(0.2)
    assert explicit.threshold == pytest.approx(0.5)

    with pytest.raises(ValueError, match="stop_threshold must be between"):
        SpeechAdmission(threshold=0.5, stop_threshold=0.6)
    with pytest.raises(ValueError, match="stop_threshold must be between"):
        SpeechAdmission(threshold=0.5, stop_threshold=-0.1)
