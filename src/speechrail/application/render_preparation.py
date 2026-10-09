"""Pure render planning from already validated request and catalog facts."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from speechrail.application.render_recipe import build_render_recipe
from speechrail.config.model_catalog import ModelArtifact
from speechrail.domain.ports import SpeechRequest
from speechrail.domain.render_recipe import RenderRecipe
from speechrail.domain.tts import (
    TTS_NORMALIZATION_REVISION,
    VoiceProfile,
    normalize_tts_text,
    tts_voice_class,
)
from speechrail.domain.tts_pronunciation import PronunciationSet, SpokenText, apply_pronunciation
from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner


@dataclass(frozen=True, slots=True)
class RenderTimingPlan:
    display_mapping_status: Literal["identity", "mapped", "unavailable"]
    expected_text_spans: tuple[tuple[int, int], ...]
    display_spans: tuple[tuple[int, int] | None, ...]
    display_mapping_reason: str | None = None


@dataclass(frozen=True, slots=True)
class RenderPreparation:
    request: SpeechRequest
    recipe: RenderRecipe | None
    timing: RenderTimingPlan | None
    text_summary: dict[str, object] | None
    planner_summary: dict[str, object] | None


def _timing_plan(raw_text: str, acoustic_text: str, spoken: SpokenText | None) -> RenderTimingPlan:
    normalized = normalize_tts_text(acoustic_text)
    planner = TtsTextPlanner()
    plan = planner.plan(normalized)
    expected = tuple((item.source_start, item.source_end) for item in plan.chunks)
    if spoken is not None and normalized == spoken.text:
        mapped = planner.plan_spoken(spoken)
        if tuple((item.source_start, item.source_end) for item in mapped.chunks) != expected:
            return RenderTimingPlan("unavailable", expected, (), "planner_mapping_mismatch")
        spans = tuple(
            (item.raw_start, item.raw_end)
            if item.raw_start is not None and item.raw_end is not None
            else None
            for item in mapped.chunks
        )
        if any(item is None for item in spans):
            return RenderTimingPlan("unavailable", expected, (), "display_mapping_ambiguous")
        return RenderTimingPlan("mapped", expected, spans)
    if normalized == raw_text and acoustic_text == raw_text:
        return RenderTimingPlan("identity", expected, expected)
    return RenderTimingPlan(
        "unavailable", expected, (), "normalization_changed_display_coordinates"
    )


def prepare_render(
    request: SpeechRequest,
    *,
    profile: VoiceProfile,
    artifact: ModelArtifact | None,
    output_format: str,
    sample_rate: int,
    pronunciation: PronunciationSet | None = None,
    integrity: bool = False,
) -> RenderPreparation:
    """Capture synthesis text, pinned revision, timing coordinates and recipe."""
    spoken = (
        apply_pronunciation(request.text, pronunciation, language=request.language)
        if pronunciation is not None
        else None
    )
    acoustic_text = spoken.text if spoken is not None else request.text
    text_summary = spoken.summary() if spoken is not None else None
    planner = TtsTextPlanner()
    planner_summary = planner.plan(acoustic_text).summary() if spoken is not None else None
    timing = (
        _timing_plan(request.text, acoustic_text, spoken)
        if request.timing_mode == "chunk"
        else None
    )
    effective_revision = request.expected_voice_revision
    recipe = None
    if integrity:
        if effective_revision is None:
            effective_revision = profile.revision
        recipe = build_render_recipe(
            raw_text=request.text,
            acoustic_text=acoustic_text,
            normalization_revision=TTS_NORMALIZATION_REVISION,
            planner_revision=PLANNER_VERSION,
            planner_max_chars=planner.max_chars,
            pronunciation_set_id=spoken.pronunciation_set_id if spoken is not None else None,
            pronunciation_revision=spoken.pronunciation_revision if spoken is not None else None,
            voice_id=request.voice,
            voice_revision=profile.revision,
            voice_mode=tts_voice_class(request.voice, profile=profile),
            model_role="tts",
            model_artifact=artifact.key if artifact is not None else None,
            model_artifact_revision=artifact.revision if artifact is not None else None,
            engine_revision=None,
            effective_speed=request.speed,
            effective_language=request.language,
            seed_policy=None,
            output_format=output_format,
            sample_rate=sample_rate,
            channels=1,
        )
    return RenderPreparation(
        request=request.model_copy(
            update={"text": acoustic_text, "expected_voice_revision": effective_revision}
        ),
        recipe=recipe,
        timing=timing,
        text_summary=text_summary,
        planner_summary=planner_summary,
    )
