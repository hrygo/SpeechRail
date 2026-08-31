import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from speechrail.app import create_app
from speechrail.config import Settings


def test_lan_binding_requires_api_key() -> None:
    with pytest.raises(ValidationError, match="api_key is required"):
        Settings(host="0.0.0.0", qwen3_model_dir=None, qwen3_python=None)


def test_api_key_is_not_accepted_from_query_or_wrong_bearer() -> None:
    client = TestClient(
        create_app(Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None))
    )
    for headers in ({}, {"Authorization": "Bearer wrong"}):
        response = client.post(
            "/v1/audio/transcriptions?token=secret",
            headers=headers,
            files={"file": ("clip.wav", b"1234", "audio/wav")},
        )
        assert response.status_code == 401
        assert response.json()["error"]["code"] == "invalid_api_key"
