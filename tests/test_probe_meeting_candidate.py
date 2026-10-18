"""Eight-slot candidate protocol checks run entirely with fake packets."""

from __future__ import annotations

import copy
import json
from dataclasses import replace

import pytest
from meeting_candidate_protocol import SDK_REVISION, candidate_activity_update
from probe_meeting_candidate import artifact_preflight, static_candidate_spec
from probe_meeting_candidate import main as probe_main


def packet(**overrides):
    return {
        "protocol_version": 3,
        "backend": "nemotron3_candidate",
        "sdk_revision": SDK_REVISION,
        "epoch": "epoch",
        "operation": "append",
        "ok": True,
        "processed_through": 160,
        "stable_through": 160,
        "frames": [{"start": 0, "end": 160, "scores": [0.5, 0.50001, 0, 0, 0, 0, 0, 1]}],
        **overrides,
    }


def parse(raw, *, accepted=160, processed=0, operation="append"):
    return candidate_activity_update(
        raw, epoch="epoch", step_id=0, processed=processed,
        accepted=accepted, operation=operation,
    )


def test_strict_threshold_preserves_ten_ms_interjection_and_slot_seven():
    frame = parse(packet()).frames[0]
    assert frame.active_slots == frozenset({1, 7})
    assert frame.span.length == 160  # No implicit 200 ms minimum turn.


@pytest.mark.parametrize("scores", [[0.1] * 7, [0.1] * 9, [float("nan")] * 8,
                                    [float("inf")] * 8, [True] * 8, [-0.1] * 8, [1.1] * 8])
def test_invalid_probabilities_fail_closed(scores):
    raw = packet()
    raw["frames"][0]["scores"] = scores
    with pytest.raises(ValueError):
        parse(raw)


@pytest.mark.parametrize("field,value", [("epoch", "stale"), ("operation", "finish"),
                                        ("sdk_revision", "wrong"), ("protocol_version", True),
                                        ("backend", "sortformer"), ("ok", 1),
                                        ("processed_through", 161), ("stable_through", 0)])
def test_identity_and_watermarks_are_not_trusted(field, value):
    with pytest.raises(ValueError):
        parse(packet(**{field: value}))


def test_one_sample_finish_tail_is_clipped_to_accepted_audio():
    raw = packet(
        operation="finish", processed_through=320, stable_through=320,
        frames=[{"start": 160, "end": 320, "scores": [0, 0, 0, 0, 0, 0, 0, 0.9]}],
    )
    result = parse(raw, accepted=161, processed=160, operation="finish")
    assert result.stable_through == result.processed_through == 161
    assert result.frames[0].span.start == 160 and result.frames[0].span.end == 161
    assert result.frames[0].active_slots == frozenset({7})


@pytest.mark.parametrize("frames", [[], [{"start": 1, "end": 160, "scores": [0] * 8}],
                                    [{"start": 0, "end": 320, "scores": [0] * 8}]])
def test_gaps_and_non_ten_ms_frames_cannot_advance(frames):
    with pytest.raises(ValueError):
        parse(packet(frames=copy.deepcopy(frames)))


def test_no_output_before_context_is_not_fabricated_silence():
    update = parse(packet(processed_through=0, stable_through=0, frames=[]))
    assert update.frames == () and update.processed_through == 0


def test_finish_must_cover_every_accepted_sample():
    with pytest.raises(ValueError):
        parse(packet(operation="finish", processed_through=0, stable_through=0, frames=[]),
              operation="finish")


@pytest.fixture
def artifacts(tmp_path):
    worker = tmp_path / "fake-worker"
    worker.write_bytes(b"never execute this fake worker")
    model = tmp_path / "models"
    bundle = model / "Nemotron3Diarizer_fast32.mlmodelc"
    bundle.mkdir(parents=True)
    (bundle / "coremldata.bin").write_bytes(b"fake compiled bytes")
    (model / "learnable_sil_emb.bin").write_bytes(bytes(2048))
    spec = static_candidate_spec(
        worker=worker, model_directory=model, preset="fast32",
        model_revision="a" * 40, compute_units="all",
    )
    return worker, model, spec


def test_preflight_reads_only_and_cannot_be_mistaken_for_runtime_or_quality(artifacts, monkeypatch):
    import subprocess

    worker, model, spec = artifacts

    def forbidden(*args, **kwargs):
        pytest.fail("preflight must not start a worker, compile or download")

    monkeypatch.setattr(subprocess, "Popen", forbidden)
    result = artifact_preflight(spec, worker=worker, model_directory=model)
    assert result["artifact_spec_matches"] is True
    assert result["runtime_identity_verified"] is False
    assert result["model_shape_verified"] is False
    assert result["certified_max_speakers"] is None
    assert result["verdict"] == "not_evaluated"
    assert str(model) not in json.dumps(result)


@pytest.mark.parametrize("change", ["worker", "model", "embedding", "preset", "decoder", "scorer"])
def test_preflight_rejects_every_changed_effective_artifact(artifacts, change):
    worker, model, spec = artifacts
    if change == "worker":
        worker.write_bytes(b"recompiled")
    elif change == "model":
        (model / "Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin").write_bytes(b"different")
    elif change == "embedding":
        (model / "learnable_sil_emb.bin").write_bytes(bytes(4))
    elif change == "preset":
        spec = replace(spec, preset={**spec.as_dict()["preset"], "chunk_len": 128})
    elif change == "decoder":
        spec = replace(spec, decoder={**spec.as_dict()["decoder"], "threshold": 0.25})
    else:
        spec = replace(spec, scorer={"unbound": True})
    with pytest.raises(ValueError):
        artifact_preflight(spec, worker=worker, model_directory=model)


def test_int8_or_split_candidate_is_not_silently_accepted(artifacts):
    worker, model, spec = artifacts
    with pytest.raises(ValueError):
        artifact_preflight(replace(spec, dtype="int8"), worker=worker, model_directory=model)
    with pytest.raises(ValueError):
        static_candidate_spec(worker=worker, model_directory=model, preset="fast32-split",
                              model_revision="a" * 40, compute_units="all")


def test_cli_only_exposes_readonly_preflight(artifacts, tmp_path, capsys):
    worker, model, spec = artifacts
    path = tmp_path / "candidate-spec.json"
    path.write_text(json.dumps(spec.as_dict()), encoding="utf-8")
    assert probe_main(["preflight", "--candidate-spec", str(path), "--worker", str(worker),
                       "--model-directory", str(model)]) == 0
    assert json.loads(capsys.readouterr().out)["verdict"] == "not_evaluated"
    with pytest.raises(SystemExit):
        probe_main(["evaluate-frozen-holdout"])


def test_preflight_rejects_symlink_embedding_without_reading_target(artifacts):
    worker, model, spec = artifacts
    embedding = model / "learnable_sil_emb.bin"
    embedding.unlink()
    embedding.symlink_to(model.parent / "unavailable-outside-file")
    with pytest.raises(ValueError):
        artifact_preflight(spec, worker=worker, model_directory=model)


def test_candidate_identity_binds_actual_attribution_and_replay_sources(artifacts, monkeypatch):
    import probe_meeting_candidate as probe
    from meeting_candidate_evidence import attribution_configuration

    worker, model, _ = artifacts
    observed = []
    original = probe._source_digest

    def digest(paths):
        observed.extend(paths)
        return original(paths)

    monkeypatch.setattr(probe, "_source_digest", digest)
    spec = probe.static_candidate_spec(
        worker=worker,
        model_directory=model,
        preset="fast32",
        model_revision="a" * 40,
        compute_units="all",
    )
    assert spec.as_dict()["attribution"] == attribution_configuration()
    assert {
        "examples/perf/meeting_candidate_runner.py",
        "examples/perf/meeting_candidate_evidence.py",
        "src/speechrail/domain/diarization/attribution.py",
    } <= set(observed)
    changed = replace(spec, attribution={**spec.as_dict()["attribution"], "min_support": 0.9})
    with pytest.raises(ValueError):
        probe.artifact_preflight(changed, worker=worker, model_directory=model)
