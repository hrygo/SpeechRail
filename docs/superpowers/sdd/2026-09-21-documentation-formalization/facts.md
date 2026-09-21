# SpeechRail 文档正式化事实台账

> 核对日期：2026-09-21（Asia/Shanghai）
>
> 本台账记录本轮文档整理使用的事实源、当前实现结论和已发现的文档冲突。它不是新的运行时契约；公共行为仍以当前代码、测试和 `contracts/` 为准。

## 读取范围

本轮已完整读取或逐段核对：

- 根文档：`README.md`、`README.zh-CN.md`、`docs/README.md`；
- 用户文档：`docs/users/README.md`、`installing-speechrail.md`、`integrations.md`、`api-contract.md`、`mcp-agent-integration.md`；
- 架构/开发/运维入口：`docs/architecture/README.md`、`architecture.md`、`product-scope.md`、`current-boundaries.md`、`speechrail-mcp-proxy.md`、`docs/developers/README.md`、`development-guide.md`、`testing-acceptance.md`、`docs/operations/README.md`、`operations-runbook.md`、`runtime-deployment.md`、`security-observability.md`、`docs/product/README.md`、`docs/product/overview.md`、`docs/decisions/README.md`；
- App 会话与数据边界：`docs/design/2026-09-18-session-layer/README.md`、`TECHNICAL-DESIGN.md`、`docs/design/UX-UI-SPEC.md`，以及 `SessionStore`、`CreativeWorkStore`、`SettingsView` 实现；
- 公共契约：`contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/diarization/v1/` 下全部 schema 与 fixture；
- 随包 skill：`src/speechrail/assets/skills/speechrail/` 下 `SKILL.md`、manifest 和全部 reference；
- 项目 skill：`.agents/skills/speechrail-local-deploy/`、`speechrail-release/`、`speechrail-perf-benchmark/`、`speechrail-zero-setup/` 及其直接引用的 operator/lifecycle/troubleshooting/reporting 文档；
- 事实实现：`pyproject.toml`、版本模块、配置示例、Realtime/模型别名、安装器和相关测试中的版本、平台、路径与能力声明。

历史审计、归档报告和已标记 `superseded` 的设计只用于识别文档来源，不作为当前能力依据；本轮不把历史材料改写成当前承诺。

## 当前事实

| 主题 | 当前结论 | 事实源 |
|---|---|---|
| 服务版本 | 当前源码、`pyproject.toml`、`src/speechrail/__init__.py`、配置示例和 OpenAPI 均为 `3.0.2`。 | `pyproject.toml`、`src/speechrail/__init__.py`、`configs/speechrail.example.*`、`contracts/openapi.yaml` |
| Python | `>=3.12,<3.13`。 | `pyproject.toml`、CI/安装 skill |
| 平台 | 当前交付目标为 Apple Silicon `arm64`、macOS 26.0+；App target 与当前 wheel/CI 目标一致。 | 根 `AGENTS.md`、CI、release/install 文档、wheel 构建事实 |
| 服务边界 | 单用户单机 SpeechRail 服务；默认 loopback；一个 LaunchAgent、一个 ASGI 父进程、一个 listener；服务不加载 LLM、不管理播放或业务会话。 | 根 `AGENTS.md`、`contracts/realtime-openai.md`、架构/运维文档 |
| Realtime | 唯一公共 WebSocket 为 `/v1/realtime`，current-only、无状态 Speech Plane；只提供 ASR/VAD/匿名分人事实与调用方显式 TTS。调用方拥有 LLM、history、memory、tools、播放队列和 barge-in。 | `contracts/realtime-openai.md`、Realtime 实现与测试、ADR-0019 |
| Realtime partial | `delta` 为追加式稳定前缀；`snapshot` 为同一 `item_id` 的完整可变全文，按严格递增 `revision` 替换；`completed` 为终态权威文本。`partial_mode` 与 `chunk_duration_ms=500|1000|2000` 必须在首个 PCM 前协商并等待 `transcription_session.updated`。 | `contracts/realtime-openai.md`、`src/speechrail/assets/skills/speechrail/references/realtime.md` |
| Realtime 时间戳 | Realtime 当前只承诺 `segment`；`word` 在该 wire 中明确拒绝。文件转写的 `word`/`segment` 由 REST `verbose_json` 提供。 | `contracts/realtime-openai.md`、Realtime adapter、OpenAPI |
| MCP | `speechrail-mcp` 是无状态 REST-to-MCP proxy；当前发布面为 15 个 tools、3 个只读 resources；不创建或代理 Realtime WebSocket，不加载模型，不拥有 LLM conversation。 | MCP 实现、`docs/architecture/speechrail-mcp-proxy.md`、skill manifest |
| 能力发现 | MCP/客户端应先读取 `describe()` 或 `GET /v1/speechrail/capabilities`，以 `effective_capabilities_v1` 为原子发现事实；不从静态模型名猜能力，也不在 capability 失败时拼接旧 discovery 伪造快照。 | OpenAPI、MCP 架构契约、MCP 用户手册 |
| 音色一致性 | `voice_revision` 与 model `catalog_revision` 是版本 pin，不是质量证明；`available=true` 只代表可路由；正式制作使用 `require_output_pass`，服务端按当前 runtime/recipe/policy 复核。 | OpenAPI、MCP 架构契约、skill references |
| Diarization | 文件分人使用 `gpt-4o-transcribe-diarize` + `diarized_json`；Realtime 需显式 opt-in；标签为 session-scoped 匿名值，不维护实名或跨会话身份。v1 schema/fixture 已核对。 | OpenAPI、`contracts/diarization/v1/`、Realtime 契约 |
| Translation | 当前没有 `/v1/audio/translations` 公共端点，也没有已实现的 translation route；“三档均支持 translation”的旧矩阵不是当前承诺。 | OpenAPI 完整路径、`src/speechrail/http`、`src/speechrail/config/profiles.py` |
| 模型下载 | 请求路径不下载模型、不读取远程音频 URL；显式安装/模型准备命令可以联网供给本地制品。 | 根 `AGENTS.md`、安装/运维 skill |
| 数据与日志 | 原始音频、PCM、完整转写、完整 prompt、embedding、凭据和绝对模型路径不得进入仓库、普通日志、fixture 或报告；自定义 voice/job 元数据按当前实现落在仓库外受控位置。 | 根 `AGENTS.md`、OpenAPI、运行时/安全文档、代码 |
| App 用户记录 | `sessions.sqlite3` 与 `Works/` 已由 macOS App 实现并长期保留；设置页当前只提供会话库单文件备份，不覆盖作品、音色或配置。 | `SessionStore.swift`、`CreativeWorkStore.swift`、`SettingsView.swift`、会话层设计 |

## 已发现的冲突与处理决定

| 冲突 | 处理决定 |
|---|---|
| 多个 active 入口仍写 `3.0.0`，而源码与 OpenAPI 为 `3.0.2`。 | 更新本轮涉及的 current/active 入口到 `3.0.2` 或对应独立文档修订号；历史报告、历史标题和归档版本不改写。 |
| `README.zh-CN.md`、安装手册部分内容写服务支持 macOS 14/15，但当前 wheel 标签为 `macosx_26_0_arm64`，仓库基线为 macOS 26+。 | 统一当前交付文案为 macOS 26.0+、Apple Silicon；不保留旧系统安装分支。 |
| 文档中心使用 “Production Ready”，但 `pyproject.toml` 为 Beta，且项目规则要求把 readiness、质量、性能和真实 smoke 分开。 | 改为 Beta/契约可用/按 profile 就绪等可证据化表述，不用健康检查或单次 smoke 宣称整体生产质量。 |
| 用户/集成/产品矩阵把 translation 或 Realtime word timestamp 写成可用。 | 删除或改为当前实际支持的 REST `segment`/`word` 与 Realtime `segment`；不修改代码以迎合旧文案。 |
| 安装手册保留 2.6.6/2.7.0 分支，active 运维文档保留迁移/兼容表述。 | 当前文档只保留当前 wheel/managed installer/zero-setup 入口；历史升级信息移出当前承诺。项目没有旧数据迁移目标，数据可按当前目录契约删除并重建。 |
| runtime-deployment 把 custom voice/session 数据写成 app home 新目录，并描述旧 `~/.speechrail` 自动迁移；当前代码默认仍使用 `~/.speechrail`。 | 文档按当前代码描述实际路径，删除未实现的迁移承诺；需要保留的数据由用户自行备份，重建区可删除后重新准备。 |
| active 运维文档示例混用源码 `uv run speechrail service ...` 与 managed runtime 命令。 | 明确生产运维必须使用已安装 `runtime/current` 的 CLI；`uv run` 仅用于源码开发/确定性测试。 |
| 历史 `openai-conformance-audit.md` 与当前 Realtime 契约存在已知差异。 | 保持 `status: superseded`，只在目录中明确不可作为当前契约依据；不修改历史审计内容。 |
| 文档正式化遗漏了 active 产品白皮书与会话层设计中的当前事实，导致 translation、性能指标和 App 记录/备份边界仍有旧表述。 | 补读并修正 `docs/product/overview.md` 与会话层 active 文档；保留单文件备份事实，明确完整数据区备份、音色迁移和 Time Machine 仍未实现。 |

## 本轮调整

- 主 README、文档中心、用户手册、架构/开发/运维入口统一到服务 `3.0.2`、Apple Silicon macOS 26.0+、current-only Realtime 与 managed runtime 入口。
- active 文档不再把 `/v1/audio/translations`、Realtime `word` timestamps、旧 Realtime wire、服务端 LLM 或未实现的生产质量写成能力承诺；历史审计和历史验收保留原文并通过 `superseded`/历史说明隔离。
- `runtime-deployment.md` 区分 managed service app home 与 App 用户记录，记录 `sessions.sqlite3`、`Works/` 和现有单文件备份入口；完整数据区备份、音色路径迁移和 Time Machine 排除仍明确为未实现。可重建 runtime/model/state 可按用户明确路径删除并重新准备。
- MCP 用户手册与架构文档统一 `effective_capabilities_v1`、15 tools/3 resources、describe-first、revision pin、validation policy 和 Realtime 直连边界；随包 skill manifest 的全部 reference 已存在。
- 运维 skill 统一使用 wheel 自带 `speechrail install` 和 `runtime/current/.venv/bin/speechrail`；`uv run` 只保留在源码开发、确定性测试或历史文档语境。
- 整篇属于历史实测的 `docs/operations/runtime-evaluation.md` 与 `docs/operations/2026-09-11-tier-repositioning-acceptance.md` 已标记 `superseded`；`docs/operations/migration-runbook.md` 同样降为历史记录。

## 本轮验证

- `npx @redocly/cli lint contracts/openapi.yaml`：通过。
- `uv run pytest --no-cov -q tests/test_speechrail_skill_package.py`：通过。
- `ruff check tests/test_speechrail_skill_package.py`：通过。
- 23 个 JSON schema/fixture/manifest：解析通过；manifest 列出的 reference 全部存在。
- 270 个非归档 Markdown 文件的相对链接：检查通过。
- `git diff --check`：通过；未执行服务启停、模型下载、真实推理或 UI 自动化。

## 文档写作规则

1. 使用“当前支持”“仅在……条件下支持”“不支持”“未验证”四类状态；不使用无法由当前证据证明的“完全兼容”“生产就绪”“零风险”“自动恢复”等表述。
2. 先描述调用方可执行的行为，再描述实现细节；内部模型名、worker、revision 和 runtime 只在集成/开发/运维层出现。
3. Realtime、MCP、REST 三条边界分别说明：输入/输出、状态所有权、失败动作和唯一事实源。
4. 版本号只表达当前文档或服务事实；历史文档保留其历史日期，不通过全局替换破坏审计语义。
5. 文档示例不得包含真实 token、私有绝对路径、完整用户音频/转写或不可验证的本机运行结果。

## 尚未作为当前承诺的内容

- 真实模型质量、性能、长时稳定性、DER/JER、跨文本音色相似度和人工听感，除非对应报告明确覆盖，否则均为未验证；
- 非 loopback 的 TLS、CORS、origin/网段控制、速率限制和集中式指标导出；
- UI 自动化、真实麦克风/OBS/会议软件可见性和跨应用播放验收；
- 历史 Realtime wire、旧字段、`/v2` 路径和数据迁移层。
