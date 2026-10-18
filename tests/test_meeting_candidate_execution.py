"""Offline evaluation exclusion uses the same kernel guard as the service."""

import asyncio
import json
import subprocess
import sys

import pytest
from meeting_candidate_execution import EvaluationPortLease, read_control_json

from speechrail.runtime.server_lock import ServerInstanceError, ServerInstanceLock


@pytest.fixture(autouse=True)
def isolated_port_guards(tmp_path, monkeypatch):
    original = EvaluationPortLease.__init__

    def init(self, port, *, directory=None):
        original(self, port, directory=directory or tmp_path)

    monkeypatch.setattr(EvaluationPortLease, "__init__", init)


@pytest.fixture
def candidate(tmp_path):
    from test_probe_meeting_candidate import artifacts

    return artifacts.__wrapped__(tmp_path)


def fake_native(monkeypatch, *, mutate=None, bad_sdk=False):
    from meeting_candidate_protocol import SDK_REVISION

    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

    peers = []

    async def start(self):
        peers.append(self)
        self.test_accepted = self.test_emitted = self.test_closes = 0
        await self.request({"operation": "preflight"})

    async def request(self, header, audio=b""):
        operation = header["operation"]
        response = {
            "protocol_version": 3,
            "operation": operation,
            "backend": "nemotron3_candidate",
            "sdk_revision": "bad" if bad_sdk else SDK_REVISION,
            "ok": True,
            "preset": self.preset,
            "compute_units": self.compute_units,
        }
        if operation == "preflight":
            return {**response, "model_shape_verified": True}, b""
        if mutate is not None:
            mutate()
        self.test_accepted += len(audio) // 2
        end = self.test_accepted // 160 * 160
        frames = [
            {"start": n, "end": n + 160, "scores": [0.9] + [0.0] * 7}
            for n in range(self.test_emitted, end, 160)
        ]
        self.test_emitted = end
        return {
            **response,
            "epoch": header["epoch"],
            "processed_through": end,
            "stable_through": end,
        }, json.dumps(frames).encode()

    async def close(self):
        self.test_closes += 1

    monkeypatch.setattr(CoreMLWorkerProcess, "start", start)
    monkeypatch.setattr(CoreMLWorkerProcess, "request", request)
    monkeypatch.setattr(CoreMLWorkerProcess, "close", close)
    return peers


def execute(tmp_path, candidate, **overrides):
    from meeting_candidate_execution import evaluate_candidate_development

    from test_meeting_development_fixture import inputs
    from test_meeting_quality_metrics import policy

    worker, model, spec = candidate
    manifest, split_lock = inputs(tmp_path)
    values = {
        "spec": spec,
        "worker": worker,
        "model_directory": model,
        "manifest": manifest,
        "split_lock": split_lock,
        "scorer_policy": policy(),
        "artifact_root": tmp_path,
        "output_directory": tmp_path / "result",
        "fixture_id": "M0",
        "service_port": 9912,
    }
    values.update(overrides)
    return asyncio.run(asyncio.wait_for(evaluate_candidate_development(**values), 3))


def test_service_and_evaluation_cannot_share_the_configured_port(tmp_path):
    with (
        ServerInstanceLock(9911, directory=tmp_path),
        pytest.raises(RuntimeError, match="evaluation_port_busy"),
        EvaluationPortLease(9911, directory=tmp_path),
    ):
        pytest.fail("evaluation acquired service lock")
    with EvaluationPortLease(9911, directory=tmp_path) as lease:
        assert lease.descriptor >= 0
        with pytest.raises(ServerInstanceError), ServerInstanceLock(9911, directory=tmp_path):
            pytest.fail("service acquired evaluation lock")
    with pytest.raises(RuntimeError, match="not_active"):
        _ = lease.descriptor
    with ServerInstanceLock(9911, directory=tmp_path):
        pass


def test_inherited_child_guard_survives_parent_lease_release(tmp_path):
    child = None
    try:
        with EvaluationPortLease(9911, directory=tmp_path) as lease:
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import sys; sys.stdout.write('r'); sys.stdout.flush(); sys.stdin.read(1)",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                pass_fds=(lease.descriptor,),
            )
            assert child.stdout.read(1) == b"r"
        with pytest.raises(ServerInstanceError), ServerInstanceLock(9911, directory=tmp_path):
            pytest.fail("orphaned exact child lost its inherited guard")
        child.communicate(b"x", timeout=3)
        with ServerInstanceLock(9911, directory=tmp_path):
            pass
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.communicate(timeout=3)


@pytest.mark.parametrize("contents", ['{"x":1,"x":2}', "[]", "NaN"])
def test_control_json_is_strict_and_bounded(tmp_path, contents):
    path = tmp_path / "control.json"
    path.write_text(contents)
    with pytest.raises(ValueError):
        read_control_json(path)


def test_control_symlink_is_not_followed(tmp_path):
    path = tmp_path / "control.json"
    path.symlink_to(tmp_path / "missing")
    with pytest.raises((OSError, ValueError)):
        read_control_json(path)


def test_native_driver_connects_locked_fixture_trace_and_saved_observation(
    tmp_path, candidate, monkeypatch
):
    peers = fake_native(monkeypatch)
    result = execute(tmp_path, candidate)
    assert result["execution"]["phase_trace_observed"]
    assert result["candidate_execution"]["native_preflight_observed"]
    assert result["candidate_execution"]["exact_child_reaped"]
    assert not result["runtime_identity_verified"] and not result["certification_eligible"]
    assert result == json.loads((tmp_path / "result/result.json").read_text())
    assert len(peers) == 1 and peers[0].test_closes == 1
    assert peers[0].inherited_guard_fd is not None
    assert str(tmp_path) not in json.dumps(result)


@pytest.mark.parametrize("binding", ["same", "different", "changed", "during"])
def test_native_shared_pcm_uses_original_owner_and_checks_reaping(
    candidate, monkeypatch, binding
):
    from meeting_candidate_execution import CandidateArtifacts, NativeCandidateRun
    from meeting_pcm_feed import PcmChunk

    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor

    worker, model, spec = candidate
    artifacts = CandidateArtifacts(spec, worker, model)
    shared = ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False)
    other = ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False)
    owners = []

    def mutate():
        if binding == "during":
            owners[0].governor = other

    peers = fake_native(monkeypatch, mutate=mutate)

    async def run():
        output, reads = [], []
        original = bytes(320)

        async def frames():
            reads.append(True)
            yield PcmChunk(0, 0, 160, .01, .01, original)

        async def sink(event):
            output.append(event)

        with EvaluationPortLease(9912) as port:
            native = NativeCandidateRun(artifacts, port, shared)
            owners.append(native)
            if binding == "changed":
                native.governor = other
            call = native.evaluate_shared_pcm(
                original, frames(), governor=other if binding == "different" else shared,
                sink=sink,
            )
            if binding in {"different", "changed"}:
                with pytest.raises(ValueError, match="governor"):
                    await call
                assert not reads and not peers
                return
            if binding == "during":
                with pytest.raises(ValueError, match="governor"):
                    await call
                assert not shared.diarization_owner.occupied
                assert len(peers) == 1 and peers[0].test_closes == 1
                return
            result = await call
            assert result["processed_samples"] == 160
            assert result["candidate_execution"]["exact_child_reaped"] is True
            assert result["asr_text_source"] == "not_observed"
            assert result["runtime_identity_verified"] is False
            assert result["certification_eligible"] is False
            assert not shared.diarization_owner.occupied
            assert len(peers) == 1 and peers[0].test_closes == 1
            assert peers[0].inherited_guard_fd == port.descriptor
            assert any(e["kind"] == "stable_activity_frame" for e in output)

    asyncio.run(asyncio.wait_for(run(), 3))


@pytest.mark.parametrize("restore", [False, True])
def test_artifact_change_during_model_execution_rejects_completed_result(
    tmp_path, candidate, monkeypatch, restore
):
    worker, _, _ = candidate
    original = worker.read_bytes()

    def change():
        worker.write_bytes(b"changed")
        if restore:
            worker.write_bytes(original)

    peers = fake_native(monkeypatch, mutate=change)
    with pytest.raises(RuntimeError):
        execute(tmp_path, candidate)
    assert peers[0].test_closes == 1
    assert not (tmp_path / "result/result.json").exists()


def test_invalid_native_handshake_reaps_child_without_producing_result(
    tmp_path, candidate, monkeypatch
):
    peers = fake_native(monkeypatch, bad_sdk=True)
    with pytest.raises(RuntimeError):
        execute(tmp_path, candidate)
    assert len(peers) == 1 and peers[0].test_closes == 1
    assert not (tmp_path / "result/result.json").exists()


def test_artifact_change_after_scoring_cannot_commit_completion(tmp_path, candidate, monkeypatch):
    import meeting_development_fixture as fixture

    worker, _, _ = candidate
    original = fixture.score_meeting_quality
    peers = fake_native(monkeypatch)

    def score(*args, **kwargs):
        result = original(*args, **kwargs)
        worker.write_bytes(b"changed after model cleanup")
        return result

    monkeypatch.setattr(fixture, "score_meeting_quality", score)
    with pytest.raises(RuntimeError):
        execute(tmp_path, candidate)
    assert peers[0].test_closes == 1
    assert not (tmp_path / "result/result.json").exists()


def test_holdout_role_rejected_before_worker_construction(tmp_path, candidate, monkeypatch):
    from meeting_evaluation_identity import canonical_digest

    from test_meeting_development_fixture import inputs

    manifest, lock = inputs(tmp_path)
    manifest["split"] = "holdout"
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    peers = fake_native(monkeypatch)
    with pytest.raises(ValueError, match="development"):
        execute(tmp_path, candidate, manifest=manifest, split_lock=lock)
    assert peers == []


def test_candidate_observation_cannot_smuggle_text_into_summary(tmp_path):
    from test_meeting_development_fixture import execute as fixture_execute
    from test_meeting_development_fixture import inputs

    manifest, lock = inputs(tmp_path)

    async def invalid_observation():
        return {"text": "private summary content"}

    with pytest.raises(RuntimeError):
        fixture_execute(tmp_path, manifest, lock, verify_candidate=invalid_observation)
    assert not (tmp_path / "result/result.json").exists()


def test_busy_configured_service_prevents_any_worker_start(tmp_path, candidate, monkeypatch):
    peers = fake_native(monkeypatch)
    with (
        ServerInstanceLock(9912, directory=tmp_path),
        pytest.raises(RuntimeError, match="evaluation_port_busy"),
    ):
        execute(tmp_path, candidate)
    assert peers == []


def test_cli_development_dispatch_is_explicit_and_holdout_stays_unavailable(
    tmp_path, candidate, monkeypatch, capsys
):
    import meeting_candidate_execution as execution
    from probe_meeting_candidate import main

    worker, model, spec = candidate
    paths = {}
    for key, value in (
        ("candidate-spec", spec.as_dict()),
        ("manifest", {}),
        ("split-lock", {}),
        ("scorer-policy", {}),
    ):
        path = tmp_path / f"{key}.json"
        path.write_text(json.dumps(value))
        paths[key] = path
    calls = []

    async def evaluate(**kwargs):
        calls.append(kwargs)
        return {"verdict": "diagnostic", "certification_eligible": False}

    monkeypatch.setattr(execution, "evaluate_candidate_development", evaluate)
    args = [
        "evaluate-development",
        "--worker",
        str(worker),
        "--model-directory",
        str(model),
        "--fixture-id",
        "M0",
        "--service-port",
        "9912",
        "--artifact-root",
        str(tmp_path),
        "--output-directory",
        str(tmp_path / "result"),
    ]
    for key, path in paths.items():
        args.extend((f"--{key}", str(path)))
    assert main(args) == 0
    assert json.loads(capsys.readouterr().out)["verdict"] == "diagnostic"
    assert calls[0]["fixture_id"] == "M0" and calls[0]["service_port"] == 9912
    with pytest.raises(SystemExit):
        main(["evaluate-frozen-holdout"])
