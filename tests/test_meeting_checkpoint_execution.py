"""Native checkpoint composition tests use synthetic WAV and fake IPC only."""

import asyncio
import json

import pytest
from meeting_checkpoint_execution import evaluate_native_checkpoint
from meeting_evaluation_identity import candidate_digest, canonical_digest

from test_meeting_c0 import c0 as c0_fixture
from test_meeting_candidate_execution import isolated_port_guards  # noqa: F401

native_c0 = c0_fixture  # re-export the synthetic pinned-artifact fixture


def controls(tmp_path, c0_artifacts):
    from probe_meeting_candidate import static_candidate_spec

    from test_meeting_development_fixture import checkpoint_inputs
    from test_meeting_quality_metrics import policy

    manifest, split = checkpoint_inputs(tmp_path)
    entries = {}
    for name, preset in (("C1", "fast32"), ("C2", "fast128")):
        worker = tmp_path / f"{name}-worker"
        worker.write_bytes(b"fake worker")
        models = tmp_path / name
        bundle = models / f"Nemotron3Diarizer_{preset}.mlmodelc"
        bundle.mkdir(parents=True)
        (bundle / "coremldata.bin").write_bytes(b"fake model")
        (models / "learnable_sil_emb.bin").write_bytes(bytes(2048))
        spec = static_candidate_spec(
            worker=worker,
            model_directory=models,
            preset=preset,
            model_revision="a" * 40,
            compute_units="all",
        )
        entries[name] = (worker, models, spec)
    entries["C0"] = c0_artifacts

    def document(name, value):
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(value))
        return {"path": str(path), "sha256": canonical_digest(value)}

    lock = {
        "schema_version": 1,
        "speakers_count": 1,
        "service_port": 9912,
        "manifest": document("manifest", manifest),
        "split_lock": document("split", split),
        "scorer_policy": document("policy", policy()),
        "artifact_root": str(tmp_path),
        "candidates": {
            name: {
                "spec": document(name + "-spec", spec.as_dict()),
                "worker": str(worker),
                "model_directory": str(models),
            }
            for name, (worker, models, spec) in entries.items()
        },
    }
    path = tmp_path / "checkpoint-lock.json"
    path.write_text(json.dumps(lock))
    return path, lock, entries


def fake_workers(monkeypatch, *, mutate=None, bad_c0=False):
    from meeting_candidate_protocol import SDK_REVISION

    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

    peers = []

    async def start(self):
        assert all(peer.closes == 1 for peer in peers)
        peers.append(self)
        self.accepted = self.emitted = self.closes = 0
        await self.request({"operation": "preflight"})

    async def request(self, header, audio=b""):
        c0_worker = self.protocol_version == 1
        if c0_worker:
            if header["operation"] == "preflight":
                return {"protocol_version": 9 if bad_c0 else 1, "ok": True}, b""
            before = self.accepted
            self.accepted += len(audio) // 2
            return {
                "protocol_version": 1,
                "ok": True,
                "epoch": header["epoch"],
                "operation": header["operation"],
                "processed_through": self.accepted,
                "stable_through": self.accepted,
                "frames": [{"start": before, "end": self.accepted, "scores": [0.25, 0, 0, 0]}]
                if before < self.accepted
                else [],
            }, b""
        response = {
            "protocol_version": 3,
            "operation": header["operation"],
            "backend": "nemotron3_candidate",
            "sdk_revision": SDK_REVISION,
            "ok": True,
            "preset": self.preset,
            "compute_units": self.compute_units,
        }
        if header["operation"] == "preflight":
            return {**response, "model_shape_verified": True}, b""
        if mutate:
            mutate()
        self.accepted += len(audio) // 2
        end = self.accepted // 160 * 160
        frames = [
            {"start": n, "end": n + 160, "scores": [0.9] + [0.0] * 7}
            for n in range(self.emitted, end, 160)
        ]
        self.emitted = end
        return {
            **response,
            "epoch": header["epoch"],
            "processed_through": end,
            "stable_through": end,
        }, json.dumps(frames).encode()

    async def close(self):
        self.closes += 1

    monkeypatch.setattr(CoreMLWorkerProcess, "start", start)
    monkeypatch.setattr(CoreMLWorkerProcess, "request", request)
    monkeypatch.setattr(CoreMLWorkerProcess, "close", close)
    return peers


def execute(tmp_path, path, **kwargs):
    return asyncio.run(
        asyncio.wait_for(
            evaluate_native_checkpoint(
                checkpoint_lock=path, output_directory=tmp_path / "checkpoint", **kwargs
            ),
            15,
        )
    )


def test_native_checkpoint_runs_serial_c0_c1_c2_with_same_port_lock(
    tmp_path, native_c0, monkeypatch
):
    path, _, entries = controls(tmp_path, native_c0)
    peers = fake_workers(monkeypatch)
    result = execute(tmp_path, path)
    assert len(peers) == 18 and all(peer.closes == 1 for peer in peers)
    assert len({peer.inherited_guard_fd for peer in peers}) == 1
    assert [peer.protocol_version for peer in peers] == [1] * 6 + [3] * 12
    assert [peer.preset for peer in peers[6:]] == ["fast32"] * 6 + ["fast128"] * 6
    assert result["candidate_ids"] == {name: candidate_digest(e[2]) for name, e in entries.items()}
    assert result["verdict"] == "diagnostic" and not result["certification_eligible"]
    assert result["runtime_identity_verified"] is False
    assert all(
        row["candidate_execution"]["native_preflight_observed"]
        for rows in result["observations"].values()
        for row in rows
    )
    assert str(tmp_path) not in json.dumps(result) and "hello" not in json.dumps(result)
    assert json.loads((tmp_path / "checkpoint/checkpoint.json").read_text()) == result


def test_later_candidate_artifact_preflight_prevents_first_worker(tmp_path, native_c0, monkeypatch):
    path, _, entries = controls(tmp_path, native_c0)
    entries["C2"][0].write_bytes(b"wrong worker")
    peers = fake_workers(monkeypatch)
    with pytest.raises(ValueError):
        execute(tmp_path, path)
    assert not peers and not (tmp_path / "checkpoint/checkpoint.json").exists()


@pytest.mark.parametrize("field", ["unknown", "candidates", "manifest"])
def test_checkpoint_control_rejects_unknown_fields(tmp_path, native_c0, field):
    path, lock, _ = controls(tmp_path, native_c0)
    if field == "unknown":
        lock[field] = True
    elif field == "candidates":
        lock[field]["C1"]["extra"] = True
    else:
        lock[field]["extra"] = True
    path.write_text(json.dumps(lock))
    with pytest.raises(ValueError):
        execute(tmp_path, path)


def test_checkpoint_verifies_all_artifacts_immediately_before_commit(
    tmp_path, native_c0, monkeypatch
):
    import meeting_development_fixture as fixture

    path, _, entries = controls(tmp_path, native_c0)
    peers = fake_workers(monkeypatch)
    write = fixture._write_json

    def mutate(path, value):
        write(path, value)
        if path.name == "checkpoint.partial.json":
            entries["C0"][0].write_bytes(b"changed after scoring")

    monkeypatch.setattr(fixture, "_write_json", mutate)
    with pytest.raises(RuntimeError):
        execute(tmp_path, path)
    assert len(peers) == 18 and all(peer.closes == 1 for peer in peers)
    assert not (tmp_path / "checkpoint/checkpoint.json").exists()


def rewrite_document(lock_path, lock, key, update):
    from pathlib import Path

    path = Path(lock[key]["path"])
    value = json.loads(path.read_text())
    update(value)
    path.write_text(json.dumps(value))
    lock[key]["sha256"] = canonical_digest(value)
    lock_path.write_text(json.dumps(lock))
    return value


@pytest.mark.parametrize("name", ["C0", "C1", "C2"])
def test_checkpoint_rejects_candidate_role_swap_before_workers(
    tmp_path, native_c0, monkeypatch, name
):
    path, lock, _ = controls(tmp_path, native_c0)
    other = {"C0": "C1", "C1": "C2", "C2": "C1"}[name]
    lock["candidates"][name] = lock["candidates"][other]
    path.write_text(json.dumps(lock))
    peers = fake_workers(monkeypatch)
    with pytest.raises(ValueError):
        execute(tmp_path, path)
    assert not peers


def test_all_shared_fixture_preflight_precedes_first_worker(tmp_path, native_c0, monkeypatch):
    path, lock, _ = controls(tmp_path, native_c0)
    manifest = rewrite_document(
        path, lock, "manifest", lambda m: m["fixtures"][-1].update(split="holdout")
    )
    rewrite_document(
        path,
        lock,
        "split_lock",
        lambda s: s.update(development_manifest_sha256=canonical_digest(manifest)),
    )
    peers = fake_workers(monkeypatch)
    with pytest.raises(ValueError):
        execute(tmp_path, path)
    assert not peers and not (tmp_path / "checkpoint").exists()


def test_busy_configured_port_rejects_whole_checkpoint(tmp_path, native_c0, monkeypatch):
    from speechrail.runtime.server_lock import ServerInstanceLock

    path, _, _ = controls(tmp_path, native_c0)
    peers = fake_workers(monkeypatch)
    with (
        ServerInstanceLock(9912, directory=tmp_path),
        pytest.raises(RuntimeError, match="evaluation_port_busy"),
    ):
        execute(tmp_path, path)
    assert not peers


@pytest.mark.parametrize("failure", ["missing_preflight", "reap_failed"])
def test_fixture_native_observation_failure_cannot_commit_checkpoint(
    tmp_path, native_c0, monkeypatch, failure
):
    from meeting_c0 import C0WorkerProcess

    from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

    path, _, _ = controls(tmp_path, native_c0)
    peers = fake_workers(monkeypatch)
    if failure == "missing_preflight":
        # Valid packets/cleanup without the actual observed handshake must fail.
        monkeypatch.setattr(C0WorkerProcess, "request", CoreMLWorkerProcess.request)
    else:

        async def close(self):
            self.closes += 1
            raise RuntimeError("fake exact-child wait failed")

        monkeypatch.setattr(CoreMLWorkerProcess, "close", close)
    with pytest.raises(RuntimeError, match="development_checkpoint_failed"):
        execute(tmp_path, path)
    assert len(peers) == 1
    assert not (tmp_path / "checkpoint/checkpoint.json").exists()
    assert not (tmp_path / "checkpoint/C0/F0/result.json").exists()


def test_resume_uses_independent_initial_lock_and_only_live_set(tmp_path, native_c0, monkeypatch):
    import meeting_checkpoint_execution as composition

    path, lock, _ = controls(tmp_path, native_c0)
    rewrite_document(
        path,
        lock,
        "manifest",
        lambda m: m["group_order"]["1"].extend([f"{i:064x}" for i in range(6)]),
    )
    initial = composition.CheckpointControls(path).initial_schedule
    request = initial.request()
    prior = initial.record(
        {
            name: {
                "candidate_sha256": initial.candidate_ids[name],
                "source_group_ids": request["source_group_ids"],
                "product_decision": "point_failed" if name == "C1" else "insufficient_evidence",
                "nondegradation_decision": None if name == "C0" else "insufficient_evidence",
            }
            for name in request["candidates"]
        }
    )
    resume = tmp_path / "resume.json"
    resume.write_text(json.dumps(prior.as_dict()))
    calls = []

    async def evaluate(*args, **kwargs):
        calls.append(kwargs)
        return {"verdict": "diagnostic"}

    monkeypatch.setattr(composition, "evaluate_development_checkpoint", evaluate)
    execute(tmp_path, path, resume_schedule=resume)
    assert len(calls) == 1
    assert calls[0]["schedule"].request()["checkpoint"] == 12
    assert set(calls[0]["activity_factories"]) == {"C0", "C2"}
    assert set(calls[0]["candidate_verifiers"]) == {"C0", "C2"}
    saved = prior.as_dict()
    saved["candidate_ids"]["C2"] = "f" * 64
    resume.write_text(json.dumps(saved))
    with pytest.raises(ValueError):
        execute(tmp_path, path, resume_schedule=resume)
    assert len(calls) == 1


def test_high_stratum_never_constructs_c0(tmp_path, native_c0, monkeypatch):
    path, lock, _ = controls(tmp_path, native_c0)
    lock["speakers_count"] = 5

    def high_stratum(m):
        m["group_order"]["5"] = m["group_order"].pop("1")
        for row in m["fixtures"]:
            row.update(speakers_count=5, sample_kind="natural_meeting")

    manifest = rewrite_document(path, lock, "manifest", high_stratum)
    rewrite_document(
        path,
        lock,
        "split_lock",
        lambda s: s.update(development_manifest_sha256=canonical_digest(manifest)),
    )
    peers = fake_workers(monkeypatch)
    result = execute(tmp_path, path)
    assert len(peers) == 12 and all(peer.protocol_version == 3 for peer in peers)
    assert set(result["candidate_ids"]) == {"C1", "C2"}


@pytest.mark.parametrize("kind", ["symlink", "fifo", "unknown_resume"])
def test_checkpoint_external_controls_are_strict_regular_files(tmp_path, native_c0, kind):
    import os

    path, _, _ = controls(tmp_path, native_c0)
    if kind == "unknown_resume":
        resume = tmp_path / "resume.json"
        resume.write_text('{"unexpected":"private control text"}')
        with pytest.raises(ValueError):
            execute(tmp_path, path, resume_schedule=resume)
        return
    control = tmp_path / "other.json"
    if kind == "symlink":
        control.symlink_to(path)
    else:
        os.mkfifo(control)
    with pytest.raises((ValueError, OSError)):
        execute(tmp_path, control)


def test_checkpoint_cli_dispatch_and_errors_do_not_expose_controls(
    tmp_path, native_c0, monkeypatch, capsys
):
    import meeting_checkpoint_execution as composition
    from probe_meeting_candidate import main

    path, _, _ = controls(tmp_path, native_c0)
    calls = []

    async def evaluate(**kwargs):
        calls.append(kwargs)
        return {"verdict": "diagnostic", "certification_eligible": False}

    monkeypatch.setattr(composition, "evaluate_native_checkpoint", evaluate)
    arguments = [
        "evaluate-checkpoint",
        "--checkpoint-lock",
        str(path),
        "--resume-schedule",
        str(tmp_path / "resume.json"),
        "--output-directory",
        str(tmp_path / "checkpoint"),
    ]
    assert main(arguments) == 0
    assert calls[0]["checkpoint_lock"] == path
    assert calls[0]["resume_schedule"] == tmp_path / "resume.json"
    assert json.loads(capsys.readouterr().out)["verdict"] == "diagnostic"

    async def invalid(**kwargs):
        raise ValueError(str(path) + " private control text")

    monkeypatch.setattr(composition, "evaluate_native_checkpoint", invalid)
    with pytest.raises(SystemExit):
        main(arguments)
    captured = capsys.readouterr()
    assert str(tmp_path) not in captured.err and "private control text" not in captured.err


@pytest.mark.parametrize("mutation", ["bool_count", "list_round"])
def test_resume_rejects_malformed_schema_before_native_work(
    tmp_path, native_c0, monkeypatch, mutation
):
    from meeting_checkpoint_execution import CheckpointControls

    path, _, _ = controls(tmp_path, native_c0)
    saved = CheckpointControls(path).initial_schedule.as_dict()
    if mutation == "bool_count":
        saved["speakers_count"] = True
    else:
        saved["rounds"] = [["C0", "C1", "C2"]]
    resume = tmp_path / "resume.json"
    resume.write_text(json.dumps(saved))
    peers = fake_workers(monkeypatch)
    with pytest.raises(ValueError):
        execute(tmp_path, path, resume_schedule=resume)
    assert not peers


@pytest.mark.parametrize("kind", ["pcm", "activity_reference", "asr_sidecar"])
def test_fixture_final_verifier_mutation_cannot_commit_input_result(tmp_path, kind):
    from meeting_development_fixture import _CANDIDATE_EXECUTION_FIELDS

    from test_meeting_development_fixture import execute as fixture_execute
    from test_meeting_development_fixture import inputs

    manifest, split = inputs(tmp_path)
    calls = 0

    async def verify():
        nonlocal calls
        calls += 1
        if calls == 2:
            pcm = tmp_path / manifest["fixtures"][0]["artifacts"][kind]["path"]
            pcm.write_bytes(pcm.read_bytes() + b"changed during final verifier")
        return dict(_CANDIDATE_EXECUTION_FIELDS)

    with pytest.raises(RuntimeError):
        fixture_execute(tmp_path, manifest, split, verify_candidate=verify)
    assert not (tmp_path / "result/result.json").exists()


@pytest.mark.parametrize("kind", ["controls", "source", "new_model_file", "pcm"])
def test_final_artifact_verification_cannot_mutate_controls_before_commit(
    tmp_path, native_c0, monkeypatch, kind
):
    import probe_meeting_candidate as probe
    from meeting_candidate_execution import CandidateArtifacts

    path, _, entries = controls(tmp_path, native_c0)
    fake_workers(monkeypatch)
    source = tmp_path / "synthetic-adapter.py"
    source.write_bytes(b"synthetic source stamp")
    paths = probe.candidate_source_paths
    monkeypatch.setattr(probe, "candidate_source_paths", lambda spec: (*paths(spec), source))
    original = CandidateArtifacts.verify
    final_c0_checks = 0

    def mutate(self):
        nonlocal final_c0_checks
        original(self)
        if (tmp_path / "checkpoint/checkpoint.partial.json").exists() and (
            self.spec.implementation_id == "sortformer-four-slot-control-v1"
        ):
            final_c0_checks += 1
            if final_c0_checks == 2:
                if kind == "controls":
                    path.write_text(path.read_text() + " ")
                elif kind == "source":
                    source.write_bytes(b"changed source after final slow checks")
                elif kind == "new_model_file":
                    (entries["C1"][1] / "unexpected.bin").write_bytes(b"added late")
                else:
                    pcm = tmp_path / "part0/M0.pcm"
                    pcm.write_bytes(b"changed shared input")

    monkeypatch.setattr(CandidateArtifacts, "verify", mutate)
    with pytest.raises(RuntimeError):
        execute(tmp_path, path)
    assert not (tmp_path / "checkpoint/checkpoint.json").exists()
