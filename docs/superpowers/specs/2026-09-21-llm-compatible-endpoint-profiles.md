# LLM 兼容端点与思考控制设计

**日期：** 2026-09-21
**状态：** Approved for implementation
**范围：** macOS App 的外部 LLM 配置、Chat/Responses 请求边界、连接检查与日志

## 目标

SpeechRail 在支持 OpenCode Go 的同时，继续支持任意使用标准 OpenAI-compatible Chat Completions 或 Responses 形状的端点与模型 ID。端点地址和模型 ID 作为用户输入的 opaque value，不按 host、路径或模型名称推断 provider，也不建立模型白名单。

SpeechRail 的业务不需要 reasoning/thinking 输出。所有请求都采用“关闭 thinking”的策略；协议差异只由端点兼容模式 adapter 在请求边界表达，不能把 OpenCode、DeepSeek 或本机模板字段无条件发送给通用端点。

## 配置契约

`LLMConfiguration` 和 `LLMModuleOverride` 增加可持久化的 `compatibilityMode`：

| 模式 | 作用 | thinking 表达 | 专有 Header |
| --- | --- | --- | --- |
| `openAICompatible` | 默认，适用于任意标准 OpenAI-compatible 端点 | Chat 使用标准 `reasoning_effort=none`；Responses 使用标准 `reasoning.effort=none`；端点拒绝时有界退化为省略字段 | 无 |
| `openCodeGo` | OpenCode Go 的 Chat 端点 | 使用原生 `thinking.type=disabled`；拒绝时有界退化为省略字段 | `x-opencode-session` |
| `localTemplateCompatible` | 已验证的本机模板兼容端点 | 使用 `chat_template_kwargs.enable_thinking=false`；拒绝时有界退化为省略字段 | 无 |

`localTemplateCompatible` 只为保留当前本机端点的已验证行为，不代表其他 provider 必须使用它。UI 显示为“本机模板兼容”，不向用户暴露具体模型运行时名称。

缺少 `compatibilityMode` 的旧 UserDefaults / module override 解码为 `openAICompatible`。新增字段有默认值，现有 URL、model 和 key 的持久化语义不变。

## 请求边界

保留 `MacPaw/OpenAI` 作为标准 Chat transport。`OpenAIMiddleware` 只负责：

- 为所有模式设置普通的 `User-Agent`；
- 仅在 `openCodeGo` 设置 `x-opencode-session`；
- 按兼容模式注入或移除 thinking 字段；
- 捕获脱敏的响应元数据用于可观测性。

业务层只调用 `LLMProvider`，不拼 provider-specific JSON。Responses 的手写请求也通过同一兼容模式映射，不能固定写入 `chat_template_kwargs`。

thinking 控制的拒绝记忆键必须包含 `baseURL + model + compatibilityMode + operation`，避免一个 provider 的失败结论污染另一个协议模式。每个组合最多因为控制字段重试一次，重试请求不含任何 thinking 控制字段。

## 能力检查

`check` 增加 operation 参数：`chat` 或 `responses`。默认保留 Responses 检查，设置页按模块选择所需操作：提词器检查 Chat，助手/纪要检查 Responses。

`GET /models` 仅作为可选信息源。即使模型列表不可用或没有列出用户输入的 model，也必须继续探测实际操作；只有实际请求明确返回模型不存在时，才报告模型不可用。这样不会因为 provider 不实现 `/models` 或使用别名模型 ID 而误判。

检查结果新增 Chat 不可用分类；Responses 不可用仍只影响需要 Responses 的模块。通用 Chat-only provider 不再被全局的 Responses 探测逻辑误杀提词器能力。

## 可观测性

每个 LLM 请求日志记录：operation、compatibilityMode、thinking control 状态（standard/native/template/omitted）、endpoint host、model、HTTP status、elapsed、response bytes、choice/finish reason、usage token、transport attempt 和稳定 error code。禁止记录 key、Authorization、完整 prompt、原始转写和完整响应正文。

macOS App 同时把这些已经脱敏的 observation 以 JSONL 追加到
ObservabilityLocation.logDirectory/teleprompter-ai/events-YYYY-MM-DD.jsonl，并在
run_finished 或无 pipeline context 的 provider terminal event 时追加当天的 metrics snapshot 到
ObservabilityLocation.historyDirectory/teleprompter-ai/metrics-YYYY-MM-DD.jsonl。
同一天的 snapshot 是截至 capturedAt 的累计值，读取时取当天最后一行。文件写入 fail-open，不得阻塞或改变 LLM 请求结果。metrics 只使用
stage、operation、compatibilityMode、outcome 和稳定 errorCode 等低基数维度；
run_id、request_id、model、host 只能作为日志字段，不能作为 metrics label。

metrics 至少覆盖 provider request/response/failure、provider 与 pipeline retry、
thinking control 被拒后的退化、LLM call/run 成功失败、请求/调用/run 时延直方图，
以及 provider 返回的 reasoning token 总量，用于识别“已请求关闭但上游仍返回 reasoning”
的兼容性问题。Chat、Responses 非流式、Responses 流式和后台轮询都发出 provider observation；
后台轮询的 thinking control 标记为 `not_applicable`。

## 非目标

- 不修改或卸载仓库外的本机代理服务、配置和凭据。
- 不实现任意用户可编辑 JSON 扩展字段；新增非标准 provider 规则必须新增显式 adapter。
- 不改变 SpeechRail ASR/TTS/Realtme 的公共协议。
- 不承诺 Chat-only provider 自动获得 Assistant/Minutes 的 Responses 能力；每个模块按其实际协议检查并给出可判定结果。

## 验收标准

1. 任意合法 HTTP(S) base URL 和任意非空 model ID 能保存并进入请求，不受 host/model 白名单限制。
2. 默认通用模式的 Chat/Responses 请求不含 OpenCode、模板或历史代理字段；thinking 通过标准禁用字段表达，拒绝后只重试一次且第二次省略控制字段。
3. OpenCode Go 模式才发送 `x-opencode-session` 和原生 thinking 字段，并在同一 run 内复用 session ID。
4. 本机模板模式继续发送并可退化 `chat_template_kwargs.enable_thinking=false`。
5. Chat-only endpoint 可以通过提词器的 Chat 检查；Responses-only 失败不会被伪装成通用连接成功。
6. 旧持久化配置缺少新字段时按通用模式加载。
7. 单元测试、Xcode Debug 构建和 `git diff --check` 通过。
