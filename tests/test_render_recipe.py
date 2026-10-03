"""Recipe identity rules.

These are pure-function tests: no models, no network, no audio.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from speechrail.application.render_recipe import build_render_recipe
from speechrail.domain.render_recipe import (
    PRONUNCIATION_UNUSED,
    RENDER_RECIPE_SCHEMA_VERSION,
    RenderRecipe,
    render_plan_identity,
    text_sha256,
)


def _complete_recipe(**overrides: object) -> RenderRecipe:
    facts: dict[str, object] = {
        "raw_text": "今天讲清楚制作配方的用途。",
        "acoustic_text": "今天讲清楚制作配方的用途。",
        "normalization_revision": "tts_norm_v1",
        "planner_revision": "tts_bounded_v1",
        "planner_max_chars": 240,
        "pronunciation_set_id": None,
        "pronunciation_revision": None,
        "voice_id": "narrator",
        "voice_revision": "vr_" + "a" * 32,
        "voice_mode": "custom",
        "model_role": "tts",
        "model_artifact": "tts-artifact",
        "model_artifact_revision": "cat-1",
        "engine_revision": "rt_" + "b" * 64,
        "effective_speed": 1.0,
        "effective_language": "zh",
        "seed_policy": "derived",
        "output_format": "wav",
        "sample_rate": 24_000,
        "channels": 1,
    }
    facts.update(overrides)
    return build_render_recipe(**facts)  # type: ignore[arg-type]


def test_a_fully_observed_recipe_is_complete_and_digested() -> None:
    recipe = _complete_recipe()

    assert recipe.state == "complete"
    assert recipe.missing_fields == ()
    assert recipe.digest is not None
    payload = recipe.to_dict()
    assert payload["schema_version"] == RENDER_RECIPE_SCHEMA_VERSION
    assert payload["state"] == "complete"
    assert payload["digest"] == recipe.digest


def test_the_recipe_records_the_original_text_and_the_spoken_text_separately() -> None:
    """`raw_text` is what the caller wrote; `acoustic_text` is what was spoken.

    A pronunciation set rewrites the text before synthesis
    (`audio.py:1876`), so the two are genuinely different facts. Recording one
    hash for both would claim the spoken text was the original — and the
    digest adoption trusts is taken over exactly these fields.
    """

    recipe = _complete_recipe(
        raw_text="3 月 5 日见。",
        acoustic_text="三月五日见。",
    )

    assert recipe.raw_text_sha256 == text_sha256("3 月 5 日见。")
    assert recipe.acoustic_text_sha256 == text_sha256("三月五日见。")
    assert recipe.raw_text_sha256 != recipe.acoustic_text_sha256


def test_the_recipe_digest_is_pinned_to_its_canonical_form() -> None:
    # Canonical form is part of the contract: stored recipes compare digests
    # across versions, so a silent change here invalidates saved works.
    assert _complete_recipe().digest == (
        "94a1b6873d2979a6c1bd341012d17d0194e2b505b22825d27ce900d2628fbed3"
    )


def test_no_pronunciation_set_is_a_fact_not_a_gap() -> None:
    recipe = _complete_recipe()

    assert recipe.pronunciation_revision == PRONUNCIATION_UNUSED
    assert "content.pronunciation_revision" not in recipe.missing_fields
    assert recipe.state == "complete"


def test_an_unobserved_runtime_keeps_the_recipe_partial_and_undigested() -> None:
    recipe = _complete_recipe(engine_revision=None)

    assert recipe.state == "partial"
    assert recipe.missing_fields == ("model.engine_revision",)
    assert recipe.digest is None
    assert recipe.to_dict()["digest"] is None


def test_a_missing_seed_policy_is_reported_instead_of_guessed() -> None:
    recipe = _complete_recipe(seed_policy=None)

    assert recipe.missing_fields == ("parameters.seed_policy",)
    assert recipe.seed_policy is None


def test_text_changes_invalidate_the_digest_but_not_the_plan() -> None:
    first = _complete_recipe()
    second = _complete_recipe(raw_text="换一段文稿。", acoustic_text="换一段文稿。")

    assert first.digest != second.digest
    assert render_plan_identity(first).plan_id == render_plan_identity(second).plan_id


def test_every_execution_parameter_changes_the_digest_and_the_plan() -> None:
    baseline = _complete_recipe()
    for field, value in (
        ("effective_speed", 1.25),
        ("effective_language", "en"),
        ("voice_revision", "vr_" + "c" * 32),
        ("voice_mode", "system"),
        ("model_role", "asr"),
        ("model_artifact", "tts-artifact-2"),
        ("model_artifact_revision", "cat-2"),
        ("engine_revision", "rt_" + "d" * 64),
        ("sample_rate", 16_000),
        ("output_format", "pcm16"),
        ("planner_max_chars", 180),
        ("normalization_revision", "tts_norm_v2"),
        ("pronunciation_revision", "pr_" + "e" * 32),
        ("channels", 2),
    ):
        changed = _complete_recipe(**{field: value})
        assert changed.digest != baseline.digest, field
        baseline_plan = render_plan_identity(baseline).plan_id
        changed_plan = render_plan_identity(changed).plan_id
        if field == "engine_revision":
            # Runtime identity belongs to "what actually ran", not to "how this
            # would execute": it must move the recipe digest and must NOT move
            # plan_id.
            #
            # This branch must not be written as
            # `... != ... or field == "engine_revision"`: that parses as
            # `... or True`, leaving a tautology. Adding engine_revision to
            # plan_id would then leave this whole file green.
            assert changed_plan == baseline_plan, field
        else:
            assert changed_plan != baseline_plan, field


def test_plan_identity_describes_execution_not_content() -> None:
    plan = render_plan_identity(_complete_recipe())

    assert plan.plan_id.startswith("plan_")
    assert len(plan.plan_id) == len("plan_") + 32
    assert len(plan.digest) == 64
    assert plan.digest.startswith(plan.plan_id.removeprefix("plan_"))


def test_text_hashing_is_stable_for_unicode_and_empty_text() -> None:
    assert text_sha256("") == (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    assert text_sha256("语音") == text_sha256("语音")
    assert text_sha256("语音") != text_sha256("語音")


@pytest.mark.parametrize(
    ("field", "missing_path"),
    [
        ("raw_text_sha256", "content.raw_text_sha256"),
        ("acoustic_text_sha256", "content.acoustic_text_sha256"),
        ("normalization_revision", "content.normalization_revision"),
        ("planner_revision", "content.planner_revision"),
        ("pronunciation_revision", "content.pronunciation_revision"),
        ("voice_id", "voice.id"),
        ("voice_revision", "voice.revision"),
        ("model_role", "model.role"),
        ("model_artifact", "model.artifact"),
        ("model_artifact_revision", "model.artifact_revision"),
        ("engine_revision", "model.engine_revision"),
        ("effective_speed", "parameters.effective_speed"),
        ("effective_language", "parameters.effective_language"),
        ("seed_policy", "parameters.seed_policy"),
    ],
)
def test_dropping_any_required_fact_is_reported(field: str, missing_path: str) -> None:
    recipe = replace(_complete_recipe(), **{field: None})

    assert recipe.state == "partial"
    assert recipe.digest is None
    assert missing_path in recipe.missing_fields


@pytest.mark.parametrize(
    "kwargs",
    [
        {"sample_rate": 0},
        {"channels": 0},
        {"output_format": ""},
        {"raw_text_sha256": "not-a-digest"},
        {"effective_speed": float("inf")},
        {"planner_max_chars": 0},
    ],
)
def test_malformed_facts_are_refused(kwargs: dict[str, object]) -> None:
    with pytest.raises(ValueError):
        RenderRecipe(
            **{"output_format": "wav", "sample_rate": 24_000, "channels": 1, **kwargs}
        )


@pytest.mark.parametrize(
    "field",
    [
        "normalization_revision",
        "planner_revision",
        "pronunciation_set_id",
        "pronunciation_revision",
        "voice_id",
        "voice_revision",
        "voice_mode",
        "model_role",
        "model_artifact",
        "model_artifact_revision",
        "engine_revision",
        "effective_language",
        "seed_policy",
    ],
)
def test_a_blank_optional_fact_is_refused_rather_than_taken_as_observed(
    field: str,
) -> None:
    """An empty string is not an observed fact.

    `missing_fields` reads "not None" as observed, so a blank value that got
    through would report the recipe as complete and hand it a digest — the
    module docstring's "presents an unobserved fact as known" failure.
    """

    with pytest.raises(ValueError):
        _complete_recipe(**{field: ""})


@pytest.mark.parametrize("field", ["voice_id", "model_artifact", "seed_policy"])
def test_a_non_string_optional_fact_is_refused(field: str) -> None:
    with pytest.raises(ValueError):
        _complete_recipe(**{field: 7})
