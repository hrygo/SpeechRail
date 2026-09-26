---
title: "ADR-0021：Extreme BF16 候选档与证据门"
status: accepted
date: 2026-09-23
---

# ADR-0021：Extreme BF16 候选档与证据门

## 状态

Superseded（2026-09-26）。`extreme` 候选档从未启用；当前目标架构已移除档位体系，改为 ASR / TTS 两项
独立 spec（`fast` / `quality` / `reference`），`extreme`、`PresetId`、`ModelPreset` 与
`precision_policy` 均已从代码与 catalog 删除，本 ADR 只作为历史决策记录保留，见
[目标架构](../architecture/2026-09-25-asr-tts-target-architecture-no-legacy.md)。

原状态：Accepted for candidate implementation. Formal activation remains blocked until the release gates below pass.

## 背景

现有 `light`、`balanced`、`quality` profile 使用各自的权重与精度组合。拟新增第四档 `extreme`（界面名「极致」），使用 BF16 ASR、VoiceDesign 与 Base 权重，并复用 `aligner-bf16`。用户决定本轮完成候选代码和静态验收，不执行性能或质量复测；当前没有可审查的 Extreme 质量、资源或延迟汇总报告。

权重 dtype 表示数值存储精度，不能单独证明 ASR 识别质量、TTS 音质、分人质量、运行速度或内存需求。候选目录存在也不等于模型运行态已验收。

## 决策

1. 增加 profile key `extreme`，用户可见名为「极致」。`quality` 与已有三档制品组成不变。
2. Extreme 使用锁定的 `asr-1.7b-bf16`、`tts-1.7b-design-bf16`、`tts-1.7b-base-bf16`，并复用 `aligner-bf16` 与现有 VAD / CoreML 分人路径。模型来源和逐文件清单见 [Extreme 设计规格](../superpowers/specs/2026-09-23-extreme-tier-bf16-design.md)。
3. `recommend_profile()` 最高仍推荐 `quality`；只有操作者显式选择时才会选择 `extreme`。App 只允许从服务实际发布的 profile catalog 生成可执行选项。
4. REST 与 Realtime 端点、payload 结构、worker 协议和调度边界不变；`/health.profile` 与 `/v1/models` canonical profile 枚举增加 `extreme`。严格校验旧枚举的消费者可能需要更新。App 必须保留未知 profile 解码兜底；未知值不能编码成 apply/prepare 控制命令。
5. VoiceDesign 与 Base clone 按当前 artifact variant、有效能力与 readiness 决定，不把 `quality` profile 名当作唯一授权条件。目录当前为 `quality` 与候选 `extreme` 配置这两项能力；响应仍须如实报告当前是否 ready。
6. MCP 永远不切换档位，不提供 profile apply/setup/prepare 或同义工具，不经 REST/CLI 隐式改变档位，也不建议 Agent 自动换档。`describe()` 只报告当前活动 profile 与有效能力；缺失或观测互相矛盾时返回 `unknown` / inconsistent，并抑制正向可用性判断。
7. `SPEECHRAIL_*_RESIDENT_BYTES` 继续由操作者在仓库外的私有配置中维护，不在 catalog 放置 resident 推算值。目标档没有实测声明依据时保持 fail-closed；不能把 `quality` 数值套用为 `extreme` 实测。
8. Extreme 在 R2/R3 证据门通过前保留为候选源码状态，不进入正式 release catalog，不切换受管服务，不使用“质量最高”等等级性宣传。

## 后果与风险

- OpenAPI profile 枚举发生 additive contract change。端点和响应 payload 形状不变，但使用闭合 enum 的老客户端可能拒绝新值。
- 已安装的旧 App 不会获得新版本源码里的未知值解码能力。正式服务启用前，须先发布并安装可容忍未知 profile 的 App，或通过单独证据证明组合发布时的版本窗口安全。
- BF16 权重目录比既有 q8 组合占用更多磁盘字节；目录大小不是本次网络下载量、resident、峰值内存、冷载时间或推荐硬件门槛。
- Extreme 有独立 ASR、VoiceDesign 和 Base 制品身份；不能用 Quality 的质量、内存或延迟数据代替。
- MCP 的只读 profile 边界使 Agent 必须接受当前服务能力缺失的结果；档位变更只能由 MCP 外部的操作者显式完成。

## 验收与启用门

候选代码门覆盖目录与 dtype 校验、供给和 selection、REST 能力、MCP 当前能力硬门、App 前向解码、OpenAPI 与 active 文档，并通过受影响的静态测试与构建。此门只证明代码可评审。

| 门 | 要求 | 当前状态 |
|---|---|---|
| R0 前向兼容 | 新 App 解码旧服务、四档服务和未知 profile；未知 profile 不能触发控制请求；正式启用前处理已安装 App 的发布窗口 | 候选源码静态验收；未安装/发布 |
| R1 候选代码 | G0–G8 通过，目录、契约与能力映射一致 | 由候选实施账本记录 |
| R2 质量 | 同口径公开真人 ASR CER/WER 劣化绝对差值 ≤0.5pp；质量等级宣传还须 TTS 对比证据 | **BLOCKED：没有报告；本轮不复测** |
| R3 资源与延迟 | 版本和制品身份可追溯的 `phys_footprint`、冷载、首包、RTF 与目标机器 resident 声明证据 | **UNVERIFIED：没有报告；本轮不复测** |
| R4 正式启用 | R0–R3 可审查通过，并另行获准执行受管切档与公共 API smoke | **BLOCKED：本轮不切档、不安装、不发布** |

## 替代关系

本决策只取代 [ADR-0015](0015-tier-user-positioning-and-precision-policy.md) 对 profile 数量及当前精度策略的三档陈述。ADR-0015 中的历史 E1 证据、旧档位定位和既有组合结论仍按其原始范围解释，不因本 ADR 重写。
