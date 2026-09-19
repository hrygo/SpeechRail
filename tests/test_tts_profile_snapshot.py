"""Private worker recipes remain the exact snapshot leased by the parent."""

from __future__ import annotations

import asyncio
import sys
from collections import Counter
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
import speechrail.domain.tts as voices
from speechrail.domain.ports import SpeechRequest
from speechrail.runtime.worker_protocol import ProtocolError
from test_qwen3_tts import _chunk_frame, _worker


def test_parent_sends_the_leased_recipe_even_after_alias_changes(
    tmp_path: Path, monkeypatch
) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json", tmp_path / "audio")
    registry.create_custom_profile(name="test", instruction="old recipe", seed=11, voice_id="test")
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", registry)
    worker, transport = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\0\0"),
            {"type": "completed", "request_id": "pending"},
        ],
    )
    original_lease = registry.lease_profile

    async def run() -> None:
        entered = asyncio.Event()

        @contextmanager
        def lease(voice):
            with original_lease(voice) as profile:
                entered.set()
                yield profile

        monkeypatch.setattr(registry, "lease_profile", lease)
        await worker._lock.acquire()

        async def collect():
            return [
                chunk async for chunk in worker.synthesize(SpeechRequest(text="test", voice="test"))
            ]

        task = asyncio.create_task(collect())
        try:
            await asyncio.wait_for(entered.wait(), timeout=1)
            registry.update_custom_profile("test", instruction="new recipe", seed=22)
        finally:
            worker._lock.release()
        assert await asyncio.wait_for(task, timeout=1)

    asyncio.run(run())
    recipe = transport.sends[0]["voice_profile"]
    assert recipe == {
        "id": "test",
        "mode": "instruction",
        "instruction": "old recipe",
        "seed": 11,
        "temperature": 0.1,
    }
    assert registry.get_profile("test").instruction == "new recipe"


def test_worker_does_not_reread_mutable_recipe_between_chunks(tmp_path: Path, monkeypatch) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json", tmp_path / "audio")
    registry.create_custom_profile(name="test", instruction="old recipe", seed=11, voice_id="test")
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", registry)
    calls: list[dict[str, Any]] = []
    seeds: list[int] = []
    mlx = ModuleType("mlx")
    core = ModuleType("mlx.core")
    core.random = SimpleNamespace(seed=seeds.append)
    mlx.core = core
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", core)

    class Model:
        def generate(self, **kwargs):
            calls.append(kwargs)
            if len(calls) == 1:
                registry.update_custom_profile("test", instruction="new recipe", seed=22)
            yield object()

    engine = object.__new__(worker_module.MlxQwenTtsEngine)
    engine.identity = worker_module.TtsWorkerIdentity(
        device="mps",
        dtype="float16",
        sample_rate=24_000,
        model_variant="voice_design",
    )
    engine._model = Model()
    engine._sample_rate = 24_000
    engine._chunk_ms = 100
    engine._temperature = 0.85
    engine._top_p = 0.95
    engine._repetition_penalty = 1.25
    engine._delivery_stats = Counter()
    monkeypatch.setattr(engine, "_to_pcm", lambda value: b"\0\0" * 10)
    chunks = list(
        engine.synthesize("One sentence. " * 50, voice="test", speed=1.0, language="auto")
    )
    assert len(chunks) == len(calls) > 1
    assert {call["instruct"] for call in calls} == {"old recipe"}
    assert {call["temperature"] for call in calls} == {0.1}
    assert seeds == [11] * len(calls)


@pytest.mark.parametrize(
    "change",
    [
        {"id": "other"},
        {"seed": True},
        {"seed": -1},
        {"temperature": float("nan")},
        {"temperature": True},
        {"temperature": -0.1},
        {"mode": "clone"},
        {"instruction": " "},
        {"instruction": "x" * 10_001},
        {"unexpected": "data"},
    ],
)
def test_private_recipe_decoder_rejects_malformed_or_mismatched_identity(change: dict) -> None:
    raw = {
        "id": "test",
        "mode": "instruction",
        "instruction": "test recipe",
        "seed": 1,
        "temperature": 0.1,
    }
    raw.update(change)
    with pytest.raises(ProtocolError, match="invalid voice profile snapshot"):
        worker_module._decode_profile_snapshot(raw, voice="test")


def test_private_snapshot_cannot_fall_back_to_registry(monkeypatch) -> None:
    profile = voices.VoiceProfile(id="test", mode="instruction", instruction="leased", seed=7)

    def forbidden(*args, **kwargs):
        raise AssertionError("second registry read")

    monkeypatch.setattr(worker_module, "get_voice_profile", forbidden)
    monkeypatch.setattr("speechrail.backends.qwen3_voice_binding.get_voice_profile", forbidden)
    assert worker_module.generation_condition("voice_design", "test", profile=profile) == {
        "voice": None,
        "instruct": "leased",
    }


def test_unnegotiated_old_worker_cannot_ignore_the_leased_recipe(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path)
    worker._supports_profile_snapshot = False

    async def collect():
        return [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="test", voice="default"))
        ]

    with pytest.raises(RuntimeError, match="worker_profile_snapshot_unsupported"):
        asyncio.run(collect())
    assert transport.sends == []
    assert transport.abort_count == 0


def test_private_host_decodes_recipe_before_engine_execution(tmp_path: Path) -> None:
    from io import BytesIO

    from speechrail.runtime.worker_protocol import read_frame, write_frame

    calls = []

    class Engine:
        identity = worker_module.TtsWorkerIdentity(
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )

        def synthesize(self, text, *, profile, **kwargs):
            calls.append((text, profile))
            yield b"\0\0"

    source, target = BytesIO(), BytesIO()
    write_frame(
        source,
        {
            "version": 1,
            "type": "start",
            "model_dir": str(tmp_path),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    raw = {
        "id": "test",
        "mode": "instruction",
        "instruction": "leased recipe",
        "seed": 9,
        "temperature": 0.2,
    }
    for number, recipe in enumerate([dict(raw, id="wrong"), raw]):
        write_frame(
            source,
            {
                "version": 1,
                "type": "synthesize",
                "request_id": f"r{number}",
                "text": "test",
                "voice": "test",
                "speed": 1.0,
                "language": "auto",
                "voice_profile": recipe,
            },
        )
    source.seek(0)
    worker_module.serve(
        source,
        target,
        model_dir=tmp_path,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: Engine(),
    )
    target.seek(0)
    assert read_frame(target)["profile_snapshot_version"] == 1
    error = read_frame(target)
    assert error["type"] == "error" and error["code"] == "worker_invalid_request"
    assert "leased recipe" not in str(error)
    assert read_frame(target)["type"] == "audio"
    assert read_frame(target)["type"] == "completed"
    assert read_frame(target) is None
    assert len(calls) == 1
    text, profile = calls[0]
    assert text == "test" and profile.seed == 9 and profile.temperature == 0.2
    assert profile.instruction == "leased recipe"


@pytest.mark.parametrize("version", [None, False, True, "1", 1.0, 2])
def test_snapshot_negotiation_is_strict_and_precedes_synthesis(tmp_path: Path, version) -> None:
    worker, transport = _worker(
        tmp_path,
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": worker_module.TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "profile_snapshot_version": version,
            }
        ],
    )
    worker._started = False

    async def collect():
        return [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="test", voice="default"))
        ]

    with pytest.raises(RuntimeError, match="worker_profile_snapshot_unsupported"):
        asyncio.run(asyncio.wait_for(collect(), timeout=1))
    assert [frame["type"] for frame in transport.sends] == ["start"]


def test_private_recipe_identifier_is_canonical_and_bounded() -> None:
    with pytest.raises(ProtocolError, match="invalid voice profile snapshot"):
        worker_module._decode_profile_snapshot(
            {
                "id": "../invalid",
                "mode": "instruction",
                "instruction": "test",
                "seed": 1,
                "temperature": 0.1,
            },
            voice="../invalid",
        )
