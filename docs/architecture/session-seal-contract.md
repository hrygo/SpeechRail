---
title: "会话归档确认、所有权与恢复合同"
status: active
audience: "App 核心开发者"
version: "1.1.0"
date: 2026-10-07
---

# 会话归档确认、所有权与恢复合同

`SessionStore.finalizeSession` 是基础归档的唯一确认入口，返回提交后读回的同一条 `archived` 记录。零行 UPDATE、目标不存在或读回不满足归档合同均不能被解释为成功。已归档目标只读回首次结果，不再次 UPDATE，不改首次 `endedAt` / `endReason`。schema 仍为 v13。

`SessionArchiveWriting` 暴露这一条存储确认边界，默认实现为 Store。Coordinator 复用 `SessionSealResult`；没有第二套归档结果类型。确定性测试可在该边界模拟写入失败、提交后确认失败和等待期间的租约变化，不向生产 Store 添加故障开关。

## 成功条件与阶段

| 阶段 | 成功证据 | 失败时保留 |
|---|---|---|
| 结束暂停区间 | 原暂停 ID 的关闭操作成功 | 同一暂停 ID 与失败原因；不越过失败归档 |
| 基础归档 | 同 ID 的 archived 记录，结束时间和原因均存在 | 原 record ID、第一次结束时间/原因；确认失败仍可重试同一命令 |
| 会议来源封存 | 来源封存操作成功 | 已确认归档事实；只重试来源阶段 |

没有定稿会议正文时，不写空快照的既有合同仍有效；来源操作返回 nil 并不表示有快照。Store 基础命令只确认归档，Coordinator 根据读回记录的 kind 组合业务步骤：会议的“封存成功”要求来源操作完成，经通用入口也不能跳过；普通字幕和助手归档不依赖会议知识域。

Coordinator 的 `pendingSeals` 按 record ID 保存当前进程内命令。失败不保留麦克风占用，也不发布 `lastFinalizedSessionID` 或助手 `.ended`。`retryPendingSeal(id:)` 不创记录、不改变原命令、不触及其他会话的设备；会议来源失败只重试来源，确认失败则重复确认已提交记录。

`sealSession`、`sealSessionReporting`、`finalize` 和助手目标结束使用同一内核。助手自身的失败状态与复制出口保留；skipped 表示尚未确认，重试不得清掉恢复目标并返回成功。

助手按记录保存失败原因及冻结的复制文本，界面恢复入口按失败顺序逐条处理。新会话成功只清除自己的恢复目标，新会话失败不能覆盖旧目标；旧目标重试成功后才推进到下一条。新会话的文字不混入旧目标的复制内容。

## await 与租约

`finalize` 在入口冻结 kind、lease ID、record ID、结束时间、暂停 ID 和 stopper。相同租约的重复结束共享任务；相同记录的并发封存共享提交，会议调用加入时不能降低来源成功条件。

stopper 必须先完成保存责任。它若通过 `abandonOccupancy` 撤销所有权，迟到的 finalize 返回 skipped，不归档新目标，也不越过原 owner 的输入保存失败。原 feature owner 继续负责未保存内容的恢复。

归档提交期间出现新租约时，只能确认冻结的旧记录。清理函数同时核对 lease ID 和 record ID；不能清空新会话的 occupancy、active ID、phase、设备或时钟。纯文字目标结束不调用其他会话的 stopper。

设备释放、协议 drain、逐行保存、归档和来源快照各自有独立证据。归档结果不能替代尚未完成的消费/保存屏障；这些连接由 #232/#231 后续包完善。

## 验证与限制

回归使用临时 SQLite、测试自有 trigger、fake archive writer 和受控 Gate，覆盖缺失目标、幂等、UPDATE 失败、提交后确认失败、暂停关闭失败、会议来源失败、重复结束、无记录结束与旧租约迟到。

本合同不增加跨重启 pending 命令的持久化或迁移，不修改 ASR wire、识别/解码策略、Assembler/Ledger，也不证明真实设备、LLM、模型质量、性能或长稳已验收。回退仅 revert 本包代码，不降 schema、不清理用户记录。

## R08 消费与截止时间接线（待最终审查与合并）

正常语音封存还须满足[应用收尾合同](session-drain-completion-contract.md)。Coordinator 按 record 保留捕获 / 消费失败，`.user` 不得凭后来空队列绕过；显式 `.interrupted` 仍允许。正常封存使用 feature 注册的同一个绝对截止时间；归档或来源确认晚于截止时间时保留任务与原命令，禁止迟到发布成功。句柄只在实际 task 完成时清理。没有改变 Store 原子归档合同或 schema。
