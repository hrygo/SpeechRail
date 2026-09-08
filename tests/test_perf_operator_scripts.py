from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_realtime


class _FakeConnection:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


class _FakeRealtime:
    def __init__(self, connection: _FakeConnection) -> None:
        self.connection = connection

    def connect(self, *, model: str) -> _FakeRealtime:
        assert model == "whisper-1"
        return self

    def enter(self) -> _FakeConnection:
        return self.connection


class _FakeClient:
    def __init__(self, connection: _FakeConnection) -> None:
        self.realtime = _FakeRealtime(connection)


def test_realtime_session_closes_connection_after_measurement_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _FakeConnection()

    def fail(*args: object, **kwargs: object) -> dict[str, object]:
        raise RuntimeError("measurement failed")

    monkeypatch.setattr(bench_realtime, "_run_connected_session", fail)

    with pytest.raises(RuntimeError, match="measurement failed"):
        bench_realtime.run_session(_FakeClient(connection), b"pcm", "text", 1)  # type: ignore[arg-type]

    assert connection.closed is True
