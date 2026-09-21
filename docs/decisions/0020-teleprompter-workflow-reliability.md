# ADR-0020：提词器采用 App 内受约束工作流与局部恢复

## Status

Implemented — 本轮代码、确定性回归测试与 App target 构建已完成；真实模型质量验收与 UI 视觉/交互验收仍待单独执行。本记录不代表这两项已通过。

## Date

2026-09-21

## Context

提词器需要把混合格式原稿转成保真、自然、可编辑的朗读稿。当前 Swift 实现已有来源切片、Map、Reduce、严格 decoder、重试、取消与版本屏障。问题不在于缺少一个 Agent 调度器。

本次用户授权为方案复审、优化与落盘。本文记录修订后的决策，实施任务见[实施计划](../superpowers/plans/2026-09-21-teleprompter-workflow-reliability.md)。不增加 Python sidecar，不把 LLM 编排移入 SpeechRail 服务，延续 ADR-0019 的职责边界。

### 证据与上一轮结论修正

| 证据 | 可支持的结论 | 不能支持的结论 |
|---|---|---|
| 本次会话检查的 2026-09-21 运行事件：两个 endpoint/model 组合返回 HTTP 200，随后出现 map_decoder / preparation_error | 在这些尝试中，本地结果处理拒绝了响应 | 所有 SOTA 模型均失败；服务永远正常；已知道具体违规字段 |
| `TeleprompterPreparationPrompts.swift` 的 Map decoder 将多种违规合并为 invalidPromptResponse | 错误粒度不足，无法从现有事件区分字段、覆盖、模式、literal 等错误 | 某一条校验已经被证明是此次失败根因 |
| `LLMProvider.swift` 的 completeJSON 使用 json_object 并把 schema 写入 system | 服务端 JSON mode 与本地严格校验是当前策略 | 实现漏传 strict schema 就是此次根因 |
| 终版规格 §8.1/§8.3 明确采用上述 JSON mode，§8.2 要求返回口语正文 | 当前 text 输出符合整理产品目标 | 返回 text 本身是契约错误 |
| 较旧功能文档描述 analysis.v2、无正文和 strict json_schema | 文档混用了标注与整理两条路径，需要同步 | 应用必须退回仅分段产品 |
| recoveryPrompt 只追加泛化重生成要求，Map 恢复失败向外抛出 | 修复缺少具体诊断，局部失败可扩大成整稿失败 | 重试一定无效，或增加重试一定有效 |

因此撤回上一轮“协议漂移足以解释所有失败”的强因果表述。当前已定位失败层，具体触发条件尚未确定；先补安全诊断，再用合成/获准样本重现。原始响应不因排障而写入日志。

本次核实还发现终版规格的部分 Map 示例使用非零编号，而当前 prompt/decoder 使用窗口局部零起始编号；Reduce 示例缺少当前要求的 revision。这些是文档示例漂移，不证明对应示例被发送到了模型。

## Decision

### 1. 继续使用 Swift typed workflow

使用现有 MacPaw/OpenAI adapter 与 Swift 并发，明确每个阶段的输入、输出、预算和终态。不引入通用 Agent loop、多 Agent 辩论、自动工具选择、长期记忆或通用 DAG 平台。模型无文件、shell、网络工具；原稿中的指令始终作为资料处理。

### 2. 分离分组与口语改写，保留产品能力

目标流程：无损切片 → 分组建议 → 程序确定来源组 → 按组口语改写 → 规则检查/人工审阅 → 可选局部 Reduce → 完整装配 → 用户采用。

- 分组阶段只返回窗口局部的半开区间，不返回正文、字符偏移或全局来源 ID。覆盖/顺序/边界由程序验证；失败时使用原有确定性来源边界，不能猜测修补错误区间。
- 改写阶段接收程序分配的组 ID、原文及只读上下文，返回该 ID 的 mode、text、issues。模型不能重新分组或修改来源范围。可批量处理有界的组，避免默认一组一次调用。
- 程序生成 ID、原稿范围、版本、预算、来源关联和最终阅读坐标。已适合朗读的正文允许保持原样；表格、列表等仍可口语化。
- 单独的确认后标注继续使用 analysis 路径，不改正文。不要把“标注不返回正文”套用到“整理需要改写正文”。

内部 wire 使用新的独立分组/改写版本，替换当前混合 Map 协议；不保留业务无需求的旧 wire alias。持久化稿件格式不是 wire，禁止因此删除或重置稿件。具体类型与 schema 必须随实现一起收敛。

拆阶段会增加延迟和 token；其收益需通过同稿同模型对照确认。先落地诊断与恢复，再实现拆阶段；质量门槛沿用终版规格 §15，不因架构更整齐降低门槛。

### 3. 根据端点能力选择输出模式

支持原生严格 JSON Schema 的 endpoint/model 优先使用服务端结构化输出；JSON mode 端点继续允许使用，并明确只有本地校验保证形状与业务约束。不把“不支持 strict”直接等同于“不能整理”。当前已知的 OpenCode Go Chat gateway 直接使用 JSON mode，避免发送其会拒绝的 `response_format=json_schema`。

能力记录至少绑定 endpoint、model、compatibility mode、API operation 和 schema 版本/摘要；不凭模型名字推断支持能力。端点明确拒绝该 schema 时，可在同一端点内有界退回 JSON mode，并记录模式变化；超时、认证失败、429、refusal 或一般 5xx 不能冒充能力不支持。该额外调用计入总恢复预算。不自动换服务、模型或数据发送目的地。

未知端点默认沿用已配置 adapter 的模式；能力验证纳入独立合成样本验收，不因打开设置或页面而触发付费探测。strict 模式下仍检查截断、拒绝、重复键、覆盖、ID、revision 与语义风险。

### 4. 区分结构错误、内容风险和系统错误

新增稳定、脱敏的诊断分类：json_syntax、duplicate_key、schema_keys、schema_version、field_type、invalid_enum、range_gap、range_overlap、range_bounds、group_limit、mode_mismatch、protected_literal、unknown_block、duplicate_block、revision_mismatch、output_truncated。网络、认证、限流、拒绝、取消、源状态损坏保持各自错误类别。

诊断可包含 schema 定义内的字段路径、组序号、计数、阶段和尝试序号，不包含实际未知 key、literal、正文片段或 provider 原始错误体。所有字符串诊断来自固定白名单。

用户锁定内容的变化阻止自动接受改写，原文保留供审阅；启发式数字、单位、否定与长度信号进入待核对项，不能把合法等义改写一概判为协议错误。20/200、数字归属与重复次数要分别测试。任何字符串检查都不能证明全文事实保真。

### 5. 局部恢复，完整候选原子提交

| 情况 | 目标行为 |
|---|---|
| 分组建议无效 | 有界重试后采用确定性来源组，继续改写 |
| 改写可归属的单组结果无效/缺失 | 保留其他有效组；失败组使用原文并进入待确认 |
| 整个 envelope 无法解析、重复/未知 ID 导致归属不可信 | 拒绝该批结果，按批回退原文，不猜测抽取 JSON |
| Reduce 失败 | 保留进入该步骤前的候选，标记衔接未检查 |
| 所有组均未获得可用 AI 结果 | 明确显示未完成 AI 整理，提供原稿路径；不计为 AI 成功 |
| 认证失败/未配置/明确拒绝 | 停止后续模型调用，不通过反复拆窗规避拒绝；原稿和已有版本保留 |
| 取消/过期 generation/源映射损坏 | 不提交本轮候选，不伪装为正常 fallback |
| 保存失败 | 保留内存候选并标识未保存；不替换已保存活动版本 |

局部失败只放宽生成结果可用性，不放宽来源完整性。每个被选来源单元最终必须恰好属于一个 AI 候选组或原文回退组；不跨排除区间、不静默 omit。完整候选全部装配并通过来源校验后才一次提交。回退组显式标为待确认，用户可保留原文、修改、仅作提示或跳过；不存在自动默许采用。

恢复预算集中在 policy：每个失败项最多一次定向修复，分组、改写、能力模式退回、暂态和拆窗共享有界预算；不让阶段拆分使预算隐式翻倍。修复只携带固定诊断码、字段路径及同一份允许输入，不发送原始错误体或无界历史。

内存中已成功结果只在 source revision、选择、目标、pace、provider/model、prompt/schema 全部一致时复用。候选手工修改后递增 block revision，迟到回复不得覆盖；取消立刻停止新调度。首轮不引入跨 App 重启的任务恢复数据库。

### 6. 质量指标必须揭示回退

分别统计窗口首轮结构成功率、恢复后成功率、整稿完整候选率、AI 有效内容占比、原文回退占比、待审阅占比、人工编辑时间、事实错误、p50/p95 延迟、调用次数和 token。回退内容不能计入 AI 整理成功率。按来源内容量计量，不通过增加或合并组数刷指标。

整稿成功概率 p^N 仅是各窗口独立且成功率相同时的示意模型；实际窗口错误可能相关，不能当实测结果或预测承诺。

### 7. 2026-09-21 实施复审补充

- App 的提词器 grouping、rewrite、reduction 和 analysis 调用对一般兼容端点显式首选 strict `json_schema`；OpenCode Go adapter 直接使用 `json_object`，并保留对未知端点明确 `response_format type is unavailable` 的一次性降级。`LLMProvider` 按 endpoint/model/compatibility/operation/schema 摘要记忆明确的 strict 能力拒绝，后续同范围请求直接使用 `json_object`。
- `Retry-After` 的秒数或 HTTP 日期被保留到 `LLMError`，pipeline 在阶段级恢复前等待且响应取消；rewrite 失败只重试 rewrite，复用原 grouping，不重复消耗 grouping 请求。
- 准备流程的结构/暂态窗口失败在有界恢复后以逐字原文补齐完整候选并标记待确认；截断仍只允许一次安全拆窗，恢复预算不因两阶段协议隐式翻倍。

## Alternatives Considered

以下框架能力依据 2026-09-21 查阅的官方资料；适配结论是本项目工程判断，未进行框架性能对比。

| 方案 | 官方能力与本项目取舍 |
|---|---|
| AgentScope | [Pipeline](https://doc.agentscope.io/tutorial/task_pipeline.html) 提供顺序/fanout 编排，[Agent](https://doc.agentscope.io/tutorial/task_agent.html) 支持结构化输出；仍需自写业务校验与恢复。当前不引入额外运行时。未来需要多 Agent/工具生态时重新评估 |
| Pydantic AI / Graph | [Output](https://pydantic.dev/docs/ai/core-concepts/output/) 支持类型输出、验证与 ModelRetry；[Join](https://pydantic.dev/docs/ai/graph/builder/joins/) 支持并行汇聚。若未来有明确 Python 应用层，优先列入验证候选，不预判实测最优 |
| LangGraph | [节点与错误处理](https://docs.langchain.com/oss/python/langgraph/thinking-in-langgraph)、[持久化](https://docs.langchain.com/oss/python/langgraph/persistence) 适合长流程恢复/人工中断；当前单机短任务不足以抵消集成成本 |
| OpenAI Agents SDK | [代码驱动与模型驱动编排](https://openai.github.io/openai-agents-python/multi_agent/) 都可实现流程，但替换 Swift 调用链不直接改善本地 decoder 和内容策略 |
| 原生结构化输出 | [官方说明](https://developers.openai.com/zh-Hans/api/docs/guides/structured-outputs?api-mode=responses) 区分 JSON mode 与 schema 约束；用于减少形状错误，无法证明事实正确，也不能外推第三方兼容端点行为 |

## Consequences

保留 App 所有权、现有 SDK、单机部署和凭据边界；新增维护成本主要为阶段 schema、类型化诊断和局部恢复测试。公共 REST/Realtime/MCP 契约不变。

本记录是[终版规格](../superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md)的可靠性增量决策：未来实施时替换混合 Map、输出模式选择与 Map 失败行为，保留 preserve、审阅、取消、版本、时长与跟读原则。实施完成前，原规格描述当前基线，不能把本文目标写成已上线能力。

回退代码时以协调版本撤销新 wire 和调用方接线，不把新 wire 交给旧 decoder；用户原稿、编辑记录、候选和活动版本均保留。若实施发现必须修改持久化格式，先补迁移和恢复方案，不把内部协议更新当成迁移授权。
