"""Model integration for the append-only Qwen3-TTS driver.

The backend keeps everything that must survive across appends inside one
generation: the talker KV cache, the code predictor cache, the sampler state
and the vocoder streaming state.  Only the conditioning is frozen up front,
which is what makes the identity stable for the whole utterance.

Two layouts are supported, and they consume target text differently:

``custom_voice``
    Upstream ``_prepare_generation_inputs`` already splits the text: the first
    target token is overlaid on the codec prefix inside the prefill and every
    later token waits in ``trailing_text_hidden``.  The extension reuses that
    split as-is and only takes the trailing EOS out of the queue.

``base``
    Upstream ``_prepare_icl_generation_inputs`` only implements the official
    non-streaming overlay, where *all* target text sits inside the prefill and
    ``trailing_text_hidden`` is a single pad.  A prefill like that cannot be
    continued, so the extension builds the official streaming layout instead
    (``non_streaming_mode=False``): the text stream ``[ref_text][target_text]``
    is added position by position to ``[codec_bos][ref_codec]``, the text that
    lines up with the reference codec frames goes into the prefill, and every
    later target token stays available as trailing text for appends.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Final, Literal

import mlx.core as mx

from .incremental import FrameOutcome

BaseLayout = Literal["aligned"]

_CHUNK_FRAMES: Final[int] = 1
_MAX_FRAMES: Final[int] = 4_096


class Qwen3TtsIncrementalBackend:
    """Drive one ``Qwen3TTS`` instance as an append-only generation."""

    def __init__(
        self,
        model: Any,
        *,
        variant: str,
        speaker: str | None = None,
        instruct: str | None = None,
        language: str = "auto",
        ref_audio: Any | None = None,
        ref_text: str | None = None,
        base_layout: BaseLayout = "aligned",
        temperature: float = 0.9,
        top_k: int = 50,
        top_p: float = 1.0,
        repetition_penalty: float = 1.05,
    ) -> None:
        if variant not in {"custom_voice", "base"}:
            raise ValueError(f"unsupported incremental variant: {variant}")
        if variant == "custom_voice" and not speaker:
            raise ValueError("custom_voice requires a speaker")
        if variant == "base" and ref_audio is None:
            raise ValueError("base requires a reference audio")
        if variant == "base" and base_layout != "aligned":
            raise ValueError("base only supports the aligned layout")
        self._model = model
        self._variant = variant
        self._speaker = speaker
        self._instruct = instruct
        self._language = language
        self._ref_audio = ref_audio
        self._ref_text = ref_text
        self._base_layout = base_layout
        self._temperature = temperature
        self._top_k = top_k
        self._top_p = top_p
        self._repetition_penalty = repetition_penalty

        self._cache: Any | None = None
        self._code_cache: Any | None = None
        self._input_embeds: Any | None = None
        self._pending_codec_embed: Any | None = None
        self._pad_embed: Any | None = None
        self._eos_embed: Any | None = None
        self._generated_tokens: list[int] = []
        self._generated_codes: list[Any] = []
        self._frames = 0
        self._started = False
        self._closed = False
        self._prefill_target = 0
        self._sample_rate = int(getattr(model, "sample_rate", 24_000))
        self._identity = _generation_identity(
            model,
            variant=variant,
            speaker=speaker,
            instruct=instruct,
            language=language,
            ref_text=ref_text,
            ref_audio=ref_audio,
            base_layout=base_layout,
            temperature=temperature,
            top_k=top_k,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
        )

    # ---------------------------------------------------------------- metadata

    @property
    def generation_identity(self) -> str:
        return self._identity

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    @property
    def prefill_target_tokens(self) -> int:
        return self._prefill_target

    @property
    def peak_memory_bytes(self) -> int | None:
        try:
            value = int(mx.get_peak_memory())
        except Exception:
            return None
        return value if value >= 0 else None

    # ------------------------------------------------------------- tokenizing

    def encode_target_text(self, text: str) -> list[int]:
        """Return the pure target text ids the prefill and trailing both use."""

        tokenizer = getattr(self._model, "tokenizer", None)
        if tokenizer is None:
            raise ValueError("tokenizer_not_loaded")
        chat = f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
        ids = list(tokenizer.encode(chat))
        if len(ids) <= 8:
            return []
        return [int(item) for item in ids[3:-5]]

    # ------------------------------------------------------------- generation

    def begin_generation(self, text: str) -> int:
        """Freeze conditioning, build the single prefill, return its text tokens."""

        if self._started:
            raise RuntimeError("generation_already_started")
        model = self._model
        config = model.config.talker_config
        self._cache = model.talker.make_cache()
        self._code_cache = model.talker.code_predictor.make_cache()
        self._generated_tokens = []
        self._generated_codes = []
        self._frames = 0
        self._sample_rate = int(getattr(model, "sample_rate", self._sample_rate))

        if self._variant == "custom_voice":
            input_embeds, trailing, pad_embed = model._prepare_generation_inputs(
                text,
                language=self._language,
                speaker=self._speaker,
                instruct=self._instruct,
            )
            # Upstream appends the trailing EOS directly after the text.  The
            # incremental path holds it back so an empty text queue can mean
            # "wait", and feeds it only once the caller seals the input.
            eos_embed = trailing[:, -1:, :]
            self._eos_embed = eos_embed
            self._pad_embed = pad_embed
            self._input_embeds = input_embeds
            self._prefill_target = 1
        else:
            (
                input_embeds,
                pad_embed,
                eos_embed,
                prefill_target,
            ) = self._prepare_aligned_icl_inputs(text)
            self._pad_embed = pad_embed
            self._eos_embed = eos_embed
            self._input_embeds = input_embeds
            self._prefill_target = prefill_target

        self._pending_codec_embed = None
        self._started = True
        model.speech_tokenizer.decoder.reset_streaming_state()
        self._eos_token_id = int(config.codec_eos_token_id)
        vocab_size = int(config.vocab_size)
        self._suppress_tokens = [
            index
            for index in range(vocab_size - 1024, vocab_size)
            if index != self._eos_token_id
        ]
        self._num_code_groups = int(config.num_code_groups)
        return self._prefill_target

    def advance(self, *, token: int | None, seal: bool) -> FrameOutcome:
        """Run one talker frame and decode exactly one codec frame of audio."""

        if not self._started:
            raise RuntimeError("generation_not_started")
        if self._closed:
            raise RuntimeError("generation_closed")
        model = self._model

        if self._input_embeds is not None:
            input_embeds = self._input_embeds
            self._input_embeds = None
        else:
            if self._pending_codec_embed is None:
                raise RuntimeError("codec_state_missing")
            if seal:
                text_embed = self._eos_embed
            elif token is None:
                text_embed = self._pad_embed
            else:
                text_embed = self._project_token(token)
            input_embeds = text_embed + self._pending_codec_embed

        logits, hidden = model.talker(input_embeds, cache=self._cache)
        next_token = model._sample_token(
            logits,
            temperature=self._temperature,
            top_k=self._top_k,
            top_p=self._top_p,
            repetition_penalty=self._repetition_penalty,
            generated_tokens=(self._generated_tokens or None),
            suppress_tokens=self._suppress_tokens,
        )
        is_eos = next_token[0, 0] == self._eos_token_id

        code_tokens = [next_token]
        code_hidden = hidden[:, -1:, :]
        for cache in self._code_cache:
            cache.keys = None
            cache.values = None
            cache.offset = 0
        for code_idx in range(self._num_code_groups - 1):
            if code_idx == 0:
                code_0_embed = model.talker.get_input_embeddings()(next_token)
                code_input = mx.concatenate([code_hidden, code_0_embed], axis=1)
            else:
                code_embed = model.talker.code_predictor.codec_embedding[code_idx - 1](
                    code_tokens[-1]
                )
                code_input = code_embed
            code_logits, self._code_cache, _ = model.talker.code_predictor(
                code_input,
                cache=self._code_cache,
                generation_step=code_idx,
            )
            code_tokens.append(
                model._sample_token(
                    code_logits,
                    temperature=self._temperature,
                    top_k=self._top_k,
                    top_p=self._top_p,
                )
            )

        all_codes = mx.concatenate(code_tokens, axis=1)
        codec_embed = model.talker.get_input_embeddings()(next_token)
        for index, code in enumerate(code_tokens[1:]):
            codec_embed = codec_embed + model.talker.code_predictor.codec_embedding[index](code)
        self._pending_codec_embed = codec_embed

        mx.eval(codec_embed, is_eos)
        if bool(is_eos.item()):
            return FrameOutcome(terminal=True)

        self._generated_tokens.append(int(next_token[0, 0]))
        self._generated_codes.append(all_codes)
        self._frames += 1
        if self._frames > _MAX_FRAMES:
            raise RuntimeError("incremental_frame_limit_exceeded")

        pcm16 = self._decode_frames(all_codes)
        return FrameOutcome(pcm16=pcm16, terminal=False)

    # ------------------------------------------------------------------ codec

    def _decode_frames(self, codes: Any) -> bytes:
        chunk = mx.stack([codes], axis=1)  # [1, 1, num_code_groups]
        codes_for_decoder = mx.transpose(chunk, (0, 2, 1))
        mx.eval(codes_for_decoder)
        wav = self._model.speech_tokenizer.decoder.streaming_step(codes_for_decoder)
        audio = wav.squeeze(1)[0]
        mx.eval(audio)
        clipped = mx.clip(audio, -1.0, 1.0)
        pcm = (clipped * 32767.0).astype(mx.int16)
        mx.eval(pcm)
        return bytes(memoryview(pcm).tobytes())

    def _project_token(self, token: int) -> Any:
        model = self._model
        ids = mx.array([[int(token)]])
        return model.talker.text_projection(model.talker.get_text_embeddings()(ids))

    # ------------------------------------------------------------------- ICL

    def _prepare_aligned_icl_inputs(self, text: str) -> tuple[Any, Any, Any, int]:
        """Build the aligned ICL prefill plus the text that stays appendable."""

        model = self._model
        config = model.config.talker_config
        tokenizer = getattr(model, "tokenizer", None)
        if tokenizer is None:
            raise ValueError("tokenizer_not_loaded")

        ref_chat = f"<|im_start|>assistant\n{self._ref_text}<|im_end|>\n"
        ref_ids = mx.array(tokenizer.encode(ref_chat))[None, :]
        ref_text_ids = ref_ids[:, 3:-2]

        target_chat = f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
        target_ids = mx.array(tokenizer.encode(target_chat))[None, :]
        text_ids = target_ids[:, 3:-5]

        tts_tokens = mx.array(
            [
                [
                    model.config.tts_bos_token_id,
                    model.config.tts_eos_token_id,
                    model.config.tts_pad_token_id,
                ]
            ]
        )
        tts_embeds = model.talker.text_projection(model.talker.get_text_embeddings()(tts_tokens))
        tts_bos_embed = tts_embeds[:, 0:1, :]
        tts_eos_embed = tts_embeds[:, 1:2, :]
        tts_pad_embed = tts_embeds[:, 2:3, :]

        ref_text_embed = model.talker.text_projection(
            model.talker.get_text_embeddings()(ref_text_ids)
        )
        target_embed = model.talker.text_projection(
            model.talker.get_text_embeddings()(text_ids)
        )
        ref_len = int(ref_text_embed.shape[1])
        target_len = int(target_embed.shape[1])

        # The speaker encoder wants the flat waveform while the codec wants a
        # [batch, channel, samples] shape, so keep both views like upstream.
        audio_for_spk = self._ref_audio
        ref_audio = self._ref_audio
        if ref_audio.ndim == 1:
            ref_audio = ref_audio[None, None, :]
        elif ref_audio.ndim == 2:
            ref_audio = ref_audio[None, :]
        ref_codes = model.speech_tokenizer.encode(ref_audio)
        mx.eval(ref_codes)

        first_cb_codes = ref_codes[:, 0, :]
        ref_codec_embed = model.talker.get_input_embeddings()(first_cb_codes)
        for index in range(config.num_code_groups - 1):
            cb_codes = ref_codes[:, index + 1, :]
            ref_codec_embed = (
                ref_codec_embed + model.talker.code_predictor.codec_embedding[index](cb_codes)
            )
        codec_bos_embed = model.talker.get_input_embeddings()(
            mx.array([[config.codec_bos_id]])
        )
        codec_embed_icl = mx.concatenate([codec_bos_embed, ref_codec_embed], axis=1)
        codec_lens = int(codec_embed_icl.shape[1])

        # Official streaming ICL layout: the text stream is added to the codec
        # stream position by position, so the prefill window is exactly the
        # reference codec.  The reference transcript consumes the first slots
        # and the target text continues from there; every later target token
        # stays in the trailing queue instead of being pre-baked, which is what
        # lets an append continue the same generation.
        window = codec_lens
        prefill_target = max(0, min(window - ref_len, target_len))
        prefill_text = mx.concatenate(
            [ref_text_embed, target_embed[:, :prefill_target, :]], axis=1
        )
        if int(prefill_text.shape[1]) < window:
            missing = window - int(prefill_text.shape[1])
            prefill_text = mx.concatenate(
                [
                    prefill_text,
                    mx.broadcast_to(
                        tts_pad_embed, (1, missing, tts_pad_embed.shape[-1])
                    ),
                ],
                axis=1,
            )
        icl_input_embed = prefill_text + codec_embed_icl

        language_id = None
        codec_language = config.codec_language_id or {}
        if self._language.lower() != "auto" and self._language.lower() in codec_language:
            language_id = codec_language[self._language.lower()]
        if language_id is None:
            codec_prefill = [
                config.codec_nothink_id,
                config.codec_think_bos_id,
                config.codec_think_eos_id,
            ]
        else:
            codec_prefill = [
                config.codec_think_id,
                config.codec_think_bos_id,
                language_id,
                config.codec_think_eos_id,
            ]
        codec_prefix_embed = model.talker.get_input_embeddings()(mx.array([codec_prefill]))
        codec_prefix_suffix = model.talker.get_input_embeddings()(
            mx.array([[config.codec_pad_id, config.codec_bos_id]])
        )
        speaker_embed = None
        if model.speaker_encoder is not None:
            speaker_embed = model.extract_speaker_embedding(audio_for_spk)
        if speaker_embed is not None:
            speaker_embed = speaker_embed.astype(codec_prefix_embed.dtype)
            codec_prefix_embed = mx.concatenate(
                [codec_prefix_embed, speaker_embed.reshape(1, 1, -1), codec_prefix_suffix],
                axis=1,
            )
        else:
            codec_prefix_embed = mx.concatenate(
                [codec_prefix_embed, codec_prefix_suffix], axis=1
            )

        role_embed = model.talker.text_projection(
            model.talker.get_text_embeddings()(target_ids[:, :3])
        )
        pad_count = int(codec_prefix_embed.shape[1]) - 2
        pad_embeds = mx.broadcast_to(
            tts_pad_embed, (1, pad_count, tts_pad_embed.shape[-1])
        )
        combined_prefix = mx.concatenate([pad_embeds, tts_bos_embed], axis=1)
        combined_prefix = combined_prefix + codec_prefix_embed[:, :-1, :]
        input_embeds = mx.concatenate([role_embed, combined_prefix, icl_input_embed], axis=1)
        mx.eval(input_embeds)
        return input_embeds, tts_pad_embed, tts_eos_embed, prefill_target

    # -------------------------------------------------------------- lifecycle

    def cancel(self) -> None:
        self._closed = True
        self._cache = None
        self._code_cache = None
        self._input_embeds = None
        self._pending_codec_embed = None
        self._generated_codes = []
        mx.clear_cache()

    def close(self) -> None:
        self._closed = True
        self._cache = None
        self._code_cache = None
        self._input_embeds = None
        self._pending_codec_embed = None
        self._generated_codes = []


def _generation_identity(
    model: Any,
    *,
    variant: str,
    speaker: str | None,
    instruct: str | None,
    language: str,
    ref_text: str | None,
    ref_audio: Any | None,
    base_layout: str,
    temperature: float,
    top_k: int,
    top_p: float,
    repetition_penalty: float,
) -> str:
    config = getattr(model, "config", None)
    payload = {
        "family": "qwen3_tts_incremental",
        "variant": variant,
        "speaker": speaker,
        "instruct": instruct,
        "language": language,
        "ref_text": ref_text,
        "ref_audio_sha256": _array_digest(ref_audio),
        "base_layout": base_layout,
        "tts_model_type": getattr(config, "tts_model_type", None),
        "temperature": temperature,
        "top_k": top_k,
        "top_p": top_p,
        "repetition_penalty": repetition_penalty,
        "implementation": "speechrail-qwen3-tts-incremental-1",
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _array_digest(value: Any) -> str | None:
    if value is None:
        return None
    try:
        array = mx.array(value)
        mx.eval(array)
        return hashlib.sha256(bytes(memoryview(array).tobytes())).hexdigest()
    except Exception:
        return None


__all__ = ["Qwen3TtsIncrementalBackend"]
