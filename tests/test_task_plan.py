from __future__ import annotations

import pytest

from speechrail.application.plan_resolver import (
    AuthenticatedCombination,
    PlanEnvironment,
    PlanResolutionError,
    resolve_plan,
)
from speechrail.config.model_catalog import load_catalog, load_runtime_lock
from speechrail.domain.task_plan import (
    AudioFormat,
    RequiredOutput,
    TaskRequest,
)


def _selection(
    *,
    generation: int = 7,
    asr_spec: str = "fast",
    tts_spec: str = "fast",
) -> dict[str, object]:
    return {
        "schema_version": 2,
        "asr_spec": asr_spec,
        "tts_spec": tts_spec,
        "auto": "off",
        "generation": generation,
        "runtime_lock_id": load_runtime_lock().id,
    }


def _request(**overrides: object) -> TaskRequest:
    values: dict[str, object] = {
        "task_id": "task_01",
        "kind": "transcription",
        "asr_spec": "fast",
        "tts_spec": None,
        "selection_generation": 7,
        "voice_revision": None,
        "input_format": AudioFormat(kind="audio/pcm", sample_rate=24_000, channels=1),
        "required_outputs": frozenset({RequiredOutput.TEXT}),
        "alignment_options": None,
        "diarization_options": None,
        "allow_auto": False,
        "language": "zh",
    }
    values.update(overrides)
    return TaskRequest.model_validate(values)


def test_plan_is_immutable_deterministic_and_uses_explicit_spec_mapping() -> None:
    catalog = load_catalog()
    environment = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={"max_audio_seconds": 300},
    )

    first = resolve_plan(_request(), _selection(), catalog, environment=environment)
    second = resolve_plan(_request(), _selection(), catalog, environment=environment)

    assert first == second
    assert first.digest == second.digest
    assert first.selection_generation == 7
    assert [model.role for model in first.models] == ["asr"]
    assert first.models[0].artifact_key == "asr-0.6b-q8"
    with pytest.raises(TypeError):
        first.limits["max_audio_seconds"] = 1  # type: ignore[index]


def test_unknown_voice_revision_is_rejected_before_model_selection() -> None:
    environment = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset({"voice-good"}),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )

    with pytest.raises(PlanResolutionError, match="voice_revision"):
        resolve_plan(
            _request(
                kind="render",
                asr_spec=None,
                tts_spec="fast",
                voice_revision="voice-missing",
                required_outputs=frozenset({RequiredOutput.AUDIO}),
            ),
            _selection(),
            load_catalog(),
            environment=environment,
        )


def test_generation_change_rejects_a_plan_bound_to_an_older_selection() -> None:
    environment = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )

    with pytest.raises(PlanResolutionError, match="generation"):
        resolve_plan(
            _request(selection_generation=6),
            _selection(generation=7),
            load_catalog(),
            environment=environment,
        )


def test_auto_is_explicit_and_only_uses_authenticated_combinations() -> None:
    catalog = load_catalog()
    no_evidence = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )
    request = _request(asr_spec=None, allow_auto=True)
    auto_selection = {**_selection(), "auto": "resource"}

    with pytest.raises(PlanResolutionError, match="auto"):
        resolve_plan(request, auto_selection, catalog, environment=no_evidence)

    with_evidence = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(
            AuthenticatedCombination(asr_spec="fast", tts_spec="fast"),
        ),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )
    plan = resolve_plan(request, auto_selection, catalog, environment=with_evidence)
    assert plan.asr_spec == "fast"
    assert plan.tts_spec == "fast"


def test_missing_target_artifact_fails_closed_without_name_guessing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import speechrail.application.plan_resolver as plan_resolver
    from speechrail.domain.model_spec import ModelSpecRegistry

    environment = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )
    monkeypatch.setattr(
        plan_resolver,
        "registry_from_catalog",
        lambda catalog, *, engine_revision: ModelSpecRegistry(()),
    )

    with pytest.raises(PlanResolutionError, match=r"unavailable.*artifact"):
        resolve_plan(
            _request(
                kind="render",
                asr_spec=None,
                tts_spec="quality",
                required_outputs=frozenset({RequiredOutput.AUDIO}),
            ),
            _selection(tts_spec="quality"),
            load_catalog(),
            environment=environment,
        )


def test_resolver_is_pure_and_does_not_start_processes_or_network(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import socket
    import subprocess

    def forbidden(*args: object, **kwargs: object) -> None:
        raise AssertionError("resolver performed I/O")

    monkeypatch.setattr(socket, "socket", forbidden)
    monkeypatch.setattr(subprocess, "Popen", forbidden)
    environment = PlanEnvironment(
        engine_revision="engine-v1",
        voice_revisions=frozenset(),
        authenticated_combinations=(),
        resource_profile_revision="resource-v1",
        capability_evidence_revision="evidence-v1",
        limits={},
    )

    resolve_plan(_request(), _selection(), load_catalog(), environment=environment)
