from __future__ import annotations

import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

from speechrail.backends.camplus import CamPlusEmbeddingExtractor
from speechrail.domain.realtime_v2 import RealtimeV2Error


def test_camplus_validates_injected_embedding_without_loading_a_model() -> None:
    extractor = CamPlusEmbeddingExtractor(
        model_path="/unused/model.onnx", extract=lambda audio: (3, 4)
    )

    assert extractor(b"pcm") == (3.0, 4.0)


def test_camplus_rejects_non_finite_embedding() -> None:
    extractor = CamPlusEmbeddingExtractor(
        model_path="/unused/model.onnx", extract=lambda audio: (float("nan"),)
    )

    with pytest.raises(RealtimeV2Error, match="speaker embedding is invalid"):
        extractor(b"pcm")


def test_camplus_runs_onnx_with_the_official_fbank_shape(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    class FakeOptions:
        def __init__(self) -> None:
            self.frame_opts = SimpleNamespace(dither=None, samp_freq=None, snip_edges=None)
            self.mel_opts = SimpleNamespace(num_bins=None, debug_mel=None)

    class FakeFbank:
        num_frames_ready = 2

        def __init__(self, options: FakeOptions) -> None:
            assert options.frame_opts.samp_freq == 16_000
            assert options.mel_opts.num_bins == 80

        def accept_waveform(self, sample_rate: int, samples: object) -> None:
            assert sample_rate == 16_000
            assert len(samples) == 4_000  # type: ignore[arg-type]

        def input_finished(self) -> None:
            return None

        def get_frame(self, index: int) -> list[float]:
            return [float(index + 1)] * 80

    class FakeSession:
        def get_modelmeta(self) -> SimpleNamespace:
            return SimpleNamespace(
                custom_metadata_map={
                    "sample_rate": "16000",
                    "feature_normalize_type": "global-mean",
                }
            )

        def get_inputs(self) -> list[SimpleNamespace]:
            return [SimpleNamespace(name="x")]

        def get_outputs(self) -> list[SimpleNamespace]:
            return [SimpleNamespace(name="embedding")]

        def run(self, names: list[str], inputs: dict[str, object]) -> list[list[list[float]]]:
            assert names == ["embedding"]
            assert inputs["x"].shape == (1, 2, 80)  # type: ignore[union-attr]
            return [[[3.0, 4.0]]]

    fake_knf = ModuleType("kaldi_native_fbank")
    fake_knf.FbankOptions = FakeOptions  # type: ignore[attr-defined]
    fake_knf.OnlineFbank = FakeFbank  # type: ignore[attr-defined]
    fake_ort = ModuleType("onnxruntime")
    fake_ort.SessionOptions = SimpleNamespace  # type: ignore[attr-defined]
    fake_ort.InferenceSession = lambda *args, **kwargs: FakeSession()  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "kaldi_native_fbank", fake_knf)
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)
    model = tmp_path / "campplus.onnx"
    model.touch()

    extractor = CamPlusEmbeddingExtractor(model_path=model)

    assert extractor(b"\x00\x00" * 4_000) == (3.0, 4.0)


def test_camplus_fails_closed_when_local_model_is_missing() -> None:
    extractor = CamPlusEmbeddingExtractor(model_path="/missing/campplus.onnx")

    with pytest.raises(RealtimeV2Error, match="model is not available"):
        extractor(b"\x00\x00" * 4_000)
