"""Voice bundle export, read-only inspection and transactional import.

The three operations share one reader so a bundle that cannot be inspected can
never be imported, and an inspection never writes anything: it parses the
archive in memory, verifies digests and reports capability gaps without
touching the catalog, the store or the models.
"""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from speechrail.domain.tts import VoiceProfile, validate_transcoded_clone_wav
from speechrail.domain.voice_bundle import (
    BUNDLE_FORMAT,
    REFERENCE_AUDIO_PATH,
    VoiceBundleError,
    build_manifest,
    parse_bundle,
    write_bundle,
)
from speechrail.domain.voice_ports import VoiceLeases, VoiceRevisions

# What a bundle deliberately leaves behind. Kept as data so the preview, the
# API response and the documentation cannot drift apart.
EXCLUDED_FROM_BUNDLE: tuple[str, ...] = (
    "本机验证与质量结论",
    "绝对路径与存储位置",
    "模型权重与运行配置",
    "会话历史与密钥",
)

_CAPABILITY_LABELS = {
    "tts_base": "音色克隆（Base）",
    "voice_design": "音色设计",
}

_NAME_SUFFIX = "（导入）"


@dataclass(frozen=True, slots=True)
class BundlePreview:
    """What an export of this voice would contain, before anything is written."""

    voice_id: str
    name: str
    mode: str
    revision: str | None
    includes_reference_audio: bool
    includes_reference_text: bool
    reference_audio_bytes: int
    reference_audio_sha256: str | None
    entries: tuple[str, ...]
    excluded: tuple[str, ...]

    def to_payload(self) -> dict[str, object]:
        return {
            "voice_id": self.voice_id,
            "name": self.name,
            "mode": self.mode,
            "revision": self.revision,
            "includes_reference_audio": self.includes_reference_audio,
            "includes_reference_text": self.includes_reference_text,
            "reference_audio_bytes": self.reference_audio_bytes,
            "reference_audio_sha256": self.reference_audio_sha256,
            "entries": list(self.entries),
            "excluded": list(self.excluded),
        }


@dataclass(frozen=True, slots=True)
class BundleInspection:
    """A read-only verdict about an uploaded bundle."""

    format: str
    format_version: int
    name: str
    mode: str
    exported_at: str
    source_voice_id: str
    source_revision: str | None
    includes_reference_audio: bool
    includes_reference_text: bool
    reference_audio_bytes: int
    duration_seconds: float
    required_capabilities: tuple[str, ...]
    missing_capabilities: tuple[str, ...]
    name_conflict: bool
    importable: bool
    notes: tuple[str, ...]

    def to_payload(self) -> dict[str, object]:
        return {
            "format": self.format,
            "format_version": self.format_version,
            "name": self.name,
            "mode": self.mode,
            "exported_at": self.exported_at,
            "source_voice_id": self.source_voice_id,
            "source_revision": self.source_revision,
            "includes_reference_audio": self.includes_reference_audio,
            "includes_reference_text": self.includes_reference_text,
            "reference_audio_bytes": self.reference_audio_bytes,
            "duration_seconds": self.duration_seconds,
            "required_capabilities": list(self.required_capabilities),
            "missing_capabilities": list(self.missing_capabilities),
            "name_conflict": self.name_conflict,
            "importable": self.importable,
            "notes": list(self.notes),
        }


def preview_export(registry: VoiceLeases, voice_id: str) -> BundlePreview:
    """Describe the bundle an export would produce, without building it."""

    with registry.lease_profile(voice_id) as profile:
        if profile.is_system:
            raise VoiceBundleError(
                "bundle_system_voice_not_exportable",
                "Built-in preset voices ship with the service and cannot be exported",
            )
        audio_bytes = 0
        digest: str | None = None
        if profile.audio_path:
            try:
                payload = Path(profile.audio_path).read_bytes()
            except OSError as exc:
                raise VoiceBundleError(
                    "bundle_asset_unavailable",
                    "The reference audio for this voice cannot be read",
                ) from exc
            audio_bytes = len(payload)
            digest = hashlib.sha256(payload).hexdigest()
        entries = ["manifest.json"]
        if audio_bytes:
            entries.append(REFERENCE_AUDIO_PATH)
        return BundlePreview(
            voice_id=profile.id,
            name=profile.name or profile.id,
            mode=profile.mode,
            revision=profile.revision,
            includes_reference_audio=audio_bytes > 0,
            includes_reference_text=bool(profile.ref_text),
            reference_audio_bytes=audio_bytes,
            reference_audio_sha256=digest,
            entries=tuple(entries),
            excluded=EXCLUDED_FROM_BUNDLE,
        )


def _bundle_mode(profile: VoiceProfile) -> Literal["clone", "instruction"]:
    """Map a stored profile mode onto the bundle's two exportable modes."""

    if profile.mode == "clone":
        return "clone"
    if profile.mode == "instruction":
        return "instruction"
    raise VoiceBundleError(
        "bundle_unsupported_voice_mode",
        f"Voice mode {profile.mode!r} has no portable bundle representation",
    )


def export_bundle(registry: VoiceLeases, voice_id: str, *, service_version: str = "") -> bytes:
    """Build the bundle bytes for one custom voice."""

    with registry.lease_profile(voice_id) as profile:
        if profile.is_system:
            raise VoiceBundleError(
                "bundle_system_voice_not_exportable",
                "Built-in preset voices ship with the service and cannot be exported",
            )
        audio_bytes: bytes | None = None
        if profile.audio_path:
            try:
                audio_bytes = Path(profile.audio_path).read_bytes()
            except OSError as exc:
                raise VoiceBundleError(
                    "bundle_asset_unavailable",
                    "The reference audio for this voice cannot be read",
                ) from exc
        manifest = build_manifest(
            voice_id=profile.id,
            name=profile.name or profile.id,
            mode=_bundle_mode(profile),
            instruction=profile.instruction,
            ref_text=profile.ref_text,
            seed=profile.seed,
            temperature=profile.temperature,
            duration_seconds=profile.duration_seconds,
            creation=profile.creation,
            revision=profile.revision,
            exported_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            service_version=service_version,
            reference_audio=audio_bytes,
        )
        assets: dict[str, bytes] = {}
        if audio_bytes is not None:
            assets[REFERENCE_AUDIO_PATH] = audio_bytes
        return write_bundle(manifest, assets)


def inspect_bundle(
    data: bytes,
    *,
    available_capabilities: set[str],
    existing_names: set[str],
) -> BundleInspection:
    """Verify a bundle and report what importing it would need.

    Nothing is written: the audio is re-validated in memory against the same
    container rules the clone path uses, so a bundle cannot smuggle in a
    duration or a container the local service would reject.
    """

    parsed = parse_bundle(data)
    voice = parsed.manifest.voice

    duration = voice.duration_seconds
    if voice.mode == "clone":
        audio = parsed.reference_audio
        if audio is None:  # parse_bundle already rejects this; keep the boundary explicit.
            raise VoiceBundleError(
                "bundle_missing_asset", "A clone voice bundle must contain its reference audio"
            )
        try:
            duration = validate_transcoded_clone_wav(audio, skip_signal_validation=True)
        except ValueError as exc:
            raise VoiceBundleError(
                "bundle_invalid_asset",
                f"The reference audio does not match the local clone requirements: {exc}",
            ) from exc

    required = parsed.required_capabilities
    missing = tuple(cap for cap in required if cap not in available_capabilities)
    notes: list[str] = []
    if missing:
        labels = "、".join(_CAPABILITY_LABELS.get(cap, cap) for cap in missing)
        notes.append(f"当前运行档位没有{labels}能力，导入后需要先准备对应模型才能合成。")
    notes.append("包内不携带验证结论：导入后仍需在本机重新核验才能用于正式制作。")
    if voice.mode == "clone":
        notes.append("参考音频与参考文本按原样保留；导入会新建本地身份，不覆盖已有音色。")

    return BundleInspection(
        format=BUNDLE_FORMAT,
        format_version=parsed.manifest.format_version,
        name=voice.name,
        mode=voice.mode,
        exported_at=parsed.manifest.source.exported_at,
        source_voice_id=parsed.manifest.source.voice_id,
        source_revision=parsed.manifest.source.revision,
        includes_reference_audio=parsed.reference_audio is not None,
        includes_reference_text=bool(voice.ref_text),
        reference_audio_bytes=len(parsed.reference_audio or b""),
        duration_seconds=round(duration, 2),
        required_capabilities=required,
        missing_capabilities=missing,
        name_conflict=voice.name in existing_names,
        importable=True,
        notes=tuple(notes),
    )


@dataclass(frozen=True, slots=True)
class ImportedVoice:
    profile: VoiceProfile
    inspection: BundleInspection
    renamed_from: str | None


def _unique_name(base: str, taken: set[str]) -> str:
    """Return a name that does not collide, never mutating the existing entry."""

    if base not in taken:
        return base
    candidate = f"{base}{_NAME_SUFFIX}"
    index = 2
    while candidate in taken:
        candidate = f"{base}（导入 {index}）"
        index += 1
    return candidate


def import_bundle(
    registry: VoiceRevisions,
    data: bytes,
    *,
    available_capabilities: set[str],
    name: str | None = None,
) -> ImportedVoice:
    """Import a bundle as a **new** local voice.

    The manifest's name is kept unless it collides with an existing custom
    voice, in which case the new voice is renamed and the original name is
    reported. An existing voice is never replaced, and the import either
    commits one complete profile or leaves the catalog untouched.
    """

    parsed = parse_bundle(data)
    voice = parsed.manifest.voice
    existing = {profile.name for profile in registry.list_profiles() if not profile.is_system}
    inspection = inspect_bundle(
        data,
        available_capabilities=available_capabilities,
        existing_names=existing,
    )

    requested = (name or "").strip() or voice.name
    final_name = _unique_name(requested, existing)
    renamed_from = requested if final_name != requested else None

    if voice.mode == "clone":
        audio = parsed.reference_audio
        if audio is None:
            raise VoiceBundleError(
                "bundle_missing_asset", "A clone voice bundle must contain its reference audio"
            )
        profile = registry.create_cloned_profile(
            name=final_name,
            ref_text=(voice.ref_text or "").strip(),
            audio_bytes=audio,
            # Re-measured from the container, never taken from the manifest.
            duration_seconds=inspection.duration_seconds,
            # Local quality/validation is intentionally not imported: the voice
            # starts unvalidated here and must pass this machine's gate.
            quality=None,
            creation=voice.creation,
            create_only=True,
        )
    else:
        profile = registry.create_custom_profile(
            name=final_name,
            instruction=voice.instruction.strip(),
            seed=voice.seed,
        )

    return ImportedVoice(profile=profile, inspection=inspection, renamed_from=renamed_from)
