# SpeechRail macOS App 逐页真实性接线与统一 Token 审查 TODO

> 类型：交付后的审查清单，不是“已经完成”的功能承诺。
>
> 基线代码提交：`ea4035d3 feat: wire macOS control plane end to end`
>
> 适用范围：macOS 26 控制面、MenuBarExtra、Settings、8 个工作区页面，以及它们连接的 XPC、REST、Application Support 和服务端契约。

## 使用规则

每一项必须同时满足“来源真实、动作可达、结果可见、失败可恢复、视觉遵循同一 token”才可以勾选。

- P0：会把不可用能力显示成可用，或会让用户误判关键运行状态。
- P1：主流程不完整、重要错误不可见、普通用户或开发者无法完成判断。
- P2：视觉、交互、可访问性或维护性收口。
- `[x]`：已有代码和实测证据支持；不代表整页完成。
- `[ ]`：待修复或待人工验收。
- 自动化测试当前按用户要求暂停；本文不以未运行的测试推断通过。

## 当前证据基线（只读）

审查时间：2026-09-14（Asia/Shanghai）；本轮最新静态审查与 Release 编译截至 11:03。

- 当前 managed profile 为 `quality`，generation 为 `102`。
- 当前 `/health`、`/readyz` 为 ready；ASR、TTS、diarization、realtime VAD 均报告 ready。ASR/TTS/streaming 为 `cold_evicted`，含义是可按需加载，不是模型缺失。
- 当前活动制品已核对：`asr-1.7b-q8`、`tts-1.7b-design-q8`、`tts-1.7b-base-q8`、`aligner-bf16`、`diarization-coreml` 均为 verified；Balanced/Light 所需资源存在但未应用。
- `GET /metrics` 在客户端要求 `Accept: application/json` 时实测 200 JSON；不带该请求头返回 Prometheus 文本，符合 `contracts/openapi.yaml` 的内容协商约定。因此不能把默认 `curl` 得到的文本误判成 Swift 接线故障。
- 审查开始时 metrics JSON 只有请求数、队列数、延迟、TTFA、worker 状态和健康 gauges；本轮源码已在同一 `/metrics` JSON/Prometheus 入口补充资源快照、准入策略和 ASR/TTS RTF。当前本机运行中的旧实例尚未替换，因此新字段仍需安装后做 live 对账，不能把源码构建当作运行态证明。
- `GET /v1/voices` 实测包含系统音色和自定义音色；其中存在超长描述 metadata，证明音色列表必须对服务端文本做边界保护。
- 未执行模型下载、模型加载/卸载、服务重启、真实创作请求和自动化测试。当前验证只覆盖源码、契约、编译、AX 手工检查和只读本机接口。

- 交互热区补强：`SpeechRailInteractiveButtonStyle` 增加 `fillsAvailableWidth` 语义；导航、列表选择行和 `DisclosureGroup` 明确使用整列布局，声学标签与试听图标按钮保持紧凑尺寸。Debug / Release 编译在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下均 `BUILD SUCCEEDED`；自动化测试、安装和运行态操作仍按用户要求暂停。
- 运行监控真相链路补强：health 最近一次读取失败时，能力状态、运行档位、版本和复制摘要不再展示内存中的旧快照；metrics 仍独立保留最近有效样本并标识新鲜度。音色创建、更新、删除成功后若服务端列表刷新失败，界面明确保留“操作已完成但列表刷新失败”的可恢复反馈。
- 运行监控独立读取修复：health 失败不再提前终止同一次刷新，继续读取独立的 JSON metrics；成功的 metrics 不会覆盖健康失败语义，health 与 metrics 同时失败时合并为可读的双重错误提示。
- 音色库窄窗口收口：头部“新建音色 / 显示详情 / 刷新”操作使用 `ViewThatFits`，空间不足时按统一间距纵向排列，避免按钮标签被压缩或挤压主工作区；Debug / Release canonical build 均通过，自动化测试和安装仍按用户要求暂停。
- 指针实现去重：侧栏服务状态按钮移除重复的外层指针注册，统一由共享交互 ButtonStyle 管理 enabled/disabled 光标区域，避免重叠 cursor rect 造成反馈不稳定；Debug / Release canonical build 均通过。
- 本轮复核：确认两处 `DisclosureGroup` 均使用共享全宽命中区；未发现裸 `onTapGesture` / `gesture(` 或重复 pointing cursor 组合。监控状态条件去重后，Debug / Release canonical build 均通过。
- Token 收口：顶部标题最小缩放比例与音色描述列表预览长度改由 `SpeechRailDesignTokens.Toolbar` / `List` 提供，页面不再持有这两个视觉边界裸常量。
- 最新验证：Release canonical build 在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下通过；本轮未执行自动化测试、安装或运行态操作。
- 本轮接线收口：音色库选中音色新增服务端 `GET /v1/voices/{id}` 详情读取，详情失败保留列表事实并提供重新读取；模型、预检和远端操作轮询对本地取消分支做了独立处理，不把“客户端停止等待”误报成远端已回滚。Debug / Release canonical build 均通过；本轮未执行自动化测试、安装或运行态操作。

## 总览

| 页面 / surface | 真实性接线结论 | 统一 Token / UX 结论 | 下一步优先级 |
| --- | --- | --- | --- |
| 配音台 | 已接 `/v1/voices`、`/v1/audio/speech`、本地作品保存与播放 | 编辑区、参数区、结果区已按单一工作面重排；生成/保存/播放/取消与播放失败状态均有真实反馈；真实请求与存储验收待用户执行 | P1 |
| 音色创作 | 已接 preview 和 registration 两条真实 REST 链路 | fail-closed 能力门禁、统一参考文案、部分失败保留、注册语义和候选状态已收口；真实请求待用户执行 | P0/P1 |
| 音色库 | 已接真实列表、试听和自定义删除 | 单一列表 surface + inspector；可用/不可用、试听失败、删除冲突有明确语义；VoiceOver 待用户验收 | P1 |
| 我的作品 | 已接 Application Support 索引、音频读取、播放和 WAV 导出 | 改为紧凑列表 + 选中展开文稿 + inspector；索引错误、播放失败、导出结果均显式呈现；重命名/删除/复用仍待数据模型与回收策略 | P1 |
| 服务状态 | 已接 health、profile、preflight、Control Agent 操作 | 关键结果、恢复入口和开发者审计信息已统一；真实操作验收待用户执行 | P1 |
| 运行监控 | 已接 health + JSON metrics，5 秒刷新并保留最后有效快照；源码已补资源/准入/ASR-TTS RTF | 数据契约、stale 语义和摘要复制已统一；安装后的 live 对账及手工失败恢复待验收 | P1 |
| 模型 | 已接 catalog/status、下载准备和 profile apply；模型存在/使用已分开表达 | 目标/当前/配置档位和“可按需加载”已分层；真实下载/应用待用户触发 | P1 |
| 诊断 | 已接 XPC preflight、选中检查项、解释、恢复动作和脱敏报告复制 | 一屏结论 + 检查清单 + 解释工作面已统一；辅助功能验收待用户执行 | P1 |
| 全局 chrome、菜单、设置 | 标题、菜单、设置均有真实入口 | 标题/操作/侧栏/指针/点击反馈及 token 已统一；手工模式矩阵待用户执行 | P1/P2 |

## 0. 全局基线与 Token 审查

### 0.1 真实性与状态来源

- [x] 建立 `AppModel → client → endpoint/XPC → typed snapshot → View` 的来源链；关键入口见 `AppModel.swift`、`ServiceAPIClient.swift`、`AgentCommandRunner.swift`、`XPCControlService.swift`。
- [x] 为每个用户可操作控件补齐“触发的命令/请求、进行中状态、成功结果、失败结果、取消边界、重试动作”审查表；不能只以按钮存在证明已接线。
- [x] 对所有跨页共享状态规定唯一事实源：服务健康来自 `/health`，运行指标来自 `/metrics` JSON，模型存在/完整性来自 XPC catalog/status，profile 应用状态来自 operation snapshot，作品来自 `CreativeWorkStore`。
- [x] 清理或标注所有仅用于 UI test 的 fake transport 和 fixture，确保 Release 路径不会误用 fake；人工验收时记录真实路径和 fake 路径的差异。
- [x] 为每个错误保留稳定用户文案和开发者安全详情；禁止直接展示 raw path、Authorization、原始 prompt、完整音频或服务端私密 metadata。

#### 0.1.1 触发—状态—结果审查表

| 页面 / 控件 | 触发与唯一来源 | 进行中 / 成功可见结果 | 失败、取消与重试边界 |
| --- | --- | --- | --- |
| 侧栏导航 | `NavigationLink` → `AppNavigationState` 本地选择 | 选中项、标题和 detail 同步切换 | 无远端失败；键盘/VoiceOver 待人工核对 |
| 全局刷新 | `AppModel.refresh()` → `GET /health` + XPC `profile.list/status` | `isRefreshingService`；更新 health/profile 与全局 badge | health/XPC 分离显示；重新读取可重试，不保留旧 ready 结论 |
| 预检 | `refreshPreflight()` → XPC `preflight` | 预检状态、检查项和完成时间来自 typed snapshot | 失败映射到模型/服务/诊断；重新运行可重试 |
| 启动 / 停止 / 重启 | 确认框 → `AppModel.execute()` → XPC command + operation status | operation banner；终态以新的 health/profile 回读为准 | command failure 显示恢复入口；不取消已提交服务命令 |
| 模型刷新 | `refreshModels()` → XPC `model.catalog/status` + health | catalog/status 与当前 worker 使用状态分层刷新 | XPC 失败显示未读取；可刷新重试 |
| 模型准备 | 确认框 → XPC `model.prepare` + operation polling | `OperationBar` 显示阶段、制品、文件和真实字节进度 | 失败/中断可重新准备；取消只停止客户端轮询/受管取消边界，不伪造清理结果 |
| 档位应用 | 确认框 → XPC `profile.apply` + operation polling | 完成后重新读 profile/health；明确目标档位与当前档位 | 失败保留当前运行档位；打开诊断/重试，不把 prepare 完成冒充 apply |
| 诊断恢复 / 复制 | XPC `preflight`、导航恢复动作、脱敏报告到 pasteboard | 选中检查项解释影响和下一步；复制动作给出结果反馈 | 未知项进入安全报告；不复制 raw path、凭据或 backend 原文 |
| 运行监控刷新 / 复制 | `refreshMonitoring()` → `/health` + JSON `/metrics` | 5 秒轮询、样本数、更新时间、stale、图表和复制摘要 | metrics 失败保留最后有效样本并标 stale；恢复后替换 |
| 配音生成 | `/v1/voices` → `POST /v1/audio/speech` → `CreativeWorkStore` → playback | 生成中/播放中/已保存状态和“我的作品”结果可见 | 请求/保存/播放分别报错；文本与选择保留，可重试或停止试听 |
| 音色创作 | `/v1/voices/previews`；注册 `/v1/voices/designs` | A–D 候选逐个显示生成/试听/注册状态 | capability 未知 fail-closed；单候选失败不清空其他候选，可重试 |
| 音色库试听 / 删除 | `/v1/voices`、`POST /v1/audio/speech`、自定义 `DELETE` | 列表与 inspector 来自真实 voice snapshot；试听/删除状态可见 | 系统音色不可删；删除需确认，冲突/失败保留目标并可刷新 |
| 我的作品播放 / 导出 | `CreativeWorkStore` + `AudioPlaybackController` + native file exporter | 选中、展开文稿、播放和导出结果可见 | 索引/音频/播放/导出分别报错；不泄漏本地绝对路径 |
| Settings | `@AppStorage("speechrail.showDeveloperDetails")` | 偏好立即持久化，影响控制台 inspector 默认展开 | 当前无服务副作用；恢复默认和辅助功能待人工核对 |

UI-test fake 仅在 `DEBUG` 编译且显式带 `--ui-test` 时可选；Release 的 `isUITest` 固定为 false，并始终选择 live XPC/REST client。真实链路与 fake 链路的人工差异仍需在恢复自动化后补测。运行中的 `OperationSnapshot` 也统一经 `OperationJournal.sanitized` 后才进入 XPC/UI，避免进度文件路径或 raw message 越过隐私边界。

### 0.2 顶部标题、操作和侧栏

- [x] 以 `WorkspaceTitleLockup` 为唯一顶部标题入口：标题视觉只保留单行 route title，使用 tail truncation/minimum scale，不再携带会挤压 toolbar 的 context 胶囊。
- [x] 重新定义标题层级：标题承担“我在哪”，页面主体只保留简洁 purpose/状态导语，不再重复一套大标题或漂浮胶囊。
- [x] `WorkspaceActionsMenu` 统一为“更多操作”语义菜单，具备 VoiceOver label、tooltip 和页面内明确菜单项，不用三个无名图标替代操作说明。
- [x] 补齐侧栏底部唯一的全局服务状态 summary；静态状态不注册 pointing hand，点击区域才显示 pointing hand，并支持点击进入“服务状态”。
- [x] 复核 `NavigationSplitView` selection 的前景色、icon 色和焦点 token；选中项不再依赖蓝底黑字的默认对比。
- [x] 统一侧栏 icon 的语义来源、monochrome rendering、光学尺寸和 weight；`AppRoute.systemImage` 是唯一来源。

### 0.3 Token 资产与实现收口

- [x] 对 `SpeechRailDesignTokens.swift` 做四层审计：Foundation、Semantic、Component、Interaction；本轮页面局部字体、focus stroke、固定宽度和颜色透明度已迁移到 token。
- [x] 解决 `SurfaceLevel.panel`、`inspector`、`elevated` 无实际视觉差异的问题；每个 surface level 现在有独立 fill/border/shadow 语义。
- [x] 合并 `MetricStrip` 与 `MetricGrid` 的重复表达，保留共享 `MetricValueView` primitive；两种布局共用 label/value/detail/accessibility 语义。
- [x] 将页面中的 `.caption2`、`.title3`、硬编码 `220`/`1.5` 等局部写法迁移至 token；保留 Apple system font，并为状态/空态 glyph 定义统一 role。
- [x] 统一 surface 叠层：页面背景 → content surface → module → inspector；禁止无信息增益的圆角卡片套卡片、过度阴影和全屏玻璃。
- [x] 为 hover、pressed、focus、disabled、loading、stale、error、success、destructive 建立可复用交互 token；共享按钮、菜单、导航和列表选择只在可操作区域注册 pointing cursor。
- [x] 完成静态 literal/token lint：业务页面不再使用 rounded border、material 玻璃、局部 caption/title 字体、裸色状态色或未命名布局尺寸；保留项均位于 token/系统窗口测试路径。
- [x] 核对路由图与编译目标：`ServiceStatusView.swift`、`ProfilePickerView.swift`、`ServiceRoutePreviewView.swift` 当前无调用点，仅作为旧源码兼容保留，不属于 Release 可达页面；交付页面统一从 `AppRoute` 进入。
- [ ] 完成人工模式矩阵：Light、Dark、Increase Contrast、Dynamic Type、Reduce Motion、最小窗口、键盘导航、VoiceOver；自动化测试恢复后再补 XCTest/XCUITest。

### 0.4 全局验收

- [ ] 逐页截图审阅顶部标题和右上角操作，确认任何窗口宽度下都没有换行、遮挡、空白胶囊或不明图标。
- [ ] 逐个点击真实控件，确认按下反馈在 100ms 级别可见，异步动作有进行中反馈，完成/失败反馈不依赖切换页面才出现。
- [ ] 逐个静态区域移动鼠标，确认不会错误显示 pointing hand；不可操作文本、状态、分隔线和空白区域使用普通箭头。
- [ ] 为所有可操作元素核对 AX role、label、value、hint 和 keyboard shortcut；将结果记录到本文“验证记录”。

## 1. 配音台 `dubbing`

### 真实性接线审查

- [x] 音色列表来自 `ServiceAPIClient.fetchVoices()` → `GET /v1/voices`，不使用静态 voice fixture 作为 Release 数据源。
- [x] 生成调用 `AppModel.synthesizeAndSave()` → `POST /v1/audio/speech`；成功后由 `CreativeWorkStore` 写入 Application Support 并由 `AudioPlaybackController` 播放。
- [x] 失败时保留文稿和选择，服务端错误通过稳定错误映射返回页面。
- [x] 解决按钮语义：主按钮已改为“生成并保存”，成功后明确提示作品已写入“我的作品”并开始播放。
- [x] 明确请求取消边界：生成中按钮改为“取消生成”，停止播放仍为“停止试听”；取消提示明确服务端若已接收请求可能仍完成。
- [x] 当 refresh 后原选中 voice 不存在时，按可用列表首项回退并给出提示，不能静默切换。
- [x] 补齐格式、文本长度边界等真实请求语义；页面明确显示“输出格式：WAV · 采样率遵循当前服务配置”，不伪造不可配置的采样率控件。
- [x] 补齐 WAV 导出闭环：作品页通过原生 `fileExporter` 读取真实 Application Support 音频并导出到用户选择的位置；不向普通用户展示内部绝对路径。

### Token / UX 审查

- [x] 以共享工作区外层（当前由 `CreatorSurfaceView` 承担）+ 单一 `PageIntro` + 编辑区/参数区/结果区重排，减少 field/card 嵌套；编辑器保持主工作面，不被状态卡片抢层级。
- [x] 文稿编辑器、voice picker、speed control、primary action 使用统一 field/control token；参数区使用 `ViewThatFits` 适配窄窗口，长文案输入不再依赖系统 rounded border。
- [x] 生成中、播放中、生成失败、作品保存失败、空音色列表分别使用明确的状态样式；播放按钮的 icon、label、pressed/playing 状态一致。
- [x] 开发者 inspector 只显示安全 metadata（format、duration、character count；sample rate/request latency 明确标注协议未提供），不显示 raw prompt 或本地绝对路径；本轮补齐配音台与音色创作 inspector，并由父级“更多操作”统一入口控制。

### 待验收

- [ ] 真实触发一次短文本生成，核对响应 content type、音频可播放、作品索引可重载、页面刷新后仍可播放。
- [ ] 验证服务不可用、voice 列表为空、文本超限、保存目录不可写时的错误和恢复动作。

## 2. 音色创作 `voiceDesign`

### 真实性接线审查

- [x] 候选请求通过 `createVoicePreview()` → `POST /v1/voices/previews`，候选使用稳定 seed 区分，试听使用真实音频数据。
- [x] 保存通过 `registerVoiceDesign()` → `POST /v1/voices/designs`，成功后刷新 `/v1/voices`。
- [x] 修复能力门禁：生成按钮现在同时依赖健康快照、当前 profile、`ttsReady`、service ready 和服务实际 `voice_design + supports_instruction` capability；未知状态 fail-closed。代码已完成，待人工/自动化验收。
- [x] 对齐模型页和创作页的能力事实源：模型页现在显示目标档位的 VoiceDesign 能力，并将“当前服务 · 档位 · ASR/TTS”与“目标档位未应用”分开表达；仍待人工核对页面文案与服务快照。
- [x] 明确“保存候选”的语义：页面现在明确说明试听音频不持久化，按钮和成功消息表达“按候选注册”，注册按 seed/instruction/reference text 重新生成并创建服务端音色；待人工验收。
- [x] preview 使用的输入文本、用户填写的 reference text、注册时 reference text 的关系已统一：同一段 20–240 字参考文案用于候选试听和注册，并在页面解释；待真实请求验收。
- [x] 四个候选按 A→B→C→D 顺序逐个请求；单个失败后继续请求其余候选，已成功候选保留，生成中取消由 task cancellation 结束当前请求。

### Token / UX 审查

- [x] Prompt、reference text、声学 chips、速度、候选 rack 使用明确的主次层级；chips 仅作为横向快捷输入，不伪装成独立配置表单。
- [x] 删除页面内硬编码 text field 样式；输入、快捷特征、选择态和候选行统一使用 tokenized field/capsule/selection primitive，窄窗口使用自适应布局。
- [x] 候选行统一显示 A/B/C/D、状态、时长、播放/停止和保存结果；loading、playing、saved、failed 均有文字语义，不只换 icon。
- [x] 服务不满足条件时，在 primary action 同一视觉区解释原因，并提供模型页/服务状态页的真实修复入口，而不是只显示灰色按钮。

### 待验收

- [ ] 在 quality + TTS ready、quality + TTS unavailable、非-quality profile、health unknown 四种状态下核对按钮和文案。
- [ ] 生成四候选、播放两个候选、按一个候选的参数注册，核对服务端 voice 列表出现对应真实音色，重启页面后仍能试听。

## 3. 音色库 `voiceLibrary`

### 真实性接线审查

- [x] 列表来自 `GET /v1/voices`；系统音色和自定义音色分组真实反映响应。
- [x] 试听调用 `POST /v1/audio/speech` 并使用 `AudioPlaybackController`，不是空闭包或静音假反馈。
- [x] 已接入服务端已有的 voice delete 能力：仅自定义音色显示删除，先确认，再调用 `DELETE /v1/voices/{voice_id}`，支持进行中、成功、服务端失败和刷新；系统音色保持保护。
- [x] 核实当前 `CreatorVoice` 解码字段；列表/详情只展示服务端实际返回的 type、variant、created time、availability、mode、duration 和 capabilities，缺失字段显示“未提供”，不生成 tags/model source/关联作品假值。
- [x] 设计音色详情 inspector：普通用户看用途、试听和“去配音台”入口，开发者看安全的 variant、mode、availability、创建时间、时长和 capability。
- [x] 对服务端 description 设置两行截断；列表同时展示 type、variant 和可用时的创建日期，超长 live metadata 不再撑开列表布局；开发者详情为服务端描述设置固定行数，并以长度元数据表达 `instruction/ref_text`，不展示原文且不撑开 inspector。

### Token / UX 审查

- [x] 从“堆叠卡片”改为单一可扫描列表 surface + inspector：列表负责选择和试听，详情负责解释和操作；选择态、播放态、不可用态互斥且可读。
- [x] 系统音色、自定义音色、不可用音色分别使用语义 token；颜色之外同时提供文字、icon 和 AX value。
- [x] 搜索、筛选、标签当前没有真实数据源，因此不显示空壳控件。

### 待验收

- [ ] 用超长 description、缺失可用 voice、试听失败、删除冲突四类数据验证截断和恢复。
- [ ] 核对试听同一时间只播放一个音色，切换页面后播放器停止，VoiceOver 能说出音色名称和播放状态。

## 4. 我的作品 `works`

### 真实性接线审查

- [x] 作品索引和音频文件来自 `CreativeWorkStore` 的 Application Support 目录，列表按真实文件和 index 读取。
- [x] 试听读取真实音频并交给 `AudioPlaybackController`；空状态能回到配音台。
- [x] 修复错误可见性：`refreshWorks()` 使用独立的 `worksMessage`，作品索引损坏、读取失败不会静默变成空列表，并提供重新加载。
- [x] 增加真实 WAV 导出和失败提示；导出失败只显示可恢复的用户文案，不泄漏内部路径。
- [ ] 增加重命名、删除、再次编辑/复用前先确认数据模型和回收策略；涉及删除必须可定位目标且优先可恢复。
- [x] 核实作品详情所需的 duration、file size、sample params、request ID、latency 是否有安全来源；当前只展示有来源的 duration/format/character count/file name，其余明确标注未提供。

### Token / UX 审查

- [x] 使用紧凑列表 + inspector 的信息结构，避免每个作品都是相同大卡片；当前选中作品有清晰 selection，播放中有文字/icon 反馈。
- [x] 用户文稿通过 DisclosureGroup 折叠/展开并保留文本选择；开发者详情仅显示安全技术 metadata，不显示 raw service path 或 Authorization。
- [x] 空、损坏/读取失败、播放失败、正在播放、已导出状态复用统一状态 token；加载态仍由本地索引同步读取，不伪造进度。

### 待验收

- [ ] 生成一件真实作品，退出/重新打开 App 后加载并播放；手动损坏 index 或移走音频，确认错误而不是“没有作品”。
- [ ] 验证长文稿、多个作品、键盘选择、VoiceOver inspector 和删除/导出确认。

## 5. 服务状态 `overview`

### 真实性接线审查

- [x] 服务健康和能力矩阵来自 `/health`；profile 和 Control Agent 状态来自 XPC。
- [x] 预检通过 XPC 执行 `preflight`；启动、停止、重启有 confirmation 和异步 operation 状态。
- [x] 预检成功后在当前页给出明确结果和下一步；不能只依靠按钮禁用或跨页查看诊断。
- [x] inspector 补齐 LaunchAgent label、port、control agent、listener/connection summary 等安全审计信息；不要把绝对路径和敏感配置直接给普通用户。
- [x] 操作期间隐藏或降级旧的“已就绪”结论，改为“正在重启/健康检查中”；终态必须以新的 health/profile 读回为准。
- [x] 服务启动失败、Control Agent 不可用、health 超时和 profile 不一致分别给出标题、原因和恢复路径；运行操作期间只显示 operation 状态，终态只保留一个服务结论。

### Token / UX 审查

- [x] 页面首屏只保留一个服务结论、一个主恢复动作和一组能力事实；终态不再叠加旧 operation banner。
- [x] capability matrix 使用统一的 ready/unavailable/unknown icon、文字和语义颜色；health 读取失败时不继续展示旧快照为当前能力。
- [x] 服务操作按钮与顶部 action menu 使用相同 label、confirmation 文案和 AppModel 异步 operation 状态来源。

### 待验收

- [ ] 分别执行预检、启动、停止、重启的手动流程，核对 operation journal、health 回读和页面结果。
- [ ] 在 Control Agent 不可用和 service 已停止状态下验证恢复入口，确认不会执行模糊的 launchctl 或重复启动。

## 6. 运行监控 `monitoring`

### 真实性接线审查

- [x] 页面进入后通过 `AppModel.refreshMonitoring()` 读取 `/health` 和 `/metrics`，任务存活期间按 5 秒刷新。
- [x] metrics 失败时保留最后一份有效快照并显示错误/新鲜度边界，避免用零覆盖真实数据。
- [x] 当前页面展示的 request、queue、ASR/TTS latency、TTFA、realtime session、worker state 均可追溯到当前 JSON metrics/health 字段。
- [x] 补齐或重新定义 memory：现有 `/metrics` 增加 physical memory、budget、配置声明、完整采样时的服务 process-tree physical footprint、overlap decision；无法完整采样时返回不可用并由 UI 显示“未提供”，不把模型大小或磁盘空间替代内存占用。
- [x] 补齐 RTF 的真实来源和定义：ASR 使用 `record_asr` 的推理时长/音频时长，TTS 使用 `record_tts` 的推理时长/生成音频时长；streaming 没有同等定义时继续显示“未提供”，不把 latency 改名为 RTF。
- [x] 增加 stale badge、last updated、样本数和 metrics 请求错误的显式状态；读到旧快照时保留可信值并标记数据已过期。
- [x] 增加 worker 状态、服务 process count、档位/服务身份、准入预算、策略原因、队列拒绝和可复制脱敏监控报告；普通用户默认看结论，开发者展开 inspector。
- [x] 核实图表时间窗、采样上限、空数据、服务刚启动和 counter reset；最近 60 个样本以内，counter 下降或时间间隔无效时不计算窗口速率。

### Token / UX 审查

- [x] 以一条主趋势 + 紧凑 metrics strip + inspector 为骨架，主图只回答活跃请求趋势，不把所有指标做成同等重量的卡片。
- [x] 统一数值字体、单位、精度、趋势色和 unavailable/stale 状态；缺失值显示“—/未提供”，不以零代替。
- [x] 刷新、复制摘要、开发者详情使用有文字语义的 toolbar menu 项，不再堆叠无名 icon；图表仍保持空数据说明。

### 待验收

- [ ] 只读状态下观察至少两个刷新周期，核对更新时间、样本数和 worker 状态与 `/health`/`/metrics` 一致。
- [ ] 模拟 metrics 暂时失败和服务恢复，确认旧数据保留、stale 明确、恢复后新快照替换。
- [x] 在 server contract 中固化 memory/RTF 的字段与计算口径：`physical_memory_bytes`、预算、完整采样的 `physical_footprint_bytes`，以及 `speechrail_asr_rtf` / `speechrail_tts_rtf`；缺失 RTF 序列显示“未提供”，不改名 streaming latency。安装后的 live endpoint 对账仍待验收，未据源码构建宣称运行态完整。

## 7. 模型 `models`

### 真实性接线审查

- [x] catalog/status 通过 XPC 读取；generic artifact 与 dedicated diarization lane 已区分，dedicated lane 是分人相关制品的权威状态。
- [x] 下载准备和档位应用分别调用 `model.prepare` 与 `profile.apply`；两者都有 confirmation，未自动下载、加载、卸载或切换。
- [x] 页面将“存在/完整性”和“当前使用/worker 生命周期”分开表达；`verified` 与 `cold_evicted` 不会被混成缺失。
- [x] 强化目标档位与当前服务档位的文案。当用户查看 Balanced/Light 而服务仍为 Quality，`asr-1.7b-q8` 等共享制品同时显示“目标需要”和“当前服务是否使用”；运行档位以 `/health.profile` 为准，XPC profile 作为配置事实单独呈现。
- [x] 所有受管 artifact 使用统一的存在状态、文件计数、完整性、使用状态、来源、量化和适用档位表达；`not_downloaded`、`unknown`、`invalid` 的图标、颜色、文案和下一步不同。
- [x] OperationBar 展示后端真实提供的阶段、制品/文件和已完成/总字节；速度、ETA、缺失字节进度及清理结果若当前协议未提供，明确标注“协议未提供”，不做估算。
- [x] 下载完成后的“可应用”与“已应用”分开；应用动作完成后由 `AppModel.execute(.profileApply)` 回读 profile/health，页面不以 prepare 完成冒充服务已切换。
- [x] 对 catalog 未登记旧制品保留隔离展示，避免普通用户把它当作当前可用模型；开发者可查看其存在状态和“当前 catalog 未登记”原因。

### Token / UX 审查

- [x] 先用档位选择器表达决策，再用制品列表表达证据，最后用 OperationBar 表达动作；制品仍是可扫描列表行，不再做成独立大卡片。
- [x] profile ready、downloaded、verified、in use、cold evicted、not checked 使用同一“存在 / 使用”状态语义与 icon/文本组合；`cold_evicted` 继续表示可按需加载，不改写为缺失。
- [x] 下载、应用、取消、刷新使用标准按钮样式和明确 confirmation；静态完整性字段没有 pointing cursor，只有可选择制品和实际按钮注册交互光标。

### 待验收

- [ ] 对 Quality、Balanced、Light 逐一核对 catalog、model status、profile status、health 和 UI 文案；记录目标/当前两套事实。
- [ ] 只在用户明确触发后验证一次下载/校验和一次 apply；验证成功、失败、取消和旧版本保留策略。

## 8. 诊断 `diagnostics`

### 真实性接线审查

- [x] 预检请求经 XPC 到受管制的 CLI；清单、选中检查项、结果和 developer details 均来自 typed preflight snapshot。
- [x] 已有“重跑预检/打开模型/查看服务”恢复入口，未直接让 App 执行 `launchctl` 或模型命令。
- [x] 增加“复制诊断报告”安全动作：只复制 schema、状态、错误 code、时间、request ID/operation ID 等安全字段，过滤绝对路径、凭据、音频和 raw metadata。（当前预检协议未提供 error code/operation ID，报告明确标注不可用，不伪造。）
- [x] 对每个预检失败项建立修复映射：模型/制品进入模型管理，配置/权限/运行时进入服务状态，未知项复制脱敏报告交开发者；所有失败均保留“重新运行诊断”主动作，不再把所有失败落到同一个恢复按钮。
- [x] 预检成功、部分失败、运行中、未知和旧快照分别可见；切换检查项不应丢失全局结论。
- [x] 模型存在/使用事实与模型页采用同一 XPC catalog/status snapshot 语义；诊断页进入时读取快照并在“模型证据”区展示，未读取时明确不可判断，不重新猜测。

### Token / UX 审查

- [x] 保持“一屏结论 + 左侧检查项 + 右侧解释/修复”的结构；选中项先显示结果、影响和建议动作，再显示开发者详情。
- [x] 检查项状态使用 icon、文字、颜色三重表达；开发者详情默认由 AppStorage 控制，展开后仍按 token 排版。
- [x] 错误解释先说影响和下一步，再显示安全的 technical detail；不把英文 backend message 直接当主标题。

### 待验收

- [ ] 逐一选择通过、失败、未知检查项，核对解释、下一步和 AX label。
- [ ] 在最小窗口、增强对比度、VoiceOver 下确认检查项名称不被裁掉，主结论不需要滚动才能看到。

## 9. 全局 MenuBarExtra、Settings 与跨页行为

### MenuBarExtra

- [x] 状态 badge、打开控制中心、音色创作快捷入口、服务 start/stop/restart 和 Settings 入口均有真实 action；服务 mutations 有 confirmation。
- [x] 菜单与控制中心使用同一 AppModel 服务健康、health failure、控制通道和 operation 状态；health 失败时不显示旧的“已就绪”。
- [x] 增加“管理模型”快捷入口，明确模型下载只准备并校验本机资产，档位切换仍在控制中心模型页完成。
- [ ] 检查 menu item 的 label、keyboard navigation、disabled 状态和操作后菜单关闭/反馈行为。

### Settings

- [x] “默认展开技术详情”通过 `@AppStorage("speechrail.showDeveloperDetails")` 持久化；关于信息显示定位和 macOS 26 最低系统。
- [x] Settings 只保留真正的 App 偏好，不复制服务操作、模型下载或运行监控；若新增偏好必须声明影响范围和恢复默认动作。
- [ ] 统一 Form、section、label、secondary text 的 token 和 Dynamic Type；核对 Light/Dark/Increase Contrast/VoiceOver。

### 跨页状态

- [x] page switch 不应丢失正在进行的 operation、生成/注册任务或错误上下文；服务、配音和音色创作的长任务与结果由 AppModel 持有，页面退出只停止本地播放器，不取消已提交服务操作。页面专属播放器按 macOS 预期在离开页面时停止，重新进入仍能看到任务、候选/作品结果和失败恢复入口。
- [x] 所有页面按需使用同一 service badge、operation bar、empty state、error state、developer inspector；配音台与音色创作补齐缺失的 developer inspector，页面不再各自定义近似组件。
- [x] 顶部标题始终只出现一次；页面主体不得重新绘制“配音台/运行监控/模型”等重复标题胶囊。

## 10. 功能真实性追踪表

实现每个 TODO 时，追加一行“View → method → transport → endpoint/command → returned state → visible result”的证据。下表在功能完成前不可全部标记为通过。

| 功能点 | 真实入口 | 当前结论 | 责任页面 |
| --- | --- | --- | --- |
| 服务健康 | `GET /health` | 已接，需持续核对 stale/操作期间状态 | 服务状态、运行监控、全局 badge |
| 运行指标 | `GET /metrics` + `Accept: application/json` | 源码已接 active/pending、worker、health、资源/准入和 ASR/TTS RTF；安装后需 live 对账 | 运行监控 |
| 模型目录 | XPC `model.catalog` | 已接 | 模型、诊断 |
| 模型完整性 | XPC `model.status` | 已接；目标/当前/配置档位与状态语义已分离，待人工对账 | 模型、诊断 |
| 模型下载/校验 | XPC `model.prepare` | 已接；阶段、字节、取消和缺失协议字段边界已明确 | 模型 |
| 档位应用 | XPC `profile.apply` | 已接；完成后回读 profile/health 证明生效，待人工对账 | 模型、服务状态 |
| 音色列表 | `GET /v1/voices` | 已接；服务端文本边界保护与自定义音色管理闭环已实现，待 live 验收 | 配音台、音色库 |
| 配音生成 | `POST /v1/audio/speech` | 已接；生成、保存、播放失败状态已拆分表达 | 配音台、作品 |
| 音色 preview | `POST /v1/voices/previews` | 已接；fail-closed 能力门禁、候选保留和试听语义已实现，待 live 验收 | 音色创作 |
| 音色注册 | `POST /v1/voices/designs` | 已接；按 seed 重注册、服务端刷新与失败反馈已明确，待 live 验收 | 音色创作、音色库 |
| 作品索引 | `CreativeWorkStore` | 已接；错误不可静默 | 我的作品 |
| 音频播放 | `AudioPlaybackController` | 已接；配音、候选、音色试听和作品播放均有统一进行中/停止反馈 | 配音台、音色创作、音色库、作品 |
| 预检 | XPC `preflight` | 已接；脱敏报告、错误修复映射和重新运行入口已实现，待故障注入验收 | 诊断、服务状态 |

## 11. 完成门槛

- [x] P0 静态审查项全部关闭：音色创作 capability gate fail-closed，模型“存在/当前使用/目标档位”在来源和文案上已分离；运行态矩阵仍待验收。
- [x] P1 静态接线项全部具备真实来源、进行中、成功、失败、恢复和可见结果；真实服务/存储/故障注入仍待验收。
- [ ] P0/P1 运行态验收全部关闭：真实创作、模型准备/应用、服务操作、失败恢复和跨页状态仍需在用户允许的验收窗口执行。
- [x] 每个页面只使用统一 token；静态 literal/token lint 已完成。
- [ ] 完成人工视觉审阅；需在用户解除测试暂停后逐页核对截图和交互反馈。
- [ ] 运行监控只宣称服务端实际提供的指标；本轮契约和源码已成立，仍需安装后的 live endpoint 对账才可关闭本门槛。
- [ ] 完成 Light/Dark/Increase Contrast/Dynamic Type/Reduce Motion/最小窗口/键盘/VoiceOver 手工矩阵。
- [ ] 用户解除“暂停自动化测试”后，更新过期 UI tests，运行 App build、XCTest/XCUITest、Python contract gate，并把结果写入本文。
- [ ] 发布或安装前再次执行旧 App 退出/移入废纸篓、安装新版本、启动验证；测试应用验收完成后清理测试实例和临时运行态，但不删除用户模型和作品。

## 验证记录

- 2026-09-13：源码审查确认 `ServiceAPIClient` 为 `/metrics` 设置 `Accept: application/json`；服务端按 Accept 内容协商，未发现此前容易误报的“Prometheus 文本无法 JSON 解码”问题。
- 2026-09-13：只读核对 profile、catalog、model status、`/health`、`/readyz`、`/v1/models`、`/v1/voices` 和 JSON `/metrics`；未下载/加载/卸载模型，未改服务运行态。
- 2026-09-13 23:01：完成音色创作能力门禁的 fail-closed 修复；进入页面先刷新 health 和 voices，Debug 编译通过。自动化测试与真实 VoiceDesign 请求按用户要求未执行。
- 2026-09-13 23:07：模型页补充目标档位 VoiceDesign 能力事实，并明确当前服务档位/运行制品与目标档位的区别；Debug 编译通过。
- 2026-09-13 23:09：音色创作页统一试听/注册参考文案，补齐候选非持久化说明与注册状态文案；Debug 编译通过。
- 2026-09-13 23:11：配音台明确“生成并保存”语义，作品页补充本地 WAV 导出、导出失败反馈和独立作品存储错误状态；Debug 编译通过。
- 2026-09-13 23:13：音色库接入自定义音色删除确认与真实 DELETE 请求，补齐删除状态/错误反馈及 description 截断；Debug 编译通过，未执行真实删除。
- 2026-09-13 23:20：诊断与服务状态页补齐独立预检状态源、更新时间、脱敏报告复制、LaunchAgent/XPC/health inspector；服务操作完成后重新读取预检，开发者详情不再展示 raw backend message；Debug 编译通过，未执行自动化测试。
- 2026-09-13 23:32：运行监控源码补齐 `/metrics` 的资源/准入快照和 TTS RTF（ASR RTF 复用既有真实来源），Swift 解码、看板 summary/inspector、stale 状态和脱敏复制报告同步接线；Debug 编译与 Python 目标模块静态编译通过，未执行自动化测试，未安装新服务实例，因此 live 字段对账留待用户验收。
- 2026-09-14 10:18：修复监控刷新在 health 失败时提前返回的问题；同一次刷新仍独立读取 metrics，成功指标不会覆盖健康失败语义，双失败会合并展示可读错误。`git diff --check`、无裸手势/重复指针静态检查通过，Debug / Release 编译通过；自动化测试、安装和运行态操作仍暂停。
- 2026-09-13 23:54：模型页完成目标档位 / 当前服务运行档位 / 配置档位分层；制品状态统一为存在、完整性、文件计数、使用状态的语义呈现；OperationBar 展示真实阶段、制品、文件、字节进度，并明确速度/ETA/清理结果等未由协议提供的字段；Debug 编译通过，未执行自动化测试、模型下载或档位应用。
- 2026-09-14 00:02：服务状态页按 health failure / control plane / profile mismatch / operation failure 分流恢复路径；菜单新增模型管理入口，并修复全局 ServiceStatusBadge 在 health 失败时沿用旧“已就绪”的问题；Debug 编译通过，未执行自动化测试或服务操作。
- 2026-09-14 00:05：诊断页接入同一 XPC 模型快照作为模型证据；预检失败按模型/服务/开发者处理映射恢复入口，详情先展示影响与建议动作，复制报告补充 runtime/config profile、health failure 和 control plane 安全状态；Debug 编译通过，未执行自动化测试或故障注入。
- 2026-09-14 00:15：创作工作区完成一轮 token/UX 与真实性收口：配音台自适应参数布局、真实生成/播放失败反馈；音色创作 tokenized 输入、快捷特征横向滚动、候选状态语义和能力修复入口；音色库改为单一列表 surface；作品改为列表 + DisclosureGroup + inspector，并拆分作品播放错误状态；Debug 编译通过，未执行自动化测试或真实创作请求。
- 2026-09-14 00:22：全局状态与隐私复核：侧栏、顶部标题、服务 badge 和服务状态页统一以最新 `/health` 判定 ready；控制 Agent、服务端错误和 operation message 不再直接展示 raw detail；模型 inspector 使用安全操作结果；Debug 编译通过。
- 2026-09-14 00:24：UI-test fake 路径限定为 Debug + 显式 `--ui-test`，Release 固定使用 live XPC/REST；Debug 编译通过，未运行 UI tests。
- 2026-09-14 00:26：页面级 surface 分层收口，服务状态、运行监控、模型和诊断外层工作面统一为 content surface，控件/操作条保留 field 语义；Debug 编译通过。
- 2026-09-14 00:27：修复 `profile.apply`/模型 operation 失败后被服务状态页标为成功的终态分流；只有 operation `committed` 才进入健康回读并显示完成；失败、中断、取消和仍在后台运行均保留非成功状态；Debug 编译通过。
- 2026-09-14 00:31：HTTP 错误 code fallback、voice ID 边界、创作候选并发注册门禁和 VoiceDesign/VoiceLibrary 列表 surface 完成收口；Debug 编译通过。
- 2026-09-14 00:33：服务动作在控制通道不可用时统一 fail-closed；模型刷新/应用按钮、菜单状态和创作页状态均不再依据 stale service snapshot 放行；Debug 编译通过。
- 2026-09-14 00:37：候选行移除嵌套 field 卡片，VoiceDesign/配音台补齐共享 developer inspector；模型 `ready == nil` 时显示“就绪状态未读取”而不依据 worker 状态过度推断；运行中 operation snapshot 在内存/XPC 出口统一脱敏；静态检查通过，自动化测试仍按用户要求暂停。
- 2026-09-14 00:51：OpenAPI 与用户 API 契约补充 ASR/TTS RTF、资源快照和缺失值语义；监控脱敏摘要补齐同一采样中的请求、延迟、RTF 和实时会话字段；Debug 构建通过，未安装新实例，live endpoint 对账、真实模型操作和自动化测试仍按用户要求暂停。
- 2026-09-14 00:52：同一改动在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 Release 构建通过；确认 Release 不启用 UI-test fake 分支。自动化测试、安装和服务运行态操作仍未执行。
- 2026-09-14 00:53：最终静态门通过：`git diff --check`、OpenAPI YAML 解析、页面 token/legacy-style 扫描均无新增问题；工作树保持干净。自动化测试、安装、真实模型操作和故障注入继续保留为用户验收门槛。
- 2026-09-14 05:28：全局交互命中区复审：标准按钮、侧栏导航、菜单行、自定义列表行以及两个 `DisclosureGroup` 标签均具备完整布局边界命中区；自定义按钮改为矩形命中形状，视觉圆角保留，避免透明内边距和圆角死角点不到。macOS 26.5 SDK / arm64 Debug build 通过；自动化测试、安装和真实运行态操作仍按用户要求暂停。
- 2026-09-14 05:37：修正 Debug/Release 条件编译路径：Debug 显式启用 `DEBUG` 以保留 UI-test fake transport，Release 排除 fake 分支并保留 bundled XPC live transport；AppModel 编译警告收口。`scripts/macos_app_build.sh --configuration Debug` 与 `Release` 均在 macOS 26.5 SDK / arm64 下通过；自动化测试、安装和真实运行态操作仍按用户要求暂停。
- 2026-09-14 05:40：菜单栏 popover 的 7 个动作将整行命中区下沉到原生 `Button` label 内部，覆盖文字、图标与行内留白，并保留 disabled 与 pointing-hand 语义；Debug 构建通过，未执行自动化测试或安装。
- 2026-09-14 05:42：顶部静态 `WorkspaceTitleLockup` 移除多余 `contentShape`，与“只有可操作区域注册命中区”的全局规则一致；设计文档同步为当前单行 icon + title 实现。未执行自动化测试或安装。
- 2026-09-14 05:44：交互覆盖矩阵补齐 Settings 页 `Toggle` 的 pointing-hand；文本输入/文本选择区继续排除在动作光标之外。未执行自动化测试或安装。
- 2026-09-14 05:46：侧栏 `NavigationLink` 的矩形命中形状下沉到完整 label 内容内部，和菜单项、`DisclosureGroup`、自定义列表行的命中区规则统一；Debug 构建通过，未执行自动化测试或安装。
- 2026-09-14 05:48：音色库选择行将上下留白纳入选择按钮的 label 命中区，保持试听/删除按钮独立；Debug / Release 编译均通过，未执行自动化测试或安装。
- 2026-09-14 05:50：复核模型、监控、诊断和音色 inspector 的服务端字符串边界：列表/指标/worker 使用单行截断或固定列，技术详情使用固定宽度滚动与行数上限，操作错误统一经过安全文案映射；未发现新的布局撑开路径。
- 2026-09-14 05:53：token 扫描收口音色编辑器 `120pt` 输入高度、焦点描边内缩和声学 chip 紧凑间距，页面不再直接持有这三处产品尺寸；未执行自动化测试或安装。
- 2026-09-14 05:58：跨页状态修复：配音生成任务句柄与最近完成作品移入 `AppModel`，配音台退出时只停止播放器，不再取消已提交生成；重新进入页面仍可观察进行中状态并取消，完成结果可恢复显示。未执行自动化测试或安装。
- 2026-09-14 06:04：跨页状态继续收口：音色创作候选生成与候选注册任务、候选音频快照及取消/成功状态移入 `AppModel`；离开页面不再取消候选任务，已完成候选保留，未完成候选明确标记“已停止”。配音与音色创作草稿改为场景级本地状态，侧栏服务状态按钮的完整 label 命中区同步固定；音色开发者详情增加 description 行数与 `instruction/ref_text` 长度边界。Debug / Release canonical build 均通过，未执行自动化测试或安装。
- 2026-09-14 06:07：只读复核运行中的服务：`/health`、`/readyz` 均为 ready，服务版本 `2.6.0`、活动档位 `quality`；`/v1/models` 返回活动 ASR/TTS 与兼容 alias，`/v1/voices` 返回系统/自定义音色并再次包含超长 metadata 样本。未执行模型操作、音频请求、服务变更或安装；该实例尚未替换为本工作树构建产物。
- 2026-09-14 10:35：补齐音色库单音色详情 GET 接线与失败保留/重读反馈；模型刷新、预检刷新和 operation polling 增加本地取消安全边界。准确静态扫描确认无裸 `onTapGesture` / `gesture(`、无重复 pointing cursor 组合；`git diff --check` 通过，Debug / Release canonical build 已通过。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 10:48：修复音色目录刷新与单音色详情读取的竞态：目录快照开始读取时使旧详情响应失效，并收敛详情读取中的状态，避免旧详情覆盖新列表或永久显示加载中。修复后 Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；`git diff --check`、裸手势扫描和重复 pointing cursor 扫描通过。自动化测试、安装、运行态和真实音频/模型操作仍按用户要求暂停。
- 2026-09-14 10:54：收口配音台空/刷新中音色选择器：无可用音色或列表刷新期间禁用 `Picker`，同时将选中音色写入 AX value，避免不可操作控件显示手形或无法说明当前选择。修复后 Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装、运行态和真实音频/模型操作仍按用户要求暂停。
- 2026-09-14 11:03：修复 `URLSession` 将取消报告为 `URLError.cancelled` 时的错误映射；配音、音色试听和 VoiceDesign preview 现在保持取消语义，不再误报“无法连接服务”。修复后 Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；自动化测试、安装、运行态和真实音频/模型操作仍按用户要求暂停。
- 2026-09-14 06:10：页面级“更多操作”菜单的刷新、复制、详情和服务状态入口统一将整行命中区下沉到 `Button` label，覆盖图标、文字与行内留白；静态文字不注册 pointing cursor，disabled 状态继续由原生菜单处理。未执行自动化测试、安装或服务变更。
- 2026-09-14 06:12：补齐服务状态页菜单中的启动、停止和重启动作的整行命中区；`scripts/macos_app_build.sh --configuration Debug` 与 `Release` 均在 macOS 26.5 SDK / arm64 下通过，`git diff --check` 通过。自动化测试、安装和服务运行态操作仍按用户要求暂停。
- 2026-09-14 06:17：Settings 保持原生 grouped `Form` 语义，补齐统一 canvas、次级文案行数/自适应布局、44pt Toggle 命中区与 pointing cursor；Debug / Release canonical build 均通过。Light/Dark、Increase Contrast、Dynamic Type、VoiceOver 的人工核验仍待用户解除测试暂停。
- 2026-09-14 06:21：音色库试听状态接线：AppModel 暴露当前 `previewingVoiceID`，音色库与详情面板在真实请求期间显示“试听中”进度；新配音/试听开始前停止旧播放器，完成或失败后清理目标状态并保留错误反馈。Debug / Release canonical build 均通过，未执行自动化测试、安装或真实音频请求。
- 2026-09-14 06:24：完成本轮全局交互收口：按钮、菜单行、侧栏导航、列表选择行、`DisclosureGroup` 标签和 Settings `Toggle` 的整块布局均纳入可点击命中区，并统一 hover/focus/按下反馈与 pointing-hand；静态标题和正文继续保持不可操作光标。当前改动下 Debug / Release canonical build 均在 macOS 26.5 SDK / arm64 通过，`git diff --check` 通过；自动化测试、安装、服务变更和真实音频请求仍按用户要求暂停。
- 2026-09-14 06:27：程序化复核所有 SwiftUI 交互入口：未发现遗漏的 `onTapGesture`/裸手势；`Button`、`NavigationLink`、`DisclosureGroup`、`Picker`、`Slider`、`Toggle` 和菜单动作均使用原生或共享交互样式，独立试听/删除动作未被列表选择命中区吞并；开发者详情面板仍统一固定宽度并垂直滚动。自动化测试、安装和运行态验收继续暂停。
- 2026-09-14 06:29：完成音频与音色功能的源码/契约对账：配音与 VoiceDesign preview 均发送 `wav` 请求并校验非空 `audio/wav` 响应；注册、更新、删除字段和状态与服务端路由及 OpenAPI 相符；`com.speechrail.plist.example` 通过 `plutil -lint`，`git diff --check` 通过。未执行真实音频请求或服务变更。
- 2026-09-14 06:30：静态核对发现现有 `SpeechRailAppUITests` 仍保留旧版标题、菜单和创作页文案断言，且 UI-test transport 未覆盖真实配音/试听反馈；已明确列入暂停解除后的测试更新项。当前不修改或运行自动化测试，避免绕过用户的测试暂停要求。
- 2026-09-14 06:32：复核模型页真实性分层：运行档位只来自 `/health`，配置档位只来自 XPC `profile.status`，制品存在/完整性只来自 `model.catalog` 与 `model.status`；health 读取失败时模型使用状态明确降级为“未确认”，未发现可安全修复的错配。
- 2026-09-14 06:34：维护 UI-test 契约：断言同步到当前“更多操作”、单行 workspace title、模型中断文案、诊断摘要和作品空状态；Debug-only `UITestCreatorClient` 增加离线音色列表、VoiceDesign preview/配音合法 WAV 和注册/更新/删除返回，使创作链路不再是空壳。Debug / Release canonical build 均通过；未运行 XCTest/XCUITest。
- 2026-09-14 06:35：重新编译包含 UI-test 支持 transport 的 App：Debug / Release 均在 macOS 26.5 SDK / arm64 下 `BUILD SUCCEEDED`，`git diff --check` 通过。UI-test 源码尚未执行，真实服务、音频和模型运行态未改变。
- 2026-09-14 06:37：将 Debug-only `UITestCreatorClient` 的音色列表改为 actor-backed 离线 store；注册、更新、删除后重新读取会反映状态，配音/VoiceDesign preview 继续返回本地合法 WAV。Debug / Release canonical build 均通过，未执行 XCTest/XCUITest。
- 2026-09-14 06:39：为取得完整收尾证据重新执行 Release canonical build，在 macOS 26.5 SDK / arm64 下 `BUILD SUCCEEDED`；`git diff --check` 通过。未执行 XCTest/XCUITest、安装、服务变更、真实音频请求或模型操作，工作区改动保持未提交供后续审阅。
- 2026-09-14 06:44：进一步加固开发者详情面板：Inspector 外列宽与内内容宽度均固定为 360pt / 328pt，长技术字段只能在固定列内换行或垂直滚动，不再依赖父布局提议宽度；Debug / Release canonical build 均在 macOS 26.5 SDK / arm64 下通过。自动化测试、安装和运行态验收继续暂停。
- 2026-09-14 06:49：按服务端 `POST /v1/voices/designs` 实现核对并修正文案：候选试听音频仅供本次会话，注册动作会按同一 instruction/reference text/seed 由服务端重新生成、校验并持久化参考音频；按钮改为“按候选注册”，开发者详情拆分两种音频的持久化语义。`List`、`Control`、`Button` 的 44pt 触达基线统一引用 `Interaction.minimumHitTarget`；Debug / Release canonical build 均通过，未执行自动化测试或真实请求。
- 2026-09-14 06:55：按“整个按钮和标签可点击”再次收口：侧栏 `NavigationLink` 的外层行也固定为整行矩形命中区；诊断页与作品页的 `DisclosureGroup` 外层固定为整行宽度，和内部共享 label 命中区一致，确保文字、图标与行内留白都能触发展开/导航。修复一次由新增本地计算属性导致的 Swift 编译错误后，Debug / Release canonical build 均在 macOS 26.5 SDK / arm64 下通过；`git diff --check` 通过。自动化测试、安装、服务变更和真实音频/模型请求仍按用户要求暂停。
- 2026-09-14 06:57：修复诊断顶部结论卡的动态内容风险：移除 84pt 硬性最大高度，仅保留最小高度，动态字体或较长状态文案可以自然增高而不被裁切；同时再次核对整行交互矩阵，无裸手势命中区。Debug / Release canonical build 均在 macOS 26.5 SDK / arm64 下通过；自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:07：修正侧栏选中态前景 token：不再用固定的 `onRail` 颜色覆盖系统选中背景，改用 AppKit 动态 `alternateSelectedControlTextColor`，在明暗、高对比和系统 accent 下保持可读。Debug / Release canonical build 均在 macOS 26.5 SDK / arm64 下通过，`git diff --check` 通过；未执行自动化测试、安装或运行态操作。
- 2026-09-14 07:12：诊断结论区用户影响说明从单行截断改为最多两行并允许自然增高，新增 `Diagnostics.summaryMessageMaximumLines` token；动态字体和较长错误文案不会被固定最大高度裁切。未执行自动化测试、安装或运行态操作。
- 2026-09-14 07:12：完成上述诊断摘要修复后的 Debug / Release canonical build，均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；`git diff --check` 与裸手势扫描通过。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:22：音色库试听请求改由 `AppModel` 持有并可取消；页面离开会取消未完成请求，响应返回前增加 cancellation check，避免离开页面后误启动播放；列表与开发者详情的试听按钮在请求进行中均扩展为整块“取消试听”操作。新增 UI-test 契约与 Debug-only 慢请求 fixture，但未执行 XCTest/XCUITest。Debug / Release canonical build 均通过，`git diff --check` 通过。
- 2026-09-14 07:22：复核当前改动后修正 Debug fixture 的显式返回并重新完成 Debug / Release canonical build；两种配置均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:26：顶部中心 workspace title 改为固定 token 槽位（`280 × 32pt`），保持单行、尾部截断与紧缩；路由切换不再改变标题宽度或挤压右侧操作，并在槽位边界增加绘制裁切，避免长本地化标题视觉溢出。Debug / Release canonical build 均通过，`git diff --check` 与裸手势扫描通过。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:31：逐页复核 `DeveloperInspector` 的固定几何时发现内层 `328pt` 内容在 padding 前被 `maxWidth: .infinity` 再次放大，可能造成水平溢出；移除该放大层后严格保持 `328pt 内容 + 32pt 内边距 = 360pt`，所有模型/监控/诊断/创作/音色/作品详情共用此边界。Debug / Release 构建随后重新验证，自动化测试与安装仍暂停。
- 2026-09-14 07:36：共享按钮、菜单行、Disclosure 标签和顶部操作菜单统一补齐最小 `44 × 44pt` 触达基线；命中区继续使用矩形，覆盖透明内边距，短标签与图标型控件不再可能低于最小宽度。修正一次 SwiftUI `.frame` 参数顺序后，Debug / Release canonical build 均在 macOS 26.5 SDK、arm64 下 `BUILD SUCCEEDED`，`git diff --check` 通过。自动化测试和安装仍按要求暂停。
- 2026-09-14 07:41：原生 `DisclosureGroup` 的两个开发者详情区统一切换为 `SpeechRailDisclosureGroupStyle`；箭头、整行矩形命中区、按压/焦点反馈与展开状态集中到共享 primitive，并为展开内容使用统一左侧 inset。自动化测试和安装仍按要求暂停。
- 2026-09-14 07:44：完成共享 Disclosure primitive 后重新执行 Release canonical build，在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；`git diff --check` 通过，裸手势扫描无结果。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:49：删除未再使用的 `speechRailDisclosureLabel()` 备用路径，避免与 `SpeechRailDisclosureGroupStyle` 形成两套命中区规则；全仓引用扫描无残留，Debug / Release canonical build 均 `BUILD SUCCEEDED`，`git diff --check` 通过。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:52：共享 Disclosure primitive 读取 macOS Reduce Motion 环境，系统启用“减少动态效果”时不再播放展开动画；Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:56：将矩形 `contentShape` 明确固化在 Disclosure label 行自身，而不只依赖 ButtonStyle 的间接布局，避免后续样式调整使整行命中区退化为文字宽度；Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 08:02：VoiceDesign 能力状态与修复入口改用 `ViewThatFits`：宽窗口横排、窄窗口纵排，避免长状态文案挤压操作按钮或产生溢出；Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 08:08：共享 `StatusBanner` 改为 `ViewThatFits` 自适应布局：宽窗口保留摘要与动作横排，窄窗口自动纵排，服务/模型/诊断/创作共用同一防溢出规则；Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 08:15：服务操作进度组件同步改为 `ViewThatFits` 宽排/窄排，长操作文案或动态字体不会挤压重试动作；服务状态、模型操作和诊断恢复共用同一防溢出规则，Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 07:59：运行监控摘要、诊断结论和服务状态页预检摘要统一采用 `ViewThatFits` 宽排/窄排；长状态文案、样本信息和恢复按钮在窄窗口或大字体下不再互相挤压，摘要外层仍保持统一 token 与可访问性语义。Debug / Release canonical build 均 `BUILD SUCCEEDED`，`git diff --check` 与裸手势扫描通过；自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 08:03：修复配音与音色试听取消竞态：取消时不再提前清空任务句柄或伪造终态，等待真实异步请求收敛；配音响应返回后增加 cancellation check，取消不会继续保存作品，旧请求也不会与下一次操作交叉。Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装和真实音频请求仍按用户要求暂停。
- 2026-09-14 08:06：音色库自定义音色列表行新增直达“编辑”按钮，普通用户无需先打开开发者详情即可完成更新；系统音色仍不可编辑，详情 inspector 的技术入口保留。音色库的创建、读取、更新、删除入口与真实 REST 接线保持一致；Debug / Release canonical build 均 `BUILD SUCCEEDED`，未执行自动化测试或安装。
- 2026-09-14 08:08：补齐音色 CRUD 与试听错误码的用户恢复文案，覆盖 `voice_in_use`、删除/创建/更新失败、输入校验、档位不支持等稳定服务端结果；修复后 Debug / Release canonical build 均 `BUILD SUCCEEDED`。自动化测试、安装和真实音频请求仍按用户要求暂停。
- 2026-09-14 08:14：补齐创作链路对 `model_not_found`、`dependency_missing`、音频时长/格式错误、连接失败和超时的用户恢复文案，并移除重复 Swift `switch` 分支；Debug / Release canonical build 均 `BUILD SUCCEEDED`，未执行自动化测试、安装或运行态操作。
- 2026-09-14 08:18：修正 VoiceDesign 顶部多余单子节点布局，并将运行监控“资源脉冲”标题与刷新状态改为 `ViewThatFits` 宽排/窄排，窄窗口和动态字体下不再互相挤压；Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。`git diff --check` 通过，页面源码无裸 `onTapGesture`/`gesture(`；自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 08:58：模型下载/档位操作的 `OperationBar` 纳入共享 `ViewThatFits` 宽排/窄排，长制品名、动态字体和窄窗口下动作按钮不会再与操作详情争抢横向空间；Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。`git diff --check`、裸手势扫描和页面 legacy-style 扫描通过；自动化测试、安装和运行态操作仍按用户要求暂停。
- 2026-09-14 09:15：全量静态复核整行交互热区后，`SpeechRailInteractiveButtonStyle(fillsAvailableWidth: true)` 已覆盖开发者详情、侧栏状态、诊断检查项、模型制品/档位、音色库和作品选择行；紧凑声学标签与试听图标按钮保持内容尺寸。运行监控 health 失败时不再展示旧缓存快照；音色创建/更新/删除成功后的列表刷新失败会保留可恢复提示。Debug / Release canonical build 均 `BUILD SUCCEEDED`，`git diff --check` 和裸手势扫描通过；自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:18：继续审计 health 失败后的跨页事实源：服务状态 inspector 的服务/版本/后端信息、Control Center 全局标题状态以及 VoiceDesign 能力门禁均改为只消费最近一次成功 health 读取；health 失败时能力门禁 fail-closed，并显示服务不可用语义。Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:24：修复本轮编译回归发现的 `ControlCenterView` 缺少 `SpeechRailControlKit` 类型导入；同时同步 VoiceDesign 播放完成后的本地候选状态清理和新增音频错误文案。修复后 Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:27：继续收口读取失败语义：XPC profile 读取失败时清空旧配置快照；音色列表和作品索引读取失败时清空旧展示快照并保留可恢复错误，避免用户继续操作未经确认的旧对象。Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:30：修正服务操作菜单的状态冲突：命令完成但 health 读取失败时，不再在菜单中显示绿色“操作已完成”摘要，最终服务状态统一由 health 结论负责；Debug / Release canonical build 均 `BUILD SUCCEEDED`。
- 2026-09-14 09:32：继续全局状态优先级收口：服务操作失败会优先于 ready 状态出现在标题、侧栏与菜单中，避免“服务已就绪”遮蔽“操作未完成”。Debug / Release canonical build 均 `BUILD SUCCEEDED`；静态差异检查通过。
- 2026-09-14 09:38：音色库头部操作补齐窄窗口自适应：三项操作宽度足够时保持单行，空间不足时纵向排列；按钮标签、命中区和交互反馈继续由共享 token 提供，不改变固定侧栏与开发者详情宽度。Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:46：清理侧栏服务状态按钮的重复指针区域注册，保留共享 ButtonStyle 作为唯一光标来源；Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；`git diff --check` 通过，自动化测试、安装和运行态验收仍暂停。
- 2026-09-14 09:51：按“整个按钮和标签可点击”完成静态交互矩阵复核：共享标准按钮、菜单行、侧栏导航、开发者详情 Disclosure 标签、模型/诊断/音色库/作品列表选择行均由完整布局边界承载命中区；未发现裸手势或仅文字注册命中区的页面入口。紧凑声学标签与试听/编辑/删除等独立动作保持各自边界，避免嵌套操作互相吞并；自动化测试、安装和运行态验收仍按用户要求暂停。
- 2026-09-14 09:57：修正配音完成反馈的终态语义：作品成功保存但播放器已自然结束时不再误报播放失败；作品列表二次读取失败时保留“已保存”事实并单独提示列表刷新问题。Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；自动化测试、安装和真实音频/服务运行态验收仍暂停。
- 2026-09-14 09:59：补强 VoiceDesign 取消竞态与本机存储错误分流：取消后的迟到预览响应不再写回候选；音频生成成功但作品库保存失败时显示本机存储恢复建议，而不是泛化为服务错误。修复后 Debug / Release canonical build 均 `BUILD SUCCEEDED`；自动化测试、安装和真实音频/服务运行态验收仍暂停。
- 2026-09-14 10:04：再次落实“整个按钮和标签可点击”：共享自定义按钮样式同时扩展外层 Button 与内部 label 的全宽矩形命中区；开发者详情等 Disclosure 标题增加稳定的 trailing hit area 与同范围反馈，透明留白也归属同一个交互目标。未执行自动化测试、安装或运行态操作。
- 2026-09-14 11:00：收口创作接线边界：`URLSession` 的 `URLError.cancelled` 归一为 `CancellationError`，取消预览/合成不会误报连接失败；`AVAudioPlayer` 异步播放失败会回写到对应的配音或作品错误状态；音色目录刷新会使迟到的单音色详情响应失效，避免新列表被旧详情覆盖；音色选择器在读取中或无可用音色时禁用并提供准确的辅助功能状态。Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；`git diff --check`、裸手势扫描和重复指针注册扫描通过。
- 2026-09-14 11:05：补齐全局交互契约遗漏：顶部统一“更多操作” `Menu` 的矩形触发区现在显式使用 enabled-only pointing hand，与原生菜单的 hover/pressed 反馈保持一致；Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。
- 2026-09-14 11:06：复核指针注册后移除 `WorkspaceActionsMenu` 的重复 modifier，仅保留一个全局 cursor 来源；`git diff --check` 和裸手势扫描通过，Release canonical build 再次 `BUILD SUCCEEDED`。
- 2026-09-14 11:10：同步交互契约与实现：所有 enabled 操作/选择控件的 pointing-hand 规则、静态区域普通箭头规则和固定单行标题槽位已写回设计系统、全局交互规格与实施计划；移除标题内部 `layoutPriority`，避免中心标题参与 toolbar 争抢。修改后 Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。
- 2026-09-14 11:11：完成文档与源码一致性复核：`WorkspaceActionsMenu`、Picker、Slider、Toggle、NavigationLink、DisclosureGroup、按钮及声学特征标签均有明确的 enabled/disabled 指针边界；标题只保留固定宽度单行 lockup；无新增裸手势或页面级 cursor 实现。自动化测试与桌面视觉矩阵仍按用户要求暂停。
- 2026-09-14 11:13：模型事实链路补强：模型页“已检测但未纳入当前目录”现在合并 generic 与 dedicated diarization 状态，并以 dedicated lane 覆盖同 key，避免 CoreML/aligner 资产因状态通道不同而漏显示或重复；Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`。
- 2026-09-14 11:22：继续收口“整个按钮和标签可点击”：共享 `DisclosureGroup` 的 label 使用透明全宽布局提议，开发者详情的箭头、文字与尾部留白统一属于同一矩形命中区；模型页新增 `tts_lifecycle` 解码，并仅以 `warm_capability` / `warm_capabilities` 展示 Quality clone TTS 的真实常驻状态，缺少证据时明确标为未公开，不再复用通用 TTS worker 状态。Debug / Release canonical build 均在 macOS 26.5 SDK、arm64、macOS 26.0 deployment target 下 `BUILD SUCCEEDED`；自动化测试、安装、服务变更和真实模型/音频请求仍按用户要求暂停。
- 2026-09-14 11:24：运行监控开发者详情补充同一份 `tts_lifecycle` 常驻能力证据；Quality 的 `voice_design` / `voice_clone` lane 不再只在模型页可见，空数组明确显示按请求加载，缺少字段显示未公开。未执行自动化测试、安装、服务变更或真实模型/音频请求。
- 待补：解除自动化暂停后的人工全矩阵、真实创作链路、模型下载/应用链路、诊断故障注入和更新后的自动化测试；作品重命名/删除/复用仍需先确定可恢复回收策略，当前不擅自扩展用户数据删除能力。
