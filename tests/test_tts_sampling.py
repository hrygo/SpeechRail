"""Sampling facts a worker reports about the sampler it actually used."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from speechrail.domain.tts_sampling import TtsSamplingObservation


def test_unseeded_sampler_is_named_as_such() -> None:
    observation = TtsSamplingObservation(
        seed_policy="unseeded_sampler",
        seed=None,
        temperature=0.7,
        top_p=0.95,
        repetition_penalty=1.1,
    )

    assert observation.is_reproducible is False
    assert observation.recipe_payload()["seed_policy"] == "unseeded_sampler"
    assert observation.recipe_payload()["seed"] is None


@pytest.mark.parametrize(
    "seed_policy",
    ["caller_fixed", "clone_reference_derived", "voice_profile_fixed"],
)
def test_every_fixed_seed_policy_is_reproducible(seed_policy: str) -> None:
    observation = TtsSamplingObservation(
        seed_policy=seed_policy,
        seed=101,
        temperature=0.7,
        top_p=0.95,
        repetition_penalty=1.1,
    )

    assert observation.is_reproducible is True
    assert observation.recipe_payload()["seed"] == 101


def test_unknown_seed_policy_is_rejected() -> None:
    with pytest.raises(ValidationError):
        TtsSamplingObservation(
            seed_policy="best_effort_reproducible",
            seed=1,
            temperature=0.7,
            top_p=0.95,
            repetition_penalty=1.1,
        )


@pytest.mark.parametrize(
    ("temperature", "top_p", "repetition_penalty", "seed"),
    [
        (-0.1, 0.95, 1.1, 1),
        (0.7, 1.5, 1.1, 1),
        # `top_p` is bounded on both sides. Only the upper bound used to be
        # covered, so dropping `gt=0` from the field left every test green.
        (0.7, 0.0, 1.1, 1),
        (0.7, -0.5, 1.1, 1),
        (0.7, 0.95, 0.0, 1),
        (0.7, 0.95, 1.1, -1),
    ],
)
def test_out_of_range_sampling_values_are_rejected(
    temperature: float,
    top_p: float,
    repetition_penalty: float,
    seed: int,
) -> None:
    with pytest.raises(ValidationError):
        TtsSamplingObservation(
            seed_policy="caller_fixed",
            seed=seed,
            temperature=temperature,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
        )


def test_unknown_fields_are_rejected() -> None:
    """A newer worker may send more, but this build must not invent a reading."""
    with pytest.raises(ValidationError):
        TtsSamplingObservation.model_validate(
            {
                "seed_policy": "caller_fixed",
                "seed": 1,
                "temperature": 0.7,
                "top_p": 0.95,
                "repetition_penalty": 1.1,
                "guidance_scale": 3.0,
            }
        )
