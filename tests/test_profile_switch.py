from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path

import pytest

from speechrail.service.model_store import PreparedArtifact, PreparedModelSet
from speechrail.service.profile_store import ProfileStore
from speechrail.service.profile_switch import ApplyResult, apply_prepared_profile


def _prepared(preset: str) -> PreparedModelSet:
    asr_key = "asr-small" if preset == "light" else "asr-large"
    tts_key = "tts-design" if preset == "quality" else "tts-custom"
    asr = PreparedArtifact(
        key=asr_key,
        path=Path(f"/models/{asr_key}"),
        model_id=f"fixture/{asr_key}",
        revision="a" * 40,
        family="qwen3_asr",
        variant="asr",
        quantization={},
        source={},
        sources=(),
        files=(),
    )
    tts = PreparedArtifact(
        key=tts_key,
        path=Path(f"/models/{tts_key}"),
        model_id=f"fixture/{tts_key}",
        revision="b" * 40,
        family="qwen3_tts",
        variant="voice_design" if preset == "quality" else "custom_voice",
        quantization={},
        source={},
        sources=(),
        files=(),
    )
    return PreparedModelSet(
        prepared_id=f"prepared-{preset}",
        preset=preset,
        runtime_lock_id="runtime-v1",
        asr=asr,
        tts=tts,
    )


def _selection(prepared: PreparedModelSet, generation: int) -> dict[str, object]:
    return {
        "schema_version": 1,
        "preset": prepared.preset,
        "generation": generation,
        "asr": prepared.asr.key,
        "tts": prepared.tts.key,
        "runtime_lock_id": prepared.runtime_lock_id,
    }


class FakeService:
    def __init__(
        self,
        events: list[str],
        *,
        fail_start_at: int | None = None,
        fail_stop_at: int | None = None,
    ) -> None:
        self.events = events
        self.fail_start_at = fail_start_at
        self.fail_stop_at = fail_stop_at
        self.starts = 0
        self.stops = 0

    def stop(self) -> None:
        self.stops += 1
        self.events.append("stop")
        if self.fail_stop_at == self.stops:
            raise RuntimeError("stop failed")

    def start(self) -> None:
        self.starts += 1
        self.events.append("start")
        if self.fail_start_at == self.starts:
            raise RuntimeError("start failed")


class FakeSmoke:
    def __init__(
        self, events: list[str], *, fail_presets: set[str] | None = None, interrupt: bool = False
    ) -> None:
        self.events = events
        self.fail_presets = fail_presets or set()
        self.interrupt = interrupt

    def run(self, prepared: PreparedModelSet) -> None:
        self.events.append(f"smoke:{prepared.preset}")
        if self.interrupt:
            raise KeyboardInterrupt
        if prepared.preset in self.fail_presets:
            raise RuntimeError("smoke failed")


def _id_resolver(
    prepared: PreparedModelSet, events: list[str]
):
    def resolve(prepared_id: str, app_home: Path) -> PreparedModelSet:
        assert prepared_id == prepared.prepared_id
        assert app_home.is_absolute()
        events.append(f"resolve:{prepared.preset}")
        return prepared

    return resolve


def _selection_resolver(
    choices: Mapping[str, PreparedModelSet], events: list[str]
):
    def resolve(selection: Mapping[str, object], app_home: Path) -> PreparedModelSet:
        assert app_home.is_absolute()
        preset = str(selection["preset"])
        events.append(f"resolve_previous:{preset}")
        return choices[preset]

    return resolve


def test_success_stops_before_staging_and_commits_only_after_smoke(tmp_path: Path) -> None:
    events: list[str] = []
    old, candidate = _prepared("quality"), _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(old, 1))

    result = apply_prepared_profile(
        candidate.prepared_id,
        app_home=tmp_path,
        service=FakeService(events),
        smoke=FakeSmoke(events),
        store=store,
        prepared_resolver=_id_resolver(candidate, events),
        selection_resolver=_selection_resolver({"quality": old}, events),
    )

    assert result.status == "committed"
    assert store.recover() == _selection(candidate, 2)
    assert events == [
        "resolve:light",
        "resolve_previous:quality",
        "stop",
        "start",
        "smoke:light",
    ]


def test_unresolvable_candidate_never_stops_service(tmp_path: Path) -> None:
    events: list[str] = []

    def reject(prepared_id: str, app_home: Path) -> PreparedModelSet:
        raise ValueError("untrusted")

    with pytest.raises(ValueError, match="untrusted"):
        apply_prepared_profile(
            "unknown",
            app_home=tmp_path,
            service=FakeService(events),
            smoke=FakeSmoke(events),
            prepared_resolver=reject,
        )

    assert events == []
    assert not (tmp_path / "state").exists()


def test_failed_candidate_smoke_restores_and_smokes_previous_once(tmp_path: Path) -> None:
    events: list[str] = []
    old, candidate = _prepared("quality"), _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(old, 1))

    result = apply_prepared_profile(
        candidate.prepared_id,
        app_home=tmp_path,
        service=FakeService(events),
        smoke=FakeSmoke(events, fail_presets={"light"}),
        store=store,
        prepared_resolver=_id_resolver(candidate, events),
        selection_resolver=_selection_resolver({"quality": old}, events),
    )

    assert result.status == "rolled_back"
    assert result.error_code == "profile_switch_failed"
    assert store.recover() == _selection(old, 1)
    assert events == [
        "resolve:light",
        "resolve_previous:quality",
        "stop",
        "start",
        "smoke:light",
        "stop",
        "start",
        "smoke:quality",
    ]


def test_failed_rollback_is_not_ready_and_does_not_retry(tmp_path: Path) -> None:
    events: list[str] = []
    old, candidate = _prepared("quality"), _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(old, 1))

    result = apply_prepared_profile(
        candidate.prepared_id,
        app_home=tmp_path,
        service=FakeService(events, fail_start_at=2),
        smoke=FakeSmoke(events, fail_presets={"light"}),
        store=store,
        prepared_resolver=_id_resolver(candidate, events),
        selection_resolver=_selection_resolver({"quality": old}, events),
    )

    assert result.status == "not_ready"
    assert events.count("start") == 2
    journal = store._journal()
    assert journal is not None and journal["stage"] == "NOT_READY"


def test_same_complete_selection_is_idempotent(tmp_path: Path) -> None:
    events: list[str] = []
    current = _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(current, 3))

    result = apply_prepared_profile(
        current.prepared_id,
        app_home=tmp_path,
        service=FakeService(events),
        smoke=FakeSmoke(events),
        store=store,
        prepared_resolver=_id_resolver(current, events),
        selection_resolver=_selection_resolver({"light": current}, events),
    )

    assert result == ApplyResult(status="unchanged", operation_id=None, error_code=None)
    assert events == ["resolve:light"]


def test_recovery_continues_when_second_stop_reports_failure(tmp_path: Path) -> None:
    events: list[str] = []
    old, candidate = _prepared("quality"), _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(old, 1))

    result = apply_prepared_profile(
        candidate.prepared_id,
        app_home=tmp_path,
        service=FakeService(events, fail_stop_at=2),
        smoke=FakeSmoke(events, fail_presets={"light"}),
        store=store,
        prepared_resolver=_id_resolver(candidate, events),
        selection_resolver=_selection_resolver({"quality": old}, events),
    )

    assert result.status == "rolled_back"
    assert store.recover() == _selection(old, 1)
    assert events[-3:] == ["stop", "start", "smoke:quality"]


def test_interrupt_rolls_back_before_propagating(tmp_path: Path) -> None:
    events: list[str] = []
    old, candidate = _prepared("quality"), _prepared("light")
    store = ProfileStore(tmp_path)
    store.initialize(_selection(old, 1))

    with pytest.raises(KeyboardInterrupt):
        apply_prepared_profile(
            candidate.prepared_id,
            app_home=tmp_path,
            service=FakeService(events),
            smoke=FakeSmoke(events, interrupt=True),
            store=store,
            prepared_resolver=_id_resolver(candidate, events),
            selection_resolver=_selection_resolver({"quality": old}, events),
        )

    assert store.recover() == _selection(old, 1)
    assert events[-3:] == ["stop", "start", "smoke:quality"]


def test_failed_first_install_stays_stopped_and_unconfigured(tmp_path: Path) -> None:
    events: list[str] = []
    candidate = _prepared("light")
    result = apply_prepared_profile(
        candidate.prepared_id,
        app_home=tmp_path,
        service=FakeService(events),
        smoke=FakeSmoke(events, fail_presets={"light"}),
        prepared_resolver=_id_resolver(candidate, events),
    )

    assert result.status == "rolled_back"
    assert ProfileStore(tmp_path).recover() is None
    assert events == ["resolve:light", "stop", "start", "smoke:light", "stop"]
