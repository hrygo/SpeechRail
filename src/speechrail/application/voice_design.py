"""Durable voice-design candidates separated from published voice revisions."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import tempfile
import threading
import wave
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, ValidationError

from speechrail.domain.file_locks import exclusive_file_lock
from speechrail.domain.tts import VOICE_REVISION_RE, VoiceProfile
from speechrail.domain.voice_creation import VoiceCreation

VoiceDesignState = Literal[
    "generated",
    "confirmed",
    "validating",
    "publishable",
    "published",
    "cancelled",
    "failed",
]
VoiceDesignReview = Literal["pass", "warn", "reject", "not_reviewed"]

# One source of truth for the retained-validation bound: the model rejects a
# longer list, and the merge refuses to build one in the first place.
_MAX_VALIDATIONS_PER_CANDIDATE = 32
# Fields a repeat machine validation must not overwrite: the human verdict, the
# derived status and the timestamps belong to the stored record, not to the
# freshly computed one.
_VALIDATION_REVIEW_FIELDS = frozenset(
    {"identity_status", "naturalness_status", "status", "created_at", "updated_at"}
)
# VoiceDesign text fidelity is versioned on its own.  v1 compared the whole
# transcript by edit distance, which passes a misread digit inside an otherwise
# faithful sentence; v2 additionally requires the spoken numbers to match
# exactly.  Bumping this revision retires v1 evidence from the publication and
# strict-synthesis gates without invalidating clone or quality-run evidence.
VOICE_DESIGN_VALIDATION_POLICY_REVISION = "voice_design_text_fidelity_v2"
_LEGACY_VALIDATION_POLICY_REVISION = "voice_design_text_fidelity_v1"
_CANDIDATE_ID_RE = r"^vd_[0-9a-f]{24}$"
_VALIDATION_ID_RE = r"^vv_[0-9a-f]{24}$"
_SHA256_RE = r"^[0-9a-f]{64}$"
_TERMINAL_STATES = frozenset({"published", "cancelled", "failed"})


class VoiceDesignStoreUnavailableError(RuntimeError):
    """The candidate store cannot be trusted or safely updated."""


class VoiceDesignNotFoundError(ValueError):
    """The requested candidate does not exist."""


class VoiceDesignAssetUnavailableError(RuntimeError):
    """A candidate audio asset is absent, unsafe, or no longer matches its record."""


class VoiceDesignConflictError(ValueError):
    """The candidate changed or the requested transition is not allowed."""


class VoiceDesignValidationLimitError(VoiceDesignConflictError):
    """The candidate already stores the maximum number of validations."""


class VoiceDesignCandidateUnavailableError(VoiceDesignConflictError):
    """The candidate is terminal and its audio is no longer reviewable."""


class VoiceDesignActionError(RuntimeError):
    """Stable public failure raised by a candidate action."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        status_code: int = 400,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.retryable = retryable


class VoiceDesignValidation(BaseModel):
    """One bounded validation result for a candidate revision and Base binding."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    validation_id: str = Field(pattern=_VALIDATION_ID_RE)
    candidate_revision: str = Field(pattern=VOICE_REVISION_RE.pattern)
    status: Literal["pass", "warn", "reject"]
    machine_status: Literal["pass", "warn", "reject"]
    identity_status: VoiceDesignReview = "not_reviewed"
    naturalness_status: VoiceDesignReview = "not_reviewed"
    failure_codes: list[str] = Field(default_factory=list, max_length=32)
    # ``None`` for records stored before the exact-number gate existed: those
    # records never compared numbers, so absence is not evidence of a match.
    transcript_numbers_match: bool | None = None
    validation_policy_revision: str = _LEGACY_VALIDATION_POLICY_REVISION
    capability_key: str
    model_artifact: str
    model_catalog_revision: str = Field(pattern=r"^[0-9a-f]{40}$")
    model_runtime_revision: str | None = None
    runtime_fingerprint: str | None = None
    preprocess_version: str
    generation_recipe_revision: str
    policy_version: str
    test_text_sha256: str = Field(pattern=_SHA256_RE)
    output_audio_sha256: str | None = Field(default=None, pattern=_SHA256_RE)
    output_wav_sha256: str | None = Field(default=None, pattern=_SHA256_RE)
    transcript_text_sha256: str | None = Field(default=None, pattern=_SHA256_RE)
    transcript_match: float | None = Field(default=None, ge=0.0, le=1.0)
    created_at: float = Field(ge=0.0)
    updated_at: float = Field(ge=0.0)


class VoiceDesignCandidate(BaseModel):
    """Private candidate state; API projections never expose text or paths."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    candidate_id: str = Field(pattern=_CANDIDATE_ID_RE)
    target_voice_id: str = Field(pattern=r"^[a-z0-9_-]{1,64}$")
    name: str = Field(min_length=1, max_length=64)
    language: Literal["zh"] = "zh"
    seed: StrictInt = Field(ge=0, le=2**32 - 1)
    instruction_sha256: str = Field(pattern=_SHA256_RE)
    reference_text: str = Field(min_length=20, max_length=240)
    reference_text_sha256: str = Field(pattern=_SHA256_RE)
    transcript: str
    transcript_sha256: str = Field(pattern=_SHA256_RE)
    reference_audio_path: str
    reference_audio_sha256: str = Field(pattern=_SHA256_RE)
    duration_seconds: float = Field(ge=0.0)
    quality: dict[str, Any]
    source_model_artifact: str
    source_model_revision: str = Field(pattern=r"^[0-9a-f]{40}$")
    creation: VoiceCreation
    revision: str = Field(pattern=VOICE_REVISION_RE.pattern)
    request_fingerprint: str = Field(pattern=_SHA256_RE)
    state: VoiceDesignState = "generated"
    validations: list[VoiceDesignValidation] = Field(
        default_factory=list, max_length=_MAX_VALIDATIONS_PER_CANDIDATE
    )
    created_at: float = Field(ge=0.0)
    updated_at: float = Field(ge=0.0)
    confirmed_at: float | None = Field(default=None, ge=0.0)
    published_at: float | None = Field(default=None, ge=0.0)
    published_voice_revision: str | None = Field(
        default=None,
        pattern=VOICE_REVISION_RE.pattern,
    )
    error_code: str | None = Field(default=None, max_length=128)

    def require_validation_writable(self, *, expected_revision: str) -> None:
        """Guard each validation transition against the locked current state."""

        if self.revision != expected_revision or self.state not in {
            "confirmed",
            "validating",
            "publishable",
        }:
            raise VoiceDesignConflictError("candidate revision or state changed")

    def profile(self) -> VoiceProfile:
        """Return the ephemeral Base profile used before publication."""

        return VoiceProfile(
            id=self.target_voice_id,
            name=self.name,
            instruction="",
            seed=42,
            temperature=0.1,
            is_default=False,
            is_system=False,
            created_at=self.created_at,
            mode="clone",
            ref_text=self.reference_text,
            audio_path=self.reference_audio_path,
            duration_seconds=self.duration_seconds,
            quality=self.quality,
            creation=self.creation,
            revision=self.revision,
        )

    def passing_validation(
        self, *, capability_key: str | None = None
    ) -> VoiceDesignValidation | None:
        """Return the newest complete pass for this exact candidate revision."""

        matches = [
            item
            for item in self.validations
            if item.candidate_revision == self.revision
            and item.status == "pass"
            and item.identity_status == "pass"
            and item.naturalness_status == "pass"
            and item.validation_policy_revision == VOICE_DESIGN_VALIDATION_POLICY_REVISION
            and item.transcript_numbers_match is True
            and (capability_key is None or item.capability_key == capability_key)
        ]
        return matches[-1] if matches else None

    def has_current_machine_pass(
        self, validation_id: str, *, capability_key: str | None = None
    ) -> bool:
        """Whether a stored result may still receive a human verdict.

        Human review sharpens a machine verdict; it can never stand in for one.
        A result produced under a retired text-fidelity policy, or one that never
        compared the spoken numbers, therefore stays unpromotable until the
        candidate is validated again under the current policy.
        """

        return any(
            item.validation_id == validation_id
            and item.candidate_revision == self.revision
            and item.machine_status == "pass"
            and item.validation_policy_revision == VOICE_DESIGN_VALIDATION_POLICY_REVISION
            and item.transcript_numbers_match is True
            and (capability_key is None or item.capability_key == capability_key)
            for item in self.validations
        )


@dataclass(frozen=True, slots=True)
class _MergedValidation:
    """One candidate's validation list plus the state its contents imply."""

    validations: list[VoiceDesignValidation]
    state: VoiceDesignState


def _merge_validation(
    candidate: VoiceDesignCandidate, validation: VoiceDesignValidation
) -> _MergedValidation:
    """Merge one machine result into the stored list, keeping earlier verdicts.

    A repeated machine validation is idempotent for the fields it actually
    measured and never revokes a human review.  Anything else would let a
    re-run silently downgrade a reviewed result, or grow the list without bound
    until the model rejects it at save time.
    """

    existing = next(
        (
            item
            for item in candidate.validations
            if item.validation_id == validation.validation_id
        ),
        None,
    )
    if existing is None:
        if len(candidate.validations) >= _MAX_VALIDATIONS_PER_CANDIDATE:
            raise VoiceDesignValidationLimitError(
                "candidate already retains the maximum number of validations"
            )
        record = validation
    elif existing.model_dump(
        exclude=set(_VALIDATION_REVIEW_FIELDS)
    ) == validation.model_dump(exclude=set(_VALIDATION_REVIEW_FIELDS)):
        record = existing
    else:
        raise VoiceDesignConflictError(
            "validation identity already exists with different machine facts"
        )
    validations = [
        item for item in candidate.validations if item.validation_id != record.validation_id
    ]
    validations.append(record)
    merged = candidate.model_copy(update={"validations": validations})
    return _MergedValidation(validations=validations, state=review_state_for(merged))


def review_state_for(candidate: VoiceDesignCandidate) -> VoiceDesignState:
    """Return the state implied by the stored validations alone.

    Both writers of the validation list -- the machine merge and the human
    review -- derive the state here, so a review can never disagree with what a
    validation would have concluded about the same records.
    """

    if candidate.passing_validation() is not None:
        return "publishable"
    if any(
        item.candidate_revision == candidate.revision
        and (item.machine_status == "reject" or item.status == "reject")
        for item in candidate.validations
    ):
        return "failed"
    return "validating"


def _atomic_write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(0o600)
        tmp_path.replace(path)
        try:
            dir_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def _atomic_write_audio(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(0o600)
        tmp_path.replace(path)
        try:
            dir_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


class VoiceDesignRepository:
    """Atomic JSON/WAV store with process and thread locks."""

    def __init__(
        self,
        path: Path,
        assets_dir: Path,
        *,
        max_entries: int = 64,
    ) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._path = Path(path)
        self._assets_dir = Path(assets_dir)
        self._max_entries = max_entries
        self._lock = threading.RLock()

    @property
    def path(self) -> Path:
        return self._path

    @property
    def assets_dir(self) -> Path:
        return self._assets_dir

    def _load_locked(self) -> dict[str, VoiceDesignCandidate]:
        if not self._path.exists():
            return {}
        try:
            if self._path.is_symlink() or not self._path.is_file():
                raise ValueError("voice design store is not a regular file")
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict) or raw.get("schema_version") != 1:
                raise ValueError("voice design store has an unsupported schema")
            records = raw.get("candidates")
            if not isinstance(records, list):
                raise ValueError("voice design candidates must be a list")
            loaded: dict[str, VoiceDesignCandidate] = {}
            for item in records:
                candidate = VoiceDesignCandidate.model_validate(item)
                if candidate.candidate_id in loaded:
                    raise ValueError("duplicate voice design candidate")
                loaded[candidate.candidate_id] = candidate
            return loaded
        except ValidationError as exc:
            raise VoiceDesignStoreUnavailableError(
                "voice design store contains an invalid candidate"
            ) from exc
        except VoiceDesignStoreUnavailableError:
            raise
        except Exception as exc:
            raise VoiceDesignStoreUnavailableError(
                "voice design store is unavailable"
            ) from exc

    def _save_locked(self, records: dict[str, VoiceDesignCandidate]) -> None:
        try:
            if self._path.parent.is_symlink() or self._assets_dir.is_symlink():
                raise OSError("voice design store path must not be a symlink")
            self._path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._assets_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            ordered = sorted(
                records.values(),
                key=lambda item: item.created_at,
                reverse=True,
            )[: self._max_entries]
            _atomic_write_json(
                self._path,
                {
                    "schema_version": 1,
                    "candidates": [
                        item.model_dump(mode="json") for item in ordered
                    ],
                },
            )
        except Exception as exc:
            raise VoiceDesignStoreUnavailableError(
                "voice design store cannot be persisted"
            ) from exc

    def _audio_path(self, candidate_id: str, revision: str) -> Path:
        if not candidate_id.startswith("vd_") or not VOICE_REVISION_RE.fullmatch(revision):
            raise ValueError("invalid voice design asset identity")
        if self._assets_dir.is_symlink():
            raise ValueError("voice design asset directory must not be a symlink")
        candidate = (self._assets_dir / f"{candidate_id}.wav").resolve()
        root = self._assets_dir.resolve()
        if candidate.parent != root:
            raise ValueError("voice design asset escaped its private directory")
        return candidate

    def _validation_audio_path(self, candidate_id: str, validation_id: str) -> Path:
        if (
            not candidate_id.startswith("vd_")
            or re.fullmatch(_CANDIDATE_ID_RE, candidate_id) is None
            or re.fullmatch(_VALIDATION_ID_RE, validation_id) is None
        ):
            raise ValueError("invalid voice design validation asset identity")
        if self._assets_dir.is_symlink():
            raise ValueError("voice design asset directory must not be a symlink")
        root = self._assets_dir.resolve()
        directory = self._assets_dir / candidate_id
        if directory.is_symlink():
            raise ValueError("voice design validation directory must not be a symlink")
        resolved_directory = directory.resolve()
        if resolved_directory.parent != root:
            raise ValueError("voice design validation asset escaped its private directory")
        return resolved_directory / f"{validation_id}.wav"

    @staticmethod
    def _read_audio_asset(path: Path, *, max_bytes: int) -> bytes:
        try:
            if path.is_symlink() or not path.is_file():
                raise VoiceDesignAssetUnavailableError("voice design audio is unavailable")
            size = path.stat().st_size
            if size <= 0 or size > max_bytes:
                raise VoiceDesignAssetUnavailableError("voice design audio is unavailable")
            payload = path.read_bytes()
        except VoiceDesignAssetUnavailableError:
            raise
        except OSError as exc:
            raise VoiceDesignAssetUnavailableError(
                "voice design audio is unavailable"
            ) from exc
        if len(payload) != size or len(payload) > max_bytes:
            raise VoiceDesignAssetUnavailableError("voice design audio is unavailable")
        return payload

    @staticmethod
    def _pcm_sha256_from_wav(payload: bytes) -> str:
        try:
            with wave.open(io.BytesIO(payload), "rb") as audio:
                if (
                    audio.getcomptype() != "NONE"
                    or audio.getnchannels() != 1
                    or audio.getsampwidth() != 2
                ):
                    raise VoiceDesignAssetUnavailableError(
                        "voice design validation audio is unavailable"
                    )
                pcm = audio.readframes(audio.getnframes())
        except VoiceDesignAssetUnavailableError:
            raise
        except (EOFError, OSError, wave.Error) as exc:
            raise VoiceDesignAssetUnavailableError(
                "voice design validation audio is unavailable"
            ) from exc
        return hashlib.sha256(pcm).hexdigest()

    def read_reference_audio(
        self,
        candidate_id: str,
        *,
        expected_revision: str,
        max_bytes: int,
    ) -> tuple[VoiceDesignCandidate, bytes]:
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            candidate = self._load_locked().get(candidate_id)
            if candidate is None:
                raise VoiceDesignNotFoundError(candidate_id)
            if candidate.revision != expected_revision:
                raise VoiceDesignConflictError("candidate revision changed")
            if candidate.state in {"cancelled", "failed"}:
                raise VoiceDesignCandidateUnavailableError(
                    "candidate audio is no longer reviewable"
                )
            try:
                expected_path = self._audio_path(candidate_id, candidate.revision)
            except ValueError as exc:
                raise VoiceDesignAssetUnavailableError(
                    "candidate reference audio path is unsafe"
                ) from exc
            if Path(candidate.reference_audio_path) != expected_path:
                raise VoiceDesignAssetUnavailableError(
                    "candidate reference audio identity is unavailable"
                )
            payload = self._read_audio_asset(expected_path, max_bytes=max_bytes)
        if hashlib.sha256(payload).hexdigest() != candidate.reference_audio_sha256:
            raise VoiceDesignAssetUnavailableError(
                "candidate reference audio does not match its record"
            )
        return candidate, payload

    def read_validation_audio(
        self,
        candidate_id: str,
        validation_id: str,
        *,
        expected_revision: str,
        max_bytes: int,
    ) -> tuple[VoiceDesignCandidate, bytes]:
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            candidate = self._load_locked().get(candidate_id)
            if candidate is None:
                raise VoiceDesignNotFoundError(candidate_id)
            if candidate.revision != expected_revision:
                raise VoiceDesignConflictError("candidate revision changed")
            if candidate.state in {"cancelled", "failed"}:
                raise VoiceDesignCandidateUnavailableError(
                    "candidate audio is no longer reviewable"
                )
            validation = next(
                (
                    item
                    for item in candidate.validations
                    if item.validation_id == validation_id
                    and item.candidate_revision == candidate.revision
                ),
                None,
            )
            if validation is None:
                raise VoiceDesignNotFoundError(validation_id)
            if (
                validation.output_audio_sha256 is None
                or validation.output_wav_sha256 is None
            ):
                raise VoiceDesignAssetUnavailableError(
                    "validation audio identity is unavailable"
                )
            try:
                path = self._validation_audio_path(candidate_id, validation_id)
            except ValueError as exc:
                raise VoiceDesignAssetUnavailableError(
                    "validation audio path is unsafe"
                ) from exc
            payload = self._read_audio_asset(path, max_bytes=max_bytes)
        if hashlib.sha256(payload).hexdigest() != validation.output_wav_sha256:
            raise VoiceDesignAssetUnavailableError(
                "validation WAV does not match its record"
            )
        if self._pcm_sha256_from_wav(payload) != validation.output_audio_sha256:
            raise VoiceDesignAssetUnavailableError(
                "validation PCM does not match its record"
            )
        return candidate, payload

    def update_with_validation_audio(
        self,
        candidate_id: str,
        *,
        expected_revision: str,
        validation: VoiceDesignValidation,
        audio_bytes: bytes,
        max_bytes: int,
    ) -> VoiceDesignCandidate:
        """Merge one validation into the current candidate under one lock.

        The caller cannot supply the candidate to store: it read the candidate
        before it awaited the backend, so a second overlapping validation would
        otherwise persist its own stale copy of ``validations`` and silently
        drop whatever the first one stored.  Reading the latest record and
        merging inside the lock is what makes two concurrent validations both
        durable.
        """

        if (
            validation.candidate_revision != expected_revision
            or validation.output_audio_sha256 is None
            or validation.output_wav_sha256 is None
            or len(audio_bytes) <= 0
            or len(audio_bytes) > max_bytes
            or hashlib.sha256(audio_bytes).hexdigest() != validation.output_wav_sha256
            or self._pcm_sha256_from_wav(audio_bytes) != validation.output_audio_sha256
        ):
            raise VoiceDesignAssetUnavailableError(
                "validation audio does not match its record"
            )

        asset_path = self._validation_audio_path(candidate_id, validation.validation_id)
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            records = self._load_locked()
            current = records.get(candidate_id)
            if current is None:
                raise VoiceDesignNotFoundError(candidate_id)
            current.require_validation_writable(expected_revision=expected_revision)

            merged = _merge_validation(current, validation)
            updated_candidate = current.model_copy(
                update={
                    "validations": merged.validations,
                    "state": merged.state,
                    "updated_at": max(current.updated_at, validation.updated_at),
                }
            )
            created_asset = False
            try:
                if asset_path.exists() or asset_path.is_symlink():
                    existing = self._read_audio_asset(asset_path, max_bytes=max_bytes)
                    if hashlib.sha256(existing).hexdigest() != validation.output_wav_sha256:
                        raise VoiceDesignAssetUnavailableError(
                            "validation asset identity already exists"
                        )
                else:
                    _atomic_write_audio(asset_path, audio_bytes)
                    created_asset = True
                records[candidate_id] = updated_candidate
                self._save_locked(records)
            except BaseException as exc:
                if created_asset:
                    asset_path.unlink(missing_ok=True)
                    with suppress(OSError):
                        asset_path.parent.rmdir()
                if isinstance(
                    exc,
                    (
                        VoiceDesignAssetUnavailableError,
                        VoiceDesignConflictError,
                        VoiceDesignValidationLimitError,
                        VoiceDesignNotFoundError,
                        VoiceDesignStoreUnavailableError,
                    ),
                ):
                    raise
                if isinstance(exc, OSError):
                    raise VoiceDesignStoreUnavailableError(
                        "voice design validation asset cannot be persisted"
                    ) from exc
                raise
        return updated_candidate

    def create(
        self,
        candidate: VoiceDesignCandidate,
        audio_bytes: bytes,
    ) -> VoiceDesignCandidate:
        """Persist the audio and candidate metadata as one recoverable creation."""

        expected = self._audio_path(candidate.candidate_id, candidate.revision)
        if Path(candidate.reference_audio_path).resolve() != expected:
            raise ValueError("candidate audio path does not match its identity")
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            records = self._load_locked()
            if candidate.candidate_id in records:
                raise VoiceDesignConflictError("voice design candidate already exists")
            if len(records) >= self._max_entries:
                terminal = sorted(
                    (
                        item
                        for item in records.values()
                        if item.state in _TERMINAL_STATES
                    ),
                    key=lambda item: item.updated_at,
                )
                if not terminal:
                    raise VoiceDesignStoreUnavailableError(
                        "voice design store is full of active candidates"
                    )
                for stale in terminal[: len(records) - self._max_entries + 1]:
                    records.pop(stale.candidate_id, None)
                    self._audio_path(
                        stale.candidate_id, stale.revision
                    ).unlink(missing_ok=True)
                    for validation in stale.validations:
                        if validation.validation_id and re.fullmatch(
                            _VALIDATION_ID_RE,
                            validation.validation_id,
                        ):
                            validation_path = self._validation_audio_path(
                                stale.candidate_id,
                                validation.validation_id,
                            )
                            validation_path.unlink(missing_ok=True)
                    with suppress(OSError):
                        (self._assets_dir / stale.candidate_id).rmdir()
            try:
                _atomic_write_audio(expected, audio_bytes)
            except OSError as exc:
                raise VoiceDesignStoreUnavailableError(
                    "voice design asset cannot be persisted"
                ) from exc
            records[candidate.candidate_id] = candidate
            try:
                self._save_locked(records)
            except BaseException:
                expected.unlink(missing_ok=True)
                raise
        return candidate

    def get(self, candidate_id: str) -> VoiceDesignCandidate:
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            candidate = self._load_locked().get(candidate_id)
        if candidate is None:
            raise VoiceDesignNotFoundError(candidate_id)
        return candidate

    def list(self) -> list[VoiceDesignCandidate]:
        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            return sorted(
                self._load_locked().values(),
                key=lambda item: item.created_at,
                reverse=True,
            )

    def update(
        self,
        candidate_id: str,
        updater: Callable[[VoiceDesignCandidate], VoiceDesignCandidate],
    ) -> VoiceDesignCandidate:
        """Apply one locked compare-and-update transition."""

        with self._lock, exclusive_file_lock(
            self._path,
            unavailable_error=VoiceDesignStoreUnavailableError,
        ):
            records = self._load_locked()
            current = records.get(candidate_id)
            if current is None:
                raise VoiceDesignNotFoundError(candidate_id)
            updated = updater(current)
            if updated.candidate_id != current.candidate_id:
                raise VoiceDesignConflictError("candidate identity cannot be changed")
            records[candidate_id] = updated
            self._save_locked(records)
        return updated

    def safe_projection(self, candidate: VoiceDesignCandidate) -> dict[str, Any]:
        """Return safe candidate metadata for REST/MCP consumers."""

        reference_quality: dict[str, Any] | None = None
        synthetic = candidate.quality.get("synthesis")
        if isinstance(candidate.quality.get("reference"), dict):
            reference_quality = {
                key: value
                for key, value in candidate.quality["reference"].items()
                if key in {
                    "status",
                    "duration_seconds",
                    "sample_rate",
                    "channels",
                    "speech_active_ratio",
                    "clipping_ratio",
                    "transcript_match",
                }
            }
        if isinstance(synthetic, dict):
            reference_quality = {
                **(reference_quality or {}),
                "synthesis": {
                    key: value
                    for key, value in synthetic.items()
                    if key in {
                        "probe_count",
                        "successful_probe_count",
                        "deterministic",
                        "transcript_match",
                    }
                },
            }
        return {
            "id": candidate.candidate_id,
            "target_voice_id": candidate.target_voice_id,
            "name": candidate.name,
            "language": candidate.language,
            "state": candidate.state,
            "revision": candidate.revision,
            "created_at": candidate.created_at,
            "updated_at": candidate.updated_at,
            "confirmed_at": candidate.confirmed_at,
            "published_at": candidate.published_at,
            "published_voice_revision": candidate.published_voice_revision,
            "error_code": candidate.error_code,
            "source_model": {
                "artifact": candidate.source_model_artifact,
                "revision": candidate.source_model_revision,
            },
            "reference": {
                "audio_sha256": candidate.reference_audio_sha256,
                "text_sha256": candidate.reference_text_sha256,
                "transcript_sha256": candidate.transcript_sha256,
                "duration_seconds": candidate.duration_seconds,
                "quality": reference_quality,
            },
            "validations": [
                {
                    "validation_id": item.validation_id,
                    "candidate_revision": item.candidate_revision,
                    "status": item.status,
                    "machine_status": item.machine_status,
                    "identity_status": item.identity_status,
                    "naturalness_status": item.naturalness_status,
                    "failure_codes": list(item.failure_codes),
                    "transcript_numbers_match": item.transcript_numbers_match,
                    "validation_policy_revision": item.validation_policy_revision,
                    "capability_key": item.capability_key,
                    "model_artifact": item.model_artifact,
                    "model_catalog_revision": item.model_catalog_revision,
                    "transcript_match": item.transcript_match,
                    "created_at": item.created_at,
                    "updated_at": item.updated_at,
                }
                for item in candidate.validations
            ],
            "publishable": candidate.passing_validation() is not None,
        }


__all__ = [
    "VoiceDesignActionError",
    "VoiceDesignAssetUnavailableError",
    "VoiceDesignCandidate",
    "VoiceDesignCandidateUnavailableError",
    "VoiceDesignConflictError",
    "VoiceDesignNotFoundError",
    "VoiceDesignRepository",
    "VoiceDesignReview",
    "VoiceDesignState",
    "VoiceDesignStoreUnavailableError",
    "VoiceDesignValidation",
]
