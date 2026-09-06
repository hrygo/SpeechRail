#!/usr/bin/env python3
"""
Generate a cinematic 90-second cyberpunk / tech-ambient synth background music (BGM).
Features:
- Sub-bass pulsing rhythm (80 BPM)
- Warm analog pad chords evolving with the 6 acts (Dm -> Bb -> F -> C -> Gm -> Dm)
- Crystalline arpeggios that shimmer and add momentum
- Dynamic mix envelope tailored for voiceover
"""

import wave
from pathlib import Path

import numpy as np

BUILD_DIR = Path(__file__).parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
SAMPLE_RATE = 44100
DURATION = 90.0
NUM_SAMPLES = int(SAMPLE_RATE * DURATION)


def generate_bgm():
    print("Generating 90-second cinematic tech ambient BGM...")
    t = np.linspace(0, DURATION, NUM_SAMPLES, endpoint=False)

    # 1. 80 BPM Clock: beat every 0.75 seconds
    beat_period = 60.0 / 80.0
    beat_phase = (t % beat_period) / beat_period

    # Kick / Pulse: exponential decay per beat
    pulse_env = np.exp(-beat_phase * 6.0)
    # Pitch drop from 90Hz to 45Hz per beat
    pulse_freq = 45.0 + 45.0 * np.exp(-beat_phase * 12.0)
    kick = np.sin(2 * np.pi * pulse_freq * t) * pulse_env * 0.35

    # 2. Chord Progression across the 6 Acts (15s each):
    # Act 1 (0-15s): D minor (D2, A2, F3, D4)
    # Act 2 (15-30s): Bb major (Bb1, F2, D3, Bb3)
    # Act 3 (30-45s): F major (F1, C2, A2, F3)
    # Act 4 (45-60s): C major / G (C2, G2, E3, C4)
    # Act 5 (60-75s): G minor (G1, D2, Bb2, G3) - tension & color change for multi-voice!
    # Act 6 (75-90s): D minor resolution (D2, A2, F3, A3) - triumphant finale

    chords = [
        # (start_s, end_s, [freqs])
        (0.0, 15.0, [73.42, 110.00, 174.61, 293.66]),
        (15.0, 30.0, [58.27, 87.31, 146.83, 233.08]),
        (30.0, 45.0, [43.65, 65.41, 110.00, 174.61]),
        (45.0, 60.0, [65.41, 98.00, 164.81, 261.63]),
        (60.0, 75.0, [48.99, 73.42, 116.54, 196.00]),
        (75.0, 90.0, [73.42, 110.00, 174.61, 220.00, 440.00]),
    ]

    pad_left = np.zeros(NUM_SAMPLES, dtype=np.float32)
    pad_right = np.zeros(NUM_SAMPLES, dtype=np.float32)

    for start_s, end_s, freqs in chords:
        mask = (t >= start_s) & (t < end_s)
        sub_t = t[mask]

        # Local fade in and fade out for chords (1.5s transition)
        local_t = sub_t - start_s
        dur = end_s - start_s
        fade = np.ones_like(sub_t)
        in_mask = local_t < 1.5
        fade[in_mask] = 0.5 * (1 - np.cos(np.pi * local_t[in_mask] / 1.5))
        out_mask = (dur - local_t) < 1.5
        fade[out_mask] = 0.5 * (1 - np.cos(np.pi * (dur - local_t[out_mask]) / 1.5))

        chunk_l = np.zeros_like(sub_t)
        chunk_r = np.zeros_like(sub_t)

        for idx, f in enumerate(freqs):
            # Rich analog detune
            detune = 1.002**idx
            l_wave = np.sin(2 * np.pi * f * sub_t) + 0.3 * np.sin(4 * np.pi * f * sub_t)
            r_wave = np.sin(2 * np.pi * f * detune * sub_t) + 0.3 * np.sin(
                4 * np.pi * f * detune * sub_t
            )
            chunk_l += l_wave / len(freqs)
            chunk_r += r_wave / len(freqs)

        pad_left[mask] += chunk_l * fade * 0.28
        pad_right[mask] += chunk_r * fade * 0.28

    # 3. Shimmering Tech Arpeggio (16th notes at 80 BPM = 0.1875s per note)
    arp_period = beat_period / 4.0
    arp_note_idx = np.floor(t / arp_period).astype(int) % 8

    # Scale degrees: D minor pentatonic [D4, F4, G4, A4, C5, D5, C5, A4]
    arp_freqs = np.array([293.66, 349.23, 392.00, 440.00, 523.25, 587.33, 523.25, 440.00])
    current_arp_f = arp_freqs[arp_note_idx]

    arp_phase = (t % arp_period) / arp_period
    arp_env = np.exp(-arp_phase * 9.0)

    # Add ping-pong panning to arpeggio
    arp_pan = np.sin(2 * np.pi * 0.5 * t)
    arp_l = np.sin(2 * np.pi * current_arp_f * t) * arp_env * 0.12 * (0.5 + 0.5 * arp_pan)
    arp_r = np.sin(2 * np.pi * current_arp_f * t) * arp_env * 0.12 * (0.5 - 0.5 * arp_pan)

    # 4. Master Global Fade In (0 to 3s) and Fade Out (86 to 90s)
    global_env = np.ones(NUM_SAMPLES, dtype=np.float32)
    fade_in_idx = int(3.0 * SAMPLE_RATE)
    global_env[:fade_in_idx] = np.linspace(0, 1, fade_in_idx)
    fade_out_idx = int(4.0 * SAMPLE_RATE)
    global_env[-fade_out_idx:] = np.linspace(1, 0, fade_out_idx)

    final_l = (kick + pad_left + arp_l) * global_env
    final_r = (kick + pad_right + arp_r) * global_env

    # Normalize to -3dB peak
    peak = max(np.max(np.abs(final_l)), np.max(np.abs(final_r)), 1e-6)
    target_peak = 0.7
    final_l = final_l * (target_peak / peak)
    final_r = final_r * (target_peak / peak)

    # Interleave to stereo 16-bit
    stereo_int16 = np.zeros(NUM_SAMPLES * 2, dtype=np.int16)
    stereo_int16[0::2] = (np.clip(final_l, -1.0, 1.0) * 32767).astype(np.int16)
    stereo_int16[1::2] = (np.clip(final_r, -1.0, 1.0) * 32767).astype(np.int16)

    bgm_path = BUILD_DIR / "bgm_90s.wav"
    with wave.open(str(bgm_path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(stereo_int16.tobytes())

    print(f"BGM generated successfully: {bgm_path} (Duration: {DURATION}s)")
    return bgm_path


if __name__ == "__main__":
    generate_bgm()
