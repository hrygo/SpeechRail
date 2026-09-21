# 提词器 Chat Completions 实施方案

> **For agentic workers:** 使用 executing-plans 在当前 worktree 连续实施；用户已授权“验证、生成方案、落地”，不增加中间确认。

**Goal:** 提词器使用非流式 Chat Completions、JSON mode 和严格本地校验，支持任意标准 OpenAI-compatible endpoint/model，并通过显式 adapter 兼容 OpenCode Go 与本机模板端点。

**Architecture:** 通过 `MacPaw/OpenAI` 0.5.1 增加独立的结构化 Chat 调用方法，复用 LLM 配置、凭据和传输生命周期。Map 的 wire 编号以窗口为单位从零开始，decoder 验证后恢复全局来源；其他模块继续使用自己的 Responses 功能。兼容 provider 的非标准字段和响应差异集中在 SDK middleware，不扩散到业务层。

**Tech Stack:** Swift 6、MacPaw/OpenAI 0.5.1、Foundation URLSession、JSONEncoder/JSONDecoder、现有 Swift Testing/XCTest。

**Spec:** `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md`，本方案同步修订其请求协议和 Map 坐标定义。

## 验证依据（2026-09-21）

使用临时 Swift 可执行程序直接编译生产 prompt builder、Map/Reduce decoder、Annotation client；真实请求通过 Chat Completions JSON mode，将生产 schema 的完整 `schema` 对象追加到 system。凭据只经内存/标准输入传递，未记录原始响应或完整 prompt。

| 模型/路径 | 生产矩阵结果 | 备注 |
|---|---:|---:|
| oMLX | 10/10 端到端场景 | 包含非零窗口、截断恢复和完整 pipeline |
| 通用 OpenAI-compatible | 10/10 场景 | 包含多窗口 Map/Reduce 与来源保真检查 |
| 直连 OpenCode Go DeepSeek | 10/10 场景 | 包含多窗口 Map/Reduce 与来源保真检查 |

每个 provider 使用同一组生产场景：纯文本、Markdown 表格、未闭合代码围栏、指令式原文、非零来源窗口、较长多单元稿件、Reduce、Annotation、完整 pipeline 与预算保护。oMLX 的一次原始 Map 响应触发了既有结构恢复路径，端到端 pipeline 通过；直连 OpenCode Go DeepSeek 全部场景直接通过。两条路径均把不确定代码内容标为 review，属于正确的候选审阅状态。

这些结果证明接入和本地结构契约可运行，不证明生产语义质量达标；没有完成 60 文稿/30 留出集、人工双评、真实 ASR 或 UI 验收。不能将保真字串检查称为事实验证。

## Global Constraints

- 当前 worktree 实施，保留现有 MCP/TTS 并行改动；不改服务配置、不重启、不安装、不迁移数据。
- macOS 26.0 / Apple silicon；持久化 v2 格式不变，无旧协议兼容分支。
- 真实模型设计验证独立于单元测试；单元测试只验证确定性的请求、解析、坐标和恢复边界。
- 不额外上传 ASR、历史或私有资料；system 固定规则与 schema 在前，user 原稿资料在后。

## Review Focus

- `finish_reason=stop` 但 usage 到达预算：必须作为疑似截断拒绝。
- reasoning、refusal、tool_calls、多个 choices、缺失 usage：不能误收为正文。
- 非零窗口、背景编号和 tighten 当前块：局部与全局坐标不能混用。
- 转义后的同名 JSON key：必须拒绝重复键，不能通过编码差异绕过。
- Map 截断恢复、取消和迟到结果：共享恢复上限，不提交半份候选。

### Task 1: 结构化 Chat 传输与 App 接入

**Files:** `LLMProvider.swift`、`App.swift`、`LLMProviderTests.swift`（均位于 macOS App 相应目录）。

**Interfaces:** 新增 `LLMProvider.completeJSON(configuration:apiKey:instructions:input:schema:maxOutputTokens:timeout:) async throws -> String`。schema 接收现有包装，其 `schema` 子对象是 system 输出定义的唯一来源。

- [x] 先添加 fake transport 回归：请求路径 `/chat/completions`、`response_format={"type":"json_object"}`、`stream=false`、`max_tokens`、system 含完整 schema；只读 `choices[0].message.content`。
- [x] 添加预算耗尽、缺失 usage、非 stop 结束、refusal/tool call、非法 JSON 和 HTTP 失败回归。
- [x] 实现 SDK middleware、取消检查和 provider 响应适配；`length` 或 `completion_tokens >= max_tokens` 抛出 `LLMError.outputTruncated`。拒绝原因为稳定用户文案，不回显模型正文。
- [x] 将 App 的 preparation、reduction 和 annotation 闭包切到此方法。其他模块原有 Responses 方法不变。

验证：`swift test --package-path macos/SpeechRailApp --filter LLMProviderTests`；预期 fake 测试全部通过。

### Task 2: Map 局部坐标、严格解析与截断恢复

**Files:** `TeleprompterPreparationPrompts.swift`、`TeleprompterPreparationPipeline.swift` 及对应 Tests。

**Interfaces:** Map builder 把目标和 current_blocks、read_only_context 转换到同一局部坐标；Map decoder 仍接收全局 targets，返回全局范围的 `TeleprompterMapOutput`。

- [x] 添加来源从 24 开始、带前后背景和 tighten 当前块的回归；期望 wire targets 为 0/1，decoder 恢复为 24/26。
- [x] 保留 schema 结构及其版本；提高 prompt 版本并明确局部坐标，不维护旧全局 wire 编号路径。
- [x] 对转义重复键补回归并修复 strict JSON scanner。
- [x] 疑似截断直接拆成两个安全子窗，子窗不再递归拆分，额外请求计入现有共享恢复上限；单单元或预算不足时明确失败。

验证：`swift test --package-path macos/SpeechRailApp --filter Teleprompter`；实际相关 Swift Testing 64/64 通过。

### Task 3: 生产路径复测与文档交付

**Files:** 终版 spec、当前提词器用户文档、本方案。

- [x] 临时验收程序切为调用生产 `completeJSON`，复测两个 provider 的同一矩阵，并运行实际多窗口 preparation pipeline；验收程序已移除，不进入产品 target。
- [x] 同步 spec 的 provider 能力、请求、局部编号示例和截断恢复；明确 JSON mode 与本地业务校验的职责。
- [x] 运行 App 编译和完整确定性测试，审查本次 diff，记录剩余质量/UI 验收范围。

验证：`swift test --package-path macos/SpeechRailApp` 实际 XCTest 136/136、Swift Testing 64/64 通过；`xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' build` 实际 `BUILD SUCCEEDED`，未启动 App。

## 实施记录

- 决策：按用户给定顺序，完成双 provider 预验证后形成方案并连续实施。
- 决策：不引入本地代理层；使用用户选定兼容模式的直连 Chat 路径。代价是服务端不保证 schema，本地严格校验与有界恢复成为必要条件。
- 决策：通用模式不发送 OpenCode/oMLX 专有字段；所有模式都不主动开启 thinking，provider-specific 的关闭表达只由显式 adapter 负责。
- 决策：结构化提词器请求统一使用 MacPaw/OpenAI 0.5.1；只保留 Responses 的现有手写适配给助手、纪要等非提词器路径，避免为不兼容 provider 扩大 Responses 改造范围。
- 决策：MacPaw SDK 对 provider 返回的部分 `usage.*_details` 结构存在强类型解码敏感性；middleware 在解码前移除不参与业务判断的嵌套 detail，只保留聚合 token 计数。
- 回退：仅撤回本次提词器请求与坐标改动；持久化原稿和 v2 bundle 不变，不需要迁移或删除。
