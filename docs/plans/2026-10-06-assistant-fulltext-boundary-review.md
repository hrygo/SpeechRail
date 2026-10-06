---
title: "完整文本 adapter 四条边界实施评审记录"
status: active
verification_scope: targeted_fake_regression
date: 2026-10-06
---

# 完整文本 adapter 四条边界实施评审（#257 §6.0）

基线：`origin/main@f7e9d4b9`。本记录只做四条边界的实施评审留档，
不启用 `usesFullTextSpeechForTest` 门闩，不关闭 #257 / #268；
启用以 #268 真机分组听审通过为前提。

## 边界 1：固定 revision + interactive purpose + integrity receipt（#264 已合入）

- 实现：`ServiceContractTypes.assistantInteractiveSpeechOptions`
  （`macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift:2428`），
  在 `creatorRequestOptions` revision pin 基础上叠加
  `withInteractivePurpose` + `withReceiptModeIntegrity`，不设 latency budget；
  pin 取服务端按 voice mode 比对的那份制品 revision，取不到则返回 nil 调用方 fail-closed。
- 回归：`ServiceContractTests/testInteractivePurposeDerivationKeepsEveryOtherOption`
  （派生不丢字段）。
- 评审结论：通过。未沿用 batch 默认准入，未附加迫使答案缩短的预算。

## 边界 2：有界接收与解码校验（#269 已合入）

- 实现：`FullTextSpeechBounds`（`SpeechRailControlKit/FullTextSpeechBounds.swift`），
  硬字节上限 4 MiB、绝对 deadline 60s、最小非空音频、content-type 魔数探针；
  超限/超时/坏格式一律显式失败，不播出、不截尾；现有
  `synthesize/postAudio/decodeAudio` 签名零改动。
- 回归：`ServiceContractTests` 边界 2 MARK 下 6 项
 （空/超限/超时/非音频/坏 wav/合法 wav 与未知子类型通过）。
- 评审结论：通过。`postAudio` 返回完整响应不等于可用，屏障在提交 player 之前。

## 边界 3：receipt 核对与 unknown 语义（#270 已合入）

- 实现：`FullTextReceiptCheck`（`SpeechRailControlKit/FullTextReceiptCheck.swift`），
  `completed + revision 对上 + 有样本 + sample_count*2 == receivedBytes + 有 pcm_sha256`
  才 `deliverable`；pending/cancelled/error/未知状态、revision 不一致、
  零样本、样本数不一致、无摘要一律 `unknown`，调用方不得播出、不得开新合成，
  转显式重试。与 Python #243 语义对齐（cancelled 不证明资源释放）。
- 回归：`ServiceContractTests` 边界 3 MARK 下 6 项
  （通过/pending/cancelled/revision 不一致/样本证据不一致）。
- 评审结论：通过。2xx、EOF、Task 退出、cancelled 回执均不证明资源空闲。

## 边界 4：取消/设备/结束屏障（#271 已合入）

- 实现：`FullTextPlaybackGate`（`SpeechRailControlKit/FullTextPlaybackGate.swift`），
  `commit(samples:)` 登记、`notePlayed(samples:chunkID:)` 去重记账
  （重复/超量/旧 epoch 拒绝）、`invalidate()` 后一切回调作废且拒绝新提交、
  `completion()` 只有 played 覆盖全部提交样本才 completed 其余一律 incomplete。
- 回归：`ServiceContractTests` 边界 4 MARK 下 4 项
  （完成门/失效停新合成/旧回调拒绝/旧 gate 不复用）。
- 评审结论：通过。取消先撤 epoch、停播再清理；played 唯一记账。

## 门禁状态

- `AssistantSession.usesFullTextSpeechForTest == false`
  （`AssistantSession.swift:604`）；门禁测试
  `AssistantCancelReceiveTests/testFullTextAdapterStaysDisabledUntilReviewed`
  断言关闭且增量路径照常工作。
- V16 fake 前置门通过（#272：增量累计文本与确认计划文本分区无关等价）；
  真机延迟对照完成（#268 留言：REST RTF 0.24–0.26x vs 增量 0.23–0.24x，同级）。

## 未决事项（不关闭 #257 / #268）

- [x] #268 真机分组听审：关键实体零漏读/零错读 + 人工听审通过（2026-10-07，
  用户亲耳双听正常版 A/B 通过，结论见 #268 评论与 M4 矩阵 §真机记录）
- [ ] #268 V17 有界积压保序对照；取消后旧积压不进正式回答
- [ ] 启用提交（门闩置 true + 同步更新门禁测试）以听审通过为前提，另开小 PR

## 范围与回退

本文档为纯文档交付，不改产品代码、协议、schema 或运行态。
回退：撤销本文档提交即可。
