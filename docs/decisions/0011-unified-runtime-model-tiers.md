# ADR-0011：统一语音运行时与仅权重分档

## Status

Accepted（用户已采纳目标设计；尚未实施，真实硬件门尚未通过）

## Date

2026-09-05

## Context

SpeechRail 面向本机单人语音服务。用户已明确 Batch ASR 与 Streaming ASR 不同时工作，
因此为这两种模式分别常驻模型没有对应业务收益。目标需同时覆盖本机质量优先优化及
M1 Air 8GB 的 ASR/TTS 通用服务，且不同用户不应手工修改模型路径、Python 环境或客户端配置。

本次决定保留 ADR-0003 的进程隔离和请求离线原则；仅把独立运维准备改为显式本地设置向导。
本记录不证明当前代码已经共用 ASR worker，也不证明模型在 M1 上已经验收。

## Decision

1. 一套 MLX 执行框架、共同依赖版本、主进程及每种模型一个 worker；ASR Batch/Streaming
   互斥复用同一模型和 IPC owner。会话隔离、取消、超时、背压与错误恢复仍有界。
2. 三档仅选择权重及量化：
   - quality：Qwen3-ASR-1.7B 8-bit + Qwen3-TTS-12Hz-1.7B-VoiceDesign 8-bit。
   - balanced：Qwen3-ASR-1.7B 8-bit + Qwen3-TTS-12Hz-0.6B-CustomVoice 8-bit。
   - light：Qwen3-ASR-0.6B 8-bit + Qwen3-TTS-12Hz-0.6B-CustomVoice 8-bit。
3. 不通过档位改变 VAD、分段、上下文、缓存、并发、调度或温度；按同一硬件探测规则保护资源。
   本机质量路径与现有可选能力保留，不接受以低配达标为理由的无说明降级。
4. VoiceDesign 与 CustomVoice 使用同一 TTS 实现内的能力分派。四公共 voice ID 和 aliases
   保留，切换前明确展示声音与能力变化；不会承诺预置音色等同于原设计音色。
5. 设置向导准备共同 runtime 与缺失模型，显式应用一次；服务请求不下载。切换时 drain、
   关闭旧模型、串行加载新组合、短音频检查通过再提交选择；失败恢复上一成功组合。
6. 使用同用户私有控制通道协调向导与正在运行的服务，不新增公网管理 API、Web 管理站点或daemon。
   配置与事务 sidecar 在仓库外；已有 .env 和未知键原样保留。
7. light 正式支持必须通过 M1 Air 8GB 真机的质量、<=4GiB基础服务物理峰值目标、
   持续生成、60分钟热机以及切换回退门；本机/12GB另外验收。缺证据不能宣布通过。
8. 0.6B CustomVoice 4-bit 是同档候选，仅在质量门通过且资源/速度有收益时替换light默认，
   不新增架构或第四档，不在运行时静默降级。

## Alternatives Considered

- 低配用 SenseVoice/Kokoro/ONNX、高配用 Qwen/MLX：增加档位专用实现，不符合统一架构要求。
- 所有档位固定 VoiceDesign 1.7B：过度收窄可选权重，不利于低资源通用播报。
- 强制最高档 BF16、最低档4-bit：没有足够质量/收益证据，不用量化标签凑档位。
- 每次ASR/TTS交替时卸载另一模型：冷启动和反复预热影响体验，采用有界暖驻留与共同资源保护。
- 切换时同时加载新旧模型实现零停机：8GB峰值不可控，采用可见的短暂不可用窗口。
- 仅编辑 .env 后重启：用户成本高，无法提供完整制品检查、活动请求排空和自动回退。

## Consequences

- 新增权重目录、共同runtime清单、能力绑定、共享ASR owner和本地换模事务，需要fake与实机双重测试。
- 一二档的音色能力不完全相同，向导和目录必须如实说明；不能仅为了不改客户端字段就隐藏变化。
- 8GB与本机质量门独立；本机有价值的优化可先交付，完整三档发布仍等待M1门。
- 仅影响目标架构与未来安装行为；既有部署不会因本ADR被自动下载、升级、启停或修改。

## References

- [已采纳设计](../archive/process/2026-09-05-low-memory-mac-architecture-proposal.md)
- [详细实施计划](../archive/process/2026-09-05-three-tier-implementation-plan.md)
- [ADR-0003：运行时隔离](0003-runtime-isolation.md)
- [现有公共契约](../../contracts/openapi.yaml)
