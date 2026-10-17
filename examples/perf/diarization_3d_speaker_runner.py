"""Python 3.11 bridge to the pinned upstream 3D-Speaker inference class."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import re
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from unittest.mock import patch

_CAMPLUS_MODEL_ID = "iic/speech_campplus_sv_zh_en_16k-common_advanced"
_CAMPLUS_MODEL_REVISION = "v1.0.0"
_CAMPLUS_CHECKPOINT = "campplus_cn_en_common.pt"
_FSMN_VAD_MODEL_ID = "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
_FSMN_VAD_MODEL_REVISION = "v2.0.4"
_RECORD_ID = re.compile(r"meeting-[0-9]{4}\Z")
_UMAP_RANDOM_STATE = 0


@contextlib.contextmanager
def _umap_seed_context(
    umap_module: Any, *, enabled: bool, seed: int = _UMAP_RANDOM_STATE
) -> Iterator[None]:
    if not enabled:
        yield
        return
    if type(seed) is not int or seed < 0:
        raise ValueError("UMAP random state must be a non-negative integer")

    original_constructor = umap_module.UMAP

    def seeded_constructor(*args: Any, **kwargs: Any) -> Any:
        kwargs["random_state"] = seed
        return original_constructor(*args, **kwargs)

    with patch.object(umap_module, "UMAP", new=seeded_constructor):
        yield


def _snapshot_digest(root: Path) -> tuple[int, str]:
    rows: list[bytes] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        file_hash = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                file_hash.update(chunk)
        digest = file_hash.hexdigest().encode("ascii")
        rows.append(relative + b"\0" + digest + b"\n")
    if not rows:
        raise ValueError("ModelScope snapshot is empty")
    return len(rows), hashlib.sha256(b"".join(rows)).hexdigest()


def _model_device(torch_module: Any) -> str:
    mps = getattr(getattr(torch_module, "backends", None), "mps", None)
    return "mps" if mps is not None and mps.is_available() else "cpu"


def _apply_cluster_type(
    diarizer: Any,
    common_clustering_type: Any,
    *,
    cluster_type: str,
    fix_cos_thr: float,
) -> None:
    if cluster_type == "spectral":
        return
    if cluster_type == "AHC":
        if fix_cos_thr != 0.4:
            raise ValueError("candidate cluster type is outside the declared experiment grid")
        diarizer.cluster = common_clustering_type(
            cluster_type="AHC",
            cluster_line=40,
            mer_cos=0.8,
            min_cluster_size=4,
            fix_cos_thr=fix_cos_thr,
        )
        return
    if cluster_type == "umap_hdbscan":
        diarizer.cluster = common_clustering_type(
            cluster_type="umap_hdbscan",
            cluster_line=40,
            mer_cos=0.8,
            min_cluster_size=4,
            n_neighbors=20,
            n_components=60,
            min_samples=20,
            metric="euclidean",
        )
        return
    raise ValueError("candidate cluster type is outside the declared experiment grid")


def _cluster_policy(diarizer: Any) -> dict[str, Any]:
    cluster = diarizer.cluster
    policy: dict[str, Any] = {
        "cluster_type": cluster.cluster_type,
        "cluster_line": cluster.cluster_line,
        "min_cluster_size": cluster.min_cluster_size,
        "mer_cos": cluster.mer_cos,
        "speaker_count_mode": "automatic",
    }
    if cluster.cluster_type == "spectral":
        policy.update(
            {
                "pval": cluster.cluster.pval,
                "min_num_spks": cluster.cluster.min_num_spks,
                "max_num_spks": cluster.cluster.max_num_spks,
                "oracle_num": cluster.cluster.k,
            }
        )
    elif cluster.cluster_type == "AHC":
        policy["fix_cos_thr"] = cluster.cluster.fix_cos_thr
    elif cluster.cluster_type == "umap_hdbscan":
        policy.update(
            {
                "n_neighbors": cluster.cluster.n_neighbors,
                "n_components": cluster.cluster.n_components,
                "min_samples": cluster.cluster.min_samples,
                "metric": cluster.cluster.metric,
                "random_state": _UMAP_RANDOM_STATE,
            }
        )
    return policy


def _construct_diarizer(
    inference_module: Any,
    torch_module: Any,
    *,
    embedding_device: str,
    model_cache_dir: Path,
    disable_cosine_merge: bool = False,
    min_cluster_size: int = 4,
    spectral_pval: float = 0.012,
    min_num_spks: int = 1,
) -> Any:
    if type(min_cluster_size) is not int or min_cluster_size < 0:
        raise ValueError("candidate minor-cluster size must be a non-negative integer")
    if type(spectral_pval) not in (int, float) or spectral_pval not in (0.003, 0.012):
        raise ValueError("candidate spectral pval is outside the declared experiment grid")
    if type(min_num_spks) is not int or min_num_spks not in (1, 4):
        raise ValueError("candidate spectral speaker floor is outside the declared grid")
    original_vad_loader = inference_module.get_voice_activity_detection_model

    def load_vad_on_cpu(device: Any = None, cache_dir: str | None = None) -> Any:
        return original_vad_loader(torch_module.device("cpu"), cache_dir)

    with patch.object(
        inference_module,
        "get_voice_activity_detection_model",
        new=load_vad_on_cpu,
    ):
        diarizer = inference_module.Diarization3Dspeaker(
            device=torch_module.device(embedding_device),
            include_overlap=False,
            hf_access_token=None,
            speaker_num=None,
            model_cache_dir=str(model_cache_dir),
        )
    if disable_cosine_merge:
        if not hasattr(diarizer, "cluster") or not hasattr(diarizer.cluster, "mer_cos"):
            raise ValueError("candidate clustering backend does not expose cosine merge")
        diarizer.cluster.mer_cos = None
    if min_cluster_size != 4:
        if not hasattr(diarizer, "cluster") or not hasattr(
            diarizer.cluster, "min_cluster_size"
        ):
            raise ValueError("candidate clustering backend does not expose minor-cluster size")
        diarizer.cluster.min_cluster_size = min_cluster_size
    if spectral_pval != 0.012:
        if not hasattr(diarizer, "cluster") or not hasattr(diarizer.cluster, "cluster"):
            raise ValueError("candidate clustering backend does not expose spectral policy")
        if not hasattr(diarizer.cluster.cluster, "pval"):
            raise ValueError("candidate spectral backend does not expose pval")
        diarizer.cluster.cluster.pval = spectral_pval
    if min_num_spks != 1:
        if not hasattr(diarizer, "cluster") or not hasattr(diarizer.cluster, "cluster"):
            raise ValueError("candidate clustering backend does not expose spectral policy")
        if not hasattr(diarizer.cluster.cluster, "min_num_spks"):
            raise ValueError("candidate spectral backend does not expose speaker floor")
        diarizer.cluster.cluster.min_num_spks = min_num_spks
    return diarizer


def _load_inputs(path: Path) -> list[dict[str, str]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, list) or len(value) != 8:
        raise ValueError("runner requires exactly eight locked input rows")
    result: list[dict[str, str]] = []
    for index, row in enumerate(value, start=1):
        if (
            not isinstance(row, dict)
            or set(row) != {"record_id", "audio_path"}
            or row.get("record_id") != f"meeting-{index:04d}"
            or not isinstance(row.get("audio_path"), str)
            or not Path(row["audio_path"]).is_absolute()
            or not Path(row["audio_path"]).is_file()
        ):
            raise ValueError("runner input rows are invalid")
        result.append({"record_id": row["record_id"], "audio_path": row["audio_path"]})
    return result


def _run(args: argparse.Namespace) -> None:
    speakerlab_root = args.speakerlab_root.resolve()
    model_cache_dir = args.model_cache_dir.resolve()
    input_rows = _load_inputs(args.input_list)
    if not speakerlab_root.is_dir() or not model_cache_dir.is_dir():
        raise ValueError("runner source or model cache is unavailable")
    if not args.output_dir.is_dir() or any(args.output_dir.iterdir()):
        raise ValueError("runner output directory must be empty")
    if args.cluster_type in {"AHC", "umap_hdbscan"} and (
        args.disable_cosine_merge
        or args.min_cluster_size != 4
        or args.spectral_pval != 0.012
        or args.min_num_spks != 1
    ):
        raise ValueError("cluster comparison requires all non-cluster settings at baseline")

    sys.path.insert(0, str(speakerlab_root))
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    import torch
    from modelscope.hub.snapshot_download import (  # type: ignore[import-not-found]
        snapshot_download,
    )
    from speakerlab.bin import infer_diarization  # type: ignore[import-not-found]
    from speakerlab.process.cluster import (  # type: ignore[import-not-found]
        CommonClustering,
    )

    umap_module: Any = None
    if args.cluster_type == "umap_hdbscan":
        import umap as loaded_umap_module  # type: ignore[import-not-found]

        umap_module = loaded_umap_module

    model_stage_started = time.perf_counter()
    model_assets: dict[str, dict[str, int | str]] = {}
    for model_id, revision in (
        (_CAMPLUS_MODEL_ID, _CAMPLUS_MODEL_REVISION),
        (_FSMN_VAD_MODEL_ID, _FSMN_VAD_MODEL_REVISION),
    ):
        snapshot_root = Path(
            snapshot_download(
                model_id,
                revision=revision,
                cache_dir=str(model_cache_dir),
            )
        ).resolve()
        file_count, snapshot_sha256 = _snapshot_digest(snapshot_root)
        model_assets[f"{model_id}@{revision}"] = {
            "file_count": file_count,
            "snapshot_sha256": snapshot_sha256,
        }
        if model_id == _CAMPLUS_MODEL_ID and not (snapshot_root / _CAMPLUS_CHECKPOINT).is_file():
            raise ValueError("CAM++ checkpoint is missing from the pinned snapshot")
    model_stage_runtime = time.perf_counter() - model_stage_started

    embedding_device = _model_device(torch)
    started = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr), contextlib.redirect_stderr(sys.stderr):
        diarizer = _construct_diarizer(
            infer_diarization,
            torch,
            embedding_device=embedding_device,
            model_cache_dir=model_cache_dir,
            disable_cosine_merge=args.disable_cosine_merge,
            min_cluster_size=args.min_cluster_size,
            spectral_pval=args.spectral_pval,
            min_num_spks=args.min_num_spks,
        )
        _apply_cluster_type(
            diarizer,
            CommonClustering,
            cluster_type=args.cluster_type,
            fix_cos_thr=args.fix_cos_thr,
        )
    model_load_runtime = time.perf_counter() - started
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=speakerlab_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    metadata = {
        "schema_version": 1,
        "source_commit": commit,
        "python_version": platform.python_version(),
        "torch_version": str(torch.__version__),
        "modelscope_version": importlib.metadata.version("modelscope"),
        "embedding_device": embedding_device,
        "vad_device": "cpu",
        "clustering_device": "cpu",
        "cluster_policy": _cluster_policy(diarizer),
        "model_stage_runtime_seconds": model_stage_runtime,
        "model_load_runtime_seconds": model_load_runtime,
        "model_assets": model_assets,
    }
    print("MODEL_METADATA\t" + json.dumps(metadata, sort_keys=True), flush=True)

    for index, row in enumerate(input_rows, start=1):
        started = time.perf_counter()
        with contextlib.redirect_stdout(sys.stderr), contextlib.redirect_stderr(sys.stderr):
            with _umap_seed_context(
                umap_module,
                enabled=umap_module is not None,
            ):
                segments = diarizer(row["audio_path"])
            diarizer.save_diar_output(
                str(args.output_dir / f"{row['record_id']}.rttm"),
                row["record_id"],
                segments,
            )
        runtime = time.perf_counter() - started
        if not math.isfinite(runtime) or runtime <= 0:
            raise ValueError("candidate inference timing is invalid")
        print(
            "PROGRESS\t"
            + json.dumps(
                {"completed_sessions": index, "runtime_seconds": runtime},
                sort_keys=True,
            ),
            flush=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--speakerlab-root", type=Path, required=True)
    parser.add_argument("--model-cache-dir", type=Path, required=True)
    parser.add_argument("--input-list", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--disable-cosine-merge", action="store_true")
    parser.add_argument("--min-cluster-size", type=int, default=4, choices=(0, 4))
    parser.add_argument("--spectral-pval", type=float, default=0.012, choices=(0.003, 0.012))
    parser.add_argument("--min-num-spks", type=int, default=1, choices=(1, 4))
    parser.add_argument(
        "--cluster-type",
        choices=("spectral", "AHC", "umap_hdbscan"),
        default="spectral",
    )
    parser.add_argument("--fix-cos-thr", type=float, default=0.4, choices=(0.4,))
    args = parser.parse_args()
    try:
        _run(args)
    except Exception as exc:
        error = {"error": type(exc).__name__}
        missing_module = getattr(exc, "name", None)
        if (
            isinstance(exc, ModuleNotFoundError)
            and isinstance(missing_module, str)
            and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]{0,159}", missing_module)
        ):
            error["missing_module"] = missing_module
        print(
            "ERROR\t" + json.dumps(error, sort_keys=True),
            file=sys.stdout,
            flush=True,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
