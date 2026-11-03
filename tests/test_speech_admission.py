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


def test_soft_watermark_valley_seeking_closes_on_micro_pause() -> None:
    """Once continuous speech exceeds soft_max_samples, a brief micro-pause
    (or punctuation-assisted pause) closes the utterance cleanly instead of
    waiting for full stop_frames and hitting a mid-word budget rollover."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=10,
        prefix_samples=0,
        frame_samples=512,
        soft_max_samples=2048,  # 4 frames
        soft_stop_frames=3,
        terminal_stop_frames=2,
        clause_stop_frames=3,
    )
    frame = bytes(1024)

    # Activate and speak for 2 frames (1024 samples < 2048 soft_max_samples)
    gate.push(frame, start_sample=0, probability=0.9)
    gate.push(frame, start_sample=512, probability=0.9)

    # Before soft watermark, a 3-frame micro-pause does NOT close the utterance
    gate.push(frame, start_sample=1024, probability=0.1)
    gate.push(frame, start_sample=1536, probability=0.1)
    assert gate.state == "HANGOVER"

    # Resume speech past soft_max_samples (up to sample 3072 >= 2048)
    gate.push(frame, start_sample=2048, probability=0.9)
    gate.push(frame, start_sample=2560, probability=0.9)
    assert gate.state == "ACTIVE"

    # Now in soft watermark zone: 3 micro-pause frames close the utterance!
    gate.push(frame, start_sample=3072, probability=0.1)
    gate.push(frame, start_sample=3584, probability=0.1)
    closing = gate.push(frame, start_sample=4096, probability=0.1)
    assert gate.state == "IDLE"
    assert closing[-1].kind == "end"
    assert closing[-1].start_sample == 0
    assert closing[-1].end_sample == 4608


def test_soft_watermark_punctuation_hint_and_rollover_advance() -> None:
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=10,
        prefix_samples=0,
        frame_samples=512,
        soft_max_samples=1536,  # 3 frames
        soft_stop_frames=4,
        terminal_stop_frames=2,
        clause_stop_frames=3,
    )
    frame = bytes(1024)

    # Speak for 3 frames (1536 samples) -> enters soft watermark zone
    gate.push(frame, start_sample=0, probability=0.9)
    gate.push(frame, start_sample=512, probability=0.9)
    gate.push(frame, start_sample=1024, probability=0.9)

    # External rollover advances segment start to 1536 -> no longer in soft zone
    gate.advance_segment_start(1536)
    gate.push(frame, start_sample=1536, probability=0.1)
    gate.push(frame, start_sample=2048, probability=0.1)
    assert gate.state == "HANGOVER"

    # Resume speech for 2 frames from 2560 -> reaches 3584 (span = 2048 >= 1536)
    gate.push(frame, start_sample=2560, probability=0.9)
    gate.push(frame, start_sample=3072, probability=0.9)
    gate.set_punctuation_boundary_hint("terminal", sample_watermark=3584)

    # With terminal punctuation hint in soft zone, only 2 frames (64ms) close the segment
    gate.push(frame, start_sample=3584, probability=0.40)  # below soft stop threshold 0.425
    closing = gate.push(frame, start_sample=4096, probability=0.40)
    assert gate.state == "IDLE"
    assert closing[-1].kind == "end"
    assert closing[-1].start_sample == 1536
    assert closing[-1].end_sample == 4608


def test_boundary_hint_uses_absolute_kernel_samples() -> None:
    """An item starting at kernel sample 16000 with relative watermark 8000
    must align its hint at 24000 (not relative 8000 or 24kHz wire 36000)."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=10,
        prefix_samples=0,
        frame_samples=512,
        soft_max_samples=4096,
        soft_stop_frames=6,
        terminal_stop_frames=2,
        clause_stop_frames=4,
    )
    frame = bytes(1024)
    gate.reset(next_sample=16_000)

    # Push 15 frames (7680 samples: 16000 -> 23680) + 1 frame (23680 -> 24192)
    # Last speech frame is 23488..24000 if we align start or push speech up to 24000:
    # Let's push 15 speech frames from 16000 -> 23680, then 1 speech chunk of 320 samples
    # + 192 samples so a frame ends past 24000, or align speech frames so speech ends at 24000:
    # Even simpler: push speech frames from 16000 to 23680 (15 frames = 7680 samples >= 4096).
    for idx in range(15):
        gate.push(frame, start_sample=16_000 + idx * 512, probability=0.9)
    # 1 silence frame (23680 -> 24192): frontier >= 24000 while last speech is 23680.
    gate.push(frame, start_sample=23_680, probability=0.1)
    assert gate.state == "HANGOVER"

    # Relative watermark 8000 (<= segment start 16000) must be rejected
    gate.set_punctuation_boundary_hint("terminal", sample_watermark=8_000)
    d_rel = gate.push(frame, start_sample=24_192, probability=0.1)
    assert gate.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_rel)

    # Wire watermark 36000 (> processed frontier) must be rejected
    gate.set_punctuation_boundary_hint("terminal", sample_watermark=36_000)
    d_wire = gate.push(frame, start_sample=24_704, probability=0.1)
    assert gate.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_wire)

    # Resume 1 speech frame (25216 -> 25728), then 1 silence frame (25728 -> 26240)
    # Wait: let's also directly test exact 16000 + 8000 = 24000 on a fresh gate!
    gate2 = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=10,
        prefix_samples=0,
        frame_samples=500,
        soft_max_samples=4_000,
        soft_stop_frames=6,
        terminal_stop_frames=2,
        clause_stop_frames=4,
    )
    frame500 = bytes(1000)
    gate2.reset(next_sample=16_000)
    # 16 frames of 500 samples: 16000 -> 24000
    for idx in range(16):
        gate2.push(frame500, start_sample=16_000 + idx * 500, probability=0.9)

    # Misaligned 8000 or 36000 must not trigger 2-frame terminal cut
    gate2.set_punctuation_boundary_hint("terminal", sample_watermark=8_000)
    gate2.push(frame500, start_sample=24_000, probability=0.1)
    d_bad1 = gate2.push(frame500, start_sample=24_500, probability=0.1)
    assert gate2.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_bad1)

    gate2.set_punctuation_boundary_hint("terminal", sample_watermark=36_000)
    d_bad2 = gate2.push(frame500, start_sample=25_000, probability=0.1)
    assert gate2.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_bad2)

    # Exact absolute kernel sample 24000 (16000 + 8000) covers speech up to 24000 and is within TTL:
    gate2.set_punctuation_boundary_hint("terminal", sample_watermark=24_000)
    closing = gate2.push(frame500, start_sample=25_500, probability=0.1)
    assert gate2.state == "IDLE"
    assert closing[-1].kind == "end"
    assert closing[-1].start_sample == 16_000
    assert closing[-1].end_sample == 26_000


def test_boundary_hint_expiry_and_speech_frontier() -> None:
    """Verify TTL boundary (8000 valid vs 8001 expired), future/missing/regressing
    watermarks, speech frontier invalidation on resumed speech, and same-watermark
    revocation."""
    frame = bytes(1024)

    def make_gate_at_soft_zone() -> SpeechAdmission:
        g = SpeechAdmission(
            threshold=0.5,
            start_frames=1,
            stop_frames=12,
            prefix_samples=0,
            frame_samples=512,
            soft_max_samples=4_096,
            soft_stop_frames=8,
            terminal_stop_frames=2,
            clause_stop_frames=4,
        )
        # Push 10 speech frames: 0 -> 5120 (in soft zone, last_speech_frame_end = 5120)
        for idx in range(10):
            g.push(frame, start_sample=idx * 512, probability=0.9)
        return g

    # 1. Exact age == 8000 vs age == 8001
    # Use frame_samples=500 so frame ends land on exact multiples of 500:
    g_ttl = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=25,
        prefix_samples=0,
        frame_samples=500,
        soft_max_samples=4_000,
        soft_stop_frames=20,
        terminal_stop_frames=2,
        clause_stop_frames=4,
    )
    f500 = bytes(1000)
    # Speech from 0 to 16000 (32 frames)
    for idx in range(32):
        g_ttl.push(f500, start_sample=idx * 500, probability=0.9)
    # 15 silence frames: 16000 -> 23500
    for idx in range(15):
        g_ttl.push(f500, start_sample=16_000 + idx * 500, probability=0.1)
    assert g_ttl.state == "HANGOVER"

    # Next frame (23500 -> 24000) has frame_end_sample = 24000.
    # Watermark 15999 -> age = 24000 - 15999 = 8001 (expired) AND < last_speech_frame_end (16000).
    # Wait: to isolate age 8000 vs 8001 while satisfying watermark >= last_speech_frame_end:
    # Have speech end at 15500, then silence up to 23500!
    g_age = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=25,
        prefix_samples=0,
        frame_samples=500,
        soft_max_samples=4_000,
        soft_stop_frames=20,
        terminal_stop_frames=2,
        clause_stop_frames=4,
    )
    for idx in range(31):  # 0 -> 15500 speech
        g_age.push(f500, start_sample=idx * 500, probability=0.9)
    for idx in range(16):  # 15500 -> 23500 silence (16 frames < soft_stop_frames=20)
        g_age.push(f500, start_sample=15_500 + idx * 500, probability=0.1)
    assert g_age.state == "HANGOVER"

    # At next frame 23500 -> 24000:
    # Watermark 15999 >= last_speech_frame_end (15500), age = 8001 > 8000 -> expired!
    g_age.set_punctuation_boundary_hint("terminal", sample_watermark=15_999)
    d_8001 = g_age.push(f500, start_sample=23_500, probability=0.1)
    assert g_age.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_8001)

    # At next frame 24000 -> 24500:
    # Watermark 16500 >= last_speech_frame_end (15500), age = 8000 <= 8000 -> valid!
    g_age.set_punctuation_boundary_hint("terminal", sample_watermark=16_500)
    d_8000 = g_age.push(f500, start_sample=24_000, probability=0.1)
    assert g_age.state == "IDLE"
    assert d_8000[-1].kind == "end"
    assert d_8000[-1].end_sample == 24_500

    # 2. Speech frontier: watermark < last_speech_frame_end
    g_frontier = make_gate_at_soft_zone()  # speech ended at 5120
    # Hint only covers up to 4608 (< 5120) -> must not fast cut
    g_frontier.set_punctuation_boundary_hint("terminal", sample_watermark=4_608)
    g_frontier.push(frame, start_sample=5_120, probability=0.1)
    d_stale = g_frontier.push(frame, start_sample=5_632, probability=0.1)
    assert g_frontier.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_stale)

    # Valid hint at 5120, then speech resumes at 6144..6656 -> old hint invalidated!
    g_frontier.set_punctuation_boundary_hint("terminal", sample_watermark=5_120)
    g_frontier.push(frame, start_sample=6_144, probability=0.9)  # last_speech = 6656
    g_frontier.push(frame, start_sample=6_656, probability=0.1)
    d_resumed = g_frontier.push(frame, start_sample=7_168, probability=0.1)
    assert g_frontier.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_resumed)

    # 3. Same-watermark revocation, regressing watermark ignored, and missing watermark revocation
    g_revoke = make_gate_at_soft_zone()  # speech ended at 5120
    g_revoke.set_punctuation_boundary_hint("terminal", sample_watermark=5_120)
    # Regressing watermark (4800 < 5120) attempting to clear or change must be ignored
    g_revoke.set_punctuation_boundary_hint(None, sample_watermark=4_800)
    # Same watermark (5120 == 5120) revoking punctuation must take effect immediately
    g_revoke.set_punctuation_boundary_hint(None, sample_watermark=5_120)
    # Regressing watermark (5000 < 5120) attempting to re-enable terminal must be ignored
    g_revoke.set_punctuation_boundary_hint("terminal", sample_watermark=5_000)
    g_revoke.push(frame, start_sample=5_120, probability=0.1)
    d_revoked = g_revoke.push(frame, start_sample=5_632, probability=0.1)
    assert g_revoke.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_revoked)

    # Advance hint to 5632, then revoke via missing watermark (sample_watermark=None)
    g_revoke.set_punctuation_boundary_hint("terminal", sample_watermark=5_632)
    g_revoke.set_punctuation_boundary_hint("terminal", sample_watermark=None)
    d_missing = g_revoke.push(frame, start_sample=6_144, probability=0.1)
    assert g_revoke.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d_missing)


def test_caption_boundary_tiers_use_exact_frame_counts() -> None:
    """In caption soft zone (stop=21, soft=17, clause=8, terminal=4):
    - terminal cuts on frame 4 (not 3)
    - clause cuts on frame 8 (not 6 or 7)
    - no hint cuts on frame 17 (not 16)
    """
    frame = bytes(1024)

    def run_tier(kind: str | None) -> int:
        gate = SpeechAdmission(
            threshold=0.5,
            start_frames=1,
            stop_frames=21,
            prefix_samples=0,
            frame_samples=512,
            soft_max_samples=123_200,  # 7.7s at 16kHz
            soft_stop_frames=17,
            terminal_stop_frames=4,
            clause_stop_frames=8,
        )
        # Push 241 speech frames (123,392 samples >= 123,200)
        for idx in range(241):
            gate.push(frame, start_sample=idx * 512, probability=0.9)
        speech_end = 241 * 512
        if kind is not None:
            gate.set_punctuation_boundary_hint(
                kind,  # type: ignore[arg-type]
                sample_watermark=speech_end,
            )
        for pause_frame in range(1, 22):
            decisions = gate.push(
                frame,
                start_sample=speech_end + (pause_frame - 1) * 512,
                probability=0.1,
            )
            if any(dec.kind == "end" for dec in decisions):
                return pause_frame
        raise AssertionError("utterance did not close within 21 frames")

    assert run_tier("terminal") == 4
    assert run_tier("clause") == 8
    assert run_tier(None) == 17


def test_punctuation_classifier_rejects_ambiguous_endings() -> None:
    from speechrail.application.realtime_asr import classify_punctuation_boundary

    # Terminal punctuation with trailing whitespace and closing quotes/brackets
    assert classify_punctuation_boundary("你好。") == "terminal"
    assert classify_punctuation_boundary("你好！” ") == "terminal"
    assert classify_punctuation_boundary("Really?!）」』”'") == "terminal"

    # Clause punctuation with closing wrappers
    assert classify_punctuation_boundary("一方面，") == "clause"
    assert classify_punctuation_boundary("first, ") == "clause"
    assert classify_punctuation_boundary("注意：”") == "clause"
    assert classify_punctuation_boundary("A；B、") == "clause"

    # Empty or wrapper-only text
    assert classify_punctuation_boundary("") is None
    assert classify_punctuation_boundary("   \t\n ") is None
    assert classify_punctuation_boundary("”’」』）》】)］]}\"'") is None

    # Ellipsis and dashes must not trigger fast cuts
    assert classify_punctuation_boundary("未完待续…", language="zh") is None
    assert classify_punctuation_boundary("未完待续...", language="zh") is None
    assert classify_punctuation_boundary("wait...", language="en") is None
    assert classify_punctuation_boundary("破折号——", language="zh") is None
    assert classify_punctuation_boundary("dash —", language="en") is None
    assert classify_punctuation_boundary("hyphen-", language="en") is None

    # ASCII period: rejected for decimals, abbreviations, Latin tokens, and non-explicit-zh sessions
    for lang in (None, "auto", "en", "ja", "ko", "zh"):
        assert classify_punctuation_boundary("3.14", language=lang) is None
        assert classify_punctuation_boundary("3.", language=lang) is None
        assert classify_punctuation_boundary("Dr.", language=lang) is None
        assert classify_punctuation_boundary("U.S.", language=lang) is None
        assert classify_punctuation_boundary("Hello world.", language=lang) is None

    # ASCII period after CJK ideograph: only accepted when session explicitly specifies Chinese
    assert classify_punctuation_boundary("你好.", language=None) is None
    assert classify_punctuation_boundary("你好.", language="auto") is None
    assert classify_punctuation_boundary("你好.", language="en") is None
    assert classify_punctuation_boundary("你好.", language="zh") == "terminal"
    assert classify_punctuation_boundary("你好.”", language="zh-CN") == "terminal"


def test_soft_boundary_requires_vad_pause() -> None:
    """Continuous speech (including weak speech at/above soft stop threshold)
    must not cut even with a fresh terminal hint; weak speech between normal
    stop_threshold (0.35) and soft stop_threshold (0.425) stays active before
    soft zone and only cuts after the required pause frames inside soft zone."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=10,
        prefix_samples=0,
        frame_samples=512,
        soft_max_samples=2048,  # 4 frames
        soft_stop_frames=6,
        terminal_stop_frames=2,
        clause_stop_frames=4,
    )
    frame = bytes(1024)

    # Before soft zone (< 2048 samples): 0.40 is >= normal stop_threshold (0.35), so it stays ACTIVE
    gate.push(frame, start_sample=0, probability=0.9)
    gate.push(frame, start_sample=512, probability=0.40)
    gate.push(frame, start_sample=1024, probability=0.35)
    assert gate.state == "ACTIVE"

    # Cross into soft zone (end_sample = 2048 >= 2048) with clear speech
    gate.push(frame, start_sample=1536, probability=0.9)
    gate.set_punctuation_boundary_hint("terminal", sample_watermark=2048)

    # Continuous speech at 0.50 or 0.425 (soft stop threshold) must NOT cut!
    for idx, prob in enumerate((0.9, 0.5, 0.425, 0.45), start=4):
        end_s = (idx + 1) * 512
        decisions = gate.push(frame, start_sample=idx * 512, probability=prob)
        gate.set_punctuation_boundary_hint("terminal", sample_watermark=end_s)
        assert gate.state == "ACTIVE"
        assert all(dec.kind != "end" for dec in decisions)

    # Weak speech at 0.40 (< 0.425) enters HANGOVER; 1st frame holds, 2nd cuts
    d1 = gate.push(frame, start_sample=4096, probability=0.40)
    assert gate.state == "HANGOVER"
    assert all(dec.kind != "end" for dec in d1)

    d2 = gate.push(frame, start_sample=4608, probability=0.40)
    assert gate.state == "IDLE"
    assert d2[-1].kind == "end"


def test_soft_zone_opportunistic_flush_requests_once_per_hangover_episode() -> None:
    """In the soft watermark zone, when hangover reaches 2 consecutive frames (64ms)
    and the latest hint watermark has not yet covered _last_speech_frame_end,
    consume_soft_zone_flush_request() returns True exactly once per hangover episode."""
    gate = SpeechAdmission(
        threshold=0.5,
        start_frames=1,
        stop_frames=12,
        prefix_samples=0,
        frame_samples=512,
        soft_max_samples=2048,  # 4 frames
        soft_stop_frames=8,
        terminal_stop_frames=4,
        clause_stop_frames=6,
    )
    frame = bytes(1024)

    # 1. Pre-soft-watermark hangover (1536 < 2048): must NOT request flush
    gate.push(frame, start_sample=0, probability=0.9)
    gate.push(frame, start_sample=512, probability=0.1)   # hangover 1 (end=1024)
    assert not gate.consume_soft_zone_flush_request()
    gate.push(frame, start_sample=1024, probability=0.1)  # hangover 2 (end=1536 < 2048)
    assert not gate.consume_soft_zone_flush_request()

    # 2. Resume speech past soft watermark (1536 -> 3072, _last_speech_frame_end = 3072)
    gate.push(frame, start_sample=1536, probability=0.9)
    gate.push(frame, start_sample=2048, probability=0.9)
    gate.push(frame, start_sample=2560, probability=0.9)
    assert not gate.consume_soft_zone_flush_request()

    # 1st hangover frame (32ms dip): must NOT request flush
    gate.push(frame, start_sample=3072, probability=0.1)
    assert not gate.consume_soft_zone_flush_request()

    # 2nd hangover frame (64ms pause) with stale watermark (< 3072): requests flush once!
    gate.set_punctuation_boundary_hint("terminal", sample_watermark=2560)
    gate.push(frame, start_sample=3584, probability=0.1)
    assert gate.consume_soft_zone_flush_request() is True
    assert gate.consume_soft_zone_flush_request() is False

    # 3rd hangover frame in same episode: does NOT request again
    gate.push(frame, start_sample=4096, probability=0.1)
    assert gate.consume_soft_zone_flush_request() is False

    # 3. Resume speech (4608 -> 5120) and immediately supply a fresh watermark covering 5120:
    gate.push(frame, start_sample=4608, probability=0.9)
    gate.set_punctuation_boundary_hint("clause", sample_watermark=5120)
    gate.push(frame, start_sample=5120, probability=0.1)  # hangover 1
    gate.push(frame, start_sample=5632, probability=0.1)  # hangover 2
    assert gate.consume_soft_zone_flush_request() is False

    # 4. If a subsequent partial clears sample_watermark=None (or out-of-bounds),
    # _hint_watermark must also be cleared so a later hangover episode can request flush again:
    gate.push(frame, start_sample=6144, probability=0.9)
    gate.set_punctuation_boundary_hint(None, sample_watermark=None)
    assert gate._hint_watermark is None
    gate.push(frame, start_sample=6656, probability=0.1)  # hangover 1
    gate.push(frame, start_sample=7168, probability=0.1)  # hangover 2
    assert gate.consume_soft_zone_flush_request() is True
