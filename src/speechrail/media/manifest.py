"""Strict manifest loading and path/symlink/hash validation for audiobook media exports."""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID

MAX_MANIFEST_BYTES = 64 * 1024 * 1024
IO_CHUNK_BYTES = 64 * 1024
MANIFEST_SCHEMA_VERSION_V1 = "audiobook_media_export_v1"
MANIFEST_SCHEMA_VERSION_V2 = "audiobook_media_export_v2"
# Kept as the historical v1 alias so existing readers/importers keep resolving.
MANIFEST_SCHEMA_VERSION = MANIFEST_SCHEMA_VERSION_V1
SUPPORTED_MANIFEST_SCHEMA_VERSIONS = frozenset(
    {MANIFEST_SCHEMA_VERSION_V1, MANIFEST_SCHEMA_VERSION_V2}
)
# Engineering cap matching the ACX web Help Center cover limit (<= 8 MB). This is
# a fail-closed upload guard, not a proof that the file satisfies ACX precisely.
MAX_COVER_BYTES = 8 * 1024 * 1024
_ALLOWED_COVER_SUFFIXES = frozenset({".jpg", ".jpeg", ".png"})
# F3: the App-side cover store writes exactly this directory + filename stem, so the
# manifest validator enforces the same fixed shape instead of accepting any path.
_COVER_DIRECTORY_NAME = "cover"
_COVER_FILENAME_STEM = "cover"
_SAFE_REL_PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
# Optional v2 loudness normalization. The unit is pinned to LUFS so a manifest
# cannot request an unverifiable scale: integrated loudness is measured per
# ITU-R BS.1770-4, which is what makes a `target_i` value comparable across runs.
# The accepted ranges mirror the App-side slider so the API cannot express a
# target the UI could never produce.
#
# The defaults below are product defaults for generic narrated long form, chosen
# on their own terms rather than copied from any storefront or tool preset:
# -1.5 dBTP keeps 1.5 dB of headroom under full scale for lossy re-encoding, and
# an LRA target of 11 tolerates normal narration dynamics while still bounding
# chapter-to-chapter swings. They are deliberately NOT an ACX/Audible claim: ACX
# states its own RMS/peak/noise-floor window and forbids unauthorized synthetic
# speech, so these values must never be presented as an ACX-ready guarantee.
LOUDNESS_UNIT = "lufs"
_LOUDNESS_TARGET_I_RANGE = (-40.0, -5.0)
_LOUDNESS_TRUE_PEAK_DB_RANGE = (-10.0, 0.0)
_LOUDNESS_RANGE_RANGE = (1.0, 50.0)
_LOUDNESS_TRUE_PEAK_DB_DEFAULT = -1.5
_LOUDNESS_RANGE_DEFAULT = 11.0
_ALLOWED_LOUDNESS_KEYS = frozenset(
    {"unit", "target_i", "true_peak_db", "loudness_range"}
)


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
class MediaCoverEntry:
    relative_path: str
    image_sha256: str


@dataclass(frozen=True, slots=True)
class MediaLoudnessSettings:
    unit: str
    target_i: float
    true_peak_db: float
    loudness_range: float


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
    cover: MediaCoverEntry | None = None
    loudness: MediaLoudnessSettings | None = None


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


def _validate_owned_cover_path(
    relative_path: str, *, book_id: UUID, audiobooks_root: Path
) -> Path:
    """Validate a v2 cover path against the fixed ``books/<book_id>/cover/cover.<ext>`` shape.

    F3: the App-side store only ever installs ``cover/cover.<ext>``, so the filename is
    pinned here rather than accepting an arbitrary owned image path.
    """
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

    if (
        len(parts) != 4
        or tuple(parts[:3]) != ("books", str(book_id), _COVER_DIRECTORY_NAME)
        or Path(parts[3]).stem != _COVER_FILENAME_STEM
        or Path(parts[3]).suffix.lower() not in _ALLOWED_COVER_SUFFIXES
    ):
        raise MediaManifestError(
            "cover asset must be books/<book_id>/cover/cover.<jpg|jpeg|png>",
            error_code="invalid_request",
        )

    candidate_path = audiobooks_root.joinpath(*parts)
    _reject_symlinks_on_chain(audiobooks_root, candidate_path)
    if not candidate_path.is_file():
        raise MediaManifestError(
            "referenced cover image does not exist",
            error_code="integrity_mismatch",
        )
    return candidate_path


def _require_finite_number(value: Any, *, field: str) -> float:
    """Return ``value`` as a float, rejecting booleans and non-finite numbers.

    ``isinstance(True, int)`` is true in Python, and JSON admits ``NaN``/``Infinity``,
    so a bare numeric check would let ``true`` through as 1.0 or smuggle a
    non-comparable value past the range gates.
    """
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise MediaManifestError(
            f"loudness {field} must be a finite number",
            error_code="invalid_request",
        )
    return float(value)


def _parse_loudness_settings(raw: Any) -> MediaLoudnessSettings:
    """Parse and validate the optional v2 ``loudness`` object.

    Unknown keys are rejected rather than ignored so a misspelled field cannot
    silently fall back to its default.
    """
    if not isinstance(raw, dict):
        raise MediaManifestError(
            "loudness must be an object",
            error_code="invalid_request",
        )
    if set(raw) - _ALLOWED_LOUDNESS_KEYS:
        raise MediaManifestError(
            "loudness contains unknown fields",
            error_code="invalid_request",
        )
    if raw.get("unit") != LOUDNESS_UNIT:
        raise MediaManifestError(
            f"loudness unit must be {LOUDNESS_UNIT!r}",
            error_code="invalid_request",
        )
    if "target_i" not in raw:
        raise MediaManifestError(
            "loudness target_i is required",
            error_code="invalid_request",
        )

    target_i = _require_finite_number(raw["target_i"], field="target_i")
    low, high = _LOUDNESS_TARGET_I_RANGE
    if not low <= target_i <= high:
        raise MediaManifestError(
            f"loudness target_i must be within [{low}, {high}]",
            error_code="invalid_request",
        )

    true_peak_db = (
        _require_finite_number(raw["true_peak_db"], field="true_peak_db")
        if "true_peak_db" in raw
        else _LOUDNESS_TRUE_PEAK_DB_DEFAULT
    )
    low, high = _LOUDNESS_TRUE_PEAK_DB_RANGE
    if not low <= true_peak_db <= high:
        raise MediaManifestError(
            f"loudness true_peak_db must be within [{low}, {high}]",
            error_code="invalid_request",
        )

    loudness_range = (
        _require_finite_number(raw["loudness_range"], field="loudness_range")
        if "loudness_range" in raw
        else _LOUDNESS_RANGE_DEFAULT
    )
    low, high = _LOUDNESS_RANGE_RANGE
    if not low <= loudness_range <= high:
        raise MediaManifestError(
            f"loudness loudness_range must be within [{low}, {high}]",
            error_code="invalid_request",
        )

    return MediaLoudnessSettings(
        unit=LOUDNESS_UNIT,
        target_i=target_i,
        true_peak_db=true_peak_db,
        loudness_range=loudness_range,
    )


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

    schema_version = payload.get("schema_version") if isinstance(payload, dict) else None
    if (
        not isinstance(payload, dict)
        or not isinstance(schema_version, str)
        or schema_version not in SUPPORTED_MANIFEST_SCHEMA_VERSIONS
    ):
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

    if schema_version == MANIFEST_SCHEMA_VERSION_V1 and (
        "cover" in payload or "loudness" in payload
    ):
        raise MediaManifestError(
            "v1 manifest must not carry cover or loudness entries",
            error_code="invalid_request",
        )

    cover_entry: MediaCoverEntry | None = None
    loudness_settings: MediaLoudnessSettings | None = None
    if schema_version == MANIFEST_SCHEMA_VERSION_V2:
        has_cover = "cover" in payload
        has_loudness = "loudness" in payload
        if not has_cover and not has_loudness:
            raise MediaManifestError(
                "v2 manifest must contain a cover or loudness object",
                error_code="invalid_request",
            )
        if has_cover and profile != "m4b":
            raise MediaManifestError(
                "cover art is only supported for the m4b profile",
                error_code="invalid_request",
            )
        if has_cover:
            raw_cover = payload.get("cover")
            if not isinstance(raw_cover, dict):
                raise MediaManifestError(
                    "v2 manifest cover must be an object",
                    error_code="invalid_request",
                )
            try:
                cover_rel_path = str(raw_cover["relative_path"])
                cover_sha256 = str(raw_cover["image_sha256"]).lower()
            except (KeyError, ValueError, TypeError) as exc:
                raise MediaManifestError(
                    "invalid cover fields", error_code="invalid_request"
                ) from exc

            resolved_cover = _validate_owned_cover_path(
                cover_rel_path,
                book_id=book_id,
                audiobooks_root=audiobooks_root,
            )
            try:
                cover_byte_count = resolved_cover.stat().st_size
            except OSError as exc:
                raise MediaManifestError(
                    "referenced cover image does not exist",
                    error_code="integrity_mismatch",
                ) from exc
            if cover_byte_count > MAX_COVER_BYTES:
                raise MediaManifestError(
                    "cover image exceeds the 8 MiB limit",
                    error_code="invalid_request",
                )
            if sha256_file_chunked(resolved_cover).lower() != cover_sha256:
                raise MediaManifestError(
                    "cover image SHA-256 mismatch against manifest",
                    error_code="integrity_mismatch",
                )
            cover_entry = MediaCoverEntry(
                relative_path=cover_rel_path,
                image_sha256=cover_sha256,
            )
        if has_loudness:
            loudness_settings = _parse_loudness_settings(payload["loudness"])

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
        schema_version=schema_version,
        request_id=request_id,
        book_id=book_id,
        source_id=source_id,
        production_revision_id=production_revision_id,
        profile=profile,
        book_title=book_title,
        author=author,
        chapters=tuple(chapters),
        app_home=Path(app_home).resolve(),
        cover=cover_entry,
        loudness=loudness_settings,
    )
