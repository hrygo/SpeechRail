# SpeechRail 设置模块一般用户优先 UI/UX 重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变 SpeechRail 服务端协议、UserDefaults 键和密钥安全边界的前提下，重构 macOS 设置 scene，使普通用户先看到启动、创作和助手连接任务；将模块覆盖、协议细节和诊断信息收进渐进式披露，并把 `SettingsView.swift` 拆成清晰的 SwiftUI 视图边界。

**Architecture:** 保留 `SettingsView` 作为 Settings scene 路由、共享异步连接状态和数据安全操作的协调器；把通用 settings row/section/layout 抽到 `SettingsComponents.swift`，把“助手”页抽到 `SettingsAssistantPane.swift`。子视图通过 `@Binding` 接收临时密钥草稿、连接状态和展开状态，通过 `@Environment(SessionPreferences.self)` 读写现有偏好。密钥策略在 `LLMProvider.swift` 保持纯函数：检查连接与持久化是两个显式动作，只有“检查并保存”成功后才写 `LLMKeychain`。

**Tech Stack:** SwiftUI、Observation、macOS 26、Xcode project、SwiftPM support target、XCTest、现有 `SpeechRailDesignTokens` 与原生系统控件。

**Spec:** `docs/superpowers/specs/2026-09-20-settings-general-user-ux-design.md`

## Global Constraints

- 只在当前独立 worktree 修改；不读取或覆盖父工作区的并行未提交实现。
- 保留现有 UserDefaults keys、`SessionPreferences` 的持久化边界、`LLMKeychain` 的安全落点和现有服务/协议实现。
- 不将 API key、完整错误、原始音频、完整转写或绝对路径写入 UI 测试、日志、文档或配置。
- 不引入旧 UI 的兼容分支；允许改变设置页布局、文案和 tab 名称。
- URL 含凭据时在本地字段附近即时提示，不能依赖网络请求才发现。
- 普通用户文案不把 LLM、provider、worker、profile、Responses API 作为主标题或主要动作名称；必要技术信息只放副说明/高级详情。
- 未获得新的 UI 自动化授权，不运行 XCUITest、Playwright、桌面自动化或前台窗口走查；可以更新 UI test 源码并运行确定性的 Swift 单元测试和 build-for-testing。
- 使用 `apply_patch` 编辑文件；不使用 `git checkout --`、`git reset --hard` 或整文件覆盖。

## Review Focus

- 密钥草稿是否只能由显式保存动作持久化，且保存失败时不伪装为“已保存”。
- Settings 的页签、信息架构和文案是否遵守一般用户优先与渐进式披露。
- `SettingsView`、共享组件和助手页之间是否形成清晰边界，避免把所有设置重新塞回单文件。
- SwiftUI accessibility label/value、键盘可达性、状态文字与颜色脱钩是否完整。
- Xcode project、SwiftPM exclude 和源码文件是否同步，避免只在一个构建入口可见。
- 是否只修改设置模块及其 active 设计系统/测试，不触及服务端、协议、模型或用户数据。

---

## Task 1: 先锁定显式密钥保存语义

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/SettingsKeyDraftPolicyTests.swift`

- [x] 在 `LLMProvider.swift` 的 `LLMKeyDraftPolicy` 附近新增 `LLMKeyDraftAction`（至少包含 `check` 与 `checkAndSave`），并提供基于草稿是否为空的纯函数动作判定。
- [x] 将持久化判定改为必须接收 `saveRequested` 的纯函数：草稿非空、连接结果为 `connected`、且调用方明确要求保存时才返回 true；移除不带显式保存意图的隐式判定入口。
- [x] 保留 `candidateKey(draft:storedKey:)`，保证检查时仍优先使用当前草稿、空草稿时使用已保存密钥。
- [x] 将单元测试扩展为：空草稿只能检查、非空草稿显示检查并保存、失败结果不保存、连接成功但未请求保存不保存、连接成功且显式请求保存才保存；测试只验证纯规则，不访问真实 Keychain。
- [x] 运行该测试文件可编译所需的最小 Swift 测试命令，确认 API 改动没有遗漏调用点。
- [x] 为服务地址的本地安全校验补充回归测试：query/fragment 地址在发起请求前判为无效。

## Task 2: 抽取共享 Settings 组件并保持构建入口一致

**Files:**
- Add: `macos/SpeechRailApp/SpeechRailApp/SettingsComponents.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`
- Modify: `macos/SpeechRailApp/Package.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

- [x] 将设置页的几何和结构辅助从 `SettingsView.swift` 移到 `SettingsComponents.swift`：`SettingsMetrics`、`settingsPane`、`settingsSection`、`settingsRow`、`settingsRowSeparator`、`settingsValueRow`、`settingsRowLabel`、`SettingsRowControlModifier` 及 `settingsRowControl()`。
- [x] 组件实现只复用已有 `SpeechRailDesignTokens`，不新增散落的颜色、圆角、字号或布局裸值；保留滚动、卡片地板、系统控件、焦点环和动态文字自然增高。
- [x] 为共享状态呈现提供可复用的连接结果视图/辅助：同时表达结论文字、用户可读详情、检查中进度和保存失败信息，不只依赖颜色或 pill。
- [x] 给共享 label/value 组件补齐 accessibility 组合语义，确保副说明与控件属于同一个可访问设置项；SecureField 不把真实密钥作为 accessibility value。
- [x] 从 `SettingsView.swift` 删除已迁移的私有 Metrics、布局 helper 和重复的 row modifier，保留 `SpeechRailHelpView` 等非设置内容。
- [x] 在 `Package.swift` 的 `SpeechRailAppSupport` exclude 列表加入两个新 App-only Swift 文件，避免 SwiftPM support target 将 SwiftUI Settings 文件当成未声明 source。
- [x] 在 `project.pbxproj` 中为两个新文件增加 file reference、build file、App group children 和 App Sources build phase 条目；不要改变其他 target 的源文件顺序或配置。
- [x] 对 project file 和新增组件执行 `git diff --check`。

## Task 3: 重构 Settings scene 的路由与共享状态协调

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`

- [x] 保留 macOS 原生 `Settings` scene 和四个 tab，顺序固定为 `通用 / 创作 / 助手 / 服务`，将原“会话”改为“助手”。
- [x] 让 `SettingsView` 只负责通用、创作、服务 pane、临时 key draft/connection state、异步检查、Keychain 读写和子视图 action closures；不再直接渲染助手页的大段表单。
- [x] 将全局和模块连接方法改为接收 `saveRequested`，按钮在有非空草稿时显示“检查并保存”，无草稿时显示“检查连接”；检查连接本身永不隐式写入 Keychain。
- [x] 删除独立的“保存到钥匙串/保存专用 Key”主按钮，避免出现与“检查并保存”竞争的第二套写入路径；保留明确的“清除密钥”动作和失败反馈。
- [x] 检查成功后仅在显式保存动作下调用现有 `persistDraftKeyIfPresent`；Keychain 写入失败时保留 connected 结果、保留草稿、显示“连接已通过，但密钥未保存”，不将 `llmKeySaved` 或模块 saved 状态误置为 true。
- [x] 连接状态在同一助手页状态区内持续显示；已保存密钥、未配置、检查中、连接失败、保存失败分别有明确文字和可访问描述。
- [x] 保持检查时的候选 key 规则：新草稿只用于当前请求，空草稿读取既有安全存储；不把 key 传入 URL、UserDefaults、错误日志或 UI test。
- [x] 在服务地址字段下方增加同步的本地校验文案：非空且含 query/fragment/credential 等非法内容时直接说明“地址里不要放密钥”或正确填写 `http(s)` 地址；未配置时不发起请求。
- [x] 将 page frame、minimum window size 和已有 token 复用保持不变，避免把设置模块重构误变成窗口几何重设计。

## Task 4: 实现助手页的一般用户优先信息架构

**Files:**
- Add: `macos/SpeechRailApp/SpeechRailApp/SettingsAssistantPane.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift`（仅接入子视图与绑定）
- Modify: `macos/SpeechRailApp/SpeechRailApp/SessionPreferences.swift`（仅在确有需要时补 presentation helper，不改 keys/解析）

- [x] 新建 `SettingsAssistantPane`，通过 `@Environment(SessionPreferences.self)` 使用现有偏好，通过 `@Binding` 接收临时密钥草稿、保存状态、检查结果、检查中状态、检查模块和高级展开状态，通过显式 closure 触发父级异步检查、清除和备份动作。
- [x] 将页面顺序固定为：对话服务 → 新助手默认值 → 字幕与会议 → 通知 → 高级：按功能单独设置。
- [x] 对话服务区域只展示用户需要的服务地址、模型、密钥状态和“检查连接/检查并保存”；把 Responses API 作为“该服务需要支持 Responses API”的副说明，不把它做成配置控件。
- [x] 新助手默认值保留默认角色、默认音色、对讲模式，沿用 `SessionPreferences` 的绑定；对讲模式使用“能否打断/建议耳机”的用户语言。
- [x] 将字幕默认字号、字幕说话人标签、会议说话人标签和记录库动作收进“字幕与会议”；记录库旁明确写出“不保存音频，只保留文字与说话人归属”，打开目录和备份动作分开。
- [x] 保留中断通知开关，说明通知只在需要用户决定时出现且不包含记录原文。
- [x] 高级区默认折叠；只有已有模块覆盖时才按当前数据需要展开。模块顺序严格使用 `LLMModule.allCases`，每个模块先显示“跟随全局/使用专用配置/专用配置不完整，当前回退到全局”状态，再显示专用字段。
- [x] 模块密钥遵循与全局相同的显式“检查并保存”规则；清除模块密钥后只回到继承全局密钥，不改地址和模型。
- [x] 不在助手页加入服务启停、模型下载、profile 切换、worker 监控或端口写入控件；服务页保持只读事实和报告偏好。
- [x] 检查所有交互控件都有可见文字、键盘可达路径、VoiceOver label/value；不新增装饰动画，DisclosureGroup 和 ProgressView 使用系统反馈。

## Task 5: 更新 active UI 契约和源码级回归断言

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`
- Modify: `docs/developers/macos-app-design-system.md`
- Modify: `docs/superpowers/specs/2026-09-20-settings-general-user-ux-design.md`

- [x] 更新 `testSettingsContainAppPreferencesOnly` 的注释和源码断言，使其描述四个 tab，至少覆盖“通用”“创作”“助手”“服务”以及默认页的“启动与窗口”；不把真实服务、密钥或网络连接引入测试。
- [x] 在 active 设计系统中补充 Settings 组件契约：原生 `Settings` scene、四 tab 信息架构、共享 row/section、默认折叠的模块覆盖、连接状态文字与 accessibility 语义、密钥显式保存；不要改写历史验证记录来伪造新的视觉实测结论。
- [x] 仅在实现与验收完成后把 spec 的 `status` 从 `draft` 更新为 `implemented`，并写明本次实际验证时间与 UI 自动化仍未执行；如果构建阻塞则保持 `draft` 并记录事实。
- [x] 检查 active 文档、spec 和 UI test 中不出现真实密钥、绝对模型路径或可复制的敏感配置。

## Task 6: 构建、单元测试与最终验收

**Files:**
- Modify only files required by Tasks 1–5.

- [x] 先执行 `git status --short --branch`、`git diff --stat`、`git diff --check`，确认没有越界修改。
- [x] 执行 `scripts/macos_app_build.sh --configuration Debug`，记录实际退出码和失败原因；不修改无关并行文件绕过构建错误。
- [x] 执行：
  ```bash
  xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj \
    -scheme SpeechRailApp -configuration Debug \
    -destination 'platform=macOS' build-for-testing
  ```
- [x] 执行设置策略单元测试（Xcode scheme 不包含 SwiftPM 的 `SpeechRailMacControlTests`，实际入口如下）：
  ```bash
  swift test --package-path macos/SpeechRailApp \
    --filter SettingsKeyDraftPolicyTests
  ```
- [x] 运行完整 `swift test --package-path macos/SpeechRailApp`，确认新增 URL 校验与密钥策略没有回归其他 SwiftPM 测试。
- [x] 如 Xcode 许可、SDK、并行源错误或环境阻塞，保留完整错误摘要并将对应验收项标为未验证；不运行 `scripts/macos_app_test.sh` 或任何 UI 自动化。
- [x] 最终复核：tab/文案/密钥语义/数据 key/文件职责逐项对照 spec；确认 SettingsView 不再包含助手页大段表单，新增文件已同时进入 Xcode 与 SwiftPM 排除规则。
- [x] 输出交付报告：改动文件、实际验证时间、成功/失败命令、未执行的 UI 验证、未兼容事项、回退方式和 worktree 路径；不自动提交或推送。

## Handoff

Native execution 已在独立 worktree 完成 Task 1–6。未提交、未推送，等待用户决定是否将该 worktree 的改动合并到目标分支。
