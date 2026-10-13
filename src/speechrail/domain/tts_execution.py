"""Optional execution capabilities, separate from batch speech synthesis."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from speechrail.domain.tts_sampling import TtsSamplingObservation
from speechrail.domain.tts_stream import IncrementalSpeechSynthesizer, TtsStreamError


class InvalidIncrementalSessionError(TtsStreamError):
    """A factory returned no usable cleanup owner; reclamation is unconfirmed."""

    def __init__(self) -> None:
        super().__init__("tts_backend_failed", "backend returned an invalid incremental session")


@runtime_checkable
class VoiceLaneResolver(Protocol):
    def resource_key_for_voice(self, voice: str) -> str | None: ...


@runtime_checkable
class VoiceRuntimeIdentity(Protocol):
    def runtime_revision_for_voice(self, voice: str) -> str | None: ...


@runtime_checkable
class VoicePreparer(Protocol):
    async def prepare_voice(
        self, voice: str, *, expected_voice_revision: str | None = None
    ) -> str | None: ...


@runtime_checkable
class SamplingObservationReader(Protocol):
    def take_sampling_observation(self, response_id: str) -> TtsSamplingObservation | None: ...


@dataclass(frozen=True, slots=True)
class TtsExecutionPorts:
    """Composition-time capabilities; their presence does not assert readiness."""

    incremental: IncrementalSpeechSynthesizer | None = None
    lanes: VoiceLaneResolver | None = None
    runtime_identity: VoiceRuntimeIdentity | None = None
    preparer: VoicePreparer | None = None
    sampling: SamplingObservationReader | None = None


EMPTY_TTS_EXECUTION = TtsExecutionPorts()
