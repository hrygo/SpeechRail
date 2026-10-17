from __future__ import annotations

import asyncio
import errno
import hashlib
import struct
from collections.abc import Callable, Sequence
from pathlib import Path
from uuid import uuid4

import pytest

from speechrail.media.encoder import (
    MediaCodecUnavailableError,
    MediaEncodeError,
    MediaProcessOutput,
    MediaToolchain,
    encode,
)
from speechrail.media.manifest import (
    MediaChapterEntry,
    MediaExportManifest,
    MediaFragmentEntry,
    MediaLoudnessSettings,
)

DEFAULT_LOUDNORM_STDERR = (
    "[\nloudnorm @ 0x1] Parsed_loudnorm_0\n"
    "{\n"
    '    "input_i" : "-23.40",\n'
    '    "input_tp" : "-3.10",\n'
    '    "input_lra" : "7.20",\n'
    '    "input_thresh" : "-34.00",\n'
    '    "output_i" : "-18.00",\n'
    '    "output_tp" : "-1.50",\n'
    '    "output_lra" : "7.00",\n'
    '    "output_thresh" : "-28.50",\n'
    '    "normalization_type" : "dynamic",\n'
    '    "target_offset" : "-0.50"\n'
    "}\n"
)


def _make_wav_bytes(frame_count: int = 4800) -> bytes:
    pcm_bytes = b"\x10\x00" * frame_count
    riff_size = 36 + len(pcm_bytes)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        riff_size,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        48000,
        96000,
        2,
        16,
        b"data",
        len(pcm_bytes),
    )
    return header + pcm_bytes


class FakeMediaRunner:
    def __init__(self, *, frame_count_per_norm: int = 4800) -> None:
        self.recorded_argv: list[list[str]] = []
        self.recorded_capture_argv: list[list[str]] = []
        self.frame_count_per_norm = frame_count_per_norm
        self.captured_ffmetadata: str = ""
        self.captured_concat: str = ""
        self.raise_on_final_encode: BaseException | None = None
        self.capture_output: MediaProcessOutput | None = None
        self.capture_count = 0

    async def run_capture(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
    ) -> MediaProcessOutput:
        args = list(argv)
        self.recorded_argv.append(args)
        self.recorded_capture_argv.append(args)
        self.capture_count += 1
        if self.capture_output is not None:
            return self.capture_output
        return MediaProcessOutput(return_code=0, stdout="", stderr=DEFAULT_LOUDNORM_STDERR)

    async def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        cancel_event: asyncio.Event | None = None,
        on_progress: Callable[[dict[str, object]], None] | None = None,
        no_progress_timeout: float = 90.0,
        total_timeout: float = 7200.0,
    ) -> int:
        args = list(argv)
        self.recorded_argv.append(args)
        out_target = Path(args[-1])
        if not out_target.is_absolute():
            out_target = cwd / out_target
        out_target.parent.mkdir(parents=True, exist_ok=True)

        if out_target.suffix == ".wav":
            out_target.write_bytes(_make_wav_bytes(self.frame_count_per_norm))
        else:
            ffmeta_file = cwd / "chapters.ffmeta"
            concat_file = cwd / "concat.txt"
            if ffmeta_file.is_file():
                self.captured_ffmetadata = ffmeta_file.read_text(encoding="utf-8")
            if concat_file.is_file():
                self.captured_concat = concat_file.read_text(encoding="utf-8")
            if self.raise_on_final_encode is not None:
                raise self.raise_on_final_encode
            out_target.write_bytes(b"FAKE_ENCODED_MEDIA_PAYLOAD")
        if on_progress is not None:
            on_progress({"progress": "end"})
        return 0


def test_encode_300_chapters_uses_chapter_track_and_counts_real_frames(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    fake_ffmpeg = tmp_path / "ffmpeg"
    fake_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    tools = MediaToolchain(
        ffmpeg_path=fake_ffmpeg,
        encoders=frozenset({"aac", "libmp3lame", "pcm_s16le"}),
    )

    wav_bytes = _make_wav_bytes(2400)
    wav_sha = hashlib.sha256(wav_bytes).hexdigest()
    cid = uuid4()
    rel_path = f"books/{book_id}/audio/{cid}.wav"
    (audio_dir / f"{cid}.wav").write_bytes(wav_bytes)

    chapters: list[MediaChapterEntry] = []
    for idx in range(300):
        chapters.append(
            MediaChapterEntry(
                chapter_id=uuid4(),
                ordinal=idx,
                title=f"第 {idx + 1} 章 章节=测试;特殊#标题",
                fragments=(
                    MediaFragmentEntry(
                        fragment_id=uuid4(),
                        candidate_id=cid,
                        relative_path=rel_path,
                        file_sha256=wav_sha,
                        pcm_sha256="",
                        frame_count=2400,
                        sample_rate=48000,
                    ),
                ),
            )
        )

    manifest = MediaExportManifest(
        schema_version="audiobook_media_export_v1",
        request_id=request_id,
        book_id=book_id,
        source_id=uuid4(),
        production_revision_id=uuid4(),
        profile="m4b",
        book_title="三百章长篇测试",
        author="测试作者",
        chapters=tuple(chapters),
        app_home=app_home,
    )

    runner = FakeMediaRunner(frame_count_per_norm=4800)
    result = asyncio.run(encode(manifest, tools, runner, app_home=app_home))

    assert result.chapter_count == 300
    assert result.total_frame_count == 300 * 4800
    assert result.sample_rate == 48000
    assert len(result.relative_outputs) == 1
    final_argv = runner.recorded_argv[-1]
    assert "+faststart+disable_chpl" in final_argv
    assert "-map_chapters" in final_argv
    assert runner.captured_ffmetadata.count("[CHAPTER]") == 300
    assert "TIMEBASE=1/48000" in runner.captured_ffmetadata
    assert "START=0" in runner.captured_ffmetadata
    assert "END=4800" in runner.captured_ffmetadata


def test_cancel_timeout_or_disk_full_cleans_stage_and_keeps_original(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    fake_ffmpeg = tmp_path / "ffmpeg"
    fake_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    tools = MediaToolchain(ffmpeg_path=fake_ffmpeg, encoders=frozenset({"aac", "libmp3lame"}))

    wav_bytes = _make_wav_bytes(4800)
    wav_sha = hashlib.sha256(wav_bytes).hexdigest()
    cid = uuid4()
    orig_wav = audio_dir / f"{cid}.wav"
    orig_wav.write_bytes(wav_bytes)

    manifest = MediaExportManifest(
        schema_version="audiobook_media_export_v1",
        request_id=request_id,
        book_id=book_id,
        source_id=uuid4(),
        production_revision_id=uuid4(),
        profile="m4b",
        book_title="磁盘满与取消保护",
        author=None,
        chapters=(
            MediaChapterEntry(
                chapter_id=uuid4(),
                ordinal=0,
                title="第一章",
                fragments=(
                    MediaFragmentEntry(
                        fragment_id=uuid4(),
                        candidate_id=cid,
                        relative_path=f"books/{book_id}/audio/{cid}.wav",
                        file_sha256=wav_sha,
                        pcm_sha256="",
                        frame_count=4800,
                        sample_rate=48000,
                    ),
                ),
            ),
        ),
        app_home=app_home,
    )

    runner = FakeMediaRunner()
    runner.raise_on_final_encode = OSError(errno.ENOSPC, "No space left on device")

    with pytest.raises(MediaEncodeError) as exc_info:
        asyncio.run(encode(manifest, tools, runner, app_home=app_home))
    assert exc_info.value.error_code == "insufficient_disk_space"
    assert orig_wav.read_bytes() == wav_bytes
    stage_dir = app_home / "audiobooks" / "exports" / str(request_id) / "stage"
    assert not stage_dir.exists()


def test_missing_codec_never_downloads_tool(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    fake_ffmpeg = tmp_path / "ffmpeg"
    fake_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    tools_without_aac = MediaToolchain(ffmpeg_path=fake_ffmpeg, encoders=frozenset({"pcm_s16le"}))

    manifest = MediaExportManifest(
        schema_version="audiobook_media_export_v1",
        request_id=uuid4(),
        book_id=uuid4(),
        source_id=uuid4(),
        production_revision_id=uuid4(),
        profile="m4b",
        book_title="缺编码器测试",
        author=None,
        chapters=(),
        app_home=app_home,
    )
    runner = FakeMediaRunner()
    with pytest.raises(MediaCodecUnavailableError) as exc_info:
        asyncio.run(encode(manifest, tools_without_aac, runner, app_home=app_home))
    assert exc_info.value.error_code == "codec_unavailable"
    assert runner.recorded_argv == []


def _seed_book(
    tmp_path: Path,
    *,
    chapters: int = 1,
    profile: str = "m4b",
    loudness: MediaLoudnessSettings | None = None,
    toolchain_has_loudnorm: bool | None = None,
) -> tuple[Path, MediaExportManifest, MediaToolchain]:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    fake_ffmpeg = tmp_path / "ffmpeg"
    fake_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    has_loudnorm = (
        toolchain_has_loudnorm
        if toolchain_has_loudnorm is not None
        else loudness is not None
    )
    tools = MediaToolchain(
        ffmpeg_path=fake_ffmpeg,
        encoders=frozenset({"aac", "libmp3lame", "pcm_s16le"}),
        has_loudnorm=has_loudnorm,
    )

    wav_bytes = _make_wav_bytes(2400)
    wav_sha = hashlib.sha256(wav_bytes).hexdigest()
    cid = uuid4()
    (audio_dir / f"{cid}.wav").write_bytes(wav_bytes)

    chapter_entries: list[MediaChapterEntry] = []
    for idx in range(chapters):
        chapter_entries.append(
            MediaChapterEntry(
                chapter_id=uuid4(),
                ordinal=idx,
                title=f"第 {idx + 1} 章",
                fragments=(
                    MediaFragmentEntry(
                        fragment_id=uuid4(),
                        candidate_id=cid,
                        relative_path=f"books/{book_id}/audio/{cid}.wav",
                        file_sha256=wav_sha,
                        pcm_sha256="",
                        frame_count=2400,
                        sample_rate=48000,
                    ),
                ),
            )
        )

    manifest = MediaExportManifest(
        schema_version="audiobook_media_export_v2",
        request_id=request_id,
        book_id=book_id,
        source_id=uuid4(),
        production_revision_id=uuid4(),
        profile=profile,
        book_title="响度测试",
        author="林远",
        chapters=tuple(chapter_entries),
        app_home=app_home,
        loudness=loudness,
    )
    return app_home, manifest, tools


def _af_value(argv: Sequence[str]) -> str:
    index = argv.index("-af")
    return argv[index + 1]


def test_encode_m4b_off_argv_is_golden_and_never_captures(tmp_path: Path) -> None:
    app_home, manifest, tools = _seed_book(tmp_path, profile="m4b")
    runner = FakeMediaRunner(frame_count_per_norm=4800)

    asyncio.run(encode(manifest, tools, runner, app_home=app_home))

    final_argv = runner.recorded_argv[-1]
    expected = [
        str(tools.ffmpeg_path),
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
        "-map",
        "0:a:0",
        "-map_metadata",
        "1",
        "-map_chapters",
        "1",
        "-vn",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "1",
        "-movflags",
        "+faststart+disable_chpl",
        "-progress",
        "pipe:1",
        "book.m4b",
    ]
    assert final_argv == expected
    assert "-af" not in final_argv
    assert runner.capture_count == 0
    assert runner.recorded_capture_argv == []


def test_encode_mp3_off_argv_is_golden_and_never_captures(tmp_path: Path) -> None:
    app_home, manifest, tools = _seed_book(tmp_path, profile="chapter_mp3")
    runner = FakeMediaRunner(frame_count_per_norm=4800)

    asyncio.run(encode(manifest, tools, runner, app_home=app_home))

    final_argv = runner.recorded_argv[-1]
    expected = [
        str(tools.ffmpeg_path),
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
        "concat_ch_0000.txt",
        "-vn",
        "-metadata",
        "title=第 1 章",
        "-metadata",
        "album=响度测试",
        "-metadata",
        "track=1/1",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "1",
        "-progress",
        "pipe:1",
        "chapters/chapter_0001.mp3",
    ]
    assert final_argv == expected
    assert "-af" not in final_argv
    assert runner.capture_count == 0
    assert runner.recorded_capture_argv == []


def test_encode_m4b_loudness_probes_whole_book_then_applies_linear_filter(
    tmp_path: Path,
) -> None:
    settings = MediaLoudnessSettings(
        unit="lufs", target_i=-18.0, true_peak_db=-1.5, loudness_range=11.0
    )
    app_home, manifest, tools = _seed_book(tmp_path, profile="m4b", loudness=settings)
    runner = FakeMediaRunner(frame_count_per_norm=4800)

    asyncio.run(encode(manifest, tools, runner, app_home=app_home))

    assert runner.capture_count == 1
    probe_argv = runner.recorded_capture_argv[0]
    assert probe_argv[-3:] == ["-f", "null", "-"]
    assert probe_argv[probe_argv.index("-i") + 1] == "concat.txt"
    probe_filter = _af_value(probe_argv)
    assert "dual_mono=false" in probe_filter
    assert "print_format=json" in probe_filter
    assert "measured_I=" not in probe_filter

    final_argv = runner.recorded_argv[-1]
    assert final_argv.count("-af") == 1
    applied_filter = _af_value(final_argv)
    assert "measured_I=" in applied_filter
    assert "linear=true" in applied_filter
    assert "dual_mono=false" in applied_filter
    assert final_argv[final_argv.index("-af") + 2 :][:1] == ["-c:a"]
    assert final_argv[final_argv.index("-ar") + 1] == "48000"
    assert final_argv[final_argv.index("-ac") + 1] == "1"


def test_encode_mp3_loudness_measures_once_and_reuses_identical_filter_per_chapter(
    tmp_path: Path,
) -> None:
    settings = MediaLoudnessSettings(
        unit="lufs", target_i=-19.0, true_peak_db=-2.0, loudness_range=9.0
    )
    app_home, manifest, tools = _seed_book(
        tmp_path, chapters=2, profile="chapter_mp3", loudness=settings
    )
    runner = FakeMediaRunner(frame_count_per_norm=4800)

    asyncio.run(encode(manifest, tools, runner, app_home=app_home))

    assert runner.capture_count == 1
    probe_argv = runner.recorded_capture_argv[0]
    assert probe_argv[probe_argv.index("-i") + 1] == "loudness_probe.txt"

    chapter_argvs = [argv for argv in runner.recorded_argv if "libmp3lame" in argv]
    assert len(chapter_argvs) == 2
    filters = {_af_value(argv) for argv in chapter_argvs}
    assert len(filters) == 1

    stage_dir = app_home / "audiobooks" / "exports" / str(manifest.request_id) / "stage"
    probe_content = (stage_dir / "loudness_probe.txt").read_text(encoding="utf-8")
    assert probe_content.startswith("ffconcat version 1.0\n")
    assert probe_content.count("file '") == 2


def test_encode_loudness_probe_failure_fails_closed(tmp_path: Path) -> None:
    settings = MediaLoudnessSettings(
        unit="lufs", target_i=-18.0, true_peak_db=-1.5, loudness_range=11.0
    )
    app_home, manifest, tools = _seed_book(tmp_path, profile="m4b", loudness=settings)

    nonzero = FakeMediaRunner(frame_count_per_norm=4800)
    nonzero.capture_output = MediaProcessOutput(return_code=1, stdout="", stderr="boom")
    with pytest.raises(MediaEncodeError) as exc_info:
        asyncio.run(encode(manifest, tools, nonzero, app_home=app_home))
    assert exc_info.value.error_code == "command_failed"

    unparseable = FakeMediaRunner(frame_count_per_norm=4800)
    unparseable.capture_output = MediaProcessOutput(
        return_code=0, stdout="", stderr="not json at all"
    )
    with pytest.raises(MediaEncodeError) as exc_info:
        asyncio.run(encode(manifest, tools, unparseable, app_home=app_home))
    assert exc_info.value.error_code == "command_failed"


def test_encode_loudness_nonfinite_measurement_rejected(tmp_path: Path) -> None:
    settings = MediaLoudnessSettings(
        unit="lufs", target_i=-18.0, true_peak_db=-1.5, loudness_range=11.0
    )
    app_home, manifest, tools = _seed_book(tmp_path, profile="m4b", loudness=settings)
    runner = FakeMediaRunner(frame_count_per_norm=4800)
    runner.capture_output = MediaProcessOutput(
        return_code=0,
        stdout="",
        stderr=(
            '{\n"input_i" : "-inf",\n"input_tp" : "-3.10",\n'
            '"input_lra" : "7.20",\n"input_thresh" : "-34.00",\n'
            '"target_offset" : "-0.50"\n}\n'
        ),
    )

    with pytest.raises(MediaEncodeError) as exc_info:
        asyncio.run(encode(manifest, tools, runner, app_home=app_home))
    assert exc_info.value.error_code == "command_failed"


def test_encode_loudness_requires_toolchain_support(tmp_path: Path) -> None:
    settings = MediaLoudnessSettings(
        unit="lufs", target_i=-18.0, true_peak_db=-1.5, loudness_range=11.0
    )
    app_home, manifest, tools = _seed_book(
        tmp_path,
        profile="m4b",
        loudness=settings,
        toolchain_has_loudnorm=False,
    )
    runner = FakeMediaRunner(frame_count_per_norm=4800)

    with pytest.raises(MediaCodecUnavailableError) as exc_info:
        asyncio.run(encode(manifest, tools, runner, app_home=app_home))
    assert exc_info.value.error_code == "codec_unavailable"
    assert runner.recorded_argv == []
    assert runner.capture_count == 0
