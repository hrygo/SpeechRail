# 有声书数据库迁移修复实施计划

**Goal:** 保留作品与资产，修复已标记为 schema 5 但缺少字段的作品库，并在运行时与 CI 阻止版本和结构再次脱节。

**Architecture:** schema 6 以备份和事务修复已知的 schema 5 变体；完成结构验证后才推进版本。运行时从建库 SQL 生成独立内存参照，检查实际表、列、约束及索引；CI 使用冻结的 schema 合同和 Git 基线约束后续结构演进。

**Tech Stack:** Swift 6、SQLite backup API、XCTest、Python sqlite3、现有 Quality Gates。

**Spec:** 本次用户缺陷报告与修复要求；`docs/developers/macos-app-audiobook.md` 的持久化与迁移契约。

## 约束与评审重点

- 不删除或重建用户作品库，不读取书籍正文，不更改服务、模型或界面。
- 新建库、历史升级库、已含部分新列的 schema 5 均须达到同一结构契约；物理列顺序不是差异。
- 迁移先一致性备份；失败回滚当前迁移的 DDL 和版本，保留原数据，允许修正原因后重试。
- 当前版本结构异常及无版本的非空库须明确拒绝，不通过 `CREATE IF NOT EXISTS` 或改版本号掩盖。
- 未知更高版本在写入前拒绝；回退 App 不得覆盖升级后的作品库。
- 验证使用合成临时库；用户已明确授权本机构建并替换 `~/Applications/SpeechRail.app`，保留旧版 ZIP 备份。安装后不自动启动，新 App 下次打开作品库时执行迁移。

## Task 1：复现与 schema 6 迁移

**Files:** `AudiobookProjectStore.swift`、`AudiobookStoreSchema.swift`、`AudiobookStoreTests.swift`、冻结的历史 SQL fixture。

- [x] 冻结缺少两列的历史 schema，复现版本 5 无法导入。
- [x] 在旧代码上运行定向用例，确认失败源为缺列。
- [x] 增加 schema 6 迁移：事务内补齐已知列，验证后推进版本，失败整步回滚。
- [x] 新建库事务创建与验收；已是当前版本的库只验证，不静默补建表。
- [x] 验证历史书籍和资产身份、再次导入、重复打开、部分迁移、失败回滚与未来版本拒绝。

## Task 2：结构合同与版本纪律

**Files:** `scripts/check_audiobook_schema.py`、`contracts/audiobook-schema/v6.sql`、对应 Python 测试、`scripts/ci_quality_gate.sh`。

- [x] 先证明同版本结构改动、篡改历史快照和缺少新快照不能通过。
- [x] 比对当前建库 SQL 与冻结结构快照，按 Git 基线要求结构变更递增版本。
- [x] 将检查接入既有 Quality Gates，所有相关路径继续运行 Swift 迁移回归。

## Task 3：验证与交付

**Files:** `docs/developers/macos-app-audiobook.md`、`docs/developers/testing-acceptance.md`。

- [x] 运行有声书存储、发音绑定、导入及工作流相关 Swift 定向测试。
- [x] 运行 schema 合同与质量门相关 Python 测试、合同检查、测试清单与 diff 检查。
- [x] 核对修复不会直接更改真实库；说明安装迁移入口、schema 6 的回退限制与未执行项。
- [x] 构建本地 Release App 4.0.1 (61)，归档 build 60 并替换安装，完成静态与唯一登记检查。

## 验证记录（2026-10-20）

- 旧实现上冻结 v5 缺列回归失败，错误与用户报告相同；修复后成功。反转迁移条件的 mutation 同样被该测试捕获，恢复后存储与发音相关 46 项测试通过。
- `swift test --package-path macos/SpeechRailApp --filter 'Audiobook.*Tests'`：XCTest 329 项（4 项按既有条件跳过）与 Swift Testing 2 项通过。
- schema 合同、质量门、测试清单、变更面分类及 workflow 相关 Python 定向测试 75 项通过；相关 Ruff、实际 schema 合同、测试清单与 diff 检查通过。
- 独立只读审查未发现阻塞问题。本机作品库的只读结构与冻结 v5 fixture 一致；未执行真实库迁移、UI 自动化或真实语音推理。
- 本地 arm64 Release 4.0.1 (61) 已替换正式安装，签名、内嵌 XPC、候选内容一致性与 LaunchServices 唯一登记通过；未启动，待用户验收。旧 App ZIP、迁移前数据库一致性备份与安装收据保存在仓库外。
- 新 App 下次打开作品库时先备份再迁移到 v6；旧 App 拒绝打开 v6 库。需要数据回退时必须人工核对升级后新增内容，不得直接以旧备份覆盖作品库。
- 修复分支为 `codex/audiobook-schema-migrations`；后续 Git 交付按用户授权提交、创建 PR 并经 CI 合并到 main，不创建新发布。
