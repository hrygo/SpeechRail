---
title: "会议知识闭环 M0 交付说明：版本指针、失败语义、恢复、检索、备份"
status: active
version: "1.0"
date: 2026-10-04
branch: "codex/meeting-knowledge-m0"
base: "origin/main @ 607b75a8"
---

# 会议知识闭环 M0 交付说明

## 范围

本分支只动纪要版本链与知识检索的库层语义，不做 schema 迁移、不改表结构、不碰采集与封存路径。

9 个提交：排队指针原子化、空输出与结构失败记失败、认领代际、恢复认领原任务、
导出固定选定版本、知识检索、私密边界、备份校验、引文校验、删除语义回归。

## 回归证据

- `MeetingMinutesVersioningTests` 12 个用例，对应 MC-25、MC-26、MC-27、MC-29、
  MC-33、MC-34、MC-35、MC-36、MC-44、MC-48、MC-49、MC-52。
- 连同 `AssistantPersistenceTests` 共 24 个用例，2026-10-04 实测全部通过。
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
