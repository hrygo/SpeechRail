"""External manifest validation for profile benchmark evidence."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from urllib import parse as urllib_parse

PHASES = frozenset({"baseline", "quality", "cold", "warm", "soak", "switch"})
PROFILE_DEVICE_PHASES: Mapping[str, str] = MappingProxyType(
    {
        "light": "m1_air_8gb",
        "balanced": "device_12gb",
        "quality": "local_quality",
    }
)
_PROFILE_REQUIRED_PHASES: Mapping[str, frozenset[str]] = MappingProxyType(
    {
        "light": frozenset(
            {"m1_air_8gb", "quality", "cold", "warm", "soak", "switch"}
        ),
        "balanced": frozenset(
            {"device_12gb", "quality", "cold", "warm", "switch"}
        ),
        "quality": frozenset(
            {"local_quality", "quality", "cold", "warm", "switch"}
        ),
    }
)
_EVIDENCE_PHASES = PHASES | frozenset(PROFILE_DEVICE_PHASES.values())
_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_FIXTURE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_LANGUAGE_RE = re.compile(r"^(?:auto|[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$")


class BenchmarkInputError(ValueError):
    """Raised when a benchmark input would violate the evidence contract."""

@dataclass(frozen=True, slots=True)
class Fixture:
    """Validated fixture metadata; the audio path never enters output JSON."""

    id: str
    path: Path
    kind: str
    language: str
    voice: str
    text: str | None


@dataclass(frozen=True, slots=True)
class LoadedManifest:
    """Validated manifest metadata with opaque fixture references."""

    fixtures: tuple[Fixture, ...]
    model_identity: Mapping[str, object]
    quality: Mapping[str, object]
    soak: Mapping[str, object]
    switch: Mapping[str, object]
    phase_evidence: Mapping[str, Mapping[str, object]]
    software: Mapping[str, object]


def required_phases(profile: str) -> set[str]:
    """Return the real-device and benchmark phases required for one profile."""

    key = profile.strip().lower() if isinstance(profile, str) else ""
    phases = _PROFILE_REQUIRED_PHASES.get(key)
    if phases is None:
        raise BenchmarkInputError(f"unknown profile: {profile}")
    return set(phases)


def _looks_like_url(value: str) -> bool:
    parsed = urllib_parse.urlsplit(value)
    return bool(parsed.scheme or value.startswith("//"))


def _repository_external(path: Path, repository_root: Path) -> Path:
    if not path.is_absolute():
        raise BenchmarkInputError("manifest and fixture paths must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise BenchmarkInputError(f"path does not exist: {path}") from exc
    try:
        resolved.relative_to(repository_root.resolve())
    except ValueError:
        return resolved
    raise BenchmarkInputError("manifest and fixture paths must be outside the repository")


def _required_string(item: Mapping[str, object], key: str, *, label: str) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value.strip():
        raise BenchmarkInputError(f"{label}.{key} must be a non-blank string")
    return value.strip()


def _fixture_path(item: Mapping[str, object], *, repository_root: Path, label: str) -> Path:
    raw: object = item.get("path", item.get("audio_path", item.get("audio")))
    if not isinstance(raw, str) or not raw.strip():
        raise BenchmarkInputError(f"{label}.path must be an external local audio path")
    if _looks_like_url(raw.strip()):
        raise BenchmarkInputError(f"{label}.path must not be an audio URL")
    resolved = _repository_external(Path(raw).expanduser(), repository_root)
    if not resolved.is_file():
        raise BenchmarkInputError(f"fixture path is not a file: {raw}")
    return resolved


def _mapping_or_empty(value: object, *, label: str) -> Mapping[str, object]:
    if value is None:
        return MappingProxyType({})
    if not isinstance(value, Mapping):
        raise BenchmarkInputError(f"{label} must be an object")
    return dict(value)


def load_manifest(
    manifest: Path, *, repository_root: Path | None = None
) -> LoadedManifest:
    """Load an external JSON fixture list and reject URLs or repository paths."""

    root = _REPOSITORY_ROOT if repository_root is None else Path(repository_root).resolve()
    resolved_manifest = _repository_external(Path(manifest).expanduser(), root)
    if not resolved_manifest.is_file():
        raise BenchmarkInputError(f"manifest path is not a file: {manifest}")
    try:
        raw = json.loads(resolved_manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BenchmarkInputError("manifest must be valid UTF-8 JSON") from exc

    metadata: Mapping[str, object]
    if isinstance(raw, list):
        entries: object = raw
        metadata = {}
    elif isinstance(raw, Mapping):
        entries = raw.get("fixtures")
        metadata = dict(raw)
    else:
        raise BenchmarkInputError("manifest must be a fixture list or object with fixtures")
    if not isinstance(entries, list) or not entries:
        raise BenchmarkInputError("manifest fixtures must be a non-empty list")

    fixtures: list[Fixture] = []
    seen_ids: set[str] = set()
    for index, raw_item in enumerate(entries):
        label = f"fixtures[{index}]"
        if not isinstance(raw_item, Mapping):
            raise BenchmarkInputError(f"{label} must be an object")
        fixture_id = _required_string(raw_item, "id", label=label)
        if (
            fixture_id in seen_ids
            or _looks_like_url(fixture_id)
            or _FIXTURE_ID_RE.fullmatch(fixture_id) is None
        ):
            raise BenchmarkInputError(f"{label}.id must be a unique opaque identifier")
        seen_ids.add(fixture_id)
        kind = str(raw_item.get("kind", "asr")).strip().lower()
        if kind not in {"asr", "tts"}:
            raise BenchmarkInputError(f"{label}.kind must be asr or tts")
        text = raw_item.get("text")
        if kind == "tts" and (not isinstance(text, str) or not text.strip()):
            raise BenchmarkInputError(f"{label}.text is required for TTS fixtures")
        if text is not None and not isinstance(text, str):
            raise BenchmarkInputError(f"{label}.text must be a string")
        language = str(raw_item.get("language", "auto")).strip()
        if _LANGUAGE_RE.fullmatch(language) is None:
            raise BenchmarkInputError(f"{label}.language must be a safe language tag")
        fixtures.append(
            Fixture(
                id=fixture_id,
                path=_fixture_path(raw_item, repository_root=root, label=label),
                kind=kind,
                language=language,
                voice=str(raw_item.get("voice", "default")),
                text=text.strip() if isinstance(text, str) else None,
            )
        )

    raw_phase_evidence = metadata.get("phase_evidence", metadata.get("evidence"))
    phase_evidence: dict[str, Mapping[str, object]] = {}
    if raw_phase_evidence is not None:
        if not isinstance(raw_phase_evidence, Mapping):
            raise BenchmarkInputError("phase_evidence must be an object")
        for phase, evidence in raw_phase_evidence.items():
            if phase not in _EVIDENCE_PHASES:
                continue
            if isinstance(evidence, Mapping):
                phase_evidence[str(phase)] = dict(evidence)

    return LoadedManifest(
        fixtures=tuple(fixtures),
        model_identity=_mapping_or_empty(metadata.get("model_identity"), label="model_identity"),
        quality=_mapping_or_empty(metadata.get("quality"), label="quality"),
        soak=_mapping_or_empty(metadata.get("soak"), label="soak"),
        switch=_mapping_or_empty(metadata.get("switch"), label="switch"),
        phase_evidence=phase_evidence,
        software=_mapping_or_empty(metadata.get("software"), label="software"),
    )
