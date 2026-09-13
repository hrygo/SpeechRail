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

审查时间：2026-09-14（Asia/Shanghai）；本轮最新静态审查截至 00:52。

- 当前 managed profile 为 `quality`，generation 为 `102`。
- 当前 `/health`、`/readyz` 为 ready；ASR、TTS、diarization、realtime VAD 均报告 ready。ASR/TTS/streaming 为 `cold_evicted`，含义是可按需加载，不是模型缺失。
- 当前活动制品已核对：`asr-1.7b-q8`、`tts-1.7b-design-q8`、`tts-1.7b-base-q8`、`aligner-bf16`、`diarization-coreml` 均为 verified；Balanced/Light 所需资源存在但未应用。
- `GET /metrics` 在客户端要求 `Accept: application/json` 时实测 200 JSON；不带该请求头返回 Prometheus 文本，符合 `contracts/openapi.yaml` 的内容协商约定。因此不能把默认 `curl` 得到的文本误判成 Swift 接线故障。
- 审查开始时 metrics JSON 只有请求数、队列数、延迟、TTFA、worker 状态和健康 gauges；本轮源码已在同一 `/metrics` JSON/Prometheus 入口补充资源快照、准入策略和 ASR/TTS RTF。当前本机运行中的旧实例尚未替换，因此新字段仍需安装后做 live 对账，不能把源码构建当作运行态证明。
- `GET /v1/voices` 实测包含系统音色和自定义音色；其中存在超长描述 metadata，证明音色列表必须对服务端文本做边界保护。
- 未执行模型下载、模型加载/卸载、服务重启、真实创作请求和自动化测试。当前验证只覆盖源码、契约、编译、AX 手工检查和只读本机接口。

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
- [x] 明确“保存候选”的语义：页面现在明确说明试听音频不持久化，按钮和成功消息改为“注册此候选”，注册按 seed/instruction/reference text 重新创建服务端音色；待人工验收。
- [x] preview 使用的输入文本、用户填写的 reference text、注册时 reference text 的关系已统一：同一段 20–240 字参考文案用于候选试听和注册，并在页面解释；待真实请求验收。
- [x] 四个候选按 A→B→C→D 顺序逐个请求；单个失败后继续请求其余候选，已成功候选保留，生成中取消由 task cancellation 结束当前请求。

### Token / UX 审查

- [x] Prompt、reference text、声学 chips、速度、候选 rack 使用明确的主次层级；chips 仅作为横向快捷输入，不伪装成独立配置表单。
- [x] 删除页面内硬编码 text field 样式；输入、快捷特征、选择态和候选行统一使用 tokenized field/capsule/selection primitive，窄窗口使用自适应布局。
- [x] 候选行统一显示 A/B/C/D、状态、时长、播放/停止和保存结果；loading、playing、saved、failed 均有文字语义，不只换 icon。
- [x] 服务不满足条件时，在 primary action 同一视觉区解释原因，并提供模型页/服务状态页的真实修复入口，而不是只显示灰色按钮。

### 待验收

- [ ] 在 quality + TTS ready、quality + TTS unavailable、非-quality profile、health unknown 四种状态下核对按钮和文案。
- [ ] 生成四候选、播放两个候选、保存一个候选，核对服务端 voice 列表出现对应真实音色，重启页面后仍能试听。

## 3. 音色库 `voiceLibrary`

### 真实性接线审查

- [x] 列表来自 `GET /v1/voices`；系统音色和自定义音色分组真实反映响应。
- [x] 试听调用 `POST /v1/audio/speech` 并使用 `AudioPlaybackController`，不是空闭包或静音假反馈。
- [x] 已接入服务端已有的 voice delete 能力：仅自定义音色显示删除，先确认，再调用 `DELETE /v1/voices/{voice_id}`，支持进行中、成功、服务端失败和刷新；系统音色保持保护。
- [x] 核实当前 `CreatorVoice` 解码字段；列表/详情只展示服务端实际返回的 type、variant、created time、availability、mode、duration 和 capabilities，缺失字段显示“未提供”，不生成 tags/model source/关联作品假值。
- [x] 设计音色详情 inspector：普通用户看用途、试听和“去配音台”入口，开发者看安全的 variant、mode、availability、创建时间、时长和 capability。
- [x] 对服务端 description 设置两行截断；列表同时展示 type、variant 和可用时的创建日期，超长 live metadata 不再撑开列表布局。instruction/detail inspector 边界仍待补。

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

- [ ] page switch 不应丢失正在进行的 operation、播放状态或错误上下文；退出页面时只停止不应继续的播放器，不取消服务端已提交操作。
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
- 待补：解除自动化暂停后的人工全矩阵、真实创作链路、模型下载/应用链路、诊断故障注入和更新后的自动化测试；作品重命名/删除/复用仍需先确定可恢复回收策略，当前不擅自扩展用户数据删除能力。
