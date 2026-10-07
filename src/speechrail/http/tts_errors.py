"""Stable TTS error envelopes shared by HTTP adapters."""

import logging

from fastapi.responses import JSONResponse

from speechrail.domain.tts_errors import TTS_PARAMETER_ERROR_CODES, TtsBackendError
from speechrail.http.errors import error_response

_LOGGER = logging.getLogger(__name__)


def tts_backend_error_response(
    request_id: str,
    exc: BaseException,
    *,
    worker_role: str | None = None,
) -> JSONResponse | None:
    """Map a typed TTS failure with safe worker attribution."""

    if not isinstance(exc, TtsBackendError):
        return None
    if exc.worker_role is None:
        exc.worker_role = worker_role
    worker = exc.worker_diagnostics
    _LOGGER.warning(
        "tts request failed: request_id=%s code=%s stage=%s diagnostic_class=%s "
        "worker_attempt_id=%s role=%s exit_code=%s exception_type=%s",
        request_id,
        exc.code,
        exc.stage,
        exc.diagnostic_class,
        worker.get("attempt_id"),
        worker.get("role"),
        worker.get("exit_code"),
        worker.get("exception_type"),
    )
    if exc.code in TTS_PARAMETER_ERROR_CODES:
        status_code = 400
        message = "TTS request parameters are unsupported for the selected voice"
    elif exc.public_code == "voice_not_production_ready":
        status_code = 409
        message = "The selected clone voice has no current passing output validation"
    elif exc.public_code == "voice_validation_runtime_changed":
        status_code = 409
        message = "The TTS worker changed after voice validation"
    elif exc.public_code in {
        "voice_validation_store_unavailable",
        "voice_validation_runtime_unavailable",
    }:
        status_code = 503
        message = "Voice validation could not confirm the current runtime"
    elif exc.public_code == "tts_initialization_failed":
        status_code = 503
        message = "TTS backend failed to initialize"
    elif exc.public_code == "tts_transport_failed":
        status_code = 503
        message = "TTS worker transport failed"
    elif exc.public_code == "backend_timeout":
        status_code = 503
        message = "Inference timed out"
    else:
        status_code = 502
        message = "TTS backend failed to synthesize audio"
    return error_response(
        status_code,
        request_id,
        exc.public_code,
        message,
        retryable=exc.retryable,
        diagnostic_class=exc.diagnostic_class,
        worker=worker,
        error_type="server_error" if status_code >= 500 else "invalid_request_error",
    )
