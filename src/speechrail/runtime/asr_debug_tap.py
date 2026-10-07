"""Time-boxed ASR input PCM capture for field diagnosis.

Disabled by default: the tap only writes while the current time is before
``SPEECHRAIL_ASR_DEBUG_CAPTURE_UNTIL`` (unix epoch seconds). The env var is
read on every append, so flipping it takes effect without a service restart.

Captured audio is the 16 kHz kernel PCM16 (mono) actually fed to ASR -- the
same bytes ``_append_asr_audio`` forwards to the backend. Files are plain WAV
(44-byte header, 16 kHz / mono / 16-bit) so they play directly in QuickTime.

Privacy: session PCM never hits disk unless this tap is explicitly armed by
the operator. Capture is additionally bounded by ``max_bytes`` as a fail-safe
on top of the time window, and the tap closes the file as soon as either
bound is hit.
"""

from __future__ import annotations

import logging
import os
import struct
import time
from pathlib import Path
from typing import BinaryIO

from speechrail.compatibility.openai_realtime import ASR_KERNEL_SAMPLE_RATE

logger = logging.getLogger(__name__)

CAPTURE_UNTIL_ENV_VAR = "SPEECHRAIL_ASR_DEBUG_CAPTURE_UNTIL"
CAPTURE_SUBDIR = "asr-debug"
# 16-bit mono samples: 1s = 32_000 bytes. 64 MiB ≈ 34 min at 16 kHz, comfortably
# above a 20-minute window while still bounding a runaway tap.
DEFAULT_MAX_BYTES = 64 * 1024 * 1024
_FALLBACK_LOG_DIR = Path.home() / "Library" / "Logs" / "SpeechRail"


def _capture_until() -> float | None:
    """Return the armed capture deadline, or None when the tap is off."""

    raw = os.environ.get(CAPTURE_UNTIL_ENV_VAR)
    if not raw:
        return None
    try:
        deadline = float(raw)
    except ValueError:
        return None
    if deadline <= 0:
        return None
    return deadline


def capture_armed(now: float | None = None) -> bool:
    """True while the operator has armed PCM capture and the window is open."""

    deadline = _capture_until()
    if deadline is None:
        return False
    return (time.time() if now is None else now) < deadline


class AsrDebugTap:
    """Per-session WAV writer for ASR kernel PCM. Open-on-first-armed-append."""

    def __init__(
        self,
        session_id: str,
        *,
        log_dir: Path | None = None,
        max_bytes: int = DEFAULT_MAX_BYTES,
    ) -> None:
        self._session_id = "".join(
            ch if (ch.isalnum() or ch in "-_") else "_" for ch in session_id
        )[:64] or "session"
        base = log_dir if log_dir is not None else _FALLBACK_LOG_DIR
        self._directory = base / CAPTURE_SUBDIR
        self._max_bytes = max_bytes
        self._handle: BinaryIO | None = None
        self._written = 0
        self._path: Path | None = None

    @property
    def path(self) -> Path | None:
        return self._path

    @property
    def written_bytes(self) -> int:
        return self._written

    def append(self, pcm16: bytes) -> None:
        """Write ``pcm16`` when armed; no-op (cheap) otherwise."""

        if self._handle is None:
            if not capture_armed():
                return
            try:
                self._directory.mkdir(parents=True, exist_ok=True)
                stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
                self._path = (
                    self._directory / f"asr-input-{stamp}-{self._session_id}.wav"
                )
                # Long-lived handle by design (one open WAV per armed session);
                # closed + header-patched in close().
                self._handle = self._path.open("wb")
                # Placeholder WAV header; patched with real sizes on close.
                self._handle.write(self._wav_header(0))
            except OSError:
                logger.warning("asr debug tap: cannot open capture file", exc_info=True)
                return
        assert self._handle is not None
        if not capture_armed():
            self.close()
            return
        if self._written + len(pcm16) > self._max_bytes:
            logger.warning(
                "asr debug tap: byte budget exhausted; closing %s", self._path
            )
            self.close()
            return
        try:
            self._handle.write(pcm16)
            self._written += len(pcm16)
        except OSError:
            logger.warning("asr debug tap: write failed", exc_info=True)
            self.close()

    def close(self) -> None:
        handle, self._handle = self._handle, None
        if handle is None:
            return
        try:
            handle.seek(0)
            handle.write(self._wav_header(self._written))
            handle.close()
        except OSError:
            logger.warning("asr debug tap: close failed", exc_info=True)

    @staticmethod
    def _wav_header(data_bytes: int) -> bytes:
        sample_rate = ASR_KERNEL_SAMPLE_RATE
        return struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF",
            36 + data_bytes,
            b"WAVE",
            b"fmt ",
            16,  # fmt chunk size
            1,  # PCM
            1,  # mono
            sample_rate,
            sample_rate * 2,  # byte rate
            2,  # block align
            16,  # bits per sample
            b"data",
            data_bytes,
        )
