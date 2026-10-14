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
    MediaToolchain,
    encode,
)
from speechrail.media.manifest import (
    MediaChapterEntry,
    MediaExportManifest,
    MediaFragmentEntry,
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
        self.frame_count_per_norm = frame_count_per_norm
        self.captured_ffmetadata: str = ""
        self.captured_concat: str = ""
        self.raise_on_final_encode: BaseException | None = None

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
