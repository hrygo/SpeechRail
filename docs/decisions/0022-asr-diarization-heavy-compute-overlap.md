---
title: "ADR-0022：ASR、TTS 与分人的受预算约束计算预留"
status: accepted
date: 2026-10-18
---

# ADR-0022：ASR、TTS 与分人的受预算约束计算预留

## 决策

在 ADR-0016 的资源准入基础上，分人使用独立的 `WorkClass.DIARIZATION`，不借用 ASR lane。同一分人计算 lane 串行；不同能力只能在启用组件的完整 footprint 和硬件预算允许时重叠。`true` 可作为运维实验强制开关，但不能证明内存上界、质量或延迟已验收。

计算预留与模型所有权分别管理。每个组合根的 governor 持有唯一 `DiarizationSessionOwner`，旧四槽与会议路径共享。会话在调用 worker factory 前同步认领 generation，chunk 间隙继续持有，确认精确 child 回收后释放；迟到 generation 不能释放后来会话。`WorkerLeaseLock` 的防驱逐引用计数不能替代此独占门。

模型 load/preflight、infer 和 finish 在分人计算预留下执行。OS 子进程创建受保护，取消时先等精确 child 完成登记；已创建 child 的 preflight 可以中断，再完成 close，最后释放 owner，避免 preflight 卡住导致无法回收。close 由一个 `DiarizationWorkerLease` 入口合并；重复 finish/cancel 不重复加载或回收。消费者跟不上时有界失败，取消唤醒等待消费者，不增长无限更新队列。

回收失败后，分人保持 owner、child 引用及 `retained_diarization` 占用。实际任务预留可以退出，但不把失联资源当作已释放；它不无限占住通用请求队列。独立 lane 只有在以下条件全部成立时继续：

1. 重叠策略已允许；
2. 所有启用组件都有可信驻留峰值，失联 child 仍在该声明上界内；
3. 完整 footprint（含 workspace、共享依赖和余量）在预算内。

否则全部计算轴 fail-closed。ASR/TTS/分人各有独立 quarantine；允许重叠且上界可信时，某一轴的清理失败不自动隔离其他轴。隔离会唤醒排队者并返回稳定错误，恢复按 managed 服务流程执行。强制 `true` 不能绕过故障资源上界检查。

同类队列保持同一模型 lane 的 FIFO。前项仅因自身模型 lane 被占用或隔离、且当前工作是允许独立运行的其他 lane 时，可以越过；不得绕过总容量、realtime 预留或任意重排。aging 对可越过阻塞前项的 batch 也生效。`lane_available` 使用同一计算准入规则。

streaming/dynamic 两条路径互斥驻留，因此 footprint 可以取两个已声明峰值的 max。任何启用路径未声明时仍为未知，不能用另一条路径的非零数值掩盖。若未来允许共驻留，必须改为求和。缺声明可能同时触发单任务预算拒绝，不承诺总能串行运行。

## 接线影响

文件转录保持先 ASR、再根据冻结正文做分人。持久任务的具体 local processor 在 ASR 阶段预留 `BATCH_ASR`，完成后释放，再进入独立分人阶段；runner 对整个流程保持一个绝对 deadline，不再在该具体 processor 外包一层 ASR 预留。其他注入的 processor 继续由 runner 管理，speech 任务的 TTS 预留不变。

公共 busy/隔离错误沿用已有 envelope 和 request ID；分人失败不赋予重写正文的权限。能力诊断将持久隔离反映为 not-ready，但瞬时忙仍按各接口的正常排队/拒绝规则处理。

## 证据与限制

2026-10-17 原 OpenCode 工作报告的 sleep 固定负载 ABBA 只作调度机制证据，开发 sidecar 的数字相同也不证明真实 ASR 与被修改分人路径共存时质量不变。新代码以确定性 fake 回归验证独占、预留、队列、取消和失败隔离；实际双模型 ABBA、phys_footprint、长稳、安装与版本回滚仍未验收，不能据此开启生产并发。

关联：[实施记录](../implementation/2026-10-18-meeting-diarization-handoff-audit.md)、[评分与身份 ADR-0023](0023-meeting-evaluation-identities-and-product-gates.md)、[操作边界](../operations/heavy-compute-overlap-configuration.md)。不改变 ADR-0012 的默认模型或认证人数。

## 回退

代码按本 PR 的资源治理逻辑提交反向恢复。运行配置与 managed release 的回退须单独按运维流程执行；本次没有改服务、模型或私有配置。禁止清空声明后假定仍可运行；串行和单任务预算须分别核实。
