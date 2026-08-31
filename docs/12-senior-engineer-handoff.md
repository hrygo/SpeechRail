---
title: "SpeechRail 高级工程师审查交接"
status: review-ready
date: 2026-08-31
---

# SpeechRail 高级工程师审查交接

## 审查目的

请审查 SpeechRail 从“Qwen3-ASR foundation”演进为**公共 ASR/TTS 运行时**的边界、接口和
迁移方案。此交接包不请求立即下载模型、变更现有客户端或安装系统服务；它请求对设计和
实施顺序作出技术判断。

## 一页结论

- 当前 `main` 已实现并本机验证：Qwen3-ASR batch REST、基础 WebSocket、离线 worker、
  QwenPaw 转写 smoke。
- 当前 `main` 尚未实现：真实 streaming ASR、TTS、异步 job、Realtime v2、
  `voice-realtime` adapter、完整 WLK `/asr` parity。
- 已接受的目标：SpeechRail 只做实时/批量 ASR 和 TTS；不做端到端语音对话、LLM、播放、
  会议、UI 或持久化。
- 迁移主线：`voice-realtime` 直接接入 `/v2/realtime`，它的语音助手与会议助手是最高优先级
  集成 smoke；不以完整复刻 WLK `/asr` 为前置条件。

目标设计与理由见[最终设计规格](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
及 [ADR-0006](decisions/0006-public-asr-tts-runtime.md)。

## 仓库与提交状态

| 项目 | 值 |
|---|---|
| 当前分支 | `main` |
| foundation 初始提交 | `5357099` |
| 实现合并 | `8ac7688` 及其前序 Qwen3 worker 提交 |
| 测试确定性修复 | `33c64b1` |
| 最终设计文档 | `624f895` |
| 本交接文件 | 本次审查文档提交 |

工作树在交接文件写入前为干净状态。该项目没有执行远端 push、模型下载、客户端仓库修改或
`launchd` 安装。

## 当前实现：已验证事实

### 可用 API

| API | 当前行为 | 审查注意事项 |
|---|---|---|
| `POST /v1/audio/transcriptions` | Qwen3-ASR 文件转写；`json`、`verbose_json`、`text`、`srt`、`vtt` | 当前唯一真实模型已验证路径 |
| `GET /health`、`/readyz`、`/v1/models` | 存活、配置就绪和公开模型清单 | `readyz` 仍应由真实短音频 smoke 补充验证 |
| `WS /v1/realtime` | append 后一次 commit，返回一次最终结果 | 不是持续 partial streaming |
| `WS /asr` | `config` + 空 PCM EOF → `ready_to_stop` | 不进行 ASR；未认证；不能替换 WLK |

### 运行时

- Qwen3-ASR 使用仓库外完整 snapshot、独立 Python 子进程和离线环境变量。
- Apple Silicon profile 为 MPS / `float16`，禁止静默 CPU fallback；CPU profile 为
  `cpu` / `float32`。
- REST 上传以固定 `ffmpeg` 参数解码为 PCM；模型 worker 长生命周期且顺序处理请求。
- 默认 loopback；非 loopback Settings 要求 API key。CORS、legacy auth、解码后时长上限、
  限速和指标导出尚未实现。

### 已完成的实测

2026-08-31 对合并后代码的最后一次验证结果：

```text
27 passed
coverage 82.58%
ruff: passed
mypy: passed
OpenAPI Redocly lint: passed
launchd plist syntax: passed
```

QwenPaw 已在本机通过其 `whisper_api` provider 指向 SpeechRail 完成一段中文短音频 smoke。
本交接不保留音频、模型绝对路径、API key 或转写正文。Hermes 与 `voice-realtime` 尚无真实
端到端验收。

## 目标设计：请重点审查

### 公共接口

| 表面 | 目标 |
|---|---|
| REST v1 | 保持 `/v1/audio/transcriptions`；新增 OpenAI-compatible `/v1/audio/speech` |
| async jobs | ASR/TTS 长任务使用明确的 job resource、取消和结果 TTL，不伪装成 OpenAI Batches |
| Realtime v2 | `/v2/realtime` 只支持 `transcription` 与 `speech` session type |
| v1 | `/v1/realtime` 语义冻结，避免破坏当前可观察行为 |
| legacy | `/asr` 只保留到 `voice-realtime` v2 迁移与回滚演练完成 |

Realtime v2 不是 OpenAI 的完整对话协议：它不携带 LLM response、tool call、语音对话编排或
播放指令。它只承载 ASR PCM 输入/partial-final 输出，以及 TTS 文本输入/音频 chunk 输出。

### 资源与数据

- ASR realtime、TTS realtime、batch 采用独立优先级 lane；单 profile 独立 worker。
- 实时 ASR 高于实时 TTS，高于 batch；不通过多 ASGI worker 复制模型。
- 音频默认瞬态；job 原始输入推理后删除，结果默认 TTL 为一小时；正文不写入日志。
- TTS 首发只允许服务器登记的预置 voice。音色克隆不在首发范围。

### 模型策略

- 继续使用当前 Qwen3-ASR profile；必须补足真正的 streaming adapter，不能把 batch 结果
  伪装成 partial。
- TTS 优先评估 Qwen3-TTS；Kyutai TTS/MLX 是低延迟 Apple Silicon 备选。
- 上述 TTS 候选均未下载、加载或基准验证。模型来源、版本、许可、量化、MPS 兼容性和质量
  必须在实施阶段逐一验收。

## `voice-realtime` 直接迁移路径

```text
AudioHub PCM
  → SpeechRailRealtimeAdapter（voice-realtime 内）
  → SpeechRail /v2/realtime, session.type=transcription
  → partial / completed
  → 现有 SubtitleProxy / MeetingSession / SRT / PostgreSQL
```

迁移只改变 transport adapter；SpeechRail 不 import `voice-realtime`，也不接管其会议、
AudioHub、TTS bridge、UI 或数据库。建议按以下阶段评审：

1. v2 ASR 契约与 fake backend 测试；
2. SpeechRail 真实 streaming worker；
3. `voice-realtime` 独立分支 adapter；
4. 同一 PCM 的受控影子比对；
5. 语音助手和完整会议冒烟；
6. 切换、回滚演练、退役旧 WLK / `/asr`。

TTS 不阻塞 ASR 迁移。`voice-realtime` 可先保留自己的播放/TTS bridge，待 SpeechRail
`speech` 会话稳定后再改为消费公共 TTS audio chunk。

## 已知风险与技术债

1. 当前 ASR v1 realtime 和 `/asr` 不满足会议实时后端需求；不能被误用为已迁移能力。
2. `readyz` 反映推理入口配置，尚不是 worker 活性探针；目标方案要求拆分真实 readiness。
3. 当前 FastAPI startup/shutdown 使用已弃用的 `on_event`；实施 v2 时应迁移至 lifespan。
4. 当前 `allowed_origins`、`max_audio_seconds` 是配置字段但未完全强制；LAN 暴露不可接受。
5. Realtime ASR/TTS 的首包、RTF、内存和并发上限尚无真实基准；不能事先承诺时延。
6. TTS 模型的许可证、声音安全、MPS 实现质量和中文表现尚未验收。
7. job 结果 TTL 引入短期输出存储，需要实现权限、清理、容量与失败恢复测试。

## 审查问题清单

请特别判断：

1. `/v2/realtime` 的版本隔离是否优于扩展现有 `/v1/realtime`？
2. `transcription` 与 `speech` session 是否应共用同一路径，还是拆成两个 WebSocket endpoint？
3. 自定义 async job resource 的命名、状态与 TTL 是否适合本地公共服务？
4. realtime ASR > realtime TTS > batch 的调度优先级是否符合会议场景？
5. `voice-realtime` adapter 是否足够窄，是否遗漏了 EOF、重连、partial 覆盖、confirmed
   文本、SRT、数据库或取消的语义？
6. TTS 首发的预置 voice 约束是否正确，是否应保留任何克隆能力？
7. 在不接管播放、打断和 LLM 的前提下，公共 TTS 流式协议是否足够支撑语音助手？
8. 是否需要先建立性能基准门，再确定默认模型 profile 和并发配置？

## 审查材料导航

- [最终架构规格](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
- [现行 API 契约](02-api-contract.md) 与 [Realtime v1 契约](../contracts/realtime.md)
- [运行时与部署](05-runtime-deployment.md)
- [测试与验收](07-testing-acceptance.md)
- [迁移 Runbook](08-migration-runbook.md)
- [当前边界](09-open-questions.md)
- [ADR 索引](decisions/README.md)

## 对审查后的预期输出

请给出“接受 / 接受但修改 / 退回重设”结论，并针对审查问题标注必须修改、可后置和不建议
实施的项。方案被接受后，下一步才创建分阶段实施计划；不会直接开始写 v2、TTS 或
`voice-realtime` 代码。
