---
title: "应用收尾的消费、保存与封存证明"
status: active
audience: "App 核心开发者"
version: "0.1.2"
date: 2026-10-07
---

# 应用收尾的消费、保存与封存证明

本合同对应 #231 / #238 R08。它约束 Assistant、Meeting、Caption 的应用层正常结束，
不改变 RealtimeASRClient 的 commit / receipt / clear、识别归约或公开 wire。
R08 PR #331 已合入 main（`cb77d296`）；一次整包独立审查的 Required 已补反例修复，
293 项联合 XCTest、App 构建与最终 head `70d40a46` 的必要 CI `37581248688` 均通过。

## 正常结束的证明链

1. 冻结 record、连接身份、uploader 与唯一 receiver；同一次 stop 重入共享任务。
2. 本地采集停产并释放设备，已缓冲尾块由原 uploader 排空。上传失败不能被成功 drain 覆盖。
3. 原连接完成协议 drain，再关闭 transport；协议 receipt 只证明服务端水位。
4. 等待原 FIFO receiver 实际结束，先前缓冲的 final / attribution 已经过应用 owner。
5. 唯一保存 owner 返回 complete，包括 queued / in-flight 正文、metadata 与 admission 拒绝账本。
6. Coordinator 确认同一条记录归档；会议还须确认来源封存，之后才自动生成纪要。

空队列快照、任务取消、close 返回、receipt 到达与本地设备释放均不能单独代替上述证明。
正常 drain 保留原连接合法输入的接纳权，同时立即撤销新回复和 TTS 发布权。
abort / reconnect 则撤销旧代次；晚到 final、metadata、上传异常不能修改新记录或新连接状态。
Meeting 暂停继续沿用 flush，不因结束链更改暂停语义；Caption 暂停保留原有 drain / close。

## 一个绝对截止时间

`SessionDrainDeadline` 使用 `ContinuousClock` 的同一个绝对截止时间覆盖正常 stop 的
capture / effects / upload / protocolDrain / transportClose / receiver / persistence 与 seal。
feature 默认预算 12 秒，协议本身仍使用既有 8 秒限制；阶段切换不重新计时。
归档、来源确认和成功发布共用剩余预算。

非合作 IO 不放进退出时必须等待子任务的 task group。
操作与计时器只恢复一次 continuation；操作返回时再次核对绝对截止时间，
即使同步回调占住 MainActor、计时器尚未获得执行机会，也不接纳晚到成功。
超时取消操作，但一直保留句柄到实际返回。
清理可在截止时间后启动，调用方不继续等待。Meeting 在旧 capture 尚未实际释放时拒绝重用来源。
receiver 内部发起 abort 时保留其回收句柄，不等待自己的 EOF。
迟到的归档提交可以成为存储事实，不能迟到发布 `lastFinalizedSessionID` 或完整纪要；
原封存命令和真实任务保留，等实际结束后才可用新预算重试。

自动标题是装饰性任务：取消并保留其完成句柄，不能占用正文封存预算。
必须保存的正文和已接纳 metadata 仍由各自 owner 确认。助手已接受的音色变更冻结
record / request / ordinal / voice 与名称，所有调用者复用同一写入任务；
失败保留命令，超时保留真实任务。正常 stop 在 EOF 后联合确认正文与音色 metadata，
重试在新预算内等待原任务或重试失败命令，再将同一剩余预算交给封存。

## 失败与恢复

| 失败 | 结果与恢复 |
| --- | --- |
| 上传、协议、异常断连、stream error、receiver 超时 | 按 record 留下不可被空队列覆盖的 incomplete 证明；正常 `.user` 封存拒绝。保留已接纳文字与恢复/复制入口；会议另有显式中断归档出口 |
| 保存失败 / 保存超时 | 保留冻结命令和行 ID；EOF 证明没有丢失时，显式重试可使用新预算恢复正常归档 |
| 归档或来源确认失败 / 超时 | 保留原命令、阶段和首次结束时间 / 原因；实际 task 结束后重试，迟到确认不发布成功 |
| 分人 drain timeout | 保留既有 degraded 状态与说明，同时阻止正常完整结束 |

保存故障与不可恢复的捕获证明分开：重试保存不能制造已经丢失的 receiver EOF。
会议 processing 中保留失败说明、导出已保存文字与重试结束入口；捕获证明丢失时，用户可明确按中断归档，
此动作不自动生成完整纪要；其保存、归档和来源确认共用一次新的绝对预算。
助手保留 pending seal 与原文复制出口。字幕保留已保存文字的复制/导出和保存重试，
本合同不新增通用捕获失败的中断归档按钮；容量拒绝仍使用保存合同已有的明确确认流程。
上述 incomplete 证明在进程内按 record 保存，不承诺跨重启恢复；没有新增 SQLite schema 或持久化格式。

## 验证范围

采用 fake realtime / audio 与临时 SQLite，真实驱动生产 feature、保存 owner 和 Coordinator。
包括 receipt 已到而 receiver Gate 未开、EOF 已到而 Store Gate 未开、非合作协议 / receiver timeout、
正常 tail + attribution、协议 / 上传 / 缓冲 stream failure、快速 stop/start 同 itemID 隔离、保存重试、
真实归档确认超时与迟到成功禁止、会议来源失败、重复 final / 空输入 / 暂停。
具体红绿结果、审查与最终 head CI 以 loop r2 的 R08 账本为准。

没有运行真实模型 / 音频、UI 自动化、钥匙串、服务操作、安装或发布。
App Debug build 只证明编译与包装脚本检查，不能证明屏幕观感、VoiceOver 或真实音频质量。

关联：[保存 owner 合同](transcript-persistence-contract.md)、[归档确认合同](session-seal-contract.md)、
[loop r2 账本](../implementation/2026-10-07-issue-238-solid-loop-plan-r2.md)。
