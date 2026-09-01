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
from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings


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
    for filename in MODEL_FILES:
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
