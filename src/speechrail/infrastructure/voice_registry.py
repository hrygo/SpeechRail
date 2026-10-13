"""File-backed voice catalog, revisions, atomic commits and reader leases."""

from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import random
import re
import tempfile
import threading
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from copy import deepcopy
from dataclasses import replace
from pathlib import Path
from typing import Any

from speechrail.domain.file_locks import exclusive_file_lock
from speechrail.domain.tts import (
    SYSTEM_VOICE_PROFILES,
    VOICE_ALIASES,
    VOICE_ID_RE,
    VOICE_REVISION_RE,
    VoiceAlreadyExistsError,
    VoiceInUseError,
    VoiceProfile,
    VoiceRevisionConflictError,
    VoiceRevokedError,
    VoiceStoreUnavailableError,
    VoiceUpdateUnsupportedError,
    _voice_revision,
    ephemeral_voice_profile,
    resolve_voice,
    voice_revision_for_clone,
)
from speechrail.domain.voice_creation import VoiceCreation
from speechrail.domain.voice_preview import normalize_preview_locale
from speechrail.domain.voice_validation import VoiceValidationRepository

logger = logging.getLogger(__name__)

_AUXILIARY_NAMES = frozenset(
    {
        "voice_validations.json",
        "voice_clone_idempotency.json",
        "voice_design_idempotency.json",
        "voice_design_candidates.json",
        "voice_design_candidates",
    }
)


def _atomic_write_bytes(target: Path, payload: bytes, *, mode: int) -> Path:
    """Write ``payload`` to ``target`` atomically with an explicit mode.

    The payload is written to a temp file in the same directory, fsync'd, then
    ``os.replace``'d onto the target so a hard kill or write failure can never
    leave a half-written file. The final file is chmod'd to ``mode`` (e.g. 0600
    for private voice metadata/audio).
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=target.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(mode)
        tmp_path.replace(target)
        dir_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        with suppress(OSError):
            tmp_path.unlink(missing_ok=True)
        raise
    return target


class FileVoiceRegistry:
    """Thread-safe registry with atomic metadata commits and reader leases."""

    def __init__(
        self,
        storage_path: Path,
        voices_dir: Path,
    ) -> None:
        self._storage_path = Path(storage_path)
        self._voices_dir = Path(voices_dir)
        self._validation_store = VoiceValidationRepository(
            self.artifact_path("voice_validations.json")
        )
        self._lock = threading.RLock()
        self._last_loaded_mtime_ns = 0
        self._custom_voices: dict[str, VoiceProfile] = {}
        self._revision_history: dict[str, dict[str, VoiceProfile]] = {}
        self._store_error: str | None = None
        self._pending_profiles: dict[str, VoiceProfile] | None = None
        self._pending_revision_history: dict[str, dict[str, VoiceProfile]] | None = None
        self._audio_readers: dict[Path, int] = {}
        self._retired_audio: set[Path] = set()

    @classmethod
    def open(cls, storage_path: Path, voices_dir: Path) -> FileVoiceRegistry:
        """Explicitly load one local store at the composition boundary."""
        if storage_path.name != "custom_voices.json":
            for name in _AUXILIARY_NAMES:
                legacy = storage_path.with_name(name)
                if legacy.exists() or legacy.is_symlink():
                    raise VoiceStoreUnavailableError(
                        "legacy voice artifact ownership is ambiguous; "
                        "explicit storage layout resolution is required"
                    )
        registry = cls(storage_path, voices_dir)
        registry.load()
        return registry

    def artifact_path(self, name: str) -> Path:
        """Keep the production layout; namespace alternate metadata files."""
        if name not in _AUXILIARY_NAMES:
            raise ValueError("unknown voice store artifact")
        if self._storage_path.name == "custom_voices.json":
            return self._storage_path.with_name(name)
        return self._storage_path.with_name(f"{self._storage_path.name}.{name}")

    def load(self) -> None:
        """Read the durable generation, retaining the existing fail-closed state."""
        self._load_custom_voices()

    @contextmanager
    def _process_lock(self) -> Iterator[None]:
        """Serialize durable voice registry transactions across processes."""
        with exclusive_file_lock(
            self._storage_path,
            unavailable_error=VoiceStoreUnavailableError,
        ):
            yield

    def _mark_unavailable(self, exc: BaseException) -> None:
        self._store_error = "custom voice registry is unavailable"
        logger.warning("failed to load custom voices: %s", type(exc).__name__)

    def _load_custom_voices(self) -> None:
        with self._lock:
            # Preserve fail-closed construction for an unsafe parent path.  A
            # sibling lock cannot be opened through a symlinked directory, so
            # let the loader record the unavailable state before attempting
            # the process lock.
            if self._storage_path.parent.is_symlink():
                self._load_custom_voices_locked()
                return
            try:
                with self._process_lock():
                    self._load_custom_voices_locked()
            except VoiceStoreUnavailableError as exc:
                self._mark_unavailable(exc)

    def _load_custom_voices_locked(self) -> None:
        if self._storage_path.parent.is_symlink():
            self._mark_unavailable(ValueError("custom voice registry parent must not be a symlink"))
            return
        if not self._storage_path.exists():
            if self._storage_path.is_symlink():
                self._mark_unavailable(ValueError("custom voice registry symlink is broken"))
                return
            self._custom_voices = {}
            self._revision_history = {}
            self._last_loaded_mtime_ns = 0
            self._store_error = None
            return
        if not self._storage_path.is_file():
            self._mark_unavailable(ValueError("custom voice registry is not a file"))
            return
        try:
            stat = self._storage_path.stat()
            if self._storage_path.is_symlink():
                raise ValueError("custom voice registry must not be a symlink")
            if stat.st_mode & 0o077:
                self._storage_path.chmod(0o600)
            data = json.loads(self._storage_path.read_text(encoding="utf-8"))
            if not isinstance(data, list):
                raise ValueError("custom voice registry must be a JSON list")
            loaded: dict[str, VoiceProfile] = {}
            loaded_history: dict[str, dict[str, VoiceProfile]] = {}
            for item in data:
                profile = self._profile_from_record(item)
                if profile.id in loaded:
                    raise ValueError(f"duplicate custom voice id: {profile.id}")
                history: dict[str, VoiceProfile] = {}
                if not isinstance(item, dict):
                    raise ValueError("custom voice record must be an object")
                raw_history = item.get("_revisions", [])
                if not isinstance(raw_history, list):
                    raise ValueError("custom voice revision history must be a list")
                for raw_revision in raw_history:
                    historic = self._profile_from_record(raw_revision)
                    if historic.id != profile.id or historic.revision is None:
                        raise ValueError("custom voice revision history is invalid")
                    history[historic.revision] = historic
                if profile.revision is not None:
                    history[profile.revision] = profile
                loaded[profile.id] = profile
                loaded_history[profile.id] = history
        except Exception as exc:
            self._last_loaded_mtime_ns = self._safe_mtime_ns()
            self._mark_unavailable(exc)
            return
        self._custom_voices = loaded
        self._revision_history = loaded_history
        self._last_loaded_mtime_ns = stat.st_mtime_ns
        self._store_error = None

    def _safe_mtime_ns(self) -> int:
        try:
            return self._storage_path.stat().st_mtime_ns
        except OSError:
            return 0

    def _check_reload(self) -> None:
        with self._lock:
            if self._storage_path.parent.is_symlink():
                self._mark_unavailable(
                    ValueError("custom voice registry parent must not be a symlink")
                )
                return
            if not self._storage_path.exists():
                if self._storage_path.is_symlink():
                    self._mark_unavailable(ValueError("custom voice registry symlink is broken"))
                    return
                if self._last_loaded_mtime_ns or self._custom_voices:
                    self._custom_voices = {}
                    self._revision_history = {}
                    self._last_loaded_mtime_ns = 0
                    self._store_error = None
                return
            if not self._storage_path.is_file():
                self._mark_unavailable(ValueError("custom voice registry is not a file"))
                return
            try:
                mtime_ns = self._storage_path.stat().st_mtime_ns
            except OSError as exc:
                self._mark_unavailable(exc)
                return
            if mtime_ns != self._last_loaded_mtime_ns:
                self._load_custom_voices_locked()

    def _ensure_available_locked(self, *, reload: bool = False) -> None:
        if reload:
            self._load_custom_voices_locked()
        else:
            self._check_reload()
        if self._store_error is not None:
            raise VoiceStoreUnavailableError(self._store_error)

    def _profile_from_record(self, item: object) -> VoiceProfile:
        if not isinstance(item, dict):
            raise ValueError("custom voice record must be an object")
        raw_id = item.get("id")
        if not isinstance(raw_id, str):
            raise ValueError("custom voice id must be a string")
        vid = raw_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("custom voice id has invalid format")
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"custom voice id is reserved: {vid}")

        name = item.get("name", vid)
        instruction = item.get("instruction", "")
        if not isinstance(name, str) or not isinstance(instruction, str):
            raise ValueError("custom voice name and instruction must be strings")
        raw_mode = item.get("mode")
        if raw_mode is None:
            raw_mode = "instruction" if instruction.strip() else "clone"
        if not isinstance(raw_mode, str) or raw_mode not in {"instruction", "clone"}:
            raise ValueError("custom voice mode is invalid")

        ref_text = item.get("ref_text")
        if ref_text is not None and not isinstance(ref_text, str):
            raise ValueError("custom voice ref_text must be a string")
        audio_raw = item.get("audio_path")
        if audio_raw is not None and not isinstance(audio_raw, str):
            raise ValueError("custom voice audio_path must be a string")
        audio_path: str | None = None
        if audio_raw is not None:
            audio_path = str(self._controlled_audio_path(audio_raw, vid, require_exists=True))
        if raw_mode == "clone" and (ref_text is None or not ref_text.strip() or audio_path is None):
            raise ValueError("clone voice record is incomplete")

        seed = item.get("seed", 42)
        if type(seed) is not int or not 0 <= seed <= 2**32 - 1:
            raise ValueError("custom voice seed is invalid")
        temperature = item.get("temperature", 0.1)
        created_at = item.get("created_at", 0.0)
        duration_seconds = item.get("duration_seconds", 0.0)
        for value, field in (
            (temperature, "temperature"),
            (created_at, "created_at"),
            (duration_seconds, "duration_seconds"),
        ):
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                or float(value) < 0
            ):
                raise ValueError(f"custom voice {field} is invalid")
        quality_raw = item.get("quality")
        quality: dict[str, Any] | None = None
        if quality_raw is not None:
            if not isinstance(quality_raw, dict):
                raise ValueError("custom voice quality must be an object")
            quality = quality_raw
        creation_raw = item.get("creation")
        creation = None if creation_raw is None else VoiceCreation.model_validate(creation_raw)
        if creation is not None and raw_mode != "clone":
            raise ValueError("generated reference provenance requires clone mode")
        revision_raw = item.get("revision")
        revision: str | None = None
        if revision_raw is not None:
            if not isinstance(revision_raw, str) or not VOICE_REVISION_RE.fullmatch(revision_raw):
                raise ValueError("custom voice revision is invalid")
            revision = revision_raw
        revoked = item.get("revoked", False)
        if not isinstance(revoked, bool):
            raise ValueError("custom voice revoked flag is invalid")
        # Display-only metadata: an absent, malformed or unsupported value
        # degrades to "no default preview" instead of failing the whole load
        # or guessing a language from the voice's name or reference text.
        preview_locale = normalize_preview_locale(item.get("preview_locale"))
        return VoiceProfile(
            id=vid,
            name=name,
            instruction=instruction,
            seed=seed,
            temperature=float(temperature),
            is_default=False,
            is_system=False,
            created_at=float(created_at),
            mode=raw_mode,
            ref_text=ref_text,
            audio_path=audio_path,
            duration_seconds=float(duration_seconds),
            quality=quality,
            creation=creation,
            revision=revision,
            revoked=revoked,
            preview_locale=preview_locale,
        )

    def _controlled_audio_path(self, raw_path: str, voice_id: str, *, require_exists: bool) -> Path:
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            raise ValueError("voice audio path must be absolute")
        if self._voices_dir.is_symlink():
            raise ValueError("voices directory must not be a symlink")
        try:
            resolved = candidate.resolve(strict=False)
            voices_root = self._voices_dir.resolve()
        except OSError as exc:
            raise ValueError("voice audio path cannot be resolved") from exc
        if resolved.parent != voices_root:
            raise ValueError("voice audio path escapes voices directory")
        if candidate.is_symlink():
            raise ValueError("voice audio path must not be a symlink")
        if not (
            resolved.name == f"{voice_id}.wav"
            or re.fullmatch(
                rf"{re.escape(voice_id)}\.(?:[0-9a-f]{{32}}|[0-9a-f-]{{36}})\.wav",
                resolved.name,
                flags=re.IGNORECASE,
            )
        ):
            raise ValueError("voice audio path has an invalid filename")
        if require_exists and (not resolved.is_file() or not candidate.is_file()):
            raise ValueError("voice audio file is missing")
        if require_exists:
            try:
                mode = resolved.stat().st_mode
                if mode & 0o077:
                    resolved.chmod(0o600)
            except OSError as exc:
                raise ValueError("voice audio file permissions are unsafe") from exc
        return resolved

    def _prepare_store_dirs_locked(self) -> None:
        try:
            if self._storage_path.parent.is_symlink():
                raise OSError("custom voice registry parent must not be a symlink")
            if self._voices_dir.is_symlink():
                raise OSError("voices directory must not be a symlink")
            self._storage_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._voices_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            if self._voices_dir.stat().st_mode & 0o077:
                self._voices_dir.chmod(0o700)
        except OSError as exc:
            raise VoiceStoreUnavailableError("custom voice store cannot be prepared") from exc

    def _save_custom_voices(self) -> None:
        # Atomic (temp + fsync + rename) and 0600 so a hard kill during a write
        # cannot leave a half-written registry.  ``_pending_profiles`` lets a
        # caller persist a private candidate before publishing it in memory.
        profiles = (
            self._pending_profiles if self._pending_profiles is not None else self._custom_voices
        )
        histories = (
            self._pending_revision_history
            if self._pending_revision_history is not None
            else self._revision_history
        )
        self._prepare_store_dirs_locked()
        data: list[dict[str, Any]] = []
        for profile in profiles.values():
            record = profile.to_dict()
            history = histories.get(profile.id, {})
            if history:
                record["_revisions"] = [
                    historic.to_dict() for _, historic in sorted(history.items())
                ]
            data.append(record)
        payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        written = _atomic_write_bytes(self._storage_path, payload, mode=0o600)
        self._last_loaded_mtime_ns = written.stat().st_mtime_ns

    def _storage_state(self) -> tuple[bool, bytes | None]:
        try:
            if not self._storage_path.is_file():
                return False, None
            return True, self._storage_path.read_bytes()
        except OSError:
            return True, None

    def _commit_candidate(
        self,
        candidate: dict[str, VoiceProfile],
        *,
        history_candidate: dict[str, dict[str, VoiceProfile]] | None = None,
        new_audio: Path | None = None,
    ) -> None:
        previous = self._custom_voices
        previous_history = self._revision_history
        next_history = (
            history_candidate if history_candidate is not None else self._revision_history
        )
        before = self._storage_state()
        self._pending_profiles = candidate
        self._pending_revision_history = next_history
        try:
            self._save_custom_voices()
        except BaseException as exc:
            self._pending_profiles = None
            self._pending_revision_history = None
            self._custom_voices = previous
            self._revision_history = previous_history
            after = self._storage_state()
            safe_to_remove = after == before and (not before[0] or before[1] is not None)
            if new_audio is not None and safe_to_remove:
                with suppress(OSError):
                    new_audio.unlink(missing_ok=True)
            elif new_audio is not None or after != before:
                self._mark_unavailable(RuntimeError("registry commit outcome is uncertain"))
                raise VoiceStoreUnavailableError(
                    "custom voice registry commit is uncertain"
                ) from exc
            raise
        finally:
            self._pending_profiles = None
            self._pending_revision_history = None
        self._custom_voices = candidate
        self._revision_history = next_history
        self._store_error = None

    def _history_candidate_locked(
        self,
        voice_id: str,
        *profiles: VoiceProfile | None,
    ) -> dict[str, dict[str, VoiceProfile]]:
        history = {key: dict(value) for key, value in self._revision_history.items()}
        revisions = dict(history.get(voice_id, {}))
        for profile in profiles:
            if profile is not None and profile.revision is not None:
                revisions[profile.revision] = profile
        history[voice_id] = revisions
        return history

    def _retire_audio_locked(self, raw_path: str | None, voice_id: str) -> None:
        if raw_path is None:
            return
        path = self._controlled_audio_path(raw_path, voice_id, require_exists=False)
        if not path.exists():
            return
        if self._audio_readers.get(path, 0) > 0:
            self._retired_audio.add(path)
            return
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            self._retired_audio.add(path)
            logger.warning("failed to clean retired voice audio: %s", type(exc).__name__)

    def _cleanup_retired_locked(self) -> None:
        for path in tuple(self._retired_audio):
            if self._audio_readers.get(path, 0) > 0:
                continue
            try:
                path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("failed to clean retired voice audio: %s", type(exc).__name__)
                continue
            self._retired_audio.discard(path)

    def _voice_has_readers_locked(self, voice_id: str) -> bool:
        prefix = f"{voice_id}."
        legacy = f"{voice_id}.wav"
        for path, readers in self._audio_readers.items():
            if readers > 0 and (path.name == legacy or path.name.startswith(prefix)):
                return True
        return False

    def snapshot_profiles(self) -> tuple[VoiceProfile, ...]:
        """Detach one catalog generation under the same registry read lock."""
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            return tuple(
                deepcopy(profile)
                for profile in (
                    *SYSTEM_VOICE_PROFILES.values(),
                    *self._custom_voices.values(),
                )
            )

    @property
    def storage_path(self) -> Path:
        """Return the private metadata path used to derive sibling stores."""

        return self._storage_path

    @property
    def voices_dir(self) -> Path:
        """Return the private publication asset directory."""

        return self._voices_dir

    def list_profiles(self) -> list[VoiceProfile]:
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            system = list(SYSTEM_VOICE_PROFILES.values())
            custom = sorted(self._custom_voices.values(), key=lambda v: v.created_at, reverse=True)
            return system + custom

    def get_profile(self, voice: str) -> VoiceProfile:
        """Return one voice profile, including an unpublished design candidate.

        An unpublished VoiceDesign candidate is exposed to internal synthesis
        through :func:`use_voice_profile` only.  Every in-process consumer of a
        voice must therefore resolve candidates here as well, exactly like
        :meth:`lease_profile` does, or a design id that is not in the durable
        store fails closed with ``unknown preset voice``.
        """
        resolved = resolve_voice(voice)
        ephemeral = ephemeral_voice_profile(resolved)
        if ephemeral is not None:
            return ephemeral
        if resolved in SYSTEM_VOICE_PROFILES:
            return SYSTEM_VOICE_PROFILES[resolved]
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            if resolved in self._custom_voices:
                return self._custom_voices[resolved]
        raise ValueError(f"unknown preset voice: {voice}")

    @contextmanager
    def lease_profile(
        self, voice: str, *, expected_revision: str | None = None
    ) -> Iterator[VoiceProfile]:
        """Lease an immutable profile snapshot, optionally pinned by acoustic revision."""

        if expected_revision is not None and not VOICE_REVISION_RE.fullmatch(expected_revision):
            raise ValueError("invalid expected voice revision")
        resolved = resolve_voice(voice)
        ephemeral = ephemeral_voice_profile(resolved)
        if ephemeral is not None:
            if expected_revision is not None and ephemeral.revision != expected_revision:
                raise VoiceRevisionConflictError(f"voice revision changed for {ephemeral.id}")
            yield ephemeral
            return
        audio_path: Path | None = None
        with self._lock, self._process_lock():
            if resolved in SYSTEM_VOICE_PROFILES:
                profile = SYSTEM_VOICE_PROFILES[resolved]
            else:
                self._ensure_available_locked(reload=True)
                custom_profile = self._custom_voices.get(resolved)
                if custom_profile is None:
                    raise ValueError(f"unknown preset voice: {voice}")
                profile = custom_profile
            if expected_revision is not None and profile.revision != expected_revision:
                raise VoiceRevisionConflictError(f"voice revision changed for {profile.id}")
            if not profile.is_system and profile.revoked:
                raise VoiceRevokedError(f"voice revision is revoked: {profile.id}")
            if not profile.is_system and profile.audio_path is not None:
                try:
                    audio_path = self._controlled_audio_path(
                        profile.audio_path, profile.id, require_exists=True
                    )
                except ValueError as exc:
                    raise VoiceStoreUnavailableError("custom voice audio is unavailable") from exc
                self._audio_readers[audio_path] = self._audio_readers.get(audio_path, 0) + 1
        try:
            yield profile
        finally:
            if audio_path is not None:
                with self._lock:
                    readers = self._audio_readers.get(audio_path, 0)
                    if readers <= 1:
                        self._audio_readers.pop(audio_path, None)
                    else:
                        self._audio_readers[audio_path] = readers - 1
                    self._cleanup_retired_locked()

    def create_custom_profile(
        self,
        name: str,
        instruction: str,
        voice_id: str | None = None,
        seed: int | None = None,
    ) -> VoiceProfile:
        if not name.strip():
            raise ValueError("voice name must not be empty")
        if not instruction.strip():
            raise ValueError("voice instruction must not be empty")
        if len(instruction.strip()) > 10_000:
            raise ValueError("voice instruction exceeds the 10000 character limit")
        if voice_id:
            vid = voice_id.strip().lower()
            if not VOICE_ID_RE.fullmatch(vid):
                raise ValueError("voice_id must match regex ^[a-zA-Z0-9_-]{1,64}$")
        else:
            vid = f"custom_{int(time.time())}_{uuid.uuid4().hex[:4]}"
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"cannot override system voice ID: {vid}")
        if seed is not None and (type(seed) is not int or not 0 <= seed <= 2**32 - 1):
            raise ValueError("voice seed must be between 0 and 4294967295")

        resolved_seed = seed if seed is not None else random.randint(1000, 999999)
        instruction_text = instruction.strip()
        profile = VoiceProfile(
            id=vid,
            name=name.strip(),
            instruction=instruction_text,
            seed=resolved_seed,
            temperature=0.1,
            is_default=False,
            is_system=False,
            created_at=time.time(),
            mode="instruction",
            revision=_voice_revision(
                mode="instruction",
                instruction=instruction_text,
                seed=resolved_seed,
                temperature=0.1,
            ),
        )
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            previous = self._custom_voices.get(vid)
            candidate = dict(self._custom_voices)
            candidate[vid] = profile
            history = self._history_candidate_locked(vid, previous, profile)
            self._commit_candidate(candidate, history_candidate=history)
            if previous is not None and previous.revision is None:
                self._retire_audio_locked(previous.audio_path, vid)
            return profile

    def create_cloned_profile(
        self,
        *,
        name: str,
        ref_text: str,
        audio_bytes: bytes,
        voice_id: str | None = None,
        duration_seconds: float,
        quality: dict[str, Any] | None = None,
        creation: VoiceCreation | None = None,
        create_only: bool = False,
    ) -> VoiceProfile:
        if not name.strip():
            raise ValueError("voice name must not be empty")
        if not ref_text.strip():
            raise ValueError("ref_text must not be empty")
        if voice_id:
            vid = voice_id.strip().lower()
            if not VOICE_ID_RE.fullmatch(vid):
                raise ValueError("voice_id must match regex ^[a-zA-Z0-9_-]{1,64}$")
        else:
            vid = f"clone_{int(time.time())}_{uuid.uuid4().hex[:6]}"
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"cannot override system voice ID: {vid}")
        if (
            isinstance(duration_seconds, bool)
            or not isinstance(duration_seconds, (int, float))
            or not math.isfinite(float(duration_seconds))
            or duration_seconds < 0
        ):
            raise ValueError("duration_seconds must be a non-negative number")
        if quality is not None and not isinstance(quality, dict):
            raise ValueError("quality must be an object")
        if creation is not None and not isinstance(creation, VoiceCreation):
            raise ValueError("creation must be validated voice provenance")
        if creation is not None and (
            creation.reference_audio_sha256 != hashlib.sha256(audio_bytes).hexdigest()
            or creation.reference_text_sha256
            != hashlib.sha256(ref_text.strip().encode()).hexdigest()
        ):
            raise ValueError("reference does not match voice provenance")

        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            # This check shares the metadata commit lock; the HTTP preflight
            # alone cannot protect against concurrent registration of the ID.
            if create_only and vid in self._custom_voices:
                raise VoiceAlreadyExistsError("target voice already exists")
            self._prepare_store_dirs_locked()
            target_file = (self._voices_dir / f"{vid}.{uuid.uuid4().hex}.wav").resolve()
            self._controlled_audio_path(str(target_file), vid, require_exists=False)
            _atomic_write_bytes(target_file, audio_bytes, mode=0o600)
            previous = self._custom_voices.get(vid)
            profile = VoiceProfile(
                id=vid,
                name=name.strip(),
                instruction="",
                seed=42,
                temperature=0.1,
                is_default=False,
                is_system=False,
                created_at=time.time(),
                mode="clone",
                ref_text=ref_text.strip(),
                audio_path=str(target_file),
                duration_seconds=round(float(duration_seconds), 2),
                quality=quality,
                creation=creation,
                revision=voice_revision_for_clone(
                    ref_text=ref_text,
                    audio_bytes=audio_bytes,
                    creation=creation,
                ),
            )
            candidate = dict(self._custom_voices)
            candidate[vid] = profile
            history = self._history_candidate_locked(vid, previous, profile)
            self._commit_candidate(
                candidate,
                history_candidate=history,
                new_audio=target_file,
            )
            if previous is not None and previous.revision is None:
                self._retire_audio_locked(previous.audio_path, vid)
            return profile

    def update_custom_profile(
        self,
        voice_id: str,
        *,
        name: str | None = None,
        instruction: str | None = None,
        seed: int | None = None,
        expected_revision: str | None = None,
    ) -> VoiceProfile:
        """Atomically update metadata; acoustic mutations may be revision-pinned."""

        if expected_revision is not None and not VOICE_REVISION_RE.fullmatch(expected_revision):
            raise ValueError("invalid expected voice revision")

        if not isinstance(voice_id, str):
            raise ValueError("invalid voice ID format")
        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise VoiceUpdateUnsupportedError(f"system voice cannot be updated: {vid}")
        if name is None and instruction is None and seed is None:
            raise ValueError("at least one voice field must be provided")

        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            profile = self._custom_voices.get(vid)
            if profile is None:
                raise KeyError(f"custom voice not found: {vid}")
            if expected_revision is not None and profile.revision != expected_revision:
                raise VoiceRevisionConflictError(f"voice revision changed for {profile.id}")
            if profile.mode == "clone" and (instruction is not None or seed is not None):
                raise VoiceUpdateUnsupportedError("clone voice instruction and seed are immutable")

            next_name = profile.name
            if name is not None:
                if not isinstance(name, str) or not name.strip():
                    raise ValueError("voice name must not be empty")
                next_name = name.strip()

            next_instruction = profile.instruction
            if instruction is not None:
                if not isinstance(instruction, str) or not instruction.strip():
                    raise ValueError("voice instruction must not be empty")
                if len(instruction.strip()) > 10_000:
                    raise ValueError("voice instruction exceeds the 10000 character limit")
                next_instruction = instruction.strip()

            next_seed = profile.seed
            if seed is not None:
                if type(seed) is not int or not 0 <= seed <= 2**32 - 1:
                    raise ValueError("voice seed must be between 0 and 4294967295")
                next_seed = seed

            acoustic_changed = next_instruction != profile.instruction or next_seed != profile.seed
            next_revision = profile.revision
            if acoustic_changed:
                next_revision = _voice_revision(
                    mode=profile.mode,
                    instruction=next_instruction,
                    seed=next_seed,
                    temperature=profile.temperature,
                    ref_text=profile.ref_text,
                    reference_audio_sha256=(
                        profile.creation.reference_audio_sha256
                        if profile.creation is not None
                        else None
                    ),
                    creation=profile.creation,
                )
            updated = replace(
                profile,
                name=next_name,
                instruction=next_instruction,
                seed=next_seed,
                revision=next_revision,
                revoked=False if acoustic_changed else profile.revoked,
            )
            candidate = dict(self._custom_voices)
            candidate[vid] = updated
            history = (
                self._history_candidate_locked(vid, profile, updated)
                if acoustic_changed
                else self._revision_history
            )
            self._commit_candidate(candidate, history_candidate=history)
            return updated

    def update_quality_validation(
        self,
        voice_id: str,
        validation: dict[str, Any],
        *,
        expected_revision: str | None = None,
    ) -> VoiceProfile:
        """Persist output evidence without changing the acoustic voice record.

        The method remains as a narrow compatibility seam for callers that
        already know the registry.  Evidence is stored in the independent
        bounded repository, never in ``VoiceProfile.quality``.
        """

        if not isinstance(voice_id, str):
            raise ValueError("invalid voice ID format")
        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if not isinstance(validation, dict):
            raise ValueError("quality validation must be an object")

        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            profile = self._custom_voices.get(vid)
            if profile is None:
                raise KeyError(f"custom voice not found: {vid}")
            if expected_revision is not None:
                if profile.revision != expected_revision:
                    raise VoiceRevisionConflictError("voice changed during quality validation")
                if profile.revoked:
                    raise VoiceRevokedError("voice revoked during quality validation")
            evidence = dict(validation)
            evidence.setdefault("voice_id", profile.id)
            if profile.revision is None:
                raise ValueError("voice validation requires a revisioned voice")
            evidence.setdefault("voice_revision", profile.revision)
            self._validation_store.put(evidence)
            return profile

    @property
    def validation_store(self) -> VoiceValidationRepository:
        """Return the output-validation repository paired with this registry."""

        return self._validation_store

    def list_revisions(self, voice_id: str) -> tuple[VoiceProfile, ...]:
        """Return immutable acoustic revisions for one custom voice."""

        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            if vid not in self._custom_voices:
                raise KeyError(f"custom voice not found: {vid}")
            history = self._revision_history.get(vid, {})
            return tuple(history[key] for key in sorted(history))

    def rollback_custom_profile(
        self,
        voice_id: str,
        *,
        target_revision: str,
        expected_revision: str,
    ) -> VoiceProfile:
        """CAS the friendly voice ID back to one persisted acoustic revision."""

        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if not VOICE_REVISION_RE.fullmatch(target_revision):
            raise ValueError("invalid target voice revision")
        if not VOICE_REVISION_RE.fullmatch(expected_revision):
            raise ValueError("invalid expected voice revision")
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            current = self._custom_voices.get(vid)
            if current is None:
                raise KeyError(f"custom voice not found: {vid}")
            if current.revision != expected_revision:
                raise VoiceRevisionConflictError(f"voice revision changed for {current.id}")
            target = self._revision_history.get(vid, {}).get(target_revision)
            if target is None:
                raise KeyError(f"voice revision not found: {target_revision}")
            if target.revoked:
                raise VoiceRevokedError(f"voice revision is revoked: {target_revision}")
            if target.audio_path is not None:
                try:
                    self._controlled_audio_path(
                        target.audio_path,
                        vid,
                        require_exists=True,
                    )
                except ValueError as exc:
                    raise VoiceStoreUnavailableError("historic voice audio is unavailable") from exc
            restored = replace(
                target,
                name=current.name,
                created_at=current.created_at,
            )
            candidate = dict(self._custom_voices)
            candidate[vid] = restored
            history = self._history_candidate_locked(vid, current, restored)
            self._commit_candidate(candidate, history_candidate=history)
            return restored

    def revoke_revision(
        self,
        voice_id: str,
        *,
        revision: str,
    ) -> VoiceProfile:
        """Revoke one persisted revision; active leases remain valid until release."""

        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if not VOICE_REVISION_RE.fullmatch(revision):
            raise ValueError("invalid voice revision")
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            current = self._custom_voices.get(vid)
            if current is None:
                raise KeyError(f"custom voice not found: {vid}")
            history = self._revision_history.get(vid, {})
            target = history.get(revision)
            if target is None:
                raise KeyError(f"voice revision not found: {revision}")
            revoked_target = replace(target, revoked=True)
            history_candidate = {key: dict(value) for key, value in self._revision_history.items()}
            revisions = dict(history_candidate.get(vid, {}))
            revisions[revision] = revoked_target
            history_candidate[vid] = revisions
            candidate = dict(self._custom_voices)
            if current.revision == revision:
                candidate[vid] = replace(current, revoked=True)
            self._commit_candidate(
                candidate,
                history_candidate=history_candidate,
            )
            return revoked_target

    def delete_custom_profile(self, voice_id: str) -> None:
        vid = voice_id.strip().lower()
        if not VOICE_ID_RE.fullmatch(vid):
            raise ValueError("invalid voice ID format")
        if vid in SYSTEM_VOICE_PROFILES or vid in VOICE_ALIASES:
            raise ValueError(f"system voice cannot be deleted: {vid}")
        with self._lock, self._process_lock():
            self._ensure_available_locked(reload=True)
            profile = self._custom_voices.get(vid)
            if profile is None:
                raise KeyError(f"custom voice not found: {vid}")
            if self._voice_has_readers_locked(vid):
                raise VoiceInUseError(f"custom voice is in use: {vid}")
            historic = self._revision_history.get(vid, {})
            candidate = dict(self._custom_voices)
            del candidate[vid]
            history = {
                key: dict(value) for key, value in self._revision_history.items() if key != vid
            }
            self._commit_candidate(candidate, history_candidate=history)
            audio_paths = {
                item.audio_path
                for item in (profile, *historic.values())
                if item.audio_path is not None
            }
            for raw_path in audio_paths:
                try:
                    path = self._controlled_audio_path(
                        raw_path,
                        vid,
                        require_exists=False,
                    )
                    path.unlink(missing_ok=True)
                except OSError as exc:
                    self._retired_audio.add(path)
                    self._mark_unavailable(exc)
                    raise VoiceStoreUnavailableError(
                        "custom voice metadata deleted but audio cleanup failed"
                    ) from exc
