from __future__ import annotations

import importlib.util
from pathlib import Path


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
