# ADR-0003：模型运行时隔离、外部快照与离线准入

## Status

Accepted

## Date

2026-08-31

## Context

`voice-realtime` 的 Qwen3 native path 已经验证了独立 Python worker、MPS identity 检查、
仓库外模型快照和离线环境的必要性。不同 runtime 的 Python 依赖、设备回退和模型加载
失败不能直接暴露给客户端。

## Decision

- SpeechRail supervisor 和 Qwen worker 分进程。
- model snapshot 使用外部绝对路径，启动前校验文件清单和哈希。
- worker 默认 `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`、
  `PYTORCH_ENABLE_MPS_FALLBACK=0`。
- MPS profile 发现 device/dtype 不匹配时 fail fast，不静默 CPU fallback。
- API 请求不触发模型下载；模型下载是单独运维步骤。
- 单实例默认一个推理槽位，不通过多个 ASGI worker 复制模型。

## Consequences

- 首次部署需要显式准备模型和 runtime。
- 运行更可预测、更容易审计和回滚。
- 需要 worker framed protocol、生命周期和资源清理测试。
