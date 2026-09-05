# SpeechRail Agent 指南

本文件只提供稳定、不可从代码直接推断的约束与导航。当前行为以代码、契约和实测为准；详细设计、运行和历史证据放在 `docs/`，不要把本文件扩写成能力百科。

## 项目目标

SpeechRail 是单人本机使用的独立 ASR/TTS 服务，为 OpenAI SDK、QwenPaw、Sona、Hermes Agent 等客户端提供稳定公共接口。服务负责协议、推理运行时、模型适配、资源边界和可观测性；客户端负责麦克风、播放、会议、UI、数据库和 LLM 编排。

设计取舍依次考虑：当前消费者是否需要、能否复用现有进程与契约、是否有可验证的失败与回退路径。不要为假设的多租户、云控制面、HA、分布式队列或服务网格增加复杂度。

## 事实来源

按以下顺序解决冲突：

1. 当前代码、测试和实际运行结果；
2. `contracts/openapi.yaml`、`contracts/realtime-openai.md`、`contracts/realtime-v2.md`；
3. 状态为 active 的 `docs/` 文档和 ADR；
4. `docs/archive/` 仅作历史追溯，不能证明当前能力。

`readyz=200`、配置存在或计划标记完成，都不等于真实模型质量与资源验收。报告必须明确区分实测、契约、历史记录和推断。

## 每次任务先做

1. 读取本文件与任务对应的入口文档。
2. 执行 `git status --short`、`git log -5 --oneline`，确认分支、未提交和并行改动。
3. 明确任务类型、写入范围、公共契约影响、运行态影响和回退方式。
4. 先调查真实现状；公共行为变更先写失败的契约或回归测试。
5. 只修改目标所需文件，不覆盖未知改动，不提交本机配置或制品。

默认使用简洁中文沟通；命令、路径、配置键、API 字段、事件、错误码、模型 ID 和符号名保留原文。

## 必须保持的边界

- Python 固定为 `>=3.12,<3.13`，使用 `uv` 和 PEP 621。
- 默认绑定 loopback；非 loopback 必须配置 API key 和明确的 origin 策略。
- 请求路径不得下载模型、读取远程音频 URL 或静默访问网络。
- snapshot、vendor Python、私有 `.env`、音频、日志和 benchmark 原始制品位于仓库外。
- 不在日志、fixture 或报告中记录 API key、Authorization、原始音频、Base64、完整 prompt、完整转写、embedding、姓名或绝对模型路径。
- 一次只运行一个 SpeechRail 服务和一个 ASGI worker；不要通过复制模型进程提高吞吐。
- batch ASR 与 streaming ASR 不作为同机同时工作的产品场景；共享 worker 的模式冲突应稳定返回 `backend_busy`。
- 三档只改变权重与量化组合，API、worker 协议、调度和服务架构保持一致；档位对调用方透明。
- `quality` 使用 1.7B VoiceDesign；`balanced/light` 使用同名 CustomVoice speaker。API 按当前权重声明能力，不伪造不可用功能。
- `/v1/realtime` 只实现 ASR/TTS 子集，不承载 LLM response、tool call、播放、会议或应用打断策略。
- diarization 只输出 session-scoped 匿名 label；不管理实名、声纹库、跨会议身份或持久化 PCM/embedding。
- 所有公共错误使用稳定 envelope 并包含 request ID；输入在 API 边界校验，vendor 输出在 adapter 边界校验。
- 破坏性公共变更进入 `/v2` 并提供迁移说明；兼容 alias 必须有明确废弃计划。

## 代码地图

| 路径 | 责任 | 先读 |
|---|---|---|
| `src/speechrail/app.py` | FastAPI 组合根、middleware、routes、lifespan | `contracts/`、`application/` |
| `src/speechrail/application/` | 用例组装与跨传输交付 | `domain/ports.py` |
| `src/speechrail/domain/` | vendor-neutral 类型与 ports | 公共契约 |
| `src/speechrail/backends/` | Qwen3 ASR/TTS 与 diarization adapters | 对应 port 与 worker 协议 |
| `src/speechrail/runtime/` | 队列、Resource Governor、worker IPC、jobs | 资源与超时配置 |
| `src/speechrail/realtime/` | Realtime 状态机 | `contracts/realtime*.md` |
| `src/speechrail/config/` | 环境配置、模型目录与 selection | `configs/` |
| `src/speechrail/service/` | LaunchAgent、managed runtime、profile 切换 | `docs/operations/` |
| `contracts/` | 公共 API 事实来源 | 任何接口修改前 |
| `tests/` | fake backend、契约、安全和边界回归 | `docs/developers/testing-acceptance.md` |

文档入口：

- 架构与产品边界：`docs/architecture/README.md`
- API 与客户端：`docs/users/README.md`
- 开发与测试：`docs/developers/README.md`
- 部署与排障：`docs/operations/README.md`
- 架构决策：`docs/decisions/README.md`
- 历史材料：`docs/archive/README.md`

## 开发与验证

```bash
uv sync --extra dev
uv run speechrail serve
```

未配置真实 backend 时服务可以启动，推理入口应返回 `503 backend_not_ready`。确定性测试使用 fake backend，不下载模型。

行为变更先跑针对性测试。代码、测试、契约或跨模块变更完成后执行完整 gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

服务、profile 或运行时变更还需检查：

```bash
plutil -lint deploy/macos/com.speechrail.plist.example
uv run speechrail service --help
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/readyz
curl http://127.0.0.1:8201/v1/models
curl http://127.0.0.1:8201/v1/voices
```

健康端点通过后，若本机已有外部 runtime 且任务已授权运行态操作，使用非敏感短音频完成公共 ASR/TTS smoke。性能和质量测试遵循 `.agents/skills/speechrail-perf-benchmark/SKILL.md`；发布遵循 `.agents/skills/speechrail-release/SKILL.md`。

## 服务操作

macOS 常驻服务只使用用户级 `LaunchAgent` 和已审查的 `speechrail service` / installer 流程。执行启停、替换或回滚前确认 app home、label `com.speechrail`、当前 PID、端口和 runtime；不要用 `pkill`、模糊进程匹配或手工 plist 修改。

wheel 替换必须先停旧实例，再在隔离 release 目录 preflight，最后原子切换 `runtime/current`。保留上一 release、私有配置、selection 和模型用于回退；`disable`/`uninstall` 不等于版本回退。

## 文档规则

- README 只保留价值、当前公共能力、快速开始和文档入口；实现细节进入专业文档。
- OpenAPI/WebSocket 行为变化同步更新契约、测试和用户文档。
- 正式文档 front matter 的 `version`/`date` 只在正文实质变化时更新。
- 归档计划不得改写成当前承诺；当前状态变化应更新 active 文档或新增有日期的验收报告。
- 持久化命令使用可移植的原生命令，不写入本机 alias、wrapper、绝对工具缓存路径或真实配置值。

## Git 与交付

- 一个 commit 表达一个逻辑主题，消息使用 `<type>: <why>`。
- 提交前检查 staged diff、`git diff --staged --check` 和敏感字段。
- 不 force-push，不覆盖他人分支，不提交 `.env`、模型、音频、日志、benchmark 原始数据或构建产物。
- 同文件存在并行改动时只提交可安全分离的 hunk；无法分离就报告阻塞。

结束时报告：结果、改动、实测、运行态、未验证/风险、并行改动和回退方式。结论范围必须与证据一致。
