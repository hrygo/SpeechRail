"""Prove local Qwen3-TTS text append after first PCM without leaking source text.

The model-specific incremental extension is supplied by the pinned mlx-audio fork:
``mlx_audio.tts.models.qwen3_tts.incremental_probe``. This tool never downloads models.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import json
import os
import re
import sys
import time
import wave
from collections.abc import Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Never, Protocol, cast

from speechrail.config.model_catalog import ModelArtifact, load_catalog

Variant = Literal["custom_voice", "base"]
Precision = Literal["q8", "bf16"]
EventKind = Literal["pcm", "waiting_for_text", "finished", "error"]
SCHEDULE_ID = "append-after-first-pcm-v1"
_VENDOR_MODULE = "mlx_audio.tts.models.qwen3_tts.incremental_probe"
_COMMIT_RE = re.compile(r"[0-9a-f]{40}")
_FAILURE_CODE_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")
_MAX_STEP_CALLS = 4096
_STEP_SIZE = 16
_FIRST_PCM_TIMEOUT_SECONDS = 30.0
_TOTAL_TIMEOUT_SECONDS = 120.0
_MAX_REFERENCE_TEXT_BYTES = 16 * 1024


class ProbeInputError(ValueError):
    """Raised when explicit probe inputs violate the local artifact contract."""


class ProbeSessionError(RuntimeError):
    """Raised when the incremental backend fails its streaming evidence contract."""

    def __init__(self, failure_code: str, *, evidence: ProbeEvidence | None = None) -> None:
        if _FAILURE_CODE_RE.fullmatch(failure_code) is None:
            failure_code = "internal_probe_error"
        self.failure_code = failure_code
        self.evidence = evidence
        super().__init__(failure_code)


@dataclass(frozen=True, slots=True)
class ProbeRequest:
    model_dir: Path
    artifact_key: str
    variant: Variant
    precision: Precision
    output_dir: Path
    schedule: str
    speaker: str | None = None
    reference_audio: Path | None = None
    reference_text_file: Path | None = None
    seed: int = 17

    def validate(self, *, repository_root: Path) -> None:
        if self.schedule != SCHEDULE_ID:
            raise ProbeInputError("unsupported probe schedule")
        if not self.artifact_key or any(character.isspace() for character in self.artifact_key):
            raise ProbeInputError("artifact key is invalid")
        if self.variant == "custom_voice":
            if self.precision != "q8":
                raise ProbeInputError("CustomVoice probe supports q8 only")
            if not self.speaker or not self.speaker.strip():
                raise ProbeInputError("CustomVoice requires an explicit speaker")
            if self.reference_audio is not None or self.reference_text_file is not None:
                raise ProbeInputError("reference inputs are only valid for Base")
        else:
            if self.speaker is not None:
                raise ProbeInputError("speaker is only valid for CustomVoice")
            if (self.reference_audio is None) != (self.reference_text_file is None):
                raise ProbeInputError("Base requires reference audio and reference text")
            if self.reference_audio is None or self.reference_text_file is None:
                raise ProbeInputError("Base requires reference audio and reference text")
        if not 0 <= self.seed <= 4_294_967_295:
            raise ProbeInputError("seed must be an unsigned 32-bit integer")

        root = repository_root.resolve(strict=True)
        model_path = _existing_local_path(self.model_dir, label="model directory")
        if not model_path.is_dir():
            raise ProbeInputError("model directory is not a directory")
        _require_outside_repository(model_path, root, label="model directory")

        output_path = _absolute_local_path(self.output_dir, label="output directory")
        _require_outside_repository(output_path, root, label="output directory")
        if not output_path.parent.is_dir():
            raise ProbeInputError("output directory parent must already exist")
        if output_path.exists():
            raise ProbeInputError("output directory must not already exist")

        for reference, label in (
            (self.reference_audio, "reference audio"),
            (self.reference_text_file, "reference text"),
        ):
            if reference is None:
                continue
            reference_path = _existing_local_path(reference, label=label)
            if not reference_path.is_file():
                raise ProbeInputError(f"{label} is not a file")
            _require_outside_repository(reference_path, root, label=label)


def _absolute_local_path(path: Path, *, label: str) -> Path:
    raw = str(path)
    if "://" in raw or not path.expanduser().is_absolute():
        raise ProbeInputError(f"{label} must be a local absolute path")
    return path.expanduser().resolve(strict=False)


def _existing_local_path(path: Path, *, label: str) -> Path:
    resolved = _absolute_local_path(path, label=label)
    if not resolved.exists():
        raise ProbeInputError(f"{label} does not exist")
    return resolved


def _require_outside_repository(path: Path, root: Path, *, label: str) -> None:
    try:
        path.relative_to(root)
    except ValueError:
        return
    raise ProbeInputError(f"{label} must be outside the repository")


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        self.exit(2, "probe_failed=arguments_invalid\n")


def build_parser() -> argparse.ArgumentParser:
    parser = _SafeArgumentParser(
        description=(
            "Run one offline, local-model test that appends text after the first PCM chunk. "
            "Text and absolute paths are never written to the report."
        )
    )
    parser.add_argument(
        "--model-dir", type=Path, required=True, help="absolute local model directory"
    )
    parser.add_argument(
        "--artifact-key", required=True, help="exact key from the SpeechRail model catalog"
    )
    parser.add_argument("--variant", choices=("custom_voice", "base"), required=True)
    parser.add_argument("--precision", choices=("q8", "bf16"), required=True)
    parser.add_argument(
        "--output-dir", type=Path, required=True, help="new directory outside the repository"
    )
    parser.add_argument("--schedule", choices=(SCHEDULE_ID,), required=True)
    parser.add_argument("--speaker", help="required for CustomVoice; never included in the report")
    parser.add_argument(
        "--reference-audio", type=Path, help="Base reference audio outside the repository"
    )
    parser.add_argument(
        "--reference-text-file", type=Path, help="Base transcript outside the repository"
    )
    parser.add_argument("--seed", type=int, default=17)
    return parser


def parse_request(argv: Sequence[str], *, repository_root: Path) -> ProbeRequest:
    args = build_parser().parse_args(argv)
    request = ProbeRequest(
        model_dir=args.model_dir,
        artifact_key=args.artifact_key,
        variant=cast(Variant, args.variant),
        precision=cast(Precision, args.precision),
        output_dir=args.output_dir,
        schedule=args.schedule,
        speaker=args.speaker,
        reference_audio=args.reference_audio,
        reference_text_file=args.reference_text_file,
        seed=args.seed,
    )
    request.validate(repository_root=repository_root)
    return request


def find_artifact(artifact_key: str) -> ModelArtifact:
    for artifact in load_catalog().artifacts:
        if artifact.key == artifact_key:
            return artifact
    raise ProbeInputError("artifact key is not present in the model catalog")


def _artifact_precision(artifact: ModelArtifact) -> Precision | None:
    if artifact.quantization.bits == 8:
        return "q8"
    if artifact.quantization.dtype == "bf16":
        return "bf16"
    return None


def validate_artifact(artifact: ModelArtifact, request: ProbeRequest) -> None:
    if artifact.key != request.artifact_key:
        raise ProbeInputError("artifact key does not match the probe")
    if artifact.family != "qwen3_tts" or artifact.variant != request.variant:
        raise ProbeInputError("artifact family or variant does not match the probe")
    if _artifact_precision(artifact) != request.precision:
        raise ProbeInputError("artifact precision does not match the probe")
    if request.variant == "custom_voice" and request.precision != "q8":
        raise ProbeInputError("CustomVoice probe supports q8 only")
    if request.variant == "base" and request.precision not in {"q8", "bf16"}:
        raise ProbeInputError("Base probe supports q8 or bf16")


def verify_artifact_files(artifact: ModelArtifact, model_dir: Path) -> int:
    """Verify every catalog-pinned file before any model code is imported."""
    root = model_dir.resolve(strict=True)
    verified = 0
    seen: set[str] = set()
    for entry in artifact.files:
        if entry.path in seen:
            raise ProbeInputError("artifact file manifest contains duplicate paths")
        seen.add(entry.path)
        try:
            path = (root / entry.path).resolve(strict=True)
            path.relative_to(root)
        except (OSError, RuntimeError, ValueError) as exc:
            raise ProbeInputError("artifact file integrity check failed") from exc
        if not path.is_file() or path.stat().st_size != entry.size:
            raise ProbeInputError("artifact file integrity check failed")
        digest = hashlib.sha256()
        try:
            with path.open("rb") as source:
                for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
                    digest.update(block)
        except OSError as exc:
            raise ProbeInputError("artifact file integrity check failed") from exc
        if digest.hexdigest() != entry.sha256:
            raise ProbeInputError("artifact file integrity check failed")
        verified += 1
    if verified == 0:
        raise ProbeInputError("artifact file manifest is empty")
    return verified


@dataclass(frozen=True, slots=True)
class ProbeEvent:
    kind: EventKind
    pcm16: bytes
    sample_rate: int
    generation_identity: str


class ProbeSession(Protocol):
    generation_identity: str

    @property
    def initial_prefill_count(self) -> int:
        """Zero before first text prefill, then exactly one for this generation."""
        ...

    sample_rate: int
    peak_memory_bytes: int | None

    def append_text(self, text: str) -> None: ...

    def finish_input(self) -> None: ...

    def step(self, *, max_steps: int) -> object: ...

    def cancel(self) -> None: ...

    def close(self) -> None: ...


def _cleanup_probe_session(session: ProbeSession, *, cancel: bool = True) -> None:
    if cancel:
        with suppress(Exception):
            session.cancel()
    with suppress(Exception):
        session.close()


class VendorProbeExtension(Protocol):
    __speechrail_vendor_commit__: str

    def open_probe_session(
        self,
        *,
        model_dir: str,
        variant: Variant,
        precision: Precision,
        speaker: str | None,
        reference_audio_path: str | None,
        reference_text: str | None,
        seed: int,
        local_files_only: bool,
    ) -> ProbeSession: ...


@dataclass(frozen=True, slots=True)
class ProbeEvidence:
    pcm16: bytes
    report: dict[str, object]


@dataclass(frozen=True, slots=True)
class ProbeOutputPaths:
    audio: Path
    report: Path


@dataclass(frozen=True, slots=True)
class _Schedule:
    initial_text: str
    appended_text: str


_SCHEDULES: dict[str, _Schedule] = {
    SCHEDULE_ID: _Schedule(
        initial_text="你好，",
        appended_text="现在继续完成连续语音增量测试。",
    ),
}


def _event(raw: object) -> ProbeEvent:
    if isinstance(raw, ProbeEvent):
        event = raw
    elif isinstance(raw, Mapping):
        kind = raw.get("kind", raw.get("type"))
        pcm = raw.get("pcm16", b"")
        sample_rate = raw.get("sample_rate", 0)
        generation = raw.get("generation_identity", "")
        if (
            kind not in {"pcm", "waiting_for_text", "finished", "error"}
            or not isinstance(pcm, bytes)
            or not isinstance(sample_rate, int)
            or isinstance(sample_rate, bool)
            or not isinstance(generation, str)
        ):
            raise ProbeSessionError("vendor_event_invalid")
        event = ProbeEvent(cast(EventKind, kind), pcm, sample_rate, generation)
    else:
        raise ProbeSessionError("vendor_event_invalid")
    if (
        event.kind not in {"pcm", "waiting_for_text", "finished", "error"}
        or not isinstance(event.pcm16, bytes)
        or not isinstance(event.sample_rate, int)
        or isinstance(event.sample_rate, bool)
        or not isinstance(event.generation_identity, str)
    ):
        raise ProbeSessionError("vendor_event_invalid")
    if not event.generation_identity:
        raise ProbeSessionError("generation_identity_missing")
    return event


def _check_event_identity(event: ProbeEvent, generation_identity: str) -> None:
    if event.generation_identity != generation_identity:
        raise ProbeSessionError("generation_identity_changed")
    if event.kind == "error":
        raise ProbeSessionError("vendor_generation_failed")
    if event.kind == "pcm":
        if event.sample_rate <= 0 or event.sample_rate > 192_000:
            raise ProbeSessionError("vendor_pcm_sample_rate_invalid")
        if not event.pcm16 or len(event.pcm16) % 2:
            raise ProbeSessionError("vendor_pcm_chunk_invalid")


def run_probe_session(
    session: ProbeSession,
    *,
    artifact: ModelArtifact,
    vendor_commit: str,
    schedule_id: str = SCHEDULE_ID,
    package_version: str = "unknown",
    verified_file_count: int | None = None,
) -> ProbeEvidence:
    """Run a bounded schedule and attach sanitized evidence to model-run failures."""
    try:
        if _COMMIT_RE.fullmatch(vendor_commit) is None:
            raise ProbeSessionError("vendor_commit_invalid")
        if schedule_id not in _SCHEDULES:
            raise ProbeInputError("unsupported probe schedule")
        if not isinstance(session.generation_identity, str) or not session.generation_identity:
            raise ProbeSessionError("generation_identity_missing")
        generation_identity = session.generation_identity
        prefill_count = session.initial_prefill_count
        if (
            isinstance(prefill_count, bool)
            or not isinstance(prefill_count, int)
            or prefill_count != 0
        ):
            raise ProbeSessionError("initial_prefill_count_invalid")
        sample_rate = session.sample_rate
        if isinstance(sample_rate, bool) or not isinstance(sample_rate, int) or sample_rate <= 0:
            raise ProbeSessionError("session_sample_rate_invalid")
    except Exception as exc:
        _cleanup_probe_session(session)
        if isinstance(exc, ProbeSessionError | ProbeInputError):
            raise
        raise ProbeSessionError("probe_session_metadata_invalid") from exc

    schedule = _SCHEDULES[schedule_id]
    pcm_chunks: list[bytes] = []
    first_pcm_at: float | None = None
    append_at: float | None = None
    next_pcm_after_append_at: float | None = None
    appended_text_count = 0
    terminal = False
    started = time.monotonic()
    deadline = started + _TOTAL_TIMEOUT_SECONDS
    close_attempted = False

    def make_evidence(*, failure_code: str | None) -> ProbeEvidence:
        pcm16 = b"".join(pcm_chunks)
        ended = time.monotonic()
        try:
            memory = session.peak_memory_bytes
        except Exception:
            memory = None
        if not isinstance(memory, int) or isinstance(memory, bool) or memory < 0:
            memory = None
        generation_digest = hashlib.sha256(generation_identity.encode("utf-8")).hexdigest()
        manifest_payload = [
            {"path": item.path, "size": item.size, "sha256": item.sha256}
            for item in artifact.files
        ]
        manifest_digest = hashlib.sha256(
            json.dumps(manifest_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        report: dict[str, object] = {
            "schema_version": 1,
            "status": (
                "streaming_contract_passed" if failure_code is None else "streaming_contract_failed"
            ),
            "artifact_key": artifact.key,
            "artifact_revision": artifact.revision,
            "artifact_manifest_sha256": manifest_digest,
            "artifact_file_count": len(artifact.files),
            "verified_file_count": verified_file_count,
            "variant": artifact.variant,
            "quantization": {
                "bits": artifact.quantization.bits,
                "dtype": artifact.quantization.dtype,
                "group_size": artifact.quantization.group_size,
                "format": artifact.quantization.format,
            },
            "precision": _artifact_precision(artifact),
            "vendor_commit": vendor_commit,
            "python_version": ".".join(str(part) for part in sys.version_info[:3]),
            "mlx_audio_version": package_version,
            "input_schedule_id": schedule_id,
            "initial_prefill_count": prefill_count,
            "append_after_first_pcm": (
                first_pcm_at is not None and append_at is not None and append_at > first_pcm_at
            ),
            "appended_text_count": appended_text_count,
            "generation_identity_sha256": generation_digest,
            "terminal": terminal,
            "timings_ms": {
                "first_pcm": (
                    round((first_pcm_at - started) * 1000, 3)
                    if first_pcm_at is not None
                    else None
                ),
                "append_to_next_pcm": (
                    round((next_pcm_after_append_at - append_at) * 1000, 3)
                    if next_pcm_after_append_at is not None and append_at is not None
                    else None
                ),
                "total": round((ended - started) * 1000, 3),
            },
            "sample_rate": sample_rate,
            "sample_count": len(pcm16) // 2,
            "peak_resource_summary": {"peak_memory_bytes": memory},
            "correctness_review": (
                "pending_manual_audio_review"
                if failure_code is None
                else "not_applicable_failed_probe"
            ),
            "limitations": [
                "Acoustic correctness and voice consistency require manual A/B review."
            ],
            "audio_file": "probe.wav",
        }
        if failure_code is not None:
            report["failure_code"] = failure_code
        return ProbeEvidence(pcm16=pcm16, report=report)

    def refresh_prefill_count(*, require_one: bool = False) -> None:
        nonlocal prefill_count
        current_count = session.initial_prefill_count
        if (
            isinstance(current_count, bool)
            or not isinstance(current_count, int)
            or current_count < prefill_count
        ):
            raise ProbeSessionError("initial_prefill_count_changed")
        prefill_count = current_count
        if prefill_count > 1:
            raise ProbeSessionError("initial_prefill_count_changed")
        if require_one and prefill_count != 1:
            raise ProbeSessionError("initial_prefill_count_invalid")

    def next_checked_event(*, until: float) -> ProbeEvent:
        for _ in range(_MAX_STEP_CALLS):
            if time.monotonic() >= min(deadline, until):
                break
            event = _event(session.step(max_steps=_STEP_SIZE))
            _check_event_identity(event, generation_identity)
            refresh_prefill_count(require_one=event.kind == "pcm")
            if event.sample_rate not in {0, sample_rate}:
                raise ProbeSessionError("session_sample_rate_changed")
            return event
        raise ProbeSessionError("incremental_generation_timed_out")

    try:
        session.append_text(schedule.initial_text)
        refresh_prefill_count()
        first_deadline = started + _FIRST_PCM_TIMEOUT_SECONDS
        while first_pcm_at is None:
            event = next_checked_event(until=first_deadline)
            if event.kind == "pcm":
                pcm_chunks.append(event.pcm16)
                first_pcm_at = time.monotonic()
                break
            if event.kind == "waiting_for_text":
                raise ProbeSessionError("backend_waited_for_text_before_first_pcm")
            if event.kind == "finished":
                raise ProbeSessionError("backend_finished_before_first_pcm")

        append_at = time.monotonic()
        session.append_text(schedule.appended_text)
        refresh_prefill_count(require_one=True)
        appended_text_count = 1
        session.finish_input()
        refresh_prefill_count(require_one=True)
        for _ in range(_MAX_STEP_CALLS):
            event = next_checked_event(until=deadline)
            if event.kind == "pcm":
                pcm_chunks.append(event.pcm16)
                if next_pcm_after_append_at is None:
                    next_pcm_after_append_at = time.monotonic()
            elif event.kind == "waiting_for_text":
                raise ProbeSessionError("backend_requested_text_after_finish")
            elif event.kind == "finished":
                terminal = True
                break
        if not terminal:
            raise ProbeSessionError("backend_terminal_missing")
        if next_pcm_after_append_at is None:
            raise ProbeSessionError("pcm_after_append_missing")
        refresh_prefill_count(require_one=True)
        if session.generation_identity != generation_identity:
            raise ProbeSessionError("generation_identity_changed")
        pcm16 = b"".join(pcm_chunks)
        if not pcm16 or len(pcm16) % 2:
            raise ProbeSessionError("probe_pcm_invalid")
        close_attempted = True
        session.close()
    except Exception as exc:
        failure_code = (
            exc.failure_code
            if isinstance(exc, ProbeSessionError)
            else "vendor_session_operation_failed"
        )
        if not close_attempted:
            close_attempted = True
            _cleanup_probe_session(session, cancel=not terminal)
        elif not terminal:
            with suppress(Exception):
                session.cancel()
        evidence = make_evidence(failure_code=failure_code)
        raise ProbeSessionError(failure_code, evidence=evidence) from exc

    return make_evidence(failure_code=None)


def write_probe_output(evidence: ProbeEvidence, output_dir: Path) -> ProbeOutputPaths:
    output_dir = output_dir.expanduser().resolve(strict=False)
    if output_dir.exists():
        raise ProbeInputError("output directory must not already exist")
    try:
        output_dir.mkdir(parents=True, exist_ok=False)
        audio_path = output_dir / "probe.wav"
        with wave.open(str(audio_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(cast(int, evidence.report["sample_rate"]))
            output.writeframes(evidence.pcm16)
        report_path = output_dir / "report.json"
        report_path.write_text(
            json.dumps(evidence.report, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, TypeError, ValueError, wave.Error) as exc:
        raise ProbeInputError("could not write probe output") from exc
    return ProbeOutputPaths(audio=audio_path, report=report_path)


def _load_vendor_extension() -> tuple[VendorProbeExtension, str]:
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    try:
        module = cast(VendorProbeExtension, importlib.import_module(_VENDOR_MODULE))
    except ImportError as exc:
        raise ProbeInputError("incremental vendor extension is not installed") from exc
    commit = module.__speechrail_vendor_commit__
    if not isinstance(commit, str) or _COMMIT_RE.fullmatch(commit) is None:
        raise ProbeInputError("incremental vendor extension has no pinned source commit")
    try:
        version = importlib.metadata.version("mlx-audio")
    except importlib.metadata.PackageNotFoundError as exc:
        raise ProbeInputError("mlx-audio package version is unavailable") from exc
    return module, version


def _open_vendor_session(
    module: VendorProbeExtension,
    request: ProbeRequest,
    *,
    reference_text: str | None,
) -> ProbeSession:
    try:
        session = module.open_probe_session(
            model_dir=str(request.model_dir.resolve(strict=True)),
            variant=request.variant,
            precision=request.precision,
            speaker=request.speaker,
            reference_audio_path=(
                str(request.reference_audio.resolve(strict=True))
                if request.reference_audio is not None
                else None
            ),
            reference_text=reference_text,
            seed=request.seed,
            local_files_only=True,
        )
    except Exception as exc:
        raise ProbeSessionError("model_session_open_failed") from exc
    return session


def _read_reference_text(path: Path | None) -> str | None:
    if path is None:
        return None
    try:
        if path.stat().st_size > _MAX_REFERENCE_TEXT_BYTES:
            raise ProbeInputError("reference text file exceeds the size limit")
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError) as exc:
        raise ProbeInputError("reference text file could not be read") from exc
    if not text:
        raise ProbeInputError("reference text file is empty")
    return text


def main(argv: Sequence[str] | None = None) -> int:
    repository_root = Path(__file__).resolve().parents[1]
    request: ProbeRequest | None = None
    try:
        request = parse_request(
            sys.argv[1:] if argv is None else argv,
            repository_root=repository_root,
        )
        artifact = find_artifact(request.artifact_key)
        validate_artifact(artifact, request)
        verified_file_count = verify_artifact_files(artifact, request.model_dir)
        module, package_version = _load_vendor_extension()
        vendor_commit = module.__speechrail_vendor_commit__
        reference_text = _read_reference_text(request.reference_text_file)
        session = _open_vendor_session(module, request, reference_text=reference_text)
        evidence = run_probe_session(
            session,
            artifact=artifact,
            vendor_commit=vendor_commit,
            package_version=package_version,
            verified_file_count=verified_file_count,
        )
        write_probe_output(evidence, request.output_dir)
    except ProbeSessionError as exc:
        if exc.evidence is not None and request is not None:
            try:
                write_probe_output(exc.evidence, request.output_dir)
            except ProbeInputError:
                print("probe_failed=probe_evidence_write_failed", file=sys.stderr)
                return 2
        print(f"probe_failed={exc.failure_code}", file=sys.stderr)
        return 2
    except ProbeInputError as exc:
        print(f"probe_failed={exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        # Do not echo exception messages: model paths and reference text may be embedded in them.
        print(f"probe_failed=unexpected_{type(exc).__name__}", file=sys.stderr)
        return 2
    print("streaming_contract_passed audio=probe.wav report=report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
