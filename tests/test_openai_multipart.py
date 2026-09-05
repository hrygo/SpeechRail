from collections.abc import Awaitable
from pathlib import Path

import pytest
import yaml
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment, TranscriptWord


def _backend(
    _: bytes, __: str | None, ___: str, ____: bool = False
) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="hello world",
            language="en",
            duration_ms=1_000,
            segments=(
                TranscriptSegment(id=0, start_ms=0, end_ms=1_000, text="hello world"),
            ),
            words=(
                TranscriptWord(word="hello", start_ms=0, end_ms=500),
                TranscriptWord(word="world", start_ms=500, end_ms=1_000),
            ),
        )

    return result()


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            transcribe=_backend,
        )
    )


def _multipart(*fields: tuple[str, str]) -> list[tuple[str, object]]:
    return [
        *((name, (None, value)) for name, value in fields),
        ("file", ("clip.wav", b"1234", "audio/wav")),
    ]


def _post(
    *fields: tuple[str, str], headers: dict[str, str] | None = None
):
    return _client().post(
        "/v1/audio/transcriptions",
        files=_multipart(*fields),
        headers=headers,
    )


def _assert_words(payload: dict[str, object]) -> None:
    assert payload["words"] == [
        {"word": "hello", "start": 0.0, "end": 0.5},
        {"word": "world", "start": 0.5, "end": 1.0},
    ]


def test_standard_bracketed_timestamp_granularity_word_only_returns_words() -> None:
    response = _post(
        ("timestamp_granularities[]", "word"),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 200
    payload = response.json()
    _assert_words(payload)
    assert "segments" not in payload


def test_standard_bracketed_timestamp_granularity_segment_only_returns_segments() -> None:
    response = _post(
        ("timestamp_granularities[]", "segment"),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["segments"][0]["text"] == "hello world"
    assert "words" not in payload


def test_repeated_standard_bracketed_timestamp_fields_return_both_granularities() -> None:
    response = _post(
        ("timestamp_granularities[]", "word"),
        ("timestamp_granularities[]", "segment"),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 200
    payload = response.json()
    _assert_words(payload)
    assert payload["segments"][0]["text"] == "hello world"


def test_standard_bracketed_timestamp_granularity_rejects_invalid_value_with_request_id() -> None:
    request_id = "req-standard-timestamp-invalid"
    response = _post(
        ("timestamp_granularities[]", "character"),
        ("response_format", "verbose_json"),
        headers={"X-Request-ID": request_id},
    )

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "invalid_timestamp_granularities"
    assert error["param"] == "timestamp_granularities"
    assert error["request_id"] == request_id
    assert response.headers["X-Request-ID"] == request_id


def test_standard_bracketed_timestamp_granularity_requires_verbose_json() -> None:
    response = _post(
        ("timestamp_granularities[]", "word"),
        ("response_format", "json"),
    )

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "timestamp_granularities_requires_verbose_json"
    assert error["param"] == "timestamp_granularities"


def test_legacy_non_bracketed_timestamp_granularity_remains_supported() -> None:
    response = _post(
        ("timestamp_granularities", "word"),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 200
    payload = response.json()
    _assert_words(payload)
    assert "segments" not in payload


def test_mixed_standard_and_legacy_timestamp_fields_merge() -> None:
    response = _post(
        ("timestamp_granularities[]", "word"),
        ("timestamp_granularities", "segment"),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 200
    payload = response.json()
    _assert_words(payload)
    assert payload["segments"][0]["text"] == "hello world"


@pytest.mark.parametrize(
    ("standard_value", "legacy_value"),
    (("character", "word"), ("word", "character")),
)
def test_mixed_timestamp_fields_reject_invalid_value_from_either_side(
    standard_value: str, legacy_value: str
) -> None:
    response = _post(
        ("timestamp_granularities[]", standard_value),
        ("timestamp_granularities", legacy_value),
        ("response_format", "verbose_json"),
    )

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "invalid_timestamp_granularities"
    assert error["param"] == "timestamp_granularities"


@pytest.mark.parametrize(
    ("field_name", "value"),
    (
        ("timestamp_granularities", "word"),
        ("timestamp_granularities[]", "word"),
        ("timestamp_granularities[]", "segment"),
    ),
)
def test_single_timestamp_granularity_response_matches_openapi_schema(
    field_name: str, value: str
) -> None:
    contract = yaml.safe_load(
        (Path(__file__).parents[1] / "contracts/openapi.yaml").read_text()
    )
    validator = Draft202012Validator(
        {
            "$ref": "#/components/schemas/VerboseTranscriptionResponse",
            "components": contract["components"],
        },
    )

    response = _post((field_name, value), ("response_format", "verbose_json"))

    assert response.status_code == 200
    errors = list(validator.iter_errors(response.json()))
    assert not errors, "\n".join(error.message for error in errors)
