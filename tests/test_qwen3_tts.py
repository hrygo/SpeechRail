from __future__ import annotations

import asyncio
import base64
import contextlib
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from sys import executable
from typing import Any

import pytest

from speechrail.backends.qwen3_tts import (
    Qwen3TtsBackendConfig,
    Qwen3TtsCapabilityRouter,
    Qwen3TtsWorker,
)
from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID
from speechrail.domain.ports import SpeechRequest
from speechrail.domain.tts import VoiceStoreUnavailableError


class _FakeTransport:
    """Record sent frames and replay canned responses with live request IDs."""

    alive = True

    def __init__(self, responses: list[dict[str, Any]] | None = None) -> None:
        self.responses: list[dict[str, Any]] = []
        self.sends: list[dict[str, Any]] = []
        self.abort_count = 0
        self._available = asyncio.Event()
        for response in responses or []:
            self.push(response)

    def push(self, response: dict[str, Any]) -> None:
        self.responses.append(response)
        self._available.set()

    async def start(self) -> None:
        return None

    async def send(self, payload: dict[str, Any]) -> None:
        self.sends.append(dict(payload))

    async def receive(self) -> dict[str, Any]:
        while not self.responses:
            self._available.clear()
            await self._available.wait()
        response = self.responses.pop(0)
        if response.get("request_id") == "pending" and self.sends:
            response["request_id"] = self.sends[-1]["request_id"]
        return response

    async def abort(self) -> None:
        self.abort_count += 1
        self.alive = False

    async def close(self) -> None:
        self.abort_count += 1
        self.alive = False


def _worker(
    tmp_path: Path,
    responses: list[dict[str, Any]] | None = None,
    on_delivery_event: Callable[[str, int], None] | None = None,
) -> tuple[Qwen3TtsWorker, _FakeTransport]:
    snapshot = tmp_path.parent / "external-qwen3-tts"
    snapshot.mkdir(exist_ok=True)
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        ),
        on_delivery_event=on_delivery_event,
    )
    fake = _FakeTransport(responses)
    worker._transport = fake  # type: ignore[assignment]
    worker._started = True
    worker._supports_profile_snapshot = True
    return worker, fake


def _chunk_frame(request_id: str, index: int, pcm: bytes) -> dict[str, Any]:
    return {
        "type": "audio",
        "request_id": request_id,
        "chunk_index": index,
        "pcm_b64": base64.b64encode(pcm).decode(),
    }


def test_tts_worker_config_requires_external_snapshot_and_builds_private_command(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts"
    snapshot.mkdir(exist_ok=True)
    (snapshot / "config.json").write_text("{}")

    config = Qwen3TtsBackendConfig(
        repository_root=tmp_path,
        python_executable=Path(executable),
        model_dir=snapshot,
        model_variant="voice_design",
        device="mps",
        dtype="float16",
        sample_rate=24_000,
    )

    assert config.model_dir == snapshot.resolve()
    assert config.command() == [
        executable,
        "-m",
        "speechrail.backends.qwen3_tts_worker",
        "--model-dir",
        str(snapshot.resolve()),
        "--device",
        "mps",
        "--sample-rate",
        "24000",
        "--chunk-ms",
        "100",
        "--repetition-penalty",
        "1.25",
        "--temperature",
        "0.85",
        "--top-p",
        "0.95",
        "--cache-limit-mb",
        "256",
    ]


def test_tts_worker_config_rejects_snapshot_inside_repository(tmp_path: Path) -> None:
    snapshot = tmp_path / "model"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")

    with pytest.raises(ValueError, match="outside repository"):
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )


def test_tts_worker_normalizes_private_audio_frames_to_public_chunks(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [_chunk_frame("pending", 0, b"\x00\x00"), {"type": "completed", "request_id": "pending"}],
    )

    async def collect() -> list[Any]:
        return [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]

    chunks = asyncio.run(collect())

    request = fake.sends[0]
    response_id = str(request["request_id"])
    assert request["version"] == 1
    assert request["type"] == "synthesize"
    assert request["text"] == "你好"
    assert request["voice"] == "default"
    assert request["speed"] == 1.0
    assert request["language"] == "auto"
    assert chunks[0].response_id == response_id
    assert chunks[0].chunk_index == 0
    assert chunks[0].audio == b"\x00\x00"
    assert fake.abort_count == 0


def test_tts_worker_records_bounded_delivery_stats_from_completed_frame(tmp_path: Path) -> None:
    events: list[tuple[str, int]] = []
    worker, _fake = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\x00\x00"),
            {
                "type": "completed",
                "request_id": "pending",
                "delivery_stats": {
                    "planner_chunks": 2,
                    "reference_cache_hits": 1,
                    "reference_cache_misses": 1,
                    "reference_cache_evictions": 1,
                    "untrusted_extra": 9,
                },
            },
        ],
        on_delivery_event=lambda event, amount: events.append((event, amount)),
    )

    async def collect() -> None:
        request = SpeechRequest(text="你好", voice="default")
        _ = [chunk async for chunk in worker.synthesize(request)]

    asyncio.run(collect())

    assert events == [
        ("planner_chunk", 2),
        ("reference_cache_hit", 1),
        ("reference_cache_miss", 1),
        ("reference_cache_eviction", 1),
    ]


def _completed_frame_with_sampling(**overrides: Any) -> dict[str, Any]:
    observation: dict[str, Any] = {
        "schema_version": "tts_sampling_v1",
        "seed_policy": "caller_fixed",
        "seed": 101,
        "temperature": 0.7,
        "top_p": 0.95,
        "repetition_penalty": 1.05,
    }
    observation.update(overrides)
    return {
        "type": "completed",
        "request_id": "pending",
        "sampling_observation": observation,
    }


def test_tts_worker_hands_the_sampler_report_to_exactly_one_reader(tmp_path: Path) -> None:
    """The report belongs to one completed response and is consumed once.

    Two readers would otherwise race for the same fact: the receipt binder and
    anything added later. "Exactly once" is the contract, so it is asserted
    rather than inferred from the pop().
    """
    worker, fake = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\x00\x00"),
            _completed_frame_with_sampling(),
        ],
    )

    async def collect() -> list[Any]:
        return [
            chunk
            async for chunk in worker.synthesize(
                SpeechRequest(text="你好", voice="default")
            )
        ]

    chunks = asyncio.run(collect())
    response_id = str(fake.sends[0]["request_id"])

    assert chunks[0].audio == b"\x00\x00"
    observation = worker.take_sampling_observation(response_id)
    assert observation is not None
    assert observation.seed_policy == "caller_fixed"
    assert observation.seed == 101
    assert worker.take_sampling_observation(response_id) is None
    # Another response's report is not reachable through this one's id.
    assert worker.take_sampling_observation("rr_some_other_response") is None


@pytest.mark.parametrize(
    "override",
    [
        {"seed_policy": "best_effort_reproducible"},
        {"top_p": 1.5},
        {"seed": -1},
        {"temperature": -0.1},
        {"schema_version": "tts_sampling_v2"},
        {"untrusted_extra": 1},
    ],
)
def test_tts_worker_drops_a_sampler_report_it_cannot_validate(
    tmp_path: Path,
    override: dict[str, Any],
) -> None:
    """Vendor output is validated at the adapter boundary.

    An unreadable report is missing metadata, not a failed render: the audio
    still arrives, and the recipe stays partial instead of carrying a fact the
    worker never actually reported.
    """
    worker, fake = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\x00\x00"),
            _completed_frame_with_sampling(**override),
        ],
    )

    async def collect() -> list[Any]:
        return [
            chunk
            async for chunk in worker.synthesize(
                SpeechRequest(text="你好", voice="default")
            )
        ]

    chunks = asyncio.run(collect())

    assert chunks[0].audio == b"\x00\x00"
    assert worker.take_sampling_observation(str(fake.sends[0]["request_id"])) is None


def test_tts_worker_bounds_the_sampler_reports_it_keeps(tmp_path: Path) -> None:
    """Reports for responses nobody reads must not accumulate forever."""
    worker, _fake = _worker(tmp_path, [])

    for index in range(70):
        worker._store_sampling_observation(
            f"resp_{index}",
            _completed_frame_with_sampling(seed=index),
        )

    assert worker.take_sampling_observation("resp_0") is None
    assert worker.take_sampling_observation("resp_69") is not None


def test_tts_worker_packs_ephemeral_preview_parameters(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [_chunk_frame("pending", 0, b"\x00\x00"), {"type": "completed", "request_id": "pending"}],
    )
    worker.model_variant = "voice_design"

    async def collect() -> list[Any]:
        request = SpeechRequest(
            text="试听这一句。",
            voice="serena",
            instruction="温暖自然的中文女声。",
            seed=12345,
        )
        return [chunk async for chunk in worker.synthesize(request)]

    chunks = asyncio.run(collect())

    assert chunks
    request = fake.sends[0]
    assert request["instruction"] == "温暖自然的中文女声。"
    assert request["seed"] == 12345


def test_tts_worker_starts_offline_transport_and_checks_ready_identity(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-start"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "family": "qwen3_tts",
                "weight_fingerprint": "shape:" + ("a" * 64),
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def start_and_close() -> None:
        await worker.start()
        assert worker.ready is True
        assert worker.runtime_revision is not None
        assert worker.runtime_revision.startswith("rt_")
        assert fake.sends[0]["type"] == "start"
        assert fake.sends[0]["model_dir"].endswith("external-qwen3-tts-start")
        assert fake.sends[0]["device"] == "mps"
        assert fake.sends[0]["sample_rate"] == 24_000
        await worker.close()
        assert worker.ready is False
        assert worker.runtime_revision is None

    asyncio.run(start_and_close())


def test_router_eviction_keeps_first_load_distinct_from_reload(tmp_path: Path) -> None:
    events: list[tuple[str, int]] = []
    worker, fake = _worker(
        tmp_path, on_delivery_event=lambda event, amount: events.append((event, amount)),
    )
    worker._started = False
    fake.alive = False
    router = Qwen3TtsCapabilityRouter({"voice_design": worker})

    async def start_transport() -> None:
        fake.alive = True
        fake.push({
            "type": "ready", "model_loaded": True, "backend": TTS_BACKEND_ID,
            "device": "mps", "dtype": "float16", "sample_rate": 24_000,
            "model_variant": "voice_design", "profile_snapshot_version": 1,
        })

    fake.start = start_transport  # type: ignore[method-assign]

    async def run() -> None:
        # A group eviction still attempts cleanup on cold children.
        await router.evict_warm_capability()
        await router.evict_warm_capability()
        assert fake.abort_count == 2
        await worker.start()
        assert router.lifecycle_stats["reload_count_by_role"] == {"voice_design": 0}
        assert events == []
        await router.evict_warm_capability()
        await worker.start()
        assert router.lifecycle_stats["reload_count_by_role"] == {"voice_design": 1}
        assert events == [("reload", 1)]
        await router.close()

    asyncio.run(run())


def test_tts_worker_prepare_returns_the_observed_runtime_identity(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-prepare"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "family": "qwen3_tts",
                "weight_fingerprint": "shape:" + ("a" * 64),
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> str:
        revision = await worker.prepare()
        assert worker.ready is True
        assert revision == worker.runtime_revision
        assert revision.startswith("rt_")
        assert [frame["type"] for frame in fake.sends] == ["start"]
        return revision

    asyncio.run(scenario())


def test_tts_worker_rejects_a_runtime_change_after_strict_admission(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-runtime-pin"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "family": "qwen3_tts",
                "weight_fingerprint": "shape:" + ("a" * 64),
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> None:
        request = SpeechRequest(
            text="你好",
            voice="serena",
            expected_runtime_revision="rt_" + ("b" * 64),
        )
        with pytest.raises(RuntimeError) as exc_info:
            async for _chunk in worker.synthesize(request):
                pass
        assert exc_info.value.public_code == "voice_validation_runtime_changed"
        assert [frame["type"] for frame in fake.sends] == ["start"]

    asyncio.run(scenario())


def test_start_failure_keeps_worker_diagnostics_out_of_exception_text(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-load-error"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "error",
                "code": "worker_load_error",
                "stderr_tail": "mlx.core: [Metal] failed to allocate model weights",
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="worker_load_error") as exc_info:
            await worker.start()
        assert "failed to allocate" not in str(exc_info.value)
        assert exc_info.value.public_code == "tts_initialization_failed"

    asyncio.run(scenario())


def test_ready_identity_mismatch_aborts_the_tts_worker(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-mismatch"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "cpu",
                "dtype": "float32",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())

    assert fake.abort_count == 1


def test_ready_identity_rejects_model_variant_mismatch(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-variant-mismatch"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="base",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())

    assert fake.abort_count == 1


def test_ready_identity_rejects_dtype_mismatch_even_when_device_matches(
    tmp_path: Path,
) -> None:
    """A dtype mismatch must abort even when the worker reports the right device.

    The identity check must compare dtype exactly against the config expectation
    (mirroring the ASR backend); a loose membership check against the whole enum
    would let a float32-on-mps worker pass while claiming an int8 config.
    """
    snapshot = tmp_path.parent / "external-qwen3-tts-dtype-mismatch"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant="voice_design",
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float32",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "profile_snapshot_version": 1,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())

    assert fake.abort_count == 1


def test_each_synthesis_uses_an_independent_response_id(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\x00\x00"),
            {"type": "completed", "request_id": "pending"},
            _chunk_frame("pending", 0, b"\x01\x00"),
            {"type": "completed", "request_id": "pending"},
        ],
    )

    async def collect_twice() -> tuple[list[Any], list[Any]]:
        first = [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]
        second = [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]
        return first, second

    first, second = asyncio.run(collect_twice())

    assert fake.sends[0]["request_id"] != fake.sends[1]["request_id"]
    assert first[0].response_id == fake.sends[0]["request_id"]
    assert second[0].response_id == fake.sends[1]["request_id"]


def test_cross_request_id_frame_aborts_the_stream(tmp_path: Path) -> None:
    worker, fake = _worker(tmp_path)

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="你好", voice="default"))
        agen = stream.__aiter__()
        task = asyncio.ensure_future(agen.__anext__())
        await asyncio.sleep(0.05)
        fake.push(
            {"type": "audio", "request_id": "other-response", "chunk_index": 0, "pcm_b64": "AAA="}
        )
        with pytest.raises(RuntimeError, match="worker_response_id_mismatch"):
            await task
        assert fake.abort_count == 1

    asyncio.run(scenario())


def test_invalid_base64_or_odd_pcm_aborts_the_stream(tmp_path: Path) -> None:
    for response in (
        {"type": "audio", "request_id": "pending", "chunk_index": 0, "pcm_b64": "not!!base64"},
        _chunk_frame("pending", 0, b"\x00"),  # odd byte count
    ):
        worker, fake = _worker(tmp_path, [response])

        async def consume(target: Qwen3TtsWorker) -> list[Any]:
            return [
                chunk
                async for chunk in target.synthesize(SpeechRequest(text="你好", voice="default"))
            ]

        with pytest.raises(RuntimeError, match="worker_audio_frame_invalid"):
            asyncio.run(consume(worker))

        assert fake.abort_count == 1


def test_worker_surfaces_voice_store_error_code(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [{"type": "error", "request_id": "pending", "code": "voice_store_unavailable"}],
    )

    async def consume() -> list[Any]:
        return [
            chunk
            async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]

    with pytest.raises(VoiceStoreUnavailableError):
        asyncio.run(consume())
    assert fake.abort_count == 1


def test_gap_or_duplicate_chunk_index_aborts_the_stream(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path, [_chunk_frame("pending", 1, b"\x00\x00")]  # gap: first frame is index 1
    )

    async def consume() -> list[Any]:
        return [
            chunk
            async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]

    with pytest.raises(RuntimeError, match="worker_audio_frame_invalid"):
        asyncio.run(consume())

    assert fake.abort_count == 1


def test_tts_worker_aborts_private_generation_when_consumer_cancels(tmp_path: Path) -> None:
    worker, fake = _worker(tmp_path)
    started = asyncio.Event()
    release = asyncio.Event()
    original_receive = fake.receive

    async def blocked_receive() -> dict[str, Any]:
        started.set()
        await release.wait()
        return {"type": "completed", "request_id": fake.sends[0]["request_id"]}

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def consume() -> None:
        async for _chunk in worker.synthesize(SpeechRequest(text="取消", voice="default")):
            pass

    async def scenario() -> None:
        worker._epoch = 1  # Simulate one completed worker start before this request.
        task = asyncio.create_task(consume())
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert fake.abort_count == 1
        assert worker.lifecycle_stats == {
            "cooperative_cancel_supported": False,
            "fallback_abort_count": 1,
            "reload_count": 0,
        }

        # A subsequent request restarts the same supervised worker exactly
        # once. The diagnostic counter records the reload without exposing
        # private request or voice data.
        fake.alive = True
        fake.receive = original_receive  # type: ignore[method-assign]
        fake.push(
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
                "model_variant": "voice_design",
                "profile_snapshot_version": 1,
            }
        )
        fake.push(_chunk_frame("pending", 0, b"\x00\x00"))
        fake.push({"type": "completed", "request_id": "pending"})
        chunks = [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="恢复", voice="default"))
        ]
        assert len(chunks) == 1
        assert worker.lifecycle_stats["reload_count"] == 1

    asyncio.run(scenario())


def test_close_waits_for_lock_then_terminates_worker(tmp_path: Path) -> None:
    """close() acquires the lock, so it waits for any active stream to finish."""
    worker, fake = _worker(tmp_path)
    started = asyncio.Event()

    async def blocked_receive() -> dict[str, Any]:
        started.set()
        await asyncio.Event().wait()  # never released: stream holds the worker lock

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="关闭", voice="default"))
        task = asyncio.ensure_future(stream.__anext__())
        await started.wait()

        # close() will block because stream holds the lock — cancel stream first
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        # stream finally aborted the worker (same epoch), releasing the lock
        assert fake.abort_count == 1

        # Now close() can acquire the lock and abort again (but epoch has advanced
        # from the finally block, so it sees a fresh transport)
        fake.alive = True
        worker._started = True
        await asyncio.wait_for(worker.close(), timeout=1.0)
        assert fake.abort_count == 2

    asyncio.run(scenario())


def test_close_acquires_lock_and_waits_for_active_stream(tmp_path: Path) -> None:
    """close() must acquire the lock, so it blocks while a stream is active."""
    worker, fake = _worker(tmp_path)
    stream_entered = asyncio.Event()
    close_started = asyncio.Event()

    original_receive = fake.receive

    call_count = 0

    async def gated_receive() -> dict[str, Any]:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            stream_entered.set()
            # Wait until close has been attempted (it should block on the lock)
            await close_started.wait()
            await asyncio.sleep(0.05)
        return await original_receive()

    fake.receive = gated_receive  # type: ignore[method-assign]
    fake.push(_chunk_frame("pending", 0, b"\x00\x00"))
    fake.push({"type": "completed", "request_id": "pending"})

    async def scenario() -> None:
        # Start streaming
        stream_task = asyncio.create_task(
            _collect(worker.synthesize(SpeechRequest(text="关闭", voice="default")))
        )
        await stream_entered.wait()

        # Try to close — should block on the lock
        close_task = asyncio.create_task(worker.close())
        close_started.set()

        # Stream should complete first
        chunks = await stream_task
        assert len(chunks) == 1

        # Then close finishes
        await asyncio.wait_for(close_task, timeout=2.0)
        assert fake.abort_count == 1  # only close()'s abort, not stream's (epoch advanced)

    asyncio.run(scenario())


def test_epoch_guard_prevents_stale_finally_from_aborting_new_worker(tmp_path: Path) -> None:
    """When worker epoch has advanced, a stale stream finally must skip abort."""
    worker, fake = _worker(tmp_path)
    stream_entered = asyncio.Event()

    async def blocked_receive() -> dict[str, Any]:
        stream_entered.set()
        await asyncio.Event().wait()  # block forever

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="epoch", voice="default"))
        stream_task = asyncio.ensure_future(stream.__anext__())
        await stream_entered.wait()

        # Advance worker epoch (simulating recycling or epoch bump)
        worker._epoch += 10
        fake.abort_count = 0

        # Now cancel the stream — its finally block sees that self._epoch != captured_epoch
        stream_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await stream_task

        # Stale stream must NOT abort the worker because epoch has advanced
        assert fake.abort_count == 0

    asyncio.run(scenario())


async def _collect(source: AsyncIterator[Any]) -> list[Any]:
    return [item async for item in source]
