"""让 Batch 与 Streaming 共用一个有界的 Qwen3 IPC owner。"""

from __future__ import annotations

import asyncio
import contextlib
import time
from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

from speechrail.runtime.asr_mode import AsrModeGate
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    error_frame_message,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

if TYPE_CHECKING:
    from speechrail.backends.qwen3_native import Qwen3BackendConfig
    from speechrail.backends.qwen3_streaming import Qwen3StreamingBackendConfig

SESSION_QUEUE_MAXSIZE = 64
MAX_SESSIONS = 8
_RETIRED_REQUEST_LIMIT = 64


class SharedWorkerConfig(Protocol):
    """Qwen3SharedWorker 所需的最窄配置协议。"""

    @property
    def model_dir(self) -> Path: ...

    @property
    def device(self) -> str: ...

    @property
    def dtype(self) -> str: ...

    @property
    def timeout_seconds(self) -> float: ...

    def worker_spec(self) -> WorkerProcessSpec: ...


if TYPE_CHECKING:

    def _check_existing_configs(
        batch: Qwen3BackendConfig,
        streaming: Qwen3StreamingBackendConfig,
    ) -> None:
        Qwen3SharedWorker(batch)
        Qwen3SharedWorker(streaming)


class FrameRouter:
    """为 batch request 与 streaming session 提供隔离的 ID 命名空间。"""

    @staticmethod
    def route_key(frame: Mapping[str, object]) -> tuple[str, str] | None:
        request_id = frame.get("request_id")
        if isinstance(request_id, str) and request_id:
            return ("batch", request_id)
        session_id = frame.get("session_id")
        if isinstance(session_id, str) and session_id:
            return ("stream", session_id)
        return None


@dataclass(slots=True)
class _SessionSlot:
    queue: asyncio.Queue[dict[str, object]]
    generation: int


@dataclass(frozen=True, slots=True)
class _PendingRequest:
    future: asyncio.Future[dict[str, object]]
    generation: int


class Qwen3SharedWorker:
    """管理一个 Qwen3 子进程, 并由单一 dispatcher 分发所有返回帧。"""

    def __init__(self, config: SharedWorkerConfig, *, max_sessions: int = MAX_SESSIONS) -> None:
        if not 1 <= max_sessions <= MAX_SESSIONS:
            raise ValueError(f"max_sessions must be between 1 and {MAX_SESSIONS}")
        self.config = config
        self.max_sessions = max_sessions
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._start_lock = asyncio.Lock()
        self._ready = False
        self._identity: tuple[str, str] | None = None
        # gate 的生命周期属于 owner, 重启子进程时也必须保持同一个对象。
        self._mode_gate = AsrModeGate()
        self._generation = 0
        self._dispatcher: asyncio.Task[None] | None = None
        self._sessions: dict[str, _SessionSlot] = {}
        self._requests: dict[str, _PendingRequest] = {}
        self._retired_request_ids: deque[str] = deque(maxlen=_RETIRED_REQUEST_LIMIT)
        self._retired_request_id_set: set[str] = set()
        self._failure_broadcasted = False
        self._metrics: dict[str, int] = {
            "unknown_frames": 0,
            "duplicate_frames": 0,
            "duplicate_requests": 0,
            "queue_full_sessions": 0,
            "global_errors": 0,
        }
        self.last_active = time.monotonic()

    @property
    def alive(self) -> bool:
        """返回底层子进程是否仍在运行。"""

        return self._transport.alive

    @property
    def ready(self) -> bool:
        """返回 owner 是否完成握手且底层子进程仍存活。"""

        return self._ready and self.alive

    @property
    def identity(self) -> tuple[str, str] | None:
        """返回握手确认的 ``(device, dtype)``; 未 ready 时不暴露旧身份。"""

        if not self.ready:
            return None
        return self._identity

    @property
    def mode_gate(self) -> AsrModeGate:
        """返回 owner 共用的 ASR 模式门, 不随子进程重启替换。"""

        return self._mode_gate

    @property
    def timeout_seconds(self) -> float:
        """返回配置中的请求和帧超时。"""

        return self.config.timeout_seconds

    @property
    def generation(self) -> int:
        """返回当前子进程 generation。"""

        return self._generation

    @property
    def pending_request_count(self) -> int:
        """返回当前等待返回帧的 batch 请求数。"""

        return len(self._requests)

    @property
    def metrics(self) -> dict[str, int]:
        """返回有限计数器的快照, 不暴露历史 ID。"""

        return dict(self._metrics)

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]:
        """注册一个有界 streaming 队列。"""

        if not isinstance(session_id, str) or not session_id:
            raise ValueError("session_id must be a non-empty string")
        if session_id in self._sessions:
            raise ValueError("session_already_registered")
        if len(self._sessions) >= self.max_sessions:
            raise RuntimeError("session_limit_reached")
        queue: asyncio.Queue[dict[str, object]] = asyncio.Queue(maxsize=SESSION_QUEUE_MAXSIZE)
        self._sessions[session_id] = _SessionSlot(queue=queue, generation=self._generation)
        self.last_active = time.monotonic()
        return queue

    def unregister_session(self, session_id: str) -> None:
        """移除一个 session, 不保留已退休 ID。"""

        self._sessions.pop(session_id, None)
        self.last_active = time.monotonic()

    async def start(self) -> None:
        """完成 ready 握手后再启动唯一 dispatcher。"""

        if self._ready and self.alive:
            return
        async with self._start_lock:
            if self._ready and self.alive:
                return
            await self._stop_dispatcher()
            self._generation += 1
            generation = self._generation
            self._failure_broadcasted = False
            self._identity = None
            self._clear_retired_request_ids()
            try:
                await self._transport.start()
                ready = await self._transport.exchange(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "start",
                        "model_dir": str(self.config.model_dir),
                        "device": self.config.device,
                        "dtype": self.config.dtype,
                    }
                )
                if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
                    raise RuntimeError(error_frame_message(ready, "worker_start_failed"))
                if (
                    ready.get("device") != self.config.device
                    or ready.get("dtype") != self.config.dtype
                ):
                    raise RuntimeError("backend_identity_mismatch")
            except BaseException:
                self._ready = False
                await self._fail_generation(generation, code="worker_start_failed")
                raise

            for slot in self._sessions.values():
                slot.generation = generation
            self._ready = True
            self._identity = (self.config.device, self.config.dtype)
            self.last_active = time.monotonic()
            self._dispatcher = asyncio.create_task(
                self._dispatch_loop(generation),
                name=f"qwen3-shared-dispatch-{generation}",
            )

    async def request(
        self,
        frame: Mapping[str, object],
        binary: bytes | None = None,
    ) -> dict[str, object]:
        """发送一个 batch 请求并等待 dispatcher 投递的同名 future。"""

        request_id = frame.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("request_id must be a non-empty string")
        await self.start()
        if not self._ready:
            raise RuntimeError("worker_not_ready")
        if request_id in self._requests or request_id in self._retired_request_id_set:
            self._metrics["duplicate_requests"] += 1
            raise ValueError("duplicate request_id")

        loop = asyncio.get_running_loop()
        pending = _PendingRequest(future=loop.create_future(), generation=self._generation)
        self._requests[request_id] = pending
        try:
            await self.send(frame, binary_payload=binary)
            try:
                return await asyncio.wait_for(
                    asyncio.shield(pending.future), timeout=self.timeout_seconds
                )
            except TimeoutError as exc:
                raise TimeoutError("worker_request_timeout") from exc
        except TimeoutError:
            if self._requests.get(request_id) is pending:
                self._requests.pop(request_id, None)
                self._retire_request_id(request_id)
            await self._fail_generation(pending.generation, code="worker_request_timeout")
            raise
        except (OSError, ProtocolError):
            # send 失败时 future 没有进入 await, 必须显式取消以免遗留未消费的 future。
            if not pending.future.done():
                pending.future.cancel()
            await self._fail_generation(pending.generation, code="worker_unavailable")
            raise
        except asyncio.CancelledError:
            if self._requests.get(request_id) is pending:
                self._requests.pop(request_id, None)
                self._retire_request_id(request_id)
                await self._fail_generation(pending.generation, code="worker_request_cancelled")
            raise
        finally:
            if self._requests.get(request_id) is pending:
                self._requests.pop(request_id, None)
                self._retire_request_id(request_id)

    async def send(
        self,
        frame: Mapping[str, object],
        binary_payload: bytes | None = None,
    ) -> None:
        """向已 ready 的子进程发送帧, 不读取返回值。"""

        if not self._ready:
            raise RuntimeError("worker_not_ready")
        await self._transport.send(frame, binary_payload=binary_payload)
        self.last_active = time.monotonic()

    async def trim_memory(self) -> None:
        """向运行中的 worker 请求受控内存整理。"""

        if self.alive and self._ready:
            with contextlib.suppress(Exception):
                await self.send({"version": PROTOCOL_VERSION, "type": "trim_memory"})

    async def close(self) -> None:
        """取消 dispatcher, 清理 session/future 并终止当前子进程。"""

        async with self._start_lock:
            self._ready = False
            self._identity = None
            self._failure_broadcasted = True
            await self._stop_dispatcher()
            for pending in self._requests.values():
                if not pending.future.done():
                    pending.future.cancel()
            self._requests.clear()
            self._sessions.clear()
            await self._transport.close()
            # 让子进程 pipe 的 connection_lost 回调在事件循环关闭前完成。
            await asyncio.sleep(0)
            self.last_active = time.monotonic()

    async def _dispatch_loop(self, generation: int) -> None:
        try:
            while self._ready and generation == self._generation:
                # wait_for_frame 允许真正的 idle, 但半帧超时由 transport 转成 ProtocolError,
                # 这里必须结束本代 worker, 不能循环吞掉它。
                frame = await self._transport.receive(wait_for_frame=True)
                if generation != self._generation or not self._ready:
                    return
                self.last_active = time.monotonic()
                await self._route_frame(frame, generation)
        except asyncio.CancelledError:
            raise
        except Exception:
            await self._fail_generation(generation, code="worker_unavailable")
        finally:
            if self._dispatcher is asyncio.current_task():
                self._dispatcher = None

    async def _route_frame(self, frame: Mapping[str, object], generation: int) -> None:
        route = FrameRouter.route_key(frame)
        if route is None:
            if frame.get("type") == "error":
                if self._failure_broadcasted:
                    self._metrics["duplicate_frames"] += 1
                    return
                self._metrics["global_errors"] += 1
                await self._fail_generation(
                    generation,
                    code=str(frame.get("code") or "worker_error"),
                    frame=frame,
                )
            else:
                self._metrics["unknown_frames"] += 1
            return

        namespace, route_id = route
        if namespace == "batch":
            pending = self._requests.get(route_id)
            if pending is None or pending.generation != generation:
                if route_id in self._retired_request_id_set:
                    self._metrics["duplicate_frames"] += 1
                else:
                    self._metrics["unknown_frames"] += 1
                return
            self._requests.pop(route_id, None)
            self._retire_request_id(route_id)
            if pending.future.done():
                self._metrics["duplicate_frames"] += 1
            else:
                pending.future.set_result(dict(frame))
            return

        slot = self._sessions.get(route_id)
        if slot is None or slot.generation != generation:
            self._metrics["unknown_frames"] += 1
            return
        await self._deliver_session_frame(route_id, slot, dict(frame))

    async def _fail_generation(
        self,
        generation: int,
        *,
        code: str,
        frame: Mapping[str, object] | None = None,
    ) -> None:
        if generation != self._generation:
            return
        self._ready = False
        self._identity = None
        if not self._failure_broadcasted:
            self._failure_broadcasted = True
            terminal = dict(frame) if frame is not None else {"type": "error", "code": code}
            for session_id, slot in tuple(self._sessions.items()):
                self._deliver_terminal_frame(session_id, slot, terminal)
            self._sessions.clear()
            for request_id, pending in tuple(self._requests.items()):
                self._requests.pop(request_id, None)
                self._retire_request_id(request_id)
                if not pending.future.done():
                    pending.future.set_exception(RuntimeError(code))
        await self._transport.abort()

    async def _deliver_session_frame(
        self,
        session_id: str,
        slot: _SessionSlot,
        frame: dict[str, object],
    ) -> None:
        if slot.queue.full():
            self._metrics["queue_full_sessions"] += 1
            # 队列中可能已有 completed/result, 此时不能用 finished 覆盖它并伪造成功。
            # 统一报告 queue_full, 由上层决定是否重建会话。
            terminal: dict[str, object] = {
                "type": "error",
                "code": "session_queue_full",
                "session_id": session_id,
            }
            _clear_queue(slot.queue)
            slot.queue.put_nowait(terminal)
            self._sessions.pop(session_id, None)
            # 释放 worker 内部的 align buffer; 直接 await 保证发送失败能结束本代,
            # 不创建无法回收的后台 cancel task。
            await self.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "cancel",
                    "session_id": session_id,
                }
            )
            return
        slot.queue.put_nowait(frame)
        if _is_terminal_frame(frame):
            self._sessions.pop(session_id, None)

    def _deliver_terminal_frame(
        self,
        session_id: str,
        slot: _SessionSlot,
        frame: Mapping[str, object],
    ) -> None:
        del session_id
        _clear_queue(slot.queue)
        slot.queue.put_nowait(dict(frame))

    async def _stop_dispatcher(self) -> None:
        dispatcher, self._dispatcher = self._dispatcher, None
        if dispatcher is None or dispatcher is asyncio.current_task():
            return
        dispatcher.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await dispatcher

    def _retire_request_id(self, request_id: str) -> None:
        if request_id in self._retired_request_id_set:
            return
        if len(self._retired_request_ids) == self._retired_request_ids.maxlen:
            oldest = self._retired_request_ids[0]
            self._retired_request_id_set.discard(oldest)
        self._retired_request_ids.append(request_id)
        self._retired_request_id_set.add(request_id)

    def _clear_retired_request_ids(self) -> None:
        self._retired_request_ids.clear()
        self._retired_request_id_set.clear()


def _clear_queue(queue: asyncio.Queue[dict[str, object]]) -> None:
    while True:
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            return


def _is_terminal_frame(frame: Mapping[str, object]) -> bool:
    return frame.get("type") in {"finished", "error", "result", "terminal", "session.closed"} or (
        frame.get("final") is True
    )


__all__ = ["MAX_SESSIONS", "FrameRouter", "Qwen3SharedWorker", "SharedWorkerConfig"]
