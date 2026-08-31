from __future__ import annotations

import asyncio
from pathlib import Path

from speechrail.runtime.job_runner import JobRunner
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.resource_governor import GovernorLimits, ResourceGovernor


def test_job_runner_completes_claimed_work_in_the_matching_batch_lane(tmp_path: Path) -> None:
    class FakeProcessor:
        async def process(self, job: JobRecord) -> str:
            assert job.kind == "speech"
            assert job.request == {"input_ref": "opaque"}
            return "result://speech/job-1"

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FakeProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        completed = repository.get(job.id, owner="owner-a")
        assert completed is not None
        assert completed.state == "completed"
        assert completed.result_ref == "result://speech/job-1"
        assert not await runner.run_once()

    asyncio.run(scenario())


def test_job_runner_records_a_bounded_processor_failure(tmp_path: Path) -> None:
    class FailingProcessor:
        async def process(self, job: JobRecord) -> str:
            del job
            raise RuntimeError("untrusted detail")

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(
            kind="transcription",
            owner="owner-a",
            request={"input_ref": "opaque"},
        )
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FailingProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        failed = repository.get(job.id, owner="owner-a")
        assert failed is not None
        assert failed.state == "failed"
        assert failed.error_code == "job_processor_failed"

    asyncio.run(scenario())
