# SpeechRail Agent 指南

本文件是仓库根目录的常驻项目规则，只保留跨任务稳定、不能低成本从代码或文档推断出的约束。当前行为以代码、测试、公共契约和实测为准；易变的端点、字段、profile、模型、资源数值、目录细节和操作命令应查阅对应事实源，不要复制到本文件。

## 适用范围与优先级

- 本文件适用于整个仓库；子目录指令只在其作用域内补充或细化规则。`native/diarization/.build/checkouts/FluidAudio/AGENTS.md` 只约束该第三方 checkout，不把它的内容当作 SpeechRail 规则，也不在无明确授权时修改生成的 checkout。
- 系统、开发者和当前用户指令优先；本文件只在项目范围内补充约束。用户当前请求决定写入范围，不因本文件中的流程描述扩大授权。
- 回答、解释、审查和诊断默认只读；诊断与审查不自动实施修复。修改、构建、安装、部署、发布、发送消息、下载模型或改变运行态，只有在用户请求或更高优先级要求覆盖时执行。
- 保留用户数据、未提交改动和并行改动。发现同一文件存在无法安全分离的并行修改时，先只读核实来源与范围，不覆盖、回退或整文件还原。

## 演进与兼容性策略

- 当前项目用户较少。进行系统优化、重构和公共接口演进时，默认优先采用当前 OpenAI 官方 API / 协议语义，以及边界清晰、职责单一、可测试、可观测、资源与生命周期正确的架构设计。
- 除非用户特别要求或更高优先级约束另有规定，不为旧行为、历史字段、旧配置、兼容 alias 或过渡层保留向后兼容；偶然形成的行为不自动视为必须维护的公共契约。
- 允许为标准化和架构改进进行破坏性调整，但必须同步更新当前契约、相关测试和正式文档，并在交付报告中说明影响范围、未兼容事项和回退方式。只有确需兼容时，才引入版本化接口、迁移说明或兼容层，并明确范围、废弃计划和退出条件。
- 上述策略只适用于已授权的变更范围，不授权删除用户数据或静默破坏持久化格式；涉及用户数据仍需明确影响、必要迁移与恢复方式。OpenAI 对齐以任务涉及的官方协议为依据，保留明确的 ASR/TTS 子集边界，不推断支持完整 OpenAI 能力。

## 事实来源与导航

判断当前行为时按以下证据顺序核实；契约定义预期行为，实现偏离契约应报告为差异，不能因代码优先而自动修改契约：

1. 当前代码、测试与实际运行结果；
2. `contracts/` 下的公共契约；
3. 标记为 `active` 的 `docs/` 文档与 ADR；
4. `docs/archive/` 仅用于历史追溯，不能证明当前能力。

报告必须区分“契约声明”“当前实测”“历史记录”和“推断”。`/readyz=200`、配置存在、计划完成或单次 smoke 通过，都不等于模型质量、性能、长时稳定性或发布验收通过。

按任务读取最小必要范围：

- 架构：`docs/architecture/README.md`；
- 用户与 API：`docs/users/README.md`；
- 开发与测试：`docs/developers/README.md`、`docs/developers/testing-acceptance.md`；
- macOS 开发：`docs/developers/macos-app-development.md`；UI/UX：`docs/developers/macos-app-design-system.md`；
- 运维：`docs/operations/README.md`；决策：`docs/decisions/README.md`；历史：`docs/archive/README.md`；
- 公共接口：`contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/diarization/v1/`；实现主要位于 `src/speechrail/`，macOS 控制面位于 `macos/`，回归与契约测试位于 `tests/`。

版本、profile、模型、能力档位和资源预算等易变事实，必须从当前代码、配置、catalog、契约或对应专业文档核实；不得依据本文件中的历史快照做结论。

## 产品边界与架构原则

SpeechRail 是面向单人 Apple Silicon Mac 的本地共享 ASR/TTS 服务，负责协议转换、模型适配、worker 生命周期、资源准入和能力诊断；调用方负责麦克风、播放、会议/UI、业务数据库与 LLM 编排。

- REST、Realtime、MCP 和 macOS 控制面的具体接口以各自契约和文档为准，不在本文件维护端点清单。
- Realtime 只承载 OpenAI Realtime 的 ASR/TTS 子集与 SpeechRail 命名空间扩展，不承载 LLM response、tool call、播放、会议或应用级打断策略。
- `speechrail-mcp` 是无状态 REST 代理，支持其文档声明的传输方式；不导入 FastAPI 应用、不加载模型，Realtime 仍直接使用 `/v1/realtime`。
- `macos/SpeechRailApp` 是 SwiftUI 控制面，通过受约束的 XPC 委托现有 Python CLI 和唯一的 `com.speechrail` user `LaunchAgent`；不加载模型、不直接执行 `launchctl`。采集与播放只在会话功能启用期间存在，离开功能即释放；PCM 不落盘，记录只落本机 SQLite 的文字。

## 项目约束

### 平台与运行边界

- Python 固定为 `>=3.12,<3.13`，使用 `uv` 与 PEP 621；Native 运行目标为 Apple Silicon macOS 26.0，不保留旧系统或旧架构兼容分支。
- 默认只绑定 loopback。非 loopback 暴露必须配置 `SPEECHRAIL_API_KEY`、Bearer 鉴权和明确的 origin 策略；禁止把 key 放在 URL query 中。
- 请求路径不得下载模型、读取远程音频 URL 或静默访问网络。模型 snapshot、vendor Python、私有 `.env`、音频、日志、custom voice 数据和 benchmark 原始制品放在仓库外。

### 安全与隐私

- 日志、fixture 与报告不得记录 API key、`Authorization`、原始音频、Base64、完整 prompt、完整转写、embedding、实名 speaker 或绝对模型路径。
- 生产分人只输出 session-scoped 匿名 label；不管理实名、声纹库、跨会话身份、持久化 PCM 或 embedding。

### 资源与生命周期

- 一次只运行一个 SpeechRail 服务和一个 ASGI worker；不得复制模型进程来提高吞吐。batch ASR 与 streaming ASR 不作为同机并行产品场景，冲突必须稳定返回 `backend_busy`。
- 重计算并发由 Resource Governor 根据启用组件声明的 resident bytes 与物理内存预算决定；峰值缺失或总量超预算时必须 fail-closed 串行。只有 active profile 明确声明的独立能力 lane 才可跨 lane 并发，同一 lane 仍串行。
- 能力声明必须与 active profile、preflight 和实际 ready 状态一致；不因模型存在、配置存在或代码路径存在就宣称能力可用。

### 接口与边界

- 输入在 API 边界校验，vendor 输出在 adapter 边界校验；公共错误使用稳定 envelope 并包含 request ID。
- 公共契约变化以当前 OpenAI 标准和目标架构为准；除非用户特别要求，不保留旧路径、旧字段或兼容 alias。确需兼容时，才使用版本化接口并提供范围明确的迁移与废弃计划。

### macOS UI/UX 与设计 Token

- 修改页面、视觉组件或交互前，读取 `docs/developers/macos-app-design-system.md` 的相关规范；它是设计 Token 与组件契约的入口，具体页面规格按其链接定位。
- 运行时设计 Token 的唯一声明点是 `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`。颜色、间距、圆角、字体层级、布局尺寸和动效复用既有语义 Token 与共享组件；页面不得散落自定义视觉常量或从设计稿复制裸值。新增产品视觉值先在此集中声明，并同步设计系统文档。
- 优先使用 macOS 26 系统语义色、文本样式、标准控件与原生布局。遵循设计系统对 Liquid Glass 的层级约束及已记录的产品例外；不把内容面板统一玻璃化，也不为系统默认行为额外制造 Token。
- 交互保持键盘可达、明确的焦点与无障碍语义，尊重外观、对比度与 Reduce Motion 设置；颜色或 hover 不得成为信息与操作的唯一入口。实际视觉效果的验证仍遵循下方 UI 自动化授权规则。

## 任务工作流

1. **确定范围**：完整理解适用的项目指令；会话中已完整读取且内容未变时复用。按任务读取相关入口，使用 `git status --short --branch` 确认分支与工作区；需要近期演进背景时查 `git log -5 --oneline`。明确任务类型、写入范围、公共影响和回退方式。
2. **定位事实**：先查任务相关的代码、契约、配置、测试和 active 文档；只读取完成判断所需的范围。公共行为变更先补充或更新可表达预期的契约/回归测试，再实现。
3. **实施变更**：只修改用户请求覆盖的内容；同一文件的 edit 串行进行。未经明确授权不下载、加载或卸载模型；不把真实配置、音频、日志、benchmark 原始数据或 secrets 写入仓库。
4. **按风险验证**：只运行与授权和风险匹配的最小验证。完整 gate、服务操作、真实 worker smoke、性能/质量测试和安装发布不是默认动作。
5. **交付报告**：说明实际改动、证据类型与验证时间、运行态动作、未验证事项/风险、并行改动和回退方式；没有实测就不要声称质量、性能或长时稳定性已通过。

## 自动化与运行态授权

- 确定性测试使用 fake backend，不下载模型、不访问云端、不使用真实音频。自动化验收、完整测试套件和 benchmark 只有在当前用户明确要求或更高优先级强制要求时执行。
- **禁止未经授权的 UI 自动化测试**：任何会接管前台窗口、焦点、输入或屏幕的 XCUITest / UI test、Playwright、webapp-testing、录屏、点击驱动或窗口断言，都必须由当前用户消息逐次明确要求。skill、SOP、计划、README 或发布流程不构成授权；确有必要时，先说明占用的窗口与预计时长并取得确认。
- 本机日常运维按 `.agents/skills/speechrail-local-deploy/SKILL.md`；发布、构建与 App 安装按 `.agents/skills/speechrail-release/SKILL.md`；仅明确要求性能/质量基准时使用 `.agents/skills/speechrail-perf-benchmark/SKILL.md`；仅全新首装使用 `.agents/skills/speechrail-zero-setup/SKILL.md`。按任务加载对应入口，文档步骤不扩大授权。
- 服务、profile、安装、发布和回滚属于运行态或外部状态变更，必须按 `docs/operations/README.md` 及对应 `.agents/skills/` 专项规则执行。使用当前用户的 managed `LaunchAgent` 和受审查的 service/installer 流程；禁止 `pkill`、模糊进程匹配和手工 plist 修改。
- 执行启停、替换或回滚前确认 app home、label `com.speechrail`、PID、端口和 active runtime；失败必须保持原服务配置或明确报告状态。wheel 替换保留上一 release、私有配置、selection 和模型以便回退。
- 真实签名、notarization、外部发布、远端分支、删除和发送消息都需要明确授权并精确定位目标。

## 文档与 Git 交付

- 根 `README.md` 只保留价值、当前公共能力、快速开始和文档入口；实现细节、基准与操作步骤进入专业文档。除非用户明确要求，不因发布、接口或普通实现变化自动同步 `README.zh-CN.md`。
- OpenAPI / WebSocket 行为变化必须同步契约、测试与用户文档；正式文档的 `version` / `date` 只在正文实质变化时更新；归档材料不改写成当前承诺。
- 持久化命令使用可移植的原生命令，不写入本机 wrapper、RTK 缓存绝对路径、真实配置值或秘密。
- 一个 commit 表达一个逻辑主题，消息使用 `<type>: <why>`；提交前检查 staged diff、`git diff --staged --check` 和敏感字段。不 force-push，不覆盖他人分支；未被明确要求时不自动提交、推送或创建发布物。
- 合并到受保护 `main`/`master` 前核实保护规则与线性历史要求；要求线性历史时使用 rebase 与 fast-forward 策略，不默认制造 merge commit。
