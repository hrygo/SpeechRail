"""ASR batch/streaming 模式的同步准入门。"""

from __future__ import annotations

from typing import Literal

AsrMode = Literal["batch", "streaming"]


class AsrModeBusy(RuntimeError):  # noqa: N818 - 公共契约要求保留此名称
    """请求模式与当前活动任务冲突时抛出。"""


class AsrModeLease:
    """由单个 :class:`AsrModeGate` 签发并记录释放状态的租约。

    调用方构造的对象使用独立 owner, 不能由任何 gate 释放。
    """

    __slots__ = ("__weakref__", "_mode", "_owner", "_released")

    def __init__(self, mode: AsrMode, *, _owner: object | None = None) -> None:
        self._owner = object() if _owner is None else _owner
        self._mode = mode
        self._released = False

    @classmethod
    def _issued(cls, owner: object, mode: AsrMode) -> AsrModeLease:
        return cls(mode, _owner=owner)

    @property
    def mode(self) -> AsrMode:
        return self._mode

    @property
    def released(self) -> bool:
        return self._released


class AsrModeGate:
    """同步跟踪 batch/streaming ASR 准入。

    由 asyncio 事件循环线程调用; 状态变更不执行 I/O、等待或任务调度。
    """

    __slots__ = ("_batch_active", "_owner", "_streaming_count")

    def __init__(self) -> None:
        self._owner = object()
        self._batch_active = False
        self._streaming_count = 0

    @property
    def active_mode(self) -> AsrMode | None:
        if self._batch_active:
            return "batch"
        if self._streaming_count > 0:
            return "streaming"
        return None

    @property
    def active_count(self) -> int:
        if self._batch_active:
            return 1
        return self._streaming_count

    def acquire(self, mode: AsrMode) -> AsrModeLease:
        """获取 ``mode`` 租约; 冲突时立即失败。"""
        if mode not in ("batch", "streaming"):
            raise ValueError(
                f"unsupported ASR mode {mode!r}; expected 'batch' or 'streaming'"
            )

        if mode == "batch":
            if self.active_count:
                raise AsrModeBusy(
                    f"ASR mode is busy: active_mode={self.active_mode!r}, "
                    f"active_count={self.active_count}"
                )
            self._batch_active = True
        else:
            if self._batch_active:
                raise AsrModeBusy(
                    "ASR mode is busy: active_mode='batch', active_count=1"
                )
            self._streaming_count += 1

        return AsrModeLease._issued(self._owner, mode)

    def release(self, lease: AsrModeLease) -> None:
        """释放本 gate 签发的租约; 重复释放不产生影响。"""
        if type(lease) is not AsrModeLease or lease._owner is not self._owner:
            raise ValueError("lease was not issued by this gate")
        if lease.released:
            return

        lease._released = True
        if lease.mode == "batch":
            self._batch_active = False
        else:
            self._streaming_count -= 1
