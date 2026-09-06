#!/usr/bin/env python3
"""
Extract 64-band audio spectrum bars for each of the 2700 video frames (30fps for 90s).
Saves numpy array for instantaneous lookup during rendering.
"""

import wave
from pathlib import Path

import numpy as np

BUILD_DIR = Path(__file__).parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
AUDIO_FILE = BUILD_DIR / "master_audio_90s.wav"
FPS = 30
DURATION = 90.0
TOTAL_FRAMES = int(FPS * DURATION)  # 2700
NUM_BARS = 64


def analyze():
    print(f"Analyzing {AUDIO_FILE} for {TOTAL_FRAMES} frames of spectrum bars...")
    with wave.open(str(AUDIO_FILE), "rb") as wf:
        n_channels = wf.getnchannels()
        framerate = wf.getframerate()
        n_frames = wf.getnframes()
        raw_data = wf.readframes(n_frames)

    # Convert to float32 mono
    audio = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0
    if n_channels == 2:
        audio = (audio[0::2] + audio[1::2]) * 0.5

    samples_per_frame = int(framerate / FPS)
    spectrum_data = np.zeros((TOTAL_FRAMES, NUM_BARS), dtype=np.float32)

    # Precompute log-spaced frequency bins
    fft_size = 1024
    freqs = np.fft.rfftfreq(fft_size, 1.0 / framerate)
    # Focus on speech and music frequencies (60Hz to 6000Hz)
    bin_edges = np.logspace(np.log10(60), np.log10(6000), NUM_BARS + 1)

    for f_idx in range(TOTAL_FRAMES):
        center_sample = f_idx * samples_per_frame
        start_s = max(0, center_sample - fft_size // 2)
        end_s = min(len(audio), start_s + fft_size)
        chunk = np.zeros(fft_size, dtype=np.float32)
        actual = audio[start_s:end_s]
        chunk[: len(actual)] = actual

        # Apply Hanning window
        chunk = chunk * np.hanning(len(chunk))
        fft_vals = np.abs(np.fft.rfft(chunk))

        # Integrate into NUM_BARS
        for b in range(NUM_BARS):
            mask = (freqs >= bin_edges[b]) & (freqs < bin_edges[b + 1])
            val = np.mean(fft_vals[mask]) if np.any(mask) else 0.0
            # Apply dB scaling and normalization
            val_norm = np.clip(val * 4.5, 0.05, 1.0)
            spectrum_data[f_idx, b] = val_norm

    out_file = BUILD_DIR / "spectrum.npy"
    np.save(str(out_file), spectrum_data)
    print(f"Spectrum data saved to {out_file}, shape: {spectrum_data.shape}")


if __name__ == "__main__":
    analyze()
