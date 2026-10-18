"""Private production composition with synthetic bytes and fake worker RPCs."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import sys
import threading
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest
from meeting_evaluation_identity import candidate_digest, canonical_digest

from speechrail.application.services import build_app_services
from speechrail.backends.model_identity import observed_runtime_revision
from speechrail.backends.qwen3_alignment import Qwen3AlignmentWorker
from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.config import Settings
from speechrail.infrastructure.voice_registry import FileVoiceRegistry


def test_model_file_symlink_into_repository_rejected_before_loading(runtime_setup):
    state = runtime_setup
    weight = state.snapshots[0] / "model.safetensors"
    weight.unlink()
    weight.symlink_to(Path(__file__).resolve().parents[1] / "pyproject.toml")
    started = []

    async def mark_started():
        started.append(True)

    state.start_hook = mark_started

    async def run():
        with pytest.raises(ValueError, match="model artifacts must remain outside repository"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass
        assert not started

    asyncio.run(run())


@pytest.fixture
def runtime_setup(tmp_path, monkeypatch):
    import meeting_asr_runtime as module

    snapshots = []
    for name in ("asr", "aligner"):
        root = tmp_path / name
        root.mkdir()
        for filename in (*MODEL_FILES, "model.safetensors"):
            (root / filename).write_text("synthetic")
        snapshots.append(root)
    dependency = tmp_path / "dependencies"
    dependency.mkdir()
    (dependency / "library.so").write_bytes(b"synthetic dependency bytes")
    source = tmp_path / "source"
    source.mkdir()
    paths = {}
    for name in ("adapter", "worker", "runtime", "formal_replay"):
        paths[name] = source / f"{name}.py"
        paths[name].write_text(f"# synthetic {name}\n")
    default_source_paths = module._source_paths
    monkeypatch.setattr(module, "_source_paths", lambda: paths)
    monkeypatch.setattr(
        FileVoiceRegistry,
        "open",
        classmethod(lambda *args: pytest.fail("ASR root opened a voice catalog")),
    )
    created = []

    def build(settings, overrides):
        # Native production owners/factory, with only inference methods replaced.
        result = build_app_services(settings, overrides)
        created.append(result)
        return result

    monkeypatch.setattr(module, "build_app_services", build)
    closed = []
    calls = []
    start_hook = None

    async def start_asr(owner):
        if owner.ready:
            return
        owner._generation_guard.advance()
        owner._transport._process = SimpleNamespace(returncode=None)
        owner._ready = True
        owner._identity = (owner.config.device, owner.config.dtype)
        owner._capabilities = frozenset({"window_decode_v1"})
        owner._runtime_revision = observed_runtime_revision(
            {
                "backend": "native",
                "device": owner.config.device,
                "dtype": owner.config.dtype,
                "compute_config": owner.config.device,
                "sample_rate": 16000,
                "family": "qwen3_asr",
                "model_variant": "asr",
                "weight_fingerprint": "shape:synthetic",
            }
        )
        owner._window_decode_max_new_tokens = owner.config.max_new_tokens or 512
        if state.start_hook is not None:
            await state.start_hook()

    async def start_aligner(owner):
        if owner.ready:
            return
        owner._process._process = SimpleNamespace(returncode=None)
        owner._ready = {"granularities": ["word"], "model_loaded": True}

    async def align_text(owner, pcm, *, text, language):
        return tuple((character, 0.0, len(pcm) / 32000) for character in text)

    async def close_asr(owner):
        closed.append(("asr", owner))
        if owner._transport._process is not None:
            owner._transport._process.returncode = 0
        owner._ready = False
        owner._transport._process = None

    async def close_aligner(owner):
        closed.append(("aligner", owner))
        if owner._process._process is not None:
            owner._process._process.returncode = 0
        owner._ready = None
        owner._process._process = None

    async def request(owner, frame, binary=None):
        calls.append(dict(frame))
        result = dict(frame)
        result["type"] = "window.closed" if frame["type"] == "window.close" else "window.result"
        if result["type"] == "window.result":
            result.update(
                text="甲乙",
                language="Chinese",
                complete=frame["kind"] == "review",
                observation={
                    "kind": frame["kind"],
                    "generated_token_count": 2,
                    "decode_max_new_tokens": owner.config.max_new_tokens,
                    "finish_reason": "eos",
                    "truncated": False,
                },
            )
        return result

    monkeypatch.setattr(Qwen3SharedWorker, "start", start_asr)
    monkeypatch.setattr(Qwen3SharedWorker, "request", request)
    monkeypatch.setattr(Qwen3SharedWorker, "close", close_asr)
    monkeypatch.setattr(Qwen3AlignmentWorker, "start", start_aligner)
    monkeypatch.setattr(Qwen3AlignmentWorker, "align_text", align_text)
    monkeypatch.setattr(Qwen3AlignmentWorker, "close", close_aligner)
    settings = Settings(
        _env_file=None,
        qwen3_model_dir=snapshots[0],
        qwen3_aligner_model_dir=snapshots[1],
        qwen3_python=Path(sys.executable),
        asr_revision_windows_enabled=True,
        realtime_vad_engine="legacy",
        qwen3_streaming_max_new_tokens=128,
        asr_resident_bytes=1024,
    )
    dependencies = module.RuntimeDependencyRoots(
        host=(dependency,), asr=(dependency,), aligner=(dependency,)
    )
    state = SimpleNamespace(
        module=module,
        settings=settings,
        dependencies=dependencies,
        created=created,
        snapshots=snapshots,
        dependency=dependency,
        paths=paths,
        closed=closed,
        calls=calls,
        start_hook=start_hook,
        default_source_paths=default_source_paths,
    )
    return state


def test_private_root_prepares_actual_cap_and_closes_only_its_two_owners(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            spec = runtime.candidate_spec(language="Chinese")
            assert spec.decoder["max_tokens"] == 512
            assert spec.decoder["max_tokens"] != state.settings.qwen3_streaming_max_new_tokens
            assert (
                spec.model_files_sha256["model.safetensors"]
                == hashlib.sha256(b"synthetic").hexdigest()
            )
            await runtime.verify()
            proof = runtime.proof()
            assert proof["preload_bytes_frozen"] is True
            assert proof["loaded_model_bytes_verified"] is False
            assert proof["actual_imports_verified"] is False
            assert proof["post_prepare_bytes_stable"] is True
            assert proof["post_replay_bytes_stable"] is False
            assert state.created[0].settings.worker_idle_timeout_seconds == 0
            assert state.settings.worker_idle_timeout_seconds > 0
            for transport in (
                state.created[0].asr_worker.shared_owner._transport,
                state.created[0].text_aligner._client._process,
            ):
                assert transport._spec.env["PYTHONDONTWRITEBYTECODE"] == "1"
        assert {name for name, _ in state.closed} == {"asr", "aligner"}
        assert not any(t.get_name().startswith("frozen-asr-") for t in asyncio.all_tasks())

    asyncio.run(run())


@pytest.mark.parametrize(
    "field", ["adapter_sha256", "worker_sha256", "sdk_revision", "model_files_sha256", "dtype"]
)
def test_expected_static_candidate_rejected_before_prepare(runtime_setup, field):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            expected = runtime.candidate_spec(language="Chinese")
        changed = {"model.safetensors": "0" * 64} if field == "model_files_sha256" else "0" * 64
        expected = replace(expected, **{field: changed})
        entered = False

        async def started():
            nonlocal entered
            entered = True

        state.start_hook = started
        with pytest.raises(ValueError, match="execution identity mismatch"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies, expected_spec=expected
            ):
                pytest.fail("published mismatched preregistered candidate")
        assert not entered

    asyncio.run(run())


def test_expected_ready_candidate_checked_before_publication(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            expected = runtime.candidate_spec(language="Chinese")
        with pytest.raises(ValueError, match="model_revision"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings,
                dependencies=state.dependencies,
                expected_spec=replace(expected, model_revision="unobserved-revision"),
            ):
                pytest.fail("published mismatched ready identity")
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies, expected_spec=expected
        ) as runtime:
            assert runtime.candidate_spec(language="Chinese") == expected
            with pytest.raises(ValueError, match="closed"):
                runtime.verify_commit()
        proof = await runtime.verify_closed()
        assert proof["owned_children_reaped"] is True
        assert proof["post_close_bytes_stable"] is True
        assert proof["commit_guard_ready"] is True
        assert proof["loaded_model_bytes_verified"] is False
        runtime.verify_commit()

    asyncio.run(run())


def test_post_close_changes_and_body_failure_never_allow_commit(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            pass
        (state.dependency / "library.so").write_bytes(b"changed after close")
        with pytest.raises(ValueError):
            runtime.verify_commit()
        with pytest.raises(ValueError):
            await runtime.verify_closed()
        with pytest.raises(RuntimeError, match="caller failed"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as failed:
                raise RuntimeError("caller failed")
        with pytest.raises(ValueError):
            failed.verify_commit()

    asyncio.run(run())


def test_success_exit_full_check_catches_mutation_during_child_close(runtime_setup, monkeypatch):
    state = runtime_setup
    original = Qwen3AlignmentWorker.close

    async def close(owner):
        await original(owner)
        (state.dependency / "library.so").write_bytes(b"changed during close")

    monkeypatch.setattr(Qwen3AlignmentWorker, "close", close)

    async def run():
        with pytest.raises(ValueError, match="runtime bytes"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as runtime:
                pass
        assert len(state.closed) == 2
        with pytest.raises(ValueError):
            runtime.verify_commit()

    asyncio.run(run())


def test_inherited_port_guard_binds_roles_not_fd_numbers(runtime_setup, tmp_path, monkeypatch):
    from meeting_candidate_execution import EvaluationPortLease

    state = runtime_setup
    lease = EvaluationPortLease(state.settings.port, directory=tmp_path)
    monkeypatch.setattr(state.module, "_guard_path", lambda port: lease._path)

    async def prepare(descriptor, expected=None):
        async with state.module.prepare_frozen_asr_runtime(
            state.settings,
            dependencies=state.dependencies,
            expected_spec=expected,
            inherited_fds=(descriptor,),
        ) as runtime:
            for transport in (runtime._owners.asr_transport, runtime._owners.alignment_transport):
                assert transport._spec.pass_fds == (descriptor,)
            spec = runtime.candidate_spec(language="Chinese")
        await runtime.verify_closed()
        return spec

    with lease:
        descriptor = os.dup(lease.descriptor)
        try:
            expected = asyncio.run(prepare(lease.descriptor))
            assert asyncio.run(prepare(descriptor, expected)) == expected
        finally:
            os.close(descriptor)
    inode = lease._path.stat().st_ino
    # Recreating the same semantic lock for another run must not change the
    # candidate. This run still independently freezes its actual new inode.
    previous = tmp_path / "previous-lock"
    lease._path.rename(previous)
    with lease:
        assert lease._path.stat().st_ino != inode
        assert asyncio.run(prepare(lease.descriptor, expected)) == expected


def test_inherited_guard_replacement_poisoned_even_after_close(
    runtime_setup, tmp_path, monkeypatch
):
    from meeting_candidate_execution import EvaluationPortLease

    state = runtime_setup
    lease = EvaluationPortLease(state.settings.port, directory=tmp_path)
    monkeypatch.setattr(state.module, "_guard_path", lambda port: lease._path)

    async def run(descriptor):
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies, inherited_fds=(descriptor,)
        ) as runtime:
            pass
        replacement = os.open(tmp_path / "other", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            os.dup2(replacement, descriptor)
            with pytest.raises(ValueError, match="closed"):
                runtime.verify_commit()
        finally:
            os.close(replacement)

    with lease:
        descriptor = os.dup(lease.descriptor)
        try:
            asyncio.run(run(descriptor))
        finally:
            os.close(descriptor)


@pytest.mark.parametrize("kind", ["retained_process", "unreaped_process"])
def test_close_requires_exact_children_reaped_not_only_ready_false(
    runtime_setup, monkeypatch, kind
):
    state = runtime_setup
    original = Qwen3SharedWorker.close

    async def close(owner):
        process = owner._transport._process
        await original(owner)
        if kind == "retained_process":
            owner._transport._process = process
        else:
            process.returncode = None

    monkeypatch.setattr(Qwen3SharedWorker, "close", close)

    async def run():
        with pytest.raises(RuntimeError, match="cleanup is unconfirmed"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as runtime:
                pass
        assert len(state.closed) == 2
        with pytest.raises(ValueError):
            await runtime.verify_closed()
        with pytest.raises(ValueError):
            runtime.proof()

    asyncio.run(run())


@pytest.mark.parametrize("kind", ["owner", "configuration", "generation", "process"])
def test_closed_guard_rechecks_exact_composition_and_configuration(runtime_setup, kind):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            pass
        owners = runtime._owners
        if kind == "owner":
            object.__setattr__(owners.services, "window_asr_factory", object())
        elif kind == "configuration":
            owners.asr_transport._spec = replace(
                owners.asr_transport._spec,
                env={**owners.asr_transport._spec.env, "ASR_CHANGED": "1"},
            )
        elif kind == "generation":
            owners.asr._generation_guard.advance()
        else:
            owners.asr_transport._process = SimpleNamespace(returncode=None)
        with pytest.raises(ValueError, match="closed"):
            runtime.verify_commit()
        with pytest.raises(ValueError):
            await runtime.verify_closed()

    asyncio.run(run())


def test_cancelled_post_close_full_hash_is_joined_and_cannot_commit(runtime_setup, monkeypatch):
    state = runtime_setup
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    original = state.module._Inventory.verify

    def verify(inventory, *, hash_bytes=True):
        if hash_bytes and len(state.closed) == 2:
            entered.set()
            assert release.wait(3)
            original(inventory, hash_bytes=hash_bytes)
            finished.set()
        else:
            original(inventory, hash_bytes=hash_bytes)

    monkeypatch.setattr(state.module._Inventory, "verify", verify)

    async def run():
        handles = []

        async def context():
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as runtime:
                handles.append(runtime)

        task = asyncio.create_task(context())
        assert await asyncio.to_thread(entered.wait, 3)
        task.cancel()
        await asyncio.sleep(0)
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert finished.is_set()
        with pytest.raises(ValueError):
            handles[0].verify_commit()
        with pytest.raises(ValueError):
            await handles[0].verify_closed()
        assert not any(t.get_name().startswith("frozen-asr-") for t in asyncio.all_tasks())

    asyncio.run(run())


def test_inherited_guard_rejects_unrelated_file_before_loading(runtime_setup, tmp_path):
    state = runtime_setup
    entered = False

    async def start():
        nonlocal entered
        entered = True

    state.start_hook = start
    descriptor = os.open(tmp_path / "unrelated", os.O_CREAT | os.O_RDWR, 0o600)

    async def run():
        with pytest.raises(ValueError, match="inherited ASR runtime guard") as error:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies, inherited_fds=(descriptor,)
            ):
                pytest.fail("unrelated descriptor was accepted as the service guard")
        assert str(tmp_path) not in str(error.value)
        assert not entered
        assert len(state.closed) == 2

    try:
        asyncio.run(run())
    finally:
        os.close(descriptor)


@pytest.mark.parametrize("kind", ["asr", "aligner", "dependency", "source"])
def test_mutation_during_prepare_is_rejected_and_both_owned_workers_close(runtime_setup, kind):
    state = runtime_setup
    path = {
        "asr": state.snapshots[0] / "model.safetensors",
        "aligner": state.snapshots[1] / "model.safetensors",
        "dependency": state.dependency / "library.so",
        "source": state.paths["adapter"],
    }[kind]

    async def mutate():
        path.write_bytes(path.read_bytes() + b"changed")

    state.start_hook = mutate

    async def run():
        with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pytest.fail("published a runtime with changed bytes")
        assert {name for name, _ in state.closed} == {"asr", "aligner"}

    asyncio.run(run())


def test_restored_bytes_and_new_dependency_file_fail_stability_guard(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            path = state.dependency / "library.so"
            before = path.read_bytes()
            path.write_bytes(before + b"x")
            path.write_bytes(before)
            with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
                await runtime.verify()
        # A failed verification poisons the handle and does not skip cleanup.
        assert len(state.closed) == 2

    asyncio.run(run())


@pytest.mark.parametrize("kind", ["generation", "cap", "revision", "aligner_identity"])
def test_actual_ready_owner_evidence_cannot_change(runtime_setup, kind):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            services = state.created[0]
            owner = services.asr_worker.shared_owner
            if kind == "generation":
                owner._generation_guard.advance()
            elif kind == "cap":
                owner._window_decode_max_new_tokens = 256
            elif kind == "revision":
                owner._runtime_revision = "changed"
            else:
                services.text_aligner._client._ready["other"] = True
            with pytest.raises(ValueError, match="ASR runtime owner"):
                runtime.candidate_spec()

    asyncio.run(run())


def test_cancelled_prepare_is_joined_before_private_worker_cleanup(runtime_setup):
    state = runtime_setup

    async def run():
        entered, finish = asyncio.Event(), asyncio.Event()

        async def block():
            entered.set()
            await finish.wait()

        state.start_hook = block

        async def prepare():
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pytest.fail("cancelled preparation was published")

        task = asyncio.create_task(prepare())
        await asyncio.wait_for(entered.wait(), 3)
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done() and not state.closed
        task.cancel()
        finish.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert {name for name, _ in state.closed} == {"asr", "aligner"}
        assert not any(t.get_name().startswith("frozen-asr-") for t in asyncio.all_tasks())

    asyncio.run(run())


@pytest.mark.parametrize(
    "field,value",
    [
        ("qwen3_tts_model_dir", Path("/unused")),
        ("diarization_dynamic_enabled", True),
        ("job_spool_dir", Path("/unused")),
    ],
)
def test_non_asr_components_rejected_before_composition(runtime_setup, field, value):
    state = runtime_setup
    settings = state.settings.model_copy(update={field: value})

    async def run():
        with pytest.raises(ValueError, match="ASR-only"):
            async with state.module.prepare_frozen_asr_runtime(
                settings, dependencies=state.dependencies
            ):
                pass
        assert not state.created

    asyncio.run(run())


def test_rejects_already_hot_result_without_closing_borrowed_worker(runtime_setup, monkeypatch):
    state = runtime_setup
    original = state.module.build_app_services

    def hot(settings, overrides):
        services = original(settings, overrides)
        services.asr_worker.shared_owner._transport._process = SimpleNamespace(returncode=None)
        return services

    monkeypatch.setattr(state.module, "build_app_services", hot)

    async def run():
        with pytest.raises(ValueError, match="cold"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass
        assert not state.closed

    asyncio.run(run())


def test_new_dependency_file_rejected_even_when_existing_files_unchanged(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            (state.dependency / "new_library.so").write_bytes(b"not frozen")
            with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
                await runtime.verify()

    asyncio.run(run())


def test_configuration_change_during_freeze_fails_before_any_loading(runtime_setup, monkeypatch):
    state = runtime_setup
    capture = state.module._Inventory.capture

    def change(roots):
        inventory = capture(roots)
        owner = state.created[0].asr_worker.shared_owner
        owner.config = replace(owner.config, model_dir=state.snapshots[1])
        return inventory

    monkeypatch.setattr(state.module._Inventory, "capture", change)

    async def never_start():
        pytest.fail("started a changed configuration against a different frozen root")

    state.start_hook = never_start

    async def run():
        with pytest.raises(ValueError, match="configuration changed"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass
        assert len(state.closed) == 2

    asyncio.run(run())


def test_unreadable_directory_cannot_disappear_from_preload_inventory(runtime_setup, monkeypatch):
    state = runtime_setup

    def unreadable(root, *, followlinks=False, onerror=None):
        if onerror is not None:
            onerror(PermissionError("private directory must not appear in reports"))
        return iter(())

    monkeypatch.setattr(state.module.os, "walk", unreadable)

    async def run():
        with pytest.raises(ValueError, match="frozen ASR runtime bytes") as caught:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pytest.fail("published a partial directory freeze")
        assert "private directory" not in str(caught.value)
        assert len(state.closed) == 2

    asyncio.run(run())


def test_file_replaced_with_fifo_cannot_block_preload_hash(runtime_setup, tmp_path, monkeypatch):
    state = runtime_setup
    path = tmp_path / "race.bin"
    path.write_bytes(b"regular file before opening")
    original_open = os.open
    flags_seen = []

    def replace_with_fifo(target, flags, *args, **kwargs):
        assert Path(target) == path
        flags_seen.append(flags)
        assert flags & os.O_NONBLOCK and flags & os.O_NOFOLLOW
        path.unlink()
        os.mkfifo(path)
        return original_open(target, flags, *args, **kwargs)

    def forbidden_blocking_open(*args, **kwargs):
        pytest.fail("preload hashing used a potentially blocking path.open")

    monkeypatch.setattr(state.module.os, "open", replace_with_fifo)
    monkeypatch.setattr(Path, "open", forbidden_blocking_open)
    with pytest.raises(ValueError, match="changed while opening"):
        state.module._entry(path, hash_bytes=True)
    assert len(flags_seen) == 1


def test_zero_worker_config_uses_observed_effective_default_cap(runtime_setup, monkeypatch):
    state = runtime_setup
    original = state.module.build_app_services

    def zero_config(settings, overrides):
        services = original(settings, overrides)
        # Exercise the worker's supported zero/default semantics independently
        # of the stricter public config constructor validation.
        object.__setattr__(services.asr_worker.shared_owner.config, "max_new_tokens", 0)
        return services

    monkeypatch.setattr(state.module, "build_app_services", zero_config)

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            assert runtime.candidate_spec().decoder["max_tokens"] == 512

    asyncio.run(run())


@pytest.mark.parametrize("role", ["asr", "aligner"])
def test_effective_worker_environment_mutation_is_rejected(runtime_setup, role):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            services = state.created[0]
            transport = (
                services.asr_worker.shared_owner._transport
                if role == "asr"
                else services.text_aligner._client._process
            )
            transport._spec.env["OMP_NUM_THREADS"] = "different effective setting"
            with pytest.raises(ValueError, match="ASR runtime owner"):
                runtime.candidate_spec()

    asyncio.run(run())


def test_cancelled_preload_hash_thread_finishes_before_private_owners_close(
    runtime_setup, monkeypatch
):
    state = runtime_setup
    entered, finish = threading.Event(), threading.Event()
    original = state.module._Inventory.capture

    def slow_capture(roots):
        inventory = original(roots)
        entered.set()
        assert finish.wait(timeout=3)
        return inventory

    monkeypatch.setattr(state.module._Inventory, "capture", slow_capture)

    async def run():
        async def prepare():
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pytest.fail("cancelled hashing published a runtime")

        task = asyncio.create_task(prepare())
        assert await asyncio.to_thread(entered.wait, 3)
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done() and not state.closed
        finish.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert len(state.closed) == 2

    asyncio.run(run())


def test_missing_dependency_error_hides_private_paths(runtime_setup, tmp_path):
    state = runtime_setup
    roots = state.module.RuntimeDependencyRoots(
        host=(tmp_path / "private-missing-dependency",),
        asr=state.dependencies.asr,
        aligner=state.dependencies.aligner,
    )

    async def run():
        with pytest.raises(ValueError) as caught:
            async with state.module.prepare_frozen_asr_runtime(state.settings, dependencies=roots):
                pass
        assert str(tmp_path) not in str(caught.value)
        assert len(state.closed) == 2

    asyncio.run(run())


@pytest.mark.parametrize("failure", ["symlink_directory", "scan_error"])
def test_source_enumeration_fails_closed_on_incomplete_tree(
    runtime_setup, tmp_path, monkeypatch, failure
):
    state = runtime_setup
    package, perf = tmp_path / "package", tmp_path / "perf"
    (package / "application").mkdir(parents=True)
    perf.mkdir()
    services_file = package / "application/services.py"
    services_file.write_text("# synthetic source")
    runtime_file = perf / "meeting_asr_runtime.py"
    runtime_file.write_text("# synthetic runtime")
    monkeypatch.setattr(state.module.services_module, "__file__", str(services_file))
    monkeypatch.setattr(state.module, "__file__", str(runtime_file))
    if failure == "symlink_directory":
        (package / "linked").symlink_to(perf)
        with pytest.raises(ValueError, match="symlink directories"):
            state.default_source_paths()
    else:

        def unreadable(root, *, followlinks=False, onerror=None):
            if onerror is not None:
                onerror(PermissionError("controlled scan failure"))
            return iter(())

        monkeypatch.setattr(state.module.os, "walk", unreadable)
        with pytest.raises(PermissionError, match="controlled scan failure"):
            state.default_source_paths()


@pytest.mark.parametrize("kind", ["aligner", "source", "dependency", "vad"])
def test_candidate_digest_binds_the_entire_frozen_runtime_closure(runtime_setup, tmp_path, kind):
    state = runtime_setup
    model = tmp_path / "synthetic.onnx"
    model.write_bytes(b"synthetic VAD")
    state.settings = state.settings.model_copy(
        update={
            "realtime_vad_engine": "silero",
            "realtime_vad_model_path": model,
        }
    )
    target = {
        "aligner": state.snapshots[1] / "model.safetensors",
        "source": state.paths["runtime"],
        "dependency": state.dependency / "library.so",
        "vad": model,
    }[kind]

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            before = candidate_digest(runtime.candidate_spec())
        target.write_bytes(target.read_bytes() + b"different closure")
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            after = candidate_digest(runtime.candidate_spec())
        assert before != after

    asyncio.run(run())


@pytest.mark.parametrize("mode", ["mutation", "cached", "cached_alias"])
def test_vad_bytes_and_cold_host_cache_are_guarded(runtime_setup, tmp_path, monkeypatch, mode):
    import speechrail.backends.neural_vad as vad

    state = runtime_setup
    model = tmp_path / "synthetic.onnx"
    model.write_bytes(b"synthetic VAD")
    state.settings = state.settings.model_copy(
        update={
            "realtime_vad_engine": "silero",
            "realtime_vad_model_path": model,
        }
    )
    cache = {}
    if mode.startswith("cached"):
        key = model
        if mode == "cached_alias":
            key = tmp_path / "alias.onnx"
            key.symlink_to(model)
        cache[str(key)] = object()
    monkeypatch.setattr(vad, "_shared_sessions", cache)

    async def run():
        if mode.startswith("cached"):
            with pytest.raises(ValueError, match="cold VAD"):
                async with state.module.prepare_frozen_asr_runtime(
                    state.settings, dependencies=state.dependencies
                ):
                    pytest.fail("borrowed a preloaded VAD model")
            assert not state.created[0].asr_worker.shared_owner.ready
            assert len(cache) == 1
        else:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as runtime:
                model.write_bytes(b"different VAD")
                with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
                    await runtime.verify()
        assert len(state.closed) == 2

    asyncio.run(run())


def test_worker_interpreter_bytes_are_frozen_before_prepare(runtime_setup, tmp_path):
    state = runtime_setup
    python = tmp_path / "python"
    python.write_bytes(b"synthetic executable, never run")
    python.chmod(0o700)
    state.settings = state.settings.model_copy(update={"qwen3_python": python})

    async def mutate():
        python.write_bytes(b"different executable")

    state.start_hook = mutate

    async def run():
        with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass
        assert len(state.closed) == 2

    asyncio.run(run())


def test_replaced_factory_owner_is_rejected_and_never_closed(runtime_setup):
    state = runtime_setup

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            original = state.created[0].asr_worker.shared_owner
            replacement = SimpleNamespace(ready=True)
            state.created[0].window_asr_factory._worker = replacement
            with pytest.raises(ValueError, match="ASR runtime owner"):
                runtime.candidate_spec()
        assert ("asr", original) in state.closed
        assert not any(owner is replacement for _, owner in state.closed)

    asyncio.run(run())


def test_replaced_process_is_not_closed_but_other_confirmed_child_is(runtime_setup):
    state = runtime_setup

    async def run():
        with pytest.raises(RuntimeError, match="cleanup ownership is unconfirmed"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ) as runtime:
                state.created[0].asr_worker.shared_owner._transport._process = SimpleNamespace(
                    returncode=None
                )
                with pytest.raises(ValueError, match="ASR runtime owner"):
                    runtime.candidate_spec()
        assert [name for name, _ in state.closed] == ["aligner"]

    asyncio.run(run())


def test_child_close_failure_still_joins_the_other_child(runtime_setup, monkeypatch):
    state = runtime_setup

    async def fail_close(owner):
        raise RuntimeError("private worker detail must not reach outer exception")

    monkeypatch.setattr(Qwen3SharedWorker, "close", fail_close)

    async def run():
        with pytest.raises(RuntimeError, match="owned ASR runtime child cleanup failed") as caught:
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass
        assert "private worker detail" not in str(caught.value)
        assert [name for name, _ in state.closed] == ["aligner"]

    asyncio.run(run())


def test_directory_symlinks_fail_closed_and_file_symlinks_bind_target(runtime_setup, tmp_path):
    state = runtime_setup
    target = tmp_path / "outside-library.so"
    target.write_bytes(b"outside bytes")
    (state.dependency / "linked-library.so").symlink_to(target)

    async def run():
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            target.write_bytes(b"outside changed")
            with pytest.raises(ValueError, match="frozen ASR runtime bytes"):
                await runtime.verify()
        directory = tmp_path / "outside-directory"
        directory.mkdir()
        (state.dependency / "linked-directory").symlink_to(directory)
        with pytest.raises(ValueError, match="symlink directories"):
            async with state.module.prepare_frozen_asr_runtime(
                state.settings, dependencies=state.dependencies
            ):
                pass

    asyncio.run(run())


@pytest.mark.parametrize(
    "mutate", [None, "asr", "dependency", "source", "generation", "background_cancel"]
)
def test_locked_source_flows_through_production_session_with_measured_spec(
    runtime_setup, tmp_path, monkeypatch, mutate
):
    import wave

    from meeting_asr_source import load_locked_asr_case

    from test_meeting_asr_sidecar import fixture as sidecar_fixture
    from test_meeting_development_fixture import inputs
    from test_meeting_quality_metrics import policy
    from test_meeting_realtime_asr_replay import case

    state = runtime_setup
    original_replay = state.module.replay_realtime_session
    entered, release, context_closing = asyncio.Event(), asyncio.Event(), asyncio.Event()
    original_request = Qwen3SharedWorker.request

    async def blocking_request(owner, frame, binary=None):
        if frame["type"] == "window.decode":
            entered.set()
            await release.wait()
        return await original_request(owner, frame, binary)

    if mutate == "background_cancel":
        monkeypatch.setattr(Qwen3SharedWorker, "request", blocking_request)

    async def replay_then_mutate(*args, **kwargs):
        result = await original_replay(*args, **kwargs)
        assert state.created[0].window_asr_factory._session is None
        if mutate == "generation":
            state.created[0].asr_worker.shared_owner._generation_guard.advance()
        elif mutate is not None and mutate != "background_cancel":
            target = {
                "asr": state.snapshots[0] / "model.safetensors",
                "dependency": state.dependency / "library.so",
                "source": state.paths["adapter"],
            }[mutate]
            target.write_bytes(target.read_bytes() + b"changed after replay")
        return result

    monkeypatch.setattr(state.module, "replay_realtime_session", replay_then_mutate)
    fixture_root = tmp_path / "fixture"
    fixture_root.mkdir()
    manifest, split = inputs(fixture_root)
    artifacts = manifest["fixtures"][0]["artifacts"]
    pcm = case().pcm16
    path = fixture_root / artifacts["pcm"]["path"]
    with wave.open(str(path), "wb") as handle:
        handle.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        handle.writeframes(pcm)
    artifacts["pcm"]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    for kind in ("activity_reference", "text_reference"):
        target = fixture_root / artifacts[kind]["path"]
        value = json.loads(target.read_text())
        value["total_samples"] = len(pcm) // 2
        target.write_text(json.dumps(value))
        artifacts[kind]["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    _, artifacts["asr_sidecar"] = sidecar_fixture(
        fixture_root, pcm_sha256=artifacts["pcm"]["sha256"]
    )
    split["development_manifest_sha256"] = canonical_digest(manifest)
    primary = fixture_root / "primary.json"
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

    async def run():
        background, release_task = None, None
        async with state.module.prepare_frozen_asr_runtime(
            state.settings, dependencies=state.dependencies
        ) as runtime:
            spec = runtime.candidate_spec(language="Chinese")
            locked = load_locked_asr_case(
                manifest,
                split,
                artifact_root=fixture_root,
                scorer_policy=policy(),
                fixture_id="M0",
                candidate_sha256=candidate_digest(spec),
                primary_reference={
                    "path": "primary.json",
                    "sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
                },
            )
            if mutate == "background_cancel":
                background = asyncio.create_task(runtime.evaluate(locked, spec))
                await asyncio.wait_for(entered.wait(), 3)
                original_finish = runtime._finish

                async def marked_finish():
                    context_closing.set()
                    await original_finish()

                monkeypatch.setattr(runtime, "_finish", marked_finish)

                async def finish_decode_after_context_cancels():
                    await context_closing.wait()
                    assert background.cancelling()
                    assert not state.closed
                    release.set()

                release_task = asyncio.create_task(finish_decode_after_context_cancels())
            elif mutate is not None:
                with pytest.raises(ValueError, match=r"runtime (bytes|owner)"):
                    await runtime.evaluate(locked, spec)
            else:
                result = await runtime.evaluate(locked, spec)
                assert result["source_validation"]["bytes_verified"] is True
                assert result["quality_evidence_valid"] is True
                assert result["actual_decode_calls"] > 0
                assert result["runtime_identity_verified"] is False
                assert result["certification_eligible"] is False
                assert result["a0_execution"] == "not_certified"
                assert result["runtime_freeze"]["preload_bytes_frozen"] is True
                assert result["runtime_freeze"]["post_replay_bytes_stable"] is True
                serialized = json.dumps(result)
                assert str(tmp_path) not in serialized
                assert "甲乙" not in serialized
        assert state.created[0].window_asr_factory._session is None
        assert len(state.closed) == 2
        if background is not None:
            await release_task
            with pytest.raises(asyncio.CancelledError):
                await background
            assert not any(t.get_name().startswith("frozen-asr-") for t in asyncio.all_tasks())

    asyncio.run(run())
