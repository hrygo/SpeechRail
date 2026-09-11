---
title: "SpeechRail MCP Proxy 工具与契约"
status: active
audience: "系统架构师、协议设计者、agent 集成方"
version: "1.2.0"
date: 2026-09-11
supersedes: "docs/architecture/speechrail-mcp-proxy-draft.md (v0.2.0)"
---

# 🎙️ SpeechRail MCP Proxy 工具与契约 (v1.2.0)

> **状态声明**：本文档描述**已实现**的外置 `speechrail-mcp` 进程（合并于 `feat/speechrail-mcp`，
> PR #15，2026-09-07）。当前行为以 `src/speechrail/mcp/` 代码与实测为准；REST 契约仍以
> `contracts/openapi.yaml` 为唯一事实来源。本文档记录 MCP 工具清单与设计取舍。
>
> **v1.2.0 变更**（2026-09-11，MCP 2026-07-28 最佳实践升级）：
> - **serverInfo** 补齐 `title`/`description`/`version`（`version` 取自 `speechrail.__version__`，不再是空串）；
> - **9 工具全部带 `title` 与 `ToolAnnotations`**（`read_only_hint`/`destructive_hint`/`idempotent_hint`，`open_world_hint` 恒为 `false`），
>   `delete_voice`/`cancel_job` 标记为破坏性；
> - **结构化输出**：每个工具的 `outputSchema` 由其返回的 Pydantic 结果模型派生并校验，同时发出 `structuredContent`
>   （模型 `extra="allow"` + 可选字段默认值，未知键/缺字段不会让工具调用失败）；
> - **cache hints**：`tools/list`、`prompts/list`、`resources/list` 配置 300000ms `public` 提示（三者均为静态元数据）；
>   `resources/read` 不缓存（内容随档位动态变化）；
> - **read-only resources**：新增 `speechrail://capabilities`、`speechrail://voices`、`speechrail://models`（同一 REST client，JSON）；
> - **progress**：`transcribe`、`synthesize`、`get_job` 注入 `Context` 并发起进度通知（`ctx` 不出现在输入 schema）；
>   `get_job` 只报 started/done（daemon job 响应无数值进度）；
> - 参数带 `Annotated[..., Field(description=...)]`，工具名/参数名/必填性/工具数完全不变。
>
> **v1.1.0 变更**（2026-09-10）：
> - **新增** `create_voice` / `delete_voice`（`POST /v1/voices` / `DELETE /v1/voices/{id}` 的透传），
>   闭环 preview → persist → synthesize；创建不限档位、可用性随档位声明；
> - `preview_voice` 文档补 VoiceDesign 指令写法指引（中英文、维度、禁模仿真人）；
> - REST `instructions` 上限 100000 → 10000，与 `SpeechRequest`/preview 对齐，超限走稳定 422。
>
> **v1.0.0 状态演进** —— 自 v0.2.0 草案实现后的收敛（与代码核对）：
> - 状态从 `draft` 提升为 `active`；实现采用**无状态**设计（`describe()` 每次实时查询
>   daemon、不缓存；`instructions` 为静态文案，能力发现走 `describe()` 工具）；
> - `audio_ref` 收敛为**本地 path / `file://`**（`BlobResourceContents` 兜底未实现，且显式
>   拒绝远程 URL，见 §8.1）；
> - transport 提供 `stdio`（默认）+ `streamable-http`（可选，见 §9）；
> - `preview_voice` 未做节流（单机本机使用，保持简单，见 §9）。
>
> **v0.2.0 修订记录**（经 Metis 预实施评审）：
> - **合并** `list_models` + `list_voices` → 单一 **`describe()`** 工具；
> - **移除** MRTR / `requestState` / `input_required`（对 agent 是打断而非辅助）；
> - **恢复** `preview_voice`（quality-only，代理强制），避免能力静默丢失；
> - **Tier 从"广告"升级为"硬强制"**（工具层拒绝而非 prose 建议）；
> - **`audio_ref` 传输契约明确化**（path-first）；
> - **修正事实**：9 个系统音色在**所有档位**可用；仅**用户自建 clone 音色**在
>   `balanced/light` 不可用（原 v0.1 "2/9 为 clone 类"表述有误）；
> - per-tool 授权矩阵降为**附录 B**（运维安全，非工具契约核心）。

---

## 1. 目标与范围

### 1.1 北极星（唯一成功标准）

> **MCP 增强的唯一目标：让 agent 使用 SpeechRail 更容易、更精准。**

| 维度 | 含义 | 度量 |
|---|---|---|
| **更容易** | 少填参数；不用学协议枚举（`response_format`/`timestamp_granularities`）；不被确认弹窗打断；不把音频灌进 context | agent 完成任务所需的调用数 / 参数数 / 上下文消耗 |
| **更精准** | 选对档位能力、选到可用音色、输出形状正确；绝不因选错而拿到 `voice_not_available` / 错误转写形状 | 误选率 / 错误返回率 |

### 1.2 为什么做

SpeechRail 已是 OpenAI-compatible REST + WS。对 agent 而言它是"能调用的语音机器"，但 agent
无法一次得知该选哪档/哪音色/能否克隆，也无法把长任务/试听编排进工作流。MCP 2026-07-28 的
`server/discover`（能力自描述）、可缓存 list、显式状态句柄（`job_id`）为此提供载体。

### 1.3 不做什么（边界，不可越界）

- ❌ **不替换 `/v1/realtime`** 实时全双工 WebSocket（VAD / barge-in / 逐句 TTS / `speechrail.diarization.v1` 分人流）。
  实时音频仍由 Sona 等客户端经 WS 直连。
- ❌ **不引入说话人实名、声纹库、LLM 上下文、会议持久化** —— 调用方职责（`product-scope.md` 红线）。
- ❌ **不把 MCP 内建进主服务进程** —— 主服务只做协议接入与调度。
- ❌ **不接收 base64 内联音频、不落盘、不记录** 原始音频/Base64/完整转写。
- ⚠️ **voice-design 试听（`preview_voice`）保留**为 quality-only 工具（代理强制），不作为普通工具暴露。

---

## 2. 架构形态（方案 A：外置 Proxy）

```mermaid
flowchart LR
    Agent["AI Agent\n(Claude / Open-WebUI / Cursor / 任意 MCP 客户端)"]
    Proxy["speechrail-mcp (外置进程)\nstdio 或 HTTP Streamable\n由工具调用 / 能力发现"]
    Rail["SpeechRail 主服务 (FastAPI :8201)\nOpenAI-compatible REST\nloopback keyless 或可选 Bearer"]

    Agent <-->|"MCP 2026-07-28\n(stateless / discover)"| Proxy
    Proxy <-->|"REST；配置 API key 时 Authorization: Bearer\\nPOST /v1/audio/* ..."| Rail
```

- Proxy 是**独立进程**，把 MCP 工具调用翻译成 REST 调用；服务配置 API key 时才携带 `Authorization: Bearer`，keyless loopback 保持零配置可用。
- **不内建** MRTR/session 管理进主进程。
- Transport：**stdio 优先**（本机），可选 HTTP Streamable（供 Open-WebUI 原生 HTTP MCP 直连）。

---

## 3. `server/discover`（能力自描述）

Proxy 对 `server/discover` 返回统一的 capabilities 与 `instructions`。`instructions` 是给 LLM 的
自然语言指导，**应以"agent 现在能做什么、该怎么选"为中心**，而非协议向自我介绍。

```jsonc
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "result": {
    "resultType": "complete",
    "supportedVersions": ["2026-07-28"],
    "capabilities": { "tools": { "listChanged": false }, "resources": { "subscribe": false, "listChanged": false } },
    "_meta": { "io.modelcontextprotocol/serverInfo": { "name": "speechrail-mcp", "version": "1.0.0" } },
    "instructions": "…（静态文案：先 describe() 看档位与可用音色；音频用 audio_ref 本地路径，禁 base64；长请求走 create_job+get_job；忙时退避重试；实时音频走 /v1/realtime。）"
  }
}
```

> `instructions` 是**静态常量**（`server.py` 的 `_INSTRUCTIONS`），不随 profile 动态变化；**动态能力发现
> 走 `describe()` 工具**（实时读 `GET /v1/models` + `GET /v1/voices` + `GET /health`）。上方示例仅示意响应
> 结构；实际 `discover` 由 MCPServer SDK（MCP Python SDK v2）生成。能力快照内容（`describe()` 的实时查询与
> `resources/read`）**不缓存**；仅 `tools/list`、`prompts/list`、`resources/list` 配置 `ttlMs`/`cacheScope`
> 提示（三者均为静态元数据），且只在
> 2026-07-28 无状态 era 下随响应下发（见 §11）。

---

## 4. 工具清单

> 全部工具执行时 Proxy 携带 `Authorization: Bearer <key>`（本机 keyless 时任意占位）。
> 输入音频一律用 **`audio_ref`**，**禁止 base64 内联**（见 §8 传输契约）。

### 4.1 `describe()` —— 单一能力快照（合并 `list_models` + `list_voices`）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `--` | — | — | 无参数 |

- **Proxy 调用**：`GET /v1/models`（`system.py:170`）+ `GET /v1/voices`（`system.py:226`）。
- **返回**：当前档位 + 能力摘要 + 音色清单（含精准判别字段）。

```jsonc
{
  "tier": "quality",
  "profile": "quality",
  "diarization_ready": false,          // 是否已安装/就绪（决定 diarize 是否可用）
  "clone_supported": true,             // quality&voice_design → true
  "preview_supported": true,           // quality&voice_design → true
  "models": [{ "id": "...", "variant": "voice_design", "capabilities": { "supports_preview": true, "supports_clone": true } }],
  "voices": [{ "id": "serena", "variant": "voice_design", "mode": "system", "is_default": true, "available": true,
               "capabilities": { "supports_speaker": false, "supports_instruction": true, "supports_clone": false } }]
}
```

- **精准作用**：agent 只从 `available=true` 的 voices 选择；`mode`（`system|instruction|clone`）区分
  "永远可用 preset" vs "跨档脆弱 clone"；`is_default`（`serena`）让 agent 可完全省略 `voice`。
- **传输**：无缓存（无状态设计）——每次调用实时查询 daemon，不携带 `ttlMs`/失效信号。

### 4.2 `transcribe`

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `audio_ref` | string | 是 | 音频文件路径或 `file://` URI（**禁 base64**） |
| `language` | string | 否 | ISO 639-1；缺省自动检测 |
| `diarize` | bool | 否 | 默认 false；true → `diarized_json` 形状。**需 `diarization_ready=true`** |
| `timestamps` | bool | 否 | 默认 false；true → `verbose_json` 形状（含 segment/word）。仅非 diarize 时生效 |

- **Proxy 调用**：`POST /v1/audio/transcriptions`（`audio.py:677`）。
- **输出形状**（在工具 schema 声明）：
  - 默认 `{text}`（纯文本，多数 agent 需要）；
  - `timestamps:true` → `{text, segments:[{start,end,text}], words?}`；
  - `diarize:true` → `{segments:[{speaker,start,end,text}]}`。
- **前置检查**：`diarize=true` 但 `diarization_ready=false` → 返回结构化错误（"diarization 引擎未安装，先 `uv sync --extra diarization`"），非盲报上游 400。
- **`timestamps` 隐含**：强制走 `verbose_json`，绝不自降为 `json`（`timestamp_granularities` 仅在 `verbose_json` 下有意义，`openapi.yaml:838-848`）。

### 4.3 `synthesize`

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `text` | string | 是 | 待合成文本（≤4096） |
| `voice` | string | 否 | 缺省 `serena`；必须来自 `describe().voices` |
| `output_format` | string | 否 | `mp3`（默认）/ `wav` / `pcm` |
| `speed` | number | 否 | 0.25–4.0 |

- **Proxy 调用**：`POST /v1/audio/speech`（`audio.py:1144`）。
- **Tier 硬强制**：`voice` 对应 `mode=clone` 或 `supports_instruction`，而当前档位非 `quality`
  → **直接拒绝**（镜像后端 `resolve_binding` 的 ValueError，`system.py:93-95`），并引导：
  *"当前档位 `balanced` 不支持此 voice；调 `describe()` 选 `available=true` 的音色，或切换档位。"*
- **输出**：二进制音频。写入临时文件并返回 `audio_path`（与 `docker-talkies`/`voice-mcp` 先例一致，
  便于 host 播放/发包）。临时文件用后由调用方删除，Proxy 不缓存。

### 4.4 `preview_voice`（恢复，quality-only）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `instruction` | string | 是 | VoiceDesign 音色指令（自然语言描述） |
| `text` | string | 是 | 试听文本 |

- **Proxy 调用**：`POST /v1/voices/previews`（`audio.py:1010`，`extra="forbid"`）。
- **仅 `quality` 档**。非 quality → 结构化错误：*"试听需 `quality` 档（voice_design）；当前档位不支持。可用 `describe()` 确认。"*
- **作用**：让 agent 先试听再选音色，是"精准选择"的关键能力——**不作为普通工具暴露**，仅 quality 档可用。
  试听是 ephemeral（不落库）；选定后调 **`create_voice`** 持久化（见 §4.5），再按 id `synthesize`。
- **指令写法**：中/英文、30–200 词；覆盖 gender/age/pitch/speed/emotion/characteristics/use-case；
  描述声音特质、不模仿真人、不写矛盾维度与 `nice`/`normal` 类模糊词。同指令多次生成可能略有差异，
  先复听再改词。

### 4.5 `create_voice` / `delete_voice`（持久化指令音色，闭环 preview → synthesize）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | 显示名（≤200） |
| `instruction` | string | 是 | 已试听的 VoiceDesign 指令（≤10000，中/英文，写法同 §4.4） |
| `voice_id` | string | 否 | 稳定 id（`^[a-zA-Z0-9_-]{1,64}$`，小写归一；缺省服务端分配） |
| `seed` | integer | 否 | 0–4294967295，用于可复现合成 |

- **Proxy 调用**：`POST /v1/voices` / `DELETE /v1/voices/{id}`（`system.py:484` / `:860`）。
- **档位语义**：创建不限档位；非 quality 档下新建音色 `available=false`，切回 quality 自动恢复。
  `delete_voice` 只需 `voice_id`。

### 4.6 `create_job` / `get_job` / `cancel_job`（可选长任务句柄）

| 工具 | 参数 | 说明 |
|---|---|---|
| `create_job` | `kind`（`transcription`\|`speech`）、`input_ref`（≤1000）、可选 `params` | `POST /v1/jobs`（`jobs.py:49`）；返回 `job_id`（`^job_[a-f0-9]{32}$`） |
| `get_job` | `job_id` | `GET /v1/jobs/{id}`（`jobs.py:66`）；`state ∈ {queued,running,completed,failed,cancelled,expired}` |
| `cancel_job` | `job_id` | `DELETE /v1/jobs/{id}`（`jobs.py:83`） |

- **定位**：**可选增益，非预教要求**。`transcribe`/`synthesize` 优先同步；仅当同步返回
  `backend_timeout`/`audio_too_long` 时，结构错误提示 *"长请求请调 `create_job`（同 `input_ref`）并轮询 `get_job`"*。
  agent 按需学，不在前置里塞。
- **`job_id` 是 SpeechRail 唯一现成的无状态显式句柄**，是 MCP SEP-2567 推荐的"显式状态句柄"模式。
- 长转写/合成（超 `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 默认 120s）走 `create_job`。

---

## 5. 资源映射（read-only resources）

当前注册**三个**只读资源，全部复用与工具相同的 `SpeechRailClient`，返回 `application/json` 文本：

| MCP 资源 | 对应 REST | 说明 |
|---|---|---|
| `speechrail://capabilities` | `GET /v1/models` + `GET /v1/voices` + `GET /health` | 与 `describe()` 等价的合并能力快照 |
| `speechrail://voices` | `GET /v1/voices` | `{"data": [...]}` 原始音色列表 |
| `speechrail://models` | `GET /v1/models` | `{"data": [...]}` 原始模型列表 |

> 注：**主要的"选能力"入口仍是 `describe()` 工具**（带 `mode`/`available`/`is_default` 等判别字段），
> 资源仅作原始读。三个资源经统一 helper 处理 REST 失败：`SpeechRailError` 映射为 MCP `ResourceError`
> 并保留原始消息。`resources/list` 作为静态元数据可缓存；`resources/read` **不设** cache hint（内容随档位动态变化）。
> MCP `Annotations` 无 readOnlyHint 字段；资源在协议层即只读，这里以 `audience=["user","assistant"]` 标注。
>
> **已知 SDK 限制**：MCPServer 总会注册 prompt handler，因而 `prompts` 能力会被广告为一个空能力，
> 当前 MCP Python SDK v2 **没有受支持的关闭方式**；proxy 不通过私有 API 篡改 handler，而是维持现状。

---

## 6. 错误 / 重试语义（映射到 MCP tool error）

SpeechRail 内置全局三闸门：Resource Governor（容量/class queue）+ AdmissionQueue（token 池）
+ AsrModeGate（batch/streaming 互斥）。任一命中返回 **429**，`code ∈ {queue_full, backend_busy}`，
`retryable=true`，`Retry-After: 1`（`audio.py:919-957`）。Proxy 映射为 MCP **tool error**（`isError=true`）：

| SpeechRail code | 语义 | MCP 处理 |
|---|---|---|
| `backend_busy` | 共享 worker 忙 / streaming 会话达上限 | `{code:"backend_busy", retryable:true}` → 退避后重试（1s 起），**勿死循环** |
| `queue_full` | 有界队列 / governor class 满 | `{code:"queue_full", retryable:true}` → 同上 |
| `audio_too_long` | 超 `SPEECHRAIL_MAX_AUDIO_SECONDS`（默认 3600） | `{code:"audio_too_long", retryable:false}` → 截断 / 走 `create_job` |
| `audio_too_large` | 超 `SPEECHRAIL_MAX_UPLOAD_BYTES`（默认 512MB） | `{code:"audio_too_large", retryable:false}` → 换引用 |
| `model_not_found` | 未登记模型 | `{code:"model_not_found", retryable:false}` → 调 `describe()` |
| `voice_not_found` / `voice_not_available` | 音色未知 / 档位不支持 | `{code:"voice_not_available", retryable:false}` → 调 `describe()` 选 `available=true` |

> **关键**：MCP 工具层重试必须**退避**，不能撞穿单机 `backend_busy` 边界——SpeechRail 是单机共享，
> agent 爆发会拖累所有调用方。

---

## 7. 明确不在本版实现（决策记录）

### 7.1 移除 MRTR / `requestState` / `input_required`
原 v0.1 用 MRTR 承载"中途确认弹窗"。**已移除**——向 agent 弹窗是要它做服务端判断，是打断而非辅助。
agent 自己能判断（如"非 quality 档"→ 它直接改用其它音色）。若后续确有需要（如语音克隆需上传参考音频），
改为**更自然的工具形态**（如 `create_clone(audio_ref, ref_text, ...)`），而非协议级的 `input_required`。

### 7.2 WS `/v1/realtime` 不做 MCP handle
`OpenAIRealtimeSession`（`application/realtime_openai.py:80-169`）是 connection-scoped、不可重入。
本版**不暴露**它为 MCP 句柄，仅暴露 `job_id`；实时全双工留给 WS 客户端直连。避免"agent 管一个实时会话"的复杂。

### 7.3 per-tool 授权矩阵 → 附录 B
SpeechRail 授权是二进制 Bearer，无 scope 分级（一个 key 解锁全部受保护工具）。MCP 层的
per-tool 授权矩阵属**运维安全**，降为附录 B。

---

## 8. 授权 / 隐私 / 传输契约

### 8.1 `audio_ref` 传输契约

| 场景 | 传输方式 | 说明 |
|---|---|---|
| stdio / host-local | **path-first**（`file://` 或裸路径） | Proxy 直读本机文件系统 |
| 远程 URL（`http`/`https`/`ftp`/`s3`/`gs`） | **拒绝**（`remote_audio_unsupported`） | 不读远程 URL（隐私边界，`tools._resolve_local_audio`） |
| 任何情况 | **base64 拒绝** | 教学错误：*"base64 不接受；传 path 或 file:// URI，让音频不进入你的 context。"* |

- **base64 是 generation-time 事件**（一旦进 args 已在 context），故**在工具 schema 描述 + `instructions` 防**，
  再在 call-time 拒绝作为恢复信号，而非唯一防线。
- **隐私**：全内存、不落日志（`openapi` 明示 request_id/content 不入日志）；唯 voice-clone 落盘
  `~/.speechrail/voices/`（`0600`）。Proxy 不缓存音频、不记录文本/音频/凭证。

### 8.2 授权
- Proxy 的 `Authorization: Bearer <key>` 由 `_resolve_api_key()`（`server.py:75`）解析，**优先级**：
  1. `SPEECHRAIL_API_KEY` 环境变量（最高）；
  2. **自动发现**：SpeechRail app home 的 `config/.env`（`SPEECHRAIL_APP_HOME` 可覆盖，默认
     `~/Library/Application Support/SpeechRail`）；
  3. 均无 → keyless（本机 loopback 免 key）。
- **零配置**：本机服务已配置 key 时，`speechrail-mcp` 启动即自动从 `config/.env` 读取并鉴权，无需手动设
  `SPEECHRAIL_API_KEY`；keyless 本机连接也无需填占位符。
- 其余环境变量：`SPEECHRAIL_BASE_URL`（默认 `http://127.0.0.1:8201`）、`SPEECHRAIL_MCP_TIMEOUT_SECONDS`、
  `SPEECHRAIL_MCP_TRANSPORT`（`stdio|streamable-http`）。
- `allowed_origins` 已定义但**无 CORSMiddleware 实例化**（`config:66`，全库仅定义无引用）——若 Proxy 走
  HTTP Streamable 对外，需在 Proxy 侧自行处理 origin 策略，**不能依赖主服务**。

---

## 9. 实施决策记录（v1.0.0）

1. **`describe()` 无缓存**：采用无状态设计，每次调用实时读 daemon；不做 `ttlMs`/`cacheScope` 缓存
   与失效信号（单机场景缓存收益低，且避免失效复杂度）。
2. **`preview_voice` 不节流**：单机本机使用，保持简单；若未来对外暴露再考虑节流。
3. **transport 已提供**：`stdio`（默认，host-local 客户端）+ `streamable-http`（可选，经
   `SPEECHRAIL_MCP_TRANSPORT` 或 `--transport` 指定，供 Open-WebUI 原生 HTTP MCP 直连）。

---

## 10. 工具矩阵汇总

| MCP 工具 | SpeechRail 端点 (file:line) | 是否推荐 | 备注 |
|---|---|---|---|
| `describe()` | `GET /v1/models`（`system.py:170`）+ `GET /v1/voices`（`system.py:226`） | ✅ 高（合并） | 单一能力快照，含 `mode/is_default/available` 判别字段 |
| `transcribe` | `POST /v1/audio/transcriptions`（`audio.py:677`） | ✅ 高 | `audio_ref`；`diarize?`/`timestamps?` 语义化 |
| `synthesize` | `POST /v1/audio/speech`（`audio.py:1144`） | ✅ 高 | **tier 硬强制**；输出 `audio_path` |
| `preview_voice` | `POST /v1/voices/previews`（`audio.py:1010`） | ✅ 高（quality-only） | 代理强制档位，先试再选 |
| `create_job`/`get_job`/`cancel_job` | `POST/GET/DELETE /v1/jobs`（`jobs.py:49/66/83`） | ✅ 中（可选长任务） | `job_id` = 显式句柄 |
| 实时全双工 | `WS /v1/realtime`（`realtime_openai.py:39`） | ❌ **不做 MCP** | 保留 WS，客户端直连 |

---

## 11. MCP 2026-07-28 协议升级（v1.2.0）

本节覆盖 server metadata、tool annotations、结构化输出、cache hints、read-only resources、progress 以及
SDK 双 era 行为。事实来源为 `src/speechrail/mcp/server.py`、`models.py` 与 MCP Python SDK v2 实测。

### 11.1 serverInfo

`create_server()` 构造 `MCPServer(name="speechrail-mcp", title="SpeechRail", description=..., version=__version__)`；
`version` 取自 `speechrail.__version__`（此前 SDK 默认为空串）。`title`/`description` 供 `server/discover` 与
初始化握手暴露。

### 11.2 Tool annotations

9 个工具全部声明 `title` 与 `ToolAnnotations`；`open_world_hint` 恒为 `false`（proxy 只访问本机 daemon）：

| 工具 | title | read_only_hint | destructive_hint | idempotent_hint |
|---|---|---|---|---|
| `describe` | Current capability snapshot | ✅ | — | ✅ |
| `transcribe` | Transcribe audio | ✅ | — | ✅ |
| `synthesize` | Synthesize speech to a file | — | — | — |
| `preview_voice` | Audition a voice instruction | — | — | — |
| `create_voice` | Create a persistent voice | — | — | — |
| `delete_voice` | Delete a voice | — | ✅ | ✅ |
| `create_job` | Create a durable job | — | — | — |
| `get_job` | Get a job record | ✅ | — | ✅ |
| `cancel_job` | Cancel a job | — | ✅ | ✅ |

### 11.3 结构化输出（outputSchema / structuredContent）

每个工具的返回类型注解为一个 Pydantic 结果模型（`speechrail/mcp/models.py`），SDK 据此派生 `outputSchema`
并校验返回值、发出 `structuredContent`。因为模型全部 `extra="allow"` 且非键字段都有默认值，
**未知键保留、可选字段缺省都不会拒绝真实 payload**；`_map_errors` 仍返回原始 dict，工具层再做
`Model.model_validate(...)`。

| 工具 | 结果模型 | 已知键 |
|---|---|---|
| `describe` | `DescribeResult` | tier/profile/readiness/realtime/jobs/models/voices/… |
| `transcribe` | `TranscribeResult` | text/segments/words/language/duration |
| `synthesize` / `preview_voice` | `AudioArtifact` | audio_path/content_type/output_format/bytes |
| `create_voice` / `delete_voice` | `VoiceRecord` | id/name/mode/available/capabilities |
| `create_job` / `get_job` / `cancel_job` | `JobRecord` | id/kind/state/result_ref/params |

### 11.4 Cache hints

`MCPServer(cache_hints={...})` 配置三个 **list** 方法（`ttlMs=300000`、`cacheScope=public`）：

- `tools/list`：工具集在进程生命周期内静态，可公开缓存；
- `prompts/list`：无自定义 prompt，空列表可公开缓存；
- `resources/list`：三个资源的 URI/name/description **是静态元数据**，可公开缓存。

**不**给 `resources/read` 配置提示——其内容（能力快照/音色/模型）随 profile 切换动态变化，
缓存会返回过期数据。

### 11.5 Progress notifications

`transcribe`、`synthesize`、`get_job` 增加 `ctx: Context` 参数（SDK 自动注入并从 `inputSchema` 排除）。
调用前 `report_progress(0.0, 1.0, "started")`，成功后 `report_progress(1.0, 1.0, "done")`，
与 `transcribe`/`synthesize` 同形。daemon 的 job 响应**不暴露数值进度**
（`_job_response` 只有 id/kind/state/error_code/result_msg/result_ref/params/queue_position/eta_seconds），
因此 `get_job` 只报 started/done，不臆造派生进度值。

### 11.6 双 era 行为（2026-07-28 vs 2025-11-25）

SDK 选择协议 era 的判据是**连接上的第一条消息**：若首条消息携带 2026 `_meta` 信封，则进入
**2026-07-28 无状态 era**；否则走 **2025-11-25 握手 era**。`ttlMs`/`cacheScope`（以及 2026 的
`resources`/`listChanged` 语义）**只在 2026-era 响应中出现**。

因此：

- 支持 2026 `_meta` 的客户端可看到 cache hints；
- **opencode 使用 2025-11-25 握手**，看不到 `ttlMs`/`cacheScope`——这是预期行为，proxy 不强行改写协议。

> 该双 era 事实在 SDK v2 的 `get_capabilities(protocol_version=...)` 与消息分发层实测确认；本 proxy 不做
> 任何 era 覆写。

### 11.7 预发布加固（v1.2.0 同批次）

本节记录 v1.2.0 发布前针对 SDK 兼容性、连接错误隐私与进程生命周期追加的加固。所有条目均有对应测试锁定。

#### 11.7.1 依赖下限收紧：`mcp>=2.1,<3`

`pyproject.toml` 的 `dev` 与 `mcp` 两个 extras 均从 `mcp>=2,<3` 收紧为 `mcp>=2.1,<3`（`pyproject.toml:47,51`）。
原因：`MCPServer(cache_hints=...)` 在 mcp 2.0.x 上对 pre-2026 会话（如 opencode 使用的 2025-11-25 握手）
调用 `list_tools()` 会崩溃；该问题在 mcp 2.1.0 修复。`uv.lock` 同步更新。

锁定测试：`tests/mcp/test_sdk_contract.py`

- `test_pyproject_pins_mcp_floor_at_2_1`：逐条校验 `dev`/`mcp` extras 中所有 `mcp` 依赖均含 `>=2.1`；
- `test_installed_mcp_minor_supports_cache_hints`：运行时校验已安装 mcp 的 minor ≥ 1；
- `test_cache_hints_api_is_importable_and_accepted`：构造 `MCPServer(cache_hints={"tools/list": CacheHint(ttl_ms=300_000, scope="public")})` 并断言 `ttl_ms == 300_000`。

#### 11.7.2 连接错误凭证脱敏

`src/speechrail/mcp/client.py` 新增纯文本函数 `_redact_userinfo()`（`:158`），在连接失败路径上
从 URL authority 中剥离 `user:pass@`，保留 scheme/host/port/path。选择纯文本而非 URL 解析，
是因为该函数运行在异常路径上，畸形 base URL 不应再抛异常而掩盖原始故障。`//` 仅当位于串首或
紧跟 scheme 分隔符 `://` 时才视为 authority 起始，因此无 scheme 的 `user:pass@host` 同样被剥离，
而无 scheme 路径中的 `//` 不会被误判为 authority。

`SpeechRailClient._request()` 在 `httpx.HTTPError` 分支构造 `SpeechRailError` 时调用
`_redact_userinfo(url)`（`:237`），确保错误消息不泄露凭证。

锁定测试：`tests/mcp/test_client.py::test_connection_errors_redact_url_userinfo`
（`:282`）——以 `http://operator:s3cret@rail.test:8201/v1` 为 base URL 触发连接错误，
断言 `exc.message` 不含 `s3cret` 与 `operator:`，但包含 `http://rail.test:8201/health`；
`test_connection_errors_redact_schemeless_userinfo`（`:301`）覆盖无 scheme 的
`user:s3cret@rail.test:8201/v1`（构造器会剥离尾部 `/v1`），断言无凭证残留且 host 保留。

#### 11.7.3 客户端生命周期：lifespan 内 `aclose`

`src/speechrail/mcp/server.py::create_server()`（`:135`）在构造 `MCPServer` 前，用
`@asynccontextmanager` 定义 `lifespan`（`:161`），在 yield 后 `await rest_client.aclose()`，
并将该 lifespan 传入 `MCPServer(lifespan=lifespan)`（`:173`）。

- stdio `run` 路径：MCPServer SDK 在 server 关闭时自动执行 lifespan 的 teardown；
- 进程内 `Client` 退出路径：测试直接 `async with app._lowlevel_server.lifespan(...)` 触发 teardown。

`aclose` 在 `httpx.AsyncClient` 上是幂等的，注入的测试 client 同样被正确关闭。

锁定测试：`tests/mcp/test_lifecycle.py::test_lifespan_closes_the_rest_client_on_shutdown`（`:31`）
——spy client 记录 `aclose` 调用次数，断言 lifespan 进入前为 0、退出后为 1。

#### 11.7.4 Era 门与成功路径测试

`tests/mcp/test_server.py` 新增三条测试，将 §11.6 的双 era 行为与 progress 语义固化为回归用例：

- `test_cache_hints_are_emitted_per_protocol_era`（`:481`）：以 `2026-07-28` 模式连接，
  断言 `tools/list` 与 `resources/list` 均返回 `ttl_ms=300_000`、`cache_scope=public`；
  以 `legacy` 模式连接，断言两者均返回 `ttl_ms=0`、`cache_scope=private`。
- `test_describe_success_returns_structured_content`（`:399`）：调用 `describe`，
  断言 `is_error=False`、`structured_content["tier"]=="quality"`、`content[0]` 为 `TextContent`。
- `test_transcribe_success_reports_started_and_done_progress`（`:426`）：调用 `transcribe`，
  断言 session 收到 `[(0.0, 1.0, "started"), (1.0, 1.0, "done")]`，
  且 `structured_content["text"]=="hello"`。

---

## 附录 A：证据

- SpeechRail 端点 file:line 取自当前工作树实测（契约/代码/文档三层核验）。
- **事实修正**：`SYSTEM_VOICE_PROFILES`（`tts.py:82`）9 音色全为 `mode="system"`，所有档位可用；
  `mode="clone"`（`tts.py:562`）/`mode="instruction"`（`tts.py:507`）仅用户自建；`resolve_binding` 对
  `mode=clone` 在 `custom_voice` 下抛 `ValueError` → `available=false`（`system.py:93-95`）。
- MCP 2026-07-28 规范字面取自官方 spec（`server/discover`、MRTR `requestState`、JSON Schema 2020-12、
  `cacheScope`/`ttlMs`）。
- 外部先例：`docker-talkies`（内置 `/v1/mcp`）、`trongnguyenbinh/voice-mcp`（MCP proxy→Bearer REST）、
  `agent-voice-mcp`/`whisper-transcribe-mcp`（`audio_ref` vs base64 踩坑）、`modelcontextprotocol/ext-apps/say-server`（实时 TTS queue-polling）。
- 本功能已实现于 `src/speechrail/mcp/`（PR #15，2026-09-07 合并到 main）；本文档随之从 draft 演进为 active。
- **依赖下限**：`pyproject.toml` `dev`/`mcp` extras 均 pin `mcp>=2.1,<3`（`:47,51`）；
  `uv.lock` 同步；锁定测试 `tests/mcp/test_sdk_contract.py::test_pyproject_pins_mcp_floor_at_2_1`、
  `test_installed_mcp_minor_supports_cache_hints`、`test_cache_hints_api_is_importable_and_accepted`。
- **凭证脱敏**：`src/speechrail/mcp/client.py::_redact_userinfo()`（`:158`）在连接错误路径
  剥离 `user:pass@`（含无 scheme 情形）；`_request()` 在 `httpx.HTTPError` 分支调用（`:237`）；
  锁定测试 `tests/mcp/test_client.py::test_connection_errors_redact_url_userinfo`（`:282`）
  与 `test_connection_errors_redact_schemeless_userinfo`（`:301`）。
- **lifespan 生命周期**：`src/speechrail/mcp/server.py::create_server()` 构造
  `@asynccontextmanager lifespan`（`:161`），yield 后 `await rest_client.aclose()`（`:164`），
  传入 `MCPServer(lifespan=lifespan)`（`:173`）；
  锁定测试 `tests/mcp/test_lifecycle.py::test_lifespan_closes_the_rest_client_on_shutdown`（`:31`）。
- **Era 门与成功路径**：`tests/mcp/test_server.py::test_cache_hints_are_emitted_per_protocol_era`（`:481`）
  断言 2026-era `ttl_ms=300_000`/`cache_scope=public`、legacy era `ttl_ms=0`/`private`；
  `test_describe_success_returns_structured_content`（`:399`）断言 `structured_content["tier"]=="quality"`；
  `test_transcribe_success_reports_started_and_done_progress`（`:426`）断言 progress 序列
  `[(0.0, 1.0, "started"), (1.0, 1.0, "done")]`。

## 附录 B：per-tool 授权矩阵（运维安全，非工具契约）

面对 agent 客户端（尤其是 MCP 端口对外时）建议的默认授权分级，供 Proxy 配置化实现：

| 工具 | 默认允许 | 建议理由 |
|---|---|---|
| `describe` | ✅ | 只读能力发现，无害 |
| `transcribe` | ✅ | 核心能力；音频引用不落日志 |
| `synthesize` | ✅ | 核心能力 |
| `preview_voice` | ⚠️ 视 token/配额 | quality 档较贵，建议 agent 内加节流 |
| `create_job`/`get_job`/`cancel_job` | ✅ | 长任务句柄 |
| `delete_voice`（克隆删除） | ❌ 默认禁 | 破坏性，应由本地人（而非 agent）操作；**未实现，预留** |

> 配置建议：`SPEECHRAIL_MCP_ALLOW_PREVIEW=0/1`、`SPEECHRAIL_MCP_ALLOW_DELETE_VOICE=0` 等。
> 注：`delete_voice` 尚未进入工具集，仅作为克隆删除能力的授权预留；当前 7 工具均无破坏性操作。
