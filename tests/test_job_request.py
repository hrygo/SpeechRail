from __future__ import annotations

import math

import pytest

from speechrail.domain.job_request import JobParamsValidationError, validate_job_params


def test_job_params_are_strictly_kind_specific() -> None:
    validate_job_params(
        "speech",
        {
            "voice": "clone",
            "speed": 1.0,
            "validation_policy": "require_output_pass",
        },
    )
    validate_job_params("transcription", {"language": "zh", "timestamps": True})

    with pytest.raises(JobParamsValidationError, match="unsupported speech params"):
        validate_job_params("speech", {"timestamps": True})
    with pytest.raises(JobParamsValidationError, match="unsupported transcription params"):
        validate_job_params("transcription", {"voice": "serena"})


@pytest.mark.parametrize("speed", [math.inf, -math.inf, math.nan, 10**400])
def test_job_params_reject_non_finite_or_unbounded_speed(speed: object) -> None:
    with pytest.raises(JobParamsValidationError, match="invalid value"):
        validate_job_params("speech", {"speed": speed})


def test_job_params_reject_unknown_kind() -> None:
    with pytest.raises(JobParamsValidationError, match="unsupported job kind"):
        validate_job_params("unknown", {})
