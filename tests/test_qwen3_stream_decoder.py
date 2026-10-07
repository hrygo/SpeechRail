from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any, ClassVar

import pytest

from speechrail.backends.qwen3_stream_decoder import (
    BoundQwen3Decoder,
    DecoderRuntime,
    StreamingDecodeState,
)


class FakeArray:
    def __init__(self, data: Any, shape: tuple[int, ...], dtype: str = "fake") -> None:
        self.data = data
        self.shape = shape
        self.dtype = dtype

    def __getitem__(self, _key: object) -> FakeArray:
        if len(self.shape) == 1:
            return FakeArray(self.data, (1, self.shape[0]), self.dtype)
        return self

    def astype(self, dtype: object) -> FakeArray:
        return FakeArray(self.data, self.shape, str(dtype))


class FakeTokenizer:
    _text_by_token: ClassVar[dict[int, str]] = {
        1: "language ",
        2: "English",
        3: "<asr_text>",
        4: "�",
        5: "first",
        6: " second",
        7: " third",
        8: " fourth",
        9: " fifth",
        10: " sixth",
        11: " next",
        12: " words",
        13: "language �",
        14: "language ",
        15: "English",
    }

    def __init__(self) -> None:
        self.prompt_calls: list[dict[str, object]] = []

    def build_prompt_tokens(
        self,
        *,
        n_audio_tokens: int,
        language: str | None = None,
        context: str = "",
    ) -> list[int]:
        self.prompt_calls.append(
            {
                "n_audio_tokens": n_audio_tokens,
                "language": language,
                "context": context,
            }
        )
        return [100, 101, *([102] * n_audio_tokens), 103]

    def decode(self, token_ids: list[int]) -> str:
        return "".join(self._text_by_token.get(token, "") for token in token_ids)

    def encode(self, text: str) -> list[int]:
        if text == "language English<asr_text>":
            return [1, 2, 3]
        return []


class FakeModel:
    def __init__(self) -> None:
        self.cache_ids: list[object] = []
        self.audio_inputs: list[FakeArray] = []

    def audio_tower(
        self,
        features: FakeArray,
        feature_lens: FakeArray,
    ) -> tuple[FakeArray, None]:
        self.audio_inputs.append(features)
        sample_count = len(features.data)
        token_count = max(1, sample_count // 2)
        return FakeArray(None, (1, token_count, 4)), None

    def create_cache(self, *, max_seq_len: int) -> object:
        cache = SimpleNamespace(max_seq_len=max_seq_len)
        self.cache_ids.append(cache)
        return cache


@dataclass(frozen=True)
class FakeGeneration:
    tokens: list[int]
    finish_reason: str = "eos"
    truncated: bool = False


@dataclass(frozen=True)
class FakeConfig:
    max_new_tokens: int
    temperature: float
    num_draft_tokens: int


class FakeRuntime:
    def __init__(self, generations: list[FakeGeneration]) -> None:
        self.generations = deque(generations)
        self.features: list[list[float]] = []
        self.input_ids: list[list[int]] = []
        self.configs: list[FakeConfig] = []

    def compute_features(self, audio: list[float]) -> tuple[FakeArray, FakeArray]:
        self.features.append(list(audio))
        return FakeArray(list(audio), (1, 128, len(audio))), FakeArray([len(audio)], (1,))

    def array(self, values: list[list[int]]) -> FakeArray:
        return FakeArray(values, (len(values), len(values[0])))

    def arange(self, count: int) -> FakeArray:
        return FakeArray(list(range(count)), (count,), "int32")

    def stack(self, values: list[FakeArray], *, axis: int) -> FakeArray:
        assert axis == 1
        return FakeArray(values, (1, len(values), values[0].shape[1]), "int32")

    def generation_config(self, **values: int | float) -> FakeConfig:
        return FakeConfig(**values)  # type: ignore[arg-type]

    def generate(
        self,
        *,
        model: FakeModel,
        input_ids: FakeArray,
        audio_features: FakeArray,
        position_ids: FakeArray,
        config: FakeConfig,
    ) -> FakeGeneration:
        del audio_features, position_ids
        self.input_ids.append(list(input_ids.data[0]))
        self.configs.append(config)
        model.create_cache(max_seq_len=input_ids.shape[1] + config.max_new_tokens)
        return self.generations.popleft()

    @staticmethod
    def coerce_generation_result(
        result: FakeGeneration,
        _config: FakeConfig,
    ) -> FakeGeneration:
        return result

    @staticmethod
    def canonicalize_language(language: str | None) -> str | None:
        if language in {None, "", "auto"}:
            return None
        return {"en": "English", "zh": "Chinese"}.get(language, language)

    @staticmethod
    def parse_asr_output(
        text: str,
        *,
        user_language: str | None,
    ) -> tuple[str, str]:
        if user_language is not None:
            if "<asr_text>" in text:
                return user_language, text.split("<asr_text>", 1)[1]
            return user_language, text
        if "<asr_text>" in text:
            header, transcript = text.split("<asr_text>", 1)
            return header.removeprefix("language "), transcript
        return "unknown", text

    def bindings(self) -> DecoderRuntime:
        return DecoderRuntime(
            compute_features=self.compute_features,
            array=self.array,
            arange=self.arange,
            stack=self.stack,
            generation_config=self.generation_config,
            generate=self.generate,
            coerce_generation_result=self.coerce_generation_result,
            canonicalize_language=self.canonicalize_language,
            parse_asr_output=self.parse_asr_output,
        )


def _make_decoder(
    generations: list[FakeGeneration],
) -> tuple[BoundQwen3Decoder, FakeRuntime, FakeModel, FakeTokenizer]:
    runtime = FakeRuntime(generations)
    model = FakeModel()
    tokenizer = FakeTokenizer()
    session = SimpleNamespace(model=model, tokenizer=tokenizer, dtype="float16")
    return (
        BoundQwen3Decoder(
            session,
            max_new_tokens=64,
            # Tiny fake waveforms use a four-sample unfixed window.
            initial_unfixed_samples=4,
            runtime=runtime.bindings(),
        ),
        runtime,
        model,
        tokenizer,
    )


def test_initial_audio_window_avoids_prefix_then_rolls_back_and_rebuilds_audio() -> None:
    decoder, runtime, model, tokenizer = _make_decoder(
        [
            FakeGeneration([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            FakeGeneration([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            FakeGeneration([11, 12]),
        ]
    )
    state = StreamingDecodeState()

    first = decoder.decode(
        [0.1, 0.2],
        state,
        language="auto",
        context="",
        sample_watermark=2,
        max_new_tokens=32,
    )
    second = decoder.decode(
        [0.1, 0.2, 0.3, 0.4],
        state,
        language="auto",
        context="",
        sample_watermark=4,
        max_new_tokens=32,
    )
    third = decoder.decode(
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
        state,
        language="auto",
        context="",
        sample_watermark=6,
        max_new_tokens=32,
    )

    assert first.language == "English"
    assert second.revision == 2
    assert third.revision == 3
    assert runtime.features == [
        [0.1, 0.2],
        [0.1, 0.2, 0.3, 0.4],
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
    ]
    assert runtime.input_ids[0] == [100, 101, 102, 103]
    assert runtime.input_ids[1] == [100, 101, 102, 102, 103]
    # Keep the full auto-detected language header, roll back the trailing
    # Unicode-incomplete token, and preserve the remaining transcript prefix.
    assert runtime.input_ids[2] == [100, 101, 102, 102, 102, 103, 1, 2, 3]
    assert runtime.configs[2].max_new_tokens == 29
    assert len(model.cache_ids) == 3
    assert len({id(cache) for cache in model.cache_ids}) == 3
    assert len(tokenizer.prompt_calls) == 3


def test_forced_language_is_in_prompt_and_not_repeated_in_generated_prefix() -> None:
    decoder, runtime, _model, tokenizer = _make_decoder(
        [
            FakeGeneration([1, 2, 3, 5, 6, 7, 8, 9]),
            FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12, 5, 6]),
            FakeGeneration([12]),
        ]
    )
    state = StreamingDecodeState()

    for watermark in (2, 4, 6):
        decoder.decode(
            [0.1] * watermark,
            state,
            language="en",
            context="name",
            sample_watermark=watermark,
            max_new_tokens=32,
        )

    assert all(call["language"] == "English" for call in tokenizer.prompt_calls)
    assert tokenizer.prompt_calls[0]["context"] == "name"
    assert runtime.input_ids[2][:4] == [100, 101, 102, 102]
    assert runtime.input_ids[2][-5:] == [5, 6, 7, 8, 9]


def test_final_stream_decode_rejects_token_budget_exhaustion() -> None:
    decoder, _runtime, _model, _tokenizer = _make_decoder(
        [FakeGeneration([5, 6], finish_reason="length", truncated=True)]
    )

    with pytest.raises(RuntimeError, match="truncated"):
        decoder.decode(
            [0.1, 0.2],
            StreamingDecodeState(),
            language="auto",
            context="",
            sample_watermark=2,
            max_new_tokens=2,
            final=True,
        )


def test_malformed_language_header_discards_unusable_prefix_without_hanging() -> None:
    decoder, runtime, _model, _tokenizer = _make_decoder(
        [
            FakeGeneration([13, 3, 5, 6, 7, 8, 9]),
            FakeGeneration([13, 3, 5, 6, 7, 8, 9]),
            FakeGeneration([5]),
        ]
    )
    state = StreamingDecodeState()

    for watermark in (2, 4, 6):
        decoder.decode(
            [0.1] * watermark,
            state,
            language="auto",
            context="",
            sample_watermark=watermark,
            max_new_tokens=32,
        )

    # The bad partial header cannot be preserved safely, so the decoder starts
    # this update from a clean assistant prompt.
    assert runtime.input_ids[2] == [100, 101, 102, 102, 102, 103]


def test_incomplete_auto_language_header_is_not_forced_as_a_prefix() -> None:
    decoder, runtime, _model, _tokenizer = _make_decoder(
        [
            FakeGeneration([14, 15, 5, 6, 7, 8, 9]),
            FakeGeneration([14, 15, 5, 6, 7, 8, 9]),
            FakeGeneration([5]),
        ]
    )
    state = StreamingDecodeState()

    for watermark in (2, 4, 6):
        decoder.decode(
            [0.1] * watermark,
            state,
            language="auto",
            context="",
            sample_watermark=watermark,
            max_new_tokens=32,
        )

    assert runtime.input_ids[2] == [100, 101, 102, 102, 102, 103]


def test_repeated_truncated_previews_keep_total_raw_tokens_within_budget() -> None:
    decoder, runtime, _model, _tokenizer = _make_decoder(
        [
            FakeGeneration([5] * 16),
            FakeGeneration([5] * 16),
            FakeGeneration([5] * 5),
            FakeGeneration([5] * 5),
        ]
    )
    state = StreamingDecodeState()

    for watermark in (2, 4, 6, 8):
        decoder.decode(
            [0.1] * watermark,
            state,
            language="zh",
            context="",
            sample_watermark=watermark,
            max_new_tokens=16,
        )
        assert len(state.raw_tokens) <= 16

    assert [config.max_new_tokens for config in runtime.configs] == [16, 16, 5, 5]

def test_decode_rollback_tokens_override_controls_prefix_length() -> None:
    def _third_input_ids(rollback: int | None) -> list[int]:
        decoder, runtime, _model, _tokenizer = _make_decoder(
            [
                FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]),
                FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]),
                FakeGeneration([5]),
            ]
        )
        state = StreamingDecodeState()
        for watermark in (2, 4):
            decoder.decode(
                [0.1] * watermark,
                state,
                language="zh",
                context="",
                sample_watermark=watermark,
                max_new_tokens=32,
            )
        kwargs: dict[str, object] = (
            {} if rollback is None else {"rollback_tokens": rollback}
        )
        decoder.decode(
            [0.1] * 6,
            state,
            language="zh",
            context="",
            sample_watermark=6,
            max_new_tokens=32,
            **kwargs,  # type: ignore[arg-type]
        )
        return runtime.input_ids[2]

    prompt = [100, 101, 102, 102, 102, 103]
    # Default construction keeps rollback_tokens=5: only the first three
    # transcript tokens survive as revisable prefix.
    assert _third_input_ids(None) == [*prompt, 5, 6, 7]
    # An explicit zero rollback keeps the whole previous hypothesis.
    assert _third_input_ids(0) == [*prompt, 5, 6, 7, 8, 9, 10, 11, 12]
    # A smaller rollback keeps proportionally more prefix.
    assert _third_input_ids(2) == [*prompt, 5, 6, 7, 8, 9, 10]


def test_decode_rejects_invalid_rollback_tokens_override() -> None:
    decoder, _runtime, _model, _tokenizer = _make_decoder(
        [FakeGeneration([5, 6])]
    )
    with pytest.raises(ValueError, match="rollback_tokens"):
        decoder.decode(
            [0.1, 0.2],
            StreamingDecodeState(),
            language="auto",
            context="",
            sample_watermark=2,
            rollback_tokens=-1,
        )


@pytest.mark.parametrize("preview_ms", [250, 500, 2_000])
def test_preview_cadence_does_not_shorten_initial_prefix_free_audio(preview_ms: int) -> None:
    # The model's reference 2 x 2-second prefix-free window is audio time.
    # More frequent preview requests must not force early mistaken tokens.
    watermarks = [ms * 16 for ms in range(preview_ms, 4_001, preview_ms)]
    watermarks.append(4_000 * 16 + preview_ms * 16)
    runtime = FakeRuntime(
        [FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]) for _ in watermarks]
    )
    session = SimpleNamespace(
        model=FakeModel(), tokenizer=FakeTokenizer(), dtype="float16",
    )
    decoder = BoundQwen3Decoder(session, max_new_tokens=64, runtime=runtime.bindings())
    state = StreamingDecodeState()

    for watermark in watermarks:
        decoder.decode(
            [0.1] * watermark, state, language="zh", context="",
            sample_watermark=watermark,
        )

    assert all(prompt[-1] == 103 for prompt in runtime.input_ids[:-1])
    assert all(config.max_new_tokens == 64 for config in runtime.configs[:-1])
    assert runtime.input_ids[-1][-3:] == [5, 6, 7]
    assert runtime.configs[-1].max_new_tokens == 61


def test_latest_wins_skips_do_not_delay_prefix_warmup_past_audio_window() -> None:
    runtime = FakeRuntime([
        FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]),
        FakeGeneration([5]),
    ])
    session = SimpleNamespace(
        model=FakeModel(), tokenizer=FakeTokenizer(), dtype="float16",
    )
    decoder = BoundQwen3Decoder(session, max_new_tokens=64, runtime=runtime.bindings())
    state = StreamingDecodeState()

    for watermark in (64_000, 72_000):
        decoder.decode(
            [0.1] * watermark, state, language="zh", context="",
            sample_watermark=watermark,
        )

    assert runtime.input_ids[0][-1] == 103
    assert runtime.input_ids[1][-3:] == [5, 6, 7]
    assert runtime.configs[1].max_new_tokens == 61


@pytest.mark.parametrize("value", [-1, True, 1.5])
def test_decoder_rejects_invalid_initial_unfixed_samples(value: object) -> None:
    session = SimpleNamespace(
        model=FakeModel(), tokenizer=FakeTokenizer(), dtype="float16",
    )
    with pytest.raises(ValueError, match="initial_unfixed_samples"):
        BoundQwen3Decoder(
            session, max_new_tokens=64,
            initial_unfixed_samples=value,  # type: ignore[arg-type]
        )


def test_late_audio_cannot_freeze_a_prefix_decoded_before_the_unfixed_window() -> None:
    decoder, runtime, _model, _tokenizer = _make_decoder([
        FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]),
        FakeGeneration([5, 6, 7, 8, 9, 10, 11, 12]),
        FakeGeneration([5]),
    ])
    state = StreamingDecodeState()
    for watermark in (2, 6, 8):
        decoder.decode(
            [0.1] * watermark, state, language="zh", context="",
            sample_watermark=watermark,
        )
    assert all(prompt[-1] == 103 for prompt in runtime.input_ids[:2])
    assert runtime.input_ids[2][-3:] == [5, 6, 7]
