from collections.abc import AsyncIterator, Awaitable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import speechrail.http.routes.audio as audio_module
from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.ports import TranscriptionRequest
from speechrail.runtime.asr_mode import AsrModeBusy


def _backend(
    _: bytes, __: str | None, ___: str, ____: bool = False
) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="hello",
            language="en",
            duration_ms=1000,
            segments=(TranscriptSegment(id=0, start_ms=0, end_ms=1000, text="hello"),),
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


def test_busy_asr_mode_returns_stable_429_with_request_id() -> None:
    async def busy_backend(
        audio: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
    ) -> TranscriptResult:
        del audio, language, prompt, include_timestamps
        raise AsrModeBusy("streaming ASR is active")

    client = TestClient(
        create_app(
            Settings(max_upload_bytes=8, qwen3_model_dir=None, qwen3_python=None),
            transcribe=busy_backend,
        )
    )
    request_id = "req_mode_busy"

    response = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        headers={"X-Request-ID": request_id},
    )

    assert response.status_code == 429
    assert response.headers["X-Request-ID"] == request_id
    assert response.headers["Retry-After"] == "1"
    assert response.json()["error"] == {
        "message": "ASR mode is busy",
        "type": "server_error",
        "code": "backend_busy",
        "request_id": request_id,
        "retryable": True,
    }


def test_ffmpeg_resolution_uses_absolute_fallback_without_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    ffmpeg = tmp_path / "ffmpeg"
    ffmpeg.touch()
    monkeypatch.setattr(audio_module.shutil, "which", lambda _: None)
    monkeypatch.setattr(audio_module, "_FFMPEG_FALLBACKS", (ffmpeg,))

    assert audio_module._resolve_ffmpeg() == str(ffmpeg)


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


def test_long_audio_limit_is_independent_of_single_ipc_frame() -> None:
    settings = Settings(_env_file=None, max_audio_seconds=3600)
    assert settings.max_audio_seconds == 3600
    assert Settings(_env_file=None, max_audio_seconds=7200).max_audio_seconds == 7200


def test_real_streaming_batch_port_consumes_decoded_audio_incrementally(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    produced: list[int] = []

    async def decoded(*_args: object, **_kwargs: object) -> AsyncIterator[bytes]:
        produced.append(1)
        yield b"\x00\x00" * 16_000
        produced.append(2)
        yield b"\x00\x00" * 16_000

    class _StreamingBatch:
        async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
            raise AssertionError(f"whole-file fallback used: {len(request.audio)}")

        async def transcribe_stream(
            self,
            request_id: str,
            audio: AsyncIterator[bytes],
            language: str | None = None,
            prompt: str | None = None,
            include_timestamps: bool = True,
        ) -> TranscriptResult:
            chunk_count = 0
            total_bytes = 0
            async for chunk in audio:
                chunk_count += 1
                total_bytes += len(chunk)
                if chunk_count == 1:
                    assert produced == [1]
            return TranscriptResult(
                request_id=request_id,
                model_id="speechrail/qwen3-asr-1.7b",
                text="incremental",
                language=language or "auto",
                duration_ms=total_bytes // 32,
            )

    monkeypatch.setattr(audio_module, "decode_upload", decoded)
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            batch_transcriber=_StreamingBatch(),
        )
    )
    response = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.webm", b"container", "video/webm")},
        data={"language": "zh"},
    )

    assert response.status_code == 200
    assert response.json()["text"] == "incremental"
    assert produced == [1, 2]


def test_transcription_rejects_stream_and_chunking_strategy() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            transcribe=_backend,
        )
    )
    streamed = client.post(
        "/v1/audio/transcriptions",
        data={"model": "speechrail/qwen3-asr-1.7b", "stream": "true"},
        files={"file": ("clip.wav", b"1234", "audio/wav")},
    )
    assert streamed.status_code == 422
    assert streamed.json()["error"]["code"] == "stream_unsupported"

    chunked = client.post(
        "/v1/audio/transcriptions",
        data={
            "model": "speechrail/qwen3-asr-1.7b",
            "chunking_strategy": '{"type":"auto"}',
        },
        files={"file": ("clip.wav", b"1234", "audio/wav")},
    )
    assert chunked.status_code == 422
    assert chunked.json()["error"]["code"] == "chunking_strategy_unsupported"


def test_transcription_languages_falls_back_to_first_language() -> None:
    seen: list[str | None] = []

    async def backend(
        audio: bytes, language: str | None, prompt: str, include_timestamps: bool = False
    ) -> TranscriptResult:
        seen.append(language)
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="hello",
            language=language or "auto",
            duration_ms=1,
        )

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            transcribe=backend,
        )
    )
    response = client.post(
        "/v1/audio/transcriptions",
        data={
            "model": "speechrail/qwen3-asr-1.7b",
            "languages": ["zh", "en"],
        },
        files={"file": ("clip.wav", b"1234", "audio/wav")},
    )
    assert response.status_code == 200
    assert seen == ["zh"]


def test_speech_accepts_instructions_and_rejects_other_stream_format() -> None:
    class FakeTTS:
        def synthesize(self, request: object):
            async def chunks():
                yield __import__("speechrail.domain.ports", fromlist=["AudioChunk"]).AudioChunk(
                    response_id="r", chunk_index=0, audio=b"\x00\x00"
                )

            return chunks()

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeTTS(),
        )
    )
    ok = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "hello",
            "voice": "default",
            "instructions": "speak softly",
            "response_format": "pcm",
        },
    )
    assert ok.status_code == 200

    bad = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "hello",
            "voice": "default",
            "stream_format": "sse",
        },
    )
    assert bad.status_code == 422
    assert bad.json()["error"]["code"] == "stream_format_unsupported"


def test_transcription_accepts_openai_standard_model_aliases() -> None:
    for model in ("gpt-4o-transcribe", "gpt-4o-mini-transcribe"):
        response = _client().post(
            "/v1/audio/transcriptions",
            files={"file": ("clip.wav", b"1234", "audio/wav")},
            data={"model": model},
        )
        assert response.status_code == 200
        assert response.json()["text"] == "hello"


def test_speech_accepts_openai_standard_model_aliases() -> None:
    class FakeTTS:
        def synthesize(self, request: object):
            async def chunks():
                yield __import__("speechrail.domain.ports", fromlist=["AudioChunk"]).AudioChunk(
                    response_id="r", chunk_index=0, audio=b"\x00\x00"
                )

            return chunks()

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeTTS(),
        )
    )
    for model in ("tts-1", "tts-1-hd", "gpt-4o-mini-tts"):
        ok = client.post(
            "/v1/audio/speech",
            json={"model": model, "input": "hello", "voice": "default"},
        )
        assert ok.status_code == 200


def test_wav_fast_path_decode() -> None:
    from speechrail.http.routes.audio import _try_fast_decode_wav, _wav_pcm16

    # 1. Valid 16kHz mono 16bit PCM WAV
    pcm_data = b"\x00\x00\x10\x00\x20\x00" * 100
    valid_wav = _wav_pcm16(pcm_data, sample_rate=16_000)
    assert _try_fast_decode_wav(valid_wav) == pcm_data

    # 2. Resampled sample rate (24000Hz -> 16000Hz)
    wav_24k = _wav_pcm16(pcm_data, sample_rate=24_000)
    resampled = _try_fast_decode_wav(wav_24k)
    assert resampled is not None
    assert abs(len(resampled) - int(len(pcm_data) * 16_000 / 24_000)) <= 4

    # 3. Not a WAV
    assert _try_fast_decode_wav(b"not a wav file") is None
    assert _try_fast_decode_wav(b"") is None

    # 4. Truncated WAV header
    assert _try_fast_decode_wav(valid_wav[:30]) is None

@pytest.mark.parametrize(
    ("prompt", "status"),
    [("p" * 2_000, 200), ("p" * 2_001, 422)],
)
def test_transcription_prompt_honors_openai_two_thousand_char_limit(
    prompt: str, status: int
) -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"response_format": "json", "prompt": prompt},
    )

    assert response.status_code == status
    if status == 422:
        error = response.json()["error"]
        assert error["code"] == "prompt_too_long"
        assert error["param"] == "prompt"


def test_transcription_rejects_audio_exceeding_max_audio_seconds() -> None:
    pcm_2s = b"\x00\x00" * 32_000
    wav_2s = audio_module._wav_pcm16(pcm_2s, sample_rate=16_000)

    client = TestClient(
        create_app(
            Settings(max_audio_seconds=1, qwen3_model_dir=None, qwen3_python=None),
            transcribe=_backend,
        )
    )
    response = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", wav_2s, "audio/wav")},
    )
    assert response.status_code == 400
    payload = response.json()
    assert payload["error"]["code"] == "audio_too_long"
    assert payload["error"]["param"] == "file"
    assert "exceeds maximum limit" in payload["error"]["message"]


def _lane_services(**settings_kwargs):
    import threading

    from speechrail.application.services import AppOverrides, build_app_services

    release = threading.Event()
    entered = threading.Event()

    def _blocking_backend(_, __, ___, ____=False):
        import asyncio

        async def result():
            entered.set()
            await asyncio.to_thread(release.wait, 10)
            return TranscriptResult(
                request_id="backend",
                model_id="speechrail/qwen3-asr-1.7b",
                text="hello",
                language="en",
                duration_ms=1000,
            )

        return result()

    settings = Settings(
        max_upload_bytes=8, qwen3_model_dir=None, qwen3_python=None, **settings_kwargs
    )
    services = build_app_services(settings, AppOverrides(transcribe=_blocking_backend))
    return services, release, entered


def _bare_audio_app(services):
    from fastapi import FastAPI

    from speechrail.http.errors import RequestIdMiddleware
    from speechrail.http.routes.audio import create_audio_router

    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    return TestClient(app)


def test_batch_transcription_holds_governor_batch_lane() -> None:
    """The REST transcription path must consume the governor's BATCH_ASR lane."""
    import threading
    import time

    services, release, entered = _lane_services()
    client = _bare_audio_app(services)

    responses: list = []

    def do_post() -> None:
        responses.append(
            client.post(
                "/v1/audio/transcriptions",
                files={"file": ("clip.wav", b"1234", "audio/wav")},
            )
        )

    thread = threading.Thread(target=do_post)
    thread.start()
    assert entered.wait(5.0), "blocking transcription never entered the backend"
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if services.governor.snapshot().active_batch == 1:
            break
        time.sleep(0.01)
    assert services.governor.snapshot().active_batch == 1, (
        "batch transcription bypassed the ResourceGovernor"
    )

    release.set()
    thread.join(10)
    assert responses[0].status_code == 200


def test_batch_speech_holds_governor_batch_tts_lane() -> None:
    """The REST speech path must consume the governor's BATCH_TTS lane."""
    import asyncio
    import threading
    import time

    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.domain.ports import AudioChunk

    release = threading.Event()
    entered = threading.Event()

    class _BlockingTts:
        def synthesize(self, request):
            async def chunks():
                entered.set()
                await asyncio.to_thread(release.wait, 10)
                yield AudioChunk(response_id="r", chunk_index=0, audio=b"\x00\x00" * 64)

            return chunks()

    settings = Settings(qwen3_model_dir=None, qwen3_python=None)
    services = build_app_services(
        settings, AppOverrides(tts_synthesizer=_BlockingTts())
    )
    client = _bare_audio_app(services)

    responses: list = []

    def do_post() -> None:
        responses.append(
            client.post(
                "/v1/audio/speech",
                json={
                    "model": "tts-1",
                    "input": "hello",
                    "voice": "default",
                    "response_format": "wav",
                },
            )
        )

    thread = threading.Thread(target=do_post)
    thread.start()
    assert entered.wait(5.0), "blocking synthesis never entered the backend"
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if services.governor.snapshot().active_batch >= 1:
            break
        time.sleep(0.01)
    assert services.governor.snapshot().active_batch >= 1, (
        "batch speech bypassed the ResourceGovernor"
    )

    release.set()
    thread.join(10)
    assert responses[0].status_code == 200


def test_governor_queue_full_maps_to_429_queue_full() -> None:
    """A governor queue overflow on the REST path returns 429 with Retry-After.

    All requests share one event loop (httpx ASGI transport) because the
    governor's admission condition is bound to the loop that uses it.
    """
    import asyncio
    import time

    import httpx

    services, release, entered = _lane_services(
        runtime_total_capacity=2,
        realtime_reserved_capacity=1,
        runtime_max_pending_per_class=1,
    )
    from fastapi import FastAPI

    from speechrail.http.errors import RequestIdMiddleware
    from speechrail.http.routes.audio import create_audio_router

    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))

    async def scenario() -> list[int]:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test"
        ) as client:

            async def post() -> int:
                response = await client.post(
                    "/v1/audio/transcriptions",
                    files={"file": ("clip.wav", b"1234", "audio/wav")},
                )
                return response.status_code

            first_task = asyncio.create_task(post())
            await asyncio.to_thread(entered.wait, 5.0)
            assert entered.is_set(), "blocking transcription never entered"

            other_tasks = [asyncio.create_task(post()) for _ in range(2)]
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                one_rejected = sum(task.done() for task in other_tasks) >= 1
                if one_rejected and services.governor.snapshot().pending_batch == 1:
                    break
                await asyncio.sleep(0.01)
            release.set()
            first_code = await first_task
            other_results = await asyncio.gather(*other_tasks)
            return [first_code, *other_results]

    codes = sorted(asyncio.run(scenario()))
    assert codes == [200, 200, 429], codes
