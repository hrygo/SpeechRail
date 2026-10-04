---
title: "会议知识闭环 M0 交付说明：版本指针、失败语义、恢复、检索、备份"
status: active
version: "1.3"
date: 2026-10-04
branch: "codex/meeting-knowledge-m0"
base: "origin/main @ 607b75a8"
---

# 会议知识闭环 M0 交付说明

## 范围

本分支只动纪要版本链、结束封存上报与知识检索语义，不做 schema 迁移、不改表结构、不碰采集链路。

9 个提交：排队指针原子化、空输出与结构失败记失败、认领代际、恢复认领原任务、
导出固定选定版本、知识检索、私密边界、备份校验、引文校验、删除语义回归。

1.1 追加（MC-27/MC-17/MC-20 收尾）：`MinutesGenerator.recoverPending`
改走 `pendingMinutesRows` 按原 job 认领续跑（`resume`），不再经 `generate`
新建版本；`MeetingSession.finishAndSummarize` 改用 `sealMeeting` 上报结果，
封存失败留在 processing 并给出重试/复制出口，不谎报已归档。

1.2 追加（MC-43/MC-35/MC-36 收尾）：快照输入 = 转录终稿 + 已校验的用户补充。
`verifyEvidenceQuotes` 经协调器透传；生成与恢复续跑两处组装点统一走
`MinutesSupplements.render`，未选中、未逐字命中、空问答不进入 prompt，
补充逐条标注身份，不升级成会议事实。

## 回归证据

- `MeetingMinutesVersioningTests` 15 个用例，对应 MC-17、MC-20、MC-25、MC-26、
 MC-27、MC-29、MC-33、MC-34、MC-35、MC-36、MC-43、MC-44、MC-48、MC-49、MC-52、MC-62。
- 连同 `AssistantPersistenceTests` 共 27 个用例，2026-10-04 实测全部通过。
- 命令：`swift test --package-path macos/SpeechRailApp --skip-update
  --filter 'MeetingMinutesVersioningTests|AssistantPersistenceTests'`。

## 迁移说明

- 无需迁移：没有新增表、列、索引，`schemaVersion` 保持 1。
- 旧库直接可用；新查询（`latestUsableMinutes`、`pendingMinutesRows`、
  `minutesVersion(id:)`、`searchKnowledge`、`verifyBackup`、`verifyEvidenceQuotes`）
  只读现有表。

## 回退说明

- 整支回退：切回 `origin/main` 即可，库文件不受影响（只新增数据行语义，无结构变更）。
- 单个提交回退：各提交互相独立，按提交哈希逐个 revert；`f213301e` 是纯测试提交，
  回退不影响生产代码。
- 回退不删除用户数据：`removeSession` 语义未变，级联行为与原来一致。

## 未验证事项

- 界面走查（版本切换、导出菜单、检索入口、删除确认）未做。
- 真实模型生成、拒答、截断的端到端语义未做。
- 重启恢复的真实演练、真实设备备份恢复未做。
- 中文短词与精确专名检索质量、删除后索引失效的真实链路未做。
- 真实采集、UI 自动化、发布另行授权。
