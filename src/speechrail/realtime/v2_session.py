"""In-memory state machines for the Realtime v2 wire contract.

The WebSocket gateway owns transport concerns.  These state machines own only
ordering, bounded input buffers, item revisions and terminal transitions so
that both ASR and TTS paths can be tested without a model runtime.
"""

from __future__ import annotations

import base64
import binascii
from collections.abc import Mapping
from enum import StrEnum
from typing import Any
from uuid import uuid4

from speechrail.domain.realtime_v2 import RealtimeV2Error

PCM16: dict[str, int | str] = {
    "type": "audio/pcm",
    "rate": 16_000,
    "channels": 1,
    "sample_width": 2,
}


class SessionState(StrEnum):
    """Observable lifetime states shared by transcription and speech."""

    NEW = "new"
    ACTIVE = "active"
    COMMITTED = "committed"
    CANCELLED = "cancelled"


class _BaseSession:
    def __init__(self, *, expected_type: str, request_id: str | None = None) -> None:
        self._expected_type = expected_type
        self.session_id = f"sess_{uuid4().hex}"
        self.request_id = request_id or f"req_{uuid4().hex}"
        self.state = SessionState.NEW
        self._sequence = 0

    def configure(self, session: Mapping[str, Any]) -> dict[str, Any]:
        if self.state is not SessionState.NEW:
            raise RealtimeV2Error("session.update may only be sent once", code="invalid_state")
        if session.get("type") != self._expected_type:
            raise RealtimeV2Error(
                f"session.type must be {self._expected_type!r}", code="invalid_session"
            )
        self._validate_configure(session)
        self.state = SessionState.ACTIVE
        return self._event(
            "session.created",
            session={"id": self.session_id, "type": self._expected_type, **dict(session)},
        )

    def cancel(self) -> dict[str, Any]:
        if self.state is SessionState.CANCELLED:
            return self._event("session.cancelled")
        self.state = SessionState.CANCELLED
        self._on_cancel()
        return self._event("session.cancelled")

    def _ensure_active(self) -> None:
        if self.state is SessionState.NEW:
            raise RealtimeV2Error("session.update is required first", code="invalid_state")
        if self.state in {SessionState.COMMITTED, SessionState.CANCELLED}:
            raise RealtimeV2Error("session is terminal", code="invalid_state")

    def _event(self, event_type: str, **payload: Any) -> dict[str, Any]:
        self._sequence += 1
        return {
            "type": event_type,
            "event_id": f"evt_{uuid4().hex}",
            "sequence": self._sequence,
            "session_id": self.session_id,
            "request_id": self.request_id,
            **payload,
        }

    def _validate_configure(self, session: Mapping[str, Any]) -> None:
        raise NotImplementedError

    def _on_cancel(self) -> None:
        """Clear subclass-owned buffered state on a terminal cancellation."""


class TranscriptionSession(_BaseSession):
    """State and event invariants for a Realtime v2 ASR session."""

    def __init__(self, *, max_audio_bytes: int, request_id: str | None = None) -> None:
        super().__init__(expected_type="transcription", request_id=request_id)
        if max_audio_bytes <= 0:
            raise ValueError("max_audio_bytes must be positive")
        self._max_audio_bytes = max_audio_bytes
        self._audio = bytearray()
        self._item_revisions: dict[str, int] = {}
        self._completed_items: set[str] = set()

    def append_audio(self, encoded_audio: str) -> bytes:
        self._ensure_active()
        audio = _decode_pcm16(encoded_audio)
        if len(self._audio) + len(audio) > self._max_audio_bytes:
            raise RealtimeV2Error("audio buffer limit exceeded", code="buffer_limit_exceeded")
        self._audio.extend(audio)
        return audio

    def flush_audio(self) -> bytes:
        self._ensure_active()
        return self._drain_audio()

    def commit_audio(self) -> bytes:
        self._ensure_active()
        audio = self._drain_audio()
        self.state = SessionState.COMMITTED
        return audio

    def transcription_delta(
        self,
        *,
        item_id: str,
        revision: int,
        text: str,
        start_ms: int,
        end_ms: int,
    ) -> dict[str, Any]:
        self._ensure_active()
        if item_id in self._completed_items:
            raise RealtimeV2Error("item has already completed", code="invalid_item_state")
        previous_revision = self._item_revisions.get(item_id, 0)
        if revision <= previous_revision:
            raise RealtimeV2Error("revision must increase for each item", code="invalid_revision")
        if start_ms < 0 or end_ms < start_ms:
            raise RealtimeV2Error("invalid transcript time range", code="invalid_transcript")
        self._item_revisions[item_id] = revision
        return self._event(
            "transcription.delta",
            item_id=item_id,
            revision=revision,
            text=text,
            start_ms=start_ms,
            end_ms=end_ms,
        )

    def transcription_completed(
        self,
        *,
        item_id: str,
        text: str,
        language: str | None,
        segments: list[Mapping[str, Any]],
    ) -> dict[str, Any]:
        self._ensure_active()
        if item_id in self._completed_items:
            raise RealtimeV2Error("item has already completed", code="invalid_item_state")
        self._completed_items.add(item_id)
        return self._event(
            "transcription.completed",
            item_id=item_id,
            text=text,
            language=language,
            segments=[dict(segment) for segment in segments],
        )

    def _validate_configure(self, session: Mapping[str, Any]) -> None:
        _validate_pcm16(session.get("input_audio_format"))

    def _drain_audio(self) -> bytes:
        audio = bytes(self._audio)
        self._audio.clear()
        return audio

    def _on_cancel(self) -> None:
        self._audio.clear()


class SpeechSession(_BaseSession):
    """State and event invariants for a Realtime v2 TTS session."""

    def __init__(self, *, max_text_chars: int, request_id: str | None = None) -> None:
        super().__init__(expected_type="speech", request_id=request_id)
        if max_text_chars <= 0:
            raise ValueError("max_text_chars must be positive")
        self._max_text_chars = max_text_chars
        self._text_parts: list[str] = []
        self._active_response_id: str | None = None
        self._next_chunk_index = 0
        self._cancelled_responses: set[str] = set()

    def append_text(self, text: str) -> None:
        self._ensure_active()
        if not text:
            raise RealtimeV2Error("text must not be empty", code="invalid_text")
        if len(self.text) + len(text) > self._max_text_chars:
            raise RealtimeV2Error("text buffer limit exceeded", code="buffer_limit_exceeded")
        self._text_parts.append(text)

    @property
    def text(self) -> str:
        return "".join(self._text_parts)

    def flush_text(self) -> str:
        self._ensure_active()
        return self._drain_text()

    def commit_text(self) -> str:
        self._ensure_active()
        text = self._drain_text()
        self.state = SessionState.COMMITTED
        return text

    def response_created(self, *, response_id: str | None = None) -> dict[str, Any]:
        self._ensure_active()
        if self._active_response_id is not None:
            raise RealtimeV2Error("a response is already active", code="response_in_progress")
        resolved_response_id = response_id or f"resp_{uuid4().hex}"
        if resolved_response_id in self._cancelled_responses:
            raise RealtimeV2Error("response id may not be reused", code="invalid_response")
        self._active_response_id = resolved_response_id
        self._next_chunk_index = 0
        return self._event("response.created", response_id=resolved_response_id)

    def audio_delta(self, *, response_id: str, chunk_index: int, audio: bytes) -> dict[str, Any]:
        self._ensure_active()
        self._require_active_response(response_id)
        if chunk_index != self._next_chunk_index:
            raise RealtimeV2Error("chunk_index is out of order", code="invalid_chunk_index")
        if not audio or len(audio) % 2:
            raise RealtimeV2Error("audio must contain PCM16 samples", code="invalid_audio")
        self._next_chunk_index += 1
        return self._event(
            "response.audio.delta",
            response_id=response_id,
            chunk_index=chunk_index,
            audio=base64.b64encode(audio).decode("ascii"),
        )

    def response_completed(self, *, response_id: str) -> dict[str, Any]:
        self._ensure_active()
        self._require_active_response(response_id)
        self._active_response_id = None
        return self._event("response.completed", response_id=response_id)

    def response_cancel(self, *, response_id: str) -> dict[str, Any]:
        if response_id in self._cancelled_responses:
            return self._event("response.cancelled", response_id=response_id)
        self._ensure_active()
        self._require_active_response(response_id)
        self._active_response_id = None
        self._cancelled_responses.add(response_id)
        return self._event("response.cancelled", response_id=response_id)

    def _validate_configure(self, session: Mapping[str, Any]) -> None:
        if not isinstance(session.get("voice"), str) or not session["voice"].strip():
            raise RealtimeV2Error("speech sessions require a voice", code="invalid_session")
        _validate_pcm16(session.get("audio_format"))

    def _require_active_response(self, response_id: str) -> None:
        if self._active_response_id != response_id:
            raise RealtimeV2Error("response is not active", code="invalid_response")

    def _drain_text(self) -> str:
        text = self.text
        self._text_parts.clear()
        return text

    def _on_cancel(self) -> None:
        self._text_parts.clear()
        self._active_response_id = None


def _decode_pcm16(encoded_audio: str) -> bytes:
    if not isinstance(encoded_audio, str) or not encoded_audio:
        raise RealtimeV2Error("audio must be a non-empty base64 string", code="invalid_audio")
    try:
        audio = base64.b64decode(encoded_audio, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise RealtimeV2Error("audio must be valid base64", code="invalid_audio") from exc
    if not audio or len(audio) % 2:
        raise RealtimeV2Error("audio must contain PCM16 samples", code="invalid_audio")
    return audio


def _validate_pcm16(value: object) -> None:
    if not isinstance(value, Mapping) or dict(value) != PCM16:
        raise RealtimeV2Error("only 16 kHz mono PCM16 is supported", code="invalid_audio_format")
