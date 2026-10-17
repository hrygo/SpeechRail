from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path
from uuid import UUID, uuid4

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


def _seed_fragment(app_home: Path, book_id: UUID) -> tuple[str, str, str]:
    candidate_id = uuid4()
    audio_dir = app_home / "audiobooks" / "books" / str(book_id) / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    wav_bytes = _make_wav_bytes()
    wav_sha = hashlib.sha256(wav_bytes).hexdigest()
    (audio_dir / f"{candidate_id}.wav").write_bytes(wav_bytes)
    return str(candidate_id), f"books/{book_id}/audio/{candidate_id}.wav", wav_sha


def _seed_cover(app_home: Path, book_id: UUID) -> tuple[str, str]:
    cover_dir = app_home / "audiobooks" / "books" / str(book_id) / "cover"
    cover_dir.mkdir(parents=True, exist_ok=True)
    cover_bytes = b"\x89PNG\r\n\x1a\n" + b"speechrail-cover"
    cover_sha = hashlib.sha256(cover_bytes).hexdigest()
    (cover_dir / "cover.png").write_bytes(cover_bytes)
    return f"books/{book_id}/cover/cover.png", cover_sha


def _manifest_payload(
    *,
    request_id: UUID,
    book_id: UUID,
    candidate_id: str,
    fragment_path: str,
    fragment_sha: str,
    schema_version: str = "audiobook_media_export_v2",
    profile: str = "m4b",
) -> dict[str, object]:
    return {
        "schema_version": schema_version,
        "request_id": str(request_id),
        "book_id": str(book_id),
        "source_id": str(uuid4()),
        "production_revision_id": str(uuid4()),
        "profile": profile,
        "book_title": "雾港夜航",
        "author": "林远",
        "chapters": [
            {
                "chapter_id": str(uuid4()),
                "ordinal": 0,
                "title": "第一章",
                "fragments": [
                    {
                        "fragment_id": str(uuid4()),
                        "candidate_id": candidate_id,
                        "relative_path": fragment_path,
                        "file_sha256": fragment_sha,
                        "pcm_sha256": "",
                        "frame_count": 4800,
                        "sample_rate": 48000,
                    }
                ],
            }
        ],
    }


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


def test_manifest_v1_without_cover_or_loudness_still_loads(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
        schema_version="audiobook_media_export_v1",
    )
    _write_manifest(app_home, str(request_id), payload)

    loaded = load_manifest(app_home, request_id)

    assert loaded.cover is None
    assert loaded.loudness is None


def test_manifest_v1_rejects_loudness_field(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
        schema_version="audiobook_media_export_v1",
    )
    payload["loudness"] = {"unit": "lufs", "target_i": -18.0}
    _write_manifest(app_home, str(request_id), payload)

    with pytest.raises(MediaManifestError) as exc_info:
        load_manifest(app_home, request_id)
    assert exc_info.value.error_code == "invalid_request"


def test_manifest_v2_loudness_only_loads_for_m4b_and_mp3(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)

    for profile in ("m4b", "chapter_mp3"):
        payload = _manifest_payload(
            request_id=request_id,
            book_id=book_id,
            candidate_id=candidate_id,
            fragment_path=fragment_path,
            fragment_sha=fragment_sha,
            profile=profile,
        )
        payload["loudness"] = {"unit": "lufs", "target_i": -18.0}
        _write_manifest(app_home, str(request_id), payload)

        loaded = load_manifest(app_home, request_id)

        assert loaded.cover is None
        assert loaded.loudness is not None
        assert loaded.loudness.unit == "lufs"
        assert loaded.loudness.target_i == -18.0


def test_manifest_v2_loudness_defaults_true_peak_and_range(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
    )
    payload["loudness"] = {"unit": "lufs", "target_i": -18.0}
    _write_manifest(app_home, str(request_id), payload)

    loaded = load_manifest(app_home, request_id)

    assert loaded.loudness is not None
    assert loaded.loudness.true_peak_db == -1.5
    assert loaded.loudness.loudness_range == 11.0

    # Declared range bounds are inclusive.
    payload["loudness"] = {
        "unit": "lufs",
        "target_i": -40.0,
        "true_peak_db": -10.0,
        "loudness_range": 50.0,
    }
    _write_manifest(app_home, str(request_id), payload)

    loaded = load_manifest(app_home, request_id)

    assert loaded.loudness is not None
    assert loaded.loudness.target_i == -40.0
    assert loaded.loudness.true_peak_db == -10.0
    assert loaded.loudness.loudness_range == 50.0


def test_manifest_v2_rejects_bad_unit_unknown_key_and_bad_types(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)

    bad_loudness_values: list[object] = [
        "lufs",
        {"unit": "LUFS", "target_i": -18.0},
        {"unit": "lufs", "target_i": -18.0, "typo_key": 1.0},
        {"unit": "lufs"},
        {"target_i": -18.0},
        {"unit": "lufs", "target_i": True},
        {"unit": "lufs", "target_i": "loud"},
        {"unit": "lufs", "target_i": float("nan")},
        {"unit": "lufs", "target_i": float("inf")},
        {"unit": "lufs", "target_i": -18.0, "true_peak_db": True},
        {"unit": "lufs", "target_i": -18.0, "true_peak_db": float("inf")},
        {"unit": "lufs", "target_i": -18.0, "loudness_range": True},
        {"unit": "lufs", "target_i": -18.0, "loudness_range": float("nan")},
    ]
    for bad_loudness in bad_loudness_values:
        payload = _manifest_payload(
            request_id=request_id,
            book_id=book_id,
            candidate_id=candidate_id,
            fragment_path=fragment_path,
            fragment_sha=fragment_sha,
        )
        payload["loudness"] = bad_loudness
        _write_manifest(app_home, str(request_id), payload)

        with pytest.raises(MediaManifestError) as exc_info:
            load_manifest(app_home, request_id)
        assert exc_info.value.error_code == "invalid_request"


def test_manifest_v2_rejects_out_of_range_loudness(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)

    out_of_range_values: list[object] = [
        {"unit": "lufs", "target_i": -40.1},
        {"unit": "lufs", "target_i": -4.9},
        {"unit": "lufs", "target_i": -18.0, "true_peak_db": -10.1},
        {"unit": "lufs", "target_i": -18.0, "true_peak_db": 0.1},
        {"unit": "lufs", "target_i": -18.0, "loudness_range": 0.9},
        {"unit": "lufs", "target_i": -18.0, "loudness_range": 50.1},
    ]
    for bad_loudness in out_of_range_values:
        payload = _manifest_payload(
            request_id=request_id,
            book_id=book_id,
            candidate_id=candidate_id,
            fragment_path=fragment_path,
            fragment_sha=fragment_sha,
        )
        payload["loudness"] = bad_loudness
        _write_manifest(app_home, str(request_id), payload)

        with pytest.raises(MediaManifestError) as exc_info:
            load_manifest(app_home, request_id)
        assert exc_info.value.error_code == "invalid_request"


def test_manifest_v2_requires_at_least_one_extension(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
    )
    assert "cover" not in payload
    assert "loudness" not in payload
    _write_manifest(app_home, str(request_id), payload)

    with pytest.raises(MediaManifestError) as exc_info:
        load_manifest(app_home, request_id)
    assert exc_info.value.error_code == "invalid_request"


def test_manifest_v2_cover_still_requires_m4b(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    cover_path, cover_sha = _seed_cover(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
        profile="chapter_mp3",
    )
    payload["cover"] = {"relative_path": cover_path, "image_sha256": cover_sha}
    _write_manifest(app_home, str(request_id), payload)

    with pytest.raises(MediaManifestError) as exc_info:
        load_manifest(app_home, request_id)
    assert exc_info.value.error_code == "invalid_request"


def test_manifest_v2_cover_plus_loudness_on_m4b_loads_both(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    cover_path, cover_sha = _seed_cover(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
    )
    payload["cover"] = {"relative_path": cover_path, "image_sha256": cover_sha}
    payload["loudness"] = {"unit": "lufs", "target_i": -19.0, "true_peak_db": -2.0}
    _write_manifest(app_home, str(request_id), payload)

    loaded = load_manifest(app_home, request_id)

    assert loaded.cover is not None
    assert loaded.cover.relative_path == cover_path
    assert loaded.loudness is not None
    assert loaded.loudness.target_i == -19.0
    assert loaded.loudness.true_peak_db == -2.0
    assert loaded.loudness.loudness_range == 11.0


def test_manifest_v2_cover_plus_loudness_on_mp3_rejected(tmp_path: Path) -> None:
    app_home = tmp_path / "app_home"
    book_id = uuid4()
    request_id = uuid4()
    candidate_id, fragment_path, fragment_sha = _seed_fragment(app_home, book_id)
    cover_path, cover_sha = _seed_cover(app_home, book_id)
    payload = _manifest_payload(
        request_id=request_id,
        book_id=book_id,
        candidate_id=candidate_id,
        fragment_path=fragment_path,
        fragment_sha=fragment_sha,
        profile="chapter_mp3",
    )
    payload["cover"] = {"relative_path": cover_path, "image_sha256": cover_sha}
    payload["loudness"] = {"unit": "lufs", "target_i": -19.0}
    _write_manifest(app_home, str(request_id), payload)

    with pytest.raises(MediaManifestError) as exc_info:
        load_manifest(app_home, request_id)
    assert exc_info.value.error_code == "invalid_request"
