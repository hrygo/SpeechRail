from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from pathlib import Path
from sys import executable
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import speechrail.application.services as services_module
from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import get_voice_registry


class FakeSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            assert request.text == "你好"
            assert request.voice == "serena"
            yield AudioChunk(response_id="resp-test", chunk_index=0, audio=b"\x00\x00")
            yield AudioChunk(response_id="resp-test", chunk_index=1, audio=b"\x01\x00")

        return chunks()


class SlowFirstSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        del request

        async def chunks() -> AsyncIterator[AudioChunk]:
            await asyncio.sleep(0.05)
            yield AudioChunk(response_id="slow", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def test_speech_timeout_covers_worker_output_after_admission() -> None:
    client = TestClient(
        create_app(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
                request_timeout_seconds=0.01,
            ),
            tts_synthesizer=SlowFirstSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_timeout"


def test_openai_compatible_speech_endpoint_streams_pcm() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/x-pcm")
    assert response.content == b"\x00\x00\x01\x00"


def test_speech_endpoint_wraps_wav_after_collecting_pcm() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "wav",
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")
    assert response.content[:4] == b"RIFF"
    assert response.content[8:12] == b"WAVE"
    assert response.content[40:44] == (4).to_bytes(4, "little")
    assert response.content[44:] == b"\x00\x00\x01\x00"


class EchoSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="resp-test", chunk_index=0, audio=bytes(24_000 * 2 // 10)
            )

        return chunks()


def _speech_client() -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=EchoSpeechSynthesizer(),
        )
    )


@pytest.mark.parametrize(
    ("response_format", "content_type", "magic"),
    [
        ("mp3", "audio/mpeg", None),
        ("opus", "audio/opus", b"OggS"),
        ("aac", "audio/aac", None),
        ("flac", "audio/flac", b"fLaC"),
    ],
)
def test_speech_endpoint_supports_openai_container_formats(
    response_format: str, content_type: str, magic: bytes | None
) -> None:
    response = _speech_client().post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": response_format,
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith(content_type)
    body = response.content
    assert body
    if magic is not None:
        assert body[: len(magic)] == magic
    elif response_format == "mp3":
        assert body[:3] == b"ID3" or (body[0] == 0xFF and body[1] & 0xE0 == 0xE0)
    else:  # aac / ADTS
        assert body[0] == 0xFF and body[1] & 0xF6 == 0xF0


def test_speech_endpoint_defaults_to_mp3_for_openai_parity() -> None:
    response = _speech_client().post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/mpeg")


class PreviewCapturingSpeechSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="preview", chunk_index=0, audio=b"\x00\x00\x01\x00")

        return chunks()


def _preview_client(
    tmp_path: Path, preset_id: str = "quality"
) -> tuple[TestClient, PreviewCapturingSpeechSynthesizer, Path]:
    preset = load_catalog().preset(preset_id)
    synthesizer = PreviewCapturingSpeechSynthesizer()
    custom_voices = tmp_path / "custom_voices.json"
    client = TestClient(
        create_app(
            Settings(
                api_key=None,
                qwen3_model_dir=tmp_path / preset.asr,
                asr_resident_bytes=1 * 1024**3,
                qwen3_python=None,
                qwen3_tts_model_dir=tmp_path / preset.tts,
                tts_resident_bytes=1 * 1024**3,
                qwen3_tts_python=None,
            ),
            tts_synthesizer=synthesizer,
        )
    )
    return client, synthesizer, custom_voices


@pytest.mark.parametrize("tier", ["quality", "extreme"])
def test_voice_preview_returns_audio_without_creating_voice_profile(
    tmp_path: Path, tier: str
) -> None:
    client, synthesizer, custom_voices = _preview_client(tmp_path, tier)

    response = client.post(
        "/v1/voices/previews",
        json={
            "model": "tts-1",
            "input": "试听这一句。",
            "instruction": "温暖自然的中文女声。",
            "seed": 12345,
            "response_format": "wav",
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")
    assert response.content[:4] == b"RIFF"
    assert synthesizer.requests[0].voice == "serena"
    assert synthesizer.requests[0].instruction == "温暖自然的中文女声。"
    assert synthesizer.requests[0].seed == 12345
    assert not custom_voices.exists()


def test_voice_preview_is_rejected_by_custom_voice_tiers(tmp_path: Path) -> None:
    client, _synthesizer, _custom_voices = _preview_client(tmp_path, "balanced")

    response = client.post(
        "/v1/voices/previews",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "试听这一句。",
            "instruction": "自然的中文女声。",
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_preview_unsupported"
    assert "quality" not in response.json()["error"]["message"].lower()


def test_quality_speech_accepts_instructions_and_passes_them_to_backend(
    tmp_path: Path,
) -> None:
    client, synthesizer, _custom_voices = _preview_client(tmp_path)
    instruction = "成年男性中文声线，低沉、近距离、克制而清晰。"
    text = "你可以称我为愚者。"

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": text,
            "voice": "uncle_fu",
            "response_format": "wav",
            "speed": 0.94,
            "language": "zh",
            "instructions": instruction,
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")
    assert synthesizer.requests[0].text == text
    assert synthesizer.requests[0].instruction == instruction


def test_speech_endpoint_caps_input_at_openai_limit() -> None:
    client = _speech_client()

    ok = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "啊" * 4096,
            "voice": "default",
            "response_format": "pcm",
        },
    )
    too_long = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "啊" * 4097,
            "voice": "default",
            "response_format": "pcm",
        },
    )

    assert ok.status_code == 200
    assert too_long.status_code == 422
    assert too_long.json()["error"]["code"] == "validation_error"
    assert too_long.json()["error"]["param"] == "input"


@pytest.mark.parametrize("length", [133, 136, 162])
def test_speech_endpoint_accepts_unicode_input_below_public_limit(length: int) -> None:
    text = ("这是一段用于验证中文语音合成边界的长文本。" * 20)[:length]
    assert len(text) == length

    response = _speech_client().post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": text,
            "voice": "uncle_fu",
            "response_format": "wav",
            "speed": 0.94,
            "language": "zh",
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")


class InvalidDeliverySynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="resp-test", chunk_index=0, audio=b"\x00\x00")
            yield AudioChunk(response_id="resp-test", chunk_index=2, audio=b"\x01\x00")

        return chunks()


class FailingSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            raise RuntimeError("worker_inference_error")
            yield AudioChunk(response_id="unreachable", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class UnavailableSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            raise RuntimeError("worker_unavailable; worker stderr tail: private detail")
            yield AudioChunk(response_id="unreachable", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def test_speech_endpoint_maps_invalid_delivery_to_unified_error_envelope() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=InvalidDeliverySynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 502
    error = response.json()["error"]
    assert error["code"] == "tts_chunk_order_invalid"
    assert error["type"] == "server_error"
    assert error["retryable"] is True
    assert error["request_id"]


@pytest.mark.parametrize("response_format", ["pcm", "wav", "mp3"])
def test_speech_endpoint_maps_worker_unavailable_to_stable_retry_diagnostic(
    response_format: str,
) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=UnavailableSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": response_format,
        },
    )

    assert response.status_code == 503
    assert response.headers["retry-after"] == "1"
    assert response.headers["speechrail-busy-reason"] == "backend_unavailable"
    assert response.headers["speechrail-retry-hint"] == "retry_after_worker_recovery"
    error = response.json()["error"]
    assert error["code"] == "backend_busy"
    assert error["retryable"] is True
    assert "private detail" not in response.text


def test_speech_endpoint_maps_backend_runtime_failure_to_unified_error_envelope() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FailingSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 502
    error = response.json()["error"]
    assert error["code"] == "backend_error"
    assert error["type"] == "server_error"
    assert error["retryable"] is True
    assert error["request_id"]


def test_speech_endpoint_returns_stable_not_ready_error_without_backend() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_ready"


def test_speech_endpoint_requires_bearer_key_when_configured() -> None:
    client = TestClient(
        create_app(
            Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_api_key"


def test_speech_endpoint_rejects_unknown_model_before_synthesis() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "not-a-model", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "model_not_found"


def test_speech_endpoint_validates_speed_at_the_public_boundary() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "speed": 9.0,
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_speech_endpoint_rejects_voice_outside_server_registry() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None, tts_voice_ids=("default",)),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "free-form-description",
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_not_found"


def test_speech_rejects_unavailable_custom_voice_before_synthesis(tmp_path: Path) -> None:
    preset = load_catalog().preset("balanced")

    class FailIfCalled:
        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            raise AssertionError("unavailable voice reached the TTS backend")

    client = TestClient(
        create_app(
            Settings(
                qwen3_model_dir=tmp_path / preset.asr,
                asr_resident_bytes=1 * 1024**3,
                qwen3_python=None,
                qwen3_tts_model_dir=tmp_path / preset.tts,
                tts_resident_bytes=1 * 1024**3,
                qwen3_tts_python=None,
            ),
            tts_synthesizer=FailIfCalled(),
        )
    )
    registry = get_voice_registry()
    voice_id = "test_unavailable_rest_voice"
    registry.create_custom_profile(
        name="不可用测试音色",
        instruction="自然清晰的中文女声。",
        voice_id=voice_id,
    )
    try:
        response = client.post(
            "/v1/audio/speech",
            json={
                "model": "tts-1",
                "input": "你好",
                "voice": voice_id,
                "response_format": "pcm",
            },
        )
    finally:
        registry.delete_custom_profile(voice_id)

    assert response.status_code == 400
    error = response.json()["error"]
    assert error["code"] == "voice_not_available"
    assert error["param"] == "voice"
    assert error["retryable"] is False


def test_configured_tts_paths_create_and_lifecycle_manage_private_worker(
    monkeypatch, tmp_path: Path
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-app"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    instances: list[object] = []

    class FakeConfiguredWorker:
        @property
        def ready(self) -> bool:
            return self.started and not self.closed

        def __init__(self, config: object, *, on_delivery_event: object | None = None) -> None:
            self.config = config
            self.on_delivery_event = on_delivery_event
            self.started = False
            self.closed = False
            instances.append(self)

        async def start(self) -> None:
            self.started = True

        async def close(self) -> None:
            self.closed = True

        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            async def chunks() -> AsyncIterator[AudioChunk]:
                yield AudioChunk(response_id="resp-configured", chunk_index=0, audio=b"\x00\x00")

            return chunks()

    monkeypatch.setattr(services_module, "Qwen3TtsWorker", FakeConfiguredWorker)
    monkeypatch.setattr(
        services_module,
        "inspect_model",
        lambda _: SimpleNamespace(variant="voice_design"),
    )
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        qwen3_tts_model_dir=snapshot,
        tts_resident_bytes=1 * 1024**3,
        qwen3_tts_python=Path(executable),
        worker_lazy_load=False,
    )

    with TestClient(create_app(settings)) as client:
        response = client.post(
            "/v1/audio/speech",
            json={
                "model": "speechrail/qwen3-tts",
                "input": "你好",
                "voice": "default",
                "response_format": "wav",
            },
        )
        assert response.status_code == 200
        assert response.content[:4] == b"RIFF"
        assert instances[0].started is True

    assert instances[0].closed is True


class EmptySpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            return
            yield AudioChunk(response_id="resp-empty", chunk_index=0, audio=b"")

        return chunks()


@pytest.mark.parametrize("response_format", ["pcm", "wav", "mp3"])
def test_speech_endpoint_empty_synthesis_stream_is_502_for_every_format(
    response_format: str,
) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=EmptySpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": response_format,
        },
    )

    assert response.status_code == 502
    error = response.json()["error"]
    assert error["code"] == "audio_encode_failed"
    assert error["retryable"] is True


def test_speech_voice_alias_rejected_when_mapped_preset_not_registered() -> None:
    client = TestClient(
        create_app(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
                tts_voice_ids=("default",),
            ),
            tts_synthesizer=EchoSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "nova",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_not_found"


def _governor_histogram_labels(client: TestClient, name: str) -> set[str]:
    response = client.get("/metrics", headers={"accept": "application/json"})
    assert response.status_code == 200
    series = response.json()["histograms"].get(name, {})
    assert isinstance(series, dict)
    return set(series)


def test_speechrail_interactive_purpose_uses_realtime_governor_class() -> None:
    client = _speech_client()
    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Purpose": "interactive"},
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )
    assert response.status_code == 200

    labels = _governor_histogram_labels(
        client, "speechrail_governor_queue_wait_seconds"
    )
    assert any(
        'class="realtime_tts"' in label and 'purpose="interactive"' in label
        for label in labels
    )


def test_plain_openai_speech_keeps_historical_batch_admission() -> None:
    client = _speech_client()
    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )
    assert response.status_code == 200

    labels = _governor_histogram_labels(
        client, "speechrail_governor_queue_wait_seconds"
    )
    assert any(
        'class="batch_tts"' in label and 'purpose="default"' in label
        for label in labels
    )


def test_speechrail_prefetch_purpose_stays_in_batch_class() -> None:
    client = _speech_client()
    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Purpose": "prefetch"},
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )
    assert response.status_code == 200

    labels = _governor_histogram_labels(
        client, "speechrail_governor_queue_wait_seconds"
    )
    assert any(
        'class="batch_tts"' in label and 'purpose="prefetch"' in label
        for label in labels
    )


def test_speechrail_latency_budget_is_relative_and_server_bounded() -> None:
    class SlowBudgetSynthesizer:
        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            del request

            async def chunks() -> AsyncIterator[AudioChunk]:
                await asyncio.sleep(0.2)
                yield AudioChunk(
                    response_id="budget",
                    chunk_index=0,
                    audio=b"\x00\x00",
                )

            return chunks()

    client = TestClient(
        create_app(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
                request_timeout_seconds=1.0,
            ),
            tts_synthesizer=SlowBudgetSynthesizer(),
        )
    )
    response = client.post(
        "/v1/audio/speech",
        headers={
            "SpeechRail-Purpose": "interactive",
            "SpeechRail-Latency-Budget-Ms": "50",
        },
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_timeout"


def test_speechrail_purpose_rejects_arbitrary_priority_strings() -> None:
    client = _speech_client()
    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Purpose": "highest_priority"},
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
