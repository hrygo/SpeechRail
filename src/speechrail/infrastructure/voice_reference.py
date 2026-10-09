"""Local ffmpeg clone-reference adapter over pure WAV validation."""

from __future__ import annotations

import subprocess

from speechrail.domain.tts import validate_transcoded_clone_wav


def transcode_and_validate_clone_audio(
    audio_bytes: bytes,
    *,
    ffmpeg_path: str = "ffmpeg",
    min_duration: float = 2.0,
    max_duration: float = 45.0,
    target_sample_rate: int = 24_000,
    skip_signal_validation: bool = False,
) -> tuple[bytes, float]:
    """Transcode user audio into 24kHz mono PCM16 WAV and validate duration limits.

    When ``skip_signal_validation`` is True the clipping/silence/speech signal
    check is skipped so the authoritative quality gate (``grade_reference_quality``)
    remains the single classifier for reference audio quality. Size, duration and
    container-format checks are always enforced.
    """
    if not audio_bytes:
        raise ValueError("audio content must not be empty")
    if len(audio_bytes) > 15 * 1024 * 1024:
        raise ValueError("audio file exceeds 15MB limit")

    try:
        proc = subprocess.run(
            [
                str(ffmpeg_path),
                "-y",
                "-i",
                "pipe:0",
                "-ac",
                "1",
                "-ar",
                str(target_sample_rate),
                "-f",
                "wav",
                "pipe:1",
            ],
            input=audio_bytes,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg_not_found") from exc
    except subprocess.TimeoutExpired as exc:
        raise ValueError("audio transcoding timed out") from exc

    if proc.returncode != 0:
        err_msg = proc.stderr.decode("utf-8", errors="replace")[:200]
        raise ValueError(f"audio transcoding failed: {err_msg}")

    wav_bytes = proc.stdout
    duration = validate_transcoded_clone_wav(
        wav_bytes,
        min_duration=min_duration,
        max_duration=max_duration,
        target_sample_rate=target_sample_rate,
        skip_signal_validation=skip_signal_validation,
    )
    return wav_bytes, duration
