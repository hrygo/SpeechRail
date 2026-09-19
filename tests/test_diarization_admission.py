from __future__ import annotations

import asyncio

import pytest

from speechrail.runtime.busy import BusyReason
from speechrail.runtime.diarization_admission import (
    DiarizationAdmission,
    DiarizationAdmissionFullError,
)


def test_diarization_admission_rejects_a_second_session_and_releases_after_close() -> None:
    async def scenario() -> None:
        admission = DiarizationAdmission()
        release = asyncio.Event()
        entered = asyncio.Event()

        async def hold_first_session() -> None:
            async with admission.reserve():
                entered.set()
                await release.wait()

        first = asyncio.create_task(hold_first_session())
        await entered.wait()
        assert admission.active == 1
        with pytest.raises(DiarizationAdmissionFullError) as caught:
            async with admission.reserve():
                raise AssertionError("second diarization session must not start")
        assert caught.value.busy_reason == BusyReason.DIARIZATION_CAPACITY
        assert caught.value.retryable is True

        release.set()
        await first
        async with admission.reserve():
            assert admission.active == 1
        assert admission.active == 0

    asyncio.run(scenario())
