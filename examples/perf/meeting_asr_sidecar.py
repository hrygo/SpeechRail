"""Bounded fixed-ASR sidecar input for locked diarization comparisons.

Only text and producer timing enter the runner. Reference labels are forbidden.
Verified bytes and declared identity bindings do not prove producer provenance,
actual current-run ASR, or joint product latency. No model is launched here.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import stat
from collections.abc import Iterator, Mapping
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO

from meeting_candidate_evidence import CompletedText
from meeting_candidate_runner import ScheduledText

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.types import TextUnit

_ROOT = Path(__file__).resolve().parents[2]
_SHA = re.compile(r"[0-9a-f]{64}")
_ROW_KEYS = {
    "sequence",
    "text",
    "start_sample",
    "end_sample",
    "ready_after_sample",
    "finish_only",
    "units",
}
_TIMING_ALGORITHM = "sha256_timing_row_digests_v1"
_MAX_LINE = 65536
_MAX_BYTES = 256 * 1024 * 1024
_MAX_ROWS = 100000


_TIMING_PREFIX = (_TIMING_ALGORITHM + "\0").encode("ascii")


def _timing_bytes(row: Mapping[str, Any]) -> bytes:
    timing = {key: row[key] for key in sorted(_ROW_KEYS - {"text"})}
    encoded = json.dumps(timing, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return hashlib.sha256(encoded).digest()


def timing_digest(rows: Iterator[Mapping[str, Any]]) -> str:
    """Hash ordered timing-row digests, excluding text and the self-referencing header."""
    digest = hashlib.sha256(_TIMING_PREFIX)
    for row in rows:
        digest.update(_timing_bytes(row))
    return digest.hexdigest()


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("sidecar JSON contains duplicate keys")
        result[key] = value
    return result


def _read(handle: BinaryIO) -> tuple[bytes, dict[str, Any] | None]:
    raw = handle.readline(_MAX_LINE + 1)
    if not raw:
        return raw, None
    if len(raw) > _MAX_LINE or not raw.endswith(b"\n"):
        raise ValueError("sidecar line is oversized or incomplete")
    try:
        value = json.loads(raw, object_pairs_hook=_pairs)
    except ValueError, UnicodeError:
        raise ValueError("sidecar JSON is invalid") from None
    if not isinstance(value, dict):
        raise ValueError("sidecar record must be an object")
    return raw, value


def _integer(value: Any) -> int:
    if type(value) is not int or value < 0:
        raise ValueError("sidecar timing and offsets require nonnegative integers")
    return value


def _decode(row: dict[str, Any], total: int) -> ScheduledText:
    if set(row) != _ROW_KEYS or not isinstance(row["text"], str) or not row["text"]:
        raise ValueError("sidecar text fields differ from schema")
    sequence, start, end, ready = (
        _integer(row[k]) for k in ("sequence", "start_sample", "end_sample", "ready_after_sample")
    )
    if not 0 <= start < end <= ready <= total or end - start > 30 * 16000:
        raise ValueError("sidecar text requires bounded causal ASR timing")
    if type(row["finish_only"]) is not bool or not isinstance(row["units"], list):
        raise ValueError("sidecar finish phase or word evidence invalid")
    if len(row["units"]) > 4096:
        raise ValueError("sidecar word evidence exceeds budget")
    units = []
    cursor = 0
    for i, unit in enumerate(row["units"]):
        if not isinstance(unit, dict) or set(unit) != {
            "text_start",
            "text_end",
            "start_sample",
            "end_sample",
        }:
            raise ValueError("sidecar word evidence fields invalid")
        a, b, sa, sb = (
            _integer(unit[k]) for k in ("text_start", "text_end", "start_sample", "end_sample")
        )
        if not cursor <= a < b <= len(row["text"]) or not start <= sa < sb <= end:
            raise ValueError("sidecar word evidence is outside actual text or timing")
        if any(c.isalnum() for c in row["text"][cursor:a]):
            raise ValueError("sidecar word evidence omits text")
        units.append(TextUnit(f"u_{sequence}_{i}", a, b, SampleSpan(sa, sb)))
        cursor = b
    if units and (
        any(c.isalnum() for c in row["text"][cursor:])
        or (len(units) > 1 and len({u.audio_span for u in units}) == 1)
    ):
        raise ValueError("sidecar word evidence is incomplete or repeats an utterance grid")
    return ScheduledText(
        ready,
        CompletedText(sequence, row["text"], SampleSpan(start, end), tuple(units)),
        row["finish_only"],
    )


class LockedASRSidecar(Iterator[ScheduledText]):
    """Two bounded passes over one open descriptor; proof requires consumed EOF."""

    def __init__(
        self,
        handle: BinaryIO,
        path: Path,
        descriptor: dict[str, str],
        pcm_sha256: str,
        total_samples: int,
    ) -> None:
        self._handle, self._path, self._descriptor = handle, path, descriptor
        self._pcm, self._total = pcm_sha256, total_samples
        self._stamp = os.fstat(handle.fileno())
        if not stat.S_ISREG(self._stamp.st_mode) or self._stamp.st_size > _MAX_BYTES:
            raise ValueError("sidecar must be a bounded regular file")
        self._verified = self._closed = False
        self._reset()
        for _ in self:
            pass
        self._check_unchanged()
        handle.seek(0)
        self._reset()

    def _reset(self) -> None:
        self._digest, self._timing = hashlib.sha256(), hashlib.sha256(_TIMING_PREFIX)
        self._count = self._bytes = self._ready = 0
        self._finishing = self._header_read = self._verified = False

    def _check_unchanged(self) -> None:
        for current in (os.fstat(self._handle.fileno()), self._path.stat(follow_symlinks=False)):
            if any(
                getattr(current, key) != getattr(self._stamp, key)
                for key in ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
            ):
                raise ValueError("sidecar changed during consumption")

    def __next__(self) -> ScheduledText:
        if self._closed or self._verified:
            raise StopIteration
        self._check_unchanged()
        raw, row = _read(self._handle)
        self._bytes += len(raw)
        if self._bytes > _MAX_BYTES:
            raise ValueError("sidecar exceeds byte budget")
        self._digest.update(raw)
        if not self._header_read:
            expected = {
                "schema_version": 1,
                "kind": "fixed_asr_sidecar",
                "sample_rate": 16000,
                "pcm_sha256": self._pcm,
                "timing_algorithm": _TIMING_ALGORITHM,
                "producer_identity_sha256": self._descriptor["producer_identity_sha256"],
                "timing_evidence_sha256": self._descriptor["timing_evidence_sha256"],
            }
            if (
                row != expected
                or type(row.get("schema_version")) is not int
                or type(row.get("sample_rate")) is not int
            ):
                raise ValueError("sidecar header differs from locked bindings")
            self._header_read = True
            return next(self)
        if row is None:
            if (
                self._digest.hexdigest() != self._descriptor["sha256"]
                or self._timing.hexdigest() != self._descriptor["timing_evidence_sha256"]
            ):
                raise ValueError("sidecar bytes or timing differ from locked bindings")
            self._check_unchanged()
            self._verified = True
            raise StopIteration
        item = _decode(row, self._total)
        if (
            item.item.sequence != self._count
            or item.ready_after_sample < self._ready
            or (self._finishing and not item.finish_only)
            or self._count >= _MAX_ROWS
        ):
            raise ValueError("sidecar observations violate producer order or row budget")
        self._count += 1
        self._ready = item.ready_after_sample
        self._finishing |= item.finish_only
        self._timing.update(_timing_bytes(row))
        return item

    def proof(self) -> dict[str, Any]:
        if not self._verified:
            raise ValueError("sidecar proof requires complete verified consumption")
        self._check_unchanged()
        return {
            "bytes_and_timing_verified": True,
            "records": self._count,
            **{k: v for k, v in self._descriptor.items() if k != "path"},
            "pcm_sha256": self._pcm,
            "producer_provenance_verified": False,
            "joint_asr_latency_observed": False,
            "certification_eligible": False,
        }

    def close(self) -> None:
        self._closed = True


@contextlib.contextmanager
def open_asr_sidecar(
    artifact_root: Path, descriptor: Mapping[str, str], *, pcm_sha256: str, total_samples: int
) -> Iterator[LockedASRSidecar]:
    """Preflight all records before yielding, then verify actual replay consumption.

    Normal exit requires EOF. On failure/cancellation the file closes without a
    proof, preserving the original exception. No complete transcript is retained.
    Call off-loop when used with a live runner: both file passes perform I/O.
    """
    root = artifact_root.expanduser().resolve(strict=True)
    if (
        root.is_relative_to(_ROOT)
        or not root.is_dir()
        or set(descriptor)
        != {"path", "sha256", "producer_identity_sha256", "timing_evidence_sha256"}
        or type(total_samples) is not int
        or total_samples <= 0
    ):
        raise ValueError("sidecar descriptor, root or sample count invalid")
    frozen = dict(descriptor)
    for value in (pcm_sha256, *(v for k, v in frozen.items() if k != "path")):
        if not isinstance(value, str) or not _SHA.fullmatch(value):
            raise ValueError("sidecar requires exact SHA-256 bindings")
    name = frozen["path"]
    if (
        not isinstance(name, str)
        or not name
        or "\\" in name
        or PurePosixPath(name).is_absolute()
        or ".." in PurePosixPath(name).parts
    ):
        raise ValueError("sidecar path must be relative and confined")
    path = root / name
    if (
        not path.resolve().is_relative_to(root)
        or any(p.is_symlink() for p in (path, *path.parents) if p.is_relative_to(root))
        or not path.is_file()
    ):
        raise ValueError("sidecar must be a regular confined file without symlinks")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        source = LockedASRSidecar(handle, path, frozen, pcm_sha256, total_samples)
        try:
            yield source
            source.proof()
        finally:
            source.close()
