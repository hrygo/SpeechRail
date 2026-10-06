"""App/服务边界闭环 -- 服务端按共享 fixture 产出事件 (方案 7.2).

这是 fixture 的服务端一侧。它通过真实 `/v1/realtime` WebSocket 与 fake
backend 跑完 `client_script`, 把观测到的事件投影回
`tests/fixtures/assistant_realtime_lifecycle.json` 的 `server_events`。

macOS 侧由 `AssistantRealtimeLifecycleFixtureTests.swift` 消费同一份
`server_events` 驱动生产 `AssistantSession`。两侧共用一份事件序列, 所以服务端
时序一旦变化, 先红的是这个测试; 重录 fixture 时必须同时确认 App 侧仍然成立,
不会各写各的模拟协议然后各自通过。

没有真实音频、模型、网络或凭据。`speechrail.tts.audio.delta` 的 Base64 PCM
按项目规则不写进 fixture, 改为断言它确实出现过 (见 fixture 的
`omitted_event_types_reason`)。
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parent))

from realtime_wire import (
    session_update,
    tts_append_text,
    tts_cancel,
    tts_finish_text,
    tts_start,
)
from test_realtime_openai import FakeStreamingFactory, FakeStreamingSession
from test_realtime_openai import _client as asr_client
from test_realtime_tts_incremental import (
    FakeIncrementalSynthesizer,
)
from test_realtime_tts_incremental import _client as tts_client

FIXTURE_PATH = Path(__file__).resolve().parent / "fixtures" / "assistant_realtime_lifecycle.json"

TERMINALS = frozenset(
    {
        "speechrail.tts.completed",
        "speechrail.tts.cancelled",
        "speechrail.tts.failed",
    }
)

KNOWN_DEFECTS = frozenset(
    {f"D{index:02d}" for index in range(1, 12)} | {f"B{index:02d}" for index in range(1, 9)}
)


def load_fixture() -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(FIXTURE_PATH.read_text(encoding="utf-8")))


def _pcm(frames: int) -> str:
    return base64.b64encode(b"\x00\x00" * frames).decode("ascii")


def _recv(socket: Any, *, expect: str) -> dict[str, Any]:
    """Read one event, failing loudly instead of blocking the suite forever."""
    event = socket.receive_json()
    if event["type"] != expect:
        raise AssertionError(f"expected {expect}, received {event['type']}")
    return cast(dict[str, Any], event)


def _drain_until_terminal(socket: Any) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for _ in range(64):
        event = socket.receive_json()
        events.append(event)
        if event["type"] in TERMINALS:
            return events
    raise AssertionError(f"never reached a terminal: {[e['type'] for e in events]}")


def _project(
    observed: list[dict[str, Any]], expected: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Keep only the fields the fixture pins, per event.

    The fixture records the stable contract surface (order, type, identity and
    the budget/ACK counters), not the volatile per-connection ids. Comparing
    the projection rather than the raw event keeps a connection-id change from
    rewriting this file while still failing on any real ordering or accounting
    regression.
    """
    assert len(observed) == len(expected), (
        f"event count drifted: observed {[e['type'] for e in observed]} "
        f"vs fixture {[e['type'] for e in expected]}"
    )
    projected: list[dict[str, Any]] = []
    for index, (actual, want) in enumerate(zip(observed, expected, strict=True)):
        assert actual["type"] == want["type"], (
            f"event {index} drifted: observed {actual['type']} where the fixture "
            f"expects {want['type']}"
        )
        entry: dict[str, Any] = {}
        for key, want_value in want.items():
            actual_value = actual.get(key)
            if isinstance(want_value, dict) and isinstance(actual_value, dict):
                # Nested contract objects (``limits``, ``error``) are pinned the
                # same way: keep the keys the fixture names, ignore the rest.
                entry[key] = {sub: actual_value.get(sub) for sub in want_value}
            else:
                entry[key] = actual_value
        projected.append(entry)
    return projected


def _run_barge_in_closure() -> list[dict[str, Any]]:
    client = tts_client(FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04",)))
    observed: list[dict[str, Any]] = []
    with client.websocket_connect("/v1/realtime") as socket:
        observed.append(_recv(socket, expect="session.created"))
        socket.send_json(session_update(tts={"enabled": True}))
        observed.append(_recv(socket, expect="session.updated"))
        socket.send_json(tts_start(request_id="req_barge", event_id="evt-start-barge"))
        observed.append(_recv(socket, expect="speechrail.tts.started"))
        for sequence, text in enumerate(("好的，", "我停下了")):
            socket.send_json(
                tts_append_text(request_id="req_barge", sequence=sequence, text=text)
            )
            observed.append(_recv(socket, expect="speechrail.tts.text_accepted"))
        socket.send_json(tts_cancel(request_id="req_barge"))
        observed.append(_recv(socket, expect="speechrail.tts.cancelled"))
        # B05: the terminal is the reuse barrier. A start issued immediately
        # after it must be admitted, not rejected with ``tts_in_progress``.
        socket.send_json(tts_start(request_id="req_next", event_id="evt-start-next"))
        observed.append(_recv(socket, expect="speechrail.tts.started"))
        socket.send_json(tts_cancel(request_id="req_next", event_id="evt-cancel-next"))
        observed.append(_recv(socket, expect="speechrail.tts.cancelled"))
    return observed


def _run_long_reply() -> list[dict[str, Any]]:
    client = tts_client(FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04",)))
    observed: list[dict[str, Any]] = []
    # Every batch is a legal delta, including the whitespace-only ones: a
    # single space and a double space are content, not noise (D11).
    batches = ("Hello", " ", "world\n", "  ", "再见")
    with client.websocket_connect("/v1/realtime") as socket:
        observed.append(_recv(socket, expect="session.created"))
        socket.send_json(session_update(tts={"enabled": True}))
        observed.append(_recv(socket, expect="session.updated"))
        socket.send_json(
            tts_start(
                request_id="req_long",
                event_id="evt-start-long",
                limits={"max_pending_codepoints": 1024},
            )
        )
        observed.append(_recv(socket, expect="speechrail.tts.started"))
        for sequence, text in enumerate(batches):
            socket.send_json(
                tts_append_text(request_id="req_long", sequence=sequence, text=text)
            )
            observed.append(_recv(socket, expect="speechrail.tts.text_accepted"))
        socket.send_json(tts_finish_text(request_id="req_long", last_sequence=4))
        observed.extend(_drain_until_terminal(socket))
    return observed


class _TwoUtteranceFactory(FakeStreamingFactory):
    """Each commit gets its own text, so a lost or doubled item is visible."""

    def __init__(self) -> None:
        super().__init__()
        self.transcripts = ["第一句", "第二句"]

    def create(self, **kwargs: Any) -> FakeStreamingSession:
        session = super().create(**kwargs)
        index = min(self.creates, len(self.transcripts)) - 1
        session.completed_text = self.transcripts[index]
        return session


def _run_input_packetization() -> list[dict[str, Any]]:
    client, _ = asr_client(factory=_TwoUtteranceFactory())
    observed: list[dict[str, Any]] = []
    with client.websocket_connect("/v1/realtime") as socket:
        observed.append(_recv(socket, expect="session.created"))
        # Utterance one: a single 64 ms packet.
        socket.send_json(
            {
                "type": "input_audio_buffer.append",
                "event_id": "evt-a1",
                "audio": _pcm(1536),
            }
        )
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "evt-c1"})
        observed.append(_recv(socket, expect="speechrail.transcription.segment_closed"))
        observed.append(
            _recv(socket, expect="conversation.item.input_audio_transcription.completed")
        )
        # Utterance two: ragged slices, including a one-frame and an odd tail.
        for index, frames in enumerate((1, 7, 1, 5, 2)):
            socket.send_json(
                {
                    "type": "input_audio_buffer.append",
                    "event_id": f"evt-b{index}",
                    "audio": _pcm(frames),
                }
            )
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "evt-c2"})
        observed.append(_recv(socket, expect="speechrail.transcription.segment_closed"))
        observed.append(
            _recv(socket, expect="conversation.item.input_audio_transcription.completed")
        )
    return observed


def _run_reconnect_recovery() -> list[dict[str, Any]]:
    client, _ = asr_client()
    observed: list[dict[str, Any]] = []
    with client.websocket_connect("/v1/realtime") as socket:
        created = _recv(socket, expect="session.created")
        # B08: the candidate fails during validation, so nothing is published.
        socket.send_json(
            session_update(model="no-such-registered-model", event_id="evt-bad-update")
        )
        rejected = _recv(socket, expect="error")
        # The same connection must still be usable, on the same session.
        socket.send_json(session_update(event_id="evt-good-update"))
        updated = _recv(socket, expect="session.updated")
        assert created["session_id"] == updated["session_id"]
        observed.extend([created, rejected, updated])
    return observed


RUNNERS = {
    "barge_in_closure": _run_barge_in_closure,
    "long_reply": _run_long_reply,
    "input_packetization": _run_input_packetization,
    "reconnect_recovery": _run_reconnect_recovery,
}


def test_fixture_only_names_defects_this_plan_defines() -> None:
    fixture = load_fixture()
    assert fixture["version"] == 1
    assert set(RUNNERS) == {scenario["id"] for scenario in fixture["scenarios"]}
    for scenario in fixture["scenarios"]:
        unknown = set(scenario["covers"]) - KNOWN_DEFECTS
        assert not unknown, f"{scenario['id']} names unknown defects: {sorted(unknown)}"


def test_server_event_sequence_matches_shared_fixture() -> None:
    """One comparison per scenario; every failure names the drifted position."""
    fixture = load_fixture()
    omitted = set(fixture["omitted_event_types"])
    seen_omitted: set[str] = set()
    failures: list[str] = []

    for scenario in fixture["scenarios"]:
        observed = RUNNERS[scenario["id"]]()
        seen_omitted.update(omitted & {event["type"] for event in observed})
        # Omitted types are accounted for above, then dropped: their payloads
        # stay out of the fixture, so they cannot take part in the comparison.
        compared = [event for event in observed if event["type"] not in omitted]
        # ``item_ref`` is the fixture's placeholder for a per-utterance id; the
        # identity itself is asserted by the scenario's own test.
        expected = [
            {key: value for key, value in event.items() if key != "item_ref"}
            for event in scenario["server_events"]
        ]
        try:
            projected = _project(compared, expected)
        except AssertionError as error:
            failures.append(f"[{scenario['id']}] {error}")
            continue
        for index, (actual, want) in enumerate(zip(projected, expected, strict=True)):
            if actual != want:
                failures.append(
                    f"[{scenario['id']}] event {index} ({want['type']}): "
                    f"observed {actual} vs fixture {want}"
                )

    assert not failures, "\n".join(failures)
    missing = omitted - seen_omitted
    assert not missing, (
        f"fixture omits {sorted(missing)} but no scenario produced them; the "
        "omission would hide a real regression"
    )


def test_packetization_keeps_one_item_per_commit() -> None:
    """B01/B03/B06 on the wire: no lost tail, no doubled item, contiguous sequence."""
    observed = _run_input_packetization()
    finals = [
        event
        for event in observed
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    ]
    assert [event["transcript"] for event in finals] == ["第一句", "第二句"]
    assert len({event["item_id"] for event in finals}) == 2
    boundaries = [
        event for event in observed
        if event["type"] == "speechrail.transcription.segment_closed"
    ]
    assert [event["commit_event_id"] for event in boundaries] == ["evt-c1", "evt-c2"]
    assert [event["item_id"] for event in boundaries] == [
        event["item_id"] for event in finals
    ]
    assert [event["sample_span"] for event in boundaries] == [
        {"start": 0, "end": 1536},
        {"start": 1536, "end": 1552},
    ]
    assert all(event["reason"] == "client_commit" for event in boundaries)
    assert [event["commit_event_id"] for event in finals] == ["evt-c1", "evt-c2"]
    assert [event["sequence"] for event in observed] == list(range(len(observed)))


def test_packetization_releases_every_asr_session() -> None:
    """B06: each committed utterance releases its backend session exactly once."""
    factory = _TwoUtteranceFactory()
    client, _ = asr_client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        _recv(socket, expect="session.created")
        for commit_id in ("evt-c1", "evt-c2"):
            socket.send_json(
                {
                    "type": "input_audio_buffer.append",
                    "event_id": f"append-{commit_id}",
                    "audio": _pcm(64),
                }
            )
            socket.send_json({"type": "input_audio_buffer.commit", "event_id": commit_id})
            boundary = _recv(socket, expect="speechrail.transcription.segment_closed")
            assert boundary["commit_event_id"] == commit_id
            _recv(socket, expect="conversation.item.input_audio_transcription.completed")
    assert factory.creates == 2
    assert len(factory.released) == 2


def test_rejected_session_update_leaves_the_connection_usable() -> None:
    """B08: a rejected candidate publishes nothing and costs nothing else."""
    observed = _run_reconnect_recovery()
    rejection = observed[1]
    assert rejection["error"]["code"] == "model_not_found"
    assert not any(event["type"] == "session.updated" for event in observed[:2])
    # The successful retry lands on the same connection: nothing was torn down.
    assert observed[0]["session_id"] == observed[2]["session_id"]
    assert [event["sequence"] for event in observed] == [0, 1, 2]
