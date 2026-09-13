---
title: "SpeechRail macOS 26 App 最佳实践整改"
status: approved
audience: "SpeechRail macOS App 开发、测试与发布维护者"
version: "0.1.0"
date: 2026-09-13
---

# SpeechRail macOS 26 App 最佳实践整改

## 1. 背景与目标

2026-09-13 对 SpeechRail 原生 macOS App 进行 macOS 26 / Xcode 26 最佳实践审查后，确认
App target、NavigationSplitView、MenuBarExtra、Settings、模型下载边界和 Distribution 配置
已经建立，但以下行为仍未形成可发布闭环：

1. `SMAppService` 的用户批准、禁用和失败状态没有被 App 明确呈现；
2. Liquid Glass 被逐面板应用，缺少相邻元素的采样分组，并存在 detail 背景影响 scroll-edge effect 的风险；
3. 运行监控图表和模型档位选择缺少完整的 VoiceOver 语义；
4. 长时间模型准备 operation 只存在于 App/Agent 内存中，App 重启后无法恢复操作上下文；
5. macOS 26 的深色模式、增加对比度、Dynamic Type、Reduce Motion 和 VoiceOver 尚未完成实际验收。

本整改将上述问题收敛为可测试的 App 行为，不降低 `SpeechRailApp` 的 macOS 26 deployment target，
不把模型下载、音频处理或服务生命周期复制到 GUI App。

## 2. 范围与非目标

### 2.1 范围

- `macos/SpeechRailApp` 的 SwiftUI UI、ControlKit、ControlAgentCore、XPC transport 和 App 测试；
- macOS App 设计系统、开发测试和发布文档；
- 新增一个 ADR，记录授权、Liquid Glass 和 operation journal 的取舍。

### 2.2 非目标

- 不修改当前未提交的 MCP/Python 改动；
- 不新增远程管理 HTTP API，不允许用户输入模型 URL、路径或 shell 参数；
- 不改变 `com.speechrail` Python 服务、模型 manifest、profile transaction 或运行时资源治理；
- 不增加 App Store 沙盒支持。本阶段仍是 Developer ID + notarization 的站外直接分发；
- 不把 App target 降到 macOS 14，也不增加 Material、`#available` 或 AppKit 视觉 fallback；
- 不在本机没有 Developer ID identity 时伪造签名、公证或 Gatekeeper 通过结果。

## 3. 设计原则

- **系统优先**：使用 macOS 26 SwiftUI 的标准结构、toolbar、控件和 Liquid Glass API，定制效果只服务于层级和语义。
- **用户批准可见**：系统服务授权是用户状态，不在 App 启动时隐式注销或反复重注册。
- **状态诚实**：缺失、未知、中断和未批准不能渲染为正常；下载完成不等于档位已经应用。
- **长任务可恢复**：只持久化 operation ID、档位、阶段、字节进度和错误码等脱敏元数据，不持久化路径、token、日志或模型内容。
- **可访问优先**：视觉状态必须有文字和控件语义；图表必须提供数据描述，展开控件必须保留展开动作。

## 4. 服务授权闭环

### 4.1 生命周期

`SpeechRailApp` 初始化时只创建 `ControlAgentRegistration` 和 transport，不调用
`unregister()` 或吞掉注册错误。Debug/Release 使用内嵌 `com.speechrail.desktop.local-control.xpc`，
不访问 Distribution 的 `SMAppService` 注册记录；清理旧注册记录只能由显式的开发/卸载流程完成。

Distribution 首次需要控制操作时按以下状态处理：

| `SMAppService.Status` | App 行为 |
|---|---|
| `enabled` | 允许执行 XPC 控制操作 |
| `notRegistered` | 由明确的“启用控制 Agent”动作调用 `register()`，成功后刷新状态 |
| `requiresApproval` | 不调用 `register()`，禁用 mutation，并提供打开 Login Items 的入口 |
| `notFound` | 显示安装包/Agent 缺失诊断，不能自动注销或重试注册 |
| 未知状态 | fail closed，显示“控制 Agent 状态未知” |

`ControlAgentRegistration` 提供一个无副作用的 status snapshot 和显式
`openLoginItemsSettings()` 操作。`AppModel` 暴露控制 Agent 状态；总览和诊断页显示该状态、
影响范围和下一步动作。注册错误保留稳定错误分类，不用 `try?` 转换成普通的“服务不可用”。

### 4.2 安全边界

- Distribution 继续要求 Team ID、same-team XPC code-signing requirement 和 Hardened Runtime；
- Debug/Release 的 unsigned 开关只存在于内嵌本地 XPC 测试资源，不得进入 Distribution bundle；
- helper 仍只接受固定 ControlKit 命令和固定 profile enum；
- 注册状态修复不能停止、删除或重置 `com.speechrail` 服务、runtime、模型和 profile journal。

## 5. Liquid Glass 与窗口层级

### 5.1 结构

保留 `NavigationSplitView` 的系统侧边栏玻璃、系统 toolbar 和 `backgroundExtensionEffect`。
同一页面内的相邻自定义玻璃元素由 `GlassEffectContainer` 包裹，使用统一的 spacing token；
不为没有交互语义的每一个 VStack 自动添加独立玻璃。

`glassEffectID` 只在确实需要跨状态 morph 的组件中使用，不为静态面板增加无意义的 ID。
`speechRailSurface` 继续作为产品层样式入口，但页面负责声明玻璃元素的分组边界。

### 5.2 背景

控制中心 detail 不在包含 toolbar 的根容器上叠加自定义深色/分组背景；需要分组背景的内容
放在 ScrollView 内容层，避免覆盖系统 scroll-edge effect 的采样区域。页面在最小窗口、全屏、
深色模式和增加对比度下检查玻璃文字的可读性。

## 6. 可访问性

### 6.1 运行监控

监控图表新增 `AXChartDescriptorRepresentable` 描述：

- 图表标题和摘要；
- X 轴采样时间；
- Y 轴活跃请求数；
- 每个样本的时间和值；
- 没有足够样本时，空状态文字作为唯一结果，不创建空图表。

监控数字和状态继续同时提供可见文字、图标/形状和 accessibility label/value；动态刷新控件
不依赖颜色或动画表达变化。

### 6.2 模型档位与制品

档位选择必须向 VoiceOver 暴露标题、用途、容量和“已选择/未选择”状态。保留当前视觉行式
选择器，不强制改成与设计包不一致的旧控件。

模型制品的 `DisclosureGroup` 必须保留展开/收起动作和技术详情可达性；不在整个
`DisclosureGroup` 上使用会吞掉子控件语义的 `.accessibilityElement(children: .combine)`。

### 6.3 验收矩阵

UI Test 和人工验收至少覆盖：

- Light / Dark；
- Increase Contrast；
- 用户字体增大和 Dynamic Type；
- Reduce Motion；
- VoiceOver 顺序：导航 → 页面定位 → 主操作 → 状态详情；
- 键盘/Full Keyboard Access 可到达所有主操作和展开控件。

## 7. 模型准备 operation 恢复

### 7.1 ControlKit 数据模型

在保持 `schemaVersion = 1` 的前提下，以可选字段向后兼容地扩展：

- `OperationSnapshot.profile: SpeechRailProfile?`；
- `OperationState.interrupted`，表示 ControlAgent 重启后无法重新附着原子进程；
- `ModelStatusSnapshot.activeOperation: OperationSnapshot?`。

旧 Agent 返回缺少这些字段时，App 按没有可恢复 operation 处理，不猜测下载状态。

### 7.2 Agent journal

`AgentOperationStore` 注入一个 `OperationJournal`，默认写入 managed app home 下受控的内部状态文件。
Journal 只允许保存：

- operation ID；
- command 和 profile；
- accepted/running/interrupted/failed/committed/cancelled 状态；
- phase、artifact key、当前文件名的安全标识和字节进度；
- error code、path-free message 和更新时间。

写入采用临时文件 + 原子替换；写入失败不阻塞当前 operation，但 `modelStatus` 返回明确的
recovery warning。Agent 启动时读取 active journal：

- 若 Agent 仍持有活动 runner，向 `modelStatus` 返回 active operation，App 可继续轮询和取消；
- 若 Agent 已重启且无法附着原进程，将 operation 标记为 `interrupted`，清除 active mutation，
  App 显示“上次准备被中断”，只提供重新准备，不伪造可取消或继续下载；
- 终态 operation 在写入一次终态后清理 active journal，最终结果以 `model status` 的 manifest
  校验为准。

### 7.3 App 重启流程

`AppModel.refreshModels()` 读取 `ModelStatusSnapshot.activeOperation`：

- 恢复 active operation 时恢复档位、阶段、进度和取消入口；
- 恢复 interrupted operation 时显示恢复建议并保留当前 active profile；
- 没有 operation 时只显示逐制品状态；
- 下载成功后再次读取 catalog/status，确认 revision、文件计数和完整校验，不信任 journal 的终态。

模型页仍明确区分“下载并校验”和“应用此档位”；App 退出不停止已经运行的 SpeechRail 服务。

## 8. 测试策略

### 8.1 先写失败测试

每个整改行为先添加失败测试，再实现：

- `ControlAgentRegistration` 在 `requiresApproval` 时不调用注册，并返回 Login Items 恢复状态；
- Debug/Release App 初始化不调用 Distribution Agent 的注销；
- `ModelStatusSnapshot` 缺失 active operation 字段时可以解码；
- operation journal 在 App 重启语义下恢复 active/interrupted/terminal 状态；
- AppModel 从 model status 恢复 operation 和 selected profile；
- Profile choice accessibility value 包含 selected 状态；
- Chart descriptor 包含时间轴、请求数轴和样本摘要；
- DisclosureGroup 的展开语义没有被合并为静态文本。

### 8.2 验证命令

代码与测试完成后执行：

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

Distribution 有真实证书后额外执行 archive、逐项 nested code signature、Hardened Runtime、
`spctl`、notarization、stapler 和干净目录安装验收；没有证书时只能报告阻塞，不标记发布通过。

## 9. 回退策略

- UI/Glass/accessibility 变更可以独立回退 App commit，不影响 Python runtime 和模型；
- ControlKit 可选字段保持 schema 1，旧 Agent 缺少字段时 App 降级为不可恢复状态，不执行危险重放；
- journal 文件损坏时删除精确的 active journal 并以 `model status` 重新核验，不删除 verified snapshot；
- SMAppService 状态修复失败时保留用户原有授权状态，不自动注销、不切换服务 owner；
- 每个逻辑整改使用独立 commit，便于逐项回退。

## 10. 参考

- [Apple Human Interface Guidelines: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Apple WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple: Accessibility chart descriptors](https://developer.apple.com/documentation/swiftui/view/accessibilitychartdescriptor%28_%3A%29)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
