"""Frozen composition-root behavior for the application lifecycle refactor."""

from __future__ import annotations

import asyncio
from pathlib import Path
from sys import executable
from typing import Any

import pytest
from fastapi.testclient import TestClient

import speechrail.application.services as services_module
from speechrail.app import create_app
from speechrail.application.lifecycle import RuntimeLifecycle
from speechrail.application.services import AppOverrides, AppServices, build_app_services
from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings


@pytest.fixture
def fake_services() -> AppServices:
    settings = Settings(api_key=None, qwen3_model_dir=None, qwen3_python=None)
    return AppServices(
        settings=settings,
        transcribe=None,
        batch_transcriber=None,
        realtime_asr_factory=None,
        diarization_engine=None,
        tts_synthesizer=None,
        job_repository=None,
        asr_worker=None,
        admission=services_module.AdmissionQueue(settings.max_queue_size),
        governor=services_module.ResourceGovernor(settings.governor_limits),
        lifecycle=RuntimeLifecycle(),
    )


def test_audio_router_can_be_built_from_fake_services(fake_services: AppServices) -> None:
    from speechrail.http.routes.audio import create_audio_router

    router = create_audio_router(fake_services)

    assert {route.path for route in router.routes} == {
        "/v1/audio/transcriptions",
        "/v1/audio/speech",
    }


def test_system_router_can_be_built_from_fake_services(fake_services: AppServices) -> None:
    from speechrail.http.routes.system import create_system_router

    router = create_system_router(fake_services)

    assert {route.path for route in router.routes} == {
        "/health",
        "/readyz",
        "/metrics",
        "/v1/models",
        "/v1/voices",
        "/v1/voices/{voice_id}",
    }


class _FakeRepository:
    def __init__(self, calls: list[str]) -> None:
        self._calls = calls

    def recover_interrupted(self) -> None:
        self._calls.append("repository.recover")


class _FakeWorker:
    def __init__(self, calls: list[str], name: str, *, fail_on_start: bool = False) -> None:
        self._calls = calls
        self._name = name
        self._fail_on_start = fail_on_start

    async def start(self) -> None:
        self._calls.append(f"{self._name}.start")
        if self._fail_on_start:
            raise RuntimeError(f"{self._name}.start failed")

    async def close(self) -> None:
        self._calls.append(f"{self._name}.close")


def _lifecycle(calls: list[str], *, tts_fails: bool) -> Any:
    from speechrail.application.lifecycle import RuntimeLifecycle

    return RuntimeLifecycle(
        repository=_FakeRepository(calls),
        asr=_FakeWorker(calls, "asr"),
        tts=_FakeWorker(calls, "tts", fail_on_start=tts_fails),
        runner=None,
        poll_seconds=0.01,
    )


def test_lifespan_rolls_back_started_components() -> None:
    calls: list[str] = []
    lifecycle = _lifecycle(calls, tts_fails=True)

    def scenario() -> None:
        async def run() -> None:
            with pytest.raises(RuntimeError, match=r"tts\.start"):
                async with lifecycle.run():
                    pass

        asyncio.run(run())

    scenario()

    assert calls == ["repository.recover", "asr.start", "tts.start", "asr.close"]


def test_lifespan_closes_started_components_once_on_normal_exit() -> None:
    calls: list[str] = []
    lifecycle = _lifecycle(calls, tts_fails=False)

    def scenario() -> None:
        async def run() -> None:
            async with lifecycle.run():
                pass
            await lifecycle.close()

        asyncio.run(run())

    scenario()

    assert calls == ["repository.recover", "asr.start", "tts.start", "tts.close", "asr.close"]


def test_fake_overrides_never_construct_real_qwen_workers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    asr_snapshot = tmp_path / "external-qwen3-asr-snapshot"
    asr_snapshot.mkdir()
    for filename in (*MODEL_FILES, "model.safetensors"):
        (asr_snapshot / filename).touch()
    tts_snapshot = tmp_path / "external-qwen3-tts-snapshot"
    tts_snapshot.mkdir()
    (tts_snapshot / "config.json").touch()

    def _forbidden(config: object) -> None:
        del config
        raise AssertionError("fake overrides must not construct real workers")

    class ReadySynthesizer:
        ready = True

    monkeypatch.setattr(services_module, "Qwen3Worker", _forbidden)
    monkeypatch.setattr(services_module, "Qwen3TtsWorker", _forbidden)

    def fake_transcribe(audio: bytes, language: str | None, prompt: str) -> object:
        del audio, language, prompt
        raise AssertionError("transcribe is not expected in this composition test")

    app = create_app(
        Settings(
            qwen3_model_dir=asr_snapshot,
            qwen3_python=Path(executable),
            qwen3_tts_model_dir=tts_snapshot,
            qwen3_tts_python=Path(executable),
        ),
        transcribe=fake_transcribe,  # type: ignore[arg-type]
        tts_synthesizer=ReadySynthesizer(),  # type: ignore[arg-type]
    )

    with TestClient(app) as client:
        health = client.get("/health")

    assert health.status_code == 200
    assert health.json()["asr_ready"] is True
    assert health.json()["tts_ready"] is True


def test_lifespan_logs_worker_startup_failure_with_stderr_tail(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    import logging

    import speechrail.app as app_module
    from speechrail.application.lifecycle import RuntimeLifecycle

    class _FailingLifecycle(RuntimeLifecycle):
        async def start(self) -> None:
            raise RuntimeError(
                "worker_load_error; worker stderr tail:\n"
                "mlx.core: [Metal] failed to allocate model weights"
            )

    settings = Settings(api_key=None, qwen3_model_dir=None, qwen3_python=None)
    failing_services = AppServices(
        settings=settings,
        transcribe=None,
        batch_transcriber=None,
        realtime_asr_factory=None,
        diarization_engine=None,
        tts_synthesizer=None,
        job_repository=None,
        asr_worker=None,
        admission=services_module.AdmissionQueue(settings.max_queue_size),
        governor=services_module.ResourceGovernor(settings.governor_limits),
        lifecycle=_FailingLifecycle(),
    )
    monkeypatch.setattr(
        app_module, "build_app_services", lambda _settings, _overrides: failing_services
    )

    app = app_module.create_app(settings)
    with (
        caplog.at_level(logging.ERROR, logger="speechrail.app"),
        pytest.raises(RuntimeError, match="worker_load_error"),
        TestClient(app),
    ):
        pass

    assert "speechrail startup failed" in caplog.text.lower()
    assert "failed to allocate model weights" in caplog.text


def test_native_realtime_uses_dedicated_streaming_worker_not_batch(
    tmp_path: Path,
) -> None:
    """Batch and native realtime must never share one worker transport.

    A realtime session's read loop parks on the transport between frames, while
    batch transcription needs its own request/response exchange on the same
    pipe; with no routing ids on session frames either read crashes
    readexactly or a locked read deadlocks every batch request. The composition
    root therefore wires a dedicated streaming worker for realtime.
    """
    snapshot = tmp_path.parent / "external-qwen3-wiring-profile"
    snapshot.mkdir(exist_ok=True)
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()

    settings = Settings(
        qwen3_model_dir=snapshot,
        qwen3_python=Path(executable),
        realtime_asr_backend="native",
        _env_file=None,
    )
    services = build_app_services(settings, AppOverrides())

    assert services.batch_transcriber is not None
    assert services.realtime_asr_factory is not None
    assert services.asr_worker is not None
    streaming_worker = getattr(services.realtime_asr_factory, "_worker", None)
    assert type(streaming_worker).__name__ == "Qwen3StreamingWorker"
    assert streaming_worker is not services.asr_worker


def test_build_app_services_tts_dtype_resolves_from_snapshot(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A pre-quantized TTS snapshot drives backend config dtype to int8."""
    captured: dict[str, str] = {}
    real_worker = services_module.Qwen3TtsWorker

    def spy_worker(config: object) -> object:
        captured["dtype"] = getattr(config, "dtype", "")
        return real_worker(config)

    monkeypatch.setattr(services_module, "Qwen3TtsWorker", spy_worker)
    asr_snapshot = tmp_path / "asr"
    asr_snapshot.mkdir()
    for filename in (*MODEL_FILES, "model.safetensors"):
        (asr_snapshot / filename).touch()
    tts_snapshot = tmp_path / "tts"
    tts_snapshot.mkdir()
    (tts_snapshot / "config.json").write_text(
        '{"tts_model_type": "voice_design", "quantization": {"bits": 8, "group_size": 64}}',
        encoding="utf-8",
    )
    settings = Settings(
        qwen3_model_dir=asr_snapshot,
        qwen3_python=Path(executable),
        qwen3_tts_model_dir=tts_snapshot,
        qwen3_tts_python=Path(executable),
        _env_file=None,
    )
    build_app_services(settings, AppOverrides())
    assert captured["dtype"] == "int8"


def test_build_app_services_asr_and_streaming_dtype_resolves_from_snapshot(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A pre-quantized ASR snapshot drives batch and streaming dtype to int8.

    The wiring must pick up the snapshot's quantization state so a ``-8bit`` ASR
    snapshot resolves to an int8 identity even when ``SPEECHRAIL_DTYPE`` is the
    float16 default. Before this, the batch/streaming config kept float16 and the
    worker's identity check failed with ``backend_identity_mismatch``.
    """
    captured: dict[str, str] = {}
    real_batch = services_module.Qwen3Worker
    real_streaming = services_module.Qwen3StreamingWorker

    def spy_batch(config: object, **kwargs: object) -> object:
        captured["asr"] = getattr(config, "dtype", "")
        return real_batch(config, **kwargs)

    def spy_streaming(config: object, **kwargs: object) -> object:
        captured["streaming"] = getattr(config, "dtype", "")
        return real_streaming(config, **kwargs)

    monkeypatch.setattr(services_module, "Qwen3Worker", spy_batch)
    monkeypatch.setattr(services_module, "Qwen3StreamingWorker", spy_streaming)

    asr_snapshot = tmp_path.parent / "external-qwen3-asr-8bit-wiring"
    asr_snapshot.mkdir(exist_ok=True)
    for filename in (*MODEL_FILES, "model.safetensors"):
        (asr_snapshot / filename).touch()
    (asr_snapshot / "config.json").write_text(
        '{"quantization": {"bits": 8, "group_size": 64}}', encoding="utf-8"
    )

    settings = Settings(
        qwen3_model_dir=asr_snapshot,
        qwen3_python=Path(executable),
        realtime_asr_backend="native",
        _env_file=None,
    )
    build_app_services(settings, AppOverrides())

    assert captured["asr"] == "int8"
    assert captured["streaming"] == "int8"


def test_batch_and_streaming_share_one_physical_owner(tmp_path: Path) -> None:
    snapshot = tmp_path / "shared-snapshot"
    snapshot.mkdir()
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()
    settings = Settings(
        _env_file=None, qwen3_model_dir=snapshot, qwen3_python=Path(executable),
        realtime_asr_backend="native", worker_lazy_load=True,
    )
    services = build_app_services(settings, AppOverrides())
    owner = services.asr_worker.shared_owner
    assert services.realtime_asr_factory._worker.shared_owner is owner
    assert services.lifecycle._pending == (owner,)
    assert services.lifecycle._evictor._workers == (owner,)


def test_explicit_batch_override_does_not_construct_real_asr(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    snapshot = tmp_path / "unused-snapshot"
    snapshot.mkdir()
    settings = Settings(
        _env_file=None, qwen3_model_dir=snapshot, qwen3_python=Path(executable),
    )
    fake = object()

    def forbidden(*args: object, **kwargs: object) -> object:
        raise AssertionError("real ASR construction is forbidden")

    monkeypatch.setattr(services_module, "Qwen3Worker", forbidden)
    result = build_app_services(settings, AppOverrides(batch_transcriber=fake))
    assert result.batch_transcriber is fake
    assert result.asr_worker is None
