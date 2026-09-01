---
title: "SpeechRail 高级工程师审查结论与实施前交接"
status: review-complete
date: 2026-08-31
---

# SpeechRail 高级工程师审查结论与实施前交接

## 审查结论

高级工程师审查结论为：**接受但修改**。公共 ASR/TTS 边界、Realtime v2 隔离、
`voice-realtime` 直接迁移和 TTS 不阻塞 ASR 的方向成立；原方案对消费端口、confirmed/EOF、
重连、资源准入、TTS 取消、job 生命周期和 LAN WebSocket 安全的定义不足。

必须修改项已进入[最终设计规格](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)、
[Realtime v2 设计契约](../../../contracts/realtime-v2.md)和 [ADR-0006](../../decisions/0006-public-asr-tts-runtime.md)。
这些文件不授权下载模型、修改客户端、安装服务或执行真实模型/客户端 smoke；后续代码实现必须
保持这些运行门禁。

## 一页结论

- 代码实现已具备：Qwen3-ASR batch REST、v2 ASR/TTS state machine、受监督 TTS worker、
  durable jobs、可选 WLK streaming transport 与 `voice-realtime` 的两个 opt-in adapter。
- 真实 streaming ASR、真实 TTS、jobs 的业务 `input_ref` resolver、QwenPaw/Hermes/
  `voice-realtime` 影子与切换 smoke 均尚未获授权或验收。
- 已接受的目标：SpeechRail 只做实时/批量 ASR 和 TTS；不做端到端语音对话、LLM、播放、
  会议、UI 或持久化。
- 迁移主线：`voice-realtime` 通过一个共享 Realtime client 和两个窄端口 adapter 接入
  `/v2/realtime`；语音助手与会议助手分别验收，不以完整复刻 WLK `/asr` 为前置条件。
- Realtime v2.0 不做透明 session 恢复；断线创建新 session/source epoch，由应用记录 gap。
- 默认 profile、worker 数和并发配置必须先通过真实 streaming、RTF、内存与资源隔离基准门。

目标设计与理由见[最终设计规格](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
及 [ADR-0006](../../decisions/0006-public-asr-tts-runtime.md)。

## 仓库与提交状态

| 项目 | 值 |
|---|---|
| 当前分支 | `main` |
| foundation 初始提交 | `5357099` |
| 实现合并 | `8ac7688` 及其前序 Qwen3 worker 提交 |
| 测试确定性修复 | `33c64b1` |
| 最终设计文档 | `624f895` |
| 审查优化 | 当前文档变更；提交后以新 commit 为准 |

高级工程师审查前的工作树为干净状态。审查优化只修改方案、契约和 ADR；没有执行远端 push、
模型下载、客户端仓库修改或 `launchd` 安装。

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

## 已优化目标设计

### 公共接口

| 表面 | 目标 |
|---|---|
| REST v1 | 保持 `/v1/audio/transcriptions`；新增 OpenAI-compatible `/v1/audio/speech` |
| async jobs | ASR/TTS 长任务使用明确 job resource、独立 cancel/result/delete 和 completed_at TTL |
| Realtime v2 | `/v2/realtime` 只支持 `transcription` 与 `speech` session type |
| v1 | `/v1/realtime` 语义冻结，避免破坏当前可观察行为 |
| legacy | `/asr` 只保留到 `voice-realtime` v2 迁移与回滚演练完成 |

Realtime v2 不是 OpenAI 的完整对话协议：它不携带 LLM response、tool call、语音对话编排或
播放指令。它只承载 ASR PCM 输入/partial-final 输出，以及 TTS 文本输入/音频 chunk 输出。

### 资源与数据

- ASR realtime、TTS realtime、batch 使用独立 lane，由全局 Resource Governor 核对设备、内存、
  profile、活动 session 和输出缓冲预算。
- 实时 ASR/TTS 使用容量预留，batch 只使用剩余容量并带 aging；不采用严格全局优先队列，
  不通过多 ASGI worker 隐式复制模型。
- 音频默认瞬态；job 原始输入推理后删除，结果默认 TTL 为一小时；正文不写入日志。
- TTS 首发只允许服务器登记的预置 voice。音色克隆不在首发范围。

### 模型策略

- 继续使用当前 Qwen3-ASR profile；已提供可选 WLK streaming transport，但必须经过真实
  streaming 验收，不能把 batch 结果伪装成 partial。
- TTS 优先评估 Qwen3-TTS；Kyutai TTS/MLX 是低延迟 Apple Silicon 备选。Qwen3-TTS 在 MPS
  可行性门通过前只是候选，不是默认实现承诺。
- 上述 TTS 候选均未下载、加载或基准验证。模型来源、版本、许可、量化、MPS 兼容性和质量
  必须在实施阶段逐一验收。

## `voice-realtime` 直接迁移路径

```text
AudioHub PCM
  → shared SpeechRailRealtimeClient（voice-realtime 内）
      ├─ SpeechRailStreamingTranscriber（字幕/会议）
      └─ SpeechRailConversationSTTFactory（语音助手）
  → SpeechRail /v2/realtime, session.type=transcription
  → delta / item completed / session completed
```

迁移只改变协议 client 与两个现有应用端口 adapter；SpeechRail 不 import `voice-realtime`，
也不接管其会议、AudioHub、TTS bridge、UI 或数据库。实施计划应按以下依赖顺序拆分：

1. 真实 streaming/resource 可行性门，确定 worker 拓扑和预算；
2. 同一 PCM 的受控影子比对；
3. 语音助手和完整会议分别冒烟；
4. 切换、回滚演练、退役旧 WLK / `/asr`。

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
8. Realtime v2.0 的断线恢复依赖应用建立新 epoch 并显式记录 gap，不提供透明续传。
9. `voice-realtime` 的会议与语音助手使用不同 ASR 端口，必须分别实现和验收 adapter。

## 审查决议

| 问题 | 决议 |
|---|---|
| v2 隔离 | 接受；v1 保持一次 commit/一次 final，新的 item/session 状态进入 v2 |
| ASR/TTS 共用路径 | 接受同一 `/v2/realtime`，使用 discriminated session 和两个独立状态机 |
| async jobs | 接受自定义 resource；拆分 cancel/result/delete，TTL 从 completed_at 开始 |
| 调度 | 接受实时容量保护；不采用严格全局优先队列，使用预留、剩余容量准入和 aging |
| voice-realtime adapter | 一个共享 client、两个窄端口 adapter；应用继续拥有 epoch/gap/SRT/数据库 |
| voice | 首发只允许 preset voice；不保留 clone 字段、样本或隐藏入口 |
| TTS streaming | 增加 response ID、chunk index、cancelled 确认和慢消费者上限后接受 |
| 性能门 | fake contract 可先行；默认模型、worker 和并发必须在真实基准后决定 |

## 审查材料导航

- [最终架构规格](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
- [现行 API 契约](../../users/api-contract.md)、[Realtime v1 契约](../../../contracts/realtime.md)与
  [Realtime v2 设计契约](../../../contracts/realtime-v2.md)
- [运行时与部署](../../operations/runtime-deployment.md)
- [测试与验收](../../developers/testing-acceptance.md)
- [迁移 Runbook](../../operations/migration-runbook.md)
- [当前边界](../../architecture/current-boundaries.md)
- [ADR 索引](../../decisions/README.md)

## 下一道门

请先确认优化后的规格、v2 设计契约和 ADR。确认后才使用独立请求创建分阶段实施计划；该计划
应把可行性门、ASR v2、两个消费端口 adapter、jobs 和 TTS 拆为可单独验证和回退的阶段。
在确认前不会开始写 v2、TTS、jobs 或 `voice-realtime` 代码。
