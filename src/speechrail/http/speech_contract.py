"""The SpeechRail-only extension boundary of ``POST /v1/audio/speech``.

OpenAI's speech endpoint has no ``language`` parameter, so SpeechRail used to
carry language and admission policy inside the "OpenAI-compatible" body.  A
client that sent them got a ``200`` and silently ignored values, which is worse
than a rejection: the caller believed it had chosen a language.

Extensions now travel in ``SpeechRail-*`` request headers, and the removed body
fields are refused with a stable error that names the replacement.  Unknown
fields are refused too, so a typo can never look like a successful request.
"""

from __future__ import annotations

from collections.abc import Mapping
from types import MappingProxyType

from fastapi.exceptions import RequestValidationError

SPEECH_ROUTE_PATH = "/v1/audio/speech"

#: Every field the OpenAI-compatible body still accepts.
STANDARD_SPEECH_BODY_FIELDS = frozenset(
    {
        "model",
        "input",
        "voice",
        "response_format",
        "speed",
        "instructions",
        "stream_format",
    }
)

#: Body field -> the request header that replaced it (``None`` when the plain
#: speech endpoint never supported the capability at all).
REMOVED_SPEECH_BODY_FIELDS: Mapping[str, str | None] = MappingProxyType(
    {
        "language": "SpeechRail-Language",
        "validation_policy": "SpeechRail-Validation-Policy",
        "seed": None,
    }
)


def removed_field_message(field: str) -> str:
    """Explain where a removed body field moved, without echoing user input."""

    replacement = REMOVED_SPEECH_BODY_FIELDS[field]
    if replacement is None:
        return (
            f"{field} is not accepted by {SPEECH_ROUTE_PATH}; ordinary synthesis "
            "does not support it."
        )
    return (
        f"{field} is not accepted in the OpenAI-compatible TTS body; "
        f"send it as the {replacement} request header instead."
    )


def _offending_body_field(exc: RequestValidationError, allowed: frozenset[str]) -> str | None:
    """Return the single reported top-level body field, if it is unambiguous."""

    fields = {
        issue["loc"][1]
        for issue in exc.errors()
        if isinstance(issue.get("loc"), (tuple, list))
        and len(issue["loc"]) >= 2
        and issue["loc"][0] == "body"
        and isinstance(issue["loc"][1], str)
        and issue["loc"][1] in allowed
    }
    return next(iter(fields)) if len(fields) == 1 else None


def speech_validation_error(exc: RequestValidationError) -> tuple[str, str, str | None]:
    """Map a TTS request-validation failure onto the public error envelope.

    Returns ``(code, message, param)``.  A removed or unknown body field is
    reported as ``unsupported_parameter`` naming the field; every other schema
    failure keeps the generic ``validation_error`` code.
    """

    field = _offending_body_field(exc, frozenset(REMOVED_SPEECH_BODY_FIELDS))
    if field is not None:
        return "unsupported_parameter", removed_field_message(field), field
    return (
        "validation_error",
        "Request validation failed",
        _offending_body_field(exc, STANDARD_SPEECH_BODY_FIELDS),
    )


__all__ = [
    "REMOVED_SPEECH_BODY_FIELDS",
    "SPEECH_ROUTE_PATH",
    "STANDARD_SPEECH_BODY_FIELDS",
    "removed_field_message",
    "speech_validation_error",
]
