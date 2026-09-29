"""Draft a teleprompter replay manifest from one recorded reading session.

The latency probe (``tools/probe_teleprompter_latency.py``) deliberately never
persists transcript text, so building the manifest that ``teleprompter-replay``
consumes was a manual transcription step: a human had to type every Realtime
event and hand-label the reading position. This tool is the dataset half of the
same evidence chain. It streams an authorized external WAV at its real 100 ms
cadence, records the Realtime event stream verbatim, and -- when ``--script`` is
given -- aligns the recognised text against the frozen script to propose
``expected_segment_index`` and ``intent`` per event.

Two deliberate limits keep a machine draft from being mistaken for evidence:

* Transcripts stay outside the repository. Any output path inside the checkout
  is refused, and no transcript text is printed to stdout or stderr.
* Nothing counts as reviewed by accident. ``dataset_revision`` is suffixed with
  ``-draft`` unless ``--confirm-reviewed`` is passed, and every decision the
  aligner was unsure about is listed in a review sidecar, by event index only.

Usage:
  uv run python tools/build_teleprompter_replay_manifest.py <external.wav> \
    --script <script.txt> --output <external-manifest.json> \
    --review-output <external-review.md> --profile quality \
    --dataset-revision A_v1 --baseline-commit <sha> \
    --candidate-commit <sha> --policy-revision <rev> \
    --app-home "$SPEECHRAIL_APP_HOME"
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import json
import queue
import threading
import time
import unicodedata
import wave
from collections.abc import Sequence
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any
from uuid import uuid4

from openai import OpenAI

from speechrail.config.auth import resolve_api_key  # type: ignore[import-untyped]

SCHEMA_VERSION = "teleprompter.replay.v1"
DRAFT_SUFFIX = "-draft"
UPLOAD_CHUNK_MILLISECONDS = 100
SAMPLE_RATE = 24_000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2
MAX_RECEIVE_QUEUE_EVENTS = 8_192

HYPOTHESIS_EVENT = "speechrail.transcription.hypothesis"
DELTA_EVENT = "conversation.item.input_audio_transcription.delta"
COMPLETED_EVENT = "conversation.item.input_audio_transcription.completed"
FAILED_EVENT = "conversation.item.input_audio_transcription.failed"

# Alignment tuning. The reader is human, not a teleprompter: recognised text
# rarely matches the script character for character. A weak match therefore
# yields *no* reading position rather than a forced one, because
# under-claiming where the reader was leaves a number missing while
# over-claiming invents it.
ALIGN_MIN_RATIO = 0.72
ALIGN_REVIEW_MARGIN = 0.1
ALIGN_BACKTRACK_CHARS = 48
ALIGN_FORWARD_CHARS = 600
ALIGN_PREFILTER_CHARS = 2
# When the anchor scan finds nothing, the expected match is still close to the
# reading position, so one narrow unanchored pass over this band is cheap and
# recovers events whose anchor was mangled by a recognition error.
ALIGN_FALLBACK_BACKTRACK_CHARS = 16
ALIGN_FALLBACK_FORWARD_CHARS = 96
# How far behind the reading position a fragment must match before the aligner
# calls it a re-read. Re-deliveries are filtered separately, so anything left
# landing this far back was spoken out of order.
RE_READ_MIN_GAP_CHARS = 4
# A revisioned hypothesis carries the whole utterance so far, so scoring all of
# it would compare the reader's opening sentence -- which sits far behind the
# reading position -- against a window that no longer contains it, and would
# divide by a denominator that grows with every recognition error. Only the
# newest text decides where the reader is now, so that is what gets scored.
ALIGN_TAIL_CHARS = 24

INTENT_READ = "read"
INTENT_IMPROVISE = "improvise"
INTENT_RE_READ = "reRead"
MANIFEST_INTENTS = (INTENT_READ, INTENT_IMPROVISE, INTENT_RE_READ, "manualJump")


class ManifestDraftError(ValueError):
    """Raised when a capture or script cannot produce an honest manifest."""


class RealtimeCaptureError(RuntimeError):
    """Raised when the realtime service returns a stable error event."""

    def __init__(self, code: str) -> None:
        self.code = code[:96] or "unknown"
        super().__init__(f"realtime_error:{self.code}")


class RealtimeQueueOverflowError(RuntimeError):
    """Raised when the capture cannot keep up with the realtime event stream."""


def _value(event: object, key: str) -> object:
    if isinstance(event, dict):
        return event.get(key)
    return getattr(event, key, None)


def _event_type(event: object) -> str:
    return str(_value(event, "type") or "unknown")


def _error_code(event: object) -> str:
    error = _value(event, "error")
    return str(_value(error, "code") or "unknown")


def find_repository_root(start: Path) -> Path | None:
    """Return the nearest ancestor that looks like this repository, if any."""

    for candidate in (start, *start.parents):
        if (candidate / "pyproject.toml").is_file() or (candidate / ".git").exists():
            return candidate
    return None


def require_external_path(path: Path, label: str) -> Path:
    """Refuse transcript-bearing material inside the checkout.

    AGENTS.md keeps full transcripts out of the repository, so the guard is
    structural rather than advisory.
    """

    resolved = path.expanduser().resolve()
    repository = find_repository_root(resolved.parent)
    if repository is not None and resolved.is_relative_to(repository):
        raise ManifestDraftError(f"{label} must stay outside {repository}")
    return resolved


def normalize_text(text: str) -> str:
    """Fold text to comparable characters: width, case and punctuation free.

    Punctuation and spacing are exactly what a human improvises around, so they
    must not decide whether two strings are the same sentence.
    """

    folded = unicodedata.normalize("NFKC", text).casefold()
    return "".join(character for character in folded if character.isalnum())


def split_segments(script: str) -> list[str]:
    """Split a reading script into frozen segments on blank lines."""

    segments: list[str] = []
    current: list[str] = []
    for line in script.splitlines():
        if line.strip():
            current.append(line.strip())
        elif current:
            segments.append(" ".join(current))
            current = []
    if current:
        segments.append(" ".join(current))
    return [segment for segment in segments if segment.strip()]


@dataclass(frozen=True, slots=True)
class SegmentIndex:
    """Map normalized character offsets back onto frozen script segments."""

    segments: tuple[str, ...]
    normalized: tuple[str, ...]
    bounds: tuple[tuple[int, int], ...]

    @classmethod
    def build(cls, segments: Sequence[str]) -> SegmentIndex:
        normalized = tuple(normalize_text(segment) for segment in segments)
        bounds: list[tuple[int, int]] = []
        offset = 0
        for text in normalized:
            bounds.append((offset, offset + len(text)))
            offset += len(text)
        return cls(segments=tuple(segments), normalized=normalized, bounds=tuple(bounds))

    @property
    def script_text(self) -> str:
        return "".join(self.normalized)

    def segment_of(self, offset: int) -> int:
        for index, (start, end) in enumerate(self.bounds):
            if start <= offset <= end:
                return index
        return max(0, len(self.bounds) - 1)


@dataclass(frozen=True, slots=True)
class Alignment:
    """One alignment decision, kept for the review sidecar."""

    segment_index: int | None
    intent: str
    ratio: float


@dataclass(slots=True)
class ScriptAligner:
    """Monotonic alignment of recognised text against the frozen script.

    ``cursor`` is the reading position the reader has demonstrably reached.
    Events are aligned in receive order, so the cursor only moves forward; a
    fragment that lands distinctly behind it is the signature of a re-read
    rather than an ASR revision.

    The aligner never claims ``improvise``. That intent describes human
    behaviour, and the replay runner counts an advancing ``improvise`` as a
    harmful jump, so inferring it from a weak text match would manufacture the
    safety number this dataset exists to measure. Low confidence yields ``read``
    with no reading position plus a line in the review sidecar.
    """

    index: SegmentIndex
    cursor: int = 0
    high_water: int = 0
    previous: str = ""

    def align(self, text: str, *, cumulative: bool) -> Alignment:
        """Align one recognised text; ``cumulative`` marks whole-utterance events."""

        normalized = normalize_text(text)
        needle = normalized[-ALIGN_TAIL_CHARS:] if cumulative else normalized
        if not needle:
            return Alignment(None, INTENT_READ, 0.0)
        script = self.index.script_text
        if not script:
            return Alignment(None, INTENT_READ, 0.0)
        if not cumulative and self.previous and (
            needle in self.previous or self.previous in needle
        ):
            # The same words arriving twice. The OpenAI delta stream and the
            # revisioned hypothesis both carry them; they arrive back to back,
            # so only the immediately preceding event is compared. Comparing
            # against the whole utterance instead would swallow every re-read,
            # since a repeated sentence is by definition already in the text.
            # A re-delivery advances nothing and is not a re-read.
            return Alignment(self.index.segment_of(self.high_water), INTENT_READ, 1.0)
        best_ratio, best_start, best_end = self._best_match(needle)
        if best_ratio < ALIGN_MIN_RATIO:
            self.previous = needle
            return Alignment(None, INTENT_READ, best_ratio)
        if not cumulative and best_start < self.cursor - RE_READ_MIN_GAP_CHARS:
            # The reader went back. What they have *read* is still the high
            # water mark, so the reading position must not regress.
            self.previous = needle
            return Alignment(
                self.index.segment_of(self.high_water), INTENT_RE_READ, best_ratio
            )
        self.cursor = max(self.cursor, best_end)
        self.high_water = max(self.high_water, best_end)
        self.previous = needle
        return Alignment(self.index.segment_of(self.high_water), INTENT_READ, best_ratio)

    def _best_match(self, needle: str) -> tuple[float, int, int]:
        """Score one needle against the script window around the cursor.

        Every matching block counts, not only the longest one. A revisioned
        hypothesis repeats the whole utterance, so scoring just its longest
        fragment would discard the prefix that was already confirmed and make
        an on-script sentence look off-script.
        """

        best = self._scan(needle, self.cursor, anchored=True)
        if best[0] == 0.0:
            best = self._scan(needle, self.cursor, anchored=False, narrow=True)
        return best

    def _scan(
        self, needle: str, cursor: int, *, anchored: bool, narrow: bool = False
    ) -> tuple[float, int, int]:
        """Score one needle against the script, optionally anchored or narrowed."""

        script = self.index.script_text
        back = ALIGN_FALLBACK_BACKTRACK_CHARS if narrow else ALIGN_BACKTRACK_CHARS
        forward = ALIGN_FALLBACK_FORWARD_CHARS if narrow else ALIGN_FORWARD_CHARS
        window_start = max(0, cursor - back)
        window_end = min(len(script), cursor + forward)
        window = script[window_start:window_end]
        # The anchor must sit at the *start* of what is being scored: the
        # matcher aligns the whole needle to the window from the offset, so an
        # anchor elsewhere would leave the rest of the needle unconstrained.
        anchor = needle[:ALIGN_PREFILTER_CHARS]
        best_matched = 0
        best_start = cursor
        best_end = cursor
        # The reader advances monotonically, so only offsets carrying the anchor
        # are worth scoring. Without this prefilter the search would build one
        # SequenceMatcher per offset per event.
        for offset in range(0, max(1, len(window) - len(anchor) + 1)):
            if anchored and window[offset:offset + len(anchor)] != anchor:
                continue
            tail = window[offset:]
            matched = 0
            reach = -1
            for block in SequenceMatcher(None, tail, needle).get_matching_blocks():
                if block.size == 0:
                    continue
                # Every block counts, adjacent or not: an ASR revision keeps
                # the confirmed prefix and appends, so the pieces of one
                # sentence are spread across several blocks.
                matched += block.size
                reach = max(reach, block.a + block.size)
            if matched <= best_matched:
                continue
            best_matched = matched
            best_start = window_start + offset
            best_end = window_start + offset + reach
        if best_matched == 0:
            return (0.0, cursor, cursor)
        return (min(1.0, best_matched / len(needle)), best_start, best_end)


@dataclass(slots=True)
class CapturedEvent:
    """One replayable Realtime event with its receive offset."""

    offset_milliseconds: int
    kind: str
    item_id: str
    event_id: str
    revision: int | None
    text: str
    stable_prefix_codepoints: int | None

    def to_manifest(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "at_milliseconds": self.offset_milliseconds,
            "kind": self.kind,
            "item_id": self.item_id,
            "event_id": self.event_id,
            "text": self.text,
        }
        if self.revision is not None:
            payload["revision"] = self.revision
        if self.stable_prefix_codepoints is not None:
            payload["stable_prefix_codepoints"] = self.stable_prefix_codepoints
        return payload


def to_captured_event(
    received_offset_ms: float, event: object, ordinal: int
) -> CapturedEvent | None:
    """Map one wire event onto a replay event, dropping those that carry none."""

    event_type = _event_type(event)
    at = max(0, round(received_offset_ms))
    if event_type == HYPOTHESIS_EVENT:
        utterance_id = str(_value(event, "utterance_id") or f"utterance-{ordinal}")
        revision = _value(event, "revision")
        stable_prefix = _value(event, "stable_prefix_codepoints")
        return CapturedEvent(
            offset_milliseconds=at,
            # A hypothesis is a revisioned snapshot of the whole utterance, not
            # a delta: the replay adapter maps it onto ``partialSnapshot`` and
            # needs ``revision`` plus the stable-prefix evidence to advance only
            # on text the engine has stopped revising.
            kind="snapshot",
            item_id=utterance_id,
            event_id=f"{utterance_id}.{revision if isinstance(revision, int) else ordinal}",
            revision=revision if isinstance(revision, int) else None,
            text=str(_value(event, "text") or ""),
            stable_prefix_codepoints=stable_prefix if isinstance(stable_prefix, int) else None,
        )
    if event_type == COMPLETED_EVENT:
        return CapturedEvent(
            offset_milliseconds=at,
            kind="completed",
            item_id=str(_value(event, "item_id") or f"item-{ordinal}"),
            event_id=str(_value(event, "commit_event_id") or f"completed-{ordinal}"),
            revision=None,
            text=str(_value(event, "transcript") or ""),
            stable_prefix_codepoints=None,
        )
    if event_type == DELTA_EVENT:
        # The delta stream is the OpenAI-shaped partial the follow path also
        # consumes, so it replays as ``partial`` rather than being dropped: a
        # capture that silently omitted it would measure a different event
        # sequence than the one the reader saw.
        return CapturedEvent(
            offset_milliseconds=at,
            kind="partial",
            item_id=str(_value(event, "item_id") or f"item-{ordinal}"),
            event_id=str(_value(event, "event_id") or f"delta-{ordinal}"),
            revision=None,
            text=str(_value(event, "delta") or ""),
            stable_prefix_codepoints=None,
        )
    if event_type == FAILED_EVENT:
        return CapturedEvent(
            offset_milliseconds=at,
            kind="failed",
            item_id=str(_value(event, "item_id") or f"item-{ordinal}"),
            event_id=f"failed-{ordinal}",
            revision=None,
            text="",
            stable_prefix_codepoints=None,
        )
    return None


def _receive_loop(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    connection: Any,
    clock: Any = time.monotonic,
    max_queue_events: int = MAX_RECEIVE_QUEUE_EVENTS,
) -> None:
    try:
        while True:
            event = connection.recv()
            received_at = clock()
            try:
                events.put_nowait((received_at, event))
            except queue.Full:
                raise RealtimeQueueOverflowError(
                    f"realtime event queue exceeded {max_queue_events} items"
                ) from None
    except Exception as exc:  # socket close is observed by the waiter
        errors.append(exc)


class _SessionCapture:
    """Collect replayable events, keyed off the first event's receive time."""

    def __init__(self) -> None:
        self.events: list[CapturedEvent] = []
        self.counts: dict[str, int] = {}
        self._origin: float | None = None
        self.commit_event_id: str | None = None
        self.terminal_seen = False

    def observe(self, received_at: float, event: object) -> str:
        event_type = _event_type(event)
        self.counts[event_type] = self.counts.get(event_type, 0) + 1
        if event_type == "error":
            raise RealtimeCaptureError(_error_code(event))
        if self._origin is None:
            self._origin = received_at
        if (
            event_type in {COMPLETED_EVENT, FAILED_EVENT}
            and self.commit_event_id is not None
            and _value(event, "commit_event_id") == self.commit_event_id
        ):
            self.terminal_seen = True
        captured = to_captured_event(
            (received_at - self._origin) * 1_000, event, len(self.events)
        )
        if captured is not None:
            self.events.append(captured)
        return event_type

    def drain(self, events: queue.Queue[tuple[float, object]]) -> None:
        while True:
            try:
                received_at, event = events.get_nowait()
            except queue.Empty:
                return
            self.observe(received_at, event)


def _receive_until(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    capture: _SessionCapture,
    target: str,
    *,
    timeout_seconds: float,
) -> float:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if errors:
            raise errors[0]
        try:
            received_at, event = events.get(
                timeout=min(1.0, max(0.01, deadline - time.monotonic()))
            )
        except queue.Empty:
            continue
        if capture.observe(received_at, event) == target:
            return received_at
    raise TimeoutError(f"realtime event timeout: {target}")


def load_wave_fixture(path: Path) -> tuple[bytes, float]:
    """Read and validate an external 24 kHz mono PCM16 WAV."""

    try:
        with wave.open(str(path), "rb") as source:
            if (
                source.getframerate() != SAMPLE_RATE
                or source.getnchannels() != CHANNELS
                or source.getsampwidth() != SAMPLE_WIDTH_BYTES
                or source.getcomptype() != "NONE"
            ):
                raise ManifestDraftError("WAV must be 24 kHz mono PCM16")
            pcm = source.readframes(source.getnframes())
    except (OSError, EOFError, wave.Error) as exc:
        raise ManifestDraftError("WAV could not be read") from exc
    if not pcm or len(pcm) % SAMPLE_WIDTH_BYTES:
        raise ManifestDraftError("WAV must contain non-empty PCM16 audio")
    return pcm, len(pcm) / (SAMPLE_RATE * SAMPLE_WIDTH_BYTES)


def capture_session(
    pcm: bytes,
    *,
    base_url: str,
    app_home: Path | None,
    model: str,
    duration_seconds: float,
) -> _SessionCapture:
    """Stream one reading session and record its Realtime events verbatim."""

    client = OpenAI(api_key=resolve_api_key(app_home=app_home) or "local", base_url=base_url)
    connection: Any = client.realtime.connect(model=model).enter()
    events: queue.Queue[tuple[float, object]] = queue.Queue()
    errors: list[Exception] = []
    receiver = threading.Thread(
        target=_receive_loop,
        args=(events, errors, connection),
        name="speechrail-teleprompter-manifest-receiver",
        daemon=True,
    )
    receiver.start()

    capture = _SessionCapture()
    commit_event_id = f"manifest-commit-{uuid4().hex}"
    capture.commit_event_id = commit_event_id
    deadline = time.monotonic() + max(60.0, duration_seconds * 3 + 30.0)
    try:
        _receive_until(events, errors, capture, "session.created", timeout_seconds=15)
        connection.send(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "audio": {
                        "input": {
                            "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                            "transcription": {"model": model, "language": "zh"},
                            "turn_detection": "manual",
                        }
                    },
                    "speechrail": {"task": "caption"},
                },
            }
        )
        origin = _receive_until(events, errors, capture, "session.updated", timeout_seconds=15)

        bytes_per_chunk = SAMPLE_RATE * SAMPLE_WIDTH_BYTES * UPLOAD_CHUNK_MILLISECONDS // 1_000
        for index, offset in enumerate(range(0, len(pcm), bytes_per_chunk)):
            scheduled_at = origin + index * UPLOAD_CHUNK_MILLISECONDS / 1_000
            time.sleep(max(0.0, scheduled_at - time.monotonic()))
            if errors:
                raise errors[0]
            if time.monotonic() >= deadline:
                raise TimeoutError("realtime upload deadline exceeded")
            capture.drain(events)
            connection.send(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(
                        pcm[offset:offset + bytes_per_chunk]
                    ).decode("ascii"),
                }
            )
        capture.drain(events)
        connection.send({"type": "input_audio_buffer.commit", "event_id": commit_event_id})

        while not capture.terminal_seen:
            if errors:
                raise errors[0]
            if time.monotonic() >= deadline:
                raise TimeoutError("realtime terminal deadline exceeded")
            try:
                received_at, event = events.get(timeout=0.5)
            except queue.Empty:
                capture.drain(events)
                continue
            capture.observe(received_at, event)
            capture.drain(events)
        if any(event.kind == "failed" for event in capture.events):
            raise RealtimeCaptureError("replay_terminal_failed")
    finally:
        with contextlib.suppress(Exception):
            capture.drain(events)
            connection.close()
    return capture


def build_manifest(
    capture: _SessionCapture,
    segments: Sequence[str],
    *,
    dataset_revision: str,
    baseline_commit: str,
    candidate_commit: str,
    policy_revision: str,
    language_lane: str,
    device_class: str,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    """Project a capture plus a frozen script into a manifest and review notes."""

    if not segments:
        raise ManifestDraftError("script contains no segments")
    for name, value in (
        ("dataset_revision", dataset_revision),
        ("baseline_commit", baseline_commit),
        ("candidate_commit", candidate_commit),
        ("policy_revision", policy_revision),
    ):
        if not value.strip():
            raise ManifestDraftError(f"{name} is required by the replay contract")

    aligner = ScriptAligner(index=SegmentIndex.build(segments))
    labels: list[dict[str, object]] = []
    review: list[dict[str, object]] = []
    for event_index, event in enumerate(capture.events):
        if event.kind == "failed":
            alignment = Alignment(None, INTENT_READ, 0.0)
            reason = "终态失败没有可对齐文本，intent 需人工确认"
        else:
            alignment = aligner.align(
                event.text, cumulative=event.kind in {"snapshot", "completed"}
            )
            if alignment.intent == INTENT_RE_READ:
                reason = "匹配位置早于已读高水位：疑似回读，需人工确认"
            elif alignment.segment_index is None:
                reason = "对齐不足，读者位置未知：若确为脱稿或停顿，请手工改为 improvise"
            elif alignment.ratio < ALIGN_MIN_RATIO + ALIGN_REVIEW_MARGIN:
                reason = "对齐度接近阈值：建议抽查"
            else:
                reason = ""
        label: dict[str, object] = {
            "event_index": event_index,
            "intent": alignment.intent,
        }
        if alignment.intent == INTENT_READ and alignment.segment_index is not None:
            label["expected_segment_index"] = alignment.segment_index
        if alignment.intent not in MANIFEST_INTENTS:
            raise ManifestDraftError(f"proposed an intent the decoder rejects: {alignment.intent}")
        labels.append(label)
        if reason:
            review.append(
                {
                    "event_index": event_index,
                    "at_milliseconds": event.offset_milliseconds,
                    "proposed_intent": alignment.intent,
                    "expected_segment_index": label.get("expected_segment_index"),
                    "ratio": round(alignment.ratio, 3),
                    "reason": reason,
                }
            )

    manifest: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "dataset_revision": dataset_revision,
        "baseline_commit": baseline_commit,
        "candidate_commit": candidate_commit,
        "policy_revision": policy_revision,
        "language_lane": language_lane,
        "device_class": device_class,
        "segments": [
            {"id": f"s{position}", "text": segment}
            for position, segment in enumerate(segments)
        ],
        "events": [event.to_manifest() for event in capture.events],
        "labels": labels,
    }
    return manifest, review


def render_review(
    manifest: dict[str, object],
    review: Sequence[dict[str, object]],
    *,
    draft: bool,
    profile: str,
    capture_counts: dict[str, int],
) -> str:
    """Render the human confirmation checklist. Contains no transcript text."""

    labels = manifest.get("labels")
    events = manifest.get("events")
    if not isinstance(labels, list) or not isinstance(events, list):
        raise ManifestDraftError("manifest is missing labels or events")
    intents: dict[str, int] = {}
    for label in labels:
        if isinstance(label, dict) and "intent" in label:
            key = str(label["intent"])
            intents[key] = intents.get(key, 0) + 1
    lines = [
        "# 提词器回放素材：人工确认清单",
        "",
        f"- dataset_revision：`{manifest.get('dataset_revision')}`"
        + ("（**机器草稿，未经人工确认**）" if draft else "（已声明人工确认）"),
        f"- 采集档位：`{profile}`",
        f"- 事件数：{len(events)}；标注数：{len(labels)}",
        f"- wire 事件计数：{json.dumps(capture_counts, ensure_ascii=False, sort_keys=True)}",
        f"- 机器提议的 intent 分布：{json.dumps(intents, ensure_ascii=False, sort_keys=True)}",
        "",
        "> 本文件按事件下标列出机器存疑项，不含任何转写文本。",
        "> `improvise` 与 `reRead` 直接决定严重误推进、回稿恢复延迟是否被计数，",
        "> 未经人工逐条确认前，manifest 只能作为草稿使用。",
        "",
        "## 需要人工确认的事件",
        "",
    ]
    if not review:
        lines.append("机器未标记存疑项；这**不等于**标注正确，仍需抽查。")
    else:
        lines.append("| event_index | at_ms | 提议 intent | 提议 segment | 对齐度 | 原因 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for note in review:
            lines.append(
                "| {event_index} | {at_milliseconds} | {proposed_intent} "
                "| {expected_segment_index} | {ratio} | {reason} |".format(**note)
            )
    lines.extend(
        [
            "",
            "## 确认方式",
            "",
            "1. 对照朗读材料逐条核对上面存疑项，就地修改 manifest 的 `labels`。",
            "2. 抽查若干 `read` 标注的 `expected_segment_index` 是否等于读者实际到达的位置。",
            "3. 全部确认后另存为正式版本，并把 `dataset_revision` 的 `-draft` 后缀去掉；",
            "   未确认的草稿不要提交，也不要用它出的报告做质量结论。",
            "",
        ]
    )
    return "\n".join(lines)


def render_capture(capture: _SessionCapture) -> dict[str, object]:
    """Project a capture that has no script behind it.

    Deliberately *not* a manifest: without a frozen script there are no
    segments, no labels and no reading positions, so it must not carry the
    replay schema version -- feeding it to ``teleprompter-replay`` would fail
    on missing fields, and labelling it with the manifest's version would
    invite exactly that attempt.
    """

    return {
        "capture_schema_version": SCHEMA_VERSION,
        "note": (
            "raw event capture, not a TeleprompterReplayManifest; "
            "rerun with --script to build one"
        ),
        "capture": [event.to_manifest() for event in capture.events],
        "wire_event_counts": dict(sorted(capture.counts.items())),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav_file", type=Path)
    parser.add_argument(
        "--script",
        type=Path,
        help="frozen reading script, one segment per paragraph",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--review-output", type=Path)
    parser.add_argument("--profile", required=True, choices=("fast", "quality", "reference"))
    parser.add_argument("--dataset-revision", default="")
    parser.add_argument("--baseline-commit", default="")
    parser.add_argument("--candidate-commit", default="")
    parser.add_argument("--policy-revision", default="")
    parser.add_argument("--language-lane", default="zh")
    parser.add_argument("--device-class", default="macbook-builtin-mic")
    parser.add_argument(
        "--confirm-reviewed",
        action="store_true",
        help=(
            "declare that a human confirmed every label; "
            "without it the dataset is marked as a draft"
        ),
    )
    parser.add_argument("--app-home", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--model", default="whisper-1")
    args = parser.parse_args(argv)

    try:
        if args.output.exists() or args.output.is_symlink():
            raise ManifestDraftError("output already exists")
        output = require_external_path(args.output, "output")
        review_output = (
            require_external_path(args.review_output, "review output")
            if args.review_output
            else None
        )
        if args.script and not review_output:
            raise ManifestDraftError("--script requires --review-output")
        pcm, duration_seconds = load_wave_fixture(args.wav_file)
        capture = capture_session(
            pcm,
            base_url=args.base_url,
            app_home=args.app_home,
            model=args.model,
            duration_seconds=duration_seconds,
        )
        if not capture.events:
            raise ManifestDraftError("capture produced no replayable events")
        if args.script:
            segments = split_segments(args.script.read_text(encoding="utf-8"))
            revision = args.dataset_revision.strip()
            if not revision:
                raise ManifestDraftError("--dataset-revision is required with --script")
            if not args.confirm_reviewed and not revision.endswith(DRAFT_SUFFIX):
                revision = f"{revision}{DRAFT_SUFFIX}"
            manifest, review = build_manifest(
                capture,
                segments,
                dataset_revision=revision,
                baseline_commit=args.baseline_commit,
                candidate_commit=args.candidate_commit,
                policy_revision=args.policy_revision,
                language_lane=args.language_lane,
                device_class=args.device_class,
            )
            assert review_output is not None
            review_output.write_text(
                render_review(
                    manifest,
                    review,
                    draft=not args.confirm_reviewed,
                    profile=args.profile,
                    capture_counts=capture.counts,
                ),
                encoding="utf-8",
            )
        else:
            manifest = render_capture(capture)
        output.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    except (
        OSError,
        ManifestDraftError,
        RealtimeCaptureError,
        RealtimeQueueOverflowError,
        TimeoutError,
    ) as exc:
        print(f"error: {type(exc).__name__}: {exc}")
        return 2
    if args.script:
        recorded = manifest.get("events")
        status = "reviewed" if args.confirm_reviewed else "draft"
    else:
        recorded = manifest.get("capture")
        status = "raw capture, no manifest built"
    events = recorded if isinstance(recorded, list) else []
    print(f"wrote {output} events={len(events)} {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
