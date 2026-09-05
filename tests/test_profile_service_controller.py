from __future__ import annotations

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
    controller = LaunchAgentServiceController(loaded)
    controller.stop()
    controller.start()
    assert loaded.calls == ["status", "disable", "enable"]

    stopped = FakeManager(loaded=False)
    controller = LaunchAgentServiceController(stopped)
    controller.stop()
    controller.start()
    assert stopped.calls == ["status", "enable"]
