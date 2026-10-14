from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path
from uuid import uuid4

from speechrail.cli import main
from speechrail.media.commands import run_media_capabilities, run_media_export
from speechrail.media.encoder import MediaToolchain
from test_media_encoder import FakeMediaRunner


def _make_wav_bytes(frame_count: int = 4800) -> bytes:
    pcm_bytes = b"\x05\x00" * frame_count
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


def test_media_capabilities_and_export_cli_envelope(
    tmp_path: Path, capsys: object
) -> None:
    app_home = tmp_path / "app_home"
    fake_ffmpeg = tmp_path / "ffmpeg"
    fake_ffmpeg.write_text("#!/bin/sh\n", encoding="utf-8")
    tools = MediaToolchain(ffmpeg_path=fake_ffmpeg, encoders=frozenset({"aac", "libmp3lame"}))

    cap_payload = run_media_capabilities(app_home, toolchain=tools)
    assert cap_payload["command"] == "media.capabilities"
    assert cap_payload["supports_m4b"] is True
    assert cap_payload["supports_mp3"] is True

    book_id = uuid4()
    request_id = uuid4()
    cid = uuid4()
    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    wav_bytes = _make_wav_bytes(4800)
    (audio_dir / f"{cid}.wav").write_bytes(wav_bytes)

    export_dir = app_home / "audiobooks" / "exports" / str(request_id)
    export_dir.mkdir(parents=True, exist_ok=True)
    manifest_payload = {
        "schema_version": "audiobook_media_export_v1",
        "request_id": str(request_id),
        "book_id": str(book_id),
        "source_id": str(uuid4()),
        "production_revision_id": str(uuid4()),
        "profile": "chapter_mp3",
        "book_title": "分章导出测试",
        "author": "林远",
        "chapters": [
            {
                "chapter_id": str(uuid4()),
                "ordinal": 0,
                "title": "第一章",
                "fragments": [
                    {
                        "fragment_id": str(uuid4()),
                        "candidate_id": str(cid),
                        "relative_path": f"books/{book_id}/audio/{cid}.wav",
                        "file_sha256": hashlib.sha256(wav_bytes).hexdigest(),
                        "pcm_sha256": "",
                        "frame_count": 4800,
                        "sample_rate": 48000,
                    }
                ],
            }
        ],
    }
    (export_dir / "request.json").write_text(json.dumps(manifest_payload), encoding="utf-8")

    runner = FakeMediaRunner(frame_count_per_norm=4800)
    export_payload = run_media_export(app_home, request_id, toolchain=tools, runner=runner)
    assert export_payload["status"] == "committed"
    assert export_payload["profile"] == "chapter_mp3"
    assert export_payload["total_frame_count"] == 4800
    assert (export_dir / "result.json").is_file()

    # Verify CLI entrypoint rejects invalid UUID with machine JSON envelope
    exit_code = main(["media", "export", "--request-id", "not-a-uuid", "--app-home", str(app_home), "--json"])
    assert exit_code == 1
