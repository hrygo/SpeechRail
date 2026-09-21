"""Shared validation for durable transcription and speech job parameters."""

from __future__ import annotations

import math

_MAX_VOICE_SEED = 2**32 - 1
_SPEED_RANGE = (0.25, 4.0)
_MAX_INSTRUCTION = 10_000


class JobParamsValidationError(ValueError):
    """A deterministic public job-parameter rejection."""


def _valid_speed(value: object) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        numeric = float(value)
    except (OverflowError, ValueError):
        return False
    return math.isfinite(numeric) and _SPEED_RANGE[0] <= numeric <= _SPEED_RANGE[1]


def validate_job_params(kind: str, params: object) -> None:
    """Validate one durable job's kind-specific parameter object.

    The REST route and MCP proxy deliberately call this same pure validator so
    the two boundaries cannot publish different accepted parameter sets.
    """

    if kind not in {"speech", "transcription"}:
        raise JobParamsValidationError("unsupported job kind")
    if not isinstance(params, dict):
        raise JobParamsValidationError("params must be a JSON object")
    allowed = (
        {"language", "diarize", "timestamps"}
        if kind == "transcription"
        else {
            "voice",
            "speed",
            "language",
            "instruction",
            "seed",
            "validation_policy",
        }
    )
    if any(not isinstance(key, str) for key in params):
        raise JobParamsValidationError("params keys must be strings")
    unknown = sorted(set(params) - allowed)
    if unknown:
        raise JobParamsValidationError(
            f"unsupported {kind} params: {', '.join(unknown)}"
        )

    invalid = False
    if kind == "transcription":
        invalid = any(
            (
                key == "language"
                and (
                    not isinstance(value, str)
                    or not value.strip()
                    or len(value) > 64
                )
            )
            or (key in {"diarize", "timestamps"} and type(value) is not bool)
            for key, value in params.items()
        )
    else:
        invalid = any(
            (
                key in {"voice", "language"}
                and (
                    not isinstance(value, str)
                    or not value.strip()
                    or len(value) > (200 if key == "voice" else 64)
                )
            )
            or (
                key == "instruction"
                and value is not None
                and (not isinstance(value, str) or len(value) > _MAX_INSTRUCTION)
            )
            or (
                key == "speed"
                and not _valid_speed(value)
            )
            or (
                key == "seed"
                and (
                    value is not None
                    and (type(value) is not int or not 0 <= value <= _MAX_VOICE_SEED)
                )
            )
            or (
                key == "validation_policy"
                and value not in {"allow_unverified", "require_output_pass"}
            )
            for key, value in params.items()
        )
    if invalid:
        raise JobParamsValidationError("job params contain an invalid value")


__all__ = ["JobParamsValidationError", "validate_job_params"]
