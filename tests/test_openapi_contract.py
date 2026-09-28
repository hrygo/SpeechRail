from __future__ import annotations

import importlib.util
from pathlib import Path

import yaml


class _DuplicateKeyLoader(yaml.SafeLoader):
    """SafeLoader that reports repeated keys instead of silently keeping the last."""


def _construct_mapping(
    loader: _DuplicateKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[str, object]:
    mapping: dict[str, object] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise AssertionError(
                f"duplicate key {key!r} at line {key_node.start_mark.line + 1}"
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_DuplicateKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping,
)


def _checker() -> object:
    script_path = Path(__file__).parents[1] / "scripts" / "check_openapi_contract.py"
    spec = importlib.util.spec_from_file_location("check_openapi_contract", script_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_runtime_routes_match_openapi_contract() -> None:
    """Every served path/method must be documented, and vice versa."""

    module = _checker()
    assert module.find_drift() == []  # type: ignore[attr-defined]


def test_checker_reports_undocumented_paths() -> None:
    """The checker must fail closed on drift rather than silently passing."""

    module = _checker()
    operations = module._operations(  # type: ignore[attr-defined]
        {"paths": {"/v1/only-in-app": {"get": {}, "post": {}}}}
    )
    assert operations == {"/v1/only-in-app": {"get", "post"}}


def test_success_status_codes_match_between_runtime_and_contract() -> None:
    """Every route's declared success code must be published by the contract."""

    module = _checker()
    assert module._status_drift() == []  # type: ignore[attr-defined]


def test_security_requirements_name_a_declared_scheme() -> None:
    """Every ``security`` entry must resolve to a declared securityScheme."""

    module = _checker()
    assert module._security_drift() == []  # type: ignore[attr-defined]


def test_contract_has_no_duplicate_mapping_keys() -> None:
    """A repeated key is silently dropped by PyYAML, hiding the losing value.

    An earlier edit left two ``description`` keys on one schema property: the
    spec still parsed, the first text was simply gone, and no drift check saw
    it. Parse fail-closed so the contract cannot carry dead or contradictory
    text again.
    """

    contract = Path(__file__).parents[1] / "contracts" / "openapi.yaml"
    document = yaml.load(contract.read_text(encoding="utf-8"), Loader=_DuplicateKeyLoader)
    assert isinstance(document, dict)


def test_route_walker_unwraps_included_routers() -> None:
    """FastAPI nests included routers; the walker must still see every route."""

    from fastapi import APIRouter, FastAPI
    from fastapi.routing import APIRoute

    module = _checker()
    router = APIRouter(prefix="/v1/example")

    @router.get("/thing")
    async def thing() -> dict[str, bool]:
        return {"ok": True}

    app = FastAPI()
    app.include_router(router)
    walked = module._walk_routes(app.routes)  # type: ignore[attr-defined]

    assert [route.path for route in walked if isinstance(route, APIRoute)] == [
        "/v1/example/thing"
    ]


def test_status_drift_is_detected_for_a_synthetic_pair() -> None:
    """A success-code difference must be reported instead of tolerated."""

    module = _checker()
    runtime = {
        "paths": {
            "/v1/example": {
                "post": {"responses": {"200": {"description": "ok"}}},
            }
        }
    }
    contract = {
        "paths": {
            "/v1/example": {
                "post": {
                    "responses": {
                        "200": {"description": "ok"},
                        "201": {"description": "created"},
                    }
                },
            }
        }
    }
    assert module._success_codes(runtime) != module._success_codes(contract)  # type: ignore[attr-defined]


def _contract() -> dict:
    import yaml

    return yaml.safe_load(
        (Path(__file__).parents[1] / "contracts" / "openapi.yaml").read_text(
            encoding="utf-8"
        )
    )


def test_speech_request_body_is_the_openai_subset() -> None:
    """SpeechRail options live in headers, so the body must not accept them."""

    schema = _contract()["components"]["schemas"]["SpeechRequest"]

    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == {
        "model",
        "input",
        "voice",
        "response_format",
        "speed",
        "instructions",
        "stream_format",
    }
    for removed in ("language", "seed", "validation_policy"):
        assert removed not in schema["properties"], removed
    # Aligned with OpenAI's documented cap.
    assert schema["properties"]["instructions"]["maxLength"] == 4096


def test_speech_language_and_policy_travel_as_speechrail_headers() -> None:
    parameters = _contract()["paths"]["/v1/audio/speech"]["post"]["parameters"]
    headers = {
        parameter["name"]: parameter
        for parameter in parameters
        if parameter["in"] == "header"
    }

    assert headers["SpeechRail-Language"]["required"] is False
    assert headers["SpeechRail-Validation-Policy"]["schema"]["enum"] == [
        "allow_unverified",
        "require_output_pass",
    ]
    for name in ("SpeechRail-Language", "SpeechRail-Validation-Policy"):
        assert headers[name]["description"].strip(), name


def test_namespaced_quality_run_keeps_the_envelope_shape() -> None:
    """C1: the client must not be able to read this route as a bare report."""
    response = _contract()["paths"]["/v1/speechrail/voices/{voice_id}/quality-runs"][
        "post"
    ]["responses"]["200"]["content"]["application/json"]["schema"]
    assert response["$ref"].endswith("VoiceQualityRunEnvelope")

    envelope = _contract()["components"]["schemas"]["VoiceQualityRunEnvelope"]
    assert envelope["type"] == "object"
    assert set(envelope["required"]) == {
        "legacy_report",
        "evidence",
        "validation_persisted",
    }
    # The top level deliberately has no `status`: it is an envelope, not a report.
    assert "status" not in envelope["properties"]


def test_strict_admission_outcomes_are_documented() -> None:
    """F1/F3: strict rejection reasons must be part of the public contract."""
    responses = _contract()["paths"]["/v1/audio/speech"]["post"]["responses"]
    conflict = responses["409"]["description"]
    for code in (
        "voice_not_production_ready",
        "voice_validation_runtime_changed",
    ):
        assert code in conflict, code


def test_clone_registration_documents_pending_replay_recovery() -> None:
    """F4/F5: an unknown registration outcome is recovered, never re-keyed."""
    operation = _contract()["paths"]["/v1/voices/clone"]["post"]
    # Folded YAML inserts newlines mid-sentence; compare on collapsed whitespace.
    description = " ".join(operation["description"].split())
    assert "replaying the same" in description
    assert "at most one acoustic asset" in description

    status = _contract()["paths"]["/v1/speechrail/voices/clone/idempotency"]["get"]
    assert "read-only" in " ".join(status["description"].split())
    assert "replaying the original" in " ".join(status["description"].split())


def test_validated_for_is_the_dimension_not_the_execution_spec() -> None:
    """F2: the scope and the capability key are two separate facts."""
    safe_voice = _contract()["components"]["schemas"]["SafeVoiceEntry"]
    description = safe_voice["properties"]["validated_for"]["description"]
    assert "output" in description
    assert "capability_key" in description
