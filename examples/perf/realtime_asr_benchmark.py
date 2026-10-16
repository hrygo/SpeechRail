"""ASR-only, paced public-API evidence for external local audio fixtures."""

from __future__ import annotations

import base64
import hashlib
import json
import math
import queue
import threading
import time
import wave
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from openai import OpenAI

from speechrail.config.auth import resolve_api_key
from speechrail.domain.audio_timeline import RationalResampler

try:
    from .asr_quality import character_error_metrics, punctuation_error_metrics
    from .asr_window_evidence import ASRWindowEvidence, PublicASRError, WindowEvidenceError
    from .bench_realtime import get
    from .benchmark_http import validate_base_url
    from .benchmark_manifest import load_manifest
    from .benchmark_resources import ProcessResourceMonitor, _normalise_resources
    from .benchmark_runner import validate_output_path, write_result
except ImportError:  # pragma: no cover - direct CLI imports
    from asr_quality import (  # type: ignore[no-redef]
        character_error_metrics,
        punctuation_error_metrics,
    )
    from asr_window_evidence import (  # type: ignore[no-redef]
        ASRWindowEvidence,
        PublicASRError,
        WindowEvidenceError,
    )
    from bench_realtime import get  # type: ignore[no-redef]
    from benchmark_http import validate_base_url  # type: ignore[no-redef]
    from benchmark_manifest import load_manifest  # type: ignore[no-redef]
    from benchmark_resources import (  # type: ignore[no-redef]
        ProcessResourceMonitor,
        _normalise_resources,
    )
    from benchmark_runner import validate_output_path, write_result  # type: ignore[no-redef]


class ASREvidence:
    """Correlate terminals by item and order text by the frozen input range."""

    def __init__(
        self,
        *,
        require_boundaries: bool,
        resource_only: bool = False,
    ) -> None:
        self.resource_only = resource_only
        self.require_boundaries = require_boundaries or resource_only
        self.boundaries: dict[str, tuple[int, int]] = {}
        self.terminals: dict[str, str] = {}
        self.preview_count = 0
        self.revised_characters = 0
        self.previews: dict[str, str] = {}
        self.snapshot_items: set[str] = set()
        self.first_preview_at: float | None = None
        self.last_terminal_at: float | None = None
        self.receipt_samples: int | None = None
        self.receipt_at: float | None = None

    def consume(self, event: object, received_at: float) -> None:
        kind = get("type", event)
        if str(kind).startswith("speechrail.transcription.window."):
            raise ValueError("revision window events require the window evidence auditor")
        if kind in {"error", "conversation.item.input_audio_transcription.failed"}:
            raise RuntimeError("public ASR request failed")
        if kind == "speechrail.transcription.segment_closed":
            item = str(get("item_id", event))
            span = get("sample_span", event)
            start, end = get("start", span), get("end", span)
            if type(start) is not int or type(end) is not int or not 0 <= start < end:
                raise ValueError("invalid ASR input boundary")
            if item in self.boundaries:
                raise ValueError("duplicate ASR input boundary")
            self.boundaries[item] = (start, end)
        elif kind in {
            "speechrail.transcription.hypothesis",
            "conversation.item.input_audio_transcription.delta",
        }:
            item = str(get("utterance_id", event) or get("item_id", event))
            if kind.endswith("hypothesis"):
                self.snapshot_items.add(item)
            elif item in self.snapshot_items:
                # Older services may mirror a snapshot as an official delta.
                # Counting both would manufacture duplicated preview text and
                # inflated revision statistics.
                return
            previous = self.previews.get(item, "")
            text = (
                str(get("text", event) or "")
                if kind.endswith("hypothesis")
                else (previous + str(get("delta", event) or ""))
            )
            self.preview_count += 1
            common = 0
            for left, right in zip(previous, text, strict=False):
                if left != right:
                    break
                common += 1
            self.revised_characters += len(previous) - common
            self.previews[item] = text
            if self.first_preview_at is None:
                self.first_preview_at = received_at
        elif kind == "conversation.item.input_audio_transcription.completed":
            item = str(get("item_id", event))
            if item in self.terminals:
                raise ValueError("duplicate ASR terminal")
            if self.require_boundaries and item not in self.boundaries:
                raise ValueError("ASR terminal precedes its input boundary")
            text = get("transcript", event)
            if not isinstance(text, str):
                raise ValueError("ASR terminal lacks transcript")
            # Resource-only evidence needs terminal identity, not transcript
            # content. Avoid retaining text or feeding it into quality scoring.
            self.terminals[item] = "" if self.resource_only else text
            self.last_terminal_at = received_at
        elif kind == "speechrail.input_audio_buffer.committed":
            if get("commit_event_id", event) != "benchmark-final":
                raise ValueError("unrelated input barrier")
            if self.receipt_samples is not None:
                raise ValueError("duplicate input barrier")
            samples = get("accepted_samples", event)
            if type(samples) is not int or samples < 0:
                raise ValueError("invalid input barrier watermark")
            self.receipt_samples = samples
            self.receipt_at = received_at

    def score(
        self,
        reference: str | None,
        *,
        expected_wire_samples: int,
        effective_max_segment_ms: int | None = None,
        punctuation_reference_text: str | None = None,
        punctuation_reference_kind: str | None = None,
    ) -> dict[str, object]:
        if effective_max_segment_ms is not None and (
            type(effective_max_segment_ms) is not int or effective_max_segment_ms < 1
        ):
            raise ValueError("invalid effective ASR segment budget")
        if self.receipt_samples != expected_wire_samples or not self.terminals:
            raise ValueError("ASR input barrier lacks exact terminal coverage")
        text = ""
        if self.require_boundaries:
            spans = sorted(self.boundaries.items(), key=lambda pair: pair[1])
            cursor = 0
            for item, (start, end) in spans:
                if start != cursor or item not in self.terminals:
                    raise ValueError("ASR input boundary has a gap or missing terminal")
                if (
                    effective_max_segment_ms is not None
                    # A manual wire anchor can precede its rounded 16 kHz
                    # cursor by one 24 kHz sample. It cannot absorb a packet.
                    and end - start > effective_max_segment_ms * 24 + 1
                ):
                    raise ValueError("ASR input boundary exceeds its effective segment budget")
                cursor = end
            if cursor != expected_wire_samples:
                raise ValueError("ASR final tail is not covered")
            if not self.resource_only:
                text = "".join(self.terminals[item] for item, _ in spans)
        elif not self.resource_only:
            text = "".join(self.terminals.values())

        evidence: dict[str, object] = {
            "terminal_count": len(self.terminals),
            "boundary_count": len(self.boundaries),
            "preview_count": self.preview_count,
            "revised_characters": self.revised_characters,
            "sample_coverage_gate": "pass" if self.require_boundaries else "unset",
            "segment_budget_gate": (
                "pass"
                if self.require_boundaries and effective_max_segment_ms is not None
                else "unset"
            ),
        }
        if self.resource_only:
            evidence.update(
                {
                    "quality_gate": "unset",
                    "accepted_samples": self.receipt_samples,
                    "sample_spans": [
                        {
                            "item_id": item,
                            "start_sample": start,
                            "end_sample": end,
                        }
                        for item, (start, end) in sorted(
                            self.boundaries.items(), key=lambda pair: pair[1]
                        )
                    ],
                }
            )
            return evidence
        if not isinstance(reference, str):
            raise ValueError("ASR quality evidence requires a human reference")
        quality = character_error_metrics(reference, text)
        if punctuation_reference_text is not None:
            quality["punctuation_metrics"] = punctuation_error_metrics(
                punctuation_reference_text,
                text,
                gold_kind=punctuation_reference_kind,
            )
        return {**quality, **evidence}


def _wire_audio(path: Path) -> tuple[bytes, float]:
    with wave.open(str(path)) as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError("ASR fixture must be 16 kHz mono PCM16 WAV")
        frames = audio.getnframes()
        # One extra frame exposes a malformed half sample in the data chunk;
        # a truncated file must not redefine the declared fixture duration.
        pcm = audio.readframes(frames + 1)
        if len(pcm) != frames * 2:
            raise ValueError("ASR fixture PCM length differs from its declared frame count")
    if not pcm:
        raise ValueError("ASR fixture is empty")
    resampler = RationalResampler(16000, 24000)
    return resampler.process(pcm) + resampler.flush(), len(pcm) / 32000


def _session_update(language: str, policy: dict[str, object] | None) -> dict[str, object]:
    extensions: dict[str, Any] = {"task": "transcription"}
    if policy is not None:
        extensions["asr"] = policy
    return {
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": 24000},
                    "transcription": {"model": "whisper-1", "language": language},
                    "turn_detection": "manual",
                }
            },
            "speechrail": extensions,
        },
    }


def _validated_policy_echo(
    configured: object,
    requested: dict[str, object],
) -> dict[str, object]:
    # Legacy baselines do not request this extension and must remain runnable
    # with their installed runtime. Candidate policies use its own validator.
    from speechrail.domain.asr_policy import ASRPolicy

    policy = ASRPolicy.from_mapping(requested)
    effective = get("asr", get("speechrail", get("session", configured)))
    echo = {
        key: get(key, effective)
        for key in (
            "preview_interval_ms",
            "max_segment_ms",
            "effective_max_segment_ms",
            "finalization",
            "final_deadline_ms",
            "rollback_tokens",
        )
    }
    # Decode the reply with the same strict integer and enum contract as requests.
    echoed_policy = ASRPolicy.from_mapping(
        {key: value for key, value in echo.items() if key != "effective_max_segment_ms"}
    )
    if (
        echoed_policy.preview_interval_ms != policy.preview_interval_ms
        or echoed_policy.max_segment_ms != policy.max_segment_ms
        or echoed_policy.finalization != policy.finalization
        or echoed_policy.rollback_tokens != policy.rollback_tokens
        or echoed_policy.final_deadline_ms is None
        or (
            policy.final_deadline_ms is not None
            and echoed_policy.final_deadline_ms != policy.final_deadline_ms
        )
    ):
        raise ValueError("ASR effective policy differs from the requested policy")
    limit = echo["effective_max_segment_ms"]
    if type(limit) is not int or not 1000 <= limit <= policy.max_segment_ms:
        raise ValueError("invalid effective ASR segment budget")
    return echo


def _observed_policy_echo(configured: object) -> dict[str, object]:
    """Validate the server default policy echo when the manifest has no override."""
    effective = get("asr", get("speechrail", get("session", configured)))
    requested = {
        key: get(key, effective)
        for key in (
            "preview_interval_ms",
            "max_segment_ms",
            "finalization",
            "final_deadline_ms",
            "rollback_tokens",
        )
    }
    if any(value is None for value in requested.values()):
        raise ValueError("ASR session omitted its effective policy echo")
    return _validated_policy_echo(configured, requested)


def _timing_metrics(
    evidence: ASREvidence,
    *,
    started: float,
    last_upload_started: float | None,
    last_upload_completed: float | None,
    playback_wait_completed: float,
    committed_at: float,
    commit_send_completed: float,
    wire_samples: int,
) -> dict[str, object]:
    """Record client timestamps; signed differences do not imply acoustic latency."""
    if type(wire_samples) is not int or wire_samples <= 0:
        raise ValueError("invalid ASR timing sample count")
    timestamps: dict[str, float] = {}
    for name, value in {
        "started": started,
        "last_upload_started": last_upload_started,
        "last_upload_completed": last_upload_completed,
        "playback_wait_completed": playback_wait_completed,
        "commit_send_started": committed_at,
        "commit_send_completed": commit_send_completed,
        "last_terminal_received": evidence.last_terminal_at,
        "receipt_received": evidence.receipt_at,
    }.items():
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
        ):
            raise ValueError("incomplete or invalid ASR timing observations")
        timestamps[name] = float(value)
    ordered = [
        timestamps[name]
        for name in (
            "started",
            "last_upload_started",
            "last_upload_completed",
            "playback_wait_completed",
            "commit_send_started",
            "commit_send_completed",
        )
    ]
    terminal = timestamps["last_terminal_received"]
    receipt = timestamps["receipt_received"]
    if ordered != sorted(ordered) or not started <= terminal <= receipt or receipt < committed_at:
        raise ValueError("invalid ASR timing order")
    preview = evidence.first_preview_at
    if preview is not None:
        if (
            isinstance(preview, bool)
            or not isinstance(preview, (int, float))
            or not math.isfinite(preview)
        ):
            raise ValueError("invalid ASR timing preview")
        if not started <= preview <= receipt:
            raise ValueError("invalid ASR timing order")
    offsets: dict[str, object] = {
        name + "_seconds": value - started
        for name, value in timestamps.items()
        if name != "started"
    }
    offsets.update(
        clock="monotonic",
        origin="paced_playback_start",
        nominal_playback_end_seconds=wire_samples / 24000,
        acoustic_speech_end="not_observed",
    )
    return {
        "first_preview_seconds": preview - started if preview is not None else None,
        "last_upload_to_last_terminal_seconds": terminal - timestamps["last_upload_completed"],
        "nominal_playback_end_to_last_terminal_seconds": terminal - started - wire_samples / 24000,
        "commit_to_last_terminal_seconds": terminal - committed_at,
        "barrier_seconds": receipt - committed_at,
        "timing_observations": offsets,
    }


def _run_asr(
    client: OpenAI,
    wire: bytes,
    *,
    language: str,
    reference: str | None,
    policy: dict[str, object] | None,
    resource_only: bool = False,
    punctuation_reference_text: str | None = None,
    punctuation_reference_kind: str | None = None,
    window_request: dict[str, object] | None = None,
    annotations: dict[str, Any] | None = None,
) -> dict[str, object]:
    if not wire or len(wire) % 2:
        raise ValueError("ASR benchmark requires nonempty PCM16 wire audio")
    conn = client.realtime.connect(model="whisper-1").enter()
    events: queue.Queue[tuple[float, object]] = queue.Queue(maxsize=512)
    errors: list[BaseException] = []

    def receive() -> None:
        try:
            while True:
                event = conn.recv()
                events.put_nowait((time.monotonic(), event))
        except BaseException as exc:
            errors.append(exc)

    reader = threading.Thread(target=receive, daemon=True)
    reader.start()
    evidence = (
        ASRWindowEvidence()
        if window_request is not None
        else ASREvidence(
            require_boundaries=policy is not None,
            resource_only=resource_only,
        )
    )

    def next_event(deadline: float) -> tuple[float, object]:
        while time.monotonic() < deadline:
            if errors:
                raise RuntimeError("ASR transport ended before its input barrier")
            try:
                return events.get(timeout=min(0.1, max(0.001, deadline - time.monotonic())))
            except queue.Empty:
                continue
        raise TimeoutError("ASR benchmark stage deadline expired")

    def wait_kind(kind: str) -> object:
        deadline = time.monotonic() + 15
        while True:
            _, event = next_event(deadline)
            if get("type", event) == "error":
                raise PublicASRError(get("error", event), stage="configuration")
            if get("type", event) == kind:
                return event

    def consume_available() -> None:
        # Consume while sending paced PCM too. A long meeting can produce more
        # than 512 previews before commit; retaining all of them in the receiver
        # queue would end the transport even when the service keeps up.
        if errors:
            raise RuntimeError("ASR transport ended before its input barrier")
        while True:
            try:
                received_at, event = events.get_nowait()
            except queue.Empty:
                return
            evidence.consume(event, received_at)

    try:
        wait_kind("session.created")
        update = _session_update(language, policy)
        if window_request is not None:
            if (
                policy is not None
                or set(window_request) != {"mode", "scene"}
                or (
                    window_request["mode"] != "revision_window_v1"
                    or window_request["scene"] not in {"meeting", "caption"}
                )
            ):
                raise ValueError("invalid or mixed window benchmark request")
            update["session"]["speechrail"]["window"] = window_request
            update["session"]["speechrail"]["task"] = (
                "caption" if window_request["scene"] == "caption" else "transcription"
            )
        conn.send(update)
        configured = wait_kind("session.updated")
        if window_request is not None:
            effective = get("window", get("speechrail", get("session", configured)))
            if any(get(key, effective) != value for key, value in window_request.items()):
                raise ValueError("window benchmark policy echo differs from request")
            echo = {
                "mode": get("mode", effective),
                "scene": get("scene", effective),
                "policy": get("policy", effective),
            }
        elif policy is not None:
            echo = _validated_policy_echo(configured, policy)
        elif resource_only:
            echo = _observed_policy_echo(configured)
        else:
            echo = None
        started = time.monotonic()
        last_upload_started: float | None = None
        last_upload_completed: float | None = None
        for offset in range(0, len(wire), 4800):
            time.sleep(max(0, started + offset / 48000 - time.monotonic()))
            consume_available()
            packet = {
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(wire[offset : offset + 4800]).decode(),
            }
            last_upload_started = time.monotonic()
            conn.send(packet)
            last_upload_completed = time.monotonic()
        time.sleep(max(0, started + len(wire) / 48000 - time.monotonic()))
        playback_wait_completed = time.monotonic()
        consume_available()
        commit = {
            "type": "input_audio_buffer.commit",
            "event_id": "benchmark-final",
            "speechrail": {"request_receipt": True},
        }
        committed_at = time.monotonic()
        conn.send(commit)
        commit_send_completed = time.monotonic()
        deadline = committed_at + 125
        while evidence.receipt_at is None:
            received_at, event = next_event(deadline)
            evidence.consume(event, received_at)
        evidence_result = (
            evidence.score(
                reference,
                expected_wire_samples=len(wire) // 2,
                language=language,
                annotations=annotations,
            )
            if isinstance(evidence, ASRWindowEvidence)
            else evidence.score(
                reference,
                expected_wire_samples=len(wire) // 2,
                effective_max_segment_ms=(
                    int(echo["effective_max_segment_ms"]) if echo is not None else None
                ),
                punctuation_reference_text=punctuation_reference_text,
                punctuation_reference_kind=punctuation_reference_kind,
            )
        )
        timing = (
            _timing_metrics(
                evidence,
                started=started,
                last_upload_started=last_upload_started,
                last_upload_completed=last_upload_completed,
                playback_wait_completed=playback_wait_completed,
                committed_at=committed_at,
                commit_send_completed=commit_send_completed,
                wire_samples=len(wire) // 2,
            )
            if evidence.last_terminal_at is not None
            else {
                "last_terminal_received": "not_observed",
                "barrier_seconds": evidence.receipt_at - committed_at,
                "acoustic_speech_end": "not_observed",
            }
        )
        result: dict[str, object] = {
            "audio_seconds": len(wire) / 48000,
            **timing,
            "last_upload_sample_span": {"start": offset // 2, "end": len(wire) // 2},
            "effective_policy": echo,
        }
        if resource_only:
            result["quality_gate"] = evidence_result.pop("quality_gate")
            result["resource_evidence"] = evidence_result
        else:
            result["quality_metrics"] = evidence_result
        return result
    finally:
        conn.close()
        reader.join(timeout=2)
        if reader.is_alive():
            raise TimeoutError("ASR benchmark receiver did not stop")


def run_manifest_asr_benchmark(
    manifest: Path,
    *,
    profile: str,
    output: Path,
    sessions: int,
    warmup: bool,
    app_home: Path | None,
    base_url: str,
    resource_only: bool = False,
    fixture_ids: Sequence[str] | None = None,
) -> dict[str, object]:
    if sessions < 1:
        raise ValueError("sessions must be positive")
    base_url = validate_base_url(base_url)
    manifest_bytes = manifest.read_bytes() if fixture_ids is not None else None
    loaded = load_manifest(manifest)
    if manifest_bytes is not None and manifest.read_bytes() != manifest_bytes:
        raise ValueError("ASR manifest changed during fixture selection")
    fixtures = [fixture for fixture in loaded.fixtures if fixture.kind == "asr"]
    known_fixture_ids = {fixture.id for fixture in fixtures}
    if not fixtures:
        raise ValueError("ASR-only evidence requires at least one ASR fixture")
    selection = None
    if fixture_ids is not None:
        if (
            not isinstance(fixture_ids, Sequence)
            or isinstance(fixture_ids, (str, bytes))
            or not fixture_ids
            or any(not isinstance(value, str) for value in fixture_ids)
        ):
            raise ValueError("ASR fixture selection must be a nonempty list of IDs")
        selected = set(fixture_ids)
        if len(selected) != len(fixture_ids):
            raise ValueError("ASR fixture selection contains duplicate IDs")
        if not selected <= {fixture.id for fixture in fixtures}:
            raise ValueError("ASR fixture selection contains unknown IDs")
        fixtures = [fixture for fixture in fixtures if fixture.id in selected]
        selection = {
            "requested_ids": list(fixture_ids),
            "executed_order": [fixture.id for fixture in fixtures],
            "warmup_fixture_id": fixtures[0].id if warmup else None,
            "source_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "scope": "selected_fixtures",
            "frozen_v4_matrix_scope": False,
        }
    if not resource_only and any(fixture.reference_text is None for fixture in fixtures):
        raise ValueError("ASR-only evidence requires external human references")
    metadata = json.loads(manifest_bytes if manifest_bytes is not None else manifest.read_text())
    policy = metadata.get("asr_policy")
    window_request = metadata.get("window_request")
    annotations = metadata.get("human_annotations", {})
    if not isinstance(annotations, dict) or any(
        not isinstance(key, str) or not isinstance(value, dict)
        for key, value in annotations.items()
    ):
        raise ValueError("human_annotations must be keyed by fixture ID")
    if not annotations.keys() <= known_fixture_ids:
        raise ValueError("human_annotations contains an unknown fixture ID")
    if annotations and window_request is None:
        raise ValueError("human_annotations require revision-window evidence")
    if window_request is not None and not isinstance(window_request, dict):
        raise ValueError("window_request must be an object")
    if policy is not None and not isinstance(policy, dict):
        raise ValueError("asr_policy must be an object")
    output = validate_output_path(output)
    client = OpenAI(api_key=resolve_api_key(app_home=app_home) or "local", base_url=base_url)
    if warmup:
        first = fixtures[0]
        wire, _ = _wire_audio(first.path)
        _run_asr(
            client,
            wire,
            language=first.language,
            reference=first.reference_text,
            policy=policy,
            resource_only=resource_only,
            punctuation_reference_text=first.punctuation_reference_text,
            punctuation_reference_kind=first.punctuation_reference_kind,
            **({"window_request": window_request} if window_request is not None else {}),
            **({"annotations": annotations[first.id]} if first.id in annotations else {}),
        )
    monitor = ProcessResourceMonitor(interval_seconds=0.25)
    monitor.start()
    results = []
    failure: Exception | None = None
    try:
        for repeat in range(sessions):
            for fixture in fixtures:
                wire, _ = _wire_audio(fixture.path)
                result = _run_asr(
                    client,
                    wire,
                    language=fixture.language,
                    reference=fixture.reference_text,
                    policy=policy,
                    resource_only=resource_only,
                    punctuation_reference_text=fixture.punctuation_reference_text,
                    punctuation_reference_kind=fixture.punctuation_reference_kind,
                    **({"window_request": window_request} if window_request is not None else {}),
                    **(
                        {"annotations": annotations[fixture.id]}
                        if fixture.id in annotations
                        else {}
                    ),
                )
                if selection is not None:
                    result["wire_pcm_sha256"] = hashlib.sha256(wire).hexdigest()
                if fixture.reference_text is not None:
                    result["reference_text_sha256"] = hashlib.sha256(
                        fixture.reference_text.encode()
                    ).hexdigest()
                if fixture.id in annotations:
                    result["human_annotation_sha256"] = hashlib.sha256(
                        json.dumps(
                            annotations[fixture.id],
                            sort_keys=True,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        ).encode()
                    ).hexdigest()
                results.append({"id": fixture.id, "repeat": repeat + 1, **result})
    except Exception as exc:
        failure = exc
    finally:
        resources = _normalise_resources(monitor.stop())
    payload = {
        "schema_version": 1 if window_request is not None else 2,
        "tool": "speechrail-asr-window-benchmark"
        if window_request is not None
        else "speechrail-bench-realtime-asr",
        "evidence_mode": "real",
        "profile": profile,
        "model_identity": dict(loaded.model_identity),
        "warmup_completed": warmup,
        "sessions": results,
        "resources": resources,
        "measurement_completed": failure is None,
        "failure_kind": type(failure).__name__ if failure is not None else None,
        "failure_code": failure.code
        if isinstance(failure, (PublicASRError, WindowEvidenceError))
        else None,
        "failure_stage": failure.stage
        if isinstance(failure, (PublicASRError, WindowEvidenceError))
        else None,
        "scene_business_gate": "unset",
        "baseline_comparison_gate": "unset",
        "timing_definitions": {
            "first_preview_seconds": "first preview receive minus paced playback start",
            "last_upload_to_last_terminal_seconds": (
                "last terminal receive minus last append send return; signed; "
                "send return does not prove server acceptance or acoustic speech end"
            ),
            "nominal_playback_end_to_last_terminal_seconds": (
                "last terminal receive minus paced playback start and wire duration; signed"
            ),
            "commit_to_last_terminal_seconds": (
                "last terminal receive minus commit send start; signed"
            ),
            "barrier_seconds": "input receipt receive minus commit send start",
            "acoustic_speech_end": "not_observed",
        },
    }
    if resource_only:
        payload["measurement_mode"] = "resource_only"
        payload["quality_gate"] = "unset"
    if selection is not None:
        payload["fixture_selection"] = selection
    write_result(payload, output)
    if failure is not None:
        raise RuntimeError("ASR benchmark stopped; partial evidence was saved") from failure
    return payload
