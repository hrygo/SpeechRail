"""Versioned pronunciation sets and auditable raw-to-spoken text mapping."""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import threading
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Literal

from speechrail.domain.tts import (
    _EMOJI_RE,
    _MARKDOWN_CLEANUP_RE,
    normalize_tts_text,
)

PRONUNCIATION_SET_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
PRONUNCIATION_REVISION_RE = re.compile(r"^pr_[0-9a-f]{32}$")
PRONUNCIATION_ENTRY_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
_MARKDOWN_CHARS = frozenset("*#`~_>")
_TRAILING_WEAK = frozenset("，,、：:")
_SENTENCE_TERMINATORS = frozenset("。！？!?；;…—.")
EntrySource = Literal["system", "user"]


class PronunciationConflictError(RuntimeError):
    """A conditional set update observed another revision or conflicting rule."""

    code = "pronunciation_conflict"


class PronunciationRevokedError(RuntimeError):
    """A requested pronunciation-set revision is revoked."""

    code = "pronunciation_revoked"


class PronunciationStoreUnavailableError(RuntimeError):
    """The local pronunciation registry cannot be trusted."""

    code = "pronunciation_store_unavailable"


@dataclass(frozen=True, slots=True)
class PronunciationEntry:
    id: str
    surface: str
    spoken: str
    language: str = "auto"
    case_sensitive: bool = True
    word_boundary: bool = False
    source: EntrySource = "user"

    def __post_init__(self) -> None:
        if not PRONUNCIATION_ENTRY_ID_RE.fullmatch(self.id):
            raise ValueError("invalid pronunciation entry id")
        if not self.surface or not self.surface.strip():
            raise ValueError("pronunciation surface must not be blank")
        if not self.spoken or not self.spoken.strip():
            raise ValueError("pronunciation spoken form must not be blank")
        if len(self.surface) > 256 or len(self.spoken) > 256:
            raise ValueError("pronunciation entry exceeds 256 characters")
        if not self.language or len(self.language) > 64:
            raise ValueError("invalid pronunciation language")

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "surface": self.surface,
            "spoken": self.spoken,
            "language": self.language,
            "case_sensitive": self.case_sensitive,
            "word_boundary": self.word_boundary,
            "source": self.source,
        }


@dataclass(frozen=True, slots=True)
class PronunciationSet:
    id: str
    revision: str
    entries: tuple[PronunciationEntry, ...]
    revoked: bool = False

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "revision": self.revision,
            "revoked": self.revoked,
            "entries": [entry.to_dict() for entry in self.entries],
        }


@dataclass(frozen=True, slots=True)
class SpokenSpan:
    spoken_start: int
    spoken_end: int
    raw_start: int
    raw_end: int
    entry_id: str | None = None


@dataclass(frozen=True, slots=True)
class PronunciationHit:
    entry_id: str
    normalized_start: int
    normalized_end: int
    spoken_start: int
    spoken_end: int
    raw_start: int
    raw_end: int


@dataclass(frozen=True, slots=True)
class SpokenText:
    text: str
    raw_sha256: str
    normalized_sha256: str
    spoken_sha256: str
    pronunciation_set_id: str | None
    pronunciation_revision: str | None
    hits: tuple[PronunciationHit, ...]
    spans: tuple[SpokenSpan, ...]

    def summary(self) -> dict[str, object]:
        """Return safe hashes/counts only; never source or spoken text."""

        return {
            "raw_sha256": self.raw_sha256,
            "normalized_sha256": self.normalized_sha256,
            "spoken_sha256": self.spoken_sha256,
            "pronunciation_set_id": self.pronunciation_set_id,
            "pronunciation_revision": self.pronunciation_revision,
            "pronunciation_hit_count": len(self.hits),
        }


def _set_revision(entries: tuple[PronunciationEntry, ...]) -> str:
    canonical = json.dumps(
        [entry.to_dict() for entry in entries],
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return "pr_" + hashlib.sha256(canonical).hexdigest()[:32]


def make_pronunciation_set(
    set_id: str,
    entries: tuple[PronunciationEntry, ...],
) -> PronunciationSet:
    if not PRONUNCIATION_SET_ID_RE.fullmatch(set_id):
        raise ValueError("invalid pronunciation set id")
    ordered = tuple(sorted(entries, key=lambda entry: entry.id))
    seen_ids: set[str] = set()
    seen_rules: dict[tuple[str, str, bool, bool], str] = {}
    for entry in ordered:
        if entry.id in seen_ids:
            raise PronunciationConflictError("duplicate pronunciation entry id")
        seen_ids.add(entry.id)
        surface_key = entry.surface if entry.case_sensitive else entry.surface.casefold()
        rule_key = (
            entry.language.casefold(),
            surface_key,
            entry.case_sensitive,
            entry.word_boundary,
        )
        previous = seen_rules.get(rule_key)
        if previous is not None and previous != entry.spoken:
            raise PronunciationConflictError(
                "conflicting pronunciation entries for the same surface policy"
            )
        seen_rules[rule_key] = entry.spoken
    return PronunciationSet(
        id=set_id,
        revision=_set_revision(ordered),
        entries=ordered,
    )


def _normalization_mapping(raw: str) -> tuple[str, tuple[tuple[int, int], ...]]:
    """Mirror normalize_tts_text while retaining source spans for every codepoint."""

    stage1: list[tuple[str, int, int]] = []
    cursor = 0
    for match in _MARKDOWN_CLEANUP_RE.finditer(raw):
        for index in range(cursor, match.start()):
            stage1.append((raw[index], index, index + 1))
        cursor = match.end()
    for index in range(cursor, len(raw)):
        stage1.append((raw[index], index, index + 1))

    stage1_text = "".join(char for char, _, _ in stage1)
    removed: set[int] = set()
    for match in _EMOJI_RE.finditer(stage1_text):
        removed.update(range(match.start(), match.end()))
    kept = [
        item
        for index, item in enumerate(stage1)
        if index not in removed
    ]

    while kept and kept[0][0].isspace():
        kept.pop(0)
    while kept and kept[-1][0].isspace():
        kept.pop()
    while kept and (
        kept[-1][0].isspace() or kept[-1][0] in _TRAILING_WEAK
    ):
        kept.pop()

    if not kept:
        normalized = ""
        mapping: tuple[tuple[int, int], ...] = ()
    else:
        normalized = "".join(char for char, _, _ in kept)
        mapped = [(start, end) for _, start, end in kept]
        if normalized[-1] not in _SENTENCE_TERMINATORS:
            has_cjk = any("\u4e00" <= char <= "\u9fff" for char in normalized)
            normalized += "。" if has_cjk else "."
            raw_end = kept[-1][2]
            mapped.append((raw_end, raw_end))
        mapping = tuple(mapped)

    expected = normalize_tts_text(raw)
    if normalized != expected:
        raise ValueError("normalization_mapping_policy_mismatch")
    return normalized, mapping


def _boundary_ok(text: str, start: int, end: int) -> bool:
    def word_char(char: str) -> bool:
        return char.isalnum() or char == "_"

    if start > 0 and word_char(text[start - 1]):
        return False
    if end < len(text) and word_char(text[end]):
        return False
    return True


def _candidate_at(
    text: str,
    start: int,
    entry: PronunciationEntry,
    *,
    language: str,
) -> int | None:
    if entry.language not in {"auto", language} and language != "auto":
        return None
    end = start + len(entry.surface)
    if end > len(text):
        return None
    segment = text[start:end]
    if entry.case_sensitive:
        matches = segment == entry.surface
    else:
        matches = segment.casefold() == entry.surface.casefold()
    if not matches:
        return None
    if entry.word_boundary and not _boundary_ok(text, start, end):
        return None
    return end


def apply_pronunciation(
    raw_text: str,
    pronunciation_set: PronunciationSet | None = None,
    *,
    language: str = "auto",
) -> SpokenText:
    """Normalize and deterministically rewrite text while retaining raw spans."""

    if pronunciation_set is not None and pronunciation_set.revoked:
        raise PronunciationRevokedError(
            f"pronunciation set is revoked: {pronunciation_set.id}"
        )

    normalized, mapping = _normalization_mapping(raw_text)
    if not normalized:
        return SpokenText(
            text="",
            raw_sha256=hashlib.sha256(raw_text.encode()).hexdigest(),
            normalized_sha256=hashlib.sha256(b"").hexdigest(),
            spoken_sha256=hashlib.sha256(b"").hexdigest(),
            pronunciation_set_id=(
                pronunciation_set.id if pronunciation_set is not None else None
            ),
            pronunciation_revision=(
                pronunciation_set.revision if pronunciation_set is not None else None
            ),
            hits=(),
            spans=(),
        )

    entries = () if pronunciation_set is None else pronunciation_set.entries
    pieces: list[str] = []
    spans: list[SpokenSpan] = []
    hits: list[PronunciationHit] = []
    spoken_cursor = 0
    position = 0
    while position < len(normalized):
        candidates: list[tuple[int, PronunciationEntry]] = []
        for entry in entries:
            end = _candidate_at(
                normalized,
                position,
                entry,
                language=language,
            )
            if end is not None:
                candidates.append((end, entry))
        if candidates:
            end, entry = min(
                candidates,
                key=lambda item: (
                    -(item[0] - position),
                    item[1].id,
                ),
            )
            raw_start = mapping[position][0]
            raw_end = mapping[end - 1][1]
            pieces.append(entry.spoken)
            next_cursor = spoken_cursor + len(entry.spoken)
            spans.append(
                SpokenSpan(
                    spoken_cursor,
                    next_cursor,
                    raw_start,
                    raw_end,
                    entry.id,
                )
            )
            hits.append(
                PronunciationHit(
                    entry_id=entry.id,
                    normalized_start=position,
                    normalized_end=end,
                    spoken_start=spoken_cursor,
                    spoken_end=next_cursor,
                    raw_start=raw_start,
                    raw_end=raw_end,
                )
            )
            spoken_cursor = next_cursor
            position = end
            continue

        char = normalized[position]
        raw_start, raw_end = mapping[position]
        pieces.append(char)
        next_cursor = spoken_cursor + 1
        spans.append(
            SpokenSpan(
                spoken_cursor,
                next_cursor,
                raw_start,
                raw_end,
            )
        )
        spoken_cursor = next_cursor
        position += 1

    spoken = "".join(pieces)
    return SpokenText(
        text=spoken,
        raw_sha256=hashlib.sha256(raw_text.encode()).hexdigest(),
        normalized_sha256=hashlib.sha256(normalized.encode()).hexdigest(),
        spoken_sha256=hashlib.sha256(spoken.encode()).hexdigest(),
        pronunciation_set_id=(
            pronunciation_set.id if pronunciation_set is not None else None
        ),
        pronunciation_revision=(
            pronunciation_set.revision if pronunciation_set is not None else None
        ),
        hits=tuple(hits),
        spans=tuple(spans),
    )


class PronunciationRegistry:
    """Atomic local store for immutable pronunciation-set revisions."""

    def __init__(self, path: Path | None = None) -> None:
        self._path = Path(
            path or (Path.home() / ".speechrail" / "pronunciation_sets.json")
        )
        self._lock = threading.RLock()

    def _load_locked(self) -> dict[str, dict[str, PronunciationSet]]:
        if not self._path.exists():
            return {}
        try:
            if self._path.is_symlink() or not self._path.is_file():
                raise ValueError("unsafe pronunciation registry")
            data = json.loads(self._path.read_text(encoding="utf-8"))
            if not isinstance(data, list):
                raise ValueError("pronunciation registry must be a list")
            result: dict[str, dict[str, PronunciationSet]] = {}
            for raw_set in data:
                if not isinstance(raw_set, dict):
                    raise ValueError("invalid pronunciation set record")
                set_id = raw_set.get("id")
                revisions = raw_set.get("revisions")
                if not isinstance(set_id, str) or not isinstance(revisions, list):
                    raise ValueError("invalid pronunciation set record")
                parsed: dict[str, PronunciationSet] = {}
                current_revision: str | None = None
                for raw_revision in revisions:
                    if not isinstance(raw_revision, dict):
                        raise ValueError("invalid pronunciation revision")
                    raw_entries = raw_revision.get("entries")
                    revision = raw_revision.get("revision")
                    if not isinstance(raw_entries, list) or not isinstance(revision, str):
                        raise ValueError("invalid pronunciation revision")
                    entries = tuple(
                        PronunciationEntry(**entry)
                        for entry in raw_entries
                        if isinstance(entry, dict)
                    )
                    value = make_pronunciation_set(set_id, entries)
                    if value.revision != revision:
                        raise ValueError("pronunciation revision mismatch")
                    parsed[revision] = replace(
                        value,
                        revoked=bool(raw_revision.get("revoked", False)),
                    )
                    if raw_revision.get("current") is True:
                        if current_revision is not None:
                            raise ValueError("multiple current pronunciation revisions")
                        current_revision = revision
                if parsed and current_revision is None:
                    current_revision = next(reversed(parsed))
                if current_revision is not None:
                    current = parsed.pop(current_revision)
                    parsed[current_revision] = current
                result[set_id] = parsed
            return result
        except Exception as exc:
            raise PronunciationStoreUnavailableError(
                "pronunciation registry is unavailable"
            ) from exc

    def _save_locked(self, data: dict[str, dict[str, PronunciationSet]]) -> None:
        try:
            if self._path.parent.is_symlink():
                raise OSError("unsafe pronunciation registry parent")
            self._path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            payload = json.dumps(
                [
                    {
                        "id": set_id,
                        "revisions": [
                            {
                                **value.to_dict(),
                                "current": revision == next(reversed(revisions)),
                            }
                            for revision, value in sorted(revisions.items())
                        ],
                    }
                    for set_id, revisions in sorted(data.items())
                ],
                ensure_ascii=False,
                indent=2,
            ).encode()
            fd, tmp_name = tempfile.mkstemp(
                prefix=f".{self._path.name}.",
                suffix=".tmp",
                dir=self._path.parent,
            )
            tmp = Path(tmp_name)
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                tmp.chmod(0o600)
                tmp.replace(self._path)
                dir_fd = os.open(self._path.parent, os.O_RDONLY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
            finally:
                tmp.unlink(missing_ok=True)
        except Exception as exc:
            raise PronunciationStoreUnavailableError(
                "pronunciation registry cannot be persisted"
            ) from exc

    def list_sets(self) -> tuple[PronunciationSet, ...]:
        with self._lock:
            data = self._load_locked()
            current: list[PronunciationSet] = []
            for revisions in data.values():
                if revisions:
                    current.append(revisions[next(reversed(revisions))])
            return tuple(sorted(current, key=lambda value: value.id))

    def get(
        self,
        set_id: str,
        *,
        revision: str | None = None,
    ) -> PronunciationSet:
        with self._lock:
            data = self._load_locked()
            revisions = data.get(set_id)
            if not revisions:
                raise KeyError(set_id)
            if revision is None:
                value = revisions[next(reversed(revisions))]
            else:
                value = revisions.get(revision)
                if value is None:
                    raise KeyError(revision)
            if value.revoked:
                raise PronunciationRevokedError(
                    f"pronunciation revision is revoked: {value.revision}"
                )
            return value

    def put(
        self,
        set_id: str,
        entries: tuple[PronunciationEntry, ...],
        *,
        expected_revision: str | None,
    ) -> PronunciationSet:
        candidate = make_pronunciation_set(set_id, entries)
        with self._lock:
            data = self._load_locked()
            revisions = dict(data.get(set_id, {}))
            current = revisions[next(reversed(revisions))] if revisions else None
            current_revision = current.revision if current is not None else None
            if current_revision != expected_revision:
                raise PronunciationConflictError(
                    "pronunciation set revision changed"
                )
            revisions[candidate.revision] = candidate
            data[set_id] = revisions
            self._save_locked(data)
            return candidate

    def revoke(
        self,
        set_id: str,
        revision: str,
    ) -> PronunciationSet:
        with self._lock:
            data = self._load_locked()
            revisions = dict(data.get(set_id, {}))
            value = revisions.get(revision)
            if value is None:
                raise KeyError(revision)
            revoked = replace(value, revoked=True)
            revisions[revision] = revoked
            data[set_id] = revisions
            self._save_locked(data)
            return revoked

    def delete(self, set_id: str) -> None:
        with self._lock:
            data = self._load_locked()
            if set_id not in data:
                raise KeyError(set_id)
            del data[set_id]
            self._save_locked(data)


_GLOBAL_PRONUNCIATION_REGISTRY = PronunciationRegistry()


def get_pronunciation_registry() -> PronunciationRegistry:
    return _GLOBAL_PRONUNCIATION_REGISTRY
