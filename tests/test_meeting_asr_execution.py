"""Locked ASR driver tests use synthetic files and fake inference only."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import threading
import wave
from pathlib import Path
from types import SimpleNamespace

import pytest
from meeting_evaluation_identity import canonical_digest

from test_meeting_asr_runtime import runtime_setup  # noqa: F401
from test_meeting_asr_sidecar import fixture as sidecar_fixture
from test_meeting_development_fixture import inputs
from test_meeting_quality_metrics import policy
from test_meeting_realtime_asr_replay import case


@pytest.fixture
def execution_case(tmp_path, runtime_setup):  # noqa: F811
    from meeting_candidate_execution import EvaluationPortLease

    state = runtime_setup
    state.settings.port = 49000 + int(hashlib.sha256(str(tmp_path).encode()).hexdigest()[:3], 16)
    # The worker interpreter is explicit and resolves to a regular file.
    state.settings.qwen3_python = state.settings.qwen3_python.resolve()

    async def freeze_independent_candidate():
        with EvaluationPortLease(state.settings.port) as lease:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings,
                dependencies=state.dependencies,
                inherited_fds=(lease.descriptor,),
            ) as runtime:
                return runtime.candidate_spec(language="Chinese")

    expected = asyncio.run(freeze_independent_candidate())
    state.created.clear()
    state.closed.clear()
    state.calls.clear()
    root = tmp_path / "fixture"
    root.mkdir()
    manifest, split = inputs(root)
    artifacts = manifest["fixtures"][0]["artifacts"]
    pcm = case().pcm16
    target = root / artifacts["pcm"]["path"]
    with wave.open(str(target), "wb") as handle:
        handle.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        handle.writeframes(pcm)
    artifacts["pcm"]["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    for kind in ("activity_reference", "text_reference"):
        target = root / artifacts[kind]["path"]
        value = json.loads(target.read_text())
        value["total_samples"] = len(pcm) // 2
        target.write_text(json.dumps(value))
        artifacts[kind]["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    _, artifacts["asr_sidecar"] = sidecar_fixture(root, pcm_sha256=artifacts["pcm"]["sha256"])
    split["development_manifest_sha256"] = canonical_digest(manifest)
    primary = root / "primary.json"
    primary.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "fixture_id": "M0",
                "manifest_sha256": canonical_digest(manifest),
                "pcm_sha256": artifacts["pcm"]["sha256"],
                "overlap_order": "unambiguous",
                "main_reference": "甲乙",
            }
        )
    )
    lock = {
        "schema_version": 1,
        "fixture_id": "M0",
        "service_port": state.settings.port,
        "artifact_root": str(root),
        "primary_reference": {
            "path": "primary.json",
            "sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
        },
        "dependencies": {
            name: [str(path) for path in getattr(state.dependencies, name)]
            for name in ("host", "asr", "aligner")
        },
    }
    documents = {
        "manifest": manifest,
        "split_lock": split,
        "scorer_policy": policy(),
        "settings": state.settings.model_dump(mode="json"),
        "candidate_spec": expected.as_dict(),
    }
    for name, value in documents.items():
        path = tmp_path / f"{name}.json"
        path.write_text(json.dumps(value))
        lock[name] = {"path": str(path), "sha256": canonical_digest(value)}
    lock_path = tmp_path / "evaluation.json"
    lock_path.write_text(json.dumps(lock))
    return SimpleNamespace(
        state=state,
        lock=lock,
        path=lock_path,
        root=root,
        primary=primary,
        documents=documents,
        expected=expected,
        output=tmp_path / "output",
    )


def save_lock(data):
    data.path.write_text(json.dumps(data.lock))


def update_document(data, name, value):
    path = Path(data.lock[name]["path"])
    path.write_text(json.dumps(value))
    data.lock[name]["sha256"] = canonical_digest(value)
    save_lock(data)


def execute(data):
    from meeting_asr_execution import execute_asr_development

    return asyncio.run(
        execute_asr_development(evaluation_lock=data.path, output_directory=data.output)
    )


def assert_no_result(data):
    assert not (data.output / "result.json").exists()
    if (data.output / "failure.json").exists():
        failure = json.loads((data.output / "failure.json").read_text())
        assert failure == {
            "schema_version": 1,
            "status": "failed",
            "code": "asr_development_execution_failed",
        }


def test_full_production_root_formal_session_commits_private_diagnostic(execution_case):
    data = execution_case
    result = execute(data)
    saved = json.loads((data.output / "result.json").read_text())
    assert saved == result
    assert saved["actual_decode_calls"] > 0
    assert saved["source_validation"]["bytes_verified"] is True
    assert saved["runtime_identity_verified"] is False
    assert saved["certification_eligible"] is False
    assert saved["a0_execution"] == "not_certified"
    assert saved["runtime_freeze"]["post_close_bytes_stable"] is True
    assert data.state.created[0].window_asr_factory._session is None
    assert sorted(name for name, _ in data.state.closed) == ["aligner", "asr"]
    assert data.output.stat().st_mode & 0o777 == 0o700
    assert (data.output / "result.json").stat().st_mode & 0o777 == 0o600
    assert (data.output / "result.json").stat().st_ino == (
        data.output / "result.partial.json"
    ).stat().st_ino
    serialized = json.dumps(saved, ensure_ascii=False)
    assert "甲乙" not in serialized and str(data.root.parent) not in serialized
    assert '"pcm16":' not in serialized and '"main_reference":' not in serialized


@pytest.mark.parametrize("field", ["sdk_revision", "adapter_sha256", "model_files_sha256"])
def test_independent_expected_change_fails_before_model_prepare(execution_case, field):
    data = execution_case
    expected = data.documents["candidate_spec"]
    if field == "model_files_sha256":
        expected[field]["model.safetensors"] = "f" * 64
    else:
        expected[field] = "f" * 64
    update_document(data, "candidate_spec", expected)

    async def forbidden_start():
        pytest.fail("changed independent expected spec started a model")

    data.state.start_hook = forbidden_start
    with pytest.raises(ValueError, match="locked ASR development execution failed"):
        execute(data)
    assert not data.state.calls
    assert_no_result(data)


@pytest.mark.parametrize(
    "field,value",
    [
        ("unknown_option", 1),
        ("port", True),
        ("host", "localhost"),
        ("api_key", "private-secret"),
        ("qwen3_tts_model_dir", "/unused"),
    ],
)
def test_unknown_secret_non_asr_or_type_substitution_settings_fail_closed(
    execution_case,
    field,
    value,
):
    data = execution_case
    settings = data.documents["settings"]
    settings[field] = value
    update_document(data, "settings", settings)
    with pytest.raises(ValueError) as caught:
        execute(data)
    assert str(caught.value) == "locked ASR development execution failed"
    assert not data.output.exists() and not data.state.created


def test_environment_and_dotenv_cannot_supplement_missing_settings(
    execution_case,
    monkeypatch,
    tmp_path,
):
    data = execution_case
    settings = data.documents["settings"]
    model = settings.pop("qwen3_model_dir")
    update_document(data, "settings", settings)
    monkeypatch.setenv("SPEECHRAIL_QWEN3_MODEL_DIR", model)
    (tmp_path / ".env").write_text(f"SPEECHRAIL_QWEN3_MODEL_DIR={model}\n")
    monkeypatch.chdir(tmp_path)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.output.exists() and not data.state.created


def test_unrelated_environment_and_legacy_env_do_not_change_locked_settings(
    execution_case,
    monkeypatch,
    tmp_path,
):
    data = execution_case
    monkeypatch.setenv("SPEECHRAIL_PORT", "12345")
    monkeypatch.setenv("SPEECHRAIL_QWEN3_TTS_MODEL_DIR", "/environment-must-not-load")
    monkeypatch.setenv("SPEECHRAIL_DIARIZATION_MODEL_PATH", "/legacy-must-not-affect-lock")
    (tmp_path / ".env").write_text("SPEECHRAIL_API_KEY=must-not-read\n")
    monkeypatch.chdir(tmp_path)
    assert execute(data)["certification_eligible"] is False


@pytest.mark.parametrize(
    "change",
    ["extra", "bool_port", "duplicate", "nonfinite", "relative", "symlink", "fifo"],
)
def test_control_schema_and_path_fail_before_source_or_model(execution_case, change):
    data = execution_case
    if change == "extra":
        data.lock["extra"] = True
        save_lock(data)
    elif change == "bool_port":
        data.lock["service_port"] = True
        save_lock(data)
    elif change == "duplicate":
        data.path.write_text('{"schema_version":1,"schema_version":1}')
    elif change == "nonfinite":
        data.path.write_text('{"schema_version":NaN}')
    elif change == "relative":
        data.lock["settings"]["path"] = "settings.json"
        save_lock(data)
    elif change == "symlink":
        target = data.path.with_name("actual-evaluation.json")
        target.write_bytes(data.path.read_bytes())
        data.path.unlink()
        data.path.symlink_to(target)
    else:
        data.path.unlink()
        os.mkfifo(data.path)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()


def test_holdout_is_rejected_before_output_and_runtime_construction(execution_case):
    data = execution_case
    manifest = data.documents["manifest"]
    manifest["split"] = "frozen_holdout"
    update_document(data, "manifest", manifest)
    split = data.documents["split_lock"]
    split["development_manifest_sha256"] = canonical_digest(manifest)
    update_document(data, "split_lock", split)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()


def test_configured_busy_port_cannot_start_private_workers(execution_case):
    from meeting_candidate_execution import EvaluationPortLease

    data = execution_case
    with EvaluationPortLease(data.lock["service_port"]), pytest.raises(ValueError):
        execute(data)
    assert not data.state.created
    assert_no_result(data)


def test_output_must_be_fresh_and_existing_bytes_are_preserved(execution_case):
    data = execution_case
    data.output.mkdir()
    (data.output / "keep.txt").write_text("untouched")
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created
    assert list(data.output.iterdir()) == [data.output / "keep.txt"]
    assert (data.output / "keep.txt").read_text() == "untouched"


@pytest.mark.parametrize("moment", ["close", "partial_write"])
@pytest.mark.parametrize("kind", ["control", "primary", "model", "dependency", "source"])
def test_mutation_through_close_and_last_write_never_commits(
    execution_case,
    monkeypatch,
    tmp_path,
    moment,
    kind,
):
    import meeting_asr_execution as module

    from speechrail.backends.qwen3_shared import Qwen3SharedWorker

    data = execution_case
    source = tmp_path / "executor-source.py"
    source.write_text("# frozen executor helper\n")
    monkeypatch.setattr(module, "_SOURCES", (*module._SOURCES, str(source)))
    target = {
        "control": Path(data.lock["settings"]["path"]),
        "primary": data.primary,
        "model": data.state.snapshots[0] / "model.safetensors",
        "dependency": data.state.dependency / "library.so",
        "source": source,
    }[kind]

    def mutate():
        before = target.read_bytes()
        target.write_bytes(before + b"transient mutation")
        target.write_bytes(before)

    if moment == "close":
        original_close = Qwen3SharedWorker.close

        async def changed_close(owner):
            await original_close(owner)
            mutate()

        monkeypatch.setattr(Qwen3SharedWorker, "close", changed_close)
    else:
        original_write = module._write_json

        def changed_write(path, report):
            original_write(path, report)
            if path.name == "result.partial.json":
                mutate()

        monkeypatch.setattr(module, "_write_json", changed_write)
    with pytest.raises(ValueError) as caught:
        execute(data)
    assert str(caught.value) == "locked ASR development execution failed"
    assert len(data.state.closed) == 2
    assert_no_result(data)


def test_cleanup_failure_never_commits_or_leaks_error(execution_case, monkeypatch):
    from speechrail.backends.qwen3_shared import Qwen3SharedWorker

    data = execution_case
    original = Qwen3SharedWorker.close

    async def failed_close(owner):
        await original(owner)
        raise RuntimeError("private model path and transcript must stay private")

    monkeypatch.setattr(Qwen3SharedWorker, "close", failed_close)
    with pytest.raises(ValueError) as caught:
        execute(data)
    assert str(caught.value) == "locked ASR development execution failed"
    assert len(data.state.closed) == 2
    assert_no_result(data)


def test_cancelled_source_preflight_joins_thread_before_return(
    execution_case,
    monkeypatch,
):
    import meeting_asr_execution as module

    data = execution_case
    entered, release = threading.Event(), threading.Event()
    original = module.load_locked_asr_case

    def blocked(*args, **kwargs):
        result = original(*args, **kwargs)
        entered.set()
        assert release.wait(3)
        return result

    monkeypatch.setattr(module, "load_locked_asr_case", blocked)

    async def exercise():
        task = asyncio.create_task(
            module.execute_asr_development(evaluation_lock=data.path, output_directory=data.output)
        )
        assert await asyncio.to_thread(entered.wait, 3)
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done() and not data.state.created
        task.cancel()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert not data.output.exists()

    asyncio.run(exercise())


def test_cancelled_formal_replay_joins_both_owners_and_keeps_fixed_failure(
    execution_case,
    monkeypatch,
):
    import meeting_asr_execution as module

    from speechrail.backends.qwen3_shared import Qwen3SharedWorker

    data = execution_case
    original = Qwen3SharedWorker.request

    async def exercise():
        entered, release = asyncio.Event(), asyncio.Event()

        async def blocked(owner, frame, binary=None):
            entered.set()
            await release.wait()
            return await original(owner, frame, binary)

        monkeypatch.setattr(Qwen3SharedWorker, "request", blocked)
        task = asyncio.create_task(
            module.execute_asr_development(evaluation_lock=data.path, output_directory=data.output)
        )
        await asyncio.wait_for(entered.wait(), 3)
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done() and not data.state.closed
        task.cancel()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 3)
        assert len(data.state.closed) == 2
        assert not (data.output / "result.json").exists()
        assert json.loads((data.output / "failure.json").read_text()) == {
            "schema_version": 1,
            "status": "cancelled",
            "code": "asr_development_execution_failed",
        }
        assert not any(task.get_name().startswith("frozen-asr-") for task in asyncio.all_tasks())

    asyncio.run(exercise())


def test_json_file_and_aggregate_budgets_fail_before_loading(execution_case, monkeypatch):
    import meeting_asr_execution as module

    data = execution_case
    monkeypatch.setattr(module, "_MAX_TOTAL_BYTES", data.path.stat().st_size)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()
    monkeypatch.setattr(module, "_MAX_TOTAL_BYTES", 32 * 1024 * 1024)
    monkeypatch.setattr(module, "_MAX_FILE_BYTES", data.path.stat().st_size - 1)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()


def test_changed_partial_report_cannot_be_committed(execution_case, monkeypatch):
    import meeting_asr_execution as module

    data = execution_case
    original = module._write_json

    def changed(path, report):
        original(path, report)
        if path.name == "result.partial.json":
            path.write_text('{"certification_eligible":true}')

    monkeypatch.setattr(module, "_write_json", changed)
    with pytest.raises(ValueError):
        execute(data)
    assert_no_result(data)


@pytest.mark.parametrize("kind", ["control", "primary", "model", "dependency", "source"])
def test_change_after_last_joined_verify_is_rejected_by_synchronous_guard(
    execution_case,
    monkeypatch,
    tmp_path,
    kind,
):
    import meeting_asr_execution as module

    data = execution_case
    helper = tmp_path / "commit-helper.py"
    helper.write_text("# frozen source\n")
    monkeypatch.setattr(module, "_SOURCES", (*module._SOURCES, str(helper)))
    target = {
        "control": data.path,
        "primary": data.primary,
        "model": data.state.snapshots[1] / "model.safetensors",
        "dependency": data.state.dependency / "library.so",
        "source": helper,
    }[kind]
    original = module._AsrControls.verify
    checks = []

    def final_mutation(self):
        original(self)
        checks.append(True)
        if len(checks) == 3:
            before = target.read_bytes()
            target.write_bytes(before + b"last window")
            target.write_bytes(before)

    monkeypatch.setattr(module._AsrControls, "verify", final_mutation)
    with pytest.raises(ValueError):
        execute(data)
    assert len(checks) == 3
    assert_no_result(data)


def test_control_parent_retarget_to_identical_inode_still_fails(
    execution_case,
    monkeypatch,
    tmp_path,
):
    import meeting_asr_execution as module

    data = execution_case
    first, second = tmp_path / "first", tmp_path / "second"
    first.mkdir()
    second.mkdir()
    settings = Path(data.lock["settings"]["path"])
    os.link(settings, first / "settings.json")
    os.link(settings, second / "settings.json")
    alias = tmp_path / "control-parent"
    alias.symlink_to(first, target_is_directory=True)
    data.lock["settings"]["path"] = str(alias / "settings.json")
    save_lock(data)
    original = module._write_json

    def redirected(path, report):
        original(path, report)
        if path.name == "result.partial.json":
            alias.unlink()
            alias.symlink_to(second, target_is_directory=True)

    monkeypatch.setattr(module, "_write_json", redirected)
    with pytest.raises(ValueError):
        execute(data)
    assert_no_result(data)


@pytest.mark.parametrize("role", ["interpreter", "dependency"])
def test_explicit_regular_file_symlinks_keep_original_paths_and_can_run(
    execution_case,
    tmp_path,
    role,
):
    from meeting_asr_runtime import RuntimeDependencyRoots
    from meeting_candidate_execution import EvaluationPortLease

    data = execution_case
    state = data.state
    link = tmp_path / "explicit-file-link"
    if role == "interpreter":
        link.symlink_to(state.settings.qwen3_python)
        state.settings.qwen3_python = link
    else:
        link.symlink_to(state.dependency / "library.so")
        state.dependencies = RuntimeDependencyRoots(host=(link,), asr=(link,), aligner=(link,))

    async def independent():
        with EvaluationPortLease(state.settings.port) as lease:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings,
                dependencies=state.dependencies,
                inherited_fds=(lease.descriptor,),
            ) as runtime:
                return runtime.candidate_spec(language="Chinese")

    expected = asyncio.run(independent())
    update_document(data, "candidate_spec", expected.as_dict())
    update_document(data, "settings", state.settings.model_dump(mode="json"))
    data.lock["dependencies"] = {
        name: [str(path) for path in getattr(state.dependencies, name)]
        for name in ("host", "asr", "aligner")
    }
    save_lock(data)
    state.created.clear()
    state.closed.clear()
    result = execute(data)
    assert result["runtime_freeze"]["owned_children_reaped"] is True
    assert result["runtime_identity_verified"] is False
    controls = __import__("meeting_asr_execution")._AsrControls(data.path)
    if role == "interpreter":
        assert controls.settings.qwen3_python == link
    else:
        assert controls.dependencies.host == (link,)


def test_directory_symlink_dependency_and_model_are_rejected_before_loading(
    execution_case,
    tmp_path,
):
    data = execution_case
    alias = tmp_path / "dependency-link"
    alias.symlink_to(data.state.dependency, target_is_directory=True)
    data.lock["dependencies"]["host"] = [str(alias)]
    save_lock(data)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()
    data.lock["dependencies"]["host"] = [str(data.state.dependency)]
    alias.unlink()
    alias.symlink_to(data.state.snapshots[0], target_is_directory=True)
    settings = data.documents["settings"]
    settings["qwen3_model_dir"] = str(alias)
    update_document(data, "settings", settings)
    with pytest.raises(ValueError):
        execute(data)
    assert not data.state.created and not data.output.exists()


@pytest.mark.parametrize("role", ["asr", "aligner", "vad"])
def test_model_artifacts_must_resolve_outside_repository(
    execution_case,
    monkeypatch,
    tmp_path,
    role,
):
    import meeting_asr_execution as module

    data = execution_case
    settings = data.documents["settings"]
    if role == "vad":
        repository = tmp_path / "synthetic-repository"
        repository.mkdir()
        model = repository / "vad.onnx"
        model.write_bytes(b"synthetic vad")
        settings["realtime_vad_model_path"] = str(model)
    else:
        repository = data.state.snapshots[{"asr": 0, "aligner": 1}[role]]
    monkeypatch.setattr(module, "_ROOT", repository)
    with pytest.raises(ValueError, match="model artifacts must remain external"):
        module._settings(settings, data.lock["service_port"])
    assert not data.state.created


def test_model_bundle_file_symlink_cannot_target_repository_bytes(
    execution_case,
    monkeypatch,
    tmp_path,
):
    import meeting_asr_execution as module

    data = execution_case
    repository = tmp_path / "synthetic-repository"
    repository.mkdir()
    target = repository / "model.safetensors"
    target.write_bytes(b"synthetic")
    weight = data.state.snapshots[0] / "model.safetensors"
    weight.unlink()
    weight.symlink_to(target)
    monkeypatch.setattr(module, "_ROOT", repository)
    with pytest.raises(ValueError, match="model artifacts must remain external"):
        module._settings(data.documents["settings"], data.lock["service_port"])
    assert not data.state.created


def test_output_directory_replacement_cannot_redirect_report(
    execution_case,
    monkeypatch,
    tmp_path,
):
    from speechrail.backends.qwen3_shared import Qwen3SharedWorker

    data = execution_case
    outside = tmp_path / "unexpected-output"
    outside.mkdir()
    original = Qwen3SharedWorker.close

    async def redirect(owner):
        await original(owner)
        data.output.rename(tmp_path / "original-output")
        data.output.symlink_to(outside, target_is_directory=True)

    monkeypatch.setattr(Qwen3SharedWorker, "close", redirect)
    with pytest.raises(ValueError):
        execute(data)
    assert list(outside.iterdir()) == []
    assert len(data.state.closed) == 2


def test_missing_control_path_is_sanitized_without_creating_output(tmp_path):
    from meeting_asr_execution import execute_asr_development

    output = tmp_path / "output"
    with pytest.raises(ValueError) as caught:
        asyncio.run(
            execute_asr_development(
                evaluation_lock=tmp_path / "private-missing-control.json",
                output_directory=output,
            )
        )
    assert str(caught.value) == "locked ASR development execution failed"
    assert not output.exists()


@pytest.mark.parametrize("version", [True, 2, "1"])
def test_invalid_control_version_cannot_start_or_create_output(tmp_path, version):
    from meeting_asr_execution import execute_asr_development

    lock = tmp_path / "lock.json"
    lock.write_text(json.dumps({"schema_version": version}))
    with pytest.raises(ValueError, match="locked ASR development execution failed"):
        asyncio.run(
            execute_asr_development(evaluation_lock=lock, output_directory=tmp_path / "output")
        )
    assert not (tmp_path / "output").exists()
