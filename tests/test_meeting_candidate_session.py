"""The isolated candidate must share production ownership and compute discipline."""

import asyncio

import pytest
from meeting_candidate_protocol import SDK_REVISION
from meeting_candidate_session import open_candidate_session

from speechrail.domain.diarization.types import DiarizationError
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
    ResourceGovernor,
)


class Worker:
    def __init__(self, governor, *, bad_packet=False, failed_close=False):
        self.governor = governor
        self.bad_packet = bad_packet
        self.failed_close = failed_close
        self.accepted = self.emitted = self.finishes = self.closes = self.starts = 0
        self.reap = None
        self.closing = asyncio.Event()

    async def start(self):
        assert self.governor.diarization_owner.occupied
        assert self.governor.snapshot().active_diarization == 1
        self.starts += 1

    async def request(self, header, audio=b""):
        assert self.governor.snapshot().active_diarization == 1
        operation = header["operation"]
        if operation == "append":
            assert header["audio_start"] == self.accepted
            assert len(audio) == header["audio_samples"] * 2
            self.accepted += len(audio) // 2
            end = self.accepted // 160 * 160
        else:
            self.finishes += 1
            end = (self.accepted + 159) // 160 * 160
        frames = [
            {"start": i, "end": i + 160, "scores": [0.5, 0.5001] + [0.0] * 6}
            for i in range(self.emitted, end, 160)
        ]
        self.emitted = end
        return {
            "protocol_version": 3,
            "backend": "nemotron3_candidate",
            "sdk_revision": SDK_REVISION,
            "epoch": "wrong" if self.bad_packet else header["epoch"],
            "operation": operation,
            "ok": True,
            "processed_through": end,
            "stable_through": end,
            "frames": frames,
        }, b""

    async def close(self):
        self.closes += 1
        self.closing.set()
        if self.reap:
            await self.reap.wait()
        if self.failed_close:
            raise RuntimeError("exact child not reaped")


def governor():
    return ResourceGovernor(GovernorLimits(3, 1, 8), allow_heavy_overlap=False)


def test_irregular_chunks_tail_and_repeat_finish():
    async def run():
        gov = governor()
        worker = Worker(gov)
        session = open_candidate_session(epoch="one", governor=gov, worker_factory=lambda: worker)
        start = 0
        for count in (1, 159, 321, 1):
            await session.append(start_sample=start, pcm16=bytes(count * 2))
            start += count
        await session.finish(through_sample=start)
        await session.finish(through_sample=start)
        await session.cancel()
        updates = [u async for u in session.updates()]
        frames = [f for u in updates for f in u.frames]
        assert [(f.span.start, f.span.end) for f in frames] == [
            (0, 160),
            (160, 320),
            (320, 480),
            (480, 482),
        ]
        assert all(f.active_slots == frozenset({1}) for f in frames)
        assert updates[-1].stable_through == start
        assert worker.starts == worker.finishes == worker.closes == 1
        assert not gov.diarization_owner.occupied

    asyncio.run(run())


def test_owner_claim_precedes_factory_and_cancel_waits_for_reap():
    async def run():
        gov = governor()
        worker = Worker(gov)
        worker.reap = asyncio.Event()
        calls = []

        def factory():
            assert gov.diarization_owner.occupied
            calls.append(1)
            return worker

        session = open_candidate_session(epoch="one", governor=gov, worker_factory=factory)
        with pytest.raises(GovernorQueueFullError):
            open_candidate_session(epoch="two", governor=gov, worker_factory=factory)
        task = asyncio.create_task(session.cancel())
        await worker.closing.wait()
        assert not task.done() and gov.diarization_owner.occupied
        worker.reap.set()
        await task
        assert calls == [1] and not gov.diarization_owner.occupied

    asyncio.run(run())


@pytest.mark.parametrize("failure", ["packet", "reap", "factory", "slow"])
def test_failures_close_or_quarantine_exact_owner(failure):
    async def run():
        gov = governor()
        worker = Worker(gov, bad_packet=failure == "packet", failed_close=failure == "reap")

        def factory():
            if failure == "factory":
                raise RuntimeError("construction failed")
            return worker

        if failure == "factory":
            with pytest.raises(RuntimeError):
                open_candidate_session(epoch="one", governor=gov, worker_factory=factory)
        else:
            session = open_candidate_session(epoch="one", governor=gov, worker_factory=factory)
            if failure == "reap":
                with pytest.raises(RuntimeError):
                    await session.cancel()
                assert gov.diarization_owner.isolated
                with pytest.raises(GovernorLaneIsolatedError):
                    gov.diarization_owner.claim("next")
                return
            with pytest.raises(DiarizationError):
                for start in range(65):
                    await session.append(start_sample=start, pcm16=bytes(2))
            assert worker.closes == 1
        assert not gov.diarization_owner.occupied

    asyncio.run(run())


@pytest.mark.parametrize("start,pcm", [(True, b""), (0, b"x"), (0, bytes(32002))])
def test_invalid_input_fails_before_model_start(start, pcm):
    async def run():
        gov = governor()
        worker = Worker(gov)
        session = open_candidate_session(epoch="one", governor=gov, worker_factory=lambda: worker)
        with pytest.raises(DiarizationError):
            await session.append(start_sample=start, pcm16=pcm)
        assert worker.starts == 0 and worker.closes == 1
        assert not gov.diarization_owner.occupied

    asyncio.run(run())


def test_candidate_payload_decodes_without_relaxing_production_ipc_header_limit():
    import json

    from meeting_candidate_session import decode_candidate_frames

    frames = [
        {"start": i * 160, "end": (i + 1) * 160, "scores": [0.123456789] * 8} for i in range(1024)
    ]
    payload = json.dumps(frames).encode()
    assert len(payload) > 64 * 1024
    assert decode_candidate_frames({}, payload)["frames"] == frames
    for header, body in [
        ({"frames": []}, payload),
        ({}, b"{}"),
        ({}, b"NaN"),
        ({}, b"x" * (512 * 1024 + 1)),
    ]:
        with pytest.raises(ValueError):
            decode_candidate_frames(header, body)


@pytest.mark.parametrize("invalid", [None, "sdk", "shape", "preset", "units", "payload"])
def test_supervised_candidate_transport_validates_runtime_and_decodes_frames(tmp_path, invalid):
    import sys

    from meeting_candidate_session import CandidateWorkerProcess

    script = tmp_path / "worker"
    script.write_text(
        "#!"
        + sys.executable
        + "\n"
        + """
import json, struct, sys
mode = MODE
assert sys.argv[1] == '--model'
assert sys.argv[3:] == [
    '--protocol-version', '3', '--preset', 'fast32', '--compute-units', 'cpuOnly']
while True:
    prefix = sys.stdin.buffer.read(8)
    if not prefix:
        break
    h, a = struct.unpack('>II', prefix)
    header = json.loads(sys.stdin.buffer.read(h))
    sys.stdin.buffer.read(a)
    operation = header['operation']
    response = dict(protocol_version=3, backend='nemotron3_candidate',
        sdk_revision=REVISION, operation=operation, ok=True, preset='fast32',
        compute_units='cpuOnly', model_shape_verified=True)
    payload = b''
    if mode == 'sdk': response['sdk_revision'] = 'wrong'
    if mode == 'shape': response['model_shape_verified'] = False
    if mode == 'preset': response['preset'] = 'fast128'
    if mode == 'units': response['compute_units'] = 'all'
    if mode == 'payload': payload = b'[]'
    if operation != 'preflight':
        payload = b'[]'
    body = json.dumps(response).encode()
    sys.stdout.buffer.write(struct.pack('>II', len(body), len(payload)) + body + payload)
    sys.stdout.buffer.flush()
""".replace("MODE", repr(invalid)).replace("REVISION", repr(SDK_REVISION))
    )
    script.chmod(0o700)

    async def run():
        worker = CandidateWorkerProcess(
            executable=script, model_path=tmp_path, preset="fast32", compute_units="cpuOnly"
        )
        try:
            if invalid:
                with pytest.raises(RuntimeError):
                    await worker.start()
            else:
                await worker.start()
                response, payload = await worker.request({"operation": "append"})
                assert response["frames"] == [] and payload == b""
        finally:
            await worker.close()
        assert worker.process is None or worker.process.returncode is not None

    asyncio.run(run())


def test_cancel_during_real_child_preflight_reaps_before_owner_release(tmp_path):
    import sys

    from meeting_candidate_session import CandidateWorkerProcess

    script = tmp_path / "blocked-worker"
    script.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(60)\n")
    script.chmod(0o700)

    async def run():
        gov = governor()
        launched = asyncio.Event()

        class Transport(CandidateWorkerProcess):
            async def _launch(self, extra):
                await super()._launch(extra)
                launched.set()

        worker = Transport(
            executable=script, model_path=tmp_path, preset="fast32", compute_units="cpuOnly"
        )
        session = open_candidate_session(epoch="one", governor=gov, worker_factory=lambda: worker)
        append = asyncio.create_task(session.append(start_sample=0, pcm16=bytes(2)))
        try:
            async with asyncio.timeout(3):
                await launched.wait()
            child = worker.process
            cancel = asyncio.create_task(session.cancel())
            await asyncio.sleep(0)
            assert gov.diarization_owner.occupied
            await asyncio.wait_for(cancel, 5)
            assert child.returncode is not None
            assert not gov.diarization_owner.occupied
            assert gov.snapshot().active_diarization == 0
        finally:
            await session.cancel()
            await asyncio.gather(append, return_exceptions=True)

    asyncio.run(run())
