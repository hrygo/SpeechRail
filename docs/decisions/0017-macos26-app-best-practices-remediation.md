# ADR-0017: macOS 26 App 最佳实践整改与可恢复控制面

## Status

Accepted

## Date

2026-09-13

## Context

SpeechRail 的原生 macOS App 已采用 macOS 26-only SwiftUI 控制面、`NavigationSplitView`、
`MenuBarExtra`、`SMAppService` helper、XPC 控制协议和模型下载页面。审查发现，当前实现会在
启动路径处理 `SMAppService`，但没有完整呈现用户批准状态；自定义 Liquid Glass 面板之间没有
明确的采样分组；监控图表与模型档位选择的 VoiceOver 语义不完整；长时间模型准备 operation
只保存在 App 和 Agent 内存中。

这些问题会影响用户对控制权限的理解、macOS 26 视觉一致性、辅助技术使用和多 GB 模型下载的
可恢复性。项目仍必须保持单一 Python 服务 owner、App 不加载模型、不直接执行 `launchctl`、
模型与敏感数据在 App bundle 外的边界。

## Decision

1. `SMAppService` 状态由 App 显式观察和呈现。App 启动不再自动注销 helper；`requiresApproval`
   不触发重注册，而是引导用户打开 Login Items。Debug/Release 内嵌 XPC 不接触 Distribution
   注册记录。
2. macOS 26 UI 使用 `GlassEffectContainer` 管理同页相邻玻璃元素，减少逐面板独立采样；
   toolbar 根容器不叠加会干扰 scroll-edge effect 的额外背景。
3. 监控图表使用 `AXChartDescriptorRepresentable`，模型档位暴露 selected accessibility
   value，制品 `DisclosureGroup` 保留展开语义。
4. ControlKit 在 schema 1 中增加可选的 operation profile、interrupted state 和
   `ModelStatusSnapshot.activeOperation`。Agent 用脱敏、原子写入的 journal 保存活动 operation；
   App 重启可恢复活动 operation，Agent 重启且无法附着原进程时显示 interrupted 并要求重新准备。
5. 保持站外 Developer ID + notarization 发布目标。没有 Developer ID 时，Debug/Release 的
   ad hoc 构建和测试只证明本地开发链路，不证明可分发包。

## Alternatives Considered

### 启动时自动注销并反复注册 `SMAppService`

- 优点：可以清理开发机上旧的失败记录。
- 缺点：会触碰用户授权状态，无法区分用户禁用与安装异常，也无法给出批准恢复路径。
- 拒绝：开发清理不应隐藏在生产 App 启动路径；改用显式开发/卸载流程。

### 只在 App 内保存 operation 状态

- 优点：实现简单，不改变 ControlKit。
- 缺点：App 重启后丢失模型下载上下文，无法恢复取消入口。
- 拒绝：模型准备是长任务，控制面必须至少能够从 Agent 重新读取脱敏状态。

### 让 GUI App 自己拥有模型下载和后台任务

- 优点：App 可以直接控制进度和生命周期。
- 缺点：突破 SpeechRail 的服务 owner、安全边界和外部模型存储设计；可能产生第二套下载/取消实现。
- 拒绝：下载继续由受控 Agent/managed Python runtime 执行，App 只观察和发出固定命令。

### 对所有面板继续单独应用玻璃

- 优点：页面实现简单且视觉上统一。
- 缺点：相邻玻璃采样可能不一致，过多玻璃会削弱内容层级。
- 拒绝：按 macOS 26 Liquid Glass 采样模型使用明确分组和有限的产品玻璃。

## Consequences

### Positive

- 用户可以理解并修复 control agent 的批准状态，不会因 Debug App 启动改变 Distribution 授权。
- macOS 26 的玻璃、toolbar 和 scroll-edge effect 有明确的结构边界。
- VoiceOver 能读取监控数据和档位选择状态。
- App 重启不会立即丢失活动模型准备 operation；Agent 重启也不会伪造可恢复能力。

### Negative

- ControlKit 的可选字段和 `interrupted` 状态需要同步单元测试与 UI 文案。
- journal 需要处理文件损坏、原子替换和旧版本兼容。
- Developer ID 发布仍需要真实证书、Keychain profile 和外部网络，无法在当前无 identity 的机器上闭合。

## Verification

实现必须先通过失败测试，再通过 macOS App build/unit/UI test、plist lint、Python gate、
Distribution archive/signature checks 和人工辅助功能验收。任何只通过 Debug build 或 unit test
的结果，都不能作为 macOS App 最佳实践完整通过的证据。
