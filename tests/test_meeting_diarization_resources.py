"""A waiter ending never certifies that native compute has stopped."""

import asyncio
from pathlib import Path

import pytest

from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    ResourceGovernor,
    WorkClass,
)


@pytest.mark.anyio
async def test_asr_quarantine_refuses_new_compute_and_wakes_existing_waiters():
    governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
    async with governor.reserve(WorkClass.REALTIME_ASR):

        async def waiting():
            async with governor.reserve(WorkClass.REALTIME_ASR):
                pass

        task = asyncio.create_task(waiting())
        await asyncio.sleep(0)
        governor.quarantine_asr_lane()
        with pytest.raises(GovernorLaneIsolatedError):
            await task
    with pytest.raises(GovernorLaneIsolatedError):
        async with governor.reserve(WorkClass.REALTIME_TTS):
            pass


@pytest.mark.anyio
async def test_failed_reap_retains_the_exact_child_reference():
    class Child:
        returncode = None

        async def wait(self):
            raise OSError("injected reap failure")

    child = Child()
    worker = CoreMLWorkerProcess(executable=Path("worker"), model_path=Path("model"))
    worker.process = child
    with pytest.raises(OSError):
        await worker.close()
    assert worker.process is child
