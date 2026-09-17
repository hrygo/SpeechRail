"""Deterministic tests for the service-owned physical footprint sampler."""

from __future__ import annotations

import pytest

from speechrail.runtime import resource_observability

_PS_OUTPUT = "\n".join(
    [
        "    1     0",
        "  100     1",
        "  300   100",
        " 4242   100",
    ]
)


class _FakePs:
    """Stand in for the ``ps`` collector so the test never spawns a process."""

    pid = 4242
    returncode = 0

    def __init__(self, command: tuple[str, ...], **_kwargs: object) -> None:
        self.command = command

    def communicate(self, timeout: float | None = None) -> tuple[str, str]:
        return _PS_OUTPUT, ""

    def kill(self) -> None:
        raise AssertionError("the fake collector never times out")


def test_service_process_ids_skips_the_collector_itself(monkeypatch: pytest.MonkeyPatch) -> None:
    """Regression: keeping the transient ``ps`` child hid every footprint reading."""
    monkeypatch.setattr(resource_observability.subprocess, "Popen", _FakePs)

    assert resource_observability._service_process_ids(100) == (100, 300)


def test_service_physical_footprint_sums_every_service_process(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(resource_observability, "_service_process_ids", lambda _pid: (100, 300))
    monkeypatch.setattr(
        resource_observability.shutil, "which", lambda _name: "/usr/bin/footprint"
    )
    values = {100: 1000, 300: 2000}
    monkeypatch.setattr(
        resource_observability, "_read_footprint", lambda _tool, pid: values.get(pid)
    )

    assert resource_observability.service_physical_footprint() == (
        3000,
        "macos_footprint",
        True,
        2,
    )


def test_service_physical_footprint_stays_incomplete_when_one_process_is_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(resource_observability, "_service_process_ids", lambda _pid: (100, 300))
    monkeypatch.setattr(
        resource_observability.shutil, "which", lambda _name: "/usr/bin/footprint"
    )
    monkeypatch.setattr(
        resource_observability,
        "_read_footprint",
        lambda _tool, pid: 1000 if pid == 100 else None,
    )

    assert resource_observability.service_physical_footprint() == (
        None,
        "macos_footprint_incomplete",
        False,
        2,
    )


def test_service_physical_footprint_is_unavailable_without_the_tool(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(resource_observability, "_service_process_ids", lambda _pid: (100,))
    monkeypatch.setattr(resource_observability.shutil, "which", lambda _name: None)

    assert resource_observability.service_physical_footprint() == (
        None,
        "unavailable",
        False,
        1,
    )
