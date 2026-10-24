"""Versioned, path-free voice bundle format.

A bundle is a ZIP carrying a readable manifest plus the reference assets a
voice needs to be reproduced on another machine. It deliberately carries no
absolute paths, no validation verdicts, no model weights and no secrets, so
importing a bundle can never inherit another machine's ``production_ready``
claim or point the store outside its own voices directory.

Reading is fail-closed: the archive is bounded before it is decompressed, every
entry name is checked for traversal and symlink markers, and every digest in the
manifest is verified against the bytes actually read.
"""

from __future__ import annotations

import hashlib
import io
import json
import zipfile
from dataclasses import dataclass
from typing import Final, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from speechrail.domain.voice_creation import VoiceCreation

BUNDLE_FORMAT: Final[Literal["speechrail.voice-bundle"]] = "speechrail.voice-bundle"
BUNDLE_FORMAT_VERSION = 1
MANIFEST_NAME = "manifest.json"
REFERENCE_AUDIO_PATH = "audio/reference.wav"

# Bounds are checked twice: once against the archive's declared sizes before
# reading anything, and once against the bytes actually decompressed, because a
# ZIP header can lie about ``file_size``.
MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024
MAX_ENTRIES = 8
MAX_REFERENCE_AUDIO_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 256 * 1024

MAX_NAME_LENGTH = 120
MAX_INSTRUCTION_LENGTH = 10_000
MAX_REFERENCE_TEXT_LENGTH = 4_000

_SYMLINK_MODE = 0o120000


class VoiceBundleError(Exception):
    """A bundle that cannot be read, with a stable code for the API envelope."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class VoiceBundleAsset(BaseModel):
    """One file in the archive, addressed by a relative path."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    path: str
    media_type: Literal["audio/wav"]
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    bytes: int = Field(ge=1, le=MAX_REFERENCE_AUDIO_BYTES)


class VoiceBundleVoice(BaseModel):
    """The acoustic identity and human-facing description of the voice.

    ``creation`` is the only provenance that is carried: it names the model
    artifact, revision and preprocessing used to generate a reference. Local
    quality scores and validation verdicts are intentionally absent.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    name: str = Field(min_length=1, max_length=MAX_NAME_LENGTH)
    mode: Literal["clone", "instruction"]
    instruction: str = Field(default="", max_length=MAX_INSTRUCTION_LENGTH)
    ref_text: str | None = Field(default=None, max_length=MAX_REFERENCE_TEXT_LENGTH)
    seed: int = Field(default=42, ge=0, le=2**32 - 1)
    temperature: float = 0.1
    duration_seconds: float = Field(default=0.0, ge=0)
    creation: VoiceCreation | None = None


class VoiceBundleSource(BaseModel):
    """Where the bundle came from. Recorded, never trusted for admission."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    voice_id: str = Field(min_length=1, max_length=64)
    revision: str | None = None
    exported_at: str
    service_version: str = ""


class VoiceBundleManifest(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    format: Literal["speechrail.voice-bundle"]
    format_version: int
    source: VoiceBundleSource
    voice: VoiceBundleVoice
    assets: tuple[VoiceBundleAsset, ...] = ()


@dataclass(frozen=True, slots=True)
class ParsedBundle:
    """A verified bundle: manifest plus the bytes its assets claim."""

    manifest: VoiceBundleManifest
    assets: dict[str, bytes]

    @property
    def reference_audio(self) -> bytes | None:
        return self.assets.get(REFERENCE_AUDIO_PATH)

    @property
    def required_capabilities(self) -> tuple[str, ...]:
        """Capabilities this voice needs before it can be synthesised here."""
        if self.manifest.voice.mode == "clone":
            return ("tts_base",)
        return ("voice_design",)


def _reject(code: str, message: str) -> VoiceBundleError:
    return VoiceBundleError(code, message)


def _safe_member(info: zipfile.ZipInfo) -> str:
    """Return the entry name, or raise when the entry is not a plain file."""

    name = info.filename
    if not name or "\x00" in name:
        raise _reject("bundle_unsafe_entry", "Bundle contains an unnamed entry")
    if name.startswith("/") or "\\" in name:
        raise _reject("bundle_unsafe_entry", f"Bundle entry is not a relative path: {name!r}")
    if name.endswith("/"):
        raise _reject("bundle_unsafe_entry", f"Bundle contains a directory entry: {name!r}")
    parts = name.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise _reject("bundle_unsafe_entry", f"Bundle entry escapes the archive: {name!r}")
    # ``external_attr`` carries the Unix mode in its high 16 bits; a symlink
    # would let a bundle reference a path outside the archive.
    mode = (info.external_attr >> 16) & 0o170000
    if mode == _SYMLINK_MODE:
        raise _reject("bundle_unsafe_entry", f"Bundle entry is a symlink: {name!r}")
    return name


def _read_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    """Read one entry with an absolute ceiling, ignoring a lying header size."""

    with archive.open(info, "r") as handle:
        payload = handle.read(limit + 1)
    if len(payload) > limit:
        raise _reject("bundle_too_large", f"Bundle entry exceeds {limit} bytes: {info.filename!r}")
    return payload


def parse_bundle(data: bytes) -> ParsedBundle:
    """Verify a bundle and return its manifest plus asset bytes.

    Every failure is a :class:`VoiceBundleError` with a stable code; callers map
    those to HTTP without having to guess what went wrong.
    """

    if not data:
        raise _reject("bundle_empty", "Bundle payload is empty")
    if len(data) > MAX_ARCHIVE_BYTES:
        raise _reject(
            "bundle_too_large",
            f"Bundle exceeds the {MAX_ARCHIVE_BYTES // (1024 * 1024)}MB archive limit",
        )

    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, OSError, ValueError) as exc:
        raise _reject("bundle_invalid_zip", "Bundle is not a readable ZIP archive") from exc

    with archive:
        infos = archive.infolist()
        if len(infos) > MAX_ENTRIES:
            raise _reject("bundle_too_large", f"Bundle has more than {MAX_ENTRIES} entries")
        if sum(info.file_size for info in infos) > MAX_UNCOMPRESSED_BYTES:
            raise _reject("bundle_too_large", "Bundle expands beyond the size limit")

        names = [_safe_member(info) for info in infos]
        if len(set(names)) != len(names):
            raise _reject("bundle_duplicate_entry", "Bundle repeats an entry name")
        by_name = dict(zip(names, infos, strict=True))

        manifest_info = by_name.get(MANIFEST_NAME)
        if manifest_info is None:
            raise _reject("bundle_missing_manifest", f"Bundle has no {MANIFEST_NAME}")
        manifest_raw = _read_entry(archive, manifest_info, MAX_MANIFEST_BYTES)
        try:
            document = json.loads(manifest_raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise _reject("bundle_invalid_manifest", "Manifest is not valid UTF-8 JSON") from exc
        if not isinstance(document, dict):
            raise _reject("bundle_invalid_manifest", "Manifest must be a JSON object")

        # Read the format/version before strict validation so an unknown future
        # schema gets its own answer instead of a generic "invalid manifest".
        if document.get("format") != BUNDLE_FORMAT:
            raise _reject(
                "bundle_unsupported_format",
                f"Bundle format is not {BUNDLE_FORMAT}",
            )
        version = document.get("format_version")
        if not isinstance(version, int) or isinstance(version, bool):
            raise _reject("bundle_invalid_manifest", "Manifest format_version must be an integer")
        if version != BUNDLE_FORMAT_VERSION:
            raise _reject(
                "bundle_unsupported_version",
                f"Bundle format_version {version} is not supported (this build reads "
                f"{BUNDLE_FORMAT_VERSION})",
            )

        try:
            manifest = VoiceBundleManifest.model_validate(document)
        except ValidationError as exc:
            raise _reject("bundle_invalid_manifest", "Manifest fields are invalid") from exc

        declared = {asset.path for asset in manifest.assets}
        unexpected = set(names) - declared - {MANIFEST_NAME}
        if unexpected:
            raise _reject(
                "bundle_unexpected_entry",
                f"Bundle contains an undeclared entry: {sorted(unexpected)[0]!r}",
            )

        assets: dict[str, bytes] = {}
        for asset in manifest.assets:
            info = by_name.get(asset.path)
            if info is None:
                raise _reject(
                    "bundle_missing_asset",
                    f"Bundle is missing its declared asset: {asset.path!r}",
                )
            payload = _read_entry(archive, info, MAX_REFERENCE_AUDIO_BYTES)
            if len(payload) != asset.bytes:
                raise _reject(
                    "bundle_digest_mismatch",
                    f"Asset size does not match the manifest: {asset.path!r}",
                )
            if hashlib.sha256(payload).hexdigest() != asset.sha256:
                raise _reject(
                    "bundle_digest_mismatch",
                    f"Asset digest does not match the manifest: {asset.path!r}",
                )
            assets[asset.path] = payload

        if manifest.voice.mode == "clone":
            if REFERENCE_AUDIO_PATH not in assets:
                raise _reject(
                    "bundle_missing_asset",
                    "A clone voice bundle must contain its reference audio",
                )
            if not (manifest.voice.ref_text or "").strip():
                raise _reject(
                    "bundle_invalid_manifest",
                    "A clone voice bundle must contain its reference text",
                )
        elif manifest.voice.mode == "instruction" and not manifest.voice.instruction.strip():
            raise _reject(
                "bundle_invalid_manifest",
                "An instruction voice bundle must contain its instruction",
            )

        return ParsedBundle(manifest=manifest, assets=assets)


def build_manifest(
    *,
    voice_id: str,
    name: str,
    mode: Literal["clone", "instruction"],
    instruction: str,
    ref_text: str | None,
    seed: int,
    temperature: float,
    duration_seconds: float,
    creation: VoiceCreation | None,
    revision: str | None,
    exported_at: str,
    service_version: str,
    reference_audio: bytes | None,
) -> VoiceBundleManifest:
    """Assemble the manifest for an export; assets are derived, never guessed."""

    assets: tuple[VoiceBundleAsset, ...] = ()
    if reference_audio is not None:
        assets = (
            VoiceBundleAsset(
                path=REFERENCE_AUDIO_PATH,
                media_type="audio/wav",
                sha256=hashlib.sha256(reference_audio).hexdigest(),
                bytes=len(reference_audio),
            ),
        )
    return VoiceBundleManifest(
        format=BUNDLE_FORMAT,
        format_version=BUNDLE_FORMAT_VERSION,
        source=VoiceBundleSource(
            voice_id=voice_id,
            revision=revision,
            exported_at=exported_at,
            service_version=service_version,
        ),
        voice=VoiceBundleVoice(
            name=name,
            mode=mode,
            instruction=instruction,
            ref_text=ref_text,
            seed=seed,
            temperature=temperature,
            duration_seconds=duration_seconds,
            creation=creation,
        ),
        assets=assets,
    )


def write_bundle(manifest: VoiceBundleManifest, assets: dict[str, bytes]) -> bytes:
    """Serialise a bundle deterministically (fixed order, fixed timestamps)."""

    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        entries = [(MANIFEST_NAME, manifest.model_dump_json(indent=2).encode("utf-8"))]
        entries.extend((path, assets[path]) for path in sorted(assets))
        for name, payload in entries:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            archive.writestr(info, payload)
    return buffer.getvalue()
