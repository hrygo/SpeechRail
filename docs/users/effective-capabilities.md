---
title: "有效能力快照与安全音色目录"
status: active
audience: "SDK、MCP 与本地语音客户端开发者"
date: 2026-09-20
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
修改音色配方、启用列表、档位、配置制品或 TTS planner 策略会改变相关内容标识。

**这些标识不是推理版本锁。** 当前已有音色的 `voice_revision=null`、
`voice_identity_assurance=legacy`。模型的 `assurance=configured_catalog` 只表示配置
匹配目录，`runtime_revision=null` 不伪装成已观测的 worker 制品身份。执行条件合成、
不可变历史版本和实际渲染回执仍需各自的能力；本接口明确报告
`inference_version_pin=false`、`admission_reserved=false`。

`available=true` 是当前配置允许按需服务，不代表已驻留、队列一定可准入或声音质量合格。
`unsupported` 应拒绝或经用户选择降级，`unknown` 应保守处理，不能等同 supported。

## 参数按操作区分

Quality 的默认 VoiceDesign 与 Base clone 是两个不同 capability worker。clone 使用
Base，只允许 `speed=1.0`，拒绝调用方 instructions/seed。HTTP VoiceDesign 可以使用
instructions；标准 Realtime response 不接收同一个参数。preview 的 seed 能力不代表
普通 HTTP speech 支持 seed。语言完整取值域尚未在固定 vendor 上验证，因此报告 unknown。

sample rate 描述 PCM 域；容器编码仍可能有其自身约束。HTTP EOF 当前只有传输层证据，
Realtime 的 response.done 也不证明扬声器播放或内容读对。SSML/phoneme、clone 原生表演、
prepared-reference 条件缓存和精细时间轴，在适配与验收前不得由客户端自行假定支持。

## 最小披露和兼容迁移

namespaced 能力目录不返回 reference text、本机音频路径、私有 instruction、creation 正文或完整
quality 调试对象。descriptors 只使用显式系统声明；缺失的 locale/音高/音色族/速度等
保留 unknown，不根据私有参考推断年龄、性别、族裔或真实身份。

本增量保留 `/v1/voices` 的历史投影，以免破坏现有音色编辑客户端；它仍可能含来源正文，
**不是最小披露接口，也不存在新增的 owner 权限保证**。自动选音/第三方消费者应迁移
到 namespaced discovery。未来移除旧字段需要单独的版本迁移，不把 API key 等同于所有来源资料的 owner。

MCP `describe` 的旧顶层 models/readiness 来自独立读取，明确标记
`legacy_discovery_consistency=independent_reads`；新增 `effective_capabilities` 保存
一次 namespaced capability 响应。只有旧服务返回 404/405 或未知 schema 时该字段为空；鉴权和存储故障
不被悄悄降级掩盖。MCP 的兼容 voice 列表也使用白名单投影，不把 `/v1/voices` 来源正文带入
Agent 上下文。需要原子路由时使用嵌套快照，而非顶层旧字段拼接。

## 证据和剩余验收

矩阵测试覆盖 light/balanced/quality 与 system/instruction/clone、内容变更/重启、
鉴权、别名、存储损坏和私有字段隔离。测试使用 fake backend；没有启动用户服务，
不能据此宣称模型语言域、音质、不可变音色或并发推理版本锁已经验收。

## 分句规划版本

`operations.tts_text_planner` 描述当前共用 worker planner：`tts_bounded_v1`、最大
240 codepoints。内部 plan 持有规范化文本区间和确定性边界，尚不提供原始 HTTP 文本
映射或音频时间轴。该版本保持既有发音输入，不添加强制预生成、上下文模型或额外停顿。
`native_context_conditioning=unsupported` 指未适配该能力，`naturalness_evidence=unevaluated`
保留真实多音色 A/B 验收；不能把 planner 版本当作完成回执或音质等级。
