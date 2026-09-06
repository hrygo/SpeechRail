from __future__ import annotations

import os
from pathlib import Path

import pytest

from speechrail.runtime.server_lock import ServerInstanceError, ServerInstanceLock


def test_server_lock_rejects_a_second_process_for_the_same_port(tmp_path: Path) -> None:
    first = ServerInstanceLock(8201, directory=tmp_path)
    first.acquire()
    try:
        with pytest.raises(ServerInstanceError, match="server_already_running"), ServerInstanceLock(
            8201, directory=tmp_path
        ):
            pass
    finally:
        first.release()

    with ServerInstanceLock(8201, directory=tmp_path):
        pass


def test_server_lock_records_owner_while_held_and_clears_it_on_release(
    tmp_path: Path,
) -> None:
    lock = ServerInstanceLock(8201, directory=tmp_path)

    lock.acquire()
    try:
        owner = ServerInstanceLock.read_owner(8201, directory=tmp_path)
        assert owner is not None
        assert owner.pid == os.getpid()
        assert owner.role == "speechrail-serve"
        assert owner.executable
    finally:
        lock.release()

    assert ServerInstanceLock.read_owner(8201, directory=tmp_path) is None
