"""Voice discovery projection shared by HTTP adapters."""

from __future__ import annotations

from typing import Any

from speechrail.application.capability_snapshot import _validation_state
from speechrail.application.voice_validation_gate import validation_state_for_voice
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.tts import VOICE_ALIASES, VoiceProfile, get_voice_registry
from speechrail.domain.tts_routing import TtsExecutionMode, tts_capability_key
from speechrail.domain.voice_preview import preview_for_profile
from speechrail.domain.voice_validation import VoiceValidationStoreUnavailableError


def voice_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    tts_ready: bool,
    *,
    enabled: bool = True,
    synthesizer: object | None = None,
    strict_validation: bool = False,
    include_streaming: bool = False,
    stream_service: Any | None = None,
) -> dict[str, Any]:
    """Project a voice profile for discovery responses.

    Shared by discovery and voice-design HTTP adapters.
    """
    from speechrail.application.tts_stream_capability import (
        resolve_tts_stream_capability,
        tts_stream_capability_payload,
    )

    artifact = active.artifact_for_voice_mode(profile.mode)
    variant: str | None = artifact.variant if artifact is not None else None
    injected_backend = (
        active.tts is None
        and active.tts_clone is None
        and active.voice_design is None
        and synthesizer is not None
    )
    if artifact is None and injected_backend:
        variant = {
            "system": "custom_voice",
            "clone": "base",
        }.get(profile.mode)
    available = (
        tts_ready
        and enabled
        and not profile.revoked
        and profile.runtime_role is not None
        and (artifact is not None or variant is not None)
    )
    validation: dict[str, Any] | None = None
    validation_state: dict[str, object]
    capability_key = (
        tts_capability_key(active.tts_spec, TtsExecutionMode.RENDER)
        if active.tts_spec is not None
        else None
    )
    if profile.mode == "clone":
        try:
            repository = get_voice_registry().validation_store
            if strict_validation:
                validation_state, validation, _ = validation_state_for_voice(
                    profile,
                    artifact,
                    repository,
                    synthesizer,
                    require_current_binding=True,
                    capability_key=capability_key,
                )
            else:
                validation = repository.get(
                    voice_id=profile.id,
                    voice_revision=profile.revision,
                    model_artifact=artifact.key if artifact is not None else None,
                    model_catalog_revision=artifact.revision if artifact is not None else None,
                )
                validation_state = _validation_state(profile, artifact, validation)
        except VoiceValidationStoreUnavailableError:
            validation = None
            validation_state = _validation_state(profile, artifact, validation)
    else:
        validation_state = _validation_state(profile, artifact, validation)
    supports_speaker = False
    supports_instruction = False
    supports_clone = False
    binding_resolved = True
    binding_variant = variant
    if binding_variant in {"voice_design", "custom_voice", "base"}:
        try:
            binding = resolve_binding(binding_variant, profile.id)
        except ValueError:
            available = False
            binding_resolved = False
        else:
            capabilities = binding.capabilities
            supports_speaker = capabilities.supports_speaker
            supports_instruction = capabilities.supports_instruction
            supports_clone = capabilities.supports_clone

    entry: dict[str, Any] = {
        "id": profile.id,
        "name": profile.name or profile.id,
        "description": profile.description,
        "instruction": profile.instruction,
        "seed": profile.seed,
        "aliases": sorted(alias for alias, preset in VOICE_ALIASES.items() if preset == profile.id),
        "is_default": profile.is_default,
        "is_system": profile.is_system,
        "created_at": profile.created_at,
        "available": available,
        "availability_reason": (
            "disabled"
            if not enabled
            else "voice_revoked"
            if profile.revoked
            else "backend_not_ready"
            if not tts_ready
            else "voice_design_task_required"
            if profile.runtime_role is None
            else "binding_unavailable"
            if not binding_resolved
            else "voice_not_available"
            if not available
            else "available"
        ),
        "variant": binding_variant,
        "capabilities": {
            "supports_speaker": supports_speaker,
            "supports_instruction": supports_instruction,
            "supports_clone": supports_clone,
        },
        "mode": profile.mode,
        "validation_state": validation_state,
        "validated_for": validation_state["validated_for"],
        "production_ready": available and validation_state["production_ready"] is True,
        "production_ready_reason": (
            validation_state["production_ready_reason"] if available else "voice_not_available"
        ),
    }
    if profile.ref_text is not None:
        entry["ref_text"] = profile.ref_text
    preview = preview_for_profile(profile)
    if preview is not None:
        entry["preview"] = preview
    if profile.duration_seconds > 0:
        entry["duration_seconds"] = profile.duration_seconds
    if profile.quality is not None:
        entry["quality"] = profile.quality
    if profile.creation is not None:
        entry["creation"] = profile.creation.model_dump(mode="json")
    if profile.revision is not None:
        entry["revision"] = profile.revision
    if profile.revoked:
        entry["revoked"] = True
    if include_streaming:
        entry["streaming"] = tts_stream_capability_payload(
            resolve_tts_stream_capability(
                voice_id=profile.id,
                voice_mode=profile.mode,
                artifact=artifact,
                tts_ready=tts_ready,
                voice_enabled=available,
                synthesizer=synthesizer,
                stream_service=stream_service,
            )
        )
    return entry


def quality_reject_content(
    request_id: str, report: vq.VoiceQualityReport
) -> tuple[int, dict[str, Any], dict[str, str]]:
    """Shared quality-gate reject envelope payload (routes wrap it in HTTP)."""
    from speechrail.http.errors import error as _http_error

    content = _http_error(
        message="Reference audio failed the voice quality gate",
        error_type="invalid_request_error",
        code="voice_quality_reject",
        request_id=request_id,
        retryable=False,
    )
    content["quality_report"] = report.to_dict()
    return 400, content, {"X-SpeechRail-Error-Code": "voice_quality_reject"}
