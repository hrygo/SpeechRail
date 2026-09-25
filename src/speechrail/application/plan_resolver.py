"""Pure request-to-plan resolution shared by every execution surface."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from types import MappingProxyType

from pydantic import BaseModel, ConfigDict, Field, field_validator

from speechrail.config.model_catalog import ModelCatalog
from speechrail.domain.model_spec import (
    ModelRole,
    ModelSpec,
    SpecTier,
    registry_from_catalog,
)
from speechrail.domain.task_plan import (
    AudioFormat,
    PlanModel,
    RequiredOutput,
    ResolvedPlan,
    TaskRequest,
)
from speechrail.service.profile_store import SelectionRecord


class PlanResolutionError(ValueError):
    """A request cannot be bound to one immutable, capability-safe plan."""


class AuthenticatedCombination(BaseModel):
    """One explicitly authenticated ASR/TTS spec pair."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    asr_spec: SpecTier
    tts_spec: SpecTier


class PlanEnvironment(BaseModel):
    """Read-only facts injected into resolution; constructing it performs no I/O."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    engine_revision: str = Field(min_length=1, max_length=128)
    voice_revisions: frozenset[str]
    authenticated_combinations: tuple[AuthenticatedCombination, ...]
    resource_profile_revision: str = Field(min_length=1, max_length=128)
    capability_evidence_revision: str = Field(min_length=1, max_length=128)
    limits: Mapping[str, int]

    @field_validator("limits")
    @classmethod
    def freeze_limits(cls, value: Mapping[str, int]) -> Mapping[str, int]:
        return MappingProxyType(dict(value))


def _selection(value: Mapping[str, object] | SelectionRecord) -> SelectionRecord:
    try:
        if isinstance(value, SelectionRecord):
            return value
        return SelectionRecord.model_validate(value)
    except Exception as exc:
        raise PlanResolutionError("selection identity is invalid") from exc


def _auto_combination(
    request: TaskRequest,
    selection: SelectionRecord,
    environment: PlanEnvironment,
) -> AuthenticatedCombination:
    if not request.allow_auto:
        raise PlanResolutionError("auto resolution was not requested")
    if selection.auto != "resource":
        raise PlanResolutionError("auto resolution is disabled by selection policy")
    for combination in environment.authenticated_combinations:
        if request.asr_spec is not None and combination.asr_spec != request.asr_spec:
            continue
        if request.tts_spec is not None and combination.tts_spec != request.tts_spec:
            continue
        return combination
    raise PlanResolutionError("auto model selection has no authenticated combination")


def _tts_role(request: TaskRequest) -> ModelRole:
    if request.kind == "voice_design":
        return "voice_design"
    if request.voice_revision is not None:
        return "tts_base"
    return "tts_custom_voice"


def _resolve_model(
    registry,
    tier: SpecTier,
    role: ModelRole,
    *,
    language: str,
) -> ModelSpec:
    try:
        spec = registry.get(tier, role)
    except KeyError as exc:
        raise PlanResolutionError(
            f"unavailable model artifact for requested spec: {tier}/{role}"
        ) from exc
    if language not in spec.languages:
        raise PlanResolutionError(f"language {language} is unsupported by {spec.spec_id}")
    return spec


def _plan_payload(
    request: TaskRequest,
    *,
    asr_spec: SpecTier | None,
    tts_spec: SpecTier | None,
    models: tuple[PlanModel, ...],
    environment: PlanEnvironment,
) -> dict[str, object]:
    return {
        "task_id": request.task_id,
        "kind": request.kind,
        "selection_generation": request.selection_generation,
        "asr_spec": asr_spec,
        "tts_spec": tts_spec,
        "models": [model.model_dump(mode="json") for model in models],
        "voice_revision": request.voice_revision,
        "input_format": request.input_format.model_dump(mode="json"),
        "required_outputs": sorted(item.value for item in request.required_outputs),
        "resource_profile_revision": environment.resource_profile_revision,
        "capability_evidence_revision": environment.capability_evidence_revision,
        "limits": dict(environment.limits),
    }


def resolve_plan(
    request: TaskRequest,
    selection: Mapping[str, object] | SelectionRecord,
    catalog: ModelCatalog,
    *,
    environment: PlanEnvironment,
) -> ResolvedPlan:
    """Resolve one task without loading models, starting processes, or using the network."""

    if not isinstance(catalog, ModelCatalog):
        raise PlanResolutionError("catalog must be a ModelCatalog")
    record = _selection(selection)
    if record.generation != request.selection_generation:
        raise PlanResolutionError("selection generation changed before plan resolution")
    if (
        request.voice_revision is not None
        and request.voice_revision not in environment.voice_revisions
    ):
        raise PlanResolutionError("unknown voice_revision")

    if request.allow_auto and (request.asr_spec is None or request.tts_spec is None):
        combination = _auto_combination(request, record, environment)
        asr_spec = request.asr_spec or combination.asr_spec
        tts_spec = request.tts_spec or combination.tts_spec
    else:
        asr_spec = request.asr_spec
        tts_spec = request.tts_spec

    registry = registry_from_catalog(catalog, engine_revision=environment.engine_revision)
    specs: list[ModelSpec] = []
    needs_asr = any(
        output in request.required_outputs
        for output in (RequiredOutput.TEXT, RequiredOutput.ALIGNMENT)
    )
    needs_tts = (
        RequiredOutput.AUDIO in request.required_outputs or request.kind == "voice_design"
    )
    if needs_asr:
        if asr_spec is None:
            raise PlanResolutionError("ASR spec is required")
        specs.append(_resolve_model(registry, asr_spec, "asr", language=request.language))
    if needs_tts:
        if tts_spec is None:
            raise PlanResolutionError("TTS spec is required")
        specs.append(
            _resolve_model(registry, tts_spec, _tts_role(request), language=request.language)
        )
    if RequiredOutput.ALIGNMENT in request.required_outputs:
        if asr_spec is None:
            raise PlanResolutionError("alignment requires an ASR spec")
        alignment = _resolve_model(
            registry, asr_spec, "alignment", language=request.language
        )
        if all(spec.artifact_key != alignment.artifact_key for spec in specs):
            specs.append(alignment)
    if RequiredOutput.DIARIZATION in request.required_outputs:
        raise PlanResolutionError("diarization resolution is not available in this build")

    models = tuple(
        PlanModel(
            spec_id=spec.spec_id,
            role=spec.role,
            tier=spec.tier,
            artifact_key=spec.artifact_key,
            artifact_revision=spec.artifact_revision,
            engine_revision=spec.engine_revision,
        )
        for spec in specs
    )
    if not models:
        raise PlanResolutionError("task requires no executable model")

    payload = _plan_payload(
        request,
        asr_spec=asr_spec,
        tts_spec=tts_spec,
        models=models,
        environment=environment,
    )
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()
    return ResolvedPlan(
        plan_id=f"plan_{digest[:32]}",
        task_id=request.task_id,
        selection_generation=record.generation,
        asr_spec=asr_spec,
        tts_spec=tts_spec,
        models=models,
        voice_revision=request.voice_revision,
        input_format=request.input_format,
        kernel_format=AudioFormat(sample_rate=16_000, channels=1),
        output_format=request.input_format,
        limits=environment.limits,
        required_outputs=request.required_outputs,
        resource_profile_revision=environment.resource_profile_revision,
        capability_evidence_revision=environment.capability_evidence_revision,
        digest=digest,
    )


__all__ = [
    "AuthenticatedCombination",
    "PlanEnvironment",
    "PlanResolutionError",
    "resolve_plan",
]
