"""Stateful validation and rendering for /v1/realtime events."""

from __future__ import annotations

import base64
import binascii
from enum import StrEnum
from typing import Any

from speechrail.domain.contracts import TranscriptResult


class SessionError(ValueError):
    def __init__(self, code: str, message: str | None = None) -> None:
        self.code = code
        super().__init__(message or code)


class SessionState(StrEnum):
    NEW = "new"
    CONFIGURED = "configured"
    COMMITTED = "committed"
    CLOSED = "closed"


class RealtimeSession:
    def __init__(self, *, session_id: str, max_frame_bytes: int, max_buffer_bytes: int) -> None:
        self.session_id = session_id
        self.max_frame_bytes = max_frame_bytes
        self.max_buffer_bytes = max_buffer_bytes
        self.state = SessionState.NEW
        self.language: str | None = None
        self.model = "speechrail/qwen3-asr-1.7b"
        self.prompt = ""
        self._audio = bytearray()

    def update(self, session: object) -> dict[str, Any]:
        if self.state is not SessionState.NEW:
            raise SessionError("session_already_configured")
        if not isinstance(session, dict):
            raise SessionError("invalid_session")
        model = session.get("model", self.model)
        language = session.get("language")
        prompt = session.get("prompt", "")
        if not isinstance(model, str) or not model.strip():
            raise SessionError("invalid_model")
        if language is not None and (not isinstance(language, str) or not language.strip()):
            raise SessionError("invalid_language")
        if not isinstance(prompt, str) or len(prompt) > 2000:
            raise SessionError("invalid_prompt")
        self.model = model.strip()
        self.language = language.strip() if isinstance(language, str) else None
        self.prompt = prompt
        self.state = SessionState.CONFIGURED
        return {
            "type": "transcription_session.created",
            "session": {"id": self.session_id, "model": self.model, "language": self.language},
        }

    def append(self, encoded: object) -> None:
        if self.state is not SessionState.CONFIGURED:
            raise SessionError("session_not_configured")
        if not isinstance(encoded, str):
            raise SessionError("invalid_base64")
        try:
            chunk = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise SessionError("invalid_base64") from exc
        if not chunk or len(chunk) % 2:
            raise SessionError("invalid_pcm")
        if (
            len(chunk) > self.max_frame_bytes
            or len(self._audio) + len(chunk) > self.max_buffer_bytes
        ):
            raise SessionError("audio_too_large")
        self._audio.extend(chunk)

    def commit(self) -> bytes:
        if self.state is SessionState.COMMITTED:
            raise SessionError("already_committed")
        if self.state is not SessionState.CONFIGURED:
            raise SessionError("session_not_configured")
        self.state = SessionState.COMMITTED
        return bytes(self._audio)

    def completed(self, result: TranscriptResult) -> dict[str, Any]:
        return {
            "type": "conversation.item.input_audio_transcription.completed",
            "event_id": f"evt_{result.request_id}",
            "session_id": self.session_id,
            "item_id": f"item_{result.request_id}",
            "transcript": result.text,
            "language": result.language,
            "segments": [
                {
                    "id": item.id,
                    "start": item.start_ms / 1000,
                    "end": item.end_ms / 1000,
                    "text": item.text,
                }
                for item in result.segments
            ],
        }

    def close(self) -> None:
        self._audio.clear()
        self.state = SessionState.CLOSED
