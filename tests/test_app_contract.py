from pathlib import Path
from sys import executable
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

import speechrail.application.services as services_module
from speechrail.app import create_app
from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.model_spec import required_spec_artifact


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
        "version": "3.2.1",
        "backend": "speechrail/qwen3-asr-1.7b",
        "profile": None,
        "asr_ready": False,
        "asr_runtime_revision": None,
        "tts_ready": False,
        "tts_warm": False,
        "diarization_ready": False,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
        "realtime_vad": {
            "configured_engine": "auto",
            "resolved_engine": "legacy",
            "speech_admission_enabled": True,
            "ready": True,
            "code": None,
            "message": "legacy VAD is ready",
        },
        "asr_state": "unconfigured",
        "tts_state": "unconfigured",
        "tts_lifecycle": None,
        "streaming_state": "unconfigured",
        "job_spool_ready": False,
        "ready": False,
    }


def test_health_reports_silero_vad_runtime_gap_without_marking_core_unready(
    tmp_path: Path,
) -> None:
    model = tmp_path / "silero_vad.onnx"
    model.write_bytes(b"onnx")
    with patch("speechrail.backends.neural_vad.importlib.util.find_spec", return_value=None):
        client = TestClient(
            create_app(
                Settings(
                    qwen3_model_dir=None,
                    qwen3_python=None,
                    backend_ready=True,
                    realtime_vad_model_path=model,
                )
            )
        )
        health = client.get("/health")

    assert health.status_code == 200
    assert health.json()["ready"] is True
    assert health.json()["realtime_vad"] == {
        "configured_engine": "auto",
        "resolved_engine": "silero",
        "speech_admission_enabled": True,
        "ready": False,
        "code": "vad_runtime_missing",
        "message": "onnxruntime is not installed in the service environment",
    }


def test_health_exposes_safe_tts_lifecycle_counters() -> None:
    class InstrumentedTTS:
        def __init__(self) -> None:
            self.lifecycle_stats = {
                "cooperative_cancel_supported": False,
                "fallback_abort_count": 2,
                "reload_count": 1,
                "private_detail": "must not be exposed",
            }

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=InstrumentedTTS(),
        )
    )

    assert client.get("/health").json()["tts_lifecycle"] == {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 2,
        "reload_count": 1,
    }


@pytest.mark.parametrize("asr_spec", ["fast", "quality", "reference"])
def test_managed_selection_publishes_active_model_identity(
    tmp_path: Path, asr_spec: str
) -> None:
    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    asr_key = required_spec_artifact(asr_spec, "asr")
    tts_key = required_spec_artifact("fast", "tts_custom_voice")
    clone_key = required_spec_artifact("fast", "tts_base")
    assert asr_key is not None and tts_key is not None
    settings = Settings(
        qwen3_model_dir=tmp_path / asr_key,
        asr_resident_bytes=1 * 1024**3,
        qwen3_python=None,
        qwen3_tts_model_dir=tmp_path / tts_key,
        tts_resident_bytes=1 * 1024**3,
        qwen3_tts_clone_model_dir=(tmp_path / clone_key if clone_key else None),
        qwen3_tts_python=None,
        selection_schema_version=2,
        selection_asr_spec=asr_spec,
        selection_tts_spec="fast",
        asr_artifact_key=asr_key,
        tts_artifact_key=tts_key,
        tts_base_artifact_key=clone_key,
    )
    client = TestClient(create_app(settings))

    profile = f"{asr_spec}/fast"
    health = client.get("/health").json()
    assert health["backend"] == asr_key
    assert health["profile"] == profile

    by_id = {
        item["id"]: item for item in client.get("/v1/models").json()["data"]
    }
    asr = artifacts[asr_key]
    tts = artifacts[tts_key]
    assert by_id[settings.model_id] == {
        "id": settings.model_id,
        "object": "model",
        "owned_by": "speechrail",
        "created": 0,
        "profile": profile,
        "artifact": asr.key,
        "source_model": asr.model_id,
        "family": asr.family,
        "variant": asr.variant,
        "quantization": asr.quantization.model_dump(mode="json"),
    }
    tts_entry = by_id[settings.tts_model_id]
    assert {
        key: tts_entry[key]
        for key in (
            "id",
            "object",
            "owned_by",
            "created",
            "profile",
            "artifact",
            "source_model",
            "family",
            "variant",
            "quantization",
        )
    } == {
        "id": settings.tts_model_id,
        "object": "model",
        "owned_by": "speechrail",
        "created": 0,
        "profile": profile,
        "artifact": tts.key,
        "source_model": tts.model_id,
        "family": tts.family,
        "variant": tts.variant,
        "quantization": tts.quantization.model_dump(mode="json"),
    }
    capabilities = tts_entry["capabilities"]
    assert {
        key: capabilities[key]
        for key in ("supports_preview", "supports_clone", "supports_instruction")
    } == {
        "supports_preview": tts.variant == "voice_design",
        "supports_clone": clone_key is not None and clone_key in artifacts,
        "supports_instruction": tts.variant == "voice_design",
    }
    # W8 adds the voice-independent incremental axis at model scope. It must
    # never claim that every voice of this model can stream.
    streaming_input = capabilities["streaming_input"]
    assert streaming_input["scope"] == "per_voice"
    assert "supported" not in streaming_input
    assert set(streaming_input["axes"]) == {
        "implementation_supported",
        "protocol_negotiated",
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


def test_runtime_openapi_describes_binary_speech_responses() -> None:
    response = _client().app.openapi()["paths"]["/v1/audio/speech"]["post"]["responses"]["200"]

    expected_media_types = {
        "audio/mpeg",
        "audio/opus",
        "audio/aac",
        "audio/flac",
        "audio/wav",
        "audio/x-pcm",
    }
    assert response["description"] == "Synthesized audio stream"
    assert set(response["content"]) == expected_media_types
    assert all(
        media["schema"] == {"type": "string", "format": "binary"}
        for media in response["content"].values()
    )


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
        "realtime_vad": {
            "configured_engine": "auto",
            "resolved_engine": "legacy",
            "speech_admission_enabled": True,
            "ready": True,
            "code": None,
            "message": "legacy VAD is ready",
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
        "version": "3.2.1",
        "backend": "speechrail/qwen3-asr-1.7b",
        "profile": None,
        "asr_ready": False,
        "asr_runtime_revision": None,
        "tts_ready": True,
        "tts_warm": True,
        "diarization_ready": False,
        "diarization": {
            "configured": False,
            "ready": False,
            "code": "diarization_not_configured",
            "message": "diarization profile is not configured",
            "profile": None,
        },
        "realtime_vad": {
            "configured_engine": "auto",
            "resolved_engine": "legacy",
            "speech_admission_enabled": True,
            "ready": True,
            "code": None,
            "message": "legacy VAD is ready",
        },
        "asr_state": "unconfigured",
        "tts_state": "active",
        "tts_lifecycle": None,
        "streaming_state": "unconfigured",
        "job_spool_ready": False,
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
        "realtime_vad": {
            "configured_engine": "auto",
            "resolved_engine": "legacy",
            "speech_admission_enabled": True,
            "ready": True,
            "code": None,
            "message": "legacy VAD is ready",
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
        asr_resident_bytes=1 * 1024**3,
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
            "realtime_vad": {
                "configured_engine": "auto",
                "resolved_engine": "legacy",
                "speech_admission_enabled": True,
                "ready": True,
                "code": None,
                "message": "legacy VAD is ready",
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
        ready = False
        model_variant = "custom_voice"

        def __init__(self, config: object, *, on_delivery_event: object | None = None) -> None:
            del config
            del on_delivery_event

        async def start(self) -> None:
            lifecycle.append("tts.start")
            raise RuntimeError("tts_start_failed")

        async def close(self) -> None:
            lifecycle.append("tts.close")

    monkeypatch.setattr(services_module, "Qwen3Worker", FakeAsrWorker)
    monkeypatch.setattr(services_module, "Qwen3TtsWorker", FailingTtsWorker)
    monkeypatch.setattr(
        services_module,
        "inspect_model",
        lambda _: SimpleNamespace(variant="custom_voice"),
    )
    settings = Settings(
        qwen3_model_dir=asr_snapshot,
        asr_resident_bytes=1 * 1024**3,
        qwen3_python=Path(executable),
        qwen3_tts_model_dir=tts_snapshot,
        tts_resident_bytes=1 * 1024**3,
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
