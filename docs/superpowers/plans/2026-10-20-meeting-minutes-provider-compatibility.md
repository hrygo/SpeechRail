# 会议纪要 Provider 兼容性修复计划

> **For agentic workers:** 使用 executing-plans 在当前会话逐项实施；不自动提交、安装或操作运行服务。

**Goal:** 纪要沿用配置解析结果中的 endpoint、model、key 和兼容模式，不要求 provider 支持后台响应。

**Architecture:** 新任务由 App 的现有租约、分窗与版本 owner 管理，调用无状态结构化接口。优先 Chat Completions JSON mode；仅在明确拒绝接口时改用同一配置的普通 Responses。仅在明确拒绝格式能力时去掉格式参数，完整 schema 仍进入提示，严格 JSON 与业务证据校验仍为提交边界。历史远端 ID 继续只查询原请求。

**Tech Stack:** Swift、现有 MacPaw/OpenAI 0.5.1、URLSession、SQLite、XCTest fake URLProtocol。

**Spec:** 当前用户要求“提升纪要对 llm provider 的兼容性，当前协同提供了什么 provider 就使用什么 provider”，以及上一轮对 `Unsupported parameter: background` 的只读诊断。

## 约束

- 不替换 endpoint/model，不猜 provider 品牌，不引入新配置或依赖。
- 新纪要不发送 background 或显式缓存专有字段；Responses 子集仍使用现有 transport。
- 保留分窗、输入摘要、配置冻结、证据核对、代际 fencing、取消和版本追加规则。
- 发出请求前保存 submitted 窗口；无远端 ID 的 submitted 窗口不得在崩溃恢复时自动重发。
- 已明确失败的窗口可人工重试；结果未知的任务要求显式重新生成新版本。
- 无 schema 迁移；不改真实数据库、密钥、用户配置、服务或安装。
- 仅 fake provider 定向验证，不接管 UI、不发真实会议内容。

## 审查重点

- Chat-only、Responses-only 与拒绝 JSON 格式参数的 provider 均保持同一配置。
- 鉴权、限流、模型缺失、坏 JSON、拒答、截断不得触发跨接口重复生成。
- 请求中断与崩溃恢复不能重发；成功窗口可复用，历史远端 ID 不转换为新请求。
- 新任务不得继续发送 background；schema、引用和原文保存边界不放松。
- 连接检查与纪要实际接口保持一致，错误不回显上游原始正文。

## Task 1: Provider 与纪要任务

**Files:** `LLMProvider.swift`、`MinutesGenerator.swift`、`SessionStore.swift`、既有 `LLMProviderTests.swift` 与 `MeetingMinutesJobRecoveryTests.swift`。

- [x] 增加 fake provider 回归，确认现有实现无法完成 Chat-only 纪要。
- [x] 在共享 Provider 内加入受限的结构化接口协商；其他结构化调用默认行为不变。
- [x] 新纪要切换到普通结构化请求；先写 submitted，成功后写候选，明确失败可重试，未知提交禁止自动重发。
- [x] 保留历史响应 ID 的查询、恢复和取消路径。
- [x] 验证取消、坏输出、格式拒绝、接口拒绝与提交未知边界。

审查修正：窗口读取错误必须停止；usage 用严格整数解码；每次运行清空历史取消 ID。
“恢复历史任务后重新生成并停止”的回归暴露 `minutes_window.id=w0` 的跨版本唯一键冲突，
写入键改为纪要版本 ID 加窗口 ID，不迁移或删除既有记录，确保重新生成可保留多版检查点。
标准预算兼容：明确拒绝 `max_tokens` 并要求 `max_completion_tokens` 时才切换，
新兼容请求不强制 temperature；其他功能的参数默认值保持不变。

## Task 2: 配置检查与说明

**Files:** `SettingsView.swift`、LLM 模块能力声明、开发与架构文档。

- [x] 纪要连接检查优先 Chat，明确不可用才检查 Responses。
- [x] 更新正式文档中的纪要接口、隐私、恢复边界。
- [x] 运行相关 SwiftPM 定向测试、独立 LLM 编译守卫与 diff 检查。

## 验证记录（2026-10-20）

初始 Chat-only 纪要测试在旧实现上失败；修正后通过。布尔 usage、模型缺失措辞、
历史任务后的取消及标准预算字段/连接检查负例均经历失败到通过。
临时绕过无远端 ID 的 submitted 保护后，崩溃恢复用例出现额外请求并失败；保护已恢复。

```sh
swift test --package-path macos/SpeechRailApp --enable-swift-testing \
  --filter 'LLMProviderTests|LLMStreamDeliveryTests|MeetingMinutes|MeetingWindowCoverage|SessionPreferences'
python3 scripts/check_llm_support_boundary.py
python3 scripts/check_macos_test_target_coverage.py
swiftc -frontend -parse macos/SpeechRailApp/SpeechRailApp/SettingsView.swift
git diff --check
```

定向测试实际执行 204 项 XCTest、13 项 Swift Testing，均通过；独立 LLM type-check、
测试清单与 Settings 语法检查通过，新增 Markdown 链接目标存在。独立审查的问题已修正。
该轮未运行完整测试套件、App bundle 构建、UI 自动化或真实 provider/会议质量测试，
未安装 App、改服务配置或重启服务。

## 补充测试与验证（2026-10-20）

按用户补充要求新增 10 个回归用例，全部使用 fake `URLProtocol`、合成转录和临时 SQLite。
provider 与纪要任务两组定向运行实际执行 126 项 XCTest，全部通过。

| 检查范围 | 补充断言 |
|---|---|
| 参数协商组合 | 格式、token 预算和 thinking 拒绝的全部六种顺序都可完成；后续窗口复用已确认能力 |
| 能力缓存隔离 | endpoint、model、compatibility mode 分别变化时，不继承其他配置的格式、预算或协议选择 |
| 格式降级校验 | 坏 JSON、数组、重复键、拒答、tool call、截断、预算耗尽和缺 usage 均拒绝，不跨协议重发 |
| Responses usage | 缺失、null、负数、小数、字符串、布尔和溢出计数均拒绝 |
| 失败与重发 | Responses 鉴权、限流、模型缺失、5xx、无关 400、超时和取消都停止；两种接口均不支持时无循环 |
| Responses 纪要落库 | 自定义 base path、同一模型、去掉被拒绝的格式参数后生成成功；重开数据库仍保留候选与文字，不把普通响应 ID 当后台任务 |
| 引用核对 | 格式降级后，伪造来源仍标记为未通过引用核对，候选保留供复核 |
| 多窗续作 | 第一窗成功、下一窗 503 后重开数据库，只提交剩余窗口；版本与已保存候选保持一致 |
| 超长来源 | 切分后的来源覆盖、最终引用核对及不可变修订锚点保持一致 |

多窗补测暴露超长单条发言的来源 ID 对齐问题：窗口使用 `u1#…`，但生成器最终覆盖统计、
候选归并核对和锚点映射仍用切分前的 `u1`。完整覆盖断言在修正前失败；
三处统一使用窗口实际拥有的来源后通过，并补查所有分段的锚点可读原始修订。
此修正不改 schema、不迁移或触碰真实数据库。

```sh
swift test --package-path macos/SpeechRailApp --enable-swift-testing \
  --filter 'LLMProviderTests|MeetingMinutesJobRecoveryTests'
swift test --package-path macos/SpeechRailApp --enable-swift-testing
python3 scripts/check_llm_support_boundary.py
python3 scripts/check_macos_test_target_coverage.py
bash scripts/macos_app_build.sh --configuration Debug
git diff --check
```

App Debug 构建、独立 LLM type-check、测试清单检查通过；构建脚本的临时 App 目录已清理。
完整 Swift 首轮运行中 XCTest 1,857 项（4 项按条件跳过）无失败，
Swift Testing 667 项中系统音频重连的 `failedReconnectPreservesRecordAndReportsInterruption`
出现一次文案断言失败；该未改动用例及同组另外两项隔离复核均通过。
保留首轮失败记录，在没有并行 App 构建的条件下复跑完整测试，结果如下。

- XCTest：1,857 项，4 项按条件跳过，0 失败。
- Swift Testing：667 项、63 个 suite，0 失败。
- 完整测试进程退出码 0；首次失败的重连用例在完整复跑中也通过。
- 首轮失败提示可能存在负载相关时序敏感性；隔离与一次全包复跑通过不证明该问题已被修复。

未执行真实 provider/会议质量、UI 自动化或安装验收；未安装或启动构建的 App，
未修改真实服务配置或重启服务。

## PR 分支验证（2026-10-20）

从 `main` 的 `78995fb1` 建立独立纪要修复分支，仅带入本任务 13 个文件；
原 UI 分支及其未提交内容保持原样，不把另一个 PR 的 UI 改动带入。
在独立分支上重新运行完整 Swift 测试：XCTest 1,867 项（4 项按条件跳过）、
Swift Testing 669 项、64 个 suite，全部无失败，进程退出码 0。
用户文档契约、macOS 测试清单及独立 LLM type-check 通过。
同一分支的 App Debug 构建通过，临时构建目录已清理；未安装或启动 App。

## 回退

只撤回本任务涉及的代码和文档改动；保留原始转录、纪要版本、窗口记录与远端响应 ID。旧 App 不认识无远端 ID 的 submitted 窗口时，不用旧 App 续跑这些任务；可以保留记录并显式生成新版本。
