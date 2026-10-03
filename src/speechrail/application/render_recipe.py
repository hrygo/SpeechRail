"""Assemble a render recipe from facts the request path has already verified.

Every argument here comes from a decision this process made or observed. A
caller that cannot supply a fact passes ``None``: the recipe then reports
`partial` with the missing field named, which is the only honest option.
"""

from __future__ import annotations

from speechrail.domain.render_recipe import (
    PRONUNCIATION_UNUSED,
    RenderRecipe,
    text_sha256,
)


def build_render_recipe(
    *,
    raw_text: str,
    acoustic_text: str,
    normalization_revision: str,
    planner_revision: str,
    planner_max_chars: int | None,
    pronunciation_set_id: str | None,
    pronunciation_revision: str | None,
    voice_id: str,
    voice_revision: str | None,
    voice_mode: str | None,
    model_role: str,
    model_artifact: str | None,
    model_artifact_revision: str | None,
    engine_revision: str | None,
    effective_speed: float | None,
    effective_language: str | None,
    seed_policy: str | None,
    output_format: str,
    sample_rate: int,
    channels: int = 1,
) -> RenderRecipe:
    """Build one recipe.

    `engine_revision` is filled in later when the worker identity is observed,
    so a render that never binds one stays partial instead of borrowing the
    source revision as if it were the runtime that produced the audio.
    """

    if pronunciation_revision is None and pronunciation_set_id is None:
        # No set was requested: "not used" is a fact, not a gap.
        pronunciation_revision = PRONUNCIATION_UNUSED
    return RenderRecipe(
        output_format=output_format,
        sample_rate=sample_rate,
        channels=channels,
        raw_text_sha256=text_sha256(raw_text),
        acoustic_text_sha256=text_sha256(acoustic_text),
        normalization_revision=normalization_revision,
        planner_revision=planner_revision,
        planner_max_chars=planner_max_chars,
        pronunciation_set_id=pronunciation_set_id,
        pronunciation_revision=pronunciation_revision,
        voice_id=voice_id,
        voice_revision=voice_revision,
        voice_mode=voice_mode,
        model_role=model_role,
        model_artifact=model_artifact,
        model_artifact_revision=model_artifact_revision,
        engine_revision=engine_revision,
        effective_speed=effective_speed,
        effective_language=effective_language,
        seed_policy=seed_policy,
    )
