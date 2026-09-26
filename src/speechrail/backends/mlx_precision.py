"""SpeechRail 精度名与 vendor MLX loader 实际接收的 dtype 之间的唯一映射。

ASR 与 ForcedAligner 都以 ``mx.Dtype`` 构造 vendor session。不显式传入时 vendor
统一退回 ``mx.float16``。要求 bfloat16 的参考档因此会在加载阶段被静默改写成
float16。worker 仍然报告 bfloat16。实际权重已不是声明的身份。

这个映射区分两种快照。

- **预量化快照**。int8 权重已经在制品内部。loader 的 dtype 只影响非权重的计算
  精度。传 ``int8`` 会落到浮点激活上。因此固定使用 vendor 的 float16 计算默认
  值。int8 只作为 worker 对外声明的身份。
- **未量化快照**。必须按声明精度加载。loader 自报的 dtype 才能与请求一致并通过
  校验。不能回落到设备默认值。
"""

from __future__ import annotations

from typing import Any, Final

SUPPORTED_DTYPES: Final = frozenset({"float16", "float32", "bfloat16", "int8"})
QUANTIZED_COMPUTE_DTYPE: Final = "float16"


def resolve_load_dtype(dtype: str, *, snapshot_quantized: bool) -> str:
    """返回 vendor MLX loader 必须收到的精度名。"""

    if dtype not in SUPPORTED_DTYPES:
        raise ValueError(f"backend_dtype_unavailable: unsupported dtype {dtype!r}")
    return QUANTIZED_COMPUTE_DTYPE if snapshot_quantized else dtype


def mlx_dtype(name: str) -> Any:
    """返回 ``name`` 对应的 ``mlx.core`` dtype 对象。未知名称 fail-closed。"""

    import mlx.core as mx  # type: ignore[import-not-found]

    resolved = getattr(mx, name, None)
    if resolved is None:
        raise RuntimeError(f"backend_dtype_unavailable: mlx has no dtype {name!r}")
    return resolved


__all__ = [
    "QUANTIZED_COMPUTE_DTYPE",
    "SUPPORTED_DTYPES",
    "mlx_dtype",
    "resolve_load_dtype",
]
