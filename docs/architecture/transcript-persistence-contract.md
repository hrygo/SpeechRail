---
title: "转录保存命令、原子确认与恢复合同"
status: under_review
audience: "macOS App 开发者、会话数据层维护者"
version: "0.1.1"
date: 2026-10-07
---

# 转录保存命令、原子确认与恢复合同

本文件跟踪 [#232](https://github.com/hrygo/SpeechRail/issues/232) 的 R07 实施。
当前为合同草稿：Store 原子确认、共享命令队列和 Meeting/Caption 接线已有定向测试证据，
整包独立审查、归属 I/O 的完整 receiver 解耦及用户操作入口尚未完成。
不得依据本文或子任务通过记录宣布 #232 已验收。

## 所有权与边界

ASR 客户端、Preview Ledger 和 Assembler 定义识别事实；保存 owner 消费已经归约的正文，
不反向修改识别终态、revision、segment boundary 或 clear 协议。#245 继续拥有这些识别语义。

助手、会议和字幕复用 `TranscriptPersistenceQueue`，各 feature 持有自己的串行实例，
不依赖整个 `AssistantSession`。源文件暂保留 `AssistantInputPersistenceQueue.swift`：
两个构建系统均已登记该编译单元，保留文件名可以避开在途 pbxproj 修改；旧类型 alias 不保留。

receiver 接纳命令后即可继续消费控制事件，保存 owner 才等待 Store I/O。
接纳不表示已保存；读到同 ID 的正文也不单独证明 outbox 和 ordinal 确认成功。

队列已有辅助写入调度端口 `enqueueProjection`，复用唯一 worker。
辅助任务最多 128 项、合计 1,024 units，活动任务也占预算；
只合并尚未执行的相同 record/line 更新，超预算不替换已有工作。
正文与辅助任务轮换执行，避免辅助更新挤占已接纳正文；
queued/in-flight 辅助任务会阻止对应 record 提前返回 settled。
Meeting/Caption 尚未接入该端口，不能把队列端口已通过测试写成 receiver 已全面解耦。

## 冻结命令

接纳时冻结以下字段，失败重试使用同一份命令和同一 `lineID`：

| 分类 | 字段及含义 |
| --- | --- |
| 身份 | session/record ID、connection、itemID、generation、acceptanceID、lineID |
| 正文 | text、source、role、speakerLabel |
| 时间 | observedAt、tStart、tEnd、timingQuality |
| 行状态 | formal/partial、isInterrupted、isDeviceSwitch |

`Command.lineDraft` 是公共行字段的唯一投影；不以当前会话或重试时的日期重新构造草稿。
observedAt 是观察时间，不能冒充声学时间。声学区间只能来自已有输入区间或对齐证据，
未知区间继续保留未知值。

非 keyboard 的 item 去重键包含 record、connection、generation、itemID 和 source。
已完成身份最多记忆 512 项；失败和未完成命令不会随已完成身份过期而丢失。
稳定保存身份与上游终态去重分属两个边界：存储重试不要求服务端再次投递 completed。

## Store 原子确认

`SessionStore.appendLine` 以有限 SQLite 事务覆盖：

1. 固定 ID 的字段核对或新增正文；
2. 需要时登记持久化索引待办；
3. ordinal 回读确认；
4. 提交成功才返回确认值，任一步失败回滚。

同 ID 核对 record、正文、role、source、speaker、起止、状态、中断/设备切换和质量。
显式声明 createdAt 时采用 SQLite Double 精度的 1 微秒确认容差；
旧调用未指定 createdAt 时，不要求再次生成的当前时间与旧值相等。
字段冲突明确失败，不覆盖正文、不使用 `INSERT OR IGNORE`、不换 UUID 绕过冲突。

一致的旧行如果缺少索引待办，可以补齐；已经待处理或已经索引的行不重复排队。
业务事务只承诺正文和必要的持久化待办，真正 FTS drain 仍独立。
partial 不进入正式索引；schema v13 不改动，不重建或降级用户数据库。

## 保存失败、容量拒绝与复制

已接纳命令最多 32 项、64,000 Unicode scalars。失败继续占预算，按 record 保留接纳顺序。
显式 retry 重用冻结命令；一个 record 的失败前置项阻塞该 record 后续保存，
不把它改成另一条 partial 正文来冒充恢复。

`DrainReport` 区分待保存命令、失败项及接纳拒绝计数。
只有三者都为空/零时，feature 才拥有“全部已保存”的证明。
`pendingSaveRecordIDs`、`saveFailures`、`retryPendingSaves` 和
`unsavedTranscriptText` 是 UI 接线端口；调用时须冻结要操作的 record ID。

容量拒绝不成为已接纳命令，也不能在队列排空后消失。
`TranscriptAdmissionLedger` 最多记录 32 场，每场只保留最近一次拒绝的复制预览，
预览最多 64,000 Unicode scalars。多次拒绝或截断明确写入复制说明，不伪装成完整恢复文本。
账本满时拒绝继续新建记录；不能通过移除旧证明来恢复“全部保存”状态。
已接纳但失败的正文仍完整保存在队列中，不受拒绝预览截断策略影响。

当前拒绝证明没有用户确认后的解除流程；复制不会自动清除它，
也不使 `retryPendingSaves` 对该记录返回成功。相应 UI/恢复策略仍属于 R07 未完成项。

## partial 恢复材料与归属

空 final 或 failed item 的已有 preview 以稳定身份保存为 partial。
它可通过 `includePartial: true` 取回，但不进入正式纪要、默认分享、正式来源快照或正式索引。

保存前到达的 attribution 按 record + connection + generation + itemID 有界缓存：
最多 128 项、合计 1,024 units；超预算保留旧缓存并显式报告辅助信息不完整。
辅助归属只回填原行，不能改 canonical transcript。
旧 record 的迟到保存使用冻结目标处理，不能把文字或 speaker 状态投影到新 record。

当前保存后 attribution 分支仍等待 metadata I/O；必须继续移入可等待的串行 owner，
并验证跨 generation 的异步 metadata 完成不会改写新会话的标签账本。
不能仅凭“正文保存已解耦”宣称 receiver 的所有存储等待都已移出。

## 关闭与封存

feature 关闭时等待事件消费任务以及已接纳命令真正 settled；
保存失败或接纳拒绝会撤销对应目标的保存证明，阻止 Coordinator 自动归档。
失败记录的 retry/copy 目标不随 `sessionID` 清空或开启新场而消失。

R07 的 settled 证明只覆盖已接纳/明确拒绝的保存结果；
完整消费 EOF、超时、stream failure 和封存结果的联合屏障由 R08 / #231 补齐。
最终封存仍服从[会话归档确认合同](session-seal-contract.md)，不能用释放租约或单次网络 drain
代替完整结束证明。

## 当前证据与未完成门槛

2026-10-07 的定向验证包含 Store/outbox 失败、ordinal 确认失败、同 ID 冲突、
Meeting/Caption 的固定命令重试、partial、控制事件、容量拒绝及跨记录归属，
并通过真实 `RealtimeASRClient` + fake transport 验证：
第二个 completed 出现前可重试保存，重复终态不覆盖权威行。
这些测试不使用设备、网络服务、真实音频或模型。

剩余门槛：

- 归属 I/O 由同一有界串行 owner 接管，并冻结 metadata 的投影目标；
- Meeting/Caption 页面和字幕浮层接入旧 record 的重试/复制及拒绝提示；
- 明确拒绝证明的用户恢复/结束路径；
- 整包独立审查、Required 红→绿修复、必要 CI 与 PR 合并；
- 与 R08 的完整 EOF/封存屏障联合验收。

实测命令、精确计数、提交和审查结论记录于
[R07 loop 账本](../implementation/2026-10-07-issue-238-solid-loop-plan-r2.md)。
