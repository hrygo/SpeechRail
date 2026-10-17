"""Streaming audiobook media encoder using managed FFmpeg and MP4 chapter tracks."""

from __future__ import annotations

import asyncio
import contextlib
import errno
import json
import math
import re
import shutil
import struct
import subprocess
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast
from uuid import UUID

from speechrail.media.manifest import (
    IO_CHUNK_BYTES,
    MediaExportManifest,
    MediaLoudnessSettings,
    sha256_file_chunked,
)

SAMPLE_RATE_HZ = 48_000
CHANNELS = 1
NO_PROGRESS_TIMEOUT_SECONDS = 90.0
TOTAL_EXPORT_TIMEOUT_SECONDS = 2 * 3600.0
CAPTURE_LIMIT_BYTES = 1024 * 1024


class MediaEncodeError(RuntimeError):
    """Raised when media encoding fails, times out, or is cancelled."""

    def __init__(self, message: str, *, error_code: str = "command_failed") -> None:
        super().__init__(message)
        self.error_code = error_code


class MediaCodecUnavailableError(MediaEncodeError):
    """Raised when the managed FFmpeg binary or required encoder is missing."""

    def __init__(self, message: str) -> None:
        super().__init__(message, error_code="codec_unavailable")


@dataclass(frozen=True, slots=True)
class MediaToolchain:
    ffmpeg_path: Path | None
    encoders: frozenset[str]
    has_loudnorm: bool = False

    @property
    def available(self) -> bool:
        return self.ffmpeg_path is not None and self.ffmpeg_path.is_file()

    @property
    def supports_m4b(self) -> bool:
        return self.available and "aac" in self.encoders

    @property
    def supports_mp3(self) -> bool:
        return self.available and "libmp3lame" in self.encoders


@dataclass(frozen=True, slots=True)
class MediaExportResult:
    request_id: UUID
    profile: str
    relative_outputs: tuple[str, ...]
    total_frame_count: int
    sample_rate: int
    chapter_count: int
    output_sha256s: dict[str, str]

    def to_dict(self) -> dict[str, object]:
        return {
            "chapter_count": self.chapter_count,
            "output_sha256s": dict(self.output_sha256s),
            "profile": self.profile,
            "relative_outputs": list(self.relative_outputs),
            "request_id": str(self.request_id),
            "sample_rate": self.sample_rate,
            "total_frame_count": self.total_frame_count,
        }


@dataclass(frozen=True, slots=True)
class MediaProcessOutput:
    return_code: int
    stdout: str
    stderr: str


class MediaProcessRunner(Protocol):
    async def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
        on_progress: Callable[[dict[str, object]], None] | None = None,
        no_progress_timeout: float = NO_PROGRESS_TIMEOUT_SECONDS,
        total_timeout: float = TOTAL_EXPORT_TIMEOUT_SECONDS,
    ) -> int: ...

    async def run_capture(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
    ) -> MediaProcessOutput: ...


class SubprocessMediaRunner:
    """Executes fixed FFmpeg argv with bounded stdout progress reading
    and guaranteed child reaping.
    """

    async def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
        on_progress: Callable[[dict[str, object]], None] | None = None,
        no_progress_timeout: float = NO_PROGRESS_TIMEOUT_SECONDS,
        total_timeout: float = TOTAL_EXPORT_TIMEOUT_SECONDS,
    ) -> int:
        process = await asyncio.create_subprocess_exec(
            *argv,
            cwd=str(cwd),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        start_monotonic = time.monotonic()
        last_progress_monotonic = start_monotonic
        stderr_tail = bytearray()

        async def _consume_stderr() -> None:
            assert process.stderr is not None
            while True:
                chunk = await process.stderr.read(4096)
                if not chunk:
                    break
                if len(stderr_tail) < 8192:
                    stderr_tail.extend(chunk[: 8192 - len(stderr_tail)])

        stderr_task = asyncio.create_task(_consume_stderr())
        try:
            assert process.stdout is not None
            while True:
                if cancel_event is not None and cancel_event.is_set():
                    await _terminate_and_reap(process)
                    raise MediaEncodeError("media export was cancelled", error_code="cancelled")

                now = time.monotonic()
                if now - start_monotonic > total_timeout:
                    await _terminate_and_reap(process)
                    raise MediaEncodeError(
                        "media export exceeded maximum duration", error_code="timeout"
                    )

                remaining_stall = max(0.05, no_progress_timeout - (now - last_progress_monotonic))
                try:
                    line_bytes = await asyncio.wait_for(
                        process.stdout.readline(),
                        timeout=min(1.0, remaining_stall),
                    )
                except TimeoutError as exc:
                    if time.monotonic() - last_progress_monotonic >= no_progress_timeout:
                        await _terminate_and_reap(process)
                        raise MediaEncodeError(
                            "media export stalled without progress", error_code="timeout"
                        ) from exc
                    if process.returncode is not None:
                        break
                    continue

                if not line_bytes:
                    break
                last_progress_monotonic = time.monotonic()
                line = line_bytes.decode("utf-8", errors="replace").strip()
                if "=" in line and on_progress is not None:
                    key, _, val = line.partition("=")
                    on_progress({key.strip(): val.strip()})

            return_code = await process.wait()
            await stderr_task
            if return_code != 0:
                stderr_text = stderr_tail.decode("utf-8", errors="replace").lower()
                if "no space left on device" in stderr_text:
                    raise MediaEncodeError(
                        "insufficient disk space during media export",
                        error_code="insufficient_disk_space",
                    )
                raise MediaEncodeError(
                    "ffmpeg exited with non-zero status", error_code="command_failed"
                )
            return return_code
        except asyncio.CancelledError:
            await _terminate_and_reap(process)
            raise
        finally:
            if not stderr_task.done():
                stderr_task.cancel()
                with contextlib.suppress(BaseException):
                    await stderr_task

    async def run_capture(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
    ) -> MediaProcessOutput:
        process = await asyncio.create_subprocess_exec(
            *argv,
            cwd=str(cwd),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert process.stdout is not None
        assert process.stderr is not None
        stdout_buf = bytearray()
        stderr_buf = bytearray()
        start_monotonic = time.monotonic()
        last_progress_monotonic = start_monotonic

        async def _drain(
            stream: asyncio.StreamReader, buffer: bytearray, *, is_progress: bool
        ) -> None:
            nonlocal last_progress_monotonic
            while True:
                chunk = await stream.read(4096)
                if not chunk:
                    break
                if is_progress:
                    last_progress_monotonic = time.monotonic()
                if len(buffer) < CAPTURE_LIMIT_BYTES:
                    buffer.extend(chunk[: CAPTURE_LIMIT_BYTES - len(buffer)])

        stdout_task = asyncio.create_task(
            _drain(process.stdout, stdout_buf, is_progress=False)
        )
        stderr_task = asyncio.create_task(
            _drain(process.stderr, stderr_buf, is_progress=True)
        )
        try:
            while not (stdout_task.done() and stderr_task.done()):
                if cancel_event is not None and cancel_event.is_set():
                    await _terminate_and_reap(process)
                    raise MediaEncodeError("media export was cancelled", error_code="cancelled")

                now = time.monotonic()
                if now - start_monotonic > TOTAL_EXPORT_TIMEOUT_SECONDS:
                    await _terminate_and_reap(process)
                    raise MediaEncodeError(
                        "media export exceeded maximum duration", error_code="timeout"
                    )
                if now - last_progress_monotonic >= NO_PROGRESS_TIMEOUT_SECONDS:
                    await _terminate_and_reap(process)
                    raise MediaEncodeError(
                        "media export stalled without progress", error_code="timeout"
                    )
                await asyncio.sleep(0.1)

            return_code = await process.wait()
            await asyncio.gather(stdout_task, stderr_task)
            return MediaProcessOutput(
                return_code=return_code,
                stdout=stdout_buf.decode("utf-8", errors="replace"),
                stderr=stderr_buf.decode("utf-8", errors="replace"),
            )
        except asyncio.CancelledError:
            await _terminate_and_reap(process)
            raise
        finally:
            for task in (stdout_task, stderr_task):
                if not task.done():
                    task.cancel()
                    with contextlib.suppress(BaseException):
                        await task


async def _terminate_and_reap(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), timeout=3.0)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()


def discover_media_toolchain(app_home: Path) -> MediaToolchain:
    """Inspect `<app_home>/vendor/current/ffmpeg/bin/ffmpeg` without downloading anything."""
    candidates = [
        Path(app_home) / "vendor" / "current" / "ffmpeg" / "bin" / "ffmpeg",
    ]
    system_ffmpeg = shutil.which("ffmpeg")
    if system_ffmpeg:
        candidates.append(Path(system_ffmpeg))

    ffmpeg_bin: Path | None = None
    for candidate in candidates:
        if candidate.is_file() and not candidate.is_symlink():
            ffmpeg_bin = candidate
            break
        if candidate.is_file():
            ffmpeg_bin = candidate
            break

    if ffmpeg_bin is None:
        return MediaToolchain(ffmpeg_path=None, encoders=frozenset())

    try:
        completed = subprocess.run(
            [str(ffmpeg_bin), "-hide_banner", "-encoders"],
            capture_output=True,
            text=True,
            timeout=10.0,
            check=False,
        )
    except OSError:
        return MediaToolchain(ffmpeg_path=None, encoders=frozenset())

    found: set[str] = set()
    output = (completed.stdout or "") + "\n" + (completed.stderr or "")
    for token in ("aac", "libmp3lame", "pcm_s16le"):
        if re.search(rf"\b{re.escape(token)}\b", output):
            found.add(token)

    has_loudnorm = False
    try:
        filters_completed = subprocess.run(
            [str(ffmpeg_bin), "-hide_banner", "-filters"],
            capture_output=True,
            text=True,
            timeout=10.0,
            check=False,
        )
    except OSError:
        has_loudnorm = False
    else:
        filters_output = (filters_completed.stdout or "") + "\n" + (filters_completed.stderr or "")
        has_loudnorm = bool(re.search(r"\bloudnorm\b", filters_output))

    return MediaToolchain(
        ffmpeg_path=ffmpeg_bin,
        encoders=frozenset(found),
        has_loudnorm=has_loudnorm,
    )


def escape_ffmetadata(value: str) -> str:
    """Escape special characters (`=`, `;`, `#`, `\\`, newline) per FFmetadata specification."""
    escaped = value.replace("\\", "\\\\")
    escaped = escaped.replace("=", "\\=")
    escaped = escaped.replace(";", "\\;")
    escaped = escaped.replace("#", "\\#")
    return escaped.replace("\r\n", "\\\n").replace("\r", "\\\n").replace("\n", "\\\n")


def read_wav_pcm16_frames(path: Path) -> int:
    """Stream WAV RIFF chunks using bounded reads and return exact 48 kHz mono PCM16 frame count."""
    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) < 12 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
            raise MediaEncodeError(
                "normalized WAV is missing RIFF/WAVE header",
                error_code="integrity_mismatch",
            )
        channels = 1
        bits_per_sample = 16
        data_bytes = 0
        while True:
            chunk_hdr = handle.read(8)
            if len(chunk_hdr) < 8:
                break
            chunk_id = chunk_hdr[:4]
            (chunk_size,) = struct.unpack("<I", chunk_hdr[4:8])
            if chunk_id == b"fmt ":
                fmt_body = handle.read(chunk_size)
                if len(fmt_body) >= 16:
                    _, channels, sample_rate, _, _, bits_per_sample = struct.unpack(
                        "<HHIIHH", fmt_body[:16]
                    )
                    if (
                        sample_rate != SAMPLE_RATE_HZ
                        or channels != CHANNELS
                        or bits_per_sample != 16
                    ):
                        raise MediaEncodeError(
                            "normalized WAV does not match 48kHz mono PCM16",
                            error_code="integrity_mismatch",
                        )
            elif chunk_id == b"data":
                remaining = chunk_size
                while remaining > 0:
                    to_read = min(IO_CHUNK_BYTES, remaining)
                    buf = handle.read(to_read)
                    if not buf:
                        break
                    data_bytes += len(buf)
                    remaining -= len(buf)
            else:
                handle.seek(chunk_size, 1)
            if chunk_size % 2 == 1:
                handle.seek(1, 1)

    bytes_per_frame = max(1, channels * (bits_per_sample // 8))
    if data_bytes <= 0 or data_bytes % bytes_per_frame != 0:
        raise MediaEncodeError(
            "normalized WAV contains empty or misaligned PCM data",
            error_code="integrity_mismatch",
        )
    return data_bytes // bytes_per_frame


_MEASUREMENT_KEYS = ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")


def _loudness_probe_argv(
    ffmpeg_str: str, concat_name: str, settings: MediaLoudnessSettings
) -> list[str]:
    loudnorm = (
        f"loudnorm=I={settings.target_i}:LRA={settings.loudness_range}"
        f":TP={settings.true_peak_db}:dual_mono=false:print_format=json"
    )
    return [
        ffmpeg_str,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "info",
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        concat_name,
        "-af",
        loudnorm,
        "-f",
        "null",
        "-",
    ]


def _parse_loudnorm_measurement(stderr: str) -> dict[str, float]:
    start = stderr.find("{")
    end = stderr.rfind("}")
    if start == -1 or end <= start:
        raise MediaEncodeError("loudnorm measurement failed", error_code="command_failed")
    try:
        decoded = cast("object", json.loads(stderr[start : end + 1]))
    except ValueError as exc:
        raise MediaEncodeError(
            "loudnorm measurement failed", error_code="command_failed"
        ) from exc
    if not isinstance(decoded, dict):
        raise MediaEncodeError("loudnorm measurement failed", error_code="command_failed")

    payload: dict[str, object] = {}
    for raw_key, raw_value in cast("dict[object, object]", decoded).items():
        if isinstance(raw_key, str):
            payload[raw_key] = raw_value

    measured: dict[str, float] = {}
    for key in _MEASUREMENT_KEYS:
        raw = payload.get(key)
        if raw is None or isinstance(raw, bool) or not isinstance(raw, (int, float, str)):
            raise MediaEncodeError("loudnorm measurement failed", error_code="command_failed")
        try:
            number = float(raw)
        except ValueError as exc:
            raise MediaEncodeError(
                "loudnorm measurement failed", error_code="command_failed"
            ) from exc
        if not math.isfinite(number):
            raise MediaEncodeError("loudnorm measurement failed", error_code="command_failed")
        measured[key] = number
    return measured


def _loudness_filter_args(
    settings: MediaLoudnessSettings, measured: dict[str, float]
) -> list[str]:
    loudnorm = (
        f"loudnorm=I={settings.target_i}:LRA={settings.loudness_range}"
        f":TP={settings.true_peak_db}:measured_I={measured['input_i']}"
        f":measured_LRA={measured['input_lra']}:measured_TP={measured['input_tp']}"
        f":measured_thresh={measured['input_thresh']}:offset={measured['target_offset']}"
        f":linear=true:dual_mono=false"
    )
    return ["-af", loudnorm]


async def _measure_loudness(
    runner: MediaProcessRunner,
    ffmpeg_str: str,
    concat_name: str,
    settings: MediaLoudnessSettings,
    *,
    cwd: Path,
    cancel_event: asyncio.Event | None,
) -> list[str]:
    probe_argv = _loudness_probe_argv(ffmpeg_str, concat_name, settings)
    output = await runner.run_capture(probe_argv, cwd=cwd, cancel_event=cancel_event)
    if output.return_code != 0:
        raise MediaEncodeError("loudnorm measurement failed", error_code="command_failed")
    return _loudness_filter_args(settings, _parse_loudnorm_measurement(output.stderr))


async def encode(
    manifest: MediaExportManifest,
    tools: MediaToolchain,
    runner: MediaProcessRunner,
    *,
    app_home: Path | None = None,
    cancel_event: asyncio.Event | None = None,
    on_progress: Callable[[dict[str, object]], None] | None = None,
) -> MediaExportResult:
    """Encode an audiobook export manifest into M4B or per-chapter MP3s inside the request stage."""
    if not tools.available or tools.ffmpeg_path is None:
        raise MediaCodecUnavailableError("managed ffmpeg tool is unavailable")

    if manifest.profile == "m4b" and not tools.supports_m4b:
        raise MediaCodecUnavailableError("AAC encoder is unavailable in managed ffmpeg")
    if manifest.profile == "chapter_mp3" and not tools.supports_mp3:
        raise MediaCodecUnavailableError("libmp3lame encoder is unavailable in managed ffmpeg")
    if manifest.loudness is not None and not tools.has_loudnorm:
        raise MediaCodecUnavailableError("loudnorm filter is unavailable in managed ffmpeg")

    raw_home = app_home or manifest.app_home
    if raw_home is None:
        raise MediaEncodeError(
            "app_home is required for media export",
            error_code="invalid_request",
        )
    home_path = Path(raw_home)
    resolved_home: Path = await asyncio.to_thread(home_path.resolve)
    audiobooks_root = resolved_home / "audiobooks"
    request_dir = audiobooks_root / "exports" / str(manifest.request_id)
    stage_dir = request_dir / "stage"
    norm_dir = stage_dir / "normalized"

    if stage_dir.exists():
        shutil.rmtree(stage_dir, ignore_errors=True)

    try:
        norm_dir.mkdir(parents=True, exist_ok=True)
        ffmpeg_str = str(tools.ffmpeg_path)

        # Step 1: Normalize each fragment to 48 kHz mono PCM16 WAV and count real frames
        chapter_norm_files: list[tuple[int, str, list[tuple[str, int]]]] = []
        total_frames = 0
        frag_counter = 0

        for chapter in manifest.chapters:
            norm_entries: list[tuple[str, int]] = []
            for fragment in chapter.fragments:
                if cancel_event is not None and cancel_event.is_set():
                    raise MediaEncodeError("media export was cancelled", error_code="cancelled")

                input_wav = audiobooks_root / fragment.relative_path
                norm_rel_name = f"normalized/frag_{frag_counter:06d}.wav"
                norm_abs_path = stage_dir / norm_rel_name
                frag_counter += 1

                norm_argv = [
                    ffmpeg_str,
                    "-nostdin",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-i",
                    str(input_wav),
                    "-vn",
                    "-ar",
                    str(SAMPLE_RATE_HZ),
                    "-ac",
                    str(CHANNELS),
                    "-c:a",
                    "pcm_s16le",
                    "-progress",
                    "pipe:1",
                    str(norm_abs_path),
                ]
                await runner.run(
                    norm_argv,
                    cwd=stage_dir,
                    cancel_event=cancel_event,
                    on_progress=on_progress,
                )
                actual_frames = read_wav_pcm16_frames(norm_abs_path)
                norm_entries.append((norm_rel_name, actual_frames))
                total_frames += actual_frames

            chapter_norm_files.append((chapter.ordinal, chapter.title, norm_entries))

        relative_outputs: list[str] = []
        output_sha256s: dict[str, str] = {}

        if manifest.profile == "m4b":
            # Build safe concat list and FFmetadata with 1/48000 frame timebase
            # and disable_chpl for 300+ chapter support
            concat_lines: list[str] = ["ffconcat version 1.0"]
            ffmeta_lines: list[str] = [
                ";FFMETADATA1",
                f"title={escape_ffmetadata(manifest.book_title)}",
            ]
            if manifest.author:
                ffmeta_lines.append(f"artist={escape_ffmetadata(manifest.author)}")
                ffmeta_lines.append(f"album_artist={escape_ffmetadata(manifest.author)}")

            cursor_frame = 0
            for _, chapter_title, norm_entries in chapter_norm_files:
                chapter_start = cursor_frame
                for norm_rel_name, frame_count in norm_entries:
                    concat_lines.append(f"file '{norm_rel_name}'")
                    cursor_frame += frame_count
                chapter_end = max(chapter_start + 1, cursor_frame)
                ffmeta_lines.extend(
                    [
                        "[CHAPTER]",
                        f"TIMEBASE=1/{SAMPLE_RATE_HZ}",
                        f"START={chapter_start}",
                        f"END={chapter_end}",
                        f"title={escape_ffmetadata(chapter_title)}",
                    ]
                )

            concat_path = stage_dir / "concat.txt"
            ffmeta_path = stage_dir / "chapters.ffmeta"
            concat_path.write_text("\n".join(concat_lines) + "\n", encoding="utf-8")
            ffmeta_path.write_text("\n".join(ffmeta_lines) + "\n", encoding="utf-8")

            m4b_loudness_af: list[str] = []
            if manifest.loudness is not None:
                m4b_loudness_af = await _measure_loudness(
                    runner,
                    ffmpeg_str,
                    "concat.txt",
                    manifest.loudness,
                    cwd=stage_dir,
                    cancel_event=cancel_event,
                )

            m4b_rel = f"exports/{manifest.request_id}/stage/book.m4b"
            m4b_abs = stage_dir / "book.m4b"
            # A cover is a third input (index 2) mapped as an attached picture; the
            # no-cover argv stays byte-for-byte identical (empty insertions, `-vn`).
            cover_input: list[str] = []
            if manifest.cover is not None:
                cover_input = ["-i", str(audiobooks_root / manifest.cover.relative_path)]
            cover_map = (
                ["-map", "2:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
                if manifest.cover is not None
                else ["-vn"]
            )
            m4b_argv = [
                ffmpeg_str,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                "concat.txt",
                "-f",
                "ffmetadata",
                "-i",
                "chapters.ffmeta",
                *cover_input,
                "-map",
                "0:a:0",
                "-map_metadata",
                "1",
                "-map_chapters",
                "1",
                *cover_map,
                *m4b_loudness_af,
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-ar",
                str(SAMPLE_RATE_HZ),
                "-ac",
                str(CHANNELS),
                "-movflags",
                "+faststart+disable_chpl",
                "-progress",
                "pipe:1",
                "book.m4b",
            ]
            await runner.run(
                m4b_argv,
                cwd=stage_dir,
                cancel_event=cancel_event,
                on_progress=on_progress,
            )
            if not m4b_abs.is_file() or m4b_abs.stat().st_size == 0:
                raise MediaEncodeError(
                    "encoded M4B output is missing or empty",
                    error_code="integrity_mismatch",
                )
            relative_outputs.append(m4b_rel)
            output_sha256s[m4b_rel] = sha256_file_chunked(m4b_abs)
        else:
            chapters_out_dir = stage_dir / "chapters"
            chapters_out_dir.mkdir(parents=True, exist_ok=True)

            mp3_loudness_af: list[str] = []
            if manifest.loudness is not None:
                probe_lines = ["ffconcat version 1.0"]
                for _, _, norm_entries in chapter_norm_files:
                    for norm_rel_name, _ in norm_entries:
                        probe_lines.append(f"file '{norm_rel_name}'")
                (stage_dir / "loudness_probe.txt").write_text(
                    "\n".join(probe_lines) + "\n", encoding="utf-8"
                )
                mp3_loudness_af = await _measure_loudness(
                    runner,
                    ffmpeg_str,
                    "loudness_probe.txt",
                    manifest.loudness,
                    cwd=stage_dir,
                    cancel_event=cancel_event,
                )

            for idx, (ordinal, chapter_title, norm_entries) in enumerate(chapter_norm_files):
                concat_name = f"concat_ch_{idx:04d}.txt"
                concat_path = stage_dir / concat_name
                concat_lines = ["ffconcat version 1.0"] + [
                    f"file '{norm_rel_name}'" for norm_rel_name, _ in norm_entries
                ]
                concat_path.write_text("\n".join(concat_lines) + "\n", encoding="utf-8")

                mp3_filename = f"chapters/chapter_{ordinal + 1:04d}.mp3"
                mp3_abs = stage_dir / mp3_filename
                mp3_rel = f"exports/{manifest.request_id}/stage/{mp3_filename}"
                mp3_argv = [
                    ffmpeg_str,
                    "-nostdin",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-f",
                    "concat",
                    "-safe",
                    "0",
                    "-i",
                    concat_name,
                    "-vn",
                    "-metadata",
                    f"title={chapter_title}",
                    "-metadata",
                    f"album={manifest.book_title}",
                    "-metadata",
                    f"track={ordinal + 1}/{len(chapter_norm_files)}",
                    *mp3_loudness_af,
                    "-c:a",
                    "libmp3lame",
                    "-b:a",
                    "128k",
                    "-ar",
                    str(SAMPLE_RATE_HZ),
                    "-ac",
                    str(CHANNELS),
                    "-progress",
                    "pipe:1",
                    mp3_filename,
                ]
                await runner.run(
                    mp3_argv,
                    cwd=stage_dir,
                    cancel_event=cancel_event,
                    on_progress=on_progress,
                )
                if not mp3_abs.is_file() or mp3_abs.stat().st_size == 0:
                    raise MediaEncodeError(
                        "encoded MP3 chapter output is missing or empty",
                        error_code="integrity_mismatch",
                    )
                relative_outputs.append(mp3_rel)
                output_sha256s[mp3_rel] = sha256_file_chunked(mp3_abs)

        # Clean intermediate normalized WAVs to save disk space while
        # keeping final staged deliverables
        shutil.rmtree(norm_dir, ignore_errors=True)

        result = MediaExportResult(
            request_id=manifest.request_id,
            profile=manifest.profile,
            relative_outputs=tuple(relative_outputs),
            total_frame_count=total_frames,
            sample_rate=SAMPLE_RATE_HZ,
            chapter_count=len(manifest.chapters),
            output_sha256s=output_sha256s,
        )
        result_tmp = request_dir / "result.json.tmp"
        result_final = request_dir / "result.json"
        result_tmp.write_text(json.dumps(result.to_dict(), sort_keys=True), encoding="utf-8")
        result_tmp.replace(result_final)
        return result
    except OSError as exc:
        shutil.rmtree(stage_dir, ignore_errors=True)
        if exc.errno == errno.ENOSPC:
            raise MediaEncodeError(
                "insufficient disk space during media export",
                error_code="insufficient_disk_space",
            ) from exc
        raise MediaEncodeError(
            "filesystem error during media export",
            error_code="command_failed",
        ) from exc
    except BaseException:
        shutil.rmtree(stage_dir, ignore_errors=True)
        raise
