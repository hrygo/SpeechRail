# App 操作反馈浮层 Implementation Plan

> **For agentic workers:** Use the approved in-session implementation with independent code review. Each writer owns a disjoint set of files.

**Goal:** 全 App 操作结果和错误（含 Sheet）不挤压正文布局，保留正文准备入口、进度、持续状态和需用户决策的确认。
**Architecture:** 共享 `OperationFeedback` 与 `View.operationFeedback(_:)` 按宿主使用 overlay 展示一条反馈；错误持续显示，成功可定时关闭。迁移各页面与 Sheet 的操作回执，避免把页面状态或恢复入口迁走。
**Tech Stack:** SwiftUI / AppKit，macOS 26+，现有设计 Token。
**Spec:** 用户本回合要求与 `docs/developers/macos-app-design-system.md` §3.2。

## Global Constraints

- 不触碰用户作品、音频、真实配置或服务运行态；App 安装目标 `~/Applications/SpeechRail.app`。
- 每个文件唯一写入者；隔离 worktree 从 main 开始，保留原工作区的无关并行改动。
- 不运行 UI 自动化；只做确定性回归、离屏检查、构建、静态安装检查，真实交互未验收须明确报告。

## Review Focus

- 错误与成功并存、同文案再次发生：关闭不清错来源，错误不被成功覆盖。
- Sheet 打开时错误可见，正文/列表位置保持不变。
- 长错误、最小窗口：正文可滚动，关闭与动作固定可达。
- 关闭不取消任务或修改业务数据；带重试/撤销入口的反馈保留动作。
- 全仓遗漏扫描覆盖 Label/Text、原生结果 alerts 与 NSAlert helper；确认、状态、恢复内容不误迁。

### Task 1: 共享呈现与既有有声书修复

- [x] 在 `WorkspaceComponents.swift` 提供 `OperationFeedback` 与 `operationFeedback` overlay；独立滚动、有界宽高、手动关闭、Escape、成功定时关闭。
- [x] 为关闭/替换/重复文案与长内容建立有意义的确定性或离屏验证；新增测试先验证失败。
- [x] 迁移 `AudiobookWorkshopView.swift` 的专用浮层与各有声书 Sheet 操作错误；保留准备与进度。
- [x] 带入本会话已验证的空结果、制作校验终态与导出 UUID/终态错误修复，分逻辑提交。

### Task 2: 全 App 迁移

- [x] Creator/VoiceClone、Assistant/Meeting/Session、Teleprompter/Settings/Engine 各按独占文件范围迁移操作错误/结果。
- [x] 检查所有 NoticeBar、StatusBanner、Label/Text error、结果 alert/NSAlert；记录保留项的状态/确认语义。
- [x] 更新设计系统与用户文档，明确正文准备与任务进度例外。
- [x] 运行受影响单测、App wrapper build 与 diff 检查；独立审查并修复全部必改项。

### Task 3: 主干与安装

- [ ] 核实远端 main 保护与线性策略，提交精确变更、PR 审查后 rebase 合入；清洁主干快进同步。
- [ ] 从合入后的 main 构建候选 App；验证版本、来源、嵌套控制链。
- [ ] 备份已安装 App；作品与音频建立只读清单，正常退出并原子替换安装；静态验证唯一登记与数据清单一致。
- [ ] 报告 main commit、安装版本、回退点与未执行的 UI/真实编码等验证。

## 验证与审查记录（2026-10-23）

- 定向 SwiftPM 回归：145 项通过，覆盖有声书制作、工作流和窗口尺寸策略；导出相关 Python 回归 38 项通过。
- 变异检查：撤销 UUID 目录大小写归一后，新增的 4 个路径回归全部失败；恢复实现后 4 项全部通过。
- 离屏 `NSHostingView` 探针：无反馈、短消息、长消息时宿主尺寸不变；长消息卡片受 420×280 / 640×480 边界约束，96 高字幕宿主尺寸不变。
- 包装脚本 App 构建通过；Swift 语法解析、Python Ruff、plist 与 diff 检查通过。合入后还须从 main 构建安装候选。
- Xcode 单测入口在编译前因 test bundle specifier 解析失败阻塞；离屏探针单独运行，不能将其等同于 Xcode 单测通过。
- 独立源码审查覆盖共享、有声书、创作、会议/字幕、引擎/设置/提词器；修复重复错误身份、恢复成功宿主销毁、复制失败误报成功，以及不可用列表重试入口等问题。
- 图谱为旧 generation；变更与 parse 不完整处使用当前源文件、差异和调用点复核，没有据旧索引推断完整性。
- 没有执行 UI 自动化或真实窗口验收；滚动、Escape、焦点恢复、点击穿透及真实导出流程仍待交互验收。
