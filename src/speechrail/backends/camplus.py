"""Local CAM++ speaker embedding adapter for anonymous diarization remaps."""

from __future__ import annotations

import math
import threading
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

from speechrail.domain.diarization import DiarizationError

NativeEmbedding = Callable[[bytes], Sequence[float] | None]


class CamPlusEmbeddingExtractor:
    """Extract in-memory 16 kHz PCM embeddings with the model's official frontend."""

    def __init__(
        self, *, model_path: str | Path, extract: NativeEmbedding | None = None
    ) -> None:
        self._model_path = Path(model_path)
        self._extract = extract
        self._session: Any | None = None
        self._input_name: str | None = None
        self._output_name: str | None = None
        self._lock = threading.Lock()

    def __call__(self, audio: bytes) -> tuple[float, ...] | None:
        if self._extract is not None:
            return _validated_embedding(self._extract(audio))
        if len(audio) < 8_000:
            return None
        return self._extract_local(audio)

    def _extract_local(self, audio: bytes) -> tuple[float, ...] | None:
        if not self._model_path.is_file():
            raise DiarizationError(
                "speaker embedding model is not available", code="diarization_not_available"
            )
        try:
            import kaldi_native_fbank as knf  # type: ignore[import-untyped]
            import numpy as np
            import onnxruntime as ort  # type: ignore[import-untyped]
        except ImportError as exc:
            raise DiarizationError(
                "speaker embedding runtime is not installed", code="diarization_not_available"
            ) from exc

        with self._lock:
            if self._session is None:
                options = ort.SessionOptions()
                options.inter_op_num_threads = 1
                options.intra_op_num_threads = 1
                self._session = ort.InferenceSession(
                    str(self._model_path), sess_options=options, providers=["CPUExecutionProvider"]
                )
                metadata = self._session.get_modelmeta().custom_metadata_map
                if (
                    metadata.get("sample_rate") != "16000"
                    or metadata.get("feature_normalize_type") != "global-mean"
                ):
                    raise DiarizationError(
                        "speaker embedding model metadata is unsupported",
                        code="diarization_not_available",
                    )
                self._input_name = self._session.get_inputs()[0].name
                self._output_name = self._session.get_outputs()[0].name
            assert self._input_name is not None
            assert self._output_name is not None
            samples = np.frombuffer(audio, dtype="<i2").astype(np.float32) / 32768.0
            features = _fbank(samples, knf=knf)
            if features is None:
                return None
            features -= features.mean(axis=0, keepdims=True)
            output = self._session.run(
                [self._output_name], {self._input_name: np.expand_dims(features, axis=0)}
            )[0][0]
        return _validated_embedding(output)


def _fbank(samples: Any, *, knf: Any) -> Any | None:
    options = knf.FbankOptions()
    options.frame_opts.dither = 0
    options.frame_opts.samp_freq = 16_000
    options.frame_opts.snip_edges = True
    options.mel_opts.num_bins = 80
    options.mel_opts.debug_mel = False
    fbank = knf.OnlineFbank(options)
    fbank.accept_waveform(16_000, samples)
    fbank.input_finished()
    if fbank.num_frames_ready < 1:
        return None
    import numpy as np

    return np.stack([fbank.get_frame(index) for index in range(fbank.num_frames_ready)], axis=0)


def _validated_embedding(values: Sequence[float] | None) -> tuple[float, ...] | None:
    if values is None:
        return None
    embedding = tuple(float(value) for value in values)
    if not embedding or not all(math.isfinite(value) for value in embedding):
        raise DiarizationError("speaker embedding is invalid", code="diarization_invalid_output")
    if math.sqrt(sum(value * value for value in embedding)) <= 1e-12:
        return None
    return embedding
