# SpeechRail macOS 26 UI/UX 验收矩阵

> 本文件是 GitHub Issue #79 和本地执行计划
> docs/superpowers/plans/2026-09-21-speechrail-macos26-uiux-audit-execution.md 的证据账本。
> 它区分源码/静态证据、纯函数或构建证据、人工桌面证据和经授权的 UI 自动化证据。
> 交接报告见 [UIUX-DELIVERY-REPORT.md](./UIUX-DELIVERY-REPORT.md)。

## 1. 基线

| 项目 | 当前值 | 证据 |
|---|---|---|
| 验收日期 | 2026-09-22 | 当前任务基线 |
| 分支 | main | git status --short --branch |
| 最近提交 | 4318e799 | git log -1 --oneline |
| 平台目标 | macOS 26.0+，Apple Silicon arm64 | Package.swift、项目规则 |
| 跟踪 Issue | #79 | https://github.com/hrygo/SpeechRail/issues/79 |
| UI 自动化 | 2026-09-22 获明确授权；完整 App test plan 255/255 通过 | `/tmp/speechrail-uiux-final-test-plan-rerun-20260922.xcresult`；未改 TCC 权限 |

### 1.1 既有未提交改动

以下文件在本矩阵建立前已经存在未提交改动。本轮没有回退、整文件覆盖或清理这些改动；需要触及时先读取既有 diff，再把本计划变更与其分离。`SpeechRailDesignTokens.swift` 本轮仅在既有内容上追加 Settings 语义 Token，其他既有文件保持原有改动。

- docs/design/voice-management-and-interaction-contract.md
- macos/SpeechRailApp/SpeechRailApp/AppModel.swift
- macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift
- macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift
- macos/SpeechRailApp/SpeechRailApp/SpeechRailAPICredentials.swift
- macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift
- macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift
- macos/SpeechRailApp/SpeechRailControlKit/ServiceHTTPTransport.swift
- macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift

若后续任务需要修改其中任何文件，必须先读取该文件的现有 diff，并在执行记录中说明如何与并行改动分离。

## 2. 证据等级

| 标记 | 含义 | 可证明的范围 |
|---|---|---|
| code | 当前源码或文档直接可见 | 结构、命名、静态语义和契约是否存在 |
| unit | 纯函数或 Swift Package 测试通过 | 隔离逻辑、阈值、状态映射 |
| build | App Debug/Release 或 build-for-testing 通过 | 编译、目标和依赖关系 |
| manual | 用户在指定设置下完成桌面走查 | 真实窗口、材质、焦点和系统偏好 |
| automation | 用户当次授权后运行 XCUITest/UI 测试 | 前台真实流程和控件可发现性 |
| unverified | 当前没有足够证据 | 不得推断为通过 |

## 3. 当前 14 个路由

| 分组 | route | 页面实现 | 首屏任务 | 键盘入口（目标） | 当前证据 |
|---|---|---|---|---|---|
| 创作 | dubbing | DubbingDeskView | 输入文稿并生成语音 | ⌘1 | code |
| 创作 | voiceDesign | VoiceDesignView | 描述、试听并保存音色 | ⌘2 | code |
| 创作 | voiceClone | VoiceCloneView | 用录音注册可复用音色 | ⌘3 | code |
| 创作 | voiceLibrary | VoiceLibraryView | 管理并试听音色 | ⌘4 | code |
| 创作 | works | WorksView | 回看、播放、导出或删除作品 | ⌘5 | code |
| 会话 | assistant | AssistantView | 开始、进行或回看语音对话 | ⌘6 | code |
| 会话 | meeting | MeetingView | 记录会议并整理纪要 | ⌘7 | code |
| 会话 | captions | SessionLibraryView(kind: .captions) | 开始或回看实时字幕 | ⌘8 | code |
| 会话 | teleprompter | TeleprompterView | 准备稿件并在舞台跟读 | ⌘⇧T | code；shortcutSpec/build |
| 引擎 | overview | ServiceOverviewView | 确认本机语音服务是否可用 | ⌘9 | code |
| 引擎 | monitoring | RuntimeMonitoringView | 判断近期运行是否需要处理 | ⌘0 | code |
| 引擎 | models | ModelManagementView | 下载校验并应用运行档位 | ⌘⇧M | code |
| 引擎 | diagnostics | PreflightDiagnosticsView | 解释异常和下一步动作 | ⌘⇧D | code |
| 引擎 | developerDocs | DeveloperDocsView | 查阅本机服务接入方式 | ⌘⇧H | code |

### 3.1 路由一致性验收

| 检查项 | 期望 | 当前状态 | 证据 |
|---|---|---|---|
| AppRoute.allCases | 14 项且顺序固定 | 已确认 | AppRoute.swift |
| 侧栏三组 | creator/session/service 从同一事实源派生 | 已确认 | ControlCenterView.swift 调用 AppRoute.routes(in:) |
| detailView | 14 项均有页面构造 | 已确认 | ControlCenterView.swift:349-382 |
| Commands | 每项都有可发现菜单动作 | 已确认菜单项遍历 allCases | App.swift:604-617 |
| route shortcut | 14 项均有不冲突快捷键 | 已确认 | AppRoute.shortcutSpec、静态契约脚本、Debug build |
| 文档路由数量 | 不再出现旧 8/10/13 页当前表述 | 已确认（当前段） | active 设计系统与 REDESIGN-SPEC 当前段已同步；历史段保留历史事实 |
| 14 个路由的页面身份与首屏 | 侧栏点击后页面身份、首屏用途和主动作可见 | 14/14 已逐页打开；本次只核对只读首屏，未启动生成、录音或采集 | 2026-09-22 CUA 前台人工走查；AX workspace-title 与页面控件树 |

## 4. 验收维度

### 4.1 窗口尺寸

| 尺寸请求 | 侧栏行为 | Inspector 行为 | 主动作位置 | searchable/List | 证据 |
|---|---|---|---|---|---|
| 1120×720 | 原生侧栏可收起/恢复 | Inspector 可收起/恢复 | 6 个代表页面主动作均在窗口内 | 未覆盖 | automation pass；实际外框 1120×760（含标题栏） |
| 1280×800 | 原生侧栏可收起/恢复 | Inspector 可收起/恢复 | 6 个代表页面主动作均在窗口内 | 未覆盖 | automation pass；外框按请求尺寸 |
| 1440×900 | 原生侧栏可收起/恢复 | Inspector 可收起/恢复 | 6 个代表页面主动作均在窗口内 | 未覆盖 | automation pass；外框按请求尺寸 |
| 1920×1080 | 原生侧栏可收起/恢复 | Inspector 可收起/恢复 | 6 个代表页面主动作均在窗口内 | 未覆盖 | automation pass；请求按屏幕 visible frame 上限收敛 |

纯策略层已有 WindowLayoutPolicy 边界测试；XCUITest 在目标主机启动真实 App，验证各请求档位的窗口 frame 约束、侧栏/Inspector 切换和 Assistant、Meeting、Captions、Teleprompter、Models、Diagnostics 六页主动作 frame 落在窗口内。它不覆盖全部路由在每个尺寸下的 searchable/List 滚动细节，也不代表所有实时采集状态均已桌面验收。

`testControlCenterHonorsRequestedWindowSizes` 对 1120×720、1280×800、1440×900 和 1920×1080 请求逐档启动窗口；标题栏使第一档外框高度为 760pt，1920×1080 档按当前 `visibleFrame` 限制在屏幕可见区域内。未修改显示器分辨率。这里的 searchable/List 列仍未覆盖，不能从主动作可见推断滚动、搜索和每页完整布局均已通过。

### 4.2 外观与 macOS 平台偏好

| 维度 | 代码检查 | 人工桌面 | UI 自动化 | 当前状态 |
|---|---|---|---|---|
| Light | 语义色和 token 可静态检查 | 强制浅色时查看 Developer Docs 首屏；正文/代码区可读，无明显裁切 | 可选 | manual sampled；其余页面未验证 |
| Dark | 语义色和 token 可静态检查 | 强制深色时查看同一首屏；文字、背景层级可辨 | 可选 | manual sampled；其余页面未验证 |
| Increase Contrast | 检查 custom color/contrast 分支 | 深色 + 增强对比度下检查状态图标、文字与边界 | 可选 | manual sampled；全页未验证 |
| 较大系统文字 | 系统文本样式和 minHeight | 首选阅读字号从默认 4 调至 5（13pt）；SpeechRail 示例页未观察到明显放大或裁切 | 可选 | manual partial；应用字号联动未证实 |
| Reduce Motion | 页面壳层、共享控件、Assistant、Meeting、Captions、内心 OS、运行监控、创作结果条和波形均有即时/静态分支 | 开启后切换至 Assistant，首屏状态与主动作仍可用；CUA 未能量化过渡时长 | 可选 | code/build；manual partial |
| Reduce Transparency | 自定义 material/solid surface | 开启后查看 Developer Docs；背景层级转为较实色，无明显裁切 | 可选 | manual sampled；其余页面未验证 |
| 基础辅助语义 | label/value/hint、状态文字/图标 | 代码与 UI 自动化 AX 控件发现证据；状态不只依赖颜色 | automation/code | 基本语义已确认；全量 VoiceOver 导航不属于目标用户验收 |
| 不依赖颜色 | 状态必须有文字/图标 | 增强对比度样本中服务状态仍有图标与文字 | 可选 | manual sampled；全页未验证 |
| 普通键盘路径 | 路由快捷键、菜单命令、基本焦点可见 | 14 项 shortcut contract、系统菜单命令与焦点恢复代码已核对；完整 FKA/方向键/Space 试听专项未跑 | code/automation | 常用入口已确认；全量 Full Keyboard Access 遍历不作为目标人群验收 |

项目设计系统当前已明确：macOS 上 dynamicTypeSize 不应被假设为改变系统文本墨迹；本次将系统首选阅读字号临时调到 13pt，SpeechRail 样本未见明显字体放大，未把它误报为字号适配通过。系统设置随后已恢复默认。

## 5. 页面状态矩阵

### 5.1 创作

| 页面 | ready/empty | loading/in-flight | blocked/error | success/partial | 主动作证据 |
|---|---|---|---|---|---|
| 配音台 | 空文稿、已有文稿 | 生成中 | 服务不可用、输入无效 | 结果条、可播放/导出 | code；桌面未验证 |
| 音色创作 | 描述为空、候选为空 | 生成候选、试听中 | 能力不可用、服务异常 | 候选可保存、部分候选 | code；桌面未验证 |
| 音色克隆 | 无录音、待录音 | 录音/注册中 | 麦克风拒绝、校验失败 | 音色已注册 | code；桌面未验证 |
| 音色库 | 空列表、有音色 | 试听中、删除确认 | 试听失败、加载失败 | 试听完成、删除完成 | code；桌面未验证 |
| 我的作品 | 空列表、有作品 | 播放/导出中 | 文件不可用、导出失败 | 播放完成、导出完成 | code；桌面未验证 |

### 5.2 会话

| 页面 | 状态 | 首要动作 | 恢复/次要动作 | 当前证据 |
|---|---|---|---|---|
| Assistant | ready | 开始对话 | 角色、音色、设置 | code |
| Assistant | blocked | 按原因给唯一出口 | 去设置、重试、打开权限 | code |
| Assistant | live | 结束对话 | 静音、停止朗读、换音色 | code |
| Assistant | review | 查看记录或新建 | 返回实时、导出、重命名、移除 | code |
| Meeting | idle | 开始会议 | 展开音频来源 | code |
| Meeting | preparing | 等待准备结论 | 重试或更换来源 | code |
| Meeting | recording | 暂停/结束并整理 | 静音、来源、重连 | code |
| Meeting | interrupted | 恢复或结束 | 解释中断原因 | code |
| Meeting | processing | 查看整理进度 | 处理失败出口 | code |
| Meeting | archived | 查看文字/纪要 | 导出、重命名、删除 | code |
| Captions | idle | 开始实时字幕 | 来源、字幕设置 | code |
| Captions | preparing | 等待连接 | 重试、权限出口 | code |
| Captions | running | 暂停/结束 | 字幕带、记录库 | code |
| Captions | paused | 继续或结束 | 说明暂停期间 | code |
| Captions | ending | 等待最后定稿 | 回到活动会话 | code |
| Teleprompter | draft | 导入/编辑稿件 | 新建空白稿 | code |
| Teleprompter | analyzing | 等待整理 | 取消或查看说明 | code |
| Teleprompter | review | 审阅候选 | 删除候选、重新整理 | code |
| Teleprompter | ready | 开始跟读 | 舞台设置、试读 | code |
| Teleprompter | preparing | 等待连接 | 重试、权限出口 | code |
| Teleprompter | following | 跟读中 | 暂停、手动提词、结束 | code |
| Teleprompter | paused | 继续或结束 | 手动提词 | code |
| Teleprompter | uncertain | 选择继续方式 | 手动、重新连接 | code |
| Teleprompter | manual | 手动提词 | 恢复跟读、结束 | code |
| Teleprompter | ended | 回看或再次开始 | 导出、删除、回到稿件 | code |

以上状态标题/语气/事实摘要由 `SessionPageStatusPresentation` 渲染；真实动作保留在各页控件树，矩阵是逐状态主动作/次动作/恢复动作的唯一审查清单。四档窗口 UI 测试验证六个代表页面的主动作 frame，完整 live 采集状态仍未启动或手动验证。

2026-09-22 只读桌面样本：Assistant 为待机；Meeting 显示“还没有开始会议”和“开始会议”；Captions 显示麦克风空闲和“开始字幕”；Teleprompter 显示稿件准备入口与范例。未启动录音、字幕采集、提词舞台或音频生成，因此只证明 idle 首屏可达，不证明 live/恢复/处理中状态。

### 5.3 引擎

| 页面 | 首屏结论 | 操作 | 技术详情位置 | 当前证据 |
|---|---|---|---|---|
| 服务状态 | 能否使用 | 启动、停止、重启、预检 | 开发者详情/Inspector | code |
| 运行监控 | 是否需要处理 | 查看趋势、复制摘要 | Inspector/开发者详情 | code |
| 模型 | 制品和档位状态 | 下载校验、应用档位、恢复 | Inspector | code |
| 诊断 | 问题与下一步 | 重跑检查、打开目标页 | 选中检查项详情 | code |
| 开发者文档 | 如何接入 | 复制端点/示例 | 开发者内容 | code |

## 6. 交互与 macOS 平台语义基线

| 检查项 | 期望 | 当前状态 |
|---|---|---|
| 页面身份 | 工具栏只出现一次，正文保留用途句 | code 已确认；manual unverified |
| 侧栏折叠 | 系统按钮可发现，收起/恢复可逆 | 原生控件在四档窗口 UI 测试中均可收起/恢复；自动 tier 策略另有纯函数测试 |
| Inspector | 由选中对象或明确动作出现，可恢复 | 四档窗口 UI 测试确认切换控件可收起/恢复；完整 Full Keyboard Access 专项未覆盖 |
| 主动作 | 每页一个主要任务和主要动作 | 会话状态矩阵静态核对；六个代表路由在四档窗口下通过主动作 frame 可见性测试 |
| 状态 | 图标和文字同时表达，不只靠颜色 | 共享状态条/结论条 code 已确认；增强对比度代表页有 manual sample |
| 搜索 | 搜索框属于内容，不与导航搜索混淆 | code 已确认；窄窗 unverified |
| List/Table | 使用系统选中态、方向键和焦点 | code 部分已有；manual unverified |
| Space 试听 | 有焦点列表/候选支持键盘试听 | 未验证 |
| 删除/重置 | 说明对象、后果、取消动作 | code 部分已有；逐页 unverified |
| 基础控件语义 | 控件可发现、名称/值/提示正确、状态不只依赖颜色 | code 与代表性 UI 自动化可确认；完整 VoiceOver 导航按目标用户范围排除 |
| Reduce Motion | 不使用弹簧、渐变或持续脉冲 | 共享组件与主要会话页 code 已确认；全页 manual unverified |
| Reduce Transparency | 自定义半透明层有固态降级 | Developer Docs 代表页 manual sample；全页未验证 |
| 长文字 | 按宽度截断，数据不预截断 | code 部分已有；manual unverified |

## 7. 命令与路由契约

| 路由 | 目标快捷键 | 当前实现 | 处理 |
|---|---|---|---|
| dubbing | ⌘1 | 已有 | 保留 |
| voiceDesign | ⌘2 | 已有 | 保留 |
| voiceClone | ⌘3 | 已有 | 保留 |
| voiceLibrary | ⌘4 | 已有 | 保留 |
| works | ⌘5 | 已有 | 保留 |
| assistant | ⌘6 | 已有 | 保留 |
| meeting | ⌘7 | 已有 | 保留 |
| captions | ⌘8 | 已有 | 保留 |
| teleprompter | ⌘⇧T | 已有 | AppRoute.shortcutSpec |
| overview | ⌘9 | 已有 | 保留 |
| monitoring | ⌘0 | 已有 | 保留 |
| models | ⌘⇧M | 已有 | 保留 |
| diagnostics | ⌘⇧D | 已有 | 保留 |
| developerDocs | ⌘⇧H | 已有 | 保留 |

## 8. Token 散点登记入口

Task 6 已逐项更新此表。每个值已选择 Token、System 或 Structural；未归类值不能在最终验收中标记为通过。

| 文件 | 区域/符号 | 当前类型 | 处置 | 证据 |
|---|---|---|---|---|
| CreatorSurfaceViews.swift | 文稿行距、音色 popover、sheet/列宽 | Token / Structural | 已有 `SpeechRailDesignTokens` 或文件内重复使用的局部规格；单次波形和采样值保留 Structural | code/build |
| MeetingView.swift | SpeakerLabelingSheet 460×520、Inspector 行 | Structural / Token | Sheet 是独立编辑任务的固定宿主尺寸；Inspector 使用 `Layout.sessionInspectorWidth` | code/build |
| SettingsView.swift | 帮助窗口、快捷键列、设置行 | Token | 新增 `Settings.*` 语义值，`SettingsMetrics` 不再持有页面裸值 | code/build |
| AssistantView.swift | 局部 9pt、padding、正文宽 | Structural / Token | 9pt 为 SF Symbol 微型图标，固定列和正文宽保留任务结构；共享间距/圆角/字体继续引用 Token | code/build |
| SessionDesignSurface.swift | 名称列、Inspector 宽、预览宿主 | Token / Structural | 名称列和 Inspector 由共享 Token；预览宿主尺寸仅为 Debug fixture 的 Structural 值 | code/build |
| WorkspaceComponents.swift | `StatusTone.color` | Token / System | neutral/healthy/attention/critical 统一引用 `SpeechRailDesignTokens.Color` 的语义色，交给 Light/Dark/Increase Contrast 变体解析 | code/build |

## 9. 验收记录

### 9.1 已执行

| 日期 | 范围 | 命令/证据 | 结果 |
|---|---|---|---|
| 2026-09-21 | 路由、页面入口和状态枚举静态核对 | AppRoute.swift、ControlCenterView.swift、各页面源码 | code |
| 2026-09-21 | 计划结构和占位符自检 | rg、git diff --check | pass |
| 2026-09-21 | AppRoute 路由契约红绿验证 | scripts/check_macos_route_contract.sh | red → pass |
| 2026-09-21 | WindowLayoutContract 纯函数测试 | swift test --package-path macos/SpeechRailApp --filter WindowLayoutPolicyTests | 7 tests pass |
| 2026-09-21 | Package 全量测试 | swift test --package-path macos/SpeechRailApp | 159 XCTest + 85 Swift Testing pass |
| 2026-09-22 | 路由契约静态脚本（扩展清单覆盖） | scripts/check_macos_route_contract.sh | 14 enum cases / 14 shortcut specs / 14 UI test entries / 14 matrix entries / one registry pass |
| 2026-09-22 | Package 全量测试（全 App Reduce Motion 收口后） | swift test --package-path macos/SpeechRailApp | exit 0；159 XCTest + 85 Swift Testing pass |
| 2026-09-22 | App Debug build（全 App Reduce Motion 与 StatusTone Token 收口后） | scripts/macos_app_build.sh --configuration Debug | exit 0；`** BUILD SUCCEEDED **` |
| 2026-09-22 | UI 测试包编译（StatusTone Token 收口后，不执行测试） | xcodebuild ... build-for-testing | exit 0；包含 `SpeechRailAppUITests` target；未接管窗口 |
| 2026-09-22 | Xcode test plan/target 元数据核对 | xcodebuild ... -showTestPlans、-list | scheme 关联 `SpeechRailApp` test plan；`SpeechRailAppUITests` target 存在；未执行测试 |
| 2026-09-22 | PageScaffold/状态/Token 静态检查 | rg、git diff --check、源码审阅 | pass；旧页面外壳参数命名无源码残留 |
| 2026-09-22 | Reduce Motion 动效静态审阅（全 App） | `rg` 动画调用点、源码审阅、Debug build | 页面外壳、共享/会话动作、内心 OS、运行监控、创作波形均有即时/静态分支；pass |
| 2026-09-22 | 工作区差异格式检查 | git diff --check | pass |
| 2026-09-22 | 14 路由与四个会话页只读首屏 | CUA 逐项点击侧栏；AX workspace-title、Description/Help、首屏按钮 | 14/14 页面身份匹配；Assistant/Meeting/Captions/Teleprompter idle 首屏可达；未启动采集或生成 |
| 2026-09-22 | 外观与 macOS 平台偏好人工抽样 | System Settings + SpeechRail live screenshots | Light、Dark、Increase Contrast、Reduce Transparency 有代表页样本；Reduce Motion/大字号为 partial；VoiceOver 仅探索性检查，不属于目标人群验收；所有系统设置已恢复基线 |
| 2026-09-22 | 授权后执行窗口矩阵 | `testControlCenterHonorsRequestedWindowSizes` | 1/1 通过；4 档窗口 frame 约束、侧栏/Inspector 收起恢复、6 个代表路由主动作可见性通过 |
| 2026-09-22 | 作品选择与导出入口 UI 回归 | `testWorksViewExposesSelectionAndExportActions` | 修正动态 File 菜单导出标题断言；Focused UI test 1/1 通过，行内与 Inspector 导出按钮及选中作品命令可发现 |
| 2026-09-22 | 完整 App test plan | `xcodebuild -project ... -scheme SpeechRailApp -testPlan SpeechRailApp test` | `.xcresult` 汇总 255 passed / 0 failed / 0 skipped；macOS 27.0 / arm64 |
| 2026-09-22 | Package 全量测试（状态摘要收敛后） | `swift test --package-path macos/SpeechRailApp` | exit 0；159 XCTest 与 85 Swift Testing 通过 |
| 2026-09-22 | Debug App build（状态摘要收敛后） | `scripts/macos_app_build.sh --configuration Debug` | exit 0；`** BUILD SUCCEEDED **`；存在非致命 AppIntents metadata 提示 |
| 2026-09-22 | 恢复桌面状态 | System Settings 与 SpeechRail AX/UI | Appearance Auto、Increase Contrast off、Reduce Transparency off、Reduce Motion off、字号默认、VoiceOver off；Assistant idle、侧栏可见、Inspector 收起 |

### 9.2 非阻塞未覆盖项

- Task 1–6 的 code/unit/build 证据已记录；UI test plan 全部 255 项通过；
- 四档窗口和六个代表页面主动作已有自动化证据；searchable/List 全页面矩阵、大字号联动及真实录音/采集 live 状态未覆盖；
- 完整 VoiceOver 与 Full Keyboard Access 专项遍历不属于当前目标人群验收；基本 macOS 控件语义、常用键盘入口和焦点反馈仍保留在产品基线中。

## 10. 完成判据

- [x] 14 个路由在源码、侧栏分组、菜单、快捷键契约、工具栏身份、active 文档中一致；14/14 首屏记录与 255 项 UI test plan 通过；
- [x] 四档窗口请求验证了 frame 约束、侧栏/Inspector 恢复与六个代表页面主动作可见性；searchable/List 全量细节仍明确未覆盖；
- [x] Light/Dark、Increase Contrast、Reduce Motion、Reduce Transparency 有代码或代表性人工证据；较大文字效果标为 partial；完整 VoiceOver 不在目标范围；
- [x] 创作、会话、引擎页面的 loading/empty/blocked/success/error/partial 下一步已有代码级状态清单与测试覆盖；真实 live 采集状态未启动；
- [x] 共享组件保留基本键盘入口、焦点、label/value/hint 和不依赖颜色的状态表达；不要求完整 VoiceOver/FKA 遍历；
- [x] Token/系统值/结构性常量分类完成；
- [x] UI 变化没有跨入服务协议、XPC、音频、记录或模型运行边界；
- [x] 静态检查、Package 测试、Debug build、授权 UI test plan 均有日期、命令和实际结果；
- [x] 未执行的 searchable/List 全量尺寸、字号联动与 live 采集项保留未验证，不推断为通过；Issue #79 保持打开继续跟踪。
