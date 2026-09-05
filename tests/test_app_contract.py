from pathlib import Path
from sys import executable

import pytest
from fastapi.testclient import TestClient

import speechrail.application.services as services_module
from speechrail.app import create_app
from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(
                api_key=None,
                qwen3_model_dir=None,
                qwen3_python=None,
                diarization_model_path=None,
                diarization_embedding_model_path=None,
            )
        )
    )


def test_health_reports_contract_shell_without_backend() -> None:
    response = _client().get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": "speechrail",
"version": "1.7.0",
        "backend": "speechrail/qwen3-asr-1.7b",
        "profile": None,
        "asr_ready": False,
        "tts_ready": False,
        "diarization_ready": False,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
        "ready": False,
    }


@pytest.mark.parametrize("preset_id", ["quality", "balanced", "light"])
def test_managed_profile_publishes_active_model_identity(
    tmp_path: Path,
    preset_id: str,
) -> None:
    catalog = load_catalog()
    preset = catalog.preset(preset_id)
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    settings = Settings(
        qwen3_model_dir=tmp_path / preset.asr,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / preset.tts,
        qwen3_tts_python=None,
    )
    client = TestClient(create_app(settings))

    health = client.get("/health").json()
    assert health["backend"] == preset.asr
    assert health["profile"] == preset_id

    by_id = {
        item["id"]: item for item in client.get("/v1/models").json()["data"]
    }
    asr = artifacts[preset.asr]
    tts = artifacts[preset.tts]
    assert by_id[settings.model_id] == {
        "id": settings.model_id,
        "object": "model",
        "owned_by": "speechrail",
        "created": 0,
        "profile": preset_id,
        "artifact": asr.key,
        "source_model": asr.model_id,
        "family": asr.family,
        "variant": asr.variant,
        "quantization": asr.quantization.model_dump(mode="json"),
    }
    assert by_id[settings.tts_model_id] == {
        "id": settings.tts_model_id,
        "object": "model",
        "owned_by": "speechrail",
        "created": 0,
        "profile": preset_id,
        "artifact": tts.key,
        "source_model": tts.model_id,
        "family": tts.family,
        "variant": tts.variant,
        "quantization": tts.quantization.model_dump(mode="json"),
    }


def test_models_exposes_canonical_model_and_compatibility_aliases() -> None:
    response = _client().get("/v1/models")

    assert response.status_code == 200
    payload = response.json()
    assert payload["object"] == "list"
    # OpenAI's Model schema carries a required `created` timestamp; strict SDK
    # clients expect it on every entry.
    assert all(item["created"] == 0 for item in payload["data"])
    by_id = {item["id"]: item for item in payload["data"]}
    assert "speechrail/qwen3-asr-1.7b" in by_id
    assert "Qwen3-ASR-1.7B" in by_id
    assert by_id["whisper-1"]["resolves_to"] == "speechrail/qwen3-asr-1.7b"
    assert by_id["gpt-4o-transcribe"]["resolves_to"] == "speechrail/qwen3-asr-1.7b"
    assert by_id["tts-1"]["resolves_to"] == "speechrail/qwen3-tts"
    assert by_id["tts-1-hd"]["resolves_to"] == "speechrail/qwen3-tts"
    assert by_id["gpt-4o-mini-tts"]["resolves_to"] == "speechrail/qwen3-tts"


def test_models_hides_diarize_alias_injected_via_compatibility_ids_without_profile() -> None:
    client = TestClient(
        create_app(
            Settings(
                api_key=None,
                qwen3_model_dir=None,
                qwen3_python=None,
                diarization_model_path=None,
                diarization_embedding_model_path=None,
                compatibility_model_ids=("gpt-4o-transcribe-diarize",),
            )
        )
    )

    ids = {item["id"] for item in client.get("/v1/models").json()["data"]}

    assert "gpt-4o-transcribe-diarize" not in ids


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


def test_private_realtime_v2_endpoint_is_removed() -> None:
    response = _client().get("/v2/realtime")

    assert response.status_code == 404


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
    response = TestClient(
        create_app(
            Settings(
                api_key=None,
                backend_ready=True,
                qwen3_model_dir=None,
                qwen3_python=None,
                diarization_model_path=None,
                diarization_embedding_model_path=None,
            )
        )
    ).get("/readyz")

    assert response.status_code == 200
    assert response.json() == {
        "ready": True,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
    }


def test_tts_only_runtime_reports_independent_readiness() -> None:
    class ReadyTts:
        ready = True

    client = TestClient(
        create_app(
            Settings(
                api_key=None,
                qwen3_model_dir=None,
                qwen3_python=None,
                diarization_model_path=None,
                diarization_embedding_model_path=None,
            ),
            tts_synthesizer=ReadyTts(),  # type: ignore[arg-type]
        )
    )

    assert client.get("/health").json() == {
        "status": "ok",
        "service": "speechrail",
"version": "1.7.0",
        "backend": "speechrail/qwen3-asr-1.7b",
        "profile": None,
        "asr_ready": False,
        "tts_ready": True,
        "diarization_ready": False,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
        "ready": True,
    }
    assert client.get("/readyz").json() == {
        "ready": True,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
    }


def test_configured_worker_lifecycle_does_not_depend_on_local_env(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-snapshot"
    snapshot.mkdir(exist_ok=True)
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()
    lifecycle: list[str] = []

    class FakeWorker:
        def __init__(self, config: object) -> None:
            del config

        async def start(self) -> None:
            lifecycle.append("start")

        async def close(self) -> None:
            lifecycle.append("close")

        async def transcribe(self, audio: bytes, language: str | None, prompt: str) -> object:
            del audio, language, prompt
            raise AssertionError("transcribe is not expected in this lifecycle test")

    monkeypatch.setattr(services_module, "Qwen3Worker", FakeWorker)
    settings = Settings(
        qwen3_model_dir=snapshot,
        qwen3_python=Path(executable),
        backend_ready=False,
        worker_lazy_load=False,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )

    with TestClient(create_app(settings)) as client:
        assert client.get("/readyz").json() == {
            "ready": True,
            "diarization": {
                "configured": False,
                "ready": False,
                "code": "diarization_not_configured",
                "message": "diarization profile is not configured",
                "profile": None,
            },
        }

    assert lifecycle == ["start", "close"]


def test_startup_failure_closes_already_started_runtime_workers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    asr_snapshot = tmp_path / "external-qwen3-asr-snapshot"
    asr_snapshot.mkdir()
    for filename in (*MODEL_FILES, "model.safetensors"):
        (asr_snapshot / filename).touch()
    tts_snapshot = tmp_path / "external-qwen3-tts-snapshot"
    tts_snapshot.mkdir()
    (tts_snapshot / "config.json").touch()
    lifecycle: list[str] = []

    class FakeAsrWorker:
        def __init__(self, config: object) -> None:
            del config

        async def start(self) -> None:
            lifecycle.append("asr.start")

        async def close(self) -> None:
            lifecycle.append("asr.close")

        async def transcribe(self, audio: bytes, language: str | None, prompt: str) -> object:
            del audio, language, prompt
            raise AssertionError("transcribe is not expected in this lifecycle test")

    class FailingTtsWorker:
        def __init__(self, config: object) -> None:
            del config

        async def start(self) -> None:
            lifecycle.append("tts.start")
            raise RuntimeError("tts_start_failed")

        async def close(self) -> None:
            lifecycle.append("tts.close")

    monkeypatch.setattr(services_module, "Qwen3Worker", FakeAsrWorker)
    monkeypatch.setattr(services_module, "Qwen3TtsWorker", FailingTtsWorker)
    settings = Settings(
        qwen3_model_dir=asr_snapshot,
        qwen3_python=Path(executable),
        qwen3_tts_model_dir=tts_snapshot,
        qwen3_tts_python=Path(executable),
        worker_lazy_load=False,
    )

    with pytest.raises(RuntimeError, match="tts_start_failed"), TestClient(create_app(settings)):
        pass

    assert lifecycle == ["asr.start", "tts.start", "asr.close"]


def test_api_key_and_model_errors_are_distinct() -> None:
    client = TestClient(
        create_app(Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None))
    )

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
