"""Batch-governed execution of durable jobs through an injected trusted processor."""

from __future__ import annotations

import re
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Protocol

from speechrail.runtime.jobs import JobKind, JobRecord, JobRepository
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass

_JOB_TIMEOUT_MESSAGE = "job exceeded the processing deadline"
_JOB_PROCESSOR_FAILED_MESSAGE = "job processor failed"
_URL_PATTERN = re.compile(r"(?:https?|file)://\S+", re.IGNORECASE)
_PATH_PATTERN = re.compile(r"(?<![\w])/(?:[^\s/]+/)*[^\s/]+")
_EMAIL_PATTERN = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_CONTROL_PATTERN = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_WHITESPACE_PATTERN = re.compile(r"\s+")


def sanitize_error_message(text: str, *, limit: int = 256) -> str:
    """Reduce untrusted text to a bounded, deterministic public error message."""
    if limit <= 0:
        raise ValueError("limit must be positive")
    scrubbed = _CONTROL_PATTERN.sub(" ", text)
    scrubbed = _URL_PATTERN.sub("<url>", scrubbed)
    scrubbed = _PATH_PATTERN.sub("<path>", scrubbed)
    scrubbed = _EMAIL_PATTERN.sub("<email>", scrubbed)
    scrubbed = _WHITESPACE_PATTERN.sub(" ", scrubbed).strip()
    return scrubbed[:limit]


class JobProcessor(Protocol):
    """Resolves an opaque job request and returns an opaque result reference."""

    async def process(self, job: JobRecord) -> str: ...


class JobProcessingError(Exception):
    """Processor rejection that carries a bounded, public error code.

    ``JobRunner`` records ``error_code`` verbatim; an optional curated ``message``
    is sanitized before persistence, and any other exception collapses to the
    generic ``job_processor_failed`` code so untrusted processor detail never
    reaches the durable record.
    """

    def __init__(self, error_code: str, message: str | None = None) -> None:
        if not error_code or len(error_code) > 200:
            raise ValueError("error_code must be between one and 200 characters")
        super().__init__(error_code)
        self.error_code = error_code
        self.message = message


class JobRunner:
    """Claims at most one job per invocation and never interprets input references."""

    def __init__(
        self,
        *,
        repository: JobRepository,
        governor: ResourceGovernor,
        processor: JobProcessor,
        deadline_seconds: float,
        result_ttl_seconds: float | None = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        if deadline_seconds <= 0:
            raise ValueError("deadline_seconds must be positive")
        if result_ttl_seconds is not None and result_ttl_seconds <= 0:
            raise ValueError("result_ttl_seconds must be positive")
        self._repository = repository
        self._governor = governor
        self._processor = processor
        self._deadline_seconds = deadline_seconds
        self._result_ttl_seconds = result_ttl_seconds
        self._clock = clock or (lambda: datetime.now(UTC))
        self._last_kind: JobKind | None = None

    async def run_once(self) -> bool:
        # Expiry runs before claiming so the idle poll loop also ages results
        # out even when no queued work exists.
        self._expire_completed_results()
        prefer_kind = _other_kind(self._last_kind)
        job = self._repository.claim_next(prefer_kind=prefer_kind)
        if job is None:
            return False
        self._last_kind = job.kind
        work_class = WorkClass.BATCH_TTS if job.kind == "speech" else WorkClass.BATCH_ASR
        try:
            result_ref = await self._governor.run(
                lambda: self._processor.process(job),
                work_class,
                deadline=self._deadline_seconds,
            )
            self._repository.complete(job.id, result_ref=result_ref)
        except JobProcessingError as exc:
            self._repository.fail(
                job.id,
                error_code=exc.error_code,
                error_message=(
                    sanitize_error_message(exc.message)
                    if exc.message is not None
                    else None
                ),
            )
        except TimeoutError:
            self._repository.fail(
                job.id,
                error_code="job_timeout",
                error_message=_JOB_TIMEOUT_MESSAGE,
            )
        except Exception:
            self._repository.fail(
                job.id,
                error_code="job_processor_failed",
                error_message=_JOB_PROCESSOR_FAILED_MESSAGE,
            )
        return True

    def _expire_completed_results(self) -> None:
        if self._result_ttl_seconds is None:
            return
        before = (self._clock() - timedelta(seconds=self._result_ttl_seconds)).isoformat()
        self._repository.expire_completed(before=before)


def _other_kind(kind: JobKind | None) -> JobKind | None:
    if kind is None:
        return None
    return "transcription" if kind == "speech" else "speech"


__all__ = [
    "JobProcessingError",
    "JobProcessor",
    "JobRunner",
    "sanitize_error_message",
]
