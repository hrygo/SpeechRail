from __future__ import annotations

import asyncio

import pytest

from speechrail.runtime.alignment_admission import AlignmentAdmission, AlignmentAdmissionFullError


def test_alignment_admission_rejects_the_fourth_concurrent_request_and_recovers() -> None:
    async def scenario() -> None:
        admission = AlignmentAdmission(limit=3)
        release = asyncio.Event()
        entered = asyncio.Event()
        count = 0

        async def hold() -> None:
            nonlocal count
            async with admission.reserve():
                count += 1
                if count == 3:
                    entered.set()
                await release.wait()

        holders = [asyncio.create_task(hold()) for _ in range(3)]
        await entered.wait()
        assert admission.active == 3
        with pytest.raises(AlignmentAdmissionFullError):
            async with admission.reserve():
                raise AssertionError("full admission must not enter")
        release.set()
        await asyncio.gather(*holders)
        assert admission.active == 0
        async with admission.reserve():
            assert admission.active == 1

    asyncio.run(scenario())
