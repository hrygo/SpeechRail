---
title: "重计算预留、资源声明与故障隔离"
status: active
date: 2026-10-18
---

# 重计算预留、资源声明与故障隔离

ASR、TTS 和分人共用一个 Resource Governor。不同能力的计算是否可重叠，由启用组件的完整 footprint 与物理内存预算决定；相同模型仍串行，不复制 worker 提高吞吐。依据见 [ADR-0016](../decisions/0016-configurable-heavy-compute-overlap.md) 与 [ADR-0022](../decisions/0022-asr-diarization-heavy-compute-overlap.md)。

## 资源声明

| 配置键 | 含义 |
|---|---|
| `SPEECHRAIL_ALLOW_HEAVY_OVERLAP` | `auto` 依声明/预算决定；`true`/`false` 是运维实验强制开关 |
| `SPEECHRAIL_ASR_RESIDENT_BYTES` | ASR 驻留峰值；启用时 0 表示未知 |
| `SPEECHRAIL_TTS_RESIDENT_BYTES` | 单个可能常驻 TTS worker 的峰值；组合根按实际可驻留 worker 数计入 |
| `SPEECHRAIL_DIARIZATION_RESIDENT_BYTES` | 四槽分人驻留峰值 |
| `SPEECHRAIL_DIARIZATION_DYNAMIC_RESIDENT_BYTES` | 会议分人驻留峰值 |

还须按现有 `ComponentFootprint` 口径核对共享依赖、active peak、workspace 和安全余量，避免重计。两个分人后端共享独占 owner，可以取已声明峰值的 max；任一启用路径的声明为 0 仍属未知。

`auto` 缺声明或总量超预算时拒绝重叠，单任务预算也可能直接拒绝推理。`false` 只关闭跨轴重叠，不豁免单任务预算或持久隔离；`true` 不代表质量/性能已认证，也不能在回收失败后继续使用未知资源。

峰值必须来自确切 worker PID/后代的 `phys_footprint`，覆盖冷启动、稳态、长静音恢复和 finish/cancel。RSS 不能按固定倍数换算 footprint。模型大小、旧机器结果、sleep 模拟或瞬时 smoke 均不能作为本机驻留峰值声明。

## 故障状态与恢复

分人 owner 从 worker factory 前持续持有到 child 确认回收，chunk 间隙也不允许另一会话加载权重。回收失败时保留 owner/引用，governor 的内部 snapshot 以 `retained_diarization` 记录未确认释放的占用，等待者收到隔离错误。

只有重叠获准且完整资源上界仍可信，其他能力 lane 才能继续；否则所有重计算 fail-closed。能力诊断反映持久隔离，不能只依据进程存在、模型文件存在或 `/readyz=200` 判断质量和性能。

恢复服务、变更声明或回退版本须遵循[本机运维技能](../../.agents/skills/speechrail-local-deploy/SKILL.md)和[运维手册](operations-runbook.md)，核对唯一 managed runtime、label、PID 与端口。不要手动清空 owner/计数绕过精确回收，也不要用模糊进程匹配杀进程。回退保留私有配置、模型与用户数据库。

## 验收条件

配置放行只证明满足准入条件。要声明并发收益，仍须同模型、同 PCM 的 ASR-only/diarization-only/serial/overlap 真实运行、预登记 ABBA、质量、实时标签/finish 延迟和 footprint 证据；机制测试通过不能替代。当前阶段记录见[实施记录](../implementation/2026-10-18-meeting-diarization-handoff-audit.md)。本说明不授权启停、配置变更、模型运行或 benchmark。
