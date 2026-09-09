# Documentation Organization Implementation Plan

> **For agentic workers:** Execute the tasks in order. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 SpeechRail 的正式文档按架构、用户、开发者和运维读者分层，并把实施计划、设计草案、审查交接和已取代方案集中归档。

**Architecture:** 正式文档放在 `docs/architecture/`、`docs/users/`、`docs/developers/` 和 `docs/operations/`，每个目录提供自己的入口页；`contracts/` 继续作为机器可读/协议事实源，`docs/decisions/` 继续作为 ADR 事实源。过程材料统一放在 `docs/archive/process/`，归档内容保留历史上下文但不作为当前行为承诺。

**Tech Stack:** Markdown、Git、OpenAPI 3.1、WebSocket 契约、`rg` 链接检索。

**Spec:** 用户请求“文档维护，整理面向架构、用户、开发者、运维的正式文档，归档过程文档”。

## Global Constraints

- 保留当前工作树中与 TTS、diarization、契约和运行指南有关的未提交改动，不覆盖或回退它们。
- `contracts/` 和 `docs/decisions/` 的位置与职责不变。
- 正式文档只陈述当前代码、当前契约或明确标注的限制；归档文档不得被文档入口当作当前承诺。
- 示例不得写入凭据、模型权重、音频、完整转写或本机绝对路径。
- 所有移动后的 Markdown 链接必须指向现有文件；完成前运行 `git diff --check`。

---

### Task 1: 建立正式文档分层

**Files:**
- Create: `docs/architecture/README.md`
- Create: `docs/users/README.md`
- Create: `docs/developers/README.md`
- Create: `docs/operations/README.md`
- Move: `docs/00-product-scope.md` → `docs/architecture/product-scope.md`
- Move: `docs/01-architecture.md` → `docs/architecture/architecture.md`
- Move: `docs/09-open-questions.md` → `docs/architecture/current-boundaries.md`
- Move: `docs/02-api-contract.md` → `docs/users/api-contract.md`
- Move: `docs/04-integrations.md` → `docs/users/integrations.md`
- Move: `docs/10-development-guide.md` → `docs/developers/development-guide.md`
- Move: `docs/07-testing-acceptance.md` → `docs/developers/testing-acceptance.md`
- Move: `docs/05-runtime-deployment.md` → `docs/operations/runtime-deployment.md`
- Move: `docs/06-security-observability.md` → `docs/operations/security-observability.md`
- Move: `docs/11-operations-runbook.md` → `docs/operations/operations-runbook.md`
- Move: `docs/08-migration-runbook.md` → `docs/operations/migration-runbook.md`

- [x] 更新四个读者入口页，明确当前状态、适用对象、下一步阅读和 `contracts/`/ADR 事实源。
- [x] 修正所有被移动文档中的相对链接、配置/部署示例链接和跨读者引用。
- [x] 更新根 `README.md`、`AGENTS.md` 和 `CHANGELOG.md` 中指向旧路径的说明。

### Task 2: 归档过程材料

**Files:**
- Create: `docs/archive/README.md`
- Move: `docs/03-sona-absorption.md` → `docs/archive/process/sona-absorption.md`
- Move: `docs/12-senior-engineer-handoff.md` → `docs/archive/process/senior-engineer-handoff.md`
- Move: `docs/superpowers/` → `docs/archive/process/superpowers/`

- [x] 在归档入口区分实施计划、设计规格、审查交接和已取代方案。
- [x] 在归档文件的头部或入口说明其历史性质；不把归档内容作为当前实现证据。
- [x] 把根 README 和文档中心的过程材料链接改为归档入口，保留 ADR 与当前正式文档入口。

### Task 3: 文档一致性与验证

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/README.md`
- Modify: `CHANGELOG.md`

- [x] 使用 `rg` 检查旧文档路径、`docs/superpowers/` 路径和失效相对链接。
- [x] 使用 `git diff --check` 检查空白和格式问题。
- [x] 使用 Markdown 链接解析脚本验证仓库内相对链接的目标存在。
- [x] 复核 `git status --short`，确认本次只新增/移动/修改文档，不改变既有代码与测试改动。
