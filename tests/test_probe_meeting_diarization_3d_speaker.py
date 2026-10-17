from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples" / "perf"))

from diarization_3d_speaker_runner import (
    _apply_cluster_type,
    _construct_diarizer,
    _umap_seed_context,
)
from probe_meeting_diarization_3d_speaker import (
    CandidateRunnerError,
    _parse_rttm,
    _read_dependency_lock,
    _require_external_executable_path,
    _require_external_path,
    _validate_runner_error,
    _validate_runner_metadata,
)


def _write_rttm(tmp_path: Path, contents: str) -> Path:
    path = tmp_path / "prediction.rttm"
    path.write_text(contents, encoding="utf-8")
    return path


def test_rttm_parser_maps_numeric_speakers_and_clips_bounded_tail_padding(
    tmp_path: Path,
) -> None:
    path = _write_rttm(
        tmp_path,
        "\n".join(
            (
                "SPEAKER meeting-0001 0 0.100 0.500 <NA> <NA> 0 <NA> <NA>",
                "SPEAKER meeting-0001 0 0.400 0.500 <NA> <NA> 1 <NA> <NA>",
                "SPEAKER meeting-0001 0 9.800 0.318 <NA> <NA> 1 <NA> <NA>",
            )
        ),
    )

    segments, clipped_count, unassigned_count = _parse_rttm(
        path, duration=10.0, expected_record_id="meeting-0001"
    )

    assert segments == [
        {"start": 0.1, "end": 0.6, "speaker": "S1"},
        {"start": 0.4, "end": 0.9, "speaker": "S2"},
        {"start": 9.8, "end": 10.0, "speaker": "S2"},
    ]
    assert clipped_count == 1
    assert unassigned_count == 0


def test_rttm_parser_accepts_an_empty_prediction(tmp_path: Path) -> None:
    path = _write_rttm(tmp_path, "")

    assert _parse_rttm(path, duration=10.0, expected_record_id="meeting-0001") == ([], 0, 0)


def test_rttm_parser_counts_hdbscan_noise_as_unassigned_speech(tmp_path: Path) -> None:
    path = _write_rttm(
        tmp_path,
        "\n".join(
            (
                "SPEAKER meeting-0001 0 0.100 0.500 <NA> <NA> 0 <NA> <NA>",
                "SPEAKER meeting-0001 0 0.600 0.500 <NA> <NA> -1 <NA> <NA>",
                "SPEAKER meeting-0001 0 9.800 0.400 <NA> <NA> -1 <NA> <NA>",
            )
        ),
    )

    segments, clipped_count, unassigned_count = _parse_rttm(
        path,
        duration=10.0,
        expected_record_id="meeting-0001",
        allow_noise_label=True,
    )

    assert segments == [{"start": 0.1, "end": 0.6, "speaker": "S1"}]
    assert clipped_count == 1
    assert unassigned_count == 2


def test_rttm_parser_rejects_hdbscan_noise_outside_the_umap_candidate(
    tmp_path: Path,
) -> None:
    path = _write_rttm(
        tmp_path, "SPEAKER meeting-0001 0 0.1 0.5 <NA> <NA> -1 <NA> <NA>"
    )

    with pytest.raises(ValueError, match="invalid candidate RTTM row"):
        _parse_rttm(path, duration=10.0, expected_record_id="meeting-0001")


@pytest.mark.parametrize(
    "contents,expected_record_id",
    [
        ("SPEAKER wrong-id 0 0.1 0.5 <NA> <NA> 0 <NA> <NA>", "meeting-0001"),
        ("SPEAKER meeting-0001 0 -0.1 0.5 <NA> <NA> 0 <NA> <NA>", "meeting-0001"),
        ("SPEAKER meeting-0001 0 0.1 nan <NA> <NA> 0 <NA> <NA>", "meeting-0001"),
        ("SPEAKER meeting-0001 0 0.1 0.5 <NA> <NA> speaker-one <NA> <NA>", "meeting-0001"),
    ],
)
def test_rttm_parser_rejects_unexpected_ids_times_and_labels(
    tmp_path: Path, contents: str, expected_record_id: str
) -> None:
    path = _write_rttm(tmp_path, contents)

    with pytest.raises(ValueError):
        _parse_rttm(path, duration=10.0, expected_record_id=expected_record_id)


def test_rttm_parser_rejects_a_model_tail_overrun_above_one_second(tmp_path: Path) -> None:
    path = _write_rttm(
        tmp_path, "SPEAKER meeting-0001 0 9.0 2.01 <NA> <NA> 0 <NA> <NA>"
    )

    with pytest.raises(ValueError, match="tail-padding bound"):
        _parse_rttm(path, duration=10.0, expected_record_id="meeting-0001")


def test_external_path_guard_accepts_external_paths(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    external = tmp_path / "artifacts" / "manifest.json"

    assert _require_external_path(external, repository_root=repository) == external.resolve()


def test_external_path_guard_rejects_paths_inside_the_repository(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    input_path = repository / "audio.wav"

    with pytest.raises(ValueError, match="must remain external"):
        _require_external_path(input_path, repository_root=repository)


def test_external_executable_guard_preserves_virtualenv_symlink(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    base_python = tmp_path / "base-python"
    base_python.write_text("", encoding="utf-8")
    venv_python = tmp_path / "venv" / "bin" / "python"
    venv_python.parent.mkdir(parents=True)
    venv_python.symlink_to(base_python)

    resolved = _require_external_executable_path(
        venv_python, repository_root=repository
    )

    assert resolved == venv_python.absolute()
    assert resolved.is_symlink()


def test_external_executable_guard_rejects_a_symlink_into_the_repository(
    tmp_path: Path,
) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    internal_python = repository / "python"
    internal_python.write_text("", encoding="utf-8")
    external_link = tmp_path / "venv" / "bin" / "python"
    external_link.parent.mkdir(parents=True)
    external_link.symlink_to(internal_python)

    with pytest.raises(ValueError, match="must remain external"):
        _require_external_executable_path(
            external_link, repository_root=repository
        )


def test_dependency_lock_is_hashed_and_kept_external(tmp_path: Path) -> None:
    import hashlib

    repository = tmp_path / "repository"
    repository.mkdir()
    lock = tmp_path / "artifacts" / "requirements.lock.txt"
    lock.parent.mkdir()
    lock.write_text("numpy==2.2.6 --hash=sha256:" + "a" * 64, encoding="utf-8")

    resolved, contents, digest = _read_dependency_lock(lock, repository_root=repository)

    assert resolved == lock.resolve()
    assert contents == lock.read_bytes()
    assert digest == hashlib.sha256(contents).hexdigest()


def test_dependency_lock_rejects_an_empty_or_repository_local_file(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    empty_lock = tmp_path / "empty.lock"
    empty_lock.write_bytes(b"")
    internal_lock = repository / "requirements.lock.txt"
    internal_lock.write_text("numpy==2.2.6", encoding="utf-8")

    with pytest.raises(ValueError, match="dependency lock is empty"):
        _read_dependency_lock(empty_lock, repository_root=repository)
    with pytest.raises(ValueError, match="must remain external"):
        _read_dependency_lock(internal_lock, repository_root=repository)


@pytest.mark.parametrize("payload", [
    {"error": "RuntimeError"},
    {"error": "OSError_23"},
    {"error": "ModuleNotFoundError", "missing_module": "fastcluster"},
])
def test_runner_error_event_accepts_only_sanitized_exception_types(
    payload: dict[str, str],
) -> None:
    assert _validate_runner_error(payload) == payload


@pytest.mark.parametrize(
    "payload",
    [
        {"error": "RuntimeError", "message": "private details"},
        {"error": "secret/path"},
        {"error": 1},
        {"error": "RuntimeError", "missing_module": "module"},
        {"error": "ModuleNotFoundError", "missing_module": "path/name"},
        [],
    ],
)
def test_runner_error_event_rejects_untrusted_details(payload: object) -> None:
    with pytest.raises(ValueError, match="error record is invalid"):
        _validate_runner_error(payload)


def test_candidate_runner_failure_exposes_only_exit_and_exception_type() -> None:
    failure = CandidateRunnerError(
        exit_code=1,
        runner_error={"error": "ModuleNotFoundError", "missing_module": "fastcluster"},
    )

    assert failure.as_record() == {
        "error": "candidate_runner_failed",
        "runner_exit_code": 1,
        "runner_error_type": "ModuleNotFoundError",
        "missing_module": "fastcluster",
    }


def test_diarizer_uses_mps_embeddings_with_modelscope_vad_on_cpu(tmp_path: Path) -> None:
    calls: list[tuple[object, object]] = []

    def original_vad_loader(device: object, cache_dir: object) -> str:
        calls.append((device, cache_dir))
        return "vad"

    def create_diarizer(**kwargs: object) -> SimpleNamespace:
        vad = infer_module.get_voice_activity_detection_model(
            kwargs["device"], kwargs["model_cache_dir"]
        )
        return SimpleNamespace(
            device=kwargs["device"],
            vad=vad,
            cluster=SimpleNamespace(
                mer_cos=0.8,
                min_cluster_size=4,
                cluster=SimpleNamespace(
                    pval=0.012, min_num_spks=1, max_num_spks=15, k=None
                ),
            ),
            include_overlap=kwargs["include_overlap"],
        )

    def make_device(name: str) -> str:
        return f"device:{name}"

    infer_module = SimpleNamespace(
        get_voice_activity_detection_model=original_vad_loader,
        Diarization3Dspeaker=create_diarizer,
    )
    torch_module = SimpleNamespace(device=make_device)

    diarizer = _construct_diarizer(
        infer_module,
        torch_module,
        embedding_device="mps",
        model_cache_dir=tmp_path,
    )

    assert diarizer.device == "device:mps"
    assert diarizer.vad == "vad"
    assert diarizer.cluster.mer_cos == 0.8
    assert calls == [("device:cpu", str(tmp_path))]
    assert infer_module.get_voice_activity_detection_model is original_vad_loader


def test_diarizer_can_disable_only_post_clustering_cosine_merge(tmp_path: Path) -> None:
    def load_vad(device: object, cache_dir: object) -> str:
        return "vad"

    def create_diarizer(**kwargs: object) -> SimpleNamespace:
        infer_module.get_voice_activity_detection_model(
            kwargs["device"], kwargs["model_cache_dir"]
        )
        return SimpleNamespace(
            cluster=SimpleNamespace(
                mer_cos=0.8,
                min_cluster_size=4,
                cluster=SimpleNamespace(
                    pval=0.012, min_num_spks=1, max_num_spks=15, k=None
                ),
            )
        )

    def make_device(name: str) -> str:
        return name

    infer_module = SimpleNamespace(
        get_voice_activity_detection_model=load_vad,
        Diarization3Dspeaker=create_diarizer,
    )
    torch_module = SimpleNamespace(device=make_device)

    diarizer = _construct_diarizer(
        infer_module,
        torch_module,
        embedding_device="mps",
        model_cache_dir=tmp_path,
        disable_cosine_merge=True,
    )

    assert diarizer.cluster.mer_cos is None


def test_diarizer_can_disable_minor_cluster_reassignment(tmp_path: Path) -> None:
    def load_vad(device: object, cache_dir: object) -> str:
        return "vad"

    def create_diarizer(**kwargs: object) -> SimpleNamespace:
        infer_module.get_voice_activity_detection_model(
            kwargs["device"], kwargs["model_cache_dir"]
        )
        return SimpleNamespace(
            cluster=SimpleNamespace(
                mer_cos=0.8,
                min_cluster_size=4,
                cluster=SimpleNamespace(
                    pval=0.012, min_num_spks=1, max_num_spks=15, k=None
                ),
            )
        )

    def make_device(name: str) -> str:
        return name

    infer_module = SimpleNamespace(
        get_voice_activity_detection_model=load_vad,
        Diarization3Dspeaker=create_diarizer,
    )
    torch_module = SimpleNamespace(device=make_device)

    diarizer = _construct_diarizer(
        infer_module,
        torch_module,
        embedding_device="mps",
        model_cache_dir=tmp_path,
        min_cluster_size=0,
    )

    assert diarizer.cluster.min_cluster_size == 0
    assert diarizer.cluster.mer_cos == 0.8


def test_diarizer_can_tune_spectral_sparsification(tmp_path: Path) -> None:
    def load_vad(device: object, cache_dir: object) -> str:
        return "vad"

    def create_diarizer(**kwargs: object) -> SimpleNamespace:
        infer_module.get_voice_activity_detection_model(
            kwargs["device"], kwargs["model_cache_dir"]
        )
        return SimpleNamespace(
            cluster=SimpleNamespace(
                mer_cos=0.8,
                min_cluster_size=4,
                cluster=SimpleNamespace(
                    pval=0.012, min_num_spks=1, max_num_spks=15, k=None
                ),
            )
        )

    def make_device(name: str) -> str:
        return name

    infer_module = SimpleNamespace(
        get_voice_activity_detection_model=load_vad,
        Diarization3Dspeaker=create_diarizer,
    )
    diarizer = _construct_diarizer(
        infer_module,
        SimpleNamespace(device=make_device),
        embedding_device="mps",
        model_cache_dir=tmp_path,
        spectral_pval=0.003,
    )

    assert diarizer.cluster.cluster.pval == 0.003
    assert diarizer.cluster.min_cluster_size == 4
    assert diarizer.cluster.mer_cos == 0.8


def test_diarizer_can_set_global_speaker_floor_without_oracle_count(
    tmp_path: Path,
) -> None:
    def load_vad(device: object, cache_dir: object) -> str:
        return "vad"

    def create_diarizer(**kwargs: object) -> SimpleNamespace:
        infer_module.get_voice_activity_detection_model(
            kwargs["device"], kwargs["model_cache_dir"]
        )
        return SimpleNamespace(
            cluster=SimpleNamespace(
                mer_cos=0.8,
                min_cluster_size=4,
                cluster=SimpleNamespace(
                    pval=0.012, min_num_spks=1, max_num_spks=15, k=None
                ),
            )
        )

    def make_device(name: str) -> str:
        return name

    infer_module = SimpleNamespace(
        get_voice_activity_detection_model=load_vad,
        Diarization3Dspeaker=create_diarizer,
    )
    diarizer = _construct_diarizer(
        infer_module,
        SimpleNamespace(device=make_device),
        embedding_device="mps",
        model_cache_dir=tmp_path,
        min_num_spks=4,
    )

    assert diarizer.cluster.cluster.min_num_spks == 4
    assert diarizer.cluster.cluster.k is None


def test_ahc_cluster_type_uses_upstream_cosine_threshold_defaults() -> None:
    calls: dict[str, object] = {}

    class FakeCommonClustering:
        def __init__(self, **kwargs: object) -> None:
            calls.update(kwargs)

    diarizer = SimpleNamespace(cluster=object())

    _apply_cluster_type(
        diarizer,
        FakeCommonClustering,
        cluster_type="AHC",
        fix_cos_thr=0.4,
    )

    assert calls == {
        "cluster_type": "AHC",
        "cluster_line": 40,
        "mer_cos": 0.8,
        "min_cluster_size": 4,
        "fix_cos_thr": 0.4,
    }
    assert isinstance(diarizer.cluster, FakeCommonClustering)


def test_umap_hdbscan_cluster_type_uses_upstream_defaults() -> None:
    calls: dict[str, object] = {}

    class FakeCommonClustering:
        def __init__(self, **kwargs: object) -> None:
            calls.update(kwargs)

    diarizer = SimpleNamespace(cluster=object())

    _apply_cluster_type(
        diarizer,
        FakeCommonClustering,
        cluster_type="umap_hdbscan",
        fix_cos_thr=0.4,
    )

    assert calls == {
        "cluster_type": "umap_hdbscan",
        "cluster_line": 40,
        "mer_cos": 0.8,
        "min_cluster_size": 4,
        "n_neighbors": 20,
        "n_components": 60,
        "min_samples": 20,
        "metric": "euclidean",
    }
    assert isinstance(diarizer.cluster, FakeCommonClustering)


def test_umap_seed_context_forces_and_restores_random_state() -> None:
    calls: list[dict[str, object]] = []

    def fake_umap(**kwargs: object) -> object:
        calls.append(kwargs)
        return object()

    umap_module = SimpleNamespace(UMAP=fake_umap)

    with _umap_seed_context(umap_module, enabled=True, seed=0):
        umap_module.UMAP(n_neighbors=20)

    assert calls == [{"n_neighbors": 20, "random_state": 0}]
    assert umap_module.UMAP is fake_umap


def test_runner_metadata_accepts_only_the_declared_umap_hdbscan_policy() -> None:
    metadata: dict[str, object] = {
        "schema_version": 1,
        "source_commit": "a" * 40,
        "python_version": "3.11.13",
        "torch_version": "2.11.0",
        "modelscope_version": "1.40.2",
        "embedding_device": "mps",
        "vad_device": "cpu",
        "clustering_device": "cpu",
        "model_stage_runtime_seconds": 0.1,
        "model_load_runtime_seconds": 0.2,
        "model_assets": {
            "iic/speech_campplus_sv_zh_en_16k-common_advanced@v1.0.0": {
                "file_count": 1,
                "snapshot_sha256": "b" * 64,
            },
            "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch@v2.0.4": {
                "file_count": 1,
                "snapshot_sha256": "c" * 64,
            },
        },
        "cluster_policy": {
            "cluster_type": "umap_hdbscan",
            "cluster_line": 40,
            "min_cluster_size": 4,
            "mer_cos": 0.8,
            "speaker_count_mode": "automatic",
            "n_neighbors": 20,
            "n_components": 60,
            "min_samples": 20,
            "metric": "euclidean",
            "random_state": 0,
        },
    }

    assert _validate_runner_metadata(metadata, source_commit="a" * 40) == metadata

    cluster_policy = metadata["cluster_policy"]
    assert isinstance(cluster_policy, dict)
    invalid_metadata = {
        **metadata,
        "cluster_policy": {**cluster_policy, "random_state": 1},
    }
    with pytest.raises(ValueError, match="cluster policy is invalid"):
        _validate_runner_metadata(invalid_metadata, source_commit="a" * 40)
