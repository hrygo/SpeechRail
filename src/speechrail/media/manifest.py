"""Strict manifest loading and path/symlink/hash validation for audiobook media exports."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID

MAX_MANIFEST_BYTES = 64 * 1024 * 1024
IO_CHUNK_BYTES = 64 * 1024
MANIFEST_SCHEMA_VERSION = "audiobook_media_export_v1"
_SAFE_REL_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")


class MediaManifestError(ValueError):
    """Raised when an audiobook export manifest violates structural or boundary rules."""

    def __init__(self, message: str, *, error_code: str = "invalid_manifest") -> None:
        super().__init__(message)
        self.error_code = error_code


@dataclass(frozen=True, slots=True)
class MediaFragmentEntry:
    fragment_id: UUID
    candidate_id: UUID
    relative_path: str
    file_sha256: str
    pcm_sha256: str
    frame_count: int
    sample_rate: int = 48_000


@dataclass(frozen=True, slots=True)
class MediaChapterEntry:
    chapter_id: UUID
    ordinal: int
    title: str
    fragments: tuple[MediaFragmentEntry, ...]


@dataclass(frozen=True, slots=True)
class MediaExportManifest:
    schema_version: str
    request_id: UUID
    book_id: UUID
    source_id: UUID
    production_revision_id: UUID
    profile: str
    book_title: str
    author: str | None
    chapters: tuple[MediaChapterEntry, ...]
    app_home: Path | None = None


def sha256_file_chunked(path: Path, *, chunk_size: int = IO_CHUNK_BYTES) -> str:
    """Compute SHA-256 using bounded 64 KiB reads so large audio files never load in memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _reject_symlinks_on_chain(root: Path, target: Path) -> None:
    if root.is_symlink() or target.is_symlink():
        raise MediaManifestError(
            "symbolic links are not allowed in media inputs",
            error_code="invalid_request",
        )
    current = target
    resolved_root = root.resolve()
    while True:
        if current.is_symlink():
            raise MediaManifestError(
                "symbolic links are not allowed in media inputs",
                error_code="invalid_request",
            )
        if current == root or current == current.parent:
            break
        current = current.parent
    resolved_target = target.resolve()
    try:
        resolved_target.relative_to(resolved_root)
    except ValueError as exc:
        raise MediaManifestError(
            "input path escapes audiobooks root",
            error_code="invalid_request",
        ) from exc


def _validate_owned_relative_path(
    relative_path: str, *, book_id: UUID, audiobooks_root: Path
) -> Path:
    if (
        not relative_path
        or "://" in relative_path
        or relative_path.startswith("/")
        or relative_path.startswith("-")
        or "\\" in relative_path
        or not _SAFE_REL_PATH_RE.match(relative_path)
    ):
        raise MediaManifestError("invalid relative asset path", error_code="invalid_request")

    parts = relative_path.split("/")
    if any(part in {"", ".", ".."} or part.startswith("-") for part in parts):
        raise MediaManifestError(
            "path traversal or flag injection rejected",
            error_code="invalid_request",
        )

    expected_prefix = ("books", str(book_id), "audio")
    if tuple(parts[:3]) != expected_prefix or len(parts) != 4 or not parts[3].endswith(".wav"):
        raise MediaManifestError(
            "media input must reside inside the book's owned audio directory",
            error_code="invalid_request",
        )

    candidate_path = audiobooks_root.joinpath(*parts)
    _reject_symlinks_on_chain(audiobooks_root, candidate_path)
    if not candidate_path.is_file():
        raise MediaManifestError(
            "referenced audio fragment does not exist",
            error_code="integrity_mismatch",
        )
    return candidate_path


def load_manifest(app_home: Path, request_id: UUID) -> MediaExportManifest:
    """Load and validate `<app_home>/audiobooks/exports/<request_id>/request.json`."""
    if not isinstance(request_id, UUID):
        request_id = UUID(str(request_id))

    audiobooks_root = Path(app_home) / "audiobooks"
    if not audiobooks_root.exists():
        raise MediaManifestError(
            "audiobooks root directory is missing",
            error_code="invalid_request",
        )
    _reject_symlinks_on_chain(audiobooks_root, audiobooks_root)

    request_dir = audiobooks_root / "exports" / str(request_id)
    request_file = request_dir / "request.json"
    _reject_symlinks_on_chain(audiobooks_root, request_file)
    if not request_file.is_file():
        raise MediaManifestError(
            "export request manifest does not exist",
            error_code="invalid_request",
        )

    stat = request_file.stat()
    if stat.st_size > MAX_MANIFEST_BYTES:
        raise MediaManifestError(
            "export manifest exceeds 64 MiB limit",
            error_code="invalid_request",
        )

    raw_bytes = bytearray()
    with request_file.open("rb") as handle:
        while True:
            chunk = handle.read(IO_CHUNK_BYTES)
            if not chunk:
                break
            if len(raw_bytes) + len(chunk) > MAX_MANIFEST_BYTES:
                raise MediaManifestError(
                    "export manifest exceeds 64 MiB limit",
                    error_code="invalid_request",
                )
            raw_bytes.extend(chunk)

    try:
        payload: dict[str, Any] = json.loads(raw_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MediaManifestError(
            "manifest is not valid UTF-8 JSON",
            error_code="invalid_request",
        ) from exc

    if not isinstance(payload, dict) or payload.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise MediaManifestError(
            "unsupported manifest schema_version",
            error_code="invalid_request",
        )

    try:
        manifest_req_id = UUID(str(payload["request_id"]))
        book_id = UUID(str(payload["book_id"]))
        source_id = UUID(str(payload["source_id"]))
        production_revision_id = UUID(str(payload["production_revision_id"]))
    except (KeyError, ValueError) as exc:
        raise MediaManifestError(
            "invalid UUID fields in manifest",
            error_code="invalid_request",
        ) from exc

    if manifest_req_id != request_id:
        raise MediaManifestError(
            "manifest request_id does not match command request_id",
            error_code="invalid_request",
        )

    profile = payload.get("profile")
    if profile not in {"m4b", "chapter_mp3"}:
        raise MediaManifestError("unsupported export profile", error_code="invalid_request")

    book_title = str(payload.get("book_title") or "").strip()
    if not book_title:
        raise MediaManifestError("book_title must not be empty", error_code="invalid_request")
    raw_author = payload.get("author")
    author = (
        str(raw_author).strip()
        if isinstance(raw_author, str) and raw_author.strip()
        else None
    )

    raw_chapters = payload.get("chapters")
    if not isinstance(raw_chapters, list) or not raw_chapters:
        raise MediaManifestError(
            "manifest must contain at least one chapter",
            error_code="invalid_request",
        )

    chapters: list[MediaChapterEntry] = []
    for ch_obj in raw_chapters:
        if not isinstance(ch_obj, dict):
            raise MediaManifestError(
                "chapter entry must be an object",
                error_code="invalid_request",
            )
        try:
            chapter_id = UUID(str(ch_obj["chapter_id"]))
            ordinal = int(ch_obj["ordinal"])
            title = str(ch_obj["title"]).strip() or f"Chapter {ordinal + 1}"
            raw_fragments = ch_obj["fragments"]
        except (KeyError, ValueError, TypeError) as exc:
            raise MediaManifestError(
                "invalid chapter fields",
                error_code="invalid_request",
            ) from exc

        if not isinstance(raw_fragments, list) or not raw_fragments:
            raise MediaManifestError(
                "chapter must contain at least one fragment",
                error_code="invalid_request",
            )

        fragments: list[MediaFragmentEntry] = []
        for frag_obj in raw_fragments:
            if not isinstance(frag_obj, dict):
                raise MediaManifestError(
                    "fragment entry must be an object",
                    error_code="invalid_request",
                )
            try:
                fragment_id = UUID(str(frag_obj["fragment_id"]))
                candidate_id = UUID(str(frag_obj["candidate_id"]))
                rel_path = str(frag_obj["relative_path"])
                file_sha256 = str(frag_obj["file_sha256"]).lower()
                pcm_sha256 = str(frag_obj.get("pcm_sha256") or "").lower()
                frame_count = int(frag_obj["frame_count"])
                sample_rate = int(frag_obj.get("sample_rate", 48_000))
            except (KeyError, ValueError, TypeError) as exc:
                raise MediaManifestError(
                    "invalid fragment fields",
                    error_code="invalid_request",
                ) from exc

            if frame_count <= 0 or sample_rate <= 0:
                raise MediaManifestError(
                    "fragment frame_count and sample_rate must be positive",
                    error_code="invalid_request",
                )

            resolved_wav = _validate_owned_relative_path(
                rel_path,
                book_id=book_id,
                audiobooks_root=audiobooks_root,
            )
            actual_sha = sha256_file_chunked(resolved_wav)
            if actual_sha.lower() != file_sha256:
                raise MediaManifestError(
                    "input WAV SHA-256 mismatch against manifest",
                    error_code="integrity_mismatch",
                )

            fragments.append(
                MediaFragmentEntry(
                    fragment_id=fragment_id,
                    candidate_id=candidate_id,
                    relative_path=rel_path,
                    file_sha256=file_sha256,
                    pcm_sha256=pcm_sha256,
                    frame_count=frame_count,
                    sample_rate=sample_rate,
                )
            )

        chapters.append(
            MediaChapterEntry(
                chapter_id=chapter_id,
                ordinal=ordinal,
                title=title,
                fragments=tuple(fragments),
            )
        )

    return MediaExportManifest(
        schema_version=MANIFEST_SCHEMA_VERSION,
        request_id=request_id,
        book_id=book_id,
        source_id=source_id,
        production_revision_id=production_revision_id,
        profile=profile,
        book_title=book_title,
        author=author,
        chapters=tuple(chapters),
        app_home=Path(app_home).resolve(),
    )
