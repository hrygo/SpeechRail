"""Deterministic unit tests for Phase 1 (1-4 speaker Sortformer & joint SA-ASR) evaluation."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import tarfile
import wave
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from probe_meeting_sortformer_1to4 import (
    attribute_utterances_to_spans,
    evaluate_locked_1to4_split,
    frozen_phase1_candidate_spec,
    main,
    run_sortformer_session_on_wav,
    score_meeting_1to4_session,
    score_speaker_attributed_asr,
    summarize_1to4_strata,
    validate_frozen_holdout_unlock,
    validate_locked_1to4_manifest,
    verify_archive_ready,
    word_error_metrics,
)

from speechrail.domain.audio_timeline import (  # type: ignore[import-untyped]
    SampleSpan,
)
from speechrail.domain.diarization.types import (  # type: ignore[import-untyped]
    ActivityFrame,
    ActivityUpdate,
)


def _write_valid_tar_gz(path: Path) -> str:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        payload = b"SPEAKER meeting 1 0.00 1.00 <NA> <NA> spk1 <NA> <NA>\n"
        info = tarfile.TarInfo(name="Eval_Ali/sample.rttm")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    data = buffer.getvalue()
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def test_verify_archive_rejects_partial_and_verifies_valid_tar_gz(
    tmp_path: Path,
) -> None:
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    external = tmp_path / "external"
    external.mkdir()

    partial_file = external / "Eval_Ali.tar.gz.partial"
    partial_sha = _write_valid_tar_gz(partial_file)
    with pytest.raises(ValueError, match="partial archive download"):
        verify_archive_ready(
            partial_file,
            repository_root=repo_root,
            expected_sha256=partial_sha,
        )

    complete_file = external / "Eval_Ali.tar.gz"
    complete_sha = _write_valid_tar_gz(complete_file)
    result = verify_archive_ready(
        complete_file,
        repository_root=repo_root,
        expected_sha256=complete_sha,
        publisher_sha256=None,
    )
    assert result["gzip_tar_valid"] is True
    assert result["file_member_count"] == 1
    assert result["publisher_checksum_verified"] is False

    verified = verify_archive_ready(
        complete_file,
        repository_root=repo_root,
        expected_sha256=complete_sha,
        publisher_sha256=complete_sha,
    )
    assert verified["publisher_checksum_verified"] is True


def test_validate_locked_1to4_manifest_enforces_bounds_holdout_and_eval_ali_isolation(
    tmp_path: Path,
) -> None:
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    external = tmp_path / "external"
    external.mkdir()

    valid_fixture = {
        "id": "AliMeeting_Train_R001_S01",
        "speakers_count": 3,
        "duration_seconds": 600.0,
        "audio_sha256": "a" * 64,
        "reference_sha256": "b" * 64,
    }
    manifest_payload = {
        "schema_version": 1,
        "split_role": "frozen_holdout",
        "fixtures": [valid_fixture],
    }
    manifest_bytes = json.dumps(manifest_payload).encode("utf-8")
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    manifest_path = external / "evaluation.json"
    manifest_path.write_bytes(manifest_bytes)

    split_lock: dict[str, Any] = {
        "dataset": "AliMeeting",
        "license": "CC-BY-SA-4.0",
        "speaker_count_cap": 4,
        "splits": {
            "frozen_holdout": {
                "manifest_sha256": manifest_sha,
                "sessions": 1,
            },
            "holdout": {
                "manifest_sha256": "c" * 64,
                "sessions": 4,
            },
        },
    }
    (external / "split-lock.json").write_text(json.dumps(split_lock), encoding="utf-8")

    fixtures, metadata = validate_locked_1to4_manifest(
        manifest_path,
        manifest_bytes,
        repository_root=repo_root,
        candidate_count=1,
    )
    assert len(fixtures) == 1
    assert metadata["split_role"] == "frozen_holdout"

    # Multi-candidate tuning sweeps must be rejected on frozen_holdout (e.g. AliMeeting Eval)
    with pytest.raises(ValueError, match="cannot run multi-candidate tuning sweeps"):
        validate_locked_1to4_manifest(
            manifest_path,
            manifest_bytes,
            repository_root=repo_root,
            candidate_count=4,
        )

    # Reject partitioning or using AliMeeting Eval in a development manifest
    eval_as_dev_bytes = json.dumps(
        {
            "schema_version": 1,
            "split_role": "development",
            "source_split": "Eval_Ali",
            "fixtures": [valid_fixture],
        }
    ).encode("utf-8")
    eval_as_dev_sha = hashlib.sha256(eval_as_dev_bytes).hexdigest()
    split_lock["splits"]["development"] = {
        "manifest_sha256": eval_as_dev_sha,
        "sessions": 1,
    }
    (external / "split-lock.json").write_text(json.dumps(split_lock), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match="AliMeeting Eval or holdout splits cannot be partitioned or used as development",
    ):
        validate_locked_1to4_manifest(
            manifest_path,
            eval_as_dev_bytes,
            repository_root=repo_root,
            candidate_count=1,
        )

    # Reject Eval_Ali fixture ID inside a development manifest
    eval_fixture_dev_bytes = json.dumps(
        {
            "schema_version": 1,
            "split_role": "development",
            "fixtures": [{**valid_fixture, "id": "Eval_Ali_R0001_M0001"}],
        }
    ).encode("utf-8")
    eval_fixture_dev_sha = hashlib.sha256(eval_fixture_dev_bytes).hexdigest()
    split_lock["splits"]["development"] = {
        "manifest_sha256": eval_fixture_dev_sha,
        "sessions": 1,
    }
    (external / "split-lock.json").write_text(json.dumps(split_lock), encoding="utf-8")
    with pytest.raises(
        ValueError,
        match="AliMeeting Eval or R004 fixture cannot be used in a development split",
    ):
        validate_locked_1to4_manifest(
            manifest_path,
            eval_fixture_dev_bytes,
            repository_root=repo_root,
            candidate_count=1,
        )

    # Reject R004 holdout or >4 speakers
    for bad_fixture in (
        {**valid_fixture, "id": "R004_S01"},
        {**valid_fixture, "speakers_count": 5},
    ):
        bad_bytes = json.dumps(
            {"schema_version": 1, "split_role": "development", "fixtures": [bad_fixture]}
        ).encode("utf-8")
        bad_sha = hashlib.sha256(bad_bytes).hexdigest()
        split_lock["splits"]["development"] = {"manifest_sha256": bad_sha, "sessions": 1}
        (external / "split-lock.json").write_text(json.dumps(split_lock), encoding="utf-8")
        with pytest.raises(ValueError, match="fixture violates 1-4 speaker"):
            validate_locked_1to4_manifest(
                manifest_path,
                bad_bytes,
                repository_root=repo_root,
                candidate_count=1,
            )


def test_frozen_candidate_spec_and_holdout_unlock_gate(tmp_path: Path) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    spec_info = frozen_phase1_candidate_spec(repository_root=repo_root)
    spec_sha = spec_info["candidate_spec_sha256"]
    assert len(spec_sha) == 64
    assert spec_info["spec"]["diarization"]["system_cap"] == 4
    assert spec_info["spec"]["diarization"]["activity_threshold"] == 0.25

    external = tmp_path / "external"
    external.mkdir()
    receipt_path = external / "development-certification.json"
    dev_sha = "d" * 64
    holdout_sha = "e" * 64

    # Incomplete development strata (e.g. missing 1_speaker) cannot unlock frozen holdout
    receipt_path.write_text(
        json.dumps(
            {
                "split_role": "development",
                "manifest_sha256": dev_sha,
                "candidate_spec_sha256": spec_sha,
                "all_1to4_strata_observed": False,
                "phase1_diarization_certified": False,
                "verdict": "no-go",
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="frozen holdout is locked"):
        validate_frozen_holdout_unlock(
            receipt_path,
            repository_root=repo_root,
            expected_candidate_spec_sha256=spec_sha,
            holdout_manifest_sha256=holdout_sha,
        )

    # Full development certification unlocks frozen holdout
    receipt_path.write_text(
        json.dumps(
            {
                "split_role": "development",
                "manifest_sha256": dev_sha,
                "candidate_spec_sha256": spec_sha,
                "all_1to4_strata_observed": True,
                "phase1_diarization_certified": True,
                "verdict": "go",
            }
        ),
        encoding="utf-8",
    )
    unlocked = validate_frozen_holdout_unlock(
        receipt_path,
        repository_root=repo_root,
        expected_candidate_spec_sha256=spec_sha,
        holdout_manifest_sha256=holdout_sha,
    )
    assert unlocked["holdout_unlocked"] is True

    # Preflight CLI returns exit code 2 when --require-pass is set and strata are unobserved
    exit_code = main(
        [
            "--mode",
            "preflight",
            "--benchmark-root",
            str(external / "missing-benchmarks"),
            "--model-root",
            str(external / "missing-models"),
            "--require-pass",
        ]
    )
    assert exit_code == 2


def test_speaker_attributed_asr_separates_speaker_confusion_and_penalizes_unknown() -> None:
    reference = [
        {"start": 0.0, "end": 2.0, "speaker": "R1", "text": "今天讨论预算"},
        {"start": 2.5, "end": 4.5, "speaker": "R2", "text": "明天确认方案"},
    ]
    consistent_hyp = [
        {"start": 0.1, "end": 1.9, "speaker": "S2", "text": "今天讨论预算"},
        {"start": 2.6, "end": 4.4, "speaker": "S1", "text": "明天确认方案"},
    ]
    perfect = score_speaker_attributed_asr(
        reference, consistent_hyp, duration=5.0, tcp_collar_seconds=1.0
    )
    assert perfect["cp_cer"] == 0.0
    assert perfect["tcp_cer"] == 0.0
    assert perfect["cp_wer"] == 0.0
    assert perfect["tcp_wer"] == 0.0
    assert perfect["di_cp_cer"] == 0.0
    assert perfect["speaker_confusion_cer_delta"] == 0.0

    collapsed_hyp = [
        {"start": 0.1, "end": 1.9, "speaker": "S1", "text": "今天讨论预算"},
        {"start": 2.6, "end": 4.4, "speaker": "S1", "text": "明天确认方案"},
    ]
    collapsed = score_speaker_attributed_asr(
        reference, collapsed_hyp, duration=5.0, tcp_collar_seconds=1.0
    )
    assert collapsed["di_cp_cer"] == 0.0
    assert collapsed["cp_cer"] is not None and collapsed["cp_cer"] > 0.5
    assert (
        collapsed["speaker_confusion_cer_delta"] is not None
        and collapsed["speaker_confusion_cer_delta"] > 0.5
    )

    unknown_hyp = [
        {"start": 0.1, "end": 1.9, "speaker": "S1", "text": "今天讨论预算"},
        {"start": 2.6, "end": 4.4, "speaker": "unknown", "text": "明天确认方案"},
    ]
    unknown_scored = score_speaker_attributed_asr(
        reference, unknown_hyp, duration=5.0, tcp_collar_seconds=1.0
    )
    assert unknown_scored["unknown_utterance_count"] == 1
    assert unknown_scored["cp_char_errors"] == 12


def test_word_metrics_preserve_utterance_boundaries_and_leave_character_metrics_unchanged() -> None:
    spans = [{"start": 0.0, "end": 2.0, "speaker": "S1"}]
    english = score_meeting_1to4_session(
        reference_speaker_spans=[{"start": 0.0, "end": 2.0, "speaker": "R1"}],
        hypothesis_speaker_spans=spans,
        reference_utterances=[
            {"start": 0.0, "end": 1.0, "speaker": "R1", "text": "hello"},
            {"start": 1.0, "end": 2.0, "speaker": "R1", "text": "world"},
        ],
        hypothesis_utterances=[
            {"start": 0.0, "end": 2.0, "speaker": "S1", "text": "helloworld"}
        ],
        duration=2.0,
    )
    assert english["asr_only"]["reference_words"] == 2
    assert english["asr_only"]["word_errors"] == 2
    assert english["asr_only"]["wer"] == 1.0
    assert english["asr_only"]["cer"] == 0.0
    assert english["speaker_attributed"]["cp_wer"] == 1.0
    assert english["speaker_attributed"]["tcp_wer"] == 1.0
    assert english["speaker_attributed"]["di_cp_wer"] == 1.0
    assert english["speaker_attributed"]["cp_cer"] == 0.0
    assert english["speaker_attributed"]["di_cp_cer"] == 0.0

    chinese = score_meeting_1to4_session(
        reference_speaker_spans=[{"start": 0.0, "end": 2.0, "speaker": "R1"}],
        hypothesis_speaker_spans=spans,
        reference_utterances=[
            {"start": 0.0, "end": 1.0, "speaker": "R1", "text": "你好"},
            {"start": 1.0, "end": 2.0, "speaker": "R1", "text": "世界"},
        ],
        hypothesis_utterances=[
            {"start": 0.0, "end": 2.0, "speaker": "S1", "text": "你好世界"}
        ],
        duration=2.0,
    )
    assert chinese["asr_only"]["cer"] == 0.0
    assert chinese["speaker_attributed"]["cp_cer"] == 0.0
    assert chinese["speaker_attributed"]["di_cp_cer"] == 0.0
    assert chinese["speaker_attributed"]["cp_wer"] == 0.0
    assert chinese["speaker_attributed"]["di_cp_wer"] == 0.0


def test_speaker_attributed_asr_discards_segments_wholly_in_tail_padding() -> None:
    scored = score_meeting_1to4_session(
        reference_speaker_spans=[{"start": 0.0, "end": 1.0, "speaker": "R1"}],
        hypothesis_speaker_spans=[{"start": 0.0, "end": 1.0, "speaker": "S1"}],
        reference_utterances=[
            {"start": 0.0, "end": 1.0, "speaker": "R1", "text": "hello"}
        ],
        hypothesis_utterances=[
            {"start": 0.0, "end": 1.0, "speaker": "S1", "text": "hello"},
            {"start": 10.2, "end": 10.8, "speaker": "S1", "text": "tail"},
        ],
        duration=10.0,
    )

    assert scored["asr_only"]["cer"] == 0.0
    assert scored["asr_only"]["wer"] == 0.0
    assert scored["speaker_attributed"]["cp_wer"] == 0.0
    assert scored["speaker_attributed"]["tcp_wer"] == 0.0
    assert scored["speaker_attributed"]["di_cp_wer"] == 0.0


def test_score_meeting_1to4_session_and_stratification_marks_missing_strata() -> None:
    ref_spans = [
        {"start": 0.0, "end": 4.0, "speaker": "R1"},
        {"start": 4.5, "end": 8.5, "speaker": "R2"},
    ]
    hyp_spans = [
        {"start": 0.0, "end": 4.0, "speaker": "S1"},
        {"start": 4.5, "end": 8.5, "speaker": "S2"},
    ]
    ref_utts = [
        {"start": 0.0, "end": 4.0, "speaker": "R1", "text": "第一句测试内容"},
        {"start": 4.5, "end": 8.5, "speaker": "R2", "text": "第二句测试内容"},
    ]
    hyp_utts = [
        {"start": 0.0, "end": 4.0, "speaker": "S1", "text": "第一句测试内容"},
        {"start": 4.5, "end": 8.5, "speaker": "S2", "text": "第二句测试内容"},
    ]
    session_metrics = score_meeting_1to4_session(
        reference_speaker_spans=ref_spans,
        hypothesis_speaker_spans=hyp_spans,
        reference_utterances=ref_utts,
        hypothesis_utterances=hyp_utts,
        duration=9.0,
    )
    assert session_metrics["speakers_count"] == 2
    assert session_metrics["diarization_gate"] == "pass"
    assert (
        session_metrics["diarization_only"]["other_min_known_coverage_applicable"]
        is False
    )
    assert session_metrics["asr_only"]["cer"] == 0.0
    assert session_metrics["speaker_attributed"]["cp_cer"] == 0.0

    summary = summarize_1to4_strata([session_metrics])
    assert summary["observed_speaker_counts"] == [2]
    assert summary["unobserved_speaker_counts"] == [1, 3, 4]
    assert summary["all_1to4_strata_observed"] is False
    assert summary["phase1_diarization_certified"] is False
    assert summary["verdict"] == "no-go"
    assert summary["strata"]["1_speaker"]["status"] == "unobserved_stratum"
    assert summary["strata"]["1_speaker"]["quality_gate"] == "no-go"
    assert summary["strata"]["2_speakers"]["status"] == "observed"
    assert summary["strata"]["2_speakers"]["quality_gate"] == "go"
    assert summary["strata"]["2_speakers"]["other_min_known_coverage"] == "N/A"


class _FakeSortformerSession:
    def __init__(self, speakers_count: int = 2) -> None:
        self.speakers_count = speakers_count
        self.appended = 0
        self.finished_through: int | None = None
        self.cancelled = False

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        assert start_sample == self.appended
        self.appended += len(pcm16) // 2

    async def finish(self, *, through_sample: int) -> None:
        self.finished_through = through_sample

    async def updates(self) -> AsyncIterator[ActivityUpdate]:
        frames: list[ActivityFrame] = []
        for idx in range(self.speakers_count):
            start = idx * 16_000
            end = (idx + 1) * 16_000
            scores = tuple(0.9 if slot == idx else 0.01 for slot in range(4))
            frames.append(
                ActivityFrame(
                    span=SampleSpan(start, end),
                    scores=scores,  # type: ignore[arg-type]
                    active_slots=frozenset({idx}),
                )
            )
        total = self.speakers_count * 16_000
        yield ActivityUpdate(
            epoch="ep-1",
            step_id=0,
            replace_span=SampleSpan(0, total),
            frames=tuple(frames),
            processed_through=total,
            stable_through=total,
        )

    async def cancel(self) -> None:
        self.cancelled = True


def test_sortformer_wav_bridge_and_utterance_attribution(tmp_path: Path) -> None:
    wav_path = tmp_path / "sample.wav"
    with wave.open(str(wav_path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16_000)
        wav_file.writeframes(b"\x00\x00" * 32_000)

    fake_session = _FakeSortformerSession(speakers_count=2)
    spans, duration = asyncio.run(
        run_sortformer_session_on_wav(
            wav_path,
            session_factory=lambda _epoch: fake_session,
            epoch="ep-1",
            chunk_samples=8_000,
        )
    )
    assert duration == 2.0
    assert fake_session.finished_through == 32_000
    assert spans == [
        {"start": 0.0, "end": 1.0, "speaker": "S1"},
        {"start": 1.0, "end": 2.0, "speaker": "S2"},
    ]

    attributed = attribute_utterances_to_spans(
        [
            {"start": 0.1, "end": 0.9, "text": "你好 SpeechRail 123"},
            {"start": 1.1, "end": 1.9, "text": "收到"},
        ],
        spans,
        duration=duration,
    )
    assert [u["speaker"] for u in attributed] == ["S1", "S2"]
    wer = word_error_metrics("你好 SpeechRail 123", "你好 speechrail 123")
    assert wer["wer"] == 0.0
    assert wer["reference_words"] == 4


def test_evaluate_locked_1to4_split_end_to_end_dev_and_holdout(tmp_path: Path) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    external = tmp_path / "external"
    external.mkdir()

    fixtures: list[dict[str, Any]] = []
    speaker_map: dict[str, int] = {}
    for count in (1, 2, 3, 4):
        sid = f"Train_Ali_S{count}"
        speaker_map[sid] = count
        wav_path = external / f"{sid}.wav"
        with wave.open(str(wav_path), "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(16_000)
            wav_file.writeframes(b"\x00\x00" * (16_000 * count))
        ref_path = external / f"{sid}.ref.json"
        ref_payload = {
            "speaker_spans": [
                {"start": float(i), "end": float(i + 1), "speaker": f"R{i + 1}"}
                for i in range(count)
            ],
            "utterances": [
                {
                    "start": float(i) + 0.1,
                    "end": float(i + 1) - 0.1,
                    "speaker": f"R{i + 1}",
                    "text": f"说话人{i + 1}内容",
                }
                for i in range(count)
            ],
        }
        ref_bytes = json.dumps(ref_payload, ensure_ascii=False).encode("utf-8")
        ref_path.write_bytes(ref_bytes)

        asr_path = external / f"{sid}.asr.json"
        asr_payload = {
            "segments": [
                {
                    "start": float(i) + 0.1,
                    "end": float(i + 1) - 0.1,
                    "text": f"说话人{i + 1}内容",
                }
                for i in range(count)
            ]
        }
        asr_bytes = json.dumps(asr_payload, ensure_ascii=False).encode("utf-8")
        asr_path.write_bytes(asr_bytes)

        fixtures.append(
            {
                "id": sid,
                "speakers_count": count,
                "duration_seconds": float(count),
                "path": str(wav_path),
                "audio_sha256": hashlib.sha256(wav_path.read_bytes()).hexdigest(),
                "reference_path": str(ref_path),
                "reference_sha256": hashlib.sha256(ref_bytes).hexdigest(),
                "asr_hypothesis_path": str(asr_path),
                "asr_hypothesis_sha256": hashlib.sha256(asr_bytes).hexdigest(),
            }
        )

    dev_manifest_bytes = json.dumps(
        {
            "schema_version": 1,
            "split_role": "development",
            "dataset": "AliMeeting_Train_Plus_1Spk_Control",
            "source_split": "Train_Ali_near",
            "fixtures": fixtures,
        }
    ).encode("utf-8")
    dev_manifest_path = external / "development.json"
    dev_manifest_path.write_bytes(dev_manifest_bytes)
    dev_sha = hashlib.sha256(dev_manifest_bytes).hexdigest()

    holdout_fixtures = [
        {**f, "id": f"Eval_Ali_S{f['speakers_count']}"} for f in fixtures
    ]
    for hf in holdout_fixtures:
        speaker_map[hf["id"]] = int(hf["speakers_count"])
    holdout_manifest_bytes = json.dumps(
        {
            "schema_version": 1,
            "split_role": "frozen_holdout",
            "dataset": "AliMeeting_Eval_Plus_1Spk_Control",
            "source_split": "Eval_Ali",
            "fixtures": holdout_fixtures,
        }
    ).encode("utf-8")
    holdout_manifest_path = external / "frozen_holdout.json"
    holdout_manifest_path.write_bytes(holdout_manifest_bytes)
    holdout_sha = hashlib.sha256(holdout_manifest_bytes).hexdigest()

    split_lock = {
        "dataset": "AliMeeting",
        "license": "CC-BY-SA-4.0",
        "speaker_count_cap": 4,
        "splits": {
            "development": {
                "manifest_sha256": dev_sha,
                "sessions": 4,
                "source_split": "Train_Ali_near",
            },
            "frozen_holdout": {
                "manifest_sha256": holdout_sha,
                "sessions": 4,
                "source_split": "Eval_Ali",
            },
        },
    }
    (external / "split-lock.json").write_text(json.dumps(split_lock), encoding="utf-8")

    dev_out = external / "dev-out"
    dev_report = asyncio.run(
        evaluate_locked_1to4_split(
            manifest_path=dev_manifest_path,
            output_dir=dev_out,
            repository_root=repo_root,
            expected_split_role="development",
            session_factory=lambda epoch: _FakeSortformerSession(
                speakers_count=speaker_map[epoch]
            ),
        )
    )
    assert dev_report["verdict"] == "go"
    assert dev_report["all_1to4_strata_observed"] is True
    assert dev_report["phase1_diarization_certified"] is True
    assert (dev_out / "development-certification.json").is_file()

    holdout_out = external / "holdout-out"
    holdout_report = asyncio.run(
        evaluate_locked_1to4_split(
            manifest_path=holdout_manifest_path,
            output_dir=holdout_out,
            repository_root=repo_root,
            expected_split_role="frozen_holdout",
            session_factory=lambda epoch: _FakeSortformerSession(
                speakers_count=speaker_map[epoch]
            ),
            development_receipt_path=dev_out / "development-certification.json",
        )
    )
    assert holdout_report["verdict"] == "go"
    assert holdout_report["holdout_unlock"]["holdout_unlocked"] is True
    assert (holdout_out / "frozen-holdout-report.json").is_file()
