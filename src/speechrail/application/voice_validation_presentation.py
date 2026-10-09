"""Public JSON projection of a detached validation verdict."""

from speechrail.domain.voice_validation_policy import VoiceValidationVerdict


def present_validation_verdict(verdict: VoiceValidationVerdict) -> dict[str, object]:
    synthesis = verdict.synthesis
    output: dict[str, object] = {"status": synthesis.status}
    if synthesis.evidence_present:
        output.update(
            run_id=synthesis.run_id, tested_at=synthesis.tested_at,
            failure_codes=list(synthesis.failure_codes),
            validated_for=list(synthesis.validated_for),
        )
    else:
        output["reason"] = synthesis.reason
    identity: dict[str, object] = {
        "status": verdict.identity.status, "reason": verdict.identity.reason,
    }
    if synthesis.stale_reason is not None:
        output["stale_reason"] = synthesis.stale_reason
        identity["stale_reason"] = verdict.identity.stale_reason
    return {
        "reference": {
            "status": verdict.reference.status,
            "policy_version": verdict.reference.policy_version,
            "source": verdict.reference.source,
        },
        "synthesis": output,
        "identity": identity,
        "stale": verdict.stale,
        "validated_for": list(verdict.validated_for),
        "production_ready": verdict.production_ready,
        "production_ready_reason": verdict.production_ready_reason,
    }
