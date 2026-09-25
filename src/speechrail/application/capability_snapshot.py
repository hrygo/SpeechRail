"""Versioned safe discovery built from one detached registry generation.

Catalog revisions are content validators, NOT immutable voice identities or
inference locks. Configured artifact provenance is distinct from an observed
worker revision; unknown runtime identities remain null until an execution
receipt can substantiate them.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from typing import Any, Literal

from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain.tts import VOICE_ALIASES, VoiceProfile
from speechrail.domain.tts_reference_condition import (
    MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT,
)
from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner
from speechrail.domain.voice_validation import VoiceValidationArtifact

SCHEMA_VERSION = "effective_capabilities_v1"
Support = Literal["supported", "unsupported", "unknown"]
# Declared system preset metadata, not an inference from private instructions.
_SYSTEM_LOCALES = {
    "serena": "zh-CN",
    "vivian": "zh-CN",
    "uncle_fu": "zh-CN",
    "dylan": "zh-CN",
    "eric": "zh-CN",
    "ryan": "en-US",
    "aiden": "en-US",
    "ono_anna": "ja-JP",
    "sohee": "ko-KR",
}


def content_revision(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
    ).hexdigest()


def parameter(status: Support, **domain: object) -> dict[str, object]:
    return {"status": status, **domain}


def model_identity(artifact: ModelArtifact | None) -> dict[str, object]:
    if artifact is None:
        return {"assurance": "unknown", "runtime_revision": None}
    return {
        "source_model": artifact.model_id,
        "artifact": artifact.key,
        "variant": artifact.variant,
        "quantization": artifact.quantization.model_dump(mode="json"),
        "catalog_revision": artifact.revision,
        "runtime_revision": None,
        "assurance": "configured_catalog",
    }


def safe_voice_descriptor(profile: VoiceProfile) -> dict[str, object]:
    source = "system_preset" if profile.is_system else "instruction_profile"
    if profile.mode == "clone":
        source = "generated_reference" if profile.creation is not None else "reference_unknown"
    locale = _SYSTEM_LOCALES.get(profile.id) if profile.is_system else None
    return {
        "voice_mode": profile.mode,
        "locales": [locale] if locale is not None else [],
        "style_tags": [],
        "pitch_band": "unknown",
        "timbre_family": "unknown",
        "baseline_pace": "unknown",
        "source_type": source,
        "metadata_method": "declared_only",
    }


def _safe_quality_summary(value: Mapping[str, Any] | None) -> dict[str, object]:
    if value is None:
        return {"status": "unevaluated", "policy_version": None}
    status = value.get("status")
    policy = value.get("policy_version")
    # Do not expose arbitrary free-form metadata as discovery diagnostics.
    return {
        "status": (status if isinstance(status, str) and status in {
            "pass", "warn", "reject", "unevaluated"
        } else "unevaluated"),
        "policy_version": policy if policy == "voice_quality_v1" else None,
    }


def _validation_state(
    profile: VoiceProfile,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    validation: Mapping[str, Any] | None = None,
    *,
    runtime_revision: str | None = None,
    runtime_identity_status: Literal["not_requested", "unknown", "observed"] = (
        "not_requested"
    ),
    validation_binding: Mapping[str, Any] | None = None,
    binding_required: bool = False,
) -> dict[str, object]:
    """Project reference/output evidence without conflating their meaning."""

    quality = profile.quality if isinstance(profile.quality, Mapping) else {}
    reference_status = quality.get("status")
    if not isinstance(reference_status, str) or reference_status not in {
        "pass", "warn", "reject", "unevaluated"
    }:
        reference_status = "unevaluated"
    reference = {
        "status": reference_status,
        "policy_version": (
            quality.get("policy_version")
            if quality.get("policy_version") == "voice_quality_v1"
            else None
        ),
        "source": "reference_gate" if profile.mode == "clone" else "not_applicable",
    }

    if profile.mode != "clone":
        synthesis: dict[str, object] = {
            "status": "not_applicable",
            "reason": "not_a_reference_conditioned_voice",
        }
        identity: dict[str, object] = {
            "status": "not_applicable",
            "reason": "not_a_reference_conditioned_voice",
        }
    else:
        # Output evidence comes only from the independent validation store.
        # A legacy value embedded in the acoustic profile is never promoted to
        # a current pass because doing so would make validation mutate identity.
        raw = validation
        if not isinstance(raw, Mapping):
            synthesis = {
                "status": "unevaluated",
                "reason": (
                    "model_runtime_identity_unknown"
                    if binding_required and runtime_identity_status != "observed"
                    else
                    "legacy_synthesis_validation_not_reused"
                    if isinstance(quality.get("synthesis_validation"), Mapping)
                    else "synthesis_validation_not_run"
                ),
            }
            identity = {
                "status": "unevaluated",
                "reason": "identity_validation_not_run",
            }
        else:
            status = raw.get("status")
            status = status if status in {"pass", "warn", "reject"} else "unevaluated"
            stale_reason: str | None = None
            if raw.get("voice_revision") != profile.revision:
                stale_reason = "voice_revision_changed"
            elif artifact is None:
                stale_reason = "model_identity_unknown"
            elif raw.get("model_artifact") != artifact.key:
                stale_reason = "model_artifact_changed"
            elif raw.get("model_catalog_revision") != artifact.revision:
                stale_reason = "model_catalog_revision_changed"
            elif binding_required and runtime_identity_status != "observed":
                stale_reason = "model_runtime_identity_unknown"
            elif binding_required and validation_binding is not None:
                compared_keys = [
                    "model_runtime_revision",
                    "runtime_fingerprint",
                    "preprocess_version",
                    "generation_recipe_revision",
                    "policy_version",
                ]
                if validation_binding.get("capability_key") is not None:
                    # A scoped evidence record names the exact tier/mode it was
                    # observed for; an unscoped lookup must not borrow it.
                    compared_keys.append("capability_key")
                for key in compared_keys:
                    if raw.get(key) != validation_binding.get(key):
                        stale_reason = "validation_binding_changed"
                        break
            elif (
                runtime_revision is not None
                and raw.get("model_runtime_revision") is not None
                and raw.get("model_runtime_revision") != runtime_revision
            ):
                stale_reason = "model_runtime_revision_changed"
            if stale_reason is not None:
                synthesis = {
                    "status": "unevaluated",
                    "reason": "stale_synthesis_validation",
                    "stale_reason": stale_reason,
                }
                identity = {
                    "status": "unevaluated",
                    "reason": "stale_synthesis_validation",
                    "stale_reason": stale_reason,
                }
            else:
                synthesis = {
                    "status": status,
                    "run_id": (
                        raw.get("run_id") if isinstance(raw.get("run_id"), str) else None
                    ),
                    "tested_at": (
                        raw.get("tested_at")
                        if isinstance(raw.get("tested_at"), str)
                        else None
                    ),
                    "failure_codes": [
                        code for code in raw.get("failure_codes", [])
                        if isinstance(code, str)
                    ],
                    "validated_for": [
                        item for item in raw.get("validated_for", []) if isinstance(item, str)
                    ],
                }
                identity_status = raw.get("identity_status")
                identity = {
                    "status": (
                        identity_status
                        if identity_status in {"pass", "warn", "reject", "unevaluated"}
                        else "unevaluated"
                    ),
                    "reason": (
                        "identity_validation_not_run"
                        if identity_status not in {"pass", "warn", "reject"}
                        else None
                    ),
                }

    stale = bool(synthesis.get("stale_reason"))

    validated_for = synthesis.get("validated_for")
    output_validated = isinstance(validated_for, list) and "output" in validated_for
    production_ready = profile.mode != "clone" or (
        reference["status"] == "pass"
        and synthesis["status"] == "pass"
        and output_validated
        and not stale
        and (not binding_required or runtime_identity_status == "observed")
    )
    if production_ready:
        reason = "validated"
    elif profile.mode != "clone":
        reason = "not_a_reference_conditioned_voice"
    elif reference["status"] != "pass":
        reason = "reference_validation_not_passed"
    elif synthesis["status"] == "pass" and not output_validated:
        reason = "output_validation_scope_missing"
    else:
        reason = str(synthesis.get("reason") or "synthesis_validation_not_passed")
    return {
        "reference": reference,
        "synthesis": synthesis,
        "identity": identity,
        "stale": stale,
        "validated_for": synthesis.get("validated_for", []),
        "production_ready": production_ready,
        "production_ready_reason": reason,
    }


def _voice_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    *,
    ready: bool,
    enabled_voices: frozenset[str],
    sample_rate: int,
    validation: Mapping[str, Any] | None = None,
    runtime_revision: str | None = None,
    runtime_identity_status: Literal["not_requested", "unknown", "observed"] = (
        "not_requested"
    ),
    validation_binding: Mapping[str, Any] | None = None,
    binding_required: bool = False,
) -> dict[str, Any]:
    artifact = active.artifact_for_voice_mode(profile.mode)
    variant = artifact.variant if artifact is not None else None
    validation_state = _validation_state(
        profile,
        artifact,
        validation,
        runtime_revision=runtime_revision,
        runtime_identity_status=runtime_identity_status,
        validation_binding=validation_binding,
        binding_required=binding_required,
    )
    enabled = not profile.is_system or profile.id in enabled_voices
    compatible = False
    if variant is not None:
        try:
            # Crucial: resolve the captured profile, not a second registry read.
            resolve_binding(variant, profile.id, profile=profile)
        except ValueError:
            pass
        else:
            compatible = True
    reason = (
        "disabled"
        if not enabled
        else "voice_revoked"
        if profile.revoked
        else "model_identity_unknown"
        if variant is None
        else "voice_incompatible"
        if not compatible
        else "backend_not_ready"
        if not ready
        else "available"
    )
    is_clone = profile.mode == "clone"
    instructions: Support = (
        "supported" if compatible and variant == "voice_design" else "unsupported"
    )
    speed = (
        parameter("supported", values=[1.0])
        if is_clone
        else parameter(
            "supported" if compatible else "unknown",
            minimum=0.25,
            maximum=4.0,
        )
    )
    common = {
        "speed": speed,
        "language": parameter(
            "unknown", default="auto", reason="vendor_language_domain_unverified"
        ),
        "seed": parameter("unsupported"),
        "phoneme": parameter("unsupported"),
        "ssml": parameter("unsupported"),
        "native_expression": parameter(
            "unsupported" if is_clone else "unknown",
            reason="fixed_identity_neutral_only"
            if is_clone
            else "identity_preservation_unevaluated",
        ),
    }
    return {
        "id": profile.id,
        "name": profile.name or profile.id,
        "aliases": sorted(alias for alias, target in VOICE_ALIASES.items() if target == profile.id),
        "is_default": profile.is_default,
        "is_system": profile.is_system,
        "mode": profile.mode,
        "available": reason == "available",
        "availability_reason": reason,
        "variant": variant,
        "voice_revision": profile.revision,
        "voice_identity_assurance": (
            "content_addressed" if profile.revision is not None else "legacy"
        ),
        "revoked": profile.revoked,
        "model": model_identity(artifact),
        "descriptors": safe_voice_descriptor(profile),
        "quality_summary": _safe_quality_summary(profile.quality),
        "validation_state": validation_state,
        "validated_for": validation_state["validated_for"],
        "production_ready": (
            reason == "available" and validation_state["production_ready"] is True
        ),
        "production_ready_reason": (
            validation_state["production_ready_reason"]
            if reason == "available"
            else reason
        ),
        "operations": {
            "http_speech": {
                "parameters": {
                    **common,
                    "instructions": parameter(instructions),
                    "pronunciation_set": parameter(
                        "supported",
                        reason="speechrail_versioned_preprocessor",
                    ),
                    "purpose": parameter(
                        "supported",
                        values=["interactive", "prefetch"],
                        default=None,
                        transport="SpeechRail-Purpose header",
                    ),
                    "latency_budget_ms": parameter(
                        "supported",
                        minimum=50,
                        maximum=120_000,
                        default=None,
                        transport="SpeechRail-Latency-Budget-Ms header",
                        server_cap="request_timeout_seconds",
                    ),
                },
                "output": {
                    "codecs": ["pcm", "wav", "mp3", "opus", "aac", "flac"],
                    "pcm_sample_rate": sample_rate,
                    "channels": 1,
                },
                "scheduling": {
                    "default_class": "batch_tts",
                    "purpose_classes": {
                        "interactive": "realtime_tts",
                        "prefetch": "batch_tts",
                    },
                    "same_lane_serial": True,
                    "hard_preemption": False,
                },
                "terminal_evidence": "render_receipt_v1_optional",
            },
            "realtime_speech": {
                "parameters": {**common, "instructions": parameter("unsupported")},
                "output": {"codecs": ["pcm16"], "pcm_sample_rate": 24_000, "channels": 1},
                "scheduling_class": "realtime_tts",
                "terminal_evidence": "speechrail.tts.completed",
            },
        },
        "conditional_synthesis": parameter(
            (
                "supported"
                if profile.revision is not None and compatible and not profile.revoked
                else "unsupported"
            ),
            reason=(
                "legacy_voice_has_no_verified_revision"
                if profile.revision is None
                else "voice_revoked"
                if profile.revoked
                else "voice_not_available"
                if not compatible
                else "atomic_registry_lease_pin"
            ),
        ),
        "prepared_reference_condition_cache": parameter(
            "unsupported",
            reason=MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT.reason,
            vendor_package=MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT.vendor_package,
            vendor_version=MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT.vendor_version,
            public_contract=MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT.public_contract,
            private_cache_observed=(
                MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT.private_cache_observed
            ),
        ),
        "timing_sidecar": parameter(
            "supported" if compatible else "unsupported",
            values=["chunk"] if compatible else [],
            coordinate_space="normalized_spoken_unicode_codepoints",
            display_mapping="conditional",
            delivery="async_resource",
            reason=(
                "planner_chunk_sample_conservation"
                if compatible
                else "voice_not_available"
            ),
        ),
    }


def asr_operations(asr_capabilities: Mapping[str, Any] | None) -> dict[str, Any]:
    """Build ASR-side operation entries from declared facts.

    Conservative by default: without declared facts every ASR operation reports
    ``unsupported`` with a readiness reason instead of falsely claiming support.
    Busy/activity state is deliberately absent so it can never deform the
    supported-capability enumeration; only the readiness reason varies.
    """

    facts = dict(asr_capabilities or {})
    available = bool(facts.get("available", False))
    ready = bool(facts.get("ready", False))
    served = available and ready
    declared_reason = facts.get("reason")
    reason = (
        declared_reason
        if isinstance(declared_reason, str) and declared_reason
        else None
        if served
        else ("asr_not_configured" if not available else "asr_not_ready")
    )
    alignment_available = bool(facts.get("alignment_available", False))
    jobs_available = bool(facts.get("jobs_available", False))
    languages = facts.get("languages")
    language_values = (
        [str(value) for value in languages] if isinstance(languages, (list, tuple)) else []
    )
    realtime_formats = facts.get("realtime_formats")
    realtime_endpointing = facts.get("realtime_endpointing")
    full_duplex = bool(facts.get("realtime_full_duplex_certified", False))
    limits = {
        "max_upload_bytes": facts.get("max_upload_bytes"),
        "max_audio_seconds": facts.get("max_audio_seconds"),
    }
    return {
        "transcription": {
            "status": "supported" if served else "unsupported",
            "reason": reason,
            "input": limits,
            "granularity": "segment",
            "languages": {
                "status": "supported" if language_values else "unknown",
                "values": language_values,
            },
            "output": {
                "formats": ["json", "text", "verbose_json"],
                "word_timestamps": False,
            },
            "terminal_evidence": "transcription.completed",
        },
        "alignment_transcription": {
            "status": "supported" if (served and alignment_available) else "unsupported",
            "reason": (
                None
                if served and alignment_available
                else reason or "alignment_artifact_not_bound"
            ),
            "input": limits,
            "granularity": "word",
            "terminal_evidence": "alignment.completed",
        },
        "realtime_transcription": {
            "status": "supported" if served else "unsupported",
            "reason": reason,
            "input": {
                "formats": [str(value) for value in realtime_formats]
                if isinstance(realtime_formats, (list, tuple))
                else ["pcm16"],
                "pcm_sample_rate": facts.get("realtime_pcm_sample_rate", 24_000),
                "endpointing": [str(value) for value in realtime_endpointing]
                if isinstance(realtime_endpointing, (list, tuple))
                else ["server_vad"],
            },
            "duplex": "full_duplex" if full_duplex else "half_duplex",
            "terminal_evidence": "transcription.completed",
        },
        "jobs": {
            "status": "supported" if jobs_available else "unsupported",
            "reason": None if jobs_available else "job_spool_not_configured",
            "input": limits,
            "scheduling": {"default_class": "batch_transcription", "hard_preemption": False},
            "terminal_evidence": "job.completed",
        },
    }


def build_capability_snapshot(
    profiles: Sequence[VoiceProfile],
    active: ActiveModelCatalog,
    *,
    epoch: str,
    ready: bool,
    enabled_voices: frozenset[str],
    sample_rate: int,
    validation_records: Mapping[str, Mapping[str, Any]] | None = None,
    runtime_revision: str | None = None,
    validation_bindings: Mapping[str, Mapping[str, Any]] | None = None,
    asr_capabilities: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Pure snapshot assembly; no model imports, registry calls, or network access."""
    ordered = sorted(profiles, key=lambda profile: profile.id)
    models = {
        "asr": model_identity(active.asr),
        "tts": model_identity(active.tts),
        "tts_clone": model_identity(active.tts_clone),
    }
    # Private recipe changes must invalidate discovery, even though neither the
    # recipe nor its text hash is a public voice identity. Never expose this input.
    private_versions = [content_revision(profile.to_dict()) for profile in ordered]
    planner_policy = {
        "version": PLANNER_VERSION,
        "max_chars": TtsTextPlanner().max_chars,
        "coordinate_space": "normalized_text_unicode_codepoints",
        "native_context_conditioning": "unsupported",
        "naturalness_evidence": "unevaluated",
    }
    catalog_revision = content_revision(
        {
            "schema": SCHEMA_VERSION,
            "models": models,
            "profile": active.profile,
            "selection_generation": active.generation,
            "recipes": private_versions,
            "enabled": sorted(enabled_voices),
            "rate": sample_rate,
            "tts_text_planner": planner_policy,
            # Engine revision, selection generation and ASR certification facts
            # must invalidate the content validator when they change.
            "runtime_revision": runtime_revision,
            "asr_capabilities": asr_capabilities,
            "realtime": {
                "orchestration": "caller",
                "server_llm": False,
                "conversation_state": False,
                "websocket_path": "/v1/realtime",
                "mcp_realtime": False,
            },
        }
    )
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "service_instance_epoch": epoch,
        "catalog_revision": catalog_revision,
        "profile": active.profile,
        "models": models,
        "realtime": {
            "orchestration": "caller",
            "server_llm": False,
            "conversation_state": False,
            "websocket_path": "/v1/realtime",
            "mcp_realtime": False,
        },
        "voices": [
            _voice_entry(
                profile,
                active,
                ready=ready,
                enabled_voices=enabled_voices,
                sample_rate=sample_rate,
                validation=(validation_records or {}).get(profile.id),
                runtime_revision=(
                    (validation_bindings or {}).get(profile.id, {}).get(
                        "model_runtime_revision"
                    )
                    if profile.id in (validation_bindings or {})
                    else runtime_revision
                ),
                runtime_identity_status=(
                    (
                        (validation_bindings or {}).get(profile.id, {}).get(
                            "runtime_identity_status"
                        )
                        if profile.id in (validation_bindings or {})
                        else ("observed" if runtime_revision is not None else "not_requested")
                    )
                    or "not_requested"
                ),
                validation_binding=(validation_bindings or {}).get(profile.id),
                binding_required=profile.id in (validation_bindings or {}),
            )
            for profile in ordered
        ],
        "operations": {
            "tts_text_planner": planner_policy,
            "voice_preview": {
                "status": "supported"
                if active.voice_design is not None
                and active.voice_design.variant == "voice_design"
                else "unsupported",
                "instruction": parameter("supported", required=True, maximum_length=10_000),
                "seed": parameter("supported", minimum=0, maximum=2**32 - 1),
                "speed": parameter("supported", minimum=0.25, maximum=4.0),
                "creates_persistent_voice": False,
            },
            **asr_operations(asr_capabilities),
        },
        "guarantees": {
            "discovery_only": True,
            "inference_version_pin": False,
            "admission_reserved": False,
            "no_sensitive_attribute_inference": True,
            "websocket_bidirectional_is_not_full_duplex": True,
            "realtime_full_duplex": bool(
                (asr_capabilities or {}).get("realtime_full_duplex_certified", False)
            ),
        },
    }
    result["snapshot_id"] = content_revision(result)
    return result
