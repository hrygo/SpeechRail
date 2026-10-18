"""C0 uses pinned four-slot artifacts and the production threshold, without models."""

import asyncio
import json
from dataclasses import replace

import pytest

from speechrail.domain.diarization.types import DiarizationError


@pytest.fixture
def c0(tmp_path, monkeypatch):
    from meeting_c0 import static_c0_spec

    from speechrail.backends.diarization import coreml

    worker = tmp_path / "c0-worker"
    worker.write_bytes(b"fake worker: never execute")
    models = tmp_path / "c0-models"
    bundle = models / coreml.MODEL_BUNDLE_NAME
    bundle.mkdir(parents=True)
    (bundle / "coremldata.bin").write_bytes(b"fake pinned artifact")
    from meeting_evaluation_identity import file_digest

    monkeypatch.setattr(
        coreml, "MODEL_FILE_SHA256", {"coremldata.bin": file_digest(bundle / "coremldata.bin")}
    )
    monkeypatch.setattr(coreml, "MODEL_MIL_SIGNATURES", {})
    return worker, models, static_c0_spec(worker=worker, model_directory=models)


def test_c0_spec_is_four_slot_fixed_revision_and_diagnostic(c0):
    from probe_meeting_candidate import artifact_preflight

    worker, models, spec = c0
    assert spec.preset["num_speakers"] == 4
    assert spec.compute_units == "all"
    assert spec.decoder["threshold"] == 0.25 and spec.decoder["comparison"] == ">="
    assert spec.decoder["consolidation"] is False
    report = artifact_preflight(spec, worker=worker, model_directory=models)
    assert report["model_slots"] == 4
    assert not report["runtime_identity_verified"] and not report["model_shape_verified"]
    assert report["certified_max_speakers"] is None
    assert str(models) not in json.dumps(report)


@pytest.mark.parametrize(
    "field,value",
    [
        ("compute_units", "cpuOnly"),
        ("model_revision", "a" * 40),
        ("implementation_id", "unrecognized"),
    ],
)
def test_c0_frozen_identity_is_not_caller_selected(c0, field, value):
    from probe_meeting_candidate import artifact_preflight

    worker, models, spec = c0
    with pytest.raises(ValueError):
        artifact_preflight(replace(spec, **{field: value}), worker=worker, model_directory=models)


def test_c0_rejects_unpinned_model_before_execution(c0):
    from meeting_c0 import static_c0_spec

    worker, models, _ = c0
    (next(models.iterdir()) / "coremldata.bin").write_bytes(b"other model")
    with pytest.raises(ValueError):
        static_c0_spec(worker=worker, model_directory=models)


def test_c0_production_threshold_and_eof_clipping(c0):
    from meeting_c0 import C0ActivitySession

    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
    from speechrail.runtime.resource_governor import ResourceGovernor

    worker, models, _ = c0

    async def run():
        governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
        session = C0ActivitySession(
            worker=CoreMLWorkerProcess(worker, models), epoch="e", governor=governor
        )
        session._next_start = 1
        await session._publish(
            {
                "ok": True,
                "epoch": "e",
                "operation": "finish",
                "processed_through": 1,
                "stable_through": 1,
                "frames": [{"start": 0, "end": 1, "scores": [0.25, 0.249, 0, 1]}],
            },
            operation="finish",
        )
        update = await anext(session.updates())
        assert update.frames[0].active_slots == frozenset({0, 3})
        assert update.frames[0].span.end == 1

    asyncio.run(run())


@pytest.mark.parametrize("bad", ["gap", "bool", "slots", "unfinished"])
def test_c0_bad_probability_coverage_cannot_advance(c0, bad):
    from meeting_c0 import C0ActivitySession

    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

    worker, models, _ = c0

    async def run():
        session = C0ActivitySession(worker=CoreMLWorkerProcess(worker, models), epoch="e")
        session._next_start = 160
        response = {
            "ok": True,
            "epoch": "e",
            "operation": "finish",
            "processed_through": 160,
            "stable_through": 160,
            "frames": [{"start": 0, "end": 160, "scores": [0.25, 0, 0, 0]}],
        }
        if bad == "gap":
            response["frames"][0]["start"] = 1
        elif bad == "bool":
            response["frames"][0]["scores"][0] = True
        elif bad == "slots":
            response["frames"][0]["scores"] = [0] * 8
        else:
            response["processed_through"] = response["stable_through"] = 0
            response["frames"] = []
        with pytest.raises(DiarizationError, match="invalid C0 probability coverage"):
            await session._publish(response, operation="finish")
        assert session._processed == 0

    asyncio.run(run())


def test_c0_executes_through_shared_fixture_driver(c0, tmp_path, monkeypatch):
    from meeting_candidate_execution import EvaluationPortLease

    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
    from test_meeting_candidate_execution import execute

    original = EvaluationPortLease.__init__
    monkeypatch.setattr(
        EvaluationPortLease, "__init__", lambda self, port: original(self, port, directory=tmp_path)
    )
    peers = []

    async def start(self):
        peers.append(self)
        self.accepted = 0
        self.closes = 0
        await self.request({"operation": "preflight"})

    async def request(self, header, audio=b""):
        if header["operation"] == "preflight":
            return {"protocol_version": 1, "ok": True}, b""
        before = self.accepted
        self.accepted += len(audio) // 2
        return {
            "protocol_version": 1,
            "ok": True,
            "epoch": header["epoch"],
            "operation": header["operation"],
            "processed_through": self.accepted,
            "stable_through": self.accepted,
            "frames": (
                [{"start": before, "end": self.accepted, "scores": [0.25, 0, 0, 0]}]
                if before < self.accepted
                else []
            ),
        }, b""

    async def close(self):
        self.closes += 1

    monkeypatch.setattr(CoreMLWorkerProcess, "start", start)
    monkeypatch.setattr(CoreMLWorkerProcess, "request", request)
    monkeypatch.setattr(CoreMLWorkerProcess, "close", close)
    report = execute(tmp_path, c0)
    assert report["candidate_execution"]["native_preflight_observed"] is True
    assert report["candidate_execution"]["exact_child_reaped"] is True
    assert report["runtime_identity_verified"] is False
    assert report["certification_eligible"] is False
    assert len(peers) == 1 and peers[0].closes == 1
    assert peers[0].protocol_version == 1 and peers[0].backend == "sortformer"
    assert peers[0].model_path.name == "SortformerNvidiaLow_v2.1.mlmodelc"
    assert peers[0].inherited_guard_fd is not None
    assert report == json.loads((tmp_path / "result/result.json").read_text())
