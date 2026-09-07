from __future__ import annotations

import pytest

from speechrail.service import lifecycle
from speechrail.service.launchd import ServiceError
from speechrail.service.profile_switch import LaunchAgentServiceController


class FakeManager:
    def __init__(self, *, loaded: bool) -> None:
        self.loaded = loaded
        self.calls: list[str] = []

    def status(self) -> str:
        self.calls.append("status")
        if not self.loaded:
            raise ServiceError("not loaded")
        return "running"

    def disable(self) -> None:
        self.calls.append("disable")
        self.loaded = False

    def enable(self) -> None:
        self.calls.append("enable")
        self.loaded = True


def test_controller_stops_only_a_loaded_service_and_always_starts() -> None:
    loaded = FakeManager(loaded=True)
    delays: list[float] = []
    controller = LaunchAgentServiceController(loaded, sleeper=delays.append)
    controller.stop()
    controller.start()
    assert loaded.calls == ["status", "disable", "enable"]
    assert delays == []

    stopped = FakeManager(loaded=False)
    controller = LaunchAgentServiceController(stopped, sleeper=delays.append)
    controller.stop()
    controller.start()
    assert stopped.calls == ["status", "enable"]
    assert delays == []


def test_controller_without_port_does_not_sleep_after_bootout() -> None:
    manager = FakeManager(loaded=True)
    delays: list[float] = []

    LaunchAgentServiceController(manager, sleeper=delays.append).stop()

    assert manager.calls == ["status", "disable"]
    assert delays == []


def test_controller_waits_for_previous_process_lock_before_restarting(monkeypatch) -> None:
    class FakePortLock:
        attempts = 0

        def __init__(self, port: int) -> None:
            assert port == 8201

        def __enter__(self):
            type(self).attempts += 1
            if self.attempts < 3:
                raise lifecycle.ServerInstanceError("server_already_running")
            return self

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(lifecycle, "ServerInstanceLock", FakePortLock)
    loaded = FakeManager(loaded=True)
    delays: list[float] = []
    controller = LaunchAgentServiceController(
        loaded,
        port=8201,
        sleeper=delays.append,
    )

    controller.stop()
    controller.start()

    assert loaded.calls == ["status", "disable", "enable"]
    assert FakePortLock.attempts == 4
    assert delays == [0.25, 0.25]


def test_controller_fails_bounded_when_previous_process_never_releases(monkeypatch) -> None:
    class StuckPortLock:
        def __init__(self, port: int) -> None:
            assert port == 8201

        def __enter__(self):
            raise lifecycle.ServerInstanceError("server_already_running")

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(lifecycle, "ServerInstanceLock", StuckPortLock)
    loaded = FakeManager(loaded=True)
    now = 0.0
    delays: list[float] = []

    def clock() -> float:
        return now

    def sleep(delay: float) -> None:
        nonlocal now
        delays.append(delay)
        now += delay

    controller = LaunchAgentServiceController(
        loaded,
        port=8201,
        sleeper=sleep,
        clock=clock,
        graceful_stop_timeout_seconds=0.5,
        force_kill_timeout_seconds=0.5,
    )

    with pytest.raises(ServiceError, match="previous service instance did not stop"):
        controller.stop()

    assert loaded.calls == ["status", "disable"]
    assert delays == [0.25, 0.25]


def test_controller_force_kills_exact_service_group_after_graceful_timeout(monkeypatch) -> None:
    class LoadedManager(FakeManager):
        def status(self) -> str:
            self.calls.append("status")
            if not self.loaded:
                raise ServiceError("not loaded")
            return "pid = 4242"

    class StalledUntilKilledLock:
        killed = False

        def __init__(self, port: int) -> None:
            assert port == 8201

        def __enter__(self):
            if not type(self).killed:
                raise lifecycle.ServerInstanceError("server_already_running")
            return self

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(lifecycle, "ServerInstanceLock", StalledUntilKilledLock)
    manager = LoadedManager(loaded=True)
    now = 0.0
    delays: list[float] = []
    killed: list[int] = []

    def clock() -> float:
        return now

    def sleep(delay: float) -> None:
        nonlocal now
        delays.append(delay)
        now += delay

    def kill(pid: int) -> None:
        killed.append(pid)
        StalledUntilKilledLock.killed = True

    controller = LaunchAgentServiceController(
        manager,
        port=8201,
        sleeper=sleep,
        clock=clock,
        graceful_stop_timeout_seconds=0.5,
        force_kill_timeout_seconds=0.5,
        process_killer=kill,
    )

    controller.stop()

    assert manager.calls == ["status", "disable"]
    assert killed == [4242]
    assert delays == [0.25, 0.25]


def test_controller_recovers_a_validated_owner_when_launchd_status_is_unavailable(
    monkeypatch,
) -> None:
    class StalledPortLock:
        killed = False

        def __init__(self, port: int) -> None:
            assert port == 8201

        def __enter__(self):
            if not type(self).killed:
                raise lifecycle.ServerInstanceError("server_already_running")
            return self

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(lifecycle, "ServerInstanceLock", StalledPortLock)
    manager = FakeManager(loaded=False)
    now = 0.0
    delays: list[float] = []
    killed: list[int] = []

    def clock() -> float:
        return now

    def sleep(delay: float) -> None:
        nonlocal now
        delays.append(delay)
        now += delay

    def kill(pid: int) -> None:
        killed.append(pid)
        StalledPortLock.killed = True

    controller = LaunchAgentServiceController(
        manager,
        port=8201,
        sleeper=sleep,
        clock=clock,
        graceful_stop_timeout_seconds=0.5,
        force_kill_timeout_seconds=0.5,
        process_killer=kill,
        owner_pid_resolver=lambda port: 4242,
    )

    controller.stop()

    assert manager.calls == ["status"]
    assert killed == [4242]
    assert delays == [0.25, 0.25]
