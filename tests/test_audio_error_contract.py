"""The documented status code is the one the service actually returns.

``scripts/check_openapi_contract.py`` proves the runtime and the
machine-readable contract agree on paths, success codes and security.  It says
nothing about failures, which is how ``stream_unsupported``,
``unsupported_parameter`` and ``stream_format_unsupported`` came to promise
``400`` in the contract and the user guide while the routes answered ``422``.
These cases pin the failure half of the contract from the outside: a real
request, a real status, and the declared response set.
"""

from __future__ import annotations

import io
import wave
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import yaml
from fastapi import FastAPI
from fastapi.testclient import TestClient

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk
from speechrail.http.errors import RequestIdMiddleware
from speechrail.http.routes.audio import create_audio_router

_CONTRACT = Path(__file__).resolve().parents[1] / "contracts" / "openapi.yaml"
_TRANSCRIPTIONS = "/v1/audio/transcriptions"
_SPEECH = "/v1/audio/speech"


def test_serial_tts_isolation_blocks_transcription_without_retry() -> None:
    class RefusingTranscriber:
        async def transcribe(self, request: object) -> None:
            pytest.fail("isolated serial policy must not start ASR")

    services = build_app_services(
        Settings(qwen3_model_dir=None, qwen3_python=None),
        AppOverrides(
            batch_transcriber=RefusingTranscriber(),
            tts_synthesizer=_RefusingSynthesizer(),
        ),
    )
    assert not services.governor.snapshot().allow_heavy_overlap
    services.governor.quarantine_tts_lane("tts_base")
    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    audio = io.BytesIO()
    with wave.open(audio, "wb") as container:
        container.setnchannels(1)
        container.setsampwidth(2)
        container.setframerate(16000)
        container.writeframes(b"\x00\x00" * 1600)
    response = TestClient(app).post(
        _TRANSCRIPTIONS,
        headers={"X-Request-ID": "req_isolated_test"},
        data={"model": "whisper-1"},
        files={"file": ("synthetic.wav", audio.getvalue(), "audio/wav")},
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_reclamation_failed"
    assert response.json()["error"]["retryable"] is False
    assert response.json()["error"]["request_id"] == "req_isolated_test"
    assert "Retry-After" not in response.headers


class _RefusingSynthesizer:
    """Enough of a TTS port for the speech route to reach its option checks.

    The route resolves the render capability before it rejects an option it does
    not implement, so the contract cases need a live synthesizer.  None of these
    tests synthesizes anything: each request is refused first.
    """

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return None

    async def synthesize(self, request: object) -> AsyncIterator[AudioChunk]:
        del request
        raise AssertionError("unsupported-option cases must not synthesize")
        yield  # pragma: no cover - keeps the async generator signature


def _client() -> TestClient:
    services = build_app_services(
        Settings(qwen3_model_dir=None, qwen3_python=None),
        AppOverrides(tts_synthesizer=_RefusingSynthesizer()),
    )
    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    return TestClient(app)


def _unsupported_option_status() -> list[tuple[str, TestClient, dict, str]]:
    client = _client()
    return [
        (
            "transcription_stream",
            client,
            {
                "data": {"model": "speechrail/qwen3-asr-1.7b", "stream": "true"},
                "files": {"file": ("clip.wav", b"1234", "audio/wav")},
            },
            _TRANSCRIPTIONS,
        ),
        (
            "transcription_chunking_strategy",
            client,
            {
                "data": {
                    "model": "speechrail/qwen3-asr-1.7b",
                    "chunking_strategy": '{"type":"auto"}',
                },
                "files": {"file": ("clip.wav", b"1234", "audio/wav")},
            },
            _TRANSCRIPTIONS,
        ),
        (
            "speech_stream_format",
            client,
            {
                "json": {
                    "model": "speechrail/qwen3-tts",
                    "input": "hello",
                    "voice": "default",
                    "stream_format": "sse",
                },
            },
            _SPEECH,
        ),
    ]


@pytest.mark.parametrize(
    ("label", "client", "payload", "path"),
    _unsupported_option_status(),
    ids=[case[0] for case in _unsupported_option_status()],
)
def test_an_explicitly_unsupported_option_is_a_bad_request(
    label: str,
    client: TestClient,
    payload: dict,
    path: str,
) -> None:
    """An option this service deliberately does not implement is a client error.

    It is not a malformed request: the request is well formed and the service
    understood it perfectly well.  ``422`` would tell the caller to fix the
    payload, which cannot make an unimplemented option appear.
    """

    response = client.post(path, **payload)

    assert response.status_code == 400, label
    assert response.headers["x-request-id"], label
    error = response.json()["error"]
    assert error["code"].endswith("_unsupported") or error["code"] == (
        "unsupported_parameter"
    ), label
    assert error["retryable"] is False, label


def _declared_responses(path: str, method: str) -> set[str]:
    spec = yaml.safe_load(_CONTRACT.read_text(encoding="utf-8"))
    responses = spec["paths"][path][method]["responses"]
    return {str(code) for code in responses}


@pytest.mark.parametrize(
    ("path", "method", "status"),
    [
        (_TRANSCRIPTIONS, "post", "400"),
        (_TRANSCRIPTIONS, "post", "502"),
        (_SPEECH, "post", "400"),
    ],
)
def test_the_contract_declares_the_failure_statuses_the_service_returns(
    path: str, method: str, status: str
) -> None:
    assert status in _declared_responses(path, method)


def test_a_malformed_request_is_still_unprocessable() -> None:
    """Fixing the unsupported-option status must not flatten the 422 boundary."""

    response = _client().post(
        _TRANSCRIPTIONS,
        data={"model": "speechrail/qwen3-asr-1.7b", "temperature": "9"},
        files={"file": ("clip.wav", b"1234", "audio/wav")},
    )

    assert response.status_code == 422
