"""Bind optional vendor capabilities once at a composition boundary."""

from __future__ import annotations

from dataclasses import dataclass
from inspect import signature
from typing import Protocol, runtime_checkable

from speechrail.domain.tts_execution import (
    InvalidIncrementalSessionError,
    SamplingObservationReader,
    TtsExecutionPorts,
    VoiceLaneResolver,
    VoicePreparer,
    VoiceRuntimeIdentity,
)
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    IncrementalSpeechSession,
    TtsStreamLimits,
    TtsStreamOptions,
)


@runtime_checkable
class _IncrementalBackend(Protocol):
    """Worker/router factory owns voice leases and slots before vendor startup."""

    async def open_incremental_stream(
        self, options: TtsStreamOptions, *, limits: TtsStreamLimits
    ) -> IncrementalSpeechSession: ...


@dataclass(frozen=True, slots=True)
class _IncrementalAdapter:
    backend: _IncrementalBackend

    @property
    def protocol_negotiated(self) -> bool | None:
        # Negotiation can change when a worker restarts; never freeze ready state.
        value = getattr(self.backend, "supports_incremental_stream", None)
        return value if isinstance(value, bool) else None

    async def open_stream(
        self,
        options: TtsStreamOptions,
        *,
        limits: TtsStreamLimits = DEFAULT_TTS_STREAM_LIMITS,
    ) -> IncrementalSpeechSession:
        session = await self.backend.open_incremental_stream(options, limits=limits)
        if not isinstance(session, IncrementalSpeechSession) or not all(
            callable(getattr(session, name, None))
            for name in ("append_text", "finish_text", "events", "cancel", "close")
        ):
            raise InvalidIncrementalSessionError()
        return session


def bind_tts_execution(backend: object | None) -> TtsExecutionPorts:
    """Dynamic third-party discovery is confined to this adapter boundary."""

    incremental = (
        _IncrementalAdapter(backend)
        if isinstance(backend, _IncrementalBackend)
        and callable(backend.open_incremental_stream)
        else None
    )
    if incremental is not None:
        try:
            signature(incremental.backend.open_incremental_stream).bind(
                object(), limits=DEFAULT_TTS_STREAM_LIMITS
            )
        except (TypeError, ValueError) as exc:
            raise ValueError("invalid_incremental_factory_signature") from exc
    return TtsExecutionPorts(
        incremental=incremental,
        lanes=(
            backend
            if isinstance(backend, VoiceLaneResolver) and callable(backend.resource_key_for_voice)
            else None
        ),
        runtime_identity=(
            backend
            if isinstance(backend, VoiceRuntimeIdentity)
            and callable(backend.runtime_revision_for_voice)
            else None
        ),
        preparer=(
            backend
            if isinstance(backend, VoicePreparer) and callable(backend.prepare_voice)
            else None
        ),
        sampling=(
            backend
            if isinstance(backend, SamplingObservationReader)
            and callable(backend.take_sampling_observation)
            else None
        ),
    )
