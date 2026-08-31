"""Batch-governed execution of durable jobs through an injected trusted processor."""

from __future__ import annotations

from typing import Protocol

from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass


class JobProcessor(Protocol):
    """Resolves an opaque job request and returns an opaque result reference."""

    async def process(self, job: JobRecord) -> str: ...


class JobRunner:
    """Claims at most one job per invocation and never interprets input references."""

    def __init__(
        self,
        *,
        repository: JobRepository,
        governor: ResourceGovernor,
        processor: JobProcessor,
        deadline_seconds: float,
    ) -> None:
        if deadline_seconds <= 0:
            raise ValueError("deadline_seconds must be positive")
        self._repository = repository
        self._governor = governor
        self._processor = processor
        self._deadline_seconds = deadline_seconds

    async def run_once(self) -> bool:
        job = self._repository.claim_next()
        if job is None:
            return False
        work_class = WorkClass.BATCH_TTS if job.kind == "speech" else WorkClass.BATCH_ASR
        try:
            result_ref = await self._governor.run(
                lambda: self._processor.process(job),
                work_class,
                deadline=self._deadline_seconds,
            )
            self._repository.complete(job.id, result_ref=result_ref)
        except TimeoutError:
            self._repository.fail(job.id, error_code="job_timeout")
        except Exception:
            self._repository.fail(job.id, error_code="job_processor_failed")
        return True
