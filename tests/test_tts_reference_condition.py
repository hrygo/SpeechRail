from __future__ import annotations

import pytest

from speechrail.domain.tts_reference_condition import (
    MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT,
    PreparedReferenceIdentityError,
    PreparedReferenceKey,
    PreparedReferenceUnsupportedError,
    UnsupportedPreparedReferenceProvider,
    prepared_reference_content_identity,
    verify_prepared_reference_material,
)

MODEL_REVISION = "1" * 40
TOKENIZER_REVISION = "2" * 40


def _key(**overrides: object) -> PreparedReferenceKey:
    values: dict[str, object] = {
        "content_identity": prepared_reference_content_identity(
            reference_audio=b"private-pcm", reference_text="private reference text"
        ),
        "preprocessing_version": "audio_prep_v1",
        "model_revision": MODEL_REVISION,
        "engine_revision": "mlx_audio_0.5.6_engine_rev_7",
        "quantization": "q8",
        "tokenizer_revision": TOKENIZER_REVISION,
        "codec_revision": "speech_tokenizer_rev_3",
        "implementation_version": "mlx_audio_0.5.6_stream_v1",
    }
    values.update(overrides)
    return PreparedReferenceKey(**values)  # type: ignore[arg-type]


def test_pinned_mlx_audio_prepared_reference_support_is_explicitly_unsupported() -> None:
    support = MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT

    assert support.vendor_package == "mlx-audio"
    assert support.vendor_version == "0.4.8"
    assert support.public_contract == "generate(ref_audio, ref_text)"
    assert support.private_cache_observed is True
    assert support.supported is False
    assert support.reason == "public_api_has_no_reusable_prepared_reference_condition"


def test_unsupported_provider_fails_closed_without_retaining_reference_material() -> None:
    provider = UnsupportedPreparedReferenceProvider()

    with pytest.raises(PreparedReferenceUnsupportedError) as caught:
        provider.prepare(
            key=_key(),
            reference_audio=b"private-pcm",
            reference_text="private reference text",
            voice_revision="vr_" + "1" * 32,
        )

    assert str(caught.value) == provider.support.reason
    assert not vars(provider)


def test_reference_content_identity_depends_on_audio_and_text() -> None:
    base = prepared_reference_content_identity(reference_audio=b"pcm", reference_text="你好")

    assert base == prepared_reference_content_identity(
        reference_audio=b"pcm", reference_text="你好"
    )
    assert base != prepared_reference_content_identity(
        reference_audio=b"pcm2", reference_text="你好"
    )
    assert base != prepared_reference_content_identity(
        reference_audio=b"pcm", reference_text="你好。"
    )
    with pytest.raises(ValueError):
        prepared_reference_content_identity(
            reference_audio="not-bytes", reference_text="你好"  # type: ignore[arg-type]
        )


def test_prepared_key_rejects_incomplete_or_unpinned_identity() -> None:
    for overrides in (
        {"content_identity": "not-a-digest"},
        {"model_revision": "short"},
        {"tokenizer_revision": ""},
        {"engine_revision": ""},
        {"codec_revision": "has space"},
        {"quantization": ""},
        {"preprocessing_version": "has space"},
        {"implementation_version": ""},
        {"conditioning_mode": ""},
    ):
        with pytest.raises(ValueError):
            _key(**overrides)


def test_prepared_key_digest_isolates_precision_and_revisions() -> None:
    q8 = _key()
    bf16 = _key(quantization="bf16")
    other_impl = _key(implementation_version="mlx_audio_0.6.0_stream_v1")
    other_tokenizer = _key(tokenizer_revision="3" * 40)
    other_codec = _key(codec_revision="speech_tokenizer_rev_4")
    other_model = _key(model_revision="4" * 40)
    other_engine = _key(engine_revision="mlx_audio_0.5.7_engine_rev_8")
    other_preprocessing = _key(preprocessing_version="audio_prep_v2")
    other_mode = _key(conditioning_mode="icl_streaming")

    digests = {
        q8.digest,
        bf16.digest,
        other_impl.digest,
        other_tokenizer.digest,
        other_codec.digest,
        other_model.digest,
        other_engine.digest,
        other_preprocessing.digest,
        other_mode.digest,
    }

    # Cross-precision reuse is impossible: every dimension changes the namespace.
    assert len(digests) == 9
    assert q8.digest == _key().digest
    assert len(q8.digest) == 64


def test_same_voice_id_cannot_share_a_cache_across_precision_or_engine() -> None:
    """One voice revision on q8 and bf16 (or two engines) is two cache entries."""

    voice_revision = "vr_" + "a" * 32
    q8_engine_a = _key()
    bf16_engine_a = _key(quantization="bf16")
    q8_engine_b = _key(engine_revision="mlx_audio_0.5.7_engine_rev_8")

    # The voice revision is identical; only the runtime identity differs.
    conditions = [
        (voice_revision, q8_engine_a),
        (voice_revision, bf16_engine_a),
        (voice_revision, q8_engine_b),
    ]
    keys = {key.digest for _revision, key in conditions}

    assert len(keys) == 3
    assert q8_engine_a.schema_version == "prepared_reference_condition_v2"


def test_material_verification_fails_closed_on_a_mismatched_key() -> None:
    key = _key()
    verify_prepared_reference_material(
        key, reference_audio=b"private-pcm", reference_text="private reference text"
    )

    with pytest.raises(PreparedReferenceIdentityError):
        verify_prepared_reference_material(
            key, reference_audio=b"other-pcm", reference_text="private reference text"
        )
    with pytest.raises(PreparedReferenceIdentityError):
        verify_prepared_reference_material(
            key, reference_audio=b"private-pcm", reference_text="other reference text"
        )
