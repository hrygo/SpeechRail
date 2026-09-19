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
from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner

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


def _voice_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    *,
    ready: bool,
    enabled_voices: frozenset[str],
    sample_rate: int,
) -> dict[str, Any]:
    artifact = active.tts_clone if profile.mode == "clone" else active.tts
    variant = artifact.variant if artifact is not None else None
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
                "terminal_evidence": "response.done",
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
            "unsupported", reason="no_adapted_public_port"
        ),
        "timing_sidecar": parameter("unsupported"),
    }


def build_capability_snapshot(
    profiles: Sequence[VoiceProfile],
    active: ActiveModelCatalog,
    *,
    epoch: str,
    ready: bool,
    enabled_voices: frozenset[str],
    sample_rate: int,
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
            "recipes": private_versions,
            "enabled": sorted(enabled_voices),
            "rate": sample_rate,
            "tts_text_planner": planner_policy,
        }
    )
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "service_instance_epoch": epoch,
        "catalog_revision": catalog_revision,
        "profile": active.profile,
        "models": models,
        "voices": [
            _voice_entry(
                profile, active, ready=ready, enabled_voices=enabled_voices, sample_rate=sample_rate
            )
            for profile in ordered
        ],
        "operations": {
            "tts_text_planner": planner_policy,
            "voice_preview": {
                "status": "supported"
                if active.tts is not None and active.tts.variant == "voice_design"
                else "unsupported",
                "instruction": parameter("supported", required=True, maximum_length=10_000),
                "seed": parameter("supported", minimum=0, maximum=2**32 - 1),
                "speed": parameter("supported", minimum=0.25, maximum=4.0),
                "creates_persistent_voice": False,
            },
        },
        "guarantees": {
            "discovery_only": True,
            "inference_version_pin": False,
            "admission_reserved": False,
            "no_sensitive_attribute_inference": True,
        },
    }
    result["snapshot_id"] = content_revision(result)
    return result
