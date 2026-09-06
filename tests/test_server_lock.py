from __future__ import annotations

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
