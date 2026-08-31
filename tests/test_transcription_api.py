from collections.abc import Awaitable

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment


def _backend(_: bytes, __: str | None, ___: str) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="hello",
            language="en",
            duration_ms=1000,
            segments=(TranscriptSegment(id="seg_1", start_ms=0, end_ms=1000, text="hello"),),
        )

    return result()


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(max_upload_bytes=8, qwen3_model_dir=None, qwen3_python=None),
            transcribe=_backend,
        )
    )


def test_transcription_formats_results_from_one_domain_result() -> None:
    for response_format, content_type, expected in (
        ("json", "application/json", "hello"),
        ("verbose_json", "application/json", "hello"),
        ("text", "text/plain", "hello"),
        ("srt", "application/x-subrip", "hello"),
        ("vtt", "text/vtt", "hello"),
    ):
        response = _client().post(
            "/v1/audio/transcriptions",
            files={"file": ("clip.wav", b"1234", "audio/wav")},
            data={"response_format": response_format},
        )
        assert response.status_code == 200
        assert response.headers["content-type"].startswith(content_type)
        assert expected in response.text


@pytest.mark.parametrize(
    ("filename", "content_type"),
    (
        ("clip.webm", "video/webm"),
        ("clip.webm", "audio/webm; codecs=opus"),
        ("clip.mp4", "video/mp4"),
        ("clip.mpeg", "video/mpeg"),
        ("clip.wav", None),
        ("clip.bin", "application/octet-stream"),
    ),
)
def test_transcription_accepts_openai_audio_container_hints(
    filename: str, content_type: str | None
) -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        files={"file": (filename, b"1234", content_type)},
        data={"model": "whisper-1"},
    )

    assert response.status_code == 200
    assert response.json()["text"] == "hello"


def test_transcription_rejects_oversized_and_unsupported_mime() -> None:
    oversized = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"123456789", "audio/wav")},
    )
    assert oversized.status_code == 413
    assert oversized.json()["error"]["code"] == "audio_too_large"

    unsupported = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.txt", b"1234", "text/plain")},
    )
    assert unsupported.status_code == 422
    assert unsupported.json()["error"]["code"] == "unsupported_audio_type"
