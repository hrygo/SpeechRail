---
title: "有效能力快照与安全音色目录"
status: active
audience: "SDK、MCP 与本地语音客户端开发者"
version: "3.2.2"
date: 2026-09-26
---

# 有效能力快照与安全音色目录

`GET /v1/speechrail/capabilities` 返回 `effective_capabilities_v1`：同一份已脱离 registry
可变对象的音色目录、活动模型配置、逐音色逐操作参数域。读取不启动、卸载 worker，
不执行推理、不下载模型。`/v1/speechrail/voices` 和 `/v1/speechrail/voices/{voice_id}` 是同一安全模型的
列表/详情投影；需要跨对象一致性时，只使用一次 `/v1/speechrail/capabilities` 返回的数据，
不要把不同时间的多个 GET 拼成原子快照。

## 身份和缓存保证

`service_instance_epoch` 在服务实例建立时生成；`catalog_revision` 由目录和配置内容
决定，普通重复读取及 readiness 变化不改目录 revision；`snapshot_id` 同时覆盖实例
与当前 availability。三个入口支持私有 ETag、If-None-Match 和 304；鉴权先于缓存判定。
修改音色配方、启用列表、ASR/TTS 独立规格、配置制品或 TTS planner 策略会改变相关内容标识。

**这些标识不是推理版本锁。** 当前已有音色的 `voice_revision=null`、
`voice_identity_assurance=legacy`。模型的 `assurance=configured_catalog` 只表示配置
匹配目录，`runtime_revision=null` 不伪装成已观测的 worker 制品身份。执行条件合成、
不可变历史版本和实际渲染回执仍需各自的能力；本接口明确报告
`inference_version_pin=false`、`admission_reserved=false`。

## 用 revision pin 固定跨请求音色

发现快照本身不产生 lease，也不会把下一次推理自动绑定到某个版本。需要跨句或跨请求保持
一致时，客户端应把选中条目的 `voice_revision` 与 `model.catalog_revision` 分别复制到
`POST /v1/audio/speech` 的 `SpeechRail-Expected-Voice-Revision` 和
`SpeechRail-Expected-Model-Revision`。服务端在首个 PCM 前原子校验：voice revision 过期或
撤销、model catalog revision 未知或变化，均返回稳定的 `409`，不会静默切换到另一音色或模型。

`speechrail-mcp` 已把这条规则做成工具行为：`describe()` 与 `synthesize()` 必须读取已知的
`effective_capabilities_v1`；`synthesize` 自动携带两个可验证的 pin；MCP 调用方传入的
`expected_voice_revision` / `expected_model_revision` 优先。返回结果回显实际采用的 revision，
便于调用方记录和审计。能力契约缺失或无法识别时，MCP 直接返回契约错误，不回退到独立的旧列表。

这套机制保证的是“绑定到同一个声明版本”，不是声学质量证明；跨文本说话人相似度、自然度与
长时稳定性仍须使用真实 Base clone runtime 和独立质量基准验收。

`available=true` 是当前配置允许按需服务，不代表已驻留、队列一定可准入或声音质量合格。
`unsupported` 应拒绝或经用户选择降级，`unknown` 应保守处理，不能等同 supported。

## 参数按操作区分

`fast`、`quality` 与 `reference` 分别解析 ASR、固定自定义音色 Base 与内置 speaker CustomVoice 角色；实际可用性以当前有效快照为准。VoiceDesign 只在 `voice_design` 任务中运行，普通 Base clone 与 CustomVoice 路由不接受 Design 音色。
普通 HTTP speech 支持 seed。语言完整取值域尚未在固定 vendor 上验证，因此报告 unknown。

ASR 侧操作在 `operations` 中按 `transcription`、`alignment_transcription`、
`realtime_transcription` 与 `jobs` 分别披露真实输入上限（`max_upload_bytes`、
`max_audio_seconds`）、粒度、语言取值域、输出能力与就绪原因。这些枚举只由配置、
绑定制品与认证事实决定，与 busy/队列状态无关：并发繁忙不会让已支持能力变成
unsupported。`realtime_transcription.duplex` 与 `guarantees.realtime_full_duplex`
只在联合实时验收通过后才是 `full_duplex`/`true`；WebSocket 双向收发本身不构成
全双工认证，未认证时明确报告 `half_duplex`。

sample rate 描述 PCM 域；容器编码仍可能有其自身约束。HTTP EOF 当前只有传输层证据，
Realtime 的 `speechrail.tts.completed` 也不证明扬声器播放或内容读对。SSML/phoneme、clone 原生表演、
prepared-reference 条件缓存和精细时间轴，在适配与验收前不得由客户端自行假定支持。

## 最小披露与路由边界

namespaced 能力目录不返回 reference text、本机音频路径、私有 instruction、creation 正文或完整
quality 调试对象。descriptors 只使用显式系统声明；缺失的 locale/音高/音色族/速度等
保留 unknown，不根据私有参考推断年龄、性别、族裔或真实身份。

`/v1/voices` 是独立的列表/详情资源，仍可能含来源正文，**不是最小披露接口，也不存在新增的
owner 权限保证**。它不参与 MCP 的能力发现、自动选音或原子路由；自动选音和第三方消费者
必须使用 namespaced discovery。MCP 的安全投影只允许公开选择音色所需字段，不把 API key 等同于
所有来源资料的 owner。

MCP `describe` 的顶层 `models` 与 readiness 仍是独立当前观察；`effective_capabilities` 是必需的
namespaced capability 响应，`voices` 只使用其安全投影，不再输出
`legacy_discovery_consistency`、`legacy_voices` 或 `voice_discovery_source`。MCP 的独立
`speechrail://voices` 资源仍使用白名单投影，不把 `/v1/voices` 来源正文带入 Agent 上下文；需要
原子路由时始终使用嵌套快照。

## 证据和剩余验收

矩阵测试覆盖 fast/quality/reference 与内置 speaker/固定自定义 revision、内容变更/重启、
鉴权、别名、存储损坏和私有字段隔离。测试使用 fake backend；没有启动用户服务，
不能据此宣称模型语言域、音质、不可变音色或并发推理版本锁已经验收。

### 认证状态（2026-09-26）

`fast`/`quality` 的制品有本机准备与逐文件 size/SHA-256 校验证据；`reference` 的 bf16 制品继承
同族 8-bit 档位已通过的门禁证据。2026-09-26 已在本机真实运行态补测三档：

- 三档 warm bench（各 30 fixture）0 失败；`reference` 的 `asr_runtime_revision` 非空，
  证明 BF16 档真实可推理（修复前为 `null`）。
- 三档冷启动、参考档反复取消 ×100、短时 soak ×30 轮通过；详见
  [Issue #95 交付认证](../developers/issue-95-certification.md) §7.2。

即便如此，本页的 `available=true` 仍只表示配置允许按需服务，**不表示**语音质量、克隆身份相似度、
自然度或 ≥2h 长稳已认证。人工听审、真实声卡播放器、CER/WER 语料分层、联合实时全双工仍需按该文档
§8.2 执行，并登记 commit、engine revision、制品 revision、设备与样本数。

## 分句规划版本

`operations.tts_text_planner` 描述当前共用 worker planner：`tts_bounded_v1`、最大
240 codepoints。内部 plan 持有规范化文本区间和确定性边界，尚不提供原始 HTTP 文本
映射或音频时间轴。该版本保持既有发音输入，不添加强制预生成、上下文模型或额外停顿。
`native_context_conditioning=unsupported` 指未适配该能力，`naturalness_evidence=unevaluated`
保留真实多音色 A/B 验收；不能把 planner 版本当作完成回执或音质等级。
