from __future__ import annotations

import hashlib

import pytest

from speechrail.application.render_receipts import RenderReceiptRegistry
from speechrail.application.render_recipe import build_render_recipe


def _recipe(**overrides: object):
    facts: dict[str, object] = {
        "raw_text": "回执里的配方。",
        "acoustic_text": "回执里的配方。",
        "normalization_revision": "tts_norm_v1",
        "planner_revision": "tts_bounded_v1",
        "planner_max_chars": 240,
        "pronunciation_set_id": None,
        "pronunciation_revision": None,
        "voice_id": "narrator",
        "voice_revision": "vr_" + "a" * 32,
        "voice_mode": "custom",
        "model_role": "tts",
        "model_artifact": "tts-artifact",
        "model_artifact_revision": "catalog-1",
        "engine_revision": None,
        "effective_speed": 1.0,
        "effective_language": "zh",
        "seed_policy": None,
        "output_format": "pcm",
        "sample_rate": 24_000,
    }
    facts.update(overrides)
    return build_render_recipe(**facts)  # type: ignore[arg-type]


def _begin(registry: RenderReceiptRegistry, request_id: str = "req-1") -> str:
    return registry.begin(
        request_id=request_id,
        response_id="resp-1",
        voice_id="narrator",
        voice_revision="vr_" + "a" * 32,
        model_artifact="tts-artifact",
        model_source="source-model",
        model_variant="base",
        model_catalog_revision="catalog-1",
        model_runtime_revision=None,
        output_format="pcm",
        sample_rate=24_000,
    )


def test_completed_receipt_hashes_exact_pcm_boundary() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    chunks = (b"\x01\x00\x02\x00", b"\x03\x00")
    for chunk in chunks:
        registry.accept_pcm(receipt_id, chunk)
    registry.complete(receipt_id)

    receipt = registry.get(receipt_id)
    assert receipt["status"] == "completed"
    assert receipt["voice"] == {
        "id": "narrator",
        "revision": "vr_" + "a" * 32,
    }
    audio = receipt["audio"]
    assert isinstance(audio, dict)
    assert audio["integrity_boundary"] == "pcm16_pre_transport"
    assert audio["sample_count"] == 3
    assert audio["pcm_sha256"] == hashlib.sha256(b"".join(chunks)).hexdigest()
    assert receipt["model"]["runtime_revision"] is None


def test_pending_receipt_can_bind_observed_runtime_revision() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)

    registry.bind_model_runtime_revision(receipt_id, "rt_" + ("b" * 64))

    assert registry.get(receipt_id)["model"]["runtime_revision"] == "rt_" + ("b" * 64)


def test_receipt_carries_the_recipe_it_was_started_with() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = registry.begin(
        request_id="req-recipe",
        voice_id="narrator",
        voice_revision="vr_" + "a" * 32,
        model_artifact="tts-artifact",
        model_source="source-model",
        model_variant="base",
        model_catalog_revision="catalog-1",
        model_runtime_revision=None,
        plan_id="plan_" + ("e" * 32),
        output_format="pcm",
        sample_rate=24_000,
        recipe=_recipe(),
    )

    receipt = registry.get(receipt_id)
    assert receipt["plan"]["plan_id"] == "plan_" + ("e" * 32)
    recipe = receipt["recipe"]
    assert isinstance(recipe, dict)
    assert recipe["voice"]["id"] == "narrator"
    assert recipe["content"]["raw_text_sha256"] == hashlib.sha256(
        "回执里的配方。".encode()
    ).hexdigest()
    assert recipe["state"] == "partial"
    assert "model.engine_revision" in recipe["missing_fields"]
    assert recipe["digest"] is None


def test_binding_an_observed_runtime_completes_the_recipe() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = registry.begin(
        request_id="req-runtime",
        voice_id="narrator",
        voice_revision="vr_" + "a" * 32,
        model_artifact="tts-artifact",
        model_source="source-model",
        model_variant="base",
        model_catalog_revision="catalog-1",
        model_runtime_revision=None,
        output_format="pcm",
        sample_rate=24_000,
        recipe=_recipe(seed_policy="derived"),
    )

    registry.bind_model_runtime_revision(receipt_id, "rt_" + ("b" * 64))

    recipe = registry.get(receipt_id)["recipe"]
    assert isinstance(recipe, dict)
    assert recipe["state"] == "complete"
    assert recipe["model"]["engine_revision"] == "rt_" + ("b" * 64)
    assert recipe["digest"] == _recipe(
        seed_policy="derived",
        engine_revision="rt_" + ("b" * 64),
    ).digest


def _begin_with_recipe(registry: RenderReceiptRegistry, request_id: str) -> str:
    return registry.begin(
        request_id=request_id,
        voice_id="narrator",
        voice_revision="vr_" + "a" * 32,
        model_artifact="tts-artifact",
        model_source="source-model",
        model_variant="base",
        model_catalog_revision="catalog-1",
        model_runtime_revision="rt_" + ("b" * 64),
        output_format="pcm",
        sample_rate=24_000,
        recipe=_recipe(seed_policy=None, engine_revision="rt_" + ("b" * 64)),
    )


def test_binding_observed_sampling_completes_the_recipe() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin_with_recipe(registry, "req-sampling")

    assert registry.bind_observed_sampling(
        receipt_id,
        seed_policy="caller_fixed",
        observed_sampling_parameters={"seed": 101, "temperature": 0.7},
    )

    recipe = registry.get(receipt_id)["recipe"]
    assert isinstance(recipe, dict)
    assert recipe["parameters"]["seed_policy"] == "caller_fixed"
    assert recipe["parameters"]["observed_sampling_parameters"] == {
        "seed": 101,
        "temperature": 0.7,
    }
    assert recipe["state"] == "complete"
    assert recipe["digest"] is not None


def test_observed_sampling_is_bound_at_most_once() -> None:
    """A late second report cannot rewrite what this render actually sampled with."""
    registry = RenderReceiptRegistry()
    receipt_id = _begin_with_recipe(registry, "req-sampling-once")
    registry.bind_observed_sampling(
        receipt_id,
        seed_policy="caller_fixed",
        observed_sampling_parameters={"seed": 101},
    )

    assert not registry.bind_observed_sampling(
        receipt_id,
        seed_policy="unseeded_sampler",
        observed_sampling_parameters={"seed": None},
    )
    recipe = registry.get(receipt_id)["recipe"]
    assert isinstance(recipe, dict)
    assert recipe["parameters"]["seed_policy"] == "caller_fixed"


def test_a_terminal_receipt_never_late_binds_sampling_facts() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin_with_recipe(registry, "req-sampling-terminal")
    registry.complete(receipt_id)

    assert not registry.bind_observed_sampling(
        receipt_id,
        seed_policy="caller_fixed",
        observed_sampling_parameters={"seed": 101},
    )
    recipe = registry.get(receipt_id)["recipe"]
    assert isinstance(recipe, dict)
    assert recipe["parameters"]["seed_policy"] is None
    assert "parameters.seed_policy" in recipe["missing_fields"]


def test_a_blank_seed_policy_is_refused_rather_than_stored() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin_with_recipe(registry, "req-sampling-blank")

    with pytest.raises(ValueError):
        registry.bind_observed_sampling(
            receipt_id,
            seed_policy="",
            observed_sampling_parameters={},
        )


def test_a_receipt_without_a_recipe_never_grows_one_from_sampling() -> None:
    """Sampling facts complete a recipe; they never invent one."""
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry, "req-no-recipe")

    assert not registry.bind_observed_sampling(
        receipt_id,
        seed_policy="caller_fixed",
        observed_sampling_parameters={"seed": 101},
    )
    assert registry.get(receipt_id)["recipe"] is None

def test_a_receipt_started_without_a_recipe_reports_none() -> None:
    registry = RenderReceiptRegistry()

    receipt = registry.get(_begin(registry))

    assert receipt["recipe"] is None


@pytest.mark.parametrize(
    ("finish", "status", "error_code"),
    [
        ("cancel", "cancelled", "cancelled"),
        ("fail", "error", "backend_timeout"),
    ],
)
def test_non_success_terminal_receipts_never_look_completed(
    finish: str,
    status: str,
    error_code: str,
) -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    registry.accept_pcm(receipt_id, b"\x00\x00" * 4)
    if finish == "cancel":
        registry.cancel(receipt_id)
    else:
        registry.fail(receipt_id, error_code)

    receipt = registry.get(receipt_id)
    assert receipt["status"] == status
    assert receipt["error_code"] == error_code
    assert receipt["audio"]["sample_count"] == 4


def test_odd_pcm_is_rejected_without_advancing_integrity_state() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    with pytest.raises(ValueError, match="whole samples"):
        registry.accept_pcm(receipt_id, b"\x00")
    receipt = registry.get(receipt_id)
    assert receipt["audio"]["sample_count"] == 0
    assert receipt["audio"]["pcm_sha256"] == hashlib.sha256(b"").hexdigest()


def test_terminal_receipt_rejects_late_audio() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)
    registry.complete(receipt_id)
    with pytest.raises(RuntimeError, match="terminal"):
        registry.accept_pcm(receipt_id, b"\x00\x00")


def test_empty_receipt_cannot_be_completed() -> None:
    registry = RenderReceiptRegistry()
    receipt_id = _begin(registry)

    registry.complete(receipt_id)

    receipt = registry.get(receipt_id)
    assert receipt["status"] == "error"
    assert receipt["error_code"] == "empty_audio"


def test_find_by_request_id_returns_latest_receipt() -> None:
    registry = RenderReceiptRegistry()
    first = _begin(registry, request_id="shared")
    registry.complete(first)
    second = _begin(registry, request_id="shared")
    registry.fail(second, "backend_error")
    assert registry.find_by_request_id("shared")["receipt_id"] == second
    with pytest.raises(KeyError):
        registry.find_by_request_id("missing")


def test_bounded_store_evicts_only_terminal_receipts() -> None:
    registry = RenderReceiptRegistry(max_entries=2)
    first = _begin(registry, request_id="first")
    registry.complete(first)
    second = _begin(registry, request_id="second")
    third = _begin(registry, request_id="third")

    with pytest.raises(KeyError):
        registry.get(first)
    assert registry.get(second)["status"] == "pending"
    assert registry.get(third)["status"] == "pending"


def test_store_full_of_pending_receipts_fails_closed() -> None:
    registry = RenderReceiptRegistry(max_entries=1)
    first = _begin(registry, request_id="first")
    with pytest.raises(RuntimeError, match="full of pending"):
        _begin(registry, request_id="second")
    assert registry.get(first)["status"] == "pending"
