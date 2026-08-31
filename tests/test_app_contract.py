from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings


def _client() -> TestClient:
    return TestClient(create_app(Settings(api_key=None)))


def test_health_reports_contract_shell_without_backend() -> None:
    response = _client().get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": "speechrail",
        "version": "0.1.0",
        "backend": "qwen3-asr-1.7b",
        "ready": False,
    }


def test_models_exposes_canonical_model_and_compatibility_aliases() -> None:
    response = _client().get("/v1/models")

    assert response.status_code == 200
    payload = response.json()
    assert payload["object"] == "list"
    ids = {item["id"] for item in payload["data"]}
    assert "speechrail/qwen3-asr-1.7b" in ids
    assert "Qwen3-ASR-1.7B" in ids


def test_transcription_returns_openai_compatible_not_ready_error() -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("hello.wav", b"RIFF", "audio/wav")},
        data={"model": "qwen3-asr-1.7b"},
    )

    assert response.status_code == 503
    error = response.json()["error"]
    assert error["type"] == "server_error"
    assert error["code"] == "backend_not_ready"
    assert error["retryable"] is True
    assert response.headers["content-type"].startswith("application/json")


def test_transcription_requires_file_at_the_boundary() -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        data={"model": "qwen3-asr-1.7b"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_request_id_is_returned_without_caching() -> None:
    response = _client().get("/health", headers={"X-Request-ID": "req_test_contract"})

    assert response.headers["X-Request-ID"] == "req_test_contract"
    assert response.headers["Cache-Control"] == "no-store"


def test_readyz_returns_retryable_error_until_backend_is_ready() -> None:
    response = _client().get("/readyz")

    assert response.status_code == 503
    assert response.json()["error"] == {
        "message": "SpeechRail inference backend is not ready",
        "type": "server_error",
        "code": "backend_not_ready",
        "request_id": response.json()["error"]["request_id"],
        "retryable": True,
    }


def test_readyz_is_200_when_runtime_reports_ready() -> None:
    response = TestClient(create_app(Settings(api_key=None, backend_ready=True))).get("/readyz")

    assert response.status_code == 200
    assert response.json() == {"ready": True}


def test_api_key_and_model_errors_are_distinct() -> None:
    client = TestClient(create_app(Settings(api_key="secret")))

    unauthorized = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("hello.wav", b"RIFF", "audio/wav")},
        data={"model": "speechrail/qwen3-asr-1.7b"},
    )
    assert unauthorized.status_code == 401
    assert unauthorized.json()["error"]["code"] == "invalid_api_key"
    assert unauthorized.headers["WWW-Authenticate"] == "Bearer"

    unknown_model = client.post(
        "/v1/audio/transcriptions",
        headers={"Authorization": "Bearer secret"},
        files={"file": ("hello.wav", b"RIFF", "audio/wav")},
        data={"model": "not-a-model"},
    )
    assert unknown_model.status_code == 400
    assert unknown_model.json()["error"]["code"] == "model_not_found"
    assert unknown_model.json()["error"]["param"] == "model"
