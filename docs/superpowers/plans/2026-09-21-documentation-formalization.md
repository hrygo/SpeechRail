# SpeechRail 主要文档正式化计划

> **For agentic workers:** 本计划在当前 worktree 内由主代理按任务顺序执行；步骤使用 checkbox 记录进度。

**Goal:** 完整读取并正式化 SpeechRail 的项目主文档、用户手册、公共契约和配套 skill，使产品边界、Realtime 扩展、MCP 能力、安装运维和版本事实一致。

**Architecture:** 以当前代码、测试和 contracts/ 公共契约为事实源，先建立术语与边界矩阵，再分层改写主 README、用户手册、active architecture/developer/operation 文档、Realtime/OpenAPI/diarization 契约及随包 skill。历史文档不改写成当前承诺；不新增运行时兼容层。

**Tech Stack:** Markdown、YAML、JSON、Python package resources、uv、pytest、ruff、本地链接与 manifest 校验。

**Spec:** AGENTS.md、contracts/openapi.yaml、contracts/realtime-openai.md、docs/README.md 及当前实现/测试。

## Global Constraints

- 当前代码、测试和 contracts/ 优先于历史说明；文档与实测冲突时明确报告并以当前实测为准。
- Realtime 只承担 ASR/TTS 子集及 speechrail.* 扩展；不承担服务端 LLM、conversation、memory、tools、播放或 barge-in。
- MCP 是无状态 REST proxy；不创建 Realtime WebSocket session，不加载模型，不替调用方编排 LLM。
- 公共接口只描述当前支持的字段、事件、错误和资源；不把历史 alias、未实现能力或推测能力写成承诺。
- 不修改运行时代码、用户数据、模型、配置或服务状态；不提交、推送或创建发布物。
- 文档 version/date 仅在正文实质变化时更新；路径、命令和示例不得泄露真实凭据、私有绝对路径或原始用户内容。

## Review Focus

- Realtime snapshot 与 delta 是否被清楚区分，并说明 revision 替换、completed 终态和首个 PCM 后不可修改。
- MCP 是否明确不代理 Realtime、不会创建会话，且 transcribe 与 caller-owned WebSocket 的输入输出语义不混淆。
- describe()、effective capability、voice/model revision、validation policy 是否在主文档、用户手册和 skill 中使用同一术语。
- 安装/升级/回滚/本地服务生命周期是否只描述当前受管流程，避免把历史命令或源码开发路径混作生产路径。
- OpenAPI、Realtime、diarization schema 和 skill manifest 的示例、版本、错误边界是否可被机器校验。

---

### Task 1: 完整读取与事实矩阵

**Files:**
- Read: README.md, README.zh-CN.md, docs/README.md, docs/users/README.md
- Read: docs/users/installing-speechrail.md, docs/users/mcp-agent-integration.md
- Read: docs/architecture/README.md, docs/architecture/openai-conformance-audit.md, docs/architecture/speechrail-mcp-proxy.md
- Read: docs/developers/README.md, docs/developers/testing-acceptance.md, docs/operations/README.md, docs/decisions/README.md
- Read: contracts/openapi.yaml, contracts/realtime-openai.md, contracts/diarization/v1/
- Read: src/speechrail/assets/skills/speechrail/, .agents/skills/speechrail-*/SKILL.md
- Create: docs/superpowers/sdd/2026-09-21-documentation-formalization/facts.md

- [x] 完整读取上述 active 文档、契约和 skill；历史/归档文档只记录引用关系，不把它们作为当前事实源。
- [x] 将服务边界、Realtime 扩展、MCP 工具/资源、安装入口、路径和版本事实整理成可核对矩阵。
- [x] 使用 rg 标出冲突术语、过期版本、旧 endpoint、历史字段和失效链接，形成后续改写清单。

### Task 2: 主文档与用户手册

**Files:**
- Modify: README.md
- Modify: README.zh-CN.md
- Modify: docs/README.md
- Modify: docs/users/README.md
- Modify: docs/users/installing-speechrail.md
- Modify: docs/users/mcp-agent-integration.md

- [x] 统一产品定位、当前能力表、安装入口、Realtime/MCP 边界和安全声明。
- [x] 把面向用户的文案改为确定、规范的当前语态：明确“支持什么/不支持什么/调用方负责什么/失败后如何行动”。
- [x] 仅保留当前命令和当前协议；源码开发、managed runtime、Codex skill、ChatGPT 远程 MCP 分层表达。
- [x] 对当前新增 speechrail.transcription 扩展给出最小可执行示例，并链接唯一 Realtime 契约。

### Task 3: 公共契约与架构/开发/运维文档

**Files:**
- Read: contracts/openapi.yaml（本轮核对后无需改写）
- Modify: contracts/realtime-openai.md
- Read: contracts/diarization/v1/（本轮核对后无需改写）
- Modify: docs/architecture/README.md
- Read only: docs/architecture/openai-conformance-audit.md（保持 `superseded` 历史内容不改写）
- Modify: docs/architecture/speechrail-mcp-proxy.md
- Modify: docs/developers/README.md
- Modify: docs/developers/testing-acceptance.md
- Modify: docs/operations/README.md
- Modify: docs/decisions/README.md only for active index/navigation consistency

- [x] 让机器可读契约与实现/测试字段一致；不通过 README 或 skill 发明契约字段。
- [x] 明确 current-only、错误 envelope、Realtime event lifecycle、MCP proxy 无状态边界和 diarization session-scoped 语义。
- [x] 将验收文档区分确定性 fake 测试、安装态 smoke、真实模型质量、性能和 UI 验收，不把一种证据冒充另一种。
- [x] 保留历史决策与 archive 入口，不把历史协议改写成当前支持。

### Task 4: 随包 skill 与项目 skill

**Files:**
- Modify: src/speechrail/assets/skills/speechrail/SKILL.md
- Modify: src/speechrail/assets/skills/speechrail/references/*.md
- Modify: src/speechrail/assets/skills/speechrail/skill-manifest.json
- Modify: .agents/skills/speechrail-local-deploy/SKILL.md
- Modify: .agents/skills/speechrail-release/SKILL.md
- Modify: .agents/skills/speechrail-perf-benchmark/SKILL.md
- Modify: .agents/skills/speechrail-zero-setup/SKILL.md

- [x] skill 只指导已发布工具、资源和当前操作边界；不能把 reference 文档当作额外 tool 权限。
- [x] 统一 describe-first、路径/隐私、错误重试、Realtime 直连、安装/发布/基准测试授权规则。
- [x] manifest 中列出的每个 reference 均存在，skill 内容不包含真实本机路径、密钥或历史承诺。

### Task 5: 一致性验证与交付记录

**Files:**
- Modify: docs/superpowers/sdd/2026-09-21-documentation-formalization/facts.md
- Modify: docs/superpowers/plans/2026-09-21-documentation-formalization.md

- [x] 运行 Markdown 链接/引用、JSON、YAML、skill manifest、package resource、ruff/pytest 文档相关检查。
- [x] 用 rg 复查旧版本、旧 endpoint、旧字段和“支持但未实现”的表述；逐项保留、改写或标记历史。
- [x] 运行 git diff --check 和 git status --short，确认没有生成物、运行态变更或无关覆盖。
- [x] 在 facts ledger 中记录读取范围、事实来源、未改写的历史文档和剩余无法验证的内容。
