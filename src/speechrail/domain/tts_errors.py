"""Structured failures shared by the local TTS worker and public adapters.

The worker protocol is intentionally small and private, but its errors still
cross a process boundary. Keep the raw worker code, lifecycle stage and retry
policy together instead of making callers infer meaning from traceback or
stderr text.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Literal

TtsErrorStage = Literal["initialize", "validate", "infer", "decode", "deliver"]
_WORKER_ROLES = frozenset({"voice_design", "tts_custom_voice", "tts_base"})
_WORKER_EXCEPTION_TYPES = frozenset(
    {
        "ModuleNotFoundError", "ImportError", "FileNotFoundError", "PermissionError",
        "MemoryError", "ValueError", "RuntimeError", "OSError", "TypeError",
    }
)

TTS_PARAMETER_ERROR_CODES = frozenset(
    {
        "clone_speed_unsupported",
        "clone_instruction_unsupported",
        "clone_seed_unsupported",
        "instructions_unsupported",
        "unsupported_language",
        "invalid_speed",
        "base_clone_required",
        "voice_clone_requires_base_model",
        "voice_design_seed_requires_instruction",
    }
)


class TtsBackendError(RuntimeError):
    """A stable, non-text-classified failure from the local TTS path."""

    def __init__(
        self,
        code: str,
        *,
        stage: TtsErrorStage,
        public_code: str | None = None,
        retryable: bool = False,
        detail: str | None = None,
        diagnostic_class: str | None = None,
        request_id: str | None = None,
        worker_attempt_id: str | None = None,
        worker_role: str | None = None,
        worker_exit_code: int | None = None,
        worker_exception_type: str | None = None,
    ) -> None:
        self.code = code
        self.stage = stage
        self.public_code = public_code or code
        self.diagnostic_class = diagnostic_class or self.public_code
        self.retryable = retryable
        self.request_id = request_id
        self.worker_attempt_id = worker_attempt_id
        self.worker_role = worker_role
        self.worker_exit_code = worker_exit_code
        self.worker_exception_type = worker_exception_type
        # Detail is for structured diagnostics and internal logging only. It
        # is deliberately excluded from ``str(exc)`` and HTTP responses.
        self.detail = detail
        super().__init__(code)

    @property
    def worker_diagnostics(self) -> dict[str, object]:
        """Return only allowlisted attribution, never vendor text or stderr."""
        result: dict[str, object] = {"stage": self.stage}
        if self.worker_role in _WORKER_ROLES:
            result["role"] = self.worker_role
        if self.worker_attempt_id is not None and re.fullmatch(
            r"tts_attempt_[0-9a-f]{32}", self.worker_attempt_id
        ):
            result["attempt_id"] = self.worker_attempt_id
        if isinstance(self.worker_exit_code, int) and not isinstance(self.worker_exit_code, bool):
            result["exit_code"] = self.worker_exit_code
        if self.worker_exception_type in _WORKER_EXCEPTION_TYPES:
            result["exception_type"] = self.worker_exception_type
        return result


def from_worker_frame(
    frame: Mapping[str, object],
    *,
    fallback_code: str,
    stage: TtsErrorStage,
    request_id: str | None = None,
    worker_attempt_id: str | None = None,
) -> TtsBackendError:
    """Translate one private worker error frame into a typed failure.

    ``stderr_tail`` may be present for local diagnostics. It is never used for
    classification and never becomes the exception message.
    """

    raw_code = frame.get("code")
    code = (
        raw_code.strip()
        if isinstance(raw_code, str) and raw_code.strip()
        else fallback_code
    )
    message = frame.get("message")
    detail = message.strip() if isinstance(message, str) and message.strip() else None
    frame_request_id = frame.get("request_id")
    effective_request_id = (
        frame_request_id
        if isinstance(frame_request_id, str) and frame_request_id
        else request_id
    )
    frame_attempt_id = frame.get("worker_attempt_id")
    effective_attempt_id = (
        frame_attempt_id
        if isinstance(frame_attempt_id, str) and frame_attempt_id
        else worker_attempt_id
    )
    raw_exception_type = frame.get("worker_exception_type")
    exception_type = raw_exception_type if isinstance(raw_exception_type, str) else None

    if code in TTS_PARAMETER_ERROR_CODES:
        return TtsBackendError(
            code,
            stage="validate",
            public_code=code,
            retryable=False,
            detail=detail,
            request_id=effective_request_id,
            worker_attempt_id=effective_attempt_id,
            worker_exception_type=exception_type,
        )
    if code == "worker_load_error":
        return TtsBackendError(
            code,
            stage="initialize",
            public_code="tts_initialization_failed",
            retryable=False,
            detail=detail,
            request_id=effective_request_id,
            worker_attempt_id=effective_attempt_id,
            worker_exception_type=exception_type,
        )
    if code == "worker_inference_error":
        return TtsBackendError(
            code,
            stage="infer",
            public_code="tts_inference_failed",
            retryable=False,
            detail=detail,
            request_id=effective_request_id,
            worker_attempt_id=effective_attempt_id,
            worker_exception_type=exception_type,
        )
    if code in {"worker_transport_error", "worker_frame_invalid"}:
        return TtsBackendError(
            code,
            stage=stage,
            public_code="tts_transport_failed",
            retryable=False,
            detail=detail,
            request_id=effective_request_id,
            worker_attempt_id=effective_attempt_id,
            worker_exception_type=exception_type,
        )
    if code == "worker_audio_frame_invalid":
        return TtsBackendError(
            code,
            stage="decode",
            public_code="output_invalid",
            retryable=False,
            detail=detail,
            request_id=effective_request_id,
            worker_attempt_id=effective_attempt_id,
            worker_exception_type=exception_type,
        )
    return TtsBackendError(
        code,
        stage=stage,
        public_code=code,
        retryable=False,
        detail=detail,
        request_id=effective_request_id,
        worker_attempt_id=effective_attempt_id,
        worker_exception_type=exception_type,
    )
