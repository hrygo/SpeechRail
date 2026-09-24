from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import replace
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.probe_tts_incremental import (
    ProbeEvent,
    ProbeInputError,
    ProbeRequest,
    ProbeSessionError,
    parse_request,
    run_probe_session,
    validate_artifact,
    verify_artifact_files,
    write_probe_output,
)

from speechrail.config.model_catalog import (
    ArtifactFile,
    ModelArtifact,
    QuantizationSpec,
    SourceLocation,
)

REVISION = "a" * 40
SHA256 = "b" * 64
VENDOR_COMMIT = "c" * 40


def _artifact(*, variant: str = "custom_voice", precision: str = "q8") -> ModelArtifact:
    quantization = (
        QuantizationSpec(bits=8, group_size=64, format="mlx")
        if precision == "q8"
        else QuantizationSpec(bits=None, group_size=None, format="none", dtype="bf16")
    )
    return ModelArtifact(
        key=f"tts-{variant}-{precision}",
        model_id="test/local-qwen3-tts",
        revision=REVISION,
        family="qwen3_tts",
        variant=variant,
        quantization=quantization,
        files=(
            ArtifactFile(path="config.json", size=1, sha256=SHA256),
            ArtifactFile(path="model.safetensors", size=1, sha256=SHA256),
            ArtifactFile(path="tokenizer.json", size=1, sha256=SHA256),
            ArtifactFile(path="speech_tokenizer/config.json", size=1, sha256=SHA256),
            ArtifactFile(path="speech_tokenizer/model.safetensors", size=1, sha256=SHA256),
        ),
        sources=(
            SourceLocation(
                provider="test",
                repository="local/test",
                revision=REVISION,
            ),
        ),
    )


def _request(
    tmp_path: Path,
    *,
    variant: str = "custom_voice",
    precision: str = "q8",
    speaker: str | None = "Vivian",
    reference_audio: Path | None = None,
    reference_text_file: Path | None = None,
) -> ProbeRequest:
    repository = tmp_path / "repo"
    repository.mkdir(exist_ok=True)
    model_dir = tmp_path / "models" / "local"
    model_dir.mkdir(parents=True, exist_ok=True)
    return ProbeRequest(
        model_dir=model_dir,
        artifact_key=f"tts-{variant}-{precision}",
        variant=variant,
        precision=precision,
        output_dir=tmp_path / "probe-output",
        schedule="append-after-first-pcm-v1",
        speaker=speaker,
        reference_audio=reference_audio,
        reference_text_file=reference_text_file,
    )


def test_cli_argument_errors_do_not_echo_supplied_paths(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repository = tmp_path / "repo"
    repository.mkdir()
    private_path = tmp_path / "private-reference.wav"

    with pytest.raises(SystemExit) as exit_info:
        parse_request(
            ["--variant", str(private_path)],
            repository_root=repository,
        )

    assert exit_info.value.code == 2
    assert str(private_path) not in capsys.readouterr().err


def test_cli_rejects_remote_paths_and_repository_local_output(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    repository.mkdir()
    model_dir = tmp_path / "models" / "local"
    model_dir.mkdir(parents=True)

    base_args = [
        "--artifact-key",
        "tts-custom_voice-q8",
        "--variant",
        "custom_voice",
        "--precision",
        "q8",
        "--schedule",
        "append-after-first-pcm-v1",
        "--speaker",
        "Vivian",
    ]
    with pytest.raises(ProbeInputError, match="local absolute"):
        parse_request(
            ["--model-dir", "https://example.invalid/model", *base_args,
             "--output-dir", str(tmp_path / "out")],
            repository_root=repository,
        )

    with pytest.raises(ProbeInputError, match="outside the repository"):
        parse_request(
            ["--model-dir", str(model_dir), *base_args,
             "--output-dir", str(repository / "probe-output")],
            repository_root=repository,
        )

    with pytest.raises(ProbeInputError, match="parent must already exist"):
        parse_request(
            ["--model-dir", str(model_dir), *base_args,
             "--output-dir", str(tmp_path / "missing-parent" / "probe-output")],
            repository_root=repository,
        )


def test_cli_requires_base_reference_pair_and_rejects_it_for_custom_voice(
    tmp_path: Path,
) -> None:
    base = _request(tmp_path, variant="base", precision="q8", speaker=None)
    with pytest.raises(ProbeInputError, match="reference audio and reference text"):
        base.validate(repository_root=tmp_path / "repo")

    custom = replace(
        _request(tmp_path, speaker="Vivian"),
        reference_audio=tmp_path / "reference.wav",
        reference_text_file=tmp_path / "reference.txt",
    )
    with pytest.raises(ProbeInputError, match="only valid for Base"):
        custom.validate(repository_root=tmp_path / "repo")


def test_tier_matrix_accepts_custom_voice_q8_and_base_q8_or_bf16(
    tmp_path: Path,
) -> None:
    custom_request = _request(tmp_path, variant="custom_voice", precision="q8")
    validate_artifact(_artifact(variant="custom_voice", precision="q8"), custom_request)

    ref_audio = tmp_path / "ref.wav"
    ref_audio.write_bytes(b"wav")
    ref_text = tmp_path / "ref.txt"
    ref_text.write_text("reference words", encoding="utf-8")
    base_q8 = replace(
        _request(tmp_path, variant="base", precision="q8", speaker=None),
        reference_audio=ref_audio,
        reference_text_file=ref_text,
    )
    base_q8.validate(repository_root=tmp_path / "repo")
    validate_artifact(_artifact(variant="base", precision="q8"), base_q8)

    base_bf16 = replace(
        _request(tmp_path, variant="base", precision="bf16", speaker=None),
        reference_audio=ref_audio,
        reference_text_file=ref_text,
    )
    base_bf16.validate(repository_root=tmp_path / "repo")
    validate_artifact(_artifact(variant="base", precision="bf16"), base_bf16)

    mismatched_request = replace(base_q8, artifact_key="tts-base-bf16")
    with pytest.raises(ProbeInputError, match="precision does not match"):
        validate_artifact(_artifact(variant="base", precision="bf16"), mismatched_request)


def test_artifact_files_are_verified_without_exposing_paths(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    config = model_dir / "config.json"
    config.write_text("{}", encoding="utf-8")
    digest = hashlib.sha256(config.read_bytes()).hexdigest()
    artifact = _artifact().model_copy(
        update={"files": (ArtifactFile(path="config.json", size=2, sha256=digest),)}
    )

    assert verify_artifact_files(artifact, model_dir) == 1

    config.write_text("{\"x\": 1}", encoding="utf-8")
    with pytest.raises(ProbeInputError, match="artifact file integrity") as error:
        verify_artifact_files(artifact, model_dir)
    assert str(config) not in str(error.value)


def test_probe_requires_pcm_before_append_and_preserves_one_generation() -> None:
    class FakeSession:
        generation_identity = "local-generation-secret-id"
        initial_prefill_count = 0
        sample_rate = 24_000
        peak_memory_bytes = 123_456

        def __init__(self) -> None:
            self.appended: list[str] = []
            self.finished = False
            self.events = [
                ProbeEvent("pcm", b"\x01\x00" * 4, 24_000, self.generation_identity),
                ProbeEvent("pcm", b"\x02\x00" * 6, 24_000, self.generation_identity),
                ProbeEvent("finished", b"", 24_000, self.generation_identity),
            ]

        def append_text(self, text: str) -> None:
            self.appended.append(text)

        def finish_input(self) -> None:
            self.finished = True

        def step(self, *, max_steps: int) -> ProbeEvent:
            assert max_steps > 0
            assert self.appended == ["你好，"] or self.finished
            self.initial_prefill_count = 1
            return self.events.pop(0)

        def cancel(self) -> None:
            pass

        def close(self) -> None:
            pass

    session = FakeSession()
    evidence = run_probe_session(session, artifact=_artifact(), vendor_commit=VENDOR_COMMIT)

    assert session.appended == ["你好，", "现在继续完成连续语音增量测试。"]
    assert session.finished is True
    assert evidence.report["append_after_first_pcm"] is True
    assert evidence.report["initial_prefill_count"] == 1
    assert evidence.report["terminal"] is True
    assert evidence.report["sample_count"] == 10
    assert evidence.report["generation_identity_sha256"] == hashlib.sha256(
        b"local-generation-secret-id"
    ).hexdigest()
    assert "local-generation-secret-id" not in json.dumps(evidence.report)
    assert "你好" not in json.dumps(evidence.report)


def test_probe_writes_sanitized_failure_evidence_when_first_pcm_is_missing(
    tmp_path: Path,
) -> None:
    class FakeSession:
        generation_identity = "generation-1"
        initial_prefill_count = 0
        sample_rate = 24_000
        peak_memory_bytes = None

        def append_text(self, text: str) -> None:
            pass

        def finish_input(self) -> None:
            raise AssertionError("must fail before input is finished")

        def step(self, *, max_steps: int) -> ProbeEvent:
            return ProbeEvent("waiting_for_text", b"", 24_000, self.generation_identity)

        def cancel(self) -> None:
            pass

        def close(self) -> None:
            pass

    with pytest.raises(ProbeSessionError) as failure:
        run_probe_session(FakeSession(), artifact=_artifact(), vendor_commit=VENDOR_COMMIT)

    assert failure.value.failure_code == "backend_waited_for_text_before_first_pcm"
    assert failure.value.evidence is not None
    assert failure.value.evidence.report["status"] == "streaming_contract_failed"
    assert failure.value.evidence.report["append_after_first_pcm"] is False
    assert failure.value.evidence.report["initial_prefill_count"] == 0
    assert failure.value.evidence.report["sample_count"] == 0
    paths = write_probe_output(failure.value.evidence, tmp_path / "failed-probe")
    assert paths.report.is_file()
    assert paths.audio.is_file()
    report = json.loads(paths.report.read_text(encoding="utf-8"))
    assert report["failure_code"] == "backend_waited_for_text_before_first_pcm"
    assert report["audio_file"] == "probe.wav"
    assert "你好" not in json.dumps(report)


def test_probe_rejects_pcm_before_initial_prefill() -> None:
    class FakeSession:
        generation_identity = "generation-1"
        initial_prefill_count = 0
        sample_rate = 24_000
        peak_memory_bytes = None

        def append_text(self, text: str) -> None:
            pass

        def finish_input(self) -> None:
            raise AssertionError("must fail before input is finished")

        def step(self, *, max_steps: int) -> ProbeEvent:
            return ProbeEvent("pcm", b"\x00\x00", 24_000, self.generation_identity)

        def cancel(self) -> None:
            pass

        def close(self) -> None:
            pass

    with pytest.raises(ProbeSessionError) as failure:
        run_probe_session(FakeSession(), artifact=_artifact(), vendor_commit=VENDOR_COMMIT)

    assert failure.value.failure_code == "initial_prefill_count_invalid"
    assert failure.value.evidence is not None
    assert failure.value.evidence.report["initial_prefill_count"] == 0
    assert failure.value.evidence.report["sample_count"] == 0


def test_probe_rejects_a_second_initial_prefill_after_first_pcm() -> None:
    class FakeSession:
        generation_identity = "generation-1"
        initial_prefill_count = 0
        sample_rate = 24_000
        peak_memory_bytes = None

        def __init__(self) -> None:
            self.steps = 0

        def append_text(self, text: str) -> None:
            pass

        def finish_input(self) -> None:
            pass

        def step(self, *, max_steps: int) -> ProbeEvent:
            self.steps += 1
            self.initial_prefill_count = self.steps
            if self.steps == 1:
                return ProbeEvent("pcm", b"\x00\x00", 24_000, self.generation_identity)
            return ProbeEvent("pcm", b"\x01\x00", 24_000, self.generation_identity)

        def cancel(self) -> None:
            pass

        def close(self) -> None:
            pass

    with pytest.raises(ProbeSessionError) as failure:
        run_probe_session(FakeSession(), artifact=_artifact(), vendor_commit=VENDOR_COMMIT)

    assert failure.value.failure_code == "initial_prefill_count_changed"
    assert failure.value.evidence is not None
    assert failure.value.evidence.report["initial_prefill_count"] == 2


def test_invalid_session_metadata_is_closed_before_rejection() -> None:
    class FakeSession:
        generation_identity = "generation-1"
        initial_prefill_count = 2
        sample_rate = 24_000
        peak_memory_bytes = None

        def __init__(self) -> None:
            self.cancelled = False
            self.closed = False

        def append_text(self, text: str) -> None:
            raise AssertionError("metadata must be checked before generation")

        def finish_input(self) -> None:
            raise AssertionError("metadata must be checked before generation")

        def step(self, *, max_steps: int) -> ProbeEvent:
            raise AssertionError("metadata must be checked before generation")

        def cancel(self) -> None:
            self.cancelled = True

        def close(self) -> None:
            self.closed = True

    session = FakeSession()
    with pytest.raises(ProbeSessionError) as failure:
        run_probe_session(session, artifact=_artifact(), vendor_commit=VENDOR_COMMIT)

    assert failure.value.failure_code == "initial_prefill_count_invalid"
    assert session.cancelled is True
    assert session.closed is True


def test_probe_output_only_contains_sanitized_report_and_pcm(tmp_path: Path) -> None:
    class FakeSession:
        generation_identity = "sensitive-generation-id"
        initial_prefill_count = 0
        sample_rate = 24_000
        peak_memory_bytes = 10

        def __init__(self) -> None:
            self.events = [
                ProbeEvent("pcm", b"\x00\x00" * 2, 24_000, self.generation_identity),
                ProbeEvent("pcm", b"\x01\x00" * 2, 24_000, self.generation_identity),
                ProbeEvent("finished", b"", 24_000, self.generation_identity),
            ]

        def append_text(self, text: str) -> None:
            pass

        def finish_input(self) -> None:
            pass

        def step(self, *, max_steps: int) -> ProbeEvent:
            self.initial_prefill_count = 1
            return self.events.pop(0)

        def cancel(self) -> None:
            pass

        def close(self) -> None:
            pass

    request = _request(tmp_path)
    evidence = run_probe_session(FakeSession(), artifact=_artifact(), vendor_commit=VENDOR_COMMIT)
    paths = write_probe_output(evidence, request.output_dir)

    assert paths.audio.is_file()
    assert paths.report.is_file()
    payload = paths.report.read_text(encoding="utf-8")
    assert "sensitive-generation-id" not in payload
    assert "你好" not in payload
    assert str(request.model_dir) not in payload
    assert '"audio_file": "probe.wav"' in payload
