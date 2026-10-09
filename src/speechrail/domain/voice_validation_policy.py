"""Pure voice evidence policy; no repository, worker or discovery dependency."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Final, Literal, Protocol, cast

from speechrail.domain.voice_validation import OUTPUT_VALIDATION_SCOPE

if TYPE_CHECKING:
    from speechrail.domain.tts import VoiceProfile

RuntimeIdentityStatus = Literal["not_requested", "unknown", "observed", "recorded"]
_BOUND_RUNTIME_IDENTITY: Final[frozenset[str]] = frozenset({"observed", "recorded"})


class ValidationArtifact(Protocol):
    @property
    def key(self) -> str: ...

    @property
    def revision(self) -> str: ...


@dataclass(frozen=True, slots=True)
class ReferenceValidationVerdict:
    status: str
    policy_version: str | None
    source: str


@dataclass(frozen=True, slots=True)
class ValidationStageVerdict:
    status: str
    reason: str | None = None
    stale_reason: str | None = None
    evidence_present: bool = False
    run_id: str | None = None
    tested_at: str | None = None
    failure_codes: tuple[str, ...] = ()
    validated_for: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class VoiceValidationVerdict:
    reference: ReferenceValidationVerdict
    synthesis: ValidationStageVerdict
    identity: ValidationStageVerdict
    stale: bool
    validated_for: tuple[str, ...]
    production_ready: bool
    production_ready_reason: str


def evaluate_voice_validation(
    profile: VoiceProfile,
    artifact: ValidationArtifact | None,
    validation: Mapping[str, Any] | None = None,
    *,
    runtime_revision: str | None = None,
    runtime_identity_status: Literal["not_requested", "unknown", "observed", "recorded"] = (
        "not_requested"
    ),
    validation_binding: Mapping[str, Any] | None = None,
    binding_required: bool = False,
) -> VoiceValidationVerdict:
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
                    if binding_required
                    and runtime_identity_status not in _BOUND_RUNTIME_IDENTITY
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
            elif (
                binding_required
                and runtime_identity_status not in _BOUND_RUNTIME_IDENTITY
            ):
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
    output_validated = (
        isinstance(validated_for, list)
        and OUTPUT_VALIDATION_SCOPE in validated_for
    )
    production_ready = profile.mode != "clone" or (
        reference["status"] == "pass"
        and synthesis["status"] == "pass"
        and output_validated
        and not stale
        and (
            not binding_required
            or runtime_identity_status in _BOUND_RUNTIME_IDENTITY
        )
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
    output = ValidationStageVerdict(
        status=cast(str, synthesis["status"]),
        reason=cast(str | None, synthesis.get("reason")),
        stale_reason=cast(str | None, synthesis.get("stale_reason")),
        evidence_present="validated_for" in synthesis,
        run_id=cast(str | None, synthesis.get("run_id")),
        tested_at=cast(str | None, synthesis.get("tested_at")),
        failure_codes=tuple(cast(list[str], synthesis.get("failure_codes", []))),
        validated_for=tuple(cast(list[str], synthesis.get("validated_for", []))),
    )
    return VoiceValidationVerdict(
        reference=ReferenceValidationVerdict(
            status=cast(str, reference["status"]),
            policy_version=cast(str | None, reference["policy_version"]),
            source=cast(str, reference["source"]),
        ),
        synthesis=output,
        identity=ValidationStageVerdict(
            status=cast(str, identity["status"]),
            reason=cast(str | None, identity.get("reason")),
            stale_reason=cast(str | None, identity.get("stale_reason")),
        ),
        stale=stale,
        validated_for=output.validated_for,
        production_ready=production_ready,
        production_ready_reason=reason,
    )
