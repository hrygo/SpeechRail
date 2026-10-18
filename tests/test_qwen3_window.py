"""Window decoding reuses one worker and retains leases until real cleanup."""

import asyncio
from dataclasses import replace
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

from speechrail.backends.qwen3_window import NativeWindowAsrFactory
from speechrail.backends.qwen3_worker import Qwen3Engine, WorkerIdentity, serve
from speechrail.domain.asr_window import WindowDecodeRequest, WindowIdentity
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.asr_mode import AsrModeBusy, AsrModeGate
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


class FakeShared:
    def __init__(self):
        self.mode_gate = AsrModeGate()
        self.ready = False
        self.alive = False
        self.supports_window_decode = True
        self.generation = 0
        self.starts = 0
        self.reaps = 0
        self.owner = None
        self.frames = []
        self.wait = None
        self.entered = asyncio.Event()
        self.bad_attempt = False
        self.fail_request = False
        self.fail_reap = False
        self.observation = None
        self.timeout_seconds = 1.0

    def reserve_window_owner(self):
        if self.owner is not None or self.mode_gate.active_count:
            raise AsrModeBusy("backend_busy")
        self.owner = object()
        return self.owner

    def release_window_owner(self, owner):
        assert owner is self.owner
        self.owner = None

    async def start(self):
        if not self.ready:
            self.starts += 1
            self.generation += 1
            self.ready = True
            self.alive = True

    async def request(self, frame, binary=None):
        await self.start()
        self.frames.append((frame, binary))
        self.entered.set()
        if self.wait is not None:
            await self.wait.wait()
        if self.fail_request:
            self.ready = False
            raise RuntimeError("reap_unconfirmed")
        response = {k: v for k, v in frame.items() if k not in {"language", "context", "kind"}}
        response["type"] = "window.closed" if frame["type"] == "window.close" else "window.result"
        if response["type"] == "window.result":
            response.update(text="合成复核", language="zh", complete=frame["kind"] == "review")
            if self.observation is not None:
                response["observation"] = self.observation
            if self.bad_attempt:
                response["attempt_id"] = "wrong-attempt"
        return response

    async def close(self):
        self.reaps += 1
        if self.fail_reap:
            raise RuntimeError("reap_unconfirmed")
        self.alive = False
        self.ready = False


def make_request(identity=None, kind="review", end=100, start=0):
    return WindowDecodeRequest(
        identity or WindowIdentity("s", 0, "w"),
        "attempt",
        kind,
        SampleSpan(start, end),
        bytes((end - start) * 2),
        "zh",
        "",
    )


def setup():
    worker = FakeShared()
    governor = ResourceGovernor(GovernorLimits(2, 1, 4), allow_heavy_overlap=False)
    return worker, governor, NativeWindowAsrFactory(worker, governor)


def test_one_hundred_windows_reuse_loaded_model_and_normal_close_is_ack_only():
    async def run():
        worker, governor, factory = setup()
        for n in range(100):
            identity = WindowIdentity("s", n, "w")
            session = factory.create(identity=identity)
            result = await session.decode(make_request(identity))
            assert result.text == "合成复核" and result.complete
            await session.close()
            assert governor.snapshot().active_asr == 0
        assert worker.starts == 1
        assert worker.reaps == 0
        assert sum(f[0]["type"] == "window.close" for f in worker.frames) == 100
        assert worker.mode_gate.active_count == 0

    asyncio.run(run())


def test_second_owner_and_batch_conflict_are_rejected():
    async def run():
        worker, _, factory = setup()
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        with pytest.raises(AsrModeBusy):
            factory.create(identity=WindowIdentity("s2", 0, "w"))
        with pytest.raises(AsrModeBusy):
            worker.mode_gate.acquire("batch")
        await session.close()
        lease = worker.mode_gate.acquire("batch")
        with pytest.raises(AsrModeBusy):
            factory.create(identity=WindowIdentity("s2", 0, "w"))
        worker.mode_gate.release(lease)

    asyncio.run(run())


def test_cancelled_decode_waiter_retains_actual_compute_and_governor_lease():
    async def run():
        worker, governor, factory = setup()
        worker.wait = asyncio.Event()
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        task = asyncio.create_task(session.decode(make_request()))
        await worker.entered.wait()
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done() and governor.snapshot().active_asr == 1
        worker.wait.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        await session.close()
        assert governor.snapshot().active_asr == 0

    asyncio.run(run())


def test_close_waiter_cancellation_does_not_abandon_cleanup():
    async def run():
        worker, _, factory = setup()
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        await session.decode(make_request())
        worker.entered.clear()
        worker.wait = asyncio.Event()
        close = asyncio.create_task(session.close())
        await worker.entered.wait()
        close.cancel()
        await asyncio.sleep(0)
        assert not close.done() and worker.mode_gate.active_count == 1
        worker.wait.set()
        with pytest.raises(asyncio.CancelledError):
            await close
        assert worker.mode_gate.active_count == 0 and worker.owner is None

    asyncio.run(run())


def test_failed_reap_keeps_resource_quarantined_until_retry_confirms_cleanup():
    async def run():
        worker, governor, factory = setup()
        worker.fail_request = True
        worker.fail_reap = True
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        with pytest.raises(RuntimeError):
            await session.decode(make_request())
        assert governor.snapshot().active_asr == 1
        with pytest.raises(RuntimeError):
            await session.close()
        assert worker.mode_gate.active_count == 1 and governor.snapshot().active_asr == 1
        worker.fail_reap = False
        await session.close()
        assert worker.mode_gate.active_count == 0 and governor.snapshot().active_asr == 0

    asyncio.run(run())


def test_unadvertised_worker_and_wrong_attempt_cannot_supply_results():
    async def run():
        worker, _, factory = setup()
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        worker.supports_window_decode = False
        with pytest.raises(RuntimeError):
            await session.decode(make_request())
        assert not worker.frames
        await session.close()
        worker.supports_window_decode = True
        worker.bad_attempt = True
        session = factory.create(identity=WindowIdentity("s", 1, "w"))
        with pytest.raises(RuntimeError):
            await session.decode(make_request(session.identity))
        assert worker.reaps >= 1
        await session.close()

    asyncio.run(run())


def test_old_epoch_is_rejected_before_worker_io():
    async def run():
        worker, _, factory = setup()
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        with pytest.raises(ValueError):
            await session.decode(make_request(WindowIdentity("s", 1, "w")))
        assert not worker.frames
        await session.close()

    asyncio.run(run())


def engine():
    instance = object.__new__(Qwen3Engine)
    instance._streaming_states = {}
    instance._window_identity = None
    instance._window_preview = None
    instance._max_new_tokens = 512
    calls = []

    def decode(audio, state, **kwargs):
        calls.append((state, len(audio), kwargs))
        return SimpleNamespace(text="合成预览", language="zh")

    reviews = []

    def transcribe(audio, **kwargs):
        reviews.append((audio, kwargs))
        return SimpleNamespace(text="合成复核", language="zh", finish_reason="eos", truncated=False)

    instance._decoder = SimpleNamespace(decode=decode)
    instance._session = SimpleNamespace(transcribe=transcribe)
    return instance, calls, reviews


def test_engine_prefix_reuse_is_bound_to_origin_and_review_resets_it():
    e, calls, reviews = engine()
    e.decode_window(make_request(kind="preview"))
    e.decode_window(make_request(kind="preview", end=200))
    assert calls[0][0] is calls[1][0]
    assert e.decode_window(make_request(kind="review", end=200)).complete
    assert len(reviews) == 1 and "prefix" not in reviews[0][1]
    e.decode_window(make_request(kind="preview", end=200))
    assert calls[-1][0] is not calls[0][0]
    e.decode_window(make_request(kind="preview", start=50, end=250))
    assert calls[-1][0] is not calls[-2][0]
    e.close_window(WindowIdentity("s", 0, "w"))
    assert e._window_preview is None


def test_engine_changed_pcm_or_language_cannot_reuse_old_prefix():
    e, calls, _ = engine()
    e.decode_window(make_request(kind="preview"))
    e.decode_window(replace(make_request(kind="preview", end=200), pcm16=b"\x01\x00" * 200))
    assert calls[0][0] is not calls[1][0]
    e.decode_window(replace(make_request(kind="preview", end=200), language="en"))
    assert calls[1][0] is not calls[2][0]


def serve_window_frames(changes=None):
    instance, _, _ = engine()
    instance.identity = WorkerIdentity(
        device="mps",
        dtype="float16",
        compute_dtype="float16",
        compute_config="mps",
        quantization_format="none",
        family="qwen3_asr",
        model_variant="asr",
        weight_fingerprint="shape:" + "a" * 64,
    )
    source, target = BytesIO(), BytesIO()
    write_frame(
        source,
        {"version": 1, "type": "start", "model_dir": "/tmp", "device": "mps", "dtype": "float16"},
    )
    frame = {
        "version": PROTOCOL_VERSION,
        "type": "window.decode",
        "request_id": "rpc-1",
        "session_id": "s",
        "input_epoch": 0,
        "window_id": "w",
        "attempt_id": "attempt",
        "kind": "review",
        "start_sample": 0,
        "end_sample": 100,
        "sample_rate": 16000,
        "channels": 1,
        "sample_width_bytes": 2,
        "language": "zh",
        "context": "",
    }
    frame.update(changes or {})
    write_frame(source, frame, binary_payload=bytes(200))
    write_frame(
        source,
        {
            "version": 1,
            "type": "window.close",
            "request_id": "rpc-close",
            "session_id": "s",
            "input_epoch": 0,
            "window_id": "w",
        },
    )
    source.seek(0)
    serve(source, target, model_dir=Path("/tmp"), device="mps", engine_factory=lambda *_: instance)
    target.seek(0)
    frames = []
    while (frame := read_frame(target)) is not None:
        frames.append(frame)
    return frames


def test_window_binary_ipc_reports_capability_result_then_real_close_ack():
    frames = serve_window_frames()
    assert frames[0]["capabilities"] == ["window_decode_v1"]
    assert [f["type"] for f in frames] == ["ready", "window.result", "window.closed"]
    assert frames[1]["request_id"] == "rpc-1" and frames[1]["complete"] is True
    assert frames[2]["request_id"] == "rpc-close"


@pytest.mark.parametrize(
    "changes",
    [
        {"version": True},
        {"unexpected": True},
        {"sample_rate": True},
        {"input_epoch": True},
        {"start_sample": True},
        {"end_sample": 101},
        {"kind": "final"},
        {"language": "unsupported"},
        {"context": "x" * 513},
    ],
)
def test_window_binary_ipc_rejects_invalid_private_frames(changes):
    frames = serve_window_frames(changes)
    assert frames[1]["type"] == "error"
    assert frames[1]["request_id"] == "rpc-1"


def test_engine_window_observes_actual_dynamic_budget_without_inventing_missing_vendor_fields():
    e, calls, reviews = engine()
    preview = e.decode_window(make_request(kind="preview", end=16000 * 10))
    assert preview.observation.kind == "preview"
    assert preview.observation.decode_max_new_tokens == calls[-1][2]["max_new_tokens"] == 84
    assert preview.observation.generation_max_new_tokens is None
    assert preview.observation.finish_reason is None
    assert preview.observation.truncated is None
    assert preview.observation.generated_token_count is None
    review = e.decode_window(make_request(kind="review", end=16000 * 10))
    assert review.observation.kind == "review"
    assert review.observation.decode_max_new_tokens == reviews[-1][1]["max_new_tokens"] == 84
    assert review.observation.generation_max_new_tokens is None
    assert review.observation.finish_reason == "eos"
    assert review.observation.truncated is False
    assert review.observation.generated_token_count is None


def test_engine_window_preserves_preview_generation_observations_and_missing_review_truncation():
    e, _, _ = engine()
    e._decoder = SimpleNamespace(decode=lambda *a, **k: SimpleNamespace(
        text="合成预览", language="zh", finish_reason="length", truncated=True,
        generation_max_new_tokens=7, generated_token_count=7, raw_tokens=(1,) * 20,
    ))
    result = e.decode_window(make_request(kind="preview"))
    assert result.observation.generation_max_new_tokens == 7
    assert result.observation.generated_token_count == 7
    assert result.observation.finish_reason == "length"
    assert result.observation.truncated is True
    assert result.complete is False
    e._session = SimpleNamespace(transcribe=lambda *a, **k: SimpleNamespace(
        text="合成复核", language="zh", finish_reason="eos",
    ))
    review = e.decode_window(make_request())
    assert review.observation.truncated is None


def test_window_ipc_and_session_preserve_decode_observation():
    frames = serve_window_frames()
    observation = frames[1]["observation"]
    assert observation == {
        "kind": "review", "decode_max_new_tokens": 32, "generation_max_new_tokens": None,
        "finish_reason": "eos", "truncated": False, "generated_token_count": None,
    }

    async def run():
        worker, _, factory = setup()
        worker.observation = observation
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        result = await session.decode(make_request())
        assert result.observation.decode_max_new_tokens == 32
        assert result.observation.finish_reason == "eos"
        assert result.observation.truncated is False
        assert result.observation.generated_token_count is None
        await session.close()
        worker.observation = None
        session = factory.create(identity=WindowIdentity("s", 1, "w"))
        assert (await session.decode(make_request(session.identity))).observation is None
        await session.close()

    asyncio.run(run())


@pytest.mark.parametrize("observation", [
    [], {"kind": "review"}, {"kind": "review", "decode_max_new_tokens": True},
    {"kind": "review", "decode_max_new_tokens": 32, "unexpected": True},
    {"kind": "review", "decode_max_new_tokens": 32, "truncated": 0},
    {"kind": "preview", "decode_max_new_tokens": 32},
])
def test_window_session_rejects_malformed_or_wrong_kind_observation(observation):
    async def run():
        worker, _, factory = setup()
        worker.observation = observation
        session = factory.create(identity=WindowIdentity("s", 0, "w"))
        with pytest.raises(RuntimeError, match="window_result_invalid"):
            await session.decode(make_request())
        assert worker.reaps == 1
        await session.close()

    asyncio.run(run())
