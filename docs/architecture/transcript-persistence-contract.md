---
title: "转录保存命令、原子确认与恢复合同"
status: active
audience: "macOS App 开发者、会话数据层维护者"
version: "0.1.7"
date: 2026-10-07
---

# 转录保存命令、原子确认与恢复合同

本文件跟踪 [#232](https://github.com/hrygo/SpeechRail/issues/232) 的 R07 实施。
R07 PR #330 已合入 main（`c997f7b0`）：Store 原子确认、共享命令队列和 Meeting/Caption 接线已有定向测试证据，
保存后 attribution 的 I/O 已接共享 owner，用户操作入口已接线；
整包独立审查已完成，Required 缓存释放修复及验收补充已有定向实测；
修订 head `776bce9f` 的必要 CI `37573261584` 全部通过。
R08 PR #331 已合入 `cb77d296`，293 项联合 XCTest 与最终 head 必要 CI 通过，完整消费/封存联合门已完成；证据性质与关闭依据见[最终矩阵](../implementation/2026-10-07-issue-238-final-acceptance.md)。

## 所有权与边界

ASR 客户端、Preview Ledger 和 Assembler 定义识别事实；保存 owner 消费已经归约的正文，
不反向修改识别终态、revision、segment boundary 或 clear 协议。#245 的识别重构已由用户确认实施完成；本包仍聚焦保存与收尾，不修改识别语义。

助手、会议和字幕复用 `TranscriptPersistenceQueue`，各 feature 持有自己的串行实例，
不依赖整个 `AssistantSession`。源文件暂保留 `AssistantInputPersistenceQueue.swift`：
两个构建系统均已登记该编译单元，保留文件名延续当前构建登记，不再以 #245 避让为限制；旧类型 alias 不保留。

receiver 接纳命令后即可继续消费控制事件，保存 owner 才等待 Store I/O。
接纳不表示已保存；读到同 ID 的正文也不单独证明 outbox 和 ordinal 确认成功。

队列已有辅助写入调度端口 `enqueueProjection`，复用唯一 worker。
辅助任务最多 128 项、合计 1,024 units，活动任务也占预算；
只有调用方声明可替换的工作才合并尚未执行的相同 record/line 更新；
attribution 是按 unit 修订，Meeting/Caption 禁用整行替换，逐批保留已接纳更新。
超预算不替换已有工作。
正文与辅助任务轮换执行，避免辅助更新挤占已接纳正文；
queued/in-flight 辅助任务会阻止对应 record 提前返回 settled。
Meeting/Caption 已接入该端口：保存前缓存回放和保存后 attribution 使用同一路径，
receiver 不等待其归属或时间写入。超预算明确提示辅助信息未保存，正文保持可用；
这个结论只覆盖 attribution 写入，不扩大为所有事件处理都没有 Store I/O。

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

会议页、字幕页与字幕浮层复用同一恢复组件，以 record ID 冻结 retry/copy 目标，
多记录按观察日期选择。只有失败或明确未接纳的记录显示恢复动作，不将正常保存中当作失败。
复制不会清除拒绝证明，也不使 `retryPendingSaves` 对该记录返回成功。

用户可以明确确认按不完整记录结束。`TranscriptAdmissionRecovery` 冻结拒绝版本、日期、
固定恢复行 ID 与包含完整性说明的有界预览。每次新增拒绝都会换版本，旧确认无法清新证明。
结束流程先等已接纳工作 settled；任何正文保存失败都会阻止继续。随后以同 ID 保存 partial
恢复说明，按 `.interrupted` 封存并读回确认状态/结束原因，最后才移除精确匹配的拒绝证明。
任一步失败继续保留原快照；并发同 record 的结束请求不重复执行。
全部确认成功后释放该 record 剩余的未匹配 attribution 缓存，其他 record 的缓存保留；
拒绝 item 没有权威保存命令，不能让其辅助缓存永久占用后续记录的预算。
此流程不生成纪要，不把丢失内容说成完整定稿；旧 record 恢复不能停止或清空新场。
恢复内容在会议和字幕的回看区单独可读/可复制，正式读取与默认分享仍排除 partial。

## partial 恢复材料与归属

空 final 或 failed item 的已有 preview 以稳定身份保存为 partial。
它可通过 `includePartial: true` 取回，但不进入正式纪要、默认分享、正式来源快照或正式索引。

保存前到达的 attribution 按 record + connection + generation + itemID 有界缓存：
最多 128 项、合计 1,024 units；超预算保留旧缓存并显式报告辅助信息不完整。
辅助归属只回填原行，不能改 canonical transcript。
旧 record 的迟到保存使用冻结目标处理，不能把文字或 speaker 状态投影到新 record。

归属命令在接纳时冻结整批 unit、lineID、目标 label 和标签账本生命周期，
时间写入也冻结原行及区间。保存 owner 执行时不重新读取新场 unit→line 映射。
开始新场、加载历史和结束账本都使旧界面投影失效；旧命令仍写自己的固定行。
同一 unit 重绑另一行时不沿用旧行的保存证明。只有已确认的同生命周期写入
才更新当前 chip；nil 修订仍能清除此前标签，不把接纳时尚未保存解释为无标签可清除。

## 关闭与封存

feature 关闭时等待事件消费任务以及已接纳命令真正 settled；
保存失败或接纳拒绝会撤销对应目标的保存证明，阻止 Coordinator 自动归档。
失败记录的 retry/copy 目标不随 `sessionID` 清空或开启新场而消失。

R07 的 settled 证明只覆盖已接纳/明确拒绝的保存结果；
完整消费 EOF、超时、stream failure 和封存结果的联合屏障由已合入的 R08 / #231 补齐。
最终封存仍服从[会话归档确认合同](session-seal-contract.md)，不能用释放租约或单次网络 drain
代替完整结束证明。

## 当前证据与验证边界

2026-10-07 的定向验证包含 Store/outbox 失败、ordinal 确认失败、同 ID 冲突、
Meeting/Caption 的固定命令重试、partial、控制事件、容量拒绝及跨记录归属，
并通过真实 `RealtimeASRClient` + fake transport 验证：
第二个 completed 出现前可重试保存，重复终态不覆盖权威行。
228 项定向测试还覆盖 metadata 容量拒绝、挂起写入时控制响应及 settled 等待，
跨记录/同记录新生命周期的冻结批次、历史加载、重绑与 nil 修订。
拒绝恢复测试覆盖快照版本、保留预览并按中断结束、已接纳失败项不能跳过、
旧场不影响新场、预览写入失败后同 ID 重试、归档与来源快照失败、
并发结束只保存一份，以及拒绝后归属缓存的跨记录预算回收。
App Debug 构建通过；
UI 视觉、键盘实际操作和 VoiceOver 尚未实测，不把编译通过视为这些验收通过。
这些测试不使用设备、网络服务、真实音频或模型。

R08 的完整 EOF/封存联合门已通过：唯一 receiver、正文与 metadata settled、归档/来源确认均有 Gate 和失败反例；不将此结果扩展为真实设备或 UI 验收。

实测命令、精确计数、提交和审查结论记录于
[R07 loop 账本](../implementation/2026-10-07-issue-238-solid-loop-plan-r2.md)。

R08 的联合消费与封存门见[应用收尾合同](session-drain-completion-contract.md)，已合入 main 并通过确定性联合验收；真实声学、UI 与长稳仍无本次实测证据。
