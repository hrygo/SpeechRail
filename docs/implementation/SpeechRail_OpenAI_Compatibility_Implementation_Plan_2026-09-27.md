---
title: "SpeechRail：OpenAI 契约兼容、试听语言与显式保存实施方案"
status: proposed
created: 2026-09-27
repository: hrygo/SpeechRail
reviewed_ref: 54e5ec39bae8cfce1621c6e11c1278c0ba889b70
reviewed_pull_request: 99
implementation_status: not_started_in_this_review
runtime_validation: not_run
---

# SpeechRail 可执行实施方案

## 0. 适用范围与证据边界

本方案基于 OpenAI 官方 Speech/Voice/Transcription 文档、Qwen3-TTS 官方说明，以及 SpeechRail PR #99 的远端提交 `54e5ec39bae8cfce1621c6e11c1278c0ba889b70`。本次是只读设计审查，没有修改仓库、运行真实模型、执行测试或安装 App。Codex 本机尚未提交的配音状态/UI 改动，不包含在这一远端基线中；实施前必须检查实际工作区并保留这些改动。[R1]

本轮解决：TTS 合成契约收敛、试听元数据、语言扩展边界、试听缓存与异步一致性，以及配音显式保存。ASR 的语言参数、Realtime 的既有协议、模型替换、全量音色路径迁移与 OpenAI Custom Voice 创建接口实现，不在本轮扩展范围内。

## 1. 必须纠正的前提

1. OpenAI `/v1/audio/speech` 没有 `language` 参数，但这不意味着任何可选扩展都会破坏 SDK 兼容。官方 Python SDK 支持 `extra_headers`、`extra_body` 等扩展入口。标准请求能否不依赖扩展完成，是兼容边界之一。[O1][O4]
2. Qwen 官方明确说明，预置 speaker 可以使用模型支持的其他语言；推荐母语试听不等于限制输出语言。Ryan/Aiden 对应英语，Eric 实际为四川口音中文男声，不能把它列为英语音色。[Q1]
3. HTTP 200、音频字节数和时长不能证明输出内容正确。此前把“内容完全不对”直接认定为“英语音色读中文”的结论，证据不充分。必须同时排查实际 speaker 绑定、旧缓存、异步回包、输入传递和音频拼接。
4. 当前 SpeechRail 的持久 VoiceDesign candidate 流程明确仅接受 `language=zh`。系统音色的多语试听修复，不等于给整个创作/确认/复验/发布流程增加多语言支持。[R5]

## 2. 本轮固定决策

| 层次 | 实施决策 |
|---|---|
| OpenAI 兼容 TTS JSON | 仅保留 `model/input/voice/instructions/response_format/speed/stream_format`；不要求客户端先调用能力发现 |
| SpeechRail 可选语言控制 | 新增 `SpeechRail-Language` 请求头；默认不发送，服务内部使用 `auto` |
| 当前 TTS JSON 的 `language` | 从 HTTP DTO 与 Swift 标准请求 DTO 移除，迁移至上述专有请求头 |
| 当前 TTS JSON 的 `seed` | 从普通 speech 请求移除；保留在已有 VoiceDesign 专有流程，不为当前不支持 seed 的系统/clone 合成另建无效扩展 |
| 当前 TTS JSON 的 `validation_policy` | 移至新增可选 `SpeechRail-Validation-Policy` 请求头，沿用当前策略枚举 |
| 音色展示 | 返回可选 `preview: {locale, text}`；不增加“只支持某种语言”的 Voice 身份约束 |
| 默认试听 | 服务端维护音色对应的试听元数据；App 不硬编码 Ryan、Sohee 等 ID 的语种 |
| 用户改文案 | 保留原文；不根据音色的默认试听语言强制指定用户文稿的语言 |
| 普通配音 | 无显式覆盖时使用 `auto`；不根据 Voice 的推荐试听语言替换输入语言 |
| 作品库 | 生成与保存完全分离；只有显式保存才创建作品记录 |
| 历史扩展路径 | 本轮保留现有 `/v1/voices`、`/v1/voice-designs`，明确标记为 SpeechRail 专有接口；不增加重复 alias，也不借试听修复批量搬迁全部路径 |
| 新专有接口 | 继续遵循仓库约定，置于 `/v1/speechrail/*`；本轮不需要新增一套音色目录接口 |

现有契约已经选择 `/v1/speechrail/*` 与可选 `SpeechRail-*` 请求头承载扩展，本方案沿用这一机制，不另造 `X-SpeechRail-*` 或第二套 JSON options。[R2][R4]

上述“标准 JSON 收敛”是 SpeechRail 的架构选择，不应描述成 OpenAI 禁止第三方实现扩展。`SpeechRail-Language` 与 `SpeechRail-Validation-Policy` 均为本方案新增，不能作为现有已实现能力使用。

## 3. 目标 HTTP 契约

### 3.1 无扩展的普通合成

```http
POST /v1/audio/speech
Authorization: Bearer <本机配置的密钥>
Content-Type: application/json

{
  "model": "speechrail/qwen3-tts",
  "voice": "ryan",
  "input": "This is a voice preview. The speech should be clear and natural.",
  "response_format": "wav",
  "speed": 1.0
}
```

这个请求不需要 `language`、voice revision、模型 revision 或能力发现令牌才能进行普通合成。实际是否可用仍取决于当前服务的模型/音色就绪状态。

`model` 使用 SpeechRail 的真实 canonical ID。OpenAI SDK 的兼容性不要求把 Qwen 假称为 OpenAI 权重。现有兼容模型名/音色名的映射必须保持可审计；本轮不新增这些映射，也不宣称同名就具有相同音色和能力。[R2][R6]

### 3.2 带明确语言覆盖的原生调用

```http
SpeechRail-Language: en
SpeechRail-Receipt-Mode: integrity
```

JSON 不变。`SpeechRail-Language` 只表示这次生成的目标语言选择，不表示 speaker 的母语，不授权翻译或改写文本。

值采用 `auto` 或当前后端确实支持的标准语言短码，例如 `zh/en/ja/ko`。服务端维护唯一的语言短码到后端参数的映射；不要让 App 发送 Qwen 专有的 `English/Chinese` 参数名称。实际枚举来自当前 capability，而不是从理论模型能力推断。

`preview.locale` 使用语言标签；没有已验证地区信息时用 `en` 而不是臆造 `en-US`。本轮模板可以全部使用基础标签，避免引入地区/方言解析复杂度。[O5]

### 3.3 语言选择规则

```text
显式 SpeechRail-Language 且受支持 → 映射到后端语言参数
否则                              → 后端 auto
```

禁止插入一条“否则取 Voice 的推荐试听语言”的分支。后端 `auto` 原本就受 Qwen 支持，本轮无需额外构建语言检测服务。[Q1]

默认模板试听由 App 已知模板语言，可以选择发送匹配的扩展头；用户一旦改写模板，默认改为不发送头。只有用户独立、明确选择了语言覆盖，才继续发送该头。

### 3.4 标准字段与能力边界

`voice` 保留字符串和 `{ "id": "..." }` 两种形状。`instructions` 保留标准字段名，长度上限按官方文档的 4096 对齐；SpeechRail 目前 `_SpeechHTTPBody` 的上限为 10000，需要调整。普通合成的 `instructions` 是生成方式控制，不等同于 VoiceDesign 创建新音色。[O1][R3]

对实际 runtime 不支持的 `instructions`、非 1.0 clone speed 或 SSE，返回明确、稳定的错误，不能忽略参数、偷偷换 speaker、换模型角色，或返回假成功。公开说明这是支持范围有限的 OpenAI-compatible ASR/TTS 服务，不宣称全部模型语义等价。[R7]

Qwen 上游 CustomVoice 支持 `instruct`，但不代表 SpeechRail 当前 MLX adapter 已验证支持。是否补齐该能力应另加 adapter 测试并更新 capability；本轮保留诚实的 unsupported 状态，纠正“所有 instructions 只能用于创建音色”的错误解释。[Q1]

### 3.5 输入校验、错误与流式

对 TTS 标准 DTO 显式禁止未知 JSON 字段。只删除字段但仍静默忽略未知输入，会使旧客户端传 `language` 时得到成功却不生效。为已移除字段提供稳定的 `unsupported_parameter` 错误，`param` 指向旧字段，并给出迁移位置；不做静默转发 alias。

TTS 路由的 schema/参数错误统一在该路由边界映射为 400 和现有错误 envelope；不得为了这一目标全局改变 ASR 等其他路由的状态码。revision 冲突继续为 409；排队与后端不可用继续沿用当前契约。

支持的音频格式、默认 mp3、speed 范围、`stream_format` 的接受与拒绝行为写入同一兼容矩阵。HTTP 分块传输与 SSE 事件不是同一能力；未通过事件契约测试不得宣布支持 SSE。[O1][O2]

### 3.6 不要误删 ASR 的 language

OpenAI `/v1/audio/transcriptions` 自身有 `language` 参数。本次只处理 TTS 普通合成的非标准字段，禁止全仓机械删除同名字段。VoiceDesign 自有 API、内部 `SpeechRequest` domain object 和 Qwen adapter 也可以继续使用其正确语义的语言字段。[O3]

## 4. 音色试听元数据

### 4.1 对外最小结构

以下是对现有 SpeechRail 音色目录条目的新增投影，不是 OpenAI `audio.voice` 的扩展承诺：

```json
{
  "id": "ryan",
  "name": "动感英语男声",
  "mode": "system",
  "preview": {
    "locale": "en",
    "text": "This is a voice preview. The speech should be clear and natural."
  }
}
```

`preview` 可为空；其 locale 描述默认示例文本，不表示这只音色只能说这一种语言。本轮不增加 `supported_languages: ["en"]`，也不增加与 `preview.locale` 重复的 `recommended_locale`。

### 4.2 单一数据源

在 `VoiceProfile` 增加可选的展示属性 `preview_locale`，系统音色在既有 `SYSTEM_VOICE_PROFILES` 中明确填写；用一个纯函数将 locale 映射到受维护的模板，并生成公共 `preview` 对象。建议新文件 `src/speechrail/domain/voice_preview.py` 承载模板、值校验和投影逻辑。

`http/routes/system.py` 的目录投影与 `application/capability_snapshot.py` 的 effective voice 投影调用同一函数。App 的 capability facade 必须能接收到该字段，不能只更新 `/v1/voices` 而漏掉实际被 App 使用的能力快照。

显示属性变化只更新目录/能力表示的 ETag 或版本，不重新生成声学 `voice_revision`。缓存使用实际模板文本与语言，自然隔离模板变化。新增字段的持久化读写必须 round-trip 兼容已有音色数据，不重新生成 ID、reference、revision 或音频。

### 4.3 系统音色配置

| Voice ID | preview.locale | 说明 |
|---|---|---|
| `serena`, `vivian`, `uncle_fu` | `zh` | 中文示例 |
| `dylan`, `eric` | `zh` | 分别保留北京、四川口音描述；不把方言误标为英语 |
| `ryan`, `aiden` | `en` | 英语示例 |
| `ono_anna` | `ja` | 日语示例 |
| `sohee` | `ko` | 韩语示例 |

这一配置依据 Qwen 官方 speaker 表与 SpeechRail 当前系统目录。[Q1][R6]

建议的普通文本模板（仍需真实试听验收，不宣称已经人工审听）：

| locale | text |
|---|---|
| zh | 这是一段音色试听。声音清晰自然，每一句表达都恰到好处。 |
| en | This is a voice preview. The speech should be clear, natural, and easy to follow. |
| ja | これは音声の試聴です。聞き取りやすく、自然な声をお届けします。 |
| ko | 목소리 미리 듣기입니다. 또렷하고 자연스러운 목소리를 들어 보세요. |

### 4.4 自定义与缺失数据

新发布音色可以记录流程中用户明确选择、且已经持久化的试听语言；当前已验收的中文 VoiceDesign 发布可记录 `zh`。已有 clone 数据没有明确来源时保留 null，不根据“名称像英文”、描述首字符或参考文本出现汉字自动断言音色语言。

App 遇到缺失 preview 时，可以使用界面语言的通用示例作为展示 fallback，但不写回元数据，也不把它当成音色母语或强制生成语言。真实生成继续默认 auto。

参考音频语言、试听语言、输出能力是三个不同概念。本轮不自动调用 ASR 扩展元数据，不增加模型驻留、下载或后台分析。

## 5. App 试听实现

### 5.1 统一入口与草稿语义

音色库详情与配音台选音色按钮复用同一个 `VoicePreviewRequestBuilder`。请求构建器接收当前音色、文本草稿来源、可选显式语言覆盖、当前能力与版本信息。

建议草稿状态：`text`、`origin = preset | user`、`explicitLanguageOverride`。初次选择和切换音色时，只有 origin 为 preset 才更新默认示例；origin 为 user 必须保留用户文本。只有“恢复默认文案”能主动重置它。

最终请求有三种清晰语义：

| 场景 | input | 语言头 |
|---|---|---|
| 未修改的服务端示例 | preview.text | 能力支持时发送匹配短码，否则保持无头的普通合成 |
| 用户手改试听文案 | 用户原文 | 默认不发送 |
| 用户显式选择目标语言 | 用户原文 | 校验后发送所选值 |

不能仅靠比较文本是否等于某个模板来猜用户是否编辑，应保存 origin 状态。

### 5.2 请求与标准 DTO 分离

`SpeechRailControlKit/ServiceContractTypes.swift`：从 `SpeechRequest` 删除语言字段；在 `SpeechRailRequestOptions` 增加 `languageOverride` 和 `validationPolicy`，统一序列化为专有请求头。

`ServiceAPIClient.swift`：删除 `createSpeech` 与 `createSpeechRender` 中硬编码 `language: "auto"`；审查所有 options 重建路径，确保复制时没有丢失新增字段。当前 createSpeechRender 手动重建 options，这是必须覆盖的回归点。[R4][R8]

### 5.3 缓存键与读取顺序

当前 App 缓存键是 `voice.id + speed + previewText`，而缓存命中发生在取得 `speechRequestOptions` 之前。这既遗漏版本，也可能跳过更新后的使用资格检查。[R9]

改为结构化、版本化缓存身份，至少包含：

- canonical voice ID、有效 voice revision；没有 revision 的 system/legacy 音色使用明确的目录/能力 epoch 隔离，不制造假 revision；
- 选中的模型 catalog revision、已知 runtime revision/epoch；
- 实际 input、instructions、有效 language override 或 auto；
- speed、response_format、发音规则版本，以及会改变波形的其他已支持参数。

先检查当前音色可用/撤销状态和有效版本，再查缓存。结果入缓存前核对返回的 receipt/身份与请求。模板改变不必改 voice revision，因为实际 text 与语言已参与缓存键。

不要使用生成之后才能获得的随机 `planID` 作为唯一的请求前置缓存键。前置键应由当时可知的模型/音色/参数身份组成，返回 plan/receipt 用于结果校验与追溯。

缓存只保存解码通过、非空、完整返回且未取消的结果；版本冲突、未知必要身份、空音频、失败、过期响应均不缓存。设置内存字节上限与淘汰规则；缓存摘要不写入公开日志。

### 5.4 迟到回包隔离

每次试听生成独立 request token。成功、错误以及 defer 清理都必须确认 token 仍为当前请求，避免旧任务返回后覆盖新任务或清空新任务句柄。

切换或离开功能时取消旧请求并停止播放；取消后返回的音频既不播放，也不更新缓存/状态。普通试听不能触发作品保存。

### 5.5 不混淆三条音频路径

`system` 普通合成保持 CustomVoice；已发布 `clone` 保持 Base；未发布 `instruction` candidate 保持独立的 VoiceDesign 流程。已生成 candidate 的“播放”读取该 revision 对应的已存参考/复验音频，不能偷偷再次调用生成接口。[R7]

## 6. 显式保存配音

```text
Idle → Generating → PendingRender → 用户点击保存 → Saving → SavedWork
                       │
                       ├─ 播放：使用同一份已生成音频
                       ├─ 导出：显式导出，但不进入作品库
                       └─ 放弃：用户确认后释放
```

建议把 `startSynthesisAndSave/synthesizeAndSave` 重命名为真实反映行为的 render 方法，不保留名为 AndSave 却不保存的包装层。已提交基线与本机未提交实现可能不同，实施前合并已有 pending 修改，不覆盖它们。

`PendingRender` 在生成结束时固定 renderID、原稿、voice ID/name/revision、模型/plan 身份、语速、音频格式、时长与音频数据。保存时不得读取 UI 当前选项重写这份身份。

`savePendingDubbing` 使用稳定的 workID/idempotency key，保存成功刷新列表；双击、保存重试和“写入成功但列表刷新失败”均不得再创建一份作品。先写临时文件并完成存储提交，再转换为已保存状态；失败保留 pending 并允许重试。

生成成功、播放、切换页面与能力刷新都不调用 `workStore.save`。离开页面停止播放并取消未完成推理，但不因为 SwiftUI 的普通 onDisappear 就静默丢弃已经完成的结果；可以在 App 内保留 pending，替换结果或关闭时提供保存/放弃/取消选择。

作品重放、导出、以及保存已经完成的 pending 不需要重新加载模型或重新合成；音色在生成后被普通删除，不应让已经得到的本机音频凭空不可保存。语音授权/撤销的额外策略如有要求，需单独定义，不能与运行时是否存在混淆。

保持既有作品存储格式。不要为了实现“以后不自动入库”删除历史作品。UI 比较/动画使用轻量 renderID，不深比较大块音频 Data。

## 7. 按文件实施与交付顺序

| 工作包 | 文件/范围 | 完成条件 |
|---|---|---|
| A：契约先行 | `contracts/openapi.yaml`、现有 Speech/Capability/VoiceDesign 测试 | 写出标准字段清单、两个专有请求头、preview schema、未知字段/语言错误，以及官方兼容矩阵 |
| B：服务端元数据 | `domain/tts.py`；新增 `domain/voice_preview.py`；`http/routes/system.py`；`application/capability_snapshot.py` | 音色目录与 effective snapshot 返回相同 preview；缺失字段可读；展示修改不改变声学 revision |
| C：边界适配 | `http/routes/audio.py`；`domain/tts_request.py`；相关 backend 与 MCP/CLI 调用处 | 标准 HTTP DTO 不含旧扩展，内部仍得到语言/策略；全部调用方完成迁移，不忽略未知字段 |
| D：Swift 协议 | `SpeechRailControlKit/ServiceContractTypes.swift`；`CreatorServiceClient.swift`；`ServiceAPIClient.swift` | 标准 DTO 无 language；options 保留所有扩展；JSON/header 快照与契约一致 |
| E：试听闭环 | `AppModel.swift`；`CreatorSurfaceViews.swift`；新增公共 request builder（如需要） | 两个试听入口同规则；用户草稿不覆盖；版本化缓存；迟到回包无副作用 |
| F：显式保存 | `AppModel.swift`；`CreatorSurfaceViews.swift`；`CreativeWorkStore` 及其测试 | 未保存数量不变；一次保存只增加一条；保存失败可重试；重播不再推理 |
| G：验收与发布 | Python/Swift 测试、SDK smoke、真实音频样本、现有 release wrapper | 逐条证据，不以计划/旧版测试替代；联合发布 App 与 service，提供双回滚点 |

建议服务契约/元数据、App 状态/缓存、真实验收/发布三个可审查提交组。无需为每个文件单独开 PR，也不把模型升级、SSE 新实现和全量旧路径清理混入这轮。

公共字段迁移采用与 App/服务同步的受控切换，不默认保留旧字段桥接。这符合当前仓库“小用户阶段优先当前标准、不自动保留旧 alias”的规则。数据读写兼容与用户数据保护仍必须保留。[R10]

## 8. 验收矩阵

下表均为待实施、待运行的验收项，本次未执行。

| 编号 | 验收 | 通过条件 |
|---|---|---|
| C01 | 官方 SDK 普通合成 | 不带额外 body/header、不先访问目录，也可完成支持范围内的合成 |
| C02 | 两种 voice 形状 | string 与 `{id}` 解析后指向同一预期声学身份 |
| C03 | 标准字段边界 | input/instructions 上限、格式、speed、stream_format 的行为符合锁定的矩阵 |
| C04 | 旧字段/拼写错误 | language/seed/validation_policy/未知 JSON 字段不会被静默接受 |
| C05 | 新扩展头 | 不带→auto；合法语言→准确映射；非法语言→稳定 400；不启动额外模型 |
| C06 | 不支持的功能 | instructions/clone speed/SSE 如不支持，准确拒绝且 capability 不作虚假声明 |
| C07 | ASR 不回归 | transcription 的标准 language 字段仍有效 |
| M01 | 9 系统音色 | 对应 4 种示例文本；Eric 与 Dylan 为中文方言音色 |
| M02 | 目录一致性 | list/detail/effective snapshot 的 preview 数据一致 |
| M03 | 缺失/迁移 | 旧音色可读取，ID/revision/reference/旧作品不变；未知语言不猜测 |
| U01 | 用户编辑 | 更换音色不覆盖用户文案；不继承旧模板的强制语言头 |
| U02 | 缓存身份 | 同请求同版本可命中；文本/语言/voice revision/模型/发音规则变化不误命中 |
| U03 | 异步交错 | A取消、B开始、A迟到成功/失败/defer，均不污染B |
| U04 | 正式/候选试听 | system/clone 不误走 Design；candidate 重放不重新生成 |
| W01 | 显式保存 | 生成/试听/导出不增库；点击保存只增加一条 |
| W02 | 保存失败与重试 | 注入磁盘失败后仍有 pending；刷新失败与双击不重复写入 |
| W03 | 保存身份 | 保存的字节与试听字节一致；元数据来自 pending 而非当前 UI |
| W04 | 离开与历史数据 | 页面离开不自动保存，不静默丢已完成结果，不删除旧作品 |
| Q01 | 内容一致性 | 真实默认样例无明显漏句、增句、重复、错误文本或空白音频 |
| Q02 | 跨语言对照 | Ryan 中文请求被正确传递；不以其英语示例语言阻止；质量问题有可定位证据 |
| R01 | 联合发布 | service/App 契约匹配、版本可追溯、XPC通过、正式安装唯一、回滚点可恢复 |

### 8.1 确定性测试

使用 fake backend/transport 验证协议、状态、缓存和数据持久化，不下载模型、不触发真实推理或 UI 接管。扩展已有：

- `tests/test_speech_api.py`
- `tests/test_openapi_contract.py`
- `tests/test_capability_snapshot.py`
- `tests/test_voice_design_workflow.py`
- `SpeechRailMacControlTests/AppModelTests.swift`
- `SpeechRailMacControlTests/ServiceContractTests.swift`
- `SpeechRailMacControlTests/CreativeWorkStoreTests.swift`

实施后的目标命令：

```bash
git diff --check
uv run --extra dev ruff check src tests
uv run --extra dev pytest \
  tests/test_speech_api.py \
  tests/test_openapi_contract.py \
  tests/test_capability_snapshot.py \
  tests/test_voice_design_workflow.py
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter CreativeWorkStoreTests
uv run python scripts/check_version_consistency.py
```

遵循实施时仓库实际测试配置；不能临时清空 addopts、屏蔽覆盖率或删除失败断言后，把结果写成完整 gate 通过。定向测试与完整 gate 分别记录。

### 8.2 官方 SDK 实际互操作

在已安装项目选定并锁定的官方 SDK 的环境中，使用真实服务做以下无扩展 smoke；本方案未执行：

```python
import os
from pathlib import Path
from openai import OpenAI

key = os.environ.get("SPEECHRAIL_API_KEY")
if not key:
    raise RuntimeError("请通过环境变量配置本机 SPEECHRAIL_API_KEY；不要写入脚本。")

output = Path("speechrail-openai-sdk-smoke.wav")
if output.exists():
    raise FileExistsError(f"拒绝覆盖已有文件：{output}")

with OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key=key,
    max_retries=0,
    timeout=120.0,
) as client:
    with client.audio.speech.with_streaming_response.create(
        model="speechrail/qwen3-tts",
        voice="ryan",
        input="This is a voice preview. Every word should be clear and natural.",
        response_format="wav",
    ) as response:
        response.stream_to_file(output)

if output.stat().st_size == 0:
    raise RuntimeError("服务返回了空音频；该测试未通过。")
```

这个脚本只证明一次 SDK/HTTP 互操作与非空输出，不能代替音频解码、内容或 App 验收。另一个独立测试在调用中加入 `extra_headers={"SpeechRail-Language": "en"}` 验证本方案新增扩展；不要把后者作为普通兼容请求的前置条件。[O4]

### 8.3 真实内容根因核验

对用户原始出问题的示例，在固定 commit、模型 revision、speaker、输入文本、格式和语速后，对比：

| 组 | 路径 | 输入 | 语言选择 | 缓存 |
|---|---|---|---|---|
| A | 后端/HTTP基线 | 原始中文文案 | auto | 关闭 |
| B | 后端/HTTP基线 | 同一中文文案 | 显式 zh | 关闭 |
| C | 后端/HTTP基线 | 对应英文文案 | auto 与显式 en 分别测 | 关闭 |
| D | App 两个入口 | 与A/B/C一致 | 与A/B/C一致 | 首次未命中、再次命中 |

分别校验音频可解码、非空/非纯静音、请求绑定的 speaker、实际朗读内容、输入与结果对应关系。中文用规范化 CER、英文用规范化 WER 辅助定位；日/韩使用有明确分词/归一化规则的对齐或 CER，再人工听审。短句、数字、品牌词和方言不能仅用同一个 ASR 阈值自动判定。

自检 ASR 不得把预期全文作为 prompt，否则内容一致性证据被污染。使用有区分度、彼此不同的句子测试串音和旧缓存；仅仅把默认文案改成另一种语言，不能证明原来的内容错误已经修复。

只对本轮代表性样例做授权范围内的真实验证，不默认扩大为全量 benchmark。原始音频和完整文本保留在本机私有验收目录，不提交仓库、不写公开日志。

## 9. 发布、迁移与回退

### 9.1 本轮不是 App-only 发布

本方案同时改动服务端响应元数据与 HTTP 请求边界，应按现有 release 规则做 combined 发布。只替换 App 而不升级服务，会导致新预览元数据或扩展头没有对应实现。先完成服务制品的 preflight/能力验证，再验收 App 控制与试听链路。[R11]

实施前读取当时的 `.agents/skills/speechrail-release/SKILL.md` 与 service 部署流程。确认工作区、本机未提交改动、并行修改、当前 branch/head，与本文件基线做差异核验。

数据迁移仅补充可选展示元数据。不得清空音色、作品、reference、模型或用户配置；不得重新发布已存在的 clone 来“补语言”。准备服务与 App 两个可恢复制品，并保存持久数据的安全备份/迁移证据。

新 App 应核对服务所声明的契约/扩展能力；不认识的专有头不能被当成已经生效。同步更新 App 版本、服务版本、单调递增 build 和契约证据。不再用相同 version/build 冒充新安装。

### 9.2 App 构建与静态验证

以下仅为实施阶段命令，本次未运行。真实构建、运行态变更与安装按当前用户授权执行：

```bash
scripts/macos_app_build.sh --configuration Release --archive
CANDIDATE="build/SpeechRail.xcarchive/Products/Applications/SpeechRail.app"
scripts/macos_app_verify_local_xpc.sh "$CANDIDATE"
```

保留本机 ad hoc 签名，不通过关闭 CODE_SIGNING_ALLOWED 绕过 XPC 身份校验。该包是本机 Release 包，不是已完成 Developer ID 签名与 notarization 的对外分发包。[R11][R12]

安装按 release skill 的 staging、校验、正常退出、同文件系统替换与回滚步骤执行，不在本方案提供一段省略保护的 mv/rm 脚本。默认正式路径为 `~/Applications/SpeechRail.app`。

安装后：

```bash
scripts/macos_app_verify_single_install.sh "$HOME/Applications/SpeechRail.app"
```

保留唯一正式注册；只清理本轮自己的 staging、archive 和派生副本。不重置全局 LaunchServices，不清空废纸篓，不改变模型 selection 或私有配置。

### 9.3 必须记录的证据

记录 source commit、契约快照/哈希、service wheel 哈希、App version/build/签名身份/制品哈希、确定性测试结果、SDK版本与smoke结果、真实样例测试编号与审听结论、安装路径、单实例/唯一登记/XPC检查、回滚制品位置，以及所有 not_run 项。

不得记录 API key、Authorization、完整用户文稿、参考音频、embedding 或绝对模型路径。原始语音证据仅保留在本机授权的私有位置。

未获本轮逐次授权时，UI 自动化必须标为 not_run。用户手工试听也应有明确结论，不能由“构建成功”推断“试听内容正确”。

### 9.4 回退规则

App 与 service 分别有 rollback point，但发生契约不匹配时按匹配的一对版本回退。不得直接用旧备份覆盖升级后新增的用户作品或音色；先保全新增数据，再按已经验证的可选字段迁移/读取策略处理。只回退代码和协议不等于授权回滚用户创作数据。

## 10. 最终交付条件

完成不是“补了一个 locale 字段”或“生成接口返回 200”，而是：普通 OpenAI SDK 请求无扩展可用；SpeechRail 扩展可发现且不改变标准字段语义；默认试听文案正确且用户输入不被干预；版本变化与迟到回包不会串音；真实输出对应输入；配音只在显式保存后入库；服务和 App 以可回退的匹配版本完成安装验收。

本轮不实施全量语言检测、全量多语言 VoiceDesign、OpenAI Custom Voice consent 创建流程、SSE 新能力或所有历史路由重命名。它们应有各自的需求、契约和验收，不作为当前两个用户反馈的隐含依赖。

## 证据索引

以下公开资料核对日期为 2026-09-27。仓库代码均固定于本文件 reviewed_ref；源链接以代码格式保留，便于复制核验。

| 编号 | 来源 |
|---|---|
| O1 | OpenAI Create speech：`https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create` |
| O2 | OpenAI Text to speech guide：`https://developers.openai.com/api/docs/guides/text-to-speech` |
| O3 | OpenAI Create transcription：`https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create` |
| O4 | OpenAI Python SDK 官方 README（自定义请求、extra_headers、base_url）：`https://github.com/openai/openai-python` |
| O5 | BCP 47 / RFC 5646：`https://www.rfc-editor.org/rfc/rfc5646.html` |
| O6 | OpenAI Create voice：`https://developers.openai.com/api/reference/resources/audio/subresources/voices/methods/create` |
| Q1 | Qwen3-TTS 官方 README（speaker 表、跨语言、Auto、CustomVoice/Design/Clone）：`https://github.com/QwenLM/Qwen3-TTS` |
| R1 | PR #99 元数据：`https://github.com/hrygo/SpeechRail/pull/99`；本轮读取 head 为 `54e5ec39bae8cfce1621c6e11c1278c0ba889b70` |
| R2 | `contracts/openapi.yaml` 1–170 行：扩展边界与 canonical 模型 |
| R3 | `src/speechrail/http/routes/audio.py` 1–260 行：当前 HTTP DTO |
| R4 | `macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift` 1150–1335 行：标准 DTO、专有 headers 与 receipt |
| R5 | `contracts/openapi.yaml` 170–470 行：音色扩展路径、VoiceDesign 中文范围与 candidate 生命周期 |
| R6 | `src/speechrail/domain/tts.py` 40–235 行：VoiceProfile、系统目录与 aliases |
| R7 | `src/speechrail/domain/tts_request.py`；`src/speechrail/backends/qwen3_voice_binding.py`；`src/speechrail/http/routes/audio.py` 1550–1770 行 |
| R8 | `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift` 200–335 行：language=auto、options 重建、receipt |
| R9 | `macos/SpeechRailApp/SpeechRailApp/AppModel.swift` 2255–2475 行：缓存、请求与播放状态 |
| R10 | 仓库根 `AGENTS.md`：只读范围、演进策略、资源/隐私与发布约束 |
| R11 | `docs/developers/macos-app-release.md`：combined 发布、签名与回滚 |
| R12 | `scripts/macos_app_build.sh`：Release archive 包装脚本 |

固定代码链接前缀：`https://github.com/hrygo/SpeechRail/blob/54e5ec39bae8cfce1621c6e11c1278c0ba889b70/`。
