---
title: "SpeechRail 公共 API 契约手册"
status: active
audience: "应用开发者、客户端工程师、API 消费者"
version: "3.3.1"
date: 2026-09-26
---

# 📡 SpeechRail 公共 API 契约手册

> 机器可读的 OpenAPI 3.1 规范位于 [`contracts/openapi.yaml`](../../contracts/openapi.yaml)；WebSocket 全双工事件规范位于 [`contracts/realtime-openai.md`](../../contracts/realtime-openai.md)。

---

安全发现与强一致性管理统一位于 `/v1/speechrail/*`；OpenAI 兼容的 TTS 主路径始终是
`POST /v1/audio/speech`。revision pin、发音集、完整性回执、调度意图与可选 TTS chunk timing 通过
`SpeechRail-*` Header 渐进增强，不改变 OpenAI JSON 请求体。
详见[有效能力快照与安全目录](effective-capabilities.md)。

## 1. 模型身份与别名映射

SpeechRail 对外暴露 Canonical（规范）模型名与 OpenAI 标准别名（Alias）：

| 能力类别 | Canonical 模型 ID | 标准别名 (Aliases) | 说明 |
|---|---|---|---|
| **语音识别 (ASR)** | `speechrail/qwen3-asr-1.7b` | `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | 别名自动归一化路由至本地 Qwen3-ASR 运行时（支持 1.7B / 0.6B 权重目录） |
| **语音合成 (TTS)** | `speechrail/qwen3-tts` | `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | 别名自动归一化路由至当前档位的 VoiceDesign、CustomVoice 或 Base capability |

> 💡 **模型规格自适应**：Canonical 模型 ID 标识服务后端能力契约，底层可通过 `SPEECHRAIL_QWEN3_MODEL_DIR` 自由加载 **Qwen3-ASR-1.7B** 或 **Qwen3-ASR-0.6B**（显存占用更低、适用于 8GB 内存设备），对外均遵循相同的 OpenAI 协议。

客户端向 `GET /v1/models` 发起请求即可获取完整的模型清单及其 `resolves_to` 映射关系。
TTS 模型条目还会返回 `capabilities.supports_preview`、`supports_clone` 与
`supports_instruction`。三个 TTS 档位都绑定 `custom_voice`（系统声音）与 `base`（参考克隆）
两个角色，`voice_design`（提示词设计）只绑定在 `reference` 档且快照缺失时降级为不可用。
客户端必须读取运行时能力字段，不能仅由默认 `variant` 推断 clone 或 preview。

### 1.1 档位与能力可用性矩阵

SpeechRail 保存独立的 ASR 与 TTS 规格，默认 `quality/quality`。三个快捷组合只同时填写两项规格，不保存第三份 preset 真相；高级设置可分别调整两项规格。

| spec | ASR | 内置 speaker TTS | 固定自定义 revision TTS |
|---|---|---|---|
| `fast` | 0.6B Q8 | 0.6B CustomVoice Q8 | 0.6B Base Q8 |
| `quality` | 1.7B Q8 | 1.7B CustomVoice Q8 | 1.7B Base Q8 |
| `reference` | 1.7B BF16 | 1.7B CustomVoice BF16 | 1.7B Base BF16 |

> - **能力由有效快照决定**：客户端不能仅凭 spec 名称推断 Alignment、Diarization、VoiceDesign、语言或实时并发已经可用。
> - **辅助能力按任务 opt-in**：VAD、Alignment、Diarization 与 VoiceDesign 不随规格自动开启；VoiceDesign 只在设计作业中运行。
> - **首批组合认证**为三个同档组合和 `ASR quality + TTS fast`；每个组合按实际 TTS 角色分别记录证据。
> - **无历史 alias**：旧 `light`/`balanced`/`extreme`、Q4/Q6、Design runtime voice 与旧 Realtime wire 都明确拒绝。

---

## 2. API 端点全览

| 请求方法 | 路径 | 描述 | 主要参数 / 返回格式 |
|---|---|---|---|
| `GET` | `/health` | 进程存活检查与组件诊断 | 返回各 Worker 进程存活状态与配置信息；`asr_runtime_revision` 仅在 ASR ready handshake 身份完整时出现，`tts_ready` 表示可按需服务，`tts_warm` 表示当前无需加载即可服务，`realtime_vad` 表示 `server_vad` 子能力的独立状态 |
| `GET` | `/readyz` | 推理就绪状态检查 | HTTP 200 只表示 ASR 或 TTS 至少一项可按需服务；响应中的 `realtime_vad` 仍需单独检查，worker 是否驻留请读取 `/health.tts_warm` 与 `/health.tts_state` |
| `GET` | `/metrics` | 运行指标导出 | 默认 Prometheus 文本；`Accept: application/json` 返回结构化视图 |
| `GET` | `/v1/models` | 模型清单与别名路由 | 列出 Canonical 模型名与 `whisper-1` 等兼容别名 |
| `GET` | `/v1/voices` | 注册与自定义的 TTS 音色列表 | 返回系统预置与自建音色全属性及可用性 |
| `GET` | `/v1/voices/{voice_id}` | 读取单个音色详情 | 返回与目录一致的完整 VoiceProfile |
| `POST` | `/v1/voices` | 自然语言创建自定义音色 (Voice Design) | 接收名称与人设描述，固化专属 Seed 并持久化 |
| `PATCH` | `/v1/voices/{voice_id}` | 更新自定义音色 metadata | instruction 音色可改名称、描述、Seed；clone 音色只可改名 |
| `DELETE` | `/v1/voices/{voice_id}` | 删除自定义音色 | 删除指定自建音色（系统预置音色只读保护） |
| `POST` | `/v1/audio/transcriptions` | OpenAI 兼容文件转写（匿名讲话人分离仅在支持分人的档位可用，见 §1.1） | `json`, `verbose_json`, `text`, `srt`, `vtt`, `diarized_json` |
| `POST` | `/v1/audio/speech` | OpenAI 兼容语音合成 | `mp3`(默认), `opus`, `aac`, `flac`, `wav`, `pcm` (24kHz 16-bit Mono) |
| `GET` | `/v1/speechrail/audio/receipts/{receipt_id}` | SpeechRail 完整性回执 | PCM sample count/hash 与终态元数据，不含音频正文 |
| `GET` | `/v1/speechrail/audio/timings/{timing_id}` | SpeechRail 可选 TTS 时间轴 sidecar | 完整合成后返回 chunk 级文本 span ↔ 24kHz PCM sample span |
| `POST` | `/v1/voices/previews` | 不落盘的自然语言音色试听 | VoiceDesign instruction、可选 seed 与音频格式 |
| `POST/GET/DELETE` | `/v1/jobs` | 异步任务 Spool 管理 | 提交长任务元数据、查询状态与取消任务 |
| `WS` | `/v1/realtime` | OpenAI Realtime WebSocket | 实时音频流式转写与合成；讲话人分离通过显式 session opt-in 开启（仅在支持分人的档位可用，见 §1.1） |

`GET /health` 的 `asr_runtime_revision` 只在 ASR worker 已完成 ready handshake 且身份字段完整时
填充 `rt_...`；未驻留、组件未提供 optional resolver 或身份不完整时为 `null`。它是低披露的当前 worker
结构身份摘要，不是模型路径或权重内容哈希；不会触发模型加载。`tts_ready` 保持 v1 兼容含义：TTS 已配置并可按需接收请求；它不承诺权重
当前驻留。新增的 `tts_warm` 为 `true` 时表示 worker 已完成加载握手，可直接产生 PCM，
为 `false` 时表示冷/未配置，注入的 backend 无法报告驻留状态时为 `null`。`tts_state` 提供
`active`、`warm_standby`、`cold_evicted`、`inactive` 或 `unconfigured` 等低基数诊断；冷状态
不会单独把仍可在请求时加载的 `tts_ready=true` 改成 false。

启用完整性回执时，`model.runtime_revision` 只有在首个 PCM 已由 worker 产生且 ready
handshake 提供完整可验证身份后才会填充 `rt_...`；否则保持 `null`。该值是当前加载 worker
的低披露结构身份摘要，不是本地路径，也不把 `shape:` 元数据误称为权重内容哈希；只读能力快照
仍保持 `configured_catalog` / `null`，不会为发现请求启动模型。

---

## 3. 文件转写 API (`POST /v1/audio/transcriptions`)

```http
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
```

### 请求参数表 (Multipart Form-Data)
| 参数名 | 类型 | 必填 | 默认值 | 说明 |
|---|---|---|---|---|
| `file` | Binary | **是** | - | 音频文件（支持 `wav`, `mp3`, `m4a`, `ogg`, `flac`, `webm` 等） |
| `model` | String | 否 | `whisper-1` | 模型名（支持 Canonical ID 或 OpenAI 标准别名） |
| `language` | String | 否 | `auto` | 语言代码（如 `zh`, `en`, `ja`, `auto` 等） |
| `prompt` | String | 否 | - | 专有名词提示文本（最长 2000 字符） |
| `response_format` | String | 否 | `json` | 响应格式：`json`, `verbose_json`, `text`, `srt`, `vtt`, `diarized_json`；后者仅与 `gpt-4o-transcribe-diarize` 配对 |
| `timestamp_granularities[]` | Array | 否 | `["segment", "word"]` | 时间戳精度：`segment`, `word`；须配合 `verbose_json` |

标准 multipart 数组使用重复字段，例如 `timestamp_granularities[]=word`。
旧 `timestamp_granularities` 字段仍可使用；两种写法混用时合并后验证，任一字段中的非法值都会返回
`422 invalid_timestamp_granularities`。只请求 `word` 时返回 `words`，只请求 `segment` 时返回
`segments`；省略粒度时保持同时返回两者。

上传大小仍受 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制；解码输出另受 128 MiB 和
`SPEECHRAIL_MAX_AUDIO_SECONDS` 约束。WAV fastpath 在重采样前检查预计输出，其他容器在
读取 `ffmpeg` 输出时检查，超限即停止处理。取消或解码超时会回收对应子进程；这不构成
`ffmpeg` 自身内存占用的操作系统硬限制。

### 3.1 批量讲话人分离

文件分人使用 OpenAI 原生参数 `model="gpt-4o-transcribe-diarize"` 与
`response_format="diarized_json"`。响应为 `task/duration/text/segments`；每个 segment 有
string `id`、`type="transcript.text.segment"`、`start/end`、匿名 `speaker: "A"…"D"` 与
`text`，不混入 Whisper confidence、内部 slot 或 revision 字段。`stream=true` 返回
`transcript.text.delta`、`transcript.text.segment`、`transcript.text.done` SSE。超过 30 秒的
文件必须提供 `chunking_strategy=auto|server_vad`；known-speaker 参数明确返回
`unsupported_parameter`，SpeechRail 不把匿名标签映射为真实姓名或跨会议身份。

文件分人是**任务级**能力，不由档位继承：需要显式供给外部 CoreML Sortformer bundle 与一个
ForcedAligner（`aligner-q8` 或 `aligner-bf16`），且当前实例 `diarization_ready=true`。
未供给时 `/v1/models` 不声明 `gpt-4o-transcribe-diarize`。在未配置、未就绪或不支持
分人的实例上，请求不会触发模型下载，而是返回 `503 diarization_not_available`。
安装可选依赖、准备仓库外部的绝对权重路径及检查 readiness 的步骤见[运行时部署方案](../operations/runtime-deployment.md)。

---

## 4. 语音合成 API (`POST /v1/audio/speech`)

```http
POST /v1/audio/speech
Content-Type: application/json
```

```json
{
  "model": "tts-1",
  "input": "欢迎使用 SpeechRail 本地语音合成引擎。",
  "voice": "serena",
  "response_format": "mp3",
  "speed": 1.0
}
```

`mp3`、`opus`、`aac`、`flac` 的容器编码具有 15 秒超时和 128 MiB 输出上限。
编码超限或失败返回 `502 audio_encode_failed`；取消请求时回收编码子进程。
`/v1/audio/speech` 与 `/v1/voices/previews` 共享一个由
`SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 定义的绝对总 deadline，覆盖队列准入、worker
生成、首块等待和后续流交付。响应头发送前超时返回 `503 backend_timeout`；响应头发送后
则关闭流并在 access 记录中标记 `outcome=cancelled` 或 `outcome=error`。

worker 已完成准入但生命周期不可用（未启动、启动失败、未就绪或已退出）时，服务返回
`503 backend_busy`，并附带 `Retry-After: 1`、`SpeechRail-Busy-Reason: backend_unavailable`、
`SpeechRail-Retry-Hint: retry_after_worker_recovery`。这些响应只暴露低基数诊断，不返回
worker 的 stderr 或内部异常文本；未知的 TTS 运行时错误仍返回 `502 backend_error`。

标准接口要求 `voice`，同时接受 OpenAI 兼容的字符串形式和 custom voice 对象
`{"id":"voice_1234"}`；对象中的 `id` 进入与字符串 voice 相同的本地解析流程。
质量档 VoiceDesign 可将 OpenAI SDK 的复数 `instructions` 字段作为
一次性音色设计指令传入；该字段不会持久化。CustomVoice 和克隆音色会稳定返回
`400 instructions_unsupported` 或 `400 clone_instruction_unsupported`，不会静默忽略。克隆
音色仅支持 `speed=1.0`，其他值返回 `400 clone_speed_unsupported`。

`seed` 仅用于 VoiceDesign preview 的确定性采样；系统 VoiceDesign 音色使用其
固定 profile seed，CustomVoice 与克隆音色不接受调用方 `seed`。内部 adapter 对这些不支持的
组合返回稳定错误，不以“已接受”暗示参数生效。

### 4.1 SpeechRail 可选准入扩展

普通 OpenAI-compatible `POST /v1/audio/speech` 不携带以下 Header 时，继续使用历史
`batch_tts` 准入语义。需要本地交互调度时，可显式协商：

- `SpeechRail-Purpose: interactive`：映射到现有 `realtime_tts` 保留容量；
- `SpeechRail-Purpose: prefetch`：保持 `batch_tts`，用于可延后预取；
- `SpeechRail-Latency-Budget-Ms: 50..120000`：相对服务预算，最终取该值与
  `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 的较小值。

需要把合成绑定到发现快照时，可同时提供 `SpeechRail-Expected-Voice-Revision: vr_...`
和 `SpeechRail-Expected-Model-Revision: <40-char-hex>`。两者均在首个 PCM 前校验；
model revision 必须等于当前有效 TTS artifact 的 catalog revision，未知或不匹配返回
`409 model_revision_conflict`，不会启动该次合成。未携带这些扩展 Header 的旧请求保持原有
alias/模型选择行为。

### 4.2 跨请求音色一致性控制

推荐客户端先读取一次 `GET /v1/speechrail/capabilities`，选择 `available=true` 的 voice，
再在每个需要一致性的 `POST /v1/audio/speech` 请求中发送：

| Header | 来源 | 失败语义 |
|---|---|---|
| `SpeechRail-Expected-Voice-Revision` | `voices[].voice_revision`，形如 `vr_<32 hex>` | 版本过期或撤销时 `409 voice_revision_conflict` / `voice_revoked` |
| `SpeechRail-Expected-Model-Revision` | `voices[].model.catalog_revision`，40 位 hex | 当前 artifact 未知或变化时 `409 model_revision_conflict` |

服务端会在首个 PCM 前完成比较并占用对应的 voice lease；它不会因 pin 失败而静默改用另一
音色、另一模型或最新 revision。`voice_revision=null` 且 `voice_identity_assurance=legacy`
的条目没有可复制的不可变音色身份，只能按普通可用性路由。revision pin 约束版本绑定，
不等价于跨文本说话人相似度、自然度或长时稳定性的质量验收。

`speechrail-mcp` 对同一流程提供自动化：当 effective snapshot 可用时，`synthesize` 自动
转发上述两个 Header；调用方也可用工具参数 `expected_voice_revision` /
`expected_model_revision` 显式指定。冲突时应重新 `describe()`，由业务决定继续使用旧版、
回滚到历史 revision，还是切换音色。

Realtime 客户端在 `session.update.session.speechrail` 中使用
`expected_asr_revision` / `expected_tts_revision` 绑定计划身份；服务端在 `session.updated`
回显已解析身份，并在首个工作前以 `model_revision_conflict` 拒绝未知或不匹配的 revision。

调用方提交 `speechrail.tts.start` 时携带 `voice_revision` 与
`expected_model_revision`。Native App 和其他需要跨请求音色一致性的客户端应从同一份
effective capability snapshot 读取当前 voice 的 `voice_revision`；revision 缺失时省略 pin，
不能从 voice 名称推断。服务端在该次 utterance 首个 PCM 前校验 pin，冲突或撤销时返回稳定的
`voice_revision_conflict`，不会静默改用另一音色。

客户端不能提交任意 purpose 或绝对时间戳来制造新的优先级。服务仍以同一个
`ResourceGovernor` 为唯一准入源：同一 TTS capability lane 串行，不同 lane 只有在资源预算
允许时并行；实现不承诺对正在运行的 Metal kernel 做硬抢占。Voice creation、quality validation
和 Realtime 会话由服务端内部标记为固定 purpose，不信任客户端把维护任务伪装成更高优先级。
`/metrics` 仅按固定 class/purpose/outcome 暴露 queue-wait、service-time 与释放结果，不记录
请求 ID、文本、音频或 voice ID。

`/metrics` 的结构化 JSON 视图中，`histograms` 的 `speechrail_asr_rtf` 定义为 ASR 推理时长 /
已处理音频时长，`speechrail_tts_rtf` 定义为 TTS 推理时长 / 已生成音频时长。只有分母为正且
存在有效观测时才会出现对应序列；缺失序列表示“未提供”，不是 0，也不能把实时流延迟改名为
RTF。资源快照中的 `physical_memory_bytes`、`memory_budget_bytes` 与完整采样时的
`physical_footprint_bytes` 也保持各自语义，模型磁盘大小不替代内存占用。

`/metrics` 的 TTS 交付计数只使用固定事件标签：`planner_chunk`、参考缓存命中/未命中/淘汰、
`abort_fallback` 与 `reload`。它们用于比较同一 runtime 与 profile 下的实现路径，不含文本、
音色 ID、音频、路径或实际音质结论。

### 4.3 可选 TTS chunk timing sidecar

需要字幕高亮、粗粒度口型或后续对齐的客户端可显式发送：

```http
SpeechRail-Timing-Mode: chunk
```

服务仍先按正常 OpenAI `/v1/audio/speech` 语义返回音频；若 bounded timing registry
接受该请求，响应头额外返回 `SpeechRail-Timing-Id: tm_...`。客户端随后读取：

```http
GET /v1/speechrail/audio/timings/{timing_id}
```

当前只声明 `timing_quality=chunk`，**不声明 word/phoneme/lip-sync precision**。每个 chunk
包含 planner chunk 序号、normalized spoken text 的 Unicode code-point span，以及最终
24 kHz PCM 的 `audio_start_sample/audio_end_sample`。这些音频边界来自实际生成样本累计值，
不是按字符数或平均语速估算；clone loudness/crossfade 路径只改变幅值且保持样本数量，因此
sample domain 与最终 PCM 守恒。

文本坐标分两层：

- 主坐标固定为 `normalized_spoken_unicode_codepoints`；
- `display_start/display_end` 仅在原始 DisplayText 到最终 spoken text 的映射被证明时返回；
- normalization 删除 Markdown/emoji/弱标点或追加句末标点后若无法保持一一坐标，DisplayText
  映射显式为 `unavailable`，对应字段为 `null`，不会伪造位置；
- 使用版本化 pronunciation set 且其 raw→spoken span 可证明时，可返回 `mapped`。

Timing 是**独立资源**，与 #64 render receipt 分离：receipt 证明服务生成/传输边界的完整性，
timing 描述文本与生成 PCM 的内容位置。Timing unavailable、后端未提供 timing metadata 或
timing registry 容量不足均不会把成功的音频合成改判失败。取消/错误请求不会发布
`completed` timing。普通 OpenAI 客户端不发送该 Header 时，不创建 timing 资源。

### 预设音色库 (Preset Voices)

九个 canonical 角色与 Qwen CustomVoice speaker 一一对应：`serena`、`vivian`、
`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。
`default/warm/bright/calm` 与 13 个 OpenAI 标准 voice 名称仍可作为兼容 alias；别名解析与档位
无关，客户端无需上送 profile。能力的**可用性**随当前规格组合和服务 readiness 不同：提示词设计
只在绑定 `voice_design` 的 `reference` 档且快照就绪时可用，参考克隆在绑定 `base` 的档位就绪时
可用，详见 §1.1。

---

## 5. 音色管理与自然语言设计 API (`/v1/voices`)

> **兼容边界**：这一组 `/v1/voices*` 是 SpeechRail 的历史本地管理 API，不冒充
> OpenAI 当前的 `POST /v1/audio/voices`。OpenAI custom voice 创建要求
> `audio_sample + consent + name`，其中 consent 是独立资源。SpeechRail 在没有实现
> 等价 consent 生命周期前，不会把本地 clone/reference API 宣称为该 OpenAI endpoint 的兼容实现。
> 已创建的本地 voice 仍可通过 `/v1/audio/speech` 的字符串或 `{"id": ...}` 形式使用。

SpeechRail 提供系统角色目录与自然语言音色设计（Voice Design）体系。系统角色在三个档位均
可用；自定义 VoiceDesign 音色仅在当前权重声明 `supports_instruction=true` 时可合成。

### 5.1 系统预置音色与采样确定性保证
为了根治大模型短句切流式 TTS 合成时可能出现的**分句换人、跨轮音色漂移**问题，SpeechRail 为每个预置音色绑定了确定的随机种子（Random Seed），并在 MLX 推理前显式调用 `mx.random.seed(profile.seed)`，将生成采样温度固定为 `temperature=0.1`：

| 音色 ID | 名称 | 专属 Seed | 采样温度 | 特征定位与适用场景 | 状态 |
|---|---|---|---|---|---|
| `serena` | 温柔中文女声 | `42` | `0.1` | 温暖柔和的年轻中文女声 | 系统预置（默认、只读） |
| `vivian` | 明亮中文女声 | `1024` | `0.1` | 明亮、略带锋利质感的年轻中文女声 | 系统预置（只读） |
| `uncle_fu` | 醇厚中文男声 | `2048` | `0.1` | 成熟、低沉醇厚的中文男声 | 系统预置（只读） |
| `dylan` | 北京青年男声 | `5120` | `0.1` | 清晰自然的北京青年男声 | 系统预置（只读） |
| `eric` | 成都活力男声 | `6144` | `0.1` | 略带沙哑与四川口音的活力男声 | 系统预置（只读） |
| `ryan` | 动感英语男声 | `7168` | `0.1` | 节奏感强的英语男声 | 系统预置（只读） |
| `aiden` | 阳光美式男声 | `8192` | `0.1` | 中频清晰的美式年轻男声 | 系统预置（只读） |
| `ono_anna` | 轻快日语女声 | `9216` | `0.1` | 轻盈俏皮的日语女声 | 系统预置（只读） |
| `sohee` | 温暖韩语女声 | `10240` | `0.1` | 情感丰富的温暖韩语女声 | 系统预置（只读） |

> 🛡️ **只读保护原则**：系统预置音色标记为 `is_system: true`，禁止通过 API 进行覆盖、修改或删除。

### 5.2 获取音色目录 (`GET /v1/voices`)
```http
GET /v1/voices
Authorization: Bearer <TOKEN>
```
**响应示例**：
```json
{
  "object": "list",
  "data": [
    {
      "id": "serena",
      "name": "温柔中文女声",
      "description": "温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
      "instruction": "温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
      "seed": 42,
      "aliases": ["alloy", "ash", "coral", "default", "echo", "marin", "onyx", "sage", "warm"],
      "is_default": true,
      "is_system": true,
      "created_at": 1788582000.0,
      "available": true,
      "variant": "voice_design",
      "capabilities": {"supports_speaker": false, "supports_instruction": true}
    },
    {
      "id": "custom_1788583825_59b3",
      "name": "知性姐姐",
      "description": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "seed": 12345,
      "aliases": [],
      "is_default": false,
      "is_system": false,
      "created_at": 1788583825.0,
      "available": true,
      "variant": "voice_design",
      "capabilities": {"supports_speaker": false, "supports_instruction": true}
    }
  ]
}
```

### 5.3 自然语言设计与创建音色 (`POST /v1/voices`)
支持使用自然语言描述特征（Prompt）动态创建新音色：
```http
POST /v1/voices
Content-Type: application/json
Authorization: Bearer <TOKEN>

{
  "name": "知性姐姐",
  "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
  "seed": 12345
}
```
**请求参数**：
- `name` (string, 必填)：音色友好展示名称。
- `instruction` (string, 必填)：音色特征自然语言描述（人设、年龄、音质、情绪、语速等）。
- `id` (string, 可选)：自定义音色标识符。若不提供则自动生成 `custom_<timestamp>_<rand>`。
- `seed` (integer, 可选)：`0`–`4294967295` 的确定性采样种子；传入后固定该 recipe，未传入则由服务生成并持久化。

**持久化机制**：创建成功的音色会使用请求提供的 Seed，或由服务自动分配固定 Seed，并持久化保存在用户目录 `~/.speechrail/custom_voices.json` 中，服务重启后依然存在。克隆音频使用受控目录内的不可变文件名（`<voice_id>.<uuid>.wav`）；历史的 `<voice_id>.wav` 引用仍可读取。损坏、不可读或结构非法的 registry 会保留原文件并进入 fail-closed 状态，列表、写入和自定义音色解析返回 `503 voice_store_unavailable`，系统预置音色仍可使用。当服务切到 `base` 角色未就绪或快照缺失的规格组合时，自建音色条目保留但返回 `available=false`，合成请求返回 `400 voice_not_available`；对应角色恢复 ready 后再次可用。

### 5.3.1 读取与更新单个音色 (`GET/PATCH /v1/voices/{voice_id}`)
读取单个音色返回与目录条目相同的完整安全 metadata：
```http
GET /v1/voices/custom_1788583825_59b3
Authorization: Bearer <TOKEN>
```

自定义音色可以原子更新 metadata。instruction 音色支持更新名称、instruction 和 seed；由 VoiceDesign/clone 生成的 reference 音色只支持更新名称，参考音频、`ref_text`、来源证明和 ID 不可替换。标准 `/v1` PATCH 使用无条件更新语义；需要把更新绑定到已知不可变版本时，使用 SpeechRail 专用 `PATCH /v1/speechrail/voices/{voice_id}`，并提供必需的 `expected_revision`，过期版本返回 `409 voice_revision_conflict`：
```http
PATCH /v1/voices/custom_1788583825_59b3
Content-Type: application/json
Authorization: Bearer <TOKEN>

{
  "name": "更新后的知性姐姐",
  "instruction": "更温暖、语速略慢的中文女声。",
  "seed": 2026
}
```

更新成功返回完整的 `VoiceProfile`。系统预置音色、标准 alias 和不存在的音色不可修改；更新失败时当前 registry 记录保持不变。SpeechRail 专用版本更新、rollback 和 revoke 会保留不可变 revision 历史；未带 revision 的现有条目保持 `null`，不会被推断或补写。

### 5.4 删除自定义音色 (`DELETE /v1/voices/{voice_id}`)
```http
DELETE /v1/voices/custom_1788583825_59b3
Authorization: Bearer <TOKEN>
```
- 若删除成功，返回 `{"status": "deleted", "id": "custom_1788583825_59b3"}`；
- 若尝试删除九个系统角色或任一保留 alias，系统返回 `403 Forbidden`；
- 若音色不存在，返回 `404 Not Found`；
- 若音色正在被 TTS 使用，返回可重试的 `409 voice_in_use`，不会修改 registry 或音频；
- metadata 已删除但音频清理失败时返回 `503 voice_store_unavailable`，调用方应保留
  `request_id` 并按运维手册处理受控目录中的残留文件。

### 5.5 在语音合成中使用自定义音色
创建成功后，自建音色的 `id` 可直接传入任何合成接口：
- **REST 试听/合成**：`POST /v1/audio/speech` 中 `{"model": "speechrail/qwen3-tts", "voice": "custom_xxx", "input": "..."}`
- **Realtime 流式会话**：`WS /v1/realtime` 中通过 `speechrail.tts.start` 的 `voice` 与 `voice_revision` 字段传入 `custom_xxx`；会话更新不保存 voice 状态。

### 5.6 不落盘的自然语言音色试听 (`POST /v1/voices/previews`)

该接口仅在当前 TTS artifact variant 为 `voice_design` 且对应服务能力可用时接受请求；当前 catalog 只有 `reference` 档绑定 `voice_design`，且该快照缺失或未就绪时接口不可用。它用于声音工坊在用户保存 VoiceProfile 前试听
一个自然语言音色配方。请求期间的 instruction 和 seed 通过内部类型化 TTS 请求传入 worker；接口
不会创建 VoiceProfile、写入 `custom_voices.json` 或保存音频文件。

```json
{
  "model": "tts-1",
  "input": "你好，这是声音设计试听。",
  "instruction": "温暖自然的中文女声，吐字清晰。",
  "seed": 12345,
  "speed": 1.0,
  "language": "zh",
  "response_format": "wav"
}
```

`instruction` 最长 10000 字符，`input` 最长 4096 字符，`seed` 范围为 `0`–`4294967295`。
支持 `mp3`、`opus`、`aac`、`flac`、`wav` 和 `pcm`；预览接口先在内存中完成生成与编码，
因此后端或编码失败时仍能返回统一错误 envelope。未绑定 `voice_design` 的档位（`fast`、`quality`）
或快照未就绪时返回 `400 voice_preview_unsupported`；预览错误仍包含 `code`、`request_id` 和 `retryable`。

### 5.7 音色克隆与质量门控 (`POST /v1/voices/clone`, `/clone/validate`, `/quality-runs`)

从参考音频 + 脚本文本克隆自定义音色的能力与默认 VoiceDesign 已解耦：reference clone 固定由独立的 Qwen3-TTS Base capability 通过公开 reference-generation 接口执行；Base 与 VoiceDesign 各自独立常驻，空闲冷却后可随 capability group 一起回收并在下一次请求时惰性恢复。VoiceDesign 不作为 clone fallback。当当前组合的 `base` 角色（`tts_clone`）未解析成功或未就绪时，调用返回 `400 voice_cloning_unsupported`。三个接口共用 `VoiceQualityReport` 结构。`reference` 的高精度 bf16 制品继承同族 8-bit 档位的门禁证据，未在本机单独复测；2026-09-12 审计已确认现有 synthesis quality-run 存在假阳性缺口，因此绿色 `status=pass` 暂不能作为跨文本 speaker identity 或纯净度已证明的充分证据。

#### 5.7.1 克隆并注册音色 (`POST /v1/voices/clone`)

与 `POST /v1/voices`（自然语言设计）不同，克隆使用 `multipart/form-data`：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `audio` | binary | 是 | 参考音频（WebM/WAV/MP3 等），最大 15MB |
| `ref_text` | string | 是 | 用户朗读的参考脚本文本，最长 2000 字符 |
| `name` | string | 是 | 克隆音色展示名称，最长 32 字符 |
| `id` | string | 否 | 可选音色标识符，匹配 `^[a-zA-Z0-9_-]{1,64}$` |

- **幂等**：可选 `Idempotency-Key` 请求头用于去重重试。服务在用户目录维护有界、原子写入的 durable journal，记录 `(owner, operation, key_hash, payload_fingerprint)`；同一 key 与不同 payload 返回 `409 idempotency_conflict`，pending/已完成记录在进程重启后仍可见，已完成且结果仍存在时直接 `201` 回放原 `VoiceProfile`，不重复推理。未知的写入结果保持 pending 并 fail-closed，不静默创建第二份音色；journal 不落原始 key、音频或参考正文。音频、`ref_text`、名称或目标 ID 变化都会形成不同 payload，仍可能被 `voice_quality_reject` 拒绝。
- **质量门控**：参考音频通过信号校验后按 `voice_quality_v1` 策略打分；先对上传原始音频分级以尽早拒绝无效输入，再规范化为语音感知归一后的 canonical WAV 并对该 canonical 音频重新分级，持久化的参考资产与 `quality` 报告均描述 canonical 音频（与 `/v1/voice-designs` 同一契约）；canonical 重评结果为 `reject` 时同样返回 `400` 不落库。
  - `status=reject`：拒绝注册，返回 `400`，错误 envelope 为 `{"error": {"code": "voice_quality_reject", ...}, "quality_report": {...}}`（`quality_report` 与 `error` 同级）。客户端以响应体 `error.code` 作为可见的错误码信号；服务端内部通过 `X-SpeechRail-Error-Code` 响应头把错误码交给观测中间件消费，该头在到达客户端前已被中间件移除，不属于客户端可见契约。
  - `status=warn` 或 `pass`：正常注册，`201` 返回的 `VoiceProfile` 携带 `quality` 字段（即该报告，含 `status` 与 `run_id`）。
- **历史音色**：本次架构切换（clone 固定走 Base capability）之前注册的 clone 音色，其已存储的 `voice_quality_v1` 报告描述的是旧合成路径，不代表当前 Base 路径表现；需通过 `/v1/voices/{voice_id}/quality-runs` 重新验证后方可继续作为质量依据。
- 注册写入受控目录失败返回 `503 voice_store_unavailable`（可重试）；注册结构非法返回 `400 voice_creation_failed`。

#### 5.7.2 仅校验不注册 (`POST /v1/voices/clone/validate`)

请求体与 `/v1/voices/clone` 完全一致（同样的 multipart 与档位/字段校验），但不创建也不持久化任何 `VoiceProfile`，不写 `custom_voices.json` 或音频文件。只要通过字段与音频格式校验，无论结果如何都返回 `200` + 完整 `VoiceQualityReport`——包括 `status=reject` 的报告，供调用方在注册前预检。

#### 5.7.3 音色质量探针 (`POST /v1/voices/{voice_id}/quality-runs`)

对已注册音色运行有界质量探针并返回 `VoiceQualityReport`。请求体为 JSON：

```json
{ "probe_set": "voice_quality_v1_zh", "runs": 3, "include_audio": false }
```

- `probe_set`：仅支持 `voice_quality_v1_zh`（默认值，可省略）；其他值返回 `422 validation_error`。
- `runs`：整数，范围 `1..3`（默认 `3`），含义是“每个固定 probe 的重复次数”；6 个内置 probe 始终全部执行，因此默认 `probe_count=18`；越界返回 `422 validation_error`。
- `include_audio`：布尔，默认 `false`。当前未实现内联音频试听，传入 `true` 直接返回 `422 include_audio_unsupported`。
- 探针按 `voice_quality_v1_zh` 的 6 条内置固定脚本逐条合成，完整覆盖自我介绍、短句、长段落、问句、数字标点和停顿；每条重复 `runs` 次。
- 所有 probe 输出必须同时通过格式、非静音、无满幅削波和重复确定性检查；`runs>=2` 时会对同一 probe 的 PCM SHA-256 做重复比较，`runs=1` 不宣称已验证确定性。
- 信号门全部通过后，服务释放 TTS phase，只取 6 类 probe 各自首个有效 PCM，以现有 Batch ASR 顺序回转录并计算归一化字符相似度；该 ASR phase 独立进入 `BATCH_ASR` governor/admission，避免把 Base TTS 与 ASR 变成未经治理的并行重计算。
- `synthesis.transcript_match` 为 6 类 probe 的最小匹配分，当前工程初始门为 `>=0.92 pass`、`0.80..0.92 warn`、`<0.80 reject`；该阈值仍需真实 Apple Silicon 语料校准。ASR 不可用时返回 `status=unevaluated` + `transcription_unavailable`，绝不伪装为通过。
- 合成侧稳定码包括 `probe_failed`、`clone_speed_unsupported`、`output_invalid`、`output_peak_exceeded`、`output_nondeterministic`、`transcript_mismatch`、`transcription_unavailable`。探针模式下 `reference` 为空指标对象，不产生参考侧失败码。
- 音色不存在返回 `404 voice_not_found`；后端未就绪返回 `503 backend_not_ready`（可重试）；registry 不可读返回 `503 voice_store_unavailable`（可重试）。

`/v1/speechrail/voices/{voice_id}/quality-runs` 还返回 `evidence` 命名空间。其
`identity.model.runtime_revision` 只在 TTS worker 已完成 ready handshake 且 probe 已实际产生
PCM 时填充 `rt_...`；worker 未提供完整身份或仅使用 fake/injected backend 时保持 `null`。
TTS eviction 发生在可懂度 ASR 复核前，但不会丢失这份已捕获的 probe 执行身份。

#### 5.7.4 `VoiceQualityReport` 字段语义与缺省值

报告顶层字段：

| 字段 | 说明 |
|---|---|
| `policy_version` | 门控策略版本，当前固定 `voice_quality_v1` |
| `status` | `pass` / `warn` / `reject` / `unevaluated`。当输出信号有效但独立 ASR 可懂度证据不可获得时，`quality-runs` 会显式下发 `unevaluated`，客户端不得把它当作 pass |
| `run_id` | 本次质量运行的唯一标识 |
| `tested_at` | 测试时间（ISO 8601 UTC） |
| `reference` | 参考音频信号指标（时长、采样率、声道、语音活动比、底噪、SNR、削波比、首尾静音；`transcript_match` 始终为 `null`，因为实现未启用 ASR 文本匹配，从不计算该分数） |
| `synthesis` | 合成输出指标（`probe_count`、`successful_probe_count`、`active_rms_dbfs`、`peak_dbfs`、`chunk_jump_p95_db`、`clipping_ratio`、`deterministic`、`transcript_match`、`intelligibility_evaluated`） |
| `failure_codes` | 失败/未评估原因数组。参考侧：`audio_too_short`、`low_snr`、`high_noise_floor`、`clipping`、`transcript_mismatch`；合成侧：`probe_failed`、`clone_speed_unsupported`、`output_invalid`、`output_peak_exceeded`、`output_nondeterministic`、`transcript_mismatch`、`transcription_unavailable` |

**字段语义**：`VoiceProfile.quality` 仅在克隆音色（或已评估音色）上出现；系统预置音色、`POST /v1/voices` 创建的音色及未执行质量评估的记录可能不携带该字段。消费端应将缺失的 `quality` 字段视为“未评估”（等同 `unevaluated`），不要假定通过。新版 `quality-runs` 也会在独立 ASR 证据不可获得时显式返回 `status=unevaluated`。

---

## 6. Realtime current-only WebSocket (`WS /v1/realtime`)

连接端点：`ws://127.0.0.1:8201/v1/realtime`。唯一机器 schema 与共享 fixtures 位于
[`contracts/realtime-events.schema.json`](../../contracts/realtime-events.schema.json) 和
`tests/fixtures/realtime-current/`。本节与它们必须同批更新；没有旧事件翻译、双 wire profile
或 `/v2` 迁移层。

### 6.1 音频与会话

- wire 输入固定为 24 kHz mono PCM16 little-endian；服务端边界有状态转换到 16 kHz ASR 内核。
- 唯一会话配置事件为 `session.update`，方向客户端 → 服务端。配置位于
  `session.audio.input`，而非旧平铺字段。
- `audio.input.turn_detection` 仅接受 `null` 或 `"manual"`；服务端 VAD 使用
  `session.speechrail.endpointing.mode="server_vad"`。
- `session.speechrail.task` 选择 `conversation`、`caption`、`transcription`、`render` 或
  `voice_design`；Alignment、Diarization 按请求 opt-in。
- 更新成功返回 `session.updated`。失败不半应用配置；未知字段、旧字段、Q4/Q6、Design runtime
  voice 和未实现官方 VAD 都返回稳定错误。

```json
{
  "type": "session.update",
  "event_id": "evt_1",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {"model": "speechrail/qwen3-asr-1.7b"},
        "turn_detection": null
      }
    },
    "speechrail": {"task": "caption", "alignment": {"enabled": false}}
  }
}
```

### 6.2 事件列表

| 事件名称 | 方向 | 说明 |
|---|---|---|
| `input_audio_buffer.append` | 客户端 → 服务端 | 追加 Base64 24 kHz PCM16 |
| `input_audio_buffer.commit` | 客户端 → 服务端 | 一个 utterance 只产生一个 ASR final |
| `input_audio_buffer.clear` | 客户端 → 服务端 | 丢弃未提交 PCM，不产生 final |
| `speechrail.tts.start` | 客户端 → 服务端 | 绑定 request/task/voice/revision/limits |
| `speechrail.tts.append_text` | 客户端 → 服务端 | 连续 sequence 的不可变稳定文本 |
| `speechrail.tts.finish_text` | 客户端 → 服务端 | 以最后 ACK sequence 关闭文本侧 |
| `speechrail.tts.cancel` | 客户端 → 服务端 | 取消匹配 utterance，取消优先 |
| `speechrail.tts.started` | 服务端 → 客户端 | 回显 task/plan/request、voice revision、PCM 格式与生效 limits |
| `speechrail.tts.text_accepted` | 服务端 → 客户端 | 精确 ACK `append_sequence` 与 codepoint 计数 |
| `speechrail.tts.audio.delta` | 服务端 → 客户端 | 唯一 TTS 音频块事件，携带 chunk/sample offset |
| `speechrail.tts.completed/cancelled/failed` | 服务端 → 客户端 | 每次 utterance 恰好一个 SpeechRail terminal |
| `speechrail.transcription.hypothesis` | 服务端 → 客户端 | 可修订全文；不能当作 append-only delta |
| `speechrail.alignment.done/failed` | 服务端 → 客户端 | 独立辅助终态，不改写 ASR final |
| `speechrail.diarization.updated/done/failed` | 服务端 → 客户端 | session-scoped 匿名归属元数据 |

### 6.3 ASR final 与辅助结果

一个 utterance 恰好一个 `conversation.item.input_audio_transcription.completed`。hypothesis 的
`revision` 递增，只有已证明稳定前缀才能映射到官方 delta。Alignment 和 Diarization 携带
`task_id`、`epoch`、`utterance_id`、`transcript_revision` 与 `metadata_revision`；迟到、旧 epoch、
旧 revision 或取消后的结果必须丢弃。辅助失败不会把已发出的 final 改成失败。

### 6.4 增量 TTS

```text
speechrail.tts.start -> speechrail.tts.started
speechrail.tts.append_text* -> speechrail.tts.text_accepted*
speechrail.tts.audio.delta*
speechrail.tts.finish_text -> speechrail.tts.completed | speechrail.tts.failed
speechrail.tts.cancel -> speechrail.tts.cancelled
```

- `sequence` 是 append 序号，从 0 连续递增；每个事件的 `sequence` 是连接级序号，两者不同义。
- 追加不重新 prepare reference、不重建 utterance；一轮只初始化一个 worker utterance。
- `finish_text.last_sequence` 必须等于最后 ACK；音频队列满不能阻塞 cancel/terminal。
- 身份 pin、参考条件缓存和验证记录按 artifact/engine/precision/tokenizer/codec/preprocessing 隔离。
- `response.output_audio.delta`、`response.done`、`speechrail.tts.create` 和
  `response.output_audio_transcript.*` 都是明确拒绝项，不提供 alias。

完整字段行为表由 [`contracts/realtime-field-matrix.json`](../../contracts/realtime-field-matrix.json)
锁定；运行校验入口为 `scripts/check_realtime_contract.py` 与共享 Python/Swift fixtures。

---

## 7. 统一错误 Envelope 与状态码

所有 HTTP 接口的非 2xx 响应严格遵循统一的错误结构体：

```json
{
  "error": {
    "message": "The uploaded audio format could not be decoded.",
    "type": "invalid_request_error",
    "code": "audio_decode_failed",
    "request_id": "req_01j6zabc1234",
    "retryable": false
  }
}
```

### 标准错误码速查表
| HTTP 状态码 | Error Code | 是否可重试 (`retryable`) | 常见原因与处理建议 |
|---|---|---|---|
| **400** | `model_not_found` | `false` | 请求的模型名不存在，核对 `/v1/models` 清单 |
| **400** | `audio_too_long` | `false` | 音频时长超出 `SPEECHRAIL_MAX_AUDIO_SECONDS` 限制 |
| **400** | `voice_quality_reject` | `false` | 克隆参考音频未通过 `voice_quality_v1` 门禁（详见 §5.7），响应同级的 `quality_report` 含失败原因 |
| **401** | `invalid_api_key` | `false` | 未提供有效的 API Key 或 Token 错误 |
| **413** | `audio_too_large` | `false` | 音频大小超出 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制 |
| **500** | `dependency_missing` | `false` | `ffmpeg` 等外部依赖缺失导致转码失败（克隆/校验路径），配置依赖后重试 |
| **422** | `audio_decode_failed` | `false` | 上传文件损坏或非标准音频容器，检查文件有效性 |
| **429** | `queue_full` | `true` | 当前并发超出 Governor 配额，按 `Retry-After` 重试 |
| **409** | `voice_in_use` | `true` | 自定义音色仍有活动 TTS 读者，等待当前合成完成后重试删除 |
| **403** | `voice_update_unsupported` | `false` | 系统音色或 clone 音色的不可变来源字段不能修改 |
| **400** | `voice_update_failed` | `false` | 音色更新字段不符合校验规则，修正名称、instruction 或 seed 后重试 |
| **503** | `backend_not_ready` / `backend_busy` | `true` | 对应模型 Worker 尚未启动、预检未通过或正在恢复；`backend_busy` 的 worker 生命周期错误附带 `SpeechRail-Busy-Reason: backend_unavailable` 与 `SpeechRail-Retry-Hint: retry_after_worker_recovery`，不暴露 worker stderr |
| **503** | `backend_timeout` | `true` | 队列准入、worker 生成或音频交付超出总 deadline，减小音频分块 |
| **503** | `voice_store_unavailable` | `true` | 自定义音色 registry 或音频存储不可读/不可写，先保留原文件并按手册修复 |


## 生成参考并发布新的 Base 音色

`/v1/voice-designs` 是 SpeechRail 专用的候选生命周期接口。候选创建只要求当前选择提供
VoiceDesign 与本地 Batch ASR；Base 能力只在 `validate`/`publish` 阶段要求。候选不会出现在
`/v1/voices`，不会改变 `/v1/voices` 仅保存提示词的语义，也不改变录音上传的
`/v1/voices/clone`。

### 1. 创建候选 (`POST /v1/voice-designs`)

```json
{
  "voice_id": "narrator_base",
  "name": "Narrator",
  "instruction": "清晰自然的中文声音，表达平稳。",
  "reference_text": "请用自然清晰的声音朗读这段参考文字，保持平稳的语气和适中的节奏。",
  "seed": 42,
  "language": "zh"
}
```

`voice_id` 必须为新的小写字母、数字、下划线或连字符组合（1–64 字符），不得使用系统
ID/alias；`name` 1–64 字符；`instruction` 1–10000 字符；`reference_text` 20–240 字符；
seed 为 0..2^32−1 的整数，默认 42。当前仅支持 `language=zh`，不接受 URL、参考音频、
速度控制或其他额外字段。

201 响应包含安全的 `candidate` 元数据，不含参考正文或私有路径；参考质量仍标明
`probe_count=0`。可选 `Idempotency-Key` 在成功后可回放原候选，不重复生成；
同一 key 复用不同请求返回 409 `idempotency_conflict`。

### 2. 确认候选 (`POST /v1/voice-designs/{candidate_id}/confirm`)

服务重新转写已保存的规范参考，并要求与（可选编辑的）`reference_text` 相似度达标。
编辑参考文本会产生新的 candidate revision 并清除旧验证，不能复用旧证据。

### 3. Base 复验与人工听审 (`POST /v1/voice-designs/{candidate_id}/validate`)

机器模式必须使用不同于参考文本的 `test_text`（省略时服务选择受控文本），并由目标
Base 角色重新合成、质检、转写且绑定 runtime identity。机器数值不会把
identity/naturalness 标为通过。人工模式在机器通过后通过 `human_review` 附加实际听审结论；
不能由自动指标代替。

### 4. 发布 (`POST /v1/voice-designs/{candidate_id}/publish`)

只有当前 revision 同时具备完整机器通过和人工 identity/naturalness 通过时才能发布。
201 响应包含已发布 `candidate` 与标准 `voice`（mode=clone、variant=base）；重复发布同一
candidate 返回 200 且不会创建第二个 revision。目标 ID 无 revision 冲突时原子 create-only；
失败或取消保留私有候选，不影响已有音色。

语料质量与声纹稳定性尚需实机校准；详见[生成式音色注册架构](../architecture/generated-voice-registration.md)。
