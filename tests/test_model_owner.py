from __future__ import annotations

import asyncio

import pytest

from speechrail.runtime.model_owner import (
    ModelOwner,
    ModelOwnerDrainingError,
    ModelOwnerIdentityError,
    ModelOwnerKey,
    ModelOwnerNotRegisteredError,
    ModelOwnerRegistry,
    OwnerState,
)


def _key(**overrides: str) -> ModelOwnerKey:
    base = {
        "artifact_key": "tts-1.7b-custom-q8",
        "artifact_revision": "rev-a",
        "engine_revision": "engine-1",
        "compute_config": "mps-fp16",
    }
    base.update(overrides)
    return ModelOwnerKey(**base)


class _FakeModel:
    def __init__(self, name: str) -> None:
        self.name = name


def test_owner_key_rejects_blank_identity_fields() -> None:
    with pytest.raises(ValueError):
        _key(engine_revision="  ")


def test_key_stable_id_is_stable_and_path_free() -> None:
    key = _key()
    assert key.stable_id == "tts-1.7b-custom-q8|rev-a|engine-1|mps-fp16"
    assert "/" not in key.stable_id
    assert dict(key.identity())["artifact_key"] == "tts-1.7b-custom-q8"


def test_concurrent_acquire_loads_weights_once_and_shares_one_instance() -> None:
    async def scenario() -> None:
        loads: list[str] = []
        release = asyncio.Event()
        entered = asyncio.Event()

        async def load() -> object:
            loads.append("load")
            entered.set()
            await release.wait()
            return _FakeModel("shared")

        owner = ModelOwner(_key(), load=load)
        seen: list[object] = []

        async def user() -> None:
            async with owner.lease() as model:
                seen.append(model)
                await asyncio.sleep(0)

        first = asyncio.create_task(user())
        await entered.wait()
        second = asyncio.create_task(user())
        third = asyncio.create_task(user())
        await asyncio.sleep(0)
        release.set()
        await asyncio.gather(first, second, third)

        assert loads == ["load"]
        assert len(seen) == 3
        assert all(model is seen[0] for model in seen)
        assert owner.state is OwnerState.READY
        assert owner.active_leases == 0

    asyncio.run(scenario())


def test_reference_count_tracks_active_leases_and_blocks_drain() -> None:
    async def scenario() -> None:
        owner = ModelOwner(_key(), load=lambda: _resolved(_FakeModel("m")))
        drained = asyncio.Event()

        async def long_lease() -> None:
            async with owner.lease():
                assert owner.active_leases == 1
                assert owner.state is OwnerState.BUSY
                await asyncio.sleep(0.05)

        lease_task = asyncio.create_task(long_lease())
        await asyncio.sleep(0)
        drain_task = asyncio.create_task(owner.begin_drain())
        drain_task.add_done_callback(lambda _: drained.set())
        await asyncio.sleep(0)
        assert not drained.is_set()
        assert owner.state is OwnerState.DRAINING
        await lease_task
        await drain_task
        assert owner.state is OwnerState.DRAINING
        assert owner.active_leases == 0

    asyncio.run(scenario())


def test_identity_mismatch_fails_closed_and_allows_retry() -> None:
    async def scenario() -> None:
        attempts = {"n": 0}

        async def load() -> object:
            attempts["n"] += 1
            if attempts["n"] == 1:
                return _FakeModel("wrong")
            return _FakeModel("right")

        def verify(model: object) -> dict[str, object]:
            if model.name == "wrong":
                return {"artifact_revision": "rev-other"}
            return dict(_key().identity())

        owner = ModelOwner(_key(), load=load, verify=verify)
        with pytest.raises(ModelOwnerIdentityError):
            async with owner.lease():
                pass
        assert owner.state is OwnerState.FAILED
        assert owner.model is None

        async with owner.lease() as model:
            assert model.name == "right"
        assert owner.state is OwnerState.READY

    asyncio.run(scenario())


def test_new_lease_while_draining_is_rejected() -> None:
    async def scenario() -> None:
        owner = ModelOwner(_key(), load=lambda: _resolved(_FakeModel("m")))
        await owner.begin_drain()
        with pytest.raises(ModelOwnerDrainingError):
            async with owner.lease():
                pass

    asyncio.run(scenario())


def test_cancel_and_error_release_the_lease_exactly_once() -> None:
    async def scenario() -> None:
        closes: list[str] = []

        async def close(model: object) -> None:
            closes.append(model.name)

        owner = ModelOwner(
            _key(), load=lambda: _resolved(_FakeModel("m")), close=close
        )

        async def cancelled() -> None:
            async with owner.lease():
                await asyncio.sleep(1)

        task = asyncio.create_task(cancelled())
        await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert owner.active_leases == 0
        assert owner.state is OwnerState.READY

        with pytest.raises(RuntimeError):
            async with owner.lease():
                raise RuntimeError("boom")
        assert owner.active_leases == 0
        assert owner.state is OwnerState.READY

        # A single unload (drain) closes the still-resident model exactly once.
        await owner.begin_drain()
        assert closes == ["m"]

    asyncio.run(scenario())


def test_timeout_while_holding_a_lease_releases_exactly_once() -> None:
    async def scenario() -> None:
        releases: list[int] = []

        async def user(owner: ModelOwner) -> None:
            async with owner.lease():
                releases.append(1)
                await asyncio.sleep(1)

        owner = ModelOwner(_key(), load=lambda: _resolved(_FakeModel("m")))
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(user(owner), timeout=0.05)
        assert releases == [1]
        # The bound was cancelled, not the owner: the lease counter returned to 0
        # and the still-resident weights never require a second load.
        assert owner.active_leases == 0
        assert owner.state is OwnerState.READY
        async with owner.lease():
            pass
        assert owner.active_leases == 0

    asyncio.run(scenario())


def test_stop_unloads_and_permits_a_fresh_handshake() -> None:
    async def scenario() -> None:
        loads = {"n": 0}

        async def load() -> object:
            loads["n"] += 1
            return _FakeModel(f"m{loads['n']}")

        owner = ModelOwner(_key(), load=load)
        async with owner.lease():
            pass
        assert loads["n"] == 1
        await owner.stop()
        assert owner.state is OwnerState.UNLOADED
        async with owner.lease() as model:
            assert model.name == "m2"
        assert loads["n"] == 2

    asyncio.run(scenario())


def test_registry_isolates_compute_configs_but_shares_artifact_group() -> None:
    async def scenario() -> None:
        registry = ModelOwnerRegistry()
        registry.register(ModelOwner(_key(), load=lambda: _resolved(_FakeModel("a"))))
        registry.register(
            ModelOwner(
                _key(compute_config="cpu-fp32"), load=lambda: _resolved(_FakeModel("b"))
            )
        )
        with pytest.raises(ModelOwnerNotRegisteredError):
            async with registry.acquire(_key(artifact_revision="rev-b")):
                pass

        async with registry.acquire(_key()) as model_a:
            assert model_a.name == "a"
        async with registry.acquire(_key(compute_config="cpu-fp32")) as model_b:
            assert model_b.name == "b"

        assert len(registry.by_artifact("tts-1.7b-custom-q8")) == 2
        await registry.stop_all()

    asyncio.run(scenario())


def test_registry_drain_artifact_drops_only_matching_owners() -> None:
    async def scenario() -> None:
        registry = ModelOwnerRegistry()
        registry.register(ModelOwner(_key(), load=lambda: _resolved(_FakeModel("a"))))
        registry.register(
            ModelOwner(
                _key(artifact_key="asr-1.7b-q8"), load=lambda: _resolved(_FakeModel("c"))
            )
        )
        async with registry.acquire(_key()):
            pass
        states = registry.states()
        assert states[_key()] is OwnerState.READY
        await registry.drain_artifact("tts-1.7b-custom-q8")
        states = registry.states()
        assert states[_key()] is OwnerState.DRAINING
        # The unrelated owner was never drained and never loaded here.
        assert states[_key(artifact_key="asr-1.7b-q8")] is not OwnerState.DRAINING

    asyncio.run(scenario())


async def _resolved(value: object) -> object:
    return value


def test_owner_key_is_derived_from_artifact_identity_not_voice() -> None:
    from types import SimpleNamespace

    artifact = SimpleNamespace(
        key="tts-1.7b-custom-q8", revision="08b854525817066e04ef6b6430a3faa0eebd24d2"
    )
    a = ModelOwnerKey.from_artifact(artifact, engine_revision="e1", compute_config="mps-fp16")
    b = ModelOwnerKey.from_artifact(artifact, engine_revision="e1", compute_config="mps-fp16")
    # Two voices resolving to the same artifact produce the same owner key.
    assert a == b
    assert a.artifact_revision == artifact.revision
    # A different engine revision or compute config isolates residency.
    assert a != ModelOwnerKey.from_artifact(
        artifact, engine_revision="e2", compute_config="mps-fp16"
    )
    assert a != ModelOwnerKey.from_artifact(
        artifact, engine_revision="e1", compute_config="cpu-fp32"
    )


def test_owner_key_from_artifact_rejects_unpinned_revision() -> None:
    from types import SimpleNamespace

    with pytest.raises(ValueError):
        ModelOwnerKey.from_artifact(
            SimpleNamespace(key="tts-1.7b-custom-q8", revision="  "),
            engine_revision="e1",
            compute_config="mps-fp16",
        )
