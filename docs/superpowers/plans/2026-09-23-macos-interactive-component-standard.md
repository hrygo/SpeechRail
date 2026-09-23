# SpeechRail macOS 可交互组件规范实施计划

**目标：** 让全 App 的交互组件遵循同一角色、状态和无障碍合同，并修复已定位的键盘操作缺口。

**方案：** 以现有原生 SwiftUI 控件、`SpeechRailDesignTokens`、`WorkspaceComponents` 为基础。先把规范纳入 active 文档，再收紧共享组件接口，最后只修改不符合合同的具体页面，不批量替换有意的原生样式。

**技术：** macOS 26+、SwiftUI、AppKit、SF Symbols。

**设计依据：** `docs/superpowers/specs/2026-09-23-macos-interactive-component-standard-design.md`

## 边界

- 不修改 SpeechRail 服务、XPC 协议、模型与用户持久化数据。
- 保留现有未提交改动；只修改已核对过的代码段。
- 不新增或运行测试，不运行接管前台的 UI 自动化，不自动构建或替换安装。
- 不自动提交、推送或创建发布物。

## 工作项

### 1. 规范入库

- 在 `docs/developers/macos-app-design-system.md` 增加“可交互组件状态与例外”小节。
- 写清按钮、工具栏、行内动作、选择行、输入、紧凑浮层与反馈的角色和状态矩阵。
- 明确 `.small` 设置按钮、字幕浮层紧凑控件等原生例外。

### 2. 收紧工具栏动作接口

- 修改 `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift` 的 `PageActionButton`，使 `helpText` 成为构造所需的明确文字。
- 无障碍名称只取可见标题或明确的 `helpText`，不使用 SF Symbol ID。
- 逐个核对 `PageActionButton` 调用点并补齐缺少的说明。

### 3. 修复音色选择行

- 修改 `macos/SpeechRailApp/SpeechRailApp/AssistantView.swift` 的 `voiceRow`。
- 使用独立的选择按钮和试听按钮；移除容器上的 `.onTapGesture`。
- 保留不可用音色门禁、试听中的停止行为和当前选中状态；给选择按钮添加名称、选中 value 和提示。

### 4. 对照全部交互家族收口

- 对照 14 个路由、Settings、菜单栏、字幕带与提词器窗口，检查纯图标名称、原生焦点、选中状态、busy/disabled 解释和视觉 token。
- 只处理有证据的偏差；原生 `Button`/`Picker`/`Toggle` 等合规用法维持原样。
- 检查 `git diff`，区分本轮修改与已有未提交改动。

### 5. 最小静态核对

- 对本轮修改的 Swift 文件执行语法解析。
- 执行 `git diff --check`，核对设计系统文档与代码同义。
- 明确记录未做构建、安装和前台视觉验收的范围。
