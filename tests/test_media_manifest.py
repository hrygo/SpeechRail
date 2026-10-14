from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path
from uuid import uuid4

import pytest

from speechrail.media.manifest import MediaManifestError, load_manifest


def _make_wav_bytes(frame_count: int = 4800) -> bytes:
    pcm_bytes = b"\x00\x01" * frame_count
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


def _write_manifest(app_home: Path, request_id: str, payload: dict[str, object]) -> Path:
    export_dir = app_home / "audiobooks" / "exports" / request_id
    export_dir.mkdir(parents=True, exist_ok=True)
    req_file = export_dir / "request.json"
    req_file.write_text(json.dumps(payload), encoding="utf-8")
    return req_file


def test_manifest_rejects_traversal_symlink_and_unowned_inputs(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    other_book_id = uuid4()
    request_id = uuid4()
    chapter_id = uuid4()
    fragment_id = uuid4()
    candidate_id = uuid4()

    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    wav_bytes = _make_wav_bytes()
    wav_sha = hashlib.sha256(wav_bytes).hexdigest()
    valid_wav = audio_dir / f"{candidate_id}.wav"
    valid_wav.write_bytes(wav_bytes)

    def make_payload(relative_path: str, sha: str = wav_sha) -> dict[str, object]:
        return {
            "schema_version": "audiobook_media_export_v1",
            "request_id": str(request_id),
            "book_id": str(book_id),
            "source_id": str(uuid4()),
            "production_revision_id": str(uuid4()),
            "profile": "m4b",
            "book_title": "雾港夜航",
            "author": "林远",
            "chapters": [
                {
                    "chapter_id": str(chapter_id),
                    "ordinal": 0,
                    "title": "第一章",
                    "fragments": [
                        {
                            "fragment_id": str(fragment_id),
                            "candidate_id": str(candidate_id),
                            "relative_path": relative_path,
                            "file_sha256": sha,
                            "pcm_sha256": "",
                            "frame_count": 4800,
                            "sample_rate": 48000,
                        }
                    ],
                }
            ],
        }

    # 1. Valid owned input succeeds
    _write_manifest(
        app_home,
        str(request_id),
        make_payload(f"books/{book_id}/audio/{candidate_id}.wav"),
    )
    loaded = load_manifest(app_home, request_id)
    assert loaded.book_id == book_id
    assert len(loaded.chapters) == 1

    # 2. Path traversal rejected
    _write_manifest(
        app_home,
        str(request_id),
        make_payload(f"books/{book_id}/audio/../../other.wav"),
    )
    with pytest.raises(MediaManifestError):
        load_manifest(app_home, request_id)

    # 3. Unowned book directory rejected
    other_audio_dir = app_home / "audiobooks" / "books" / str(other_book_id) / "audio"
    other_audio_dir.mkdir(parents=True, exist_ok=True)
    (other_audio_dir / f"{candidate_id}.wav").write_bytes(wav_bytes)
    _write_manifest(
        app_home,
        str(request_id),
        make_payload(f"books/{other_book_id}/audio/{candidate_id}.wav"),
    )
    with pytest.raises(MediaManifestError):
        load_manifest(app_home, request_id)

    # 4. Symlink input rejected
    symlink_wav = audio_dir / "symlink.wav"
    symlink_wav.symlink_to(valid_wav)
    _write_manifest(
        app_home,
        str(request_id),
        make_payload(f"books/{book_id}/audio/symlink.wav"),
    )
    with pytest.raises(MediaManifestError):
        load_manifest(app_home, request_id)

    # 5. Tampered SHA-256 rejected
    _write_manifest(
        app_home,
        str(request_id),
        make_payload(f"books/{book_id}/audio/{candidate_id}.wav", sha="0" * 64),
    )
    with pytest.raises(MediaManifestError) as exc_info:
        load_manifest(app_home, request_id)
    assert exc_info.value.error_code == "integrity_mismatch"
