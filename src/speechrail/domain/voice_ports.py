"""Narrow voice catalog, revision, validation and lease contracts."""

from __future__ import annotations

from contextlib import AbstractContextManager
from pathlib import Path
from typing import Any, Protocol

from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_creation import VoiceCreation
from speechrail.domain.voice_validation import VoiceValidationRepository


class VoiceDirectory(Protocol):
    def snapshot_profiles(self) -> tuple[VoiceProfile, ...]: ...

    def list_profiles(self) -> list[VoiceProfile]: ...

    def get_profile(self, voice: str) -> VoiceProfile: ...


class VoiceLeases(VoiceDirectory, Protocol):
    def lease_profile(
        self, voice: str, *, expected_revision: str | None = None
    ) -> AbstractContextManager[VoiceProfile]: ...


class VoiceRevisions(VoiceDirectory, Protocol):
    def create_custom_profile(
        self, name: str, instruction: str, voice_id: str | None = None, seed: int | None = None
    ) -> VoiceProfile: ...

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
    ) -> VoiceProfile: ...

    def update_custom_profile(
        self,
        voice_id: str,
        *,
        name: str | None = None,
        instruction: str | None = None,
        seed: int | None = None,
        expected_revision: str | None = None,
    ) -> VoiceProfile: ...

    def list_revisions(self, voice_id: str) -> tuple[VoiceProfile, ...]: ...

    def rollback_custom_profile(
        self, voice_id: str, *, target_revision: str, expected_revision: str
    ) -> VoiceProfile: ...

    def revoke_revision(self, voice_id: str, *, revision: str) -> VoiceProfile: ...

    def delete_custom_profile(self, voice_id: str) -> None: ...


class ValidatedVoiceDirectory(VoiceDirectory, Protocol):
    @property
    def validation_store(self) -> VoiceValidationRepository: ...


class VoiceValidationWriter(ValidatedVoiceDirectory, VoiceLeases, Protocol):
    def update_quality_validation(
        self, voice_id: str, validation: dict[str, Any], *, expected_revision: str | None = None
    ) -> VoiceProfile: ...


class VoiceStore(VoiceRevisions, VoiceValidationWriter, Protocol):
    def artifact_path(self, name: str) -> Path: ...

    @property
    def storage_path(self) -> Path: ...

    @property
    def voices_dir(self) -> Path: ...
