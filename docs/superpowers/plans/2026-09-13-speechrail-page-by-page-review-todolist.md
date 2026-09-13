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

审查时间：2026-09-13（Asia/Shanghai）。

- 当前 managed profile 为 `quality`，generation 为 `102`。
- 当前 `/health`、`/readyz` 为 ready；ASR、TTS、diarization、realtime VAD 均报告 ready。ASR/TTS/streaming 为 `cold_evicted`，含义是可按需加载，不是模型缺失。
- 当前活动制品已核对：`asr-1.7b-q8`、`tts-1.7b-design-q8`、`tts-1.7b-base-q8`、`aligner-bf16`、`diarization-coreml` 均为 verified；Balanced/Light 所需资源存在但未应用。
- `GET /metrics` 在客户端要求 `Accept: application/json` 时实测 200 JSON；不带该请求头返回 Prometheus 文本，符合 `contracts/openapi.yaml` 的内容协商约定。因此不能把默认 `curl` 得到的文本误判成 Swift 接线故障。
- 当前 metrics JSON 有请求数、队列数、延迟、TTFA、worker 状态和健康 gauges，但没有可直接展示的 resident memory、物理内存预算、RTF 或重叠冲突字段；这是真实数据面缺口，不允许 UI 伪造。
- `GET /v1/voices` 实测包含系统音色和自定义音色；其中存在超长描述 metadata，证明音色列表必须对服务端文本做边界保护。
- 未执行模型下载、模型加载/卸载、服务重启、真实创作请求和自动化测试。当前验证只覆盖源码、契约、编译、AX 手工检查和只读本机接口。

## 总览

| 页面 / surface | 真实性接线结论 | 统一 Token / UX 结论 | 下一步优先级 |
| --- | --- | --- | --- |
| 配音台 | 已接 `/v1/voices`、`/v1/audio/speech`、本地作品保存与播放 | 主流程可用，但“生成并试听”实际还会保存；导出、格式和信息结构不完整 | P1 |
| 音色创作 | 已接 preview 和 registration 两条真实 REST 链路 | 能力门禁和候选保存语义仍可能误导；局部样式未完全收口 | P0/P1 |
| 音色库 | 已接真实列表和试听 | 缺少管理闭环；长 metadata 有布局风险 | P1 |
| 我的作品 | 已接 Application Support 索引、音频读取和播放 | 存储错误不会在当前页显式呈现；缺少导出/管理 | P1 |
| 服务状态 | 已接 health、profile、preflight、Control Agent 操作 | 关键结果可见性和开发者审计信息仍不完整 | P1 |
| 运行监控 | 已接 health + JSON metrics，5 秒刷新并保留最后有效快照 | 现有数据不足以兑现 memory/RTF/budget 设计；图表信息层级偏弱 | P1 |
| 模型 | 已接 catalog/status、下载准备和 profile apply；模型存在/使用已分开表达 | 目标档位与当前档位还需更强区分；下载进度缺速度/ETA | P1 |
| 诊断 | 已接 XPC preflight、选中检查项和恢复动作 | 缺复制报告/结构化修复闭环；需完成一屏和辅助功能验收 | P1 |
| 全局 chrome、菜单、设置 | 标题、菜单、设置均有真实入口 | 侧栏全局状态 footer、标题/操作语义、指针/点击反馈和 token 仍需统一验收 | P1/P2 |

## 0. 全局基线与 Token 审查

### 0.1 真实性与状态来源

- [x] 建立 `AppModel → client → endpoint/XPC → typed snapshot → View` 的来源链；关键入口见 `AppModel.swift`、`ServiceAPIClient.swift`、`AgentCommandRunner.swift`、`XPCControlService.swift`。
- [ ] 为每个用户可操作控件补齐“触发的命令/请求、进行中状态、成功结果、失败结果、取消边界、重试动作”审查表；不能只以按钮存在证明已接线。
- [ ] 对所有跨页共享状态规定唯一事实源：服务健康来自 `/health`，运行指标来自 `/metrics` JSON，模型存在/完整性来自 XPC catalog/status，profile 应用状态来自 operation snapshot，作品来自 `CreativeWorkStore`。
- [ ] 清理或标注所有仅用于 UI test 的 fake transport 和 fixture，确保 Release 路径不会误用 fake；人工验收时记录真实路径和 fake 路径的差异。
- [ ] 为每个错误保留稳定用户文案和开发者安全详情；禁止直接展示 raw path、Authorization、原始 prompt、完整音频或服务端私密 metadata。

### 0.2 顶部标题、操作和侧栏

- [ ] 以 `WorkspaceTitleLockup` 为唯一顶部标题入口：长标题只允许单行尾部截断，禁止换行、溢出、遮挡状态 badge 或挤压 toolbar 操作。
- [ ] 重新定义标题层级：标题承担“我在哪”，页面主体只保留简洁 purpose/状态导语，不再重复一套大标题或漂浮胶囊。
- [ ] `WorkspaceActionsMenu` 统一为有明确语义的菜单入口；逐项检查 label、VoiceOver label、tooltip、confirmation 和执行结果，不用三个无名图标替代操作说明。
- [ ] 补齐侧栏底部唯一的全局服务状态 summary；静态状态只使用普通箭头，点击区域才显示 pointing hand，并支持点击进入“服务状态”。
- [ ] 复核 `NavigationSplitView` 原生 selection 的浅色、暗色、增强对比度、键盘选择和焦点环；选中项同时满足背景、文字、icon 对比度，不靠“蓝底黑字”。
- [ ] 统一侧栏 icon 的语义、光学尺寸、weight 和对齐基线；`AppRoute.systemImage` 是唯一来源，不允许页面内重新选择 SF Symbol。

### 0.3 Token 资产与实现收口

- [ ] 对 `SpeechRailDesignTokens.swift` 做四层审计：Foundation、Semantic、Component、Interaction；页面只能消费 semantic/component/interaction，禁止散落 hex、opacity、font、radius、lineWidth 和 magic frame。
- [ ] 解决 `SurfaceLevel.panel`、`inspector`、`elevated` 当前 modifier 无实际视觉差异的问题；每个 surface level 要有可验证的 material/fill/border/shadow 语义，或删除无效层级。
- [ ] 合并 `MetricStrip` 与 `MetricGrid` 的重复表达，保留一个按布局模式变化的 metric primitive；所有 metric 使用相同 label/value/detail/empty/stale 状态。
- [ ] 将页面中的 `.caption2`、`.title3`、硬编码 `220`/`1.5` 等局部写法迁移至 token；保留 Apple system font，但统一 text role、weight、line height 和 Dynamic Type 行为。
- [ ] 统一 surface 叠层：页面背景 → content surface → module → inspector；禁止无信息增益的圆角卡片套卡片、过度阴影和全屏玻璃。
- [ ] 为 hover、pressed、focus、disabled、loading、stale、error、success、destructive 建立可复用交互 token；静态区域不得注册点击 cursor。
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
- [ ] 解决按钮语义：当前“生成并试听”成功后同时保存作品；二选一：拆成“生成试听”和“保存到作品”，或把主按钮明确命名为“生成并保存”。
- [ ] 明确请求取消边界：停止播放不等于取消已提交的服务请求；UI 需要分别表达“停止播放”和“生成请求仍在处理/已完成”。
- [ ] 当 refresh 后原选中 voice 不存在时，自动选择规则和用户提示必须明确，不能静默切换到另一音色。
- [ ] 补齐格式、采样率、文本长度/段落边界等真实请求参数；若服务契约暂不支持，页面应明确显示“当前固定为 WAV/服务默认值”，不能让用户以为可配置。
- [ ] 补齐导出到 Finder、复制文件位置和再次使用作品的真实闭环；不得把 Application Support 的绝对路径直接放进普通用户主界面。

### Token / UX 审查

- [ ] 用 `PageScaffold` + 单一 `PageIntro` + 编辑区/参数区/结果区重排，减少 field/card 嵌套；编辑器是主工作面，不被状态卡片抢层级。
- [ ] 文稿编辑器、voice picker、speed control、primary action 使用统一 field/control token；检查长文案、Dynamic Type 和最小窗口。
- [ ] 生成中、播放中、生成失败、作品保存失败、空音色列表分别使用明确的状态样式；播放按钮需要 icon、label、pressed/playing 状态一致。
- [ ] 开发者 inspector 只显示安全 metadata（model、format、sample rate、request ID/latency 若契约提供），不显示 raw prompt 或本地绝对路径。

### 待验收

- [ ] 真实触发一次短文本生成，核对响应 content type、音频可播放、作品索引可重载、页面刷新后仍可播放。
- [ ] 验证服务不可用、voice 列表为空、文本超限、保存目录不可写时的错误和恢复动作。

## 2. 音色创作 `voiceDesign`

### 真实性接线审查

- [x] 候选请求通过 `createVoicePreview()` → `POST /v1/voices/previews`，候选使用稳定 seed 区分，试听使用真实音频数据。
- [x] 保存通过 `registerVoiceDesign()` → `POST /v1/voices/designs`，成功后刷新 `/v1/voices`。
- [x] 修复能力门禁：生成按钮现在同时依赖健康快照、当前 profile、`ttsReady`、service ready 和服务实际 `voice_design + supports_instruction` capability；未知状态 fail-closed。代码已完成，待人工/自动化验收。
- [ ] 对齐模型页和创作页的能力事实源：不得出现模型页显示当前 TTS 不支持 voice design、创作页却允许生成的矛盾。
- [ ] 明确“保存候选”的语义：当前保存是按 seed/instruction/reference text 重新注册，不是把已经试听的音频文件持久化；文案和确认框必须如实表达，或改为服务端保存 exact candidate。
- [ ] preview 使用的输入文本、用户填写的 reference text、注册时 reference text 的关系必须在 UI 中解释清楚，避免用户以为候选音频就是最终音色资产。
- [ ] 检查四个候选请求的顺序、取消、部分失败和重试；某个候选失败不能让其他已成功候选丢失或被误标为成功。

### Token / UX 审查

- [ ] Prompt、reference text、声学 chips、速度、候选 rack 使用明确的主次层级；chips 是快捷输入，不要伪装成可独立配置的复杂表单。
- [ ] 删除页面内硬编码 text field 样式、宽度和 line width，统一使用 tokenized field/capsule/selection primitive。
- [ ] 候选行统一显示 A/B/C/D、状态、时长、播放/停止和保存结果；按钮在 loading、playing、saved、failed 状态下不能只换 icon。
- [ ] 服务不满足条件时，在 primary action 旁解释“为什么不能用”和“去哪里修复”（模型/服务/诊断），而不是只显示灰色按钮。

### 待验收

- [ ] 在 quality + TTS ready、quality + TTS unavailable、非-quality profile、health unknown 四种状态下核对按钮和文案。
- [ ] 生成四候选、播放两个候选、保存一个候选，核对服务端 voice 列表出现对应真实音色，重启页面后仍能试听。

## 3. 音色库 `voiceLibrary`

### 真实性接线审查

- [x] 列表来自 `GET /v1/voices`；系统音色和自定义音色分组真实反映响应。
- [x] 试听调用 `POST /v1/audio/speech` 并使用 `AudioPlaybackController`，不是空闭包或静音假反馈。
- [ ] 接入服务端已有的 voice delete 能力（若产品确认允许删除），并实现确认、进行中、成功、失败、误删恢复/刷新；没有 delete 契约时先补契约，不在 App 内伪造删除。
- [ ] 核实 voice response 是否包含 tags、created time、model source、关联作品所需字段；字段不存在时不要在 UI 生成假值，应补 API 或明确“未提供”。
- [ ] 设计音色详情 inspector：普通用户看用途/试听/使用入口，开发者看安全的 model source、variant、availability 和关联关系。
- [ ] 对服务端名称、description、instruction 等不可信文本设置行数、截断和详情展开边界；当前 live metadata 已证明超长内容会出现。

### Token / UX 审查

- [ ] 从“堆叠卡片”改为可扫描的双栏或 table/list：列表负责选择和试听，详情负责解释和操作；当前音色的选择态、播放态、不可用态要互斥且可读。
- [ ] 系统音色、自定义音色、不可用音色分别使用语义 token；颜色不是唯一状态依据，必须有文字/icon/AX value。
- [ ] 搜索、筛选、标签若未接真实数据暂不显示；不提供看似能用但不改变列表的空壳控件。

### 待验收

- [ ] 用超长 description、缺失可用 voice、试听失败、删除冲突四类数据验证截断和恢复。
- [ ] 核对试听同一时间只播放一个音色，切换页面后播放器停止，VoiceOver 能说出音色名称和播放状态。

## 4. 我的作品 `works`

### 真实性接线审查

- [x] 作品索引和音频文件来自 `CreativeWorkStore` 的 Application Support 目录，列表按真实文件和 index 读取。
- [x] 试听读取真实音频并交给 `AudioPlaybackController`；空状态能回到配音台。
- [ ] 修复错误可见性：`AppModel.refreshWorks()` 产生的 `creatorMessage` 当前没有在 `WorksView` 明确渲染；存储损坏、文件丢失、权限失败不能静默变成空列表。
- [ ] 增加导出/在 Finder 中显示/复制安全文件引用；导出失败要有可恢复提示，不能泄漏内部路径作为普通文案。
- [ ] 增加重命名、删除、再次编辑/复用前先确认数据模型和回收策略；涉及删除必须可定位目标且优先可恢复。
- [ ] 核实作品详情所需的 duration、file size、sample params、request ID、latency 是否有安全来源；缺少来源就标注 unavailable。

### Token / UX 审查

- [ ] 使用时间线/列表 + inspector 的信息结构，避免每个作品都是相同大卡片；当前选中作品要有清晰 focus/selection 和可见播放反馈。
- [ ] 用户文稿可显示完整内容，但需要折叠/展开和可读边界；开发者详情仅显示安全技术 metadata，不显示 raw service path 或 Authorization。
- [ ] 空、加载、损坏、播放失败、正在播放、已导出状态全部复用统一状态 token。

### 待验收

- [ ] 生成一件真实作品，退出/重新打开 App 后加载并播放；手动损坏 index 或移走音频，确认错误而不是“没有作品”。
- [ ] 验证长文稿、多个作品、键盘选择、VoiceOver inspector 和删除/导出确认。

## 5. 服务状态 `overview`

### 真实性接线审查

- [x] 服务健康和能力矩阵来自 `/health`；profile 和 Control Agent 状态来自 XPC。
- [x] 预检通过 XPC 执行 `preflight`；启动、停止、重启有 confirmation 和异步 operation 状态。
- [ ] 预检成功后在当前页给出明确结果和下一步；不能只依靠按钮禁用或跨页查看诊断。
- [ ] inspector 补齐 LaunchAgent label、port、control agent、listener/connection summary 等安全审计信息；不要把绝对路径和敏感配置直接给普通用户。
- [ ] 操作期间隐藏或降级旧的“已就绪”结论，改为“正在重启/健康检查中”；终态必须以新的 health/profile 读回为准。
- [ ] 服务启动失败、Control Agent 不可用、health 超时和 profile 不一致分别给出恢复路径，不共用一个模糊的“失败”。

### Token / UX 审查

- [ ] 页面首屏只保留一个服务结论、一个主恢复动作和一组能力事实；减少重复 status banner 与操作胶囊。
- [ ] capability matrix 使用统一的 ready/unavailable/unknown token；不能只用绿色/红色。
- [ ] 服务操作按钮与顶部 action menu 的 label、confirmation 文案和 pressed/loading 状态一致。

### 待验收

- [ ] 分别执行预检、启动、停止、重启的手动流程，核对 operation journal、health 回读和页面结果。
- [ ] 在 Control Agent 不可用和 service 已停止状态下验证恢复入口，确认不会执行模糊的 launchctl 或重复启动。

## 6. 运行监控 `monitoring`

### 真实性接线审查

- [x] 页面进入后通过 `AppModel.refreshMonitoring()` 读取 `/health` 和 `/metrics`，任务存活期间按 5 秒刷新。
- [x] metrics 失败时保留最后一份有效快照并显示错误/新鲜度边界，避免用零覆盖真实数据。
- [x] 当前页面展示的 request、queue、ASR/TTS latency、TTFA、realtime session、worker state 均可追溯到当前 JSON metrics/health 字段。
- [ ] 补齐或重新定义 memory：服务端需提供 resident bytes、physical memory、budget、overlap decision 等安全低基数指标；在契约完成前 UI 必须显示“未提供”，不能用模型大小或磁盘空间替代内存占用。
- [ ] 补齐 RTF 的真实来源和定义（ASR/TTS/streaming 分开）；没有 RTF 数据时不要把 latency label 改成 RTF。
- [ ] 增加 stale badge、last updated、样本数和 metrics 请求错误的显式状态；读到旧快照时必须让用户知道。
- [ ] 增加 worker tree、档位、准入预算、冲突/拒绝原因和可复制诊断报告；普通用户默认看结论，开发者展开细节。
- [ ] 核实图表时间窗、采样上限、空数据、服务刚启动和 counter reset；counter 下降时不要画出负速率。

### Token / UX 审查

- [ ] 以一条主趋势 + 紧凑 metrics strip + inspector 为骨架，主图只回答一个问题；不要把所有指标做成同等重量的卡片。
- [ ] 统一数值字体、单位、精度、趋势色和 unavailable/stale 状态；数值不能因窗口宽度换行或抖动。
- [ ] 图例、时间范围、刷新状态和错误操作使用系统控件和 tokenized toolbar，不再堆叠无名 icon。

### 待验收

- [ ] 只读状态下观察至少两个刷新周期，核对更新时间、样本数和 worker 状态与 `/health`/`/metrics` 一致。
- [ ] 模拟 metrics 暂时失败和服务恢复，确认旧数据保留、stale 明确、恢复后新快照替换。
- [ ] 在 server contract 增加 memory/RTF 后补端到端数据对账；在此之前不得宣称“监控看板完整”。

## 7. 模型 `models`

### 真实性接线审查

- [x] catalog/status 通过 XPC 读取；generic artifact 与 dedicated diarization lane 已区分，dedicated lane 是分人相关制品的权威状态。
- [x] 下载准备和档位应用分别调用 `model.prepare` 与 `profile.apply`；两者都有 confirmation，未自动下载、加载、卸载或切换。
- [x] 页面将“存在/完整性”和“当前使用/worker 生命周期”分开表达；`verified` 与 `cold_evicted` 不会被混成缺失。
- [ ] 强化目标档位与当前服务档位的文案。当用户查看 Balanced/Light 而服务仍为 Quality，`asr-1.7b-q8` 等共享制品必须同时显示“目标需要”和“当前服务是否使用”，不能只写“当前 ASR”。
- [ ] 所有 artifact 显示统一的存在状态、文件计数、完整性、使用状态、来源、量化和档位；`not_checked`、`unknown`、`invalid` 的下一步必须不同。
- [ ] OperationBar 补齐阶段、已完成/总大小、速度、ETA、校验、失败、取消中、取消完成和清理结果；只展示后端真实提供的数据。
- [ ] 下载完成后的“可应用”与“已应用”必须分开；应用成功要回读 profile/health，不能以 prepare 完成冒充服务已切换。
- [ ] 对 catalog 未登记旧制品保留隔离展示，避免普通用户把它当作当前可用模型；开发者可查看原因和处理建议。

### Token / UX 审查

- [ ] 先用档位选择器表达决策，再用制品表表达证据，最后用 OperationBar 表达动作；不把每个 artifact 做成独立大卡片。
- [ ] profile ready、downloaded、verified、in use、cold evicted、not checked 使用同一状态语义和 icon/文本组合。
- [ ] 下载、应用、取消、刷新使用标准按钮样式和明确 confirmation；静态完整性字段不可显示 pointing hand。

### 待验收

- [ ] 对 Quality、Balanced、Light 逐一核对 catalog、model status、profile status、health 和 UI 文案；记录目标/当前两套事实。
- [ ] 只在用户明确触发后验证一次下载/校验和一次 apply；验证成功、失败、取消和旧版本保留策略。

## 8. 诊断 `diagnostics`

### 真实性接线审查

- [x] 预检请求经 XPC 到受管制的 CLI；清单、选中检查项、结果和 developer details 均来自 typed preflight snapshot。
- [x] 已有“重跑预检/打开模型/查看服务”恢复入口，未直接让 App 执行 `launchctl` 或模型命令。
- [ ] 增加“复制诊断报告”安全动作：只复制 schema、状态、错误 code、时间、request ID/operation ID 等安全字段，过滤绝对路径、凭据、音频和 raw metadata。
- [ ] 对每个失败 code 建立修复映射：可自动重跑、需要打开模型、需要服务操作、需要用户授权、只能联系开发者；不要让所有失败都落到同一个按钮。
- [ ] 预检成功、部分失败、运行中、未知和旧快照分别可见；切换检查项不应丢失全局结论。
- [ ] 模型存在/使用事实与模型页采用同一 XPC snapshot 语义，不在诊断页重新猜测模型状态。

### Token / UX 审查

- [ ] 保持“一屏结论 + 左侧检查项 + 右侧解释/修复”的结构；在最小窗口和 Dynamic Type 下优先保证结论、选中项和主修复动作可见。
- [ ] 检查项状态使用 icon、文字、颜色三重表达；开发者详情默认折叠，展开后仍按 token 排版。
- [ ] 错误解释先说影响和下一步，再显示安全的 technical detail；不把英文 backend message 直接当主标题。

### 待验收

- [ ] 逐一选择通过、失败、未知检查项，核对解释、下一步和 AX label。
- [ ] 在最小窗口、增强对比度、VoiceOver 下确认检查项名称不被裁掉，主结论不需要滚动才能看到。

## 9. 全局 MenuBarExtra、Settings 与跨页行为

### MenuBarExtra

- [x] 状态 badge、打开控制中心、音色创作快捷入口、服务 start/stop/restart 和 Settings 入口均有真实 action；服务 mutations 有 confirmation。
- [ ] 菜单与控制中心使用同一服务状态事实和操作状态，不允许菜单显示旧的“已就绪”。
- [ ] 评估是否加入“模型”快捷入口；若不加入，在信息架构文档中明确模型操作只从控制中心进入，避免用户找不到模型下载。
- [ ] 检查 menu item 的 label、keyboard navigation、disabled 状态和操作后菜单关闭/反馈行为。

### Settings

- [x] “默认展开技术详情”通过 `@AppStorage("speechrail.showDeveloperDetails")` 持久化；关于信息显示定位和 macOS 26 最低系统。
- [ ] Settings 只保留真正的 App 偏好，不复制服务操作、模型下载或运行监控；若新增偏好必须声明影响范围和恢复默认动作。
- [ ] 统一 Form、section、label、secondary text 的 token 和 Dynamic Type；核对 Light/Dark/Increase Contrast/VoiceOver。

### 跨页状态

- [ ] page switch 不应丢失正在进行的 operation、播放状态或错误上下文；退出页面时只停止不应继续的播放器，不取消服务端已提交操作。
- [ ] 所有页面使用同一 service badge、operation bar、empty state、error state、developer inspector，不再各自定义一套近似组件。
- [ ] 顶部标题始终只出现一次；页面主体不得重新绘制“配音台/运行监控/模型”等重复标题胶囊。

## 10. 功能真实性追踪表

实现每个 TODO 时，追加一行“View → method → transport → endpoint/command → returned state → visible result”的证据。下表在功能完成前不可全部标记为通过。

| 功能点 | 真实入口 | 当前结论 | 责任页面 |
| --- | --- | --- | --- |
| 服务健康 | `GET /health` | 已接，需持续核对 stale/操作期间状态 | 服务状态、运行监控、全局 badge |
| 运行指标 | `GET /metrics` + `Accept: application/json` | 已接当前字段；memory/RTF/budget 缺口 | 运行监控 |
| 模型目录 | XPC `model.catalog` | 已接 | 模型、诊断 |
| 模型完整性 | XPC `model.status` | 已接，需强化目标/当前文案 | 模型、诊断 |
| 模型下载/校验 | XPC `model.prepare` | 已接，需补速度/ETA/清理语义 | 模型 |
| 档位应用 | XPC `profile.apply` | 已接，需回读 profile/health 证明生效 | 模型、服务状态 |
| 音色列表 | `GET /v1/voices` | 已接，需边界保护和管理闭环 | 配音台、音色库 |
| 配音生成 | `POST /v1/audio/speech` | 已接；按钮保存语义需修正 | 配音台、作品 |
| 音色 preview | `POST /v1/voices/previews` | 已接；门禁和候选语义需修正 | 音色创作 |
| 音色注册 | `POST /v1/voices/designs` | 已接；需说明按 seed 重注册 | 音色创作、音色库 |
| 作品索引 | `CreativeWorkStore` | 已接；错误不可静默 | 我的作品 |
| 音频播放 | `AudioPlaybackController` | 已接；需统一播放反馈 | 配音台、音色创作、音色库、作品 |
| 预检 | XPC `preflight` | 已接；需复制报告和错误修复映射 | 诊断、服务状态 |

## 11. 完成门槛

- [ ] P0 项全部关闭，尤其是音色创作 capability gate 和所有“存在/当前使用/目标档位”歧义。
- [ ] P1 主流程全部有真实来源、进行中、成功、失败、恢复和可见结果。
- [ ] 每个页面只使用统一 token；完成一次静态 literal/token lint 和一次人工视觉审阅。
- [ ] 运行监控只宣称服务端实际提供的指标；memory、RTF、budget 在契约和实测都成立后再进入完成结论。
- [ ] 完成 Light/Dark/Increase Contrast/Dynamic Type/Reduce Motion/最小窗口/键盘/VoiceOver 手工矩阵。
- [ ] 用户解除“暂停自动化测试”后，更新过期 UI tests，运行 App build、XCTest/XCUITest、Python contract gate，并把结果写入本文。
- [ ] 发布或安装前再次执行旧 App 退出/移入废纸篓、安装新版本、启动验证；测试应用验收完成后清理测试实例和临时运行态，但不删除用户模型和作品。

## 验证记录

- 2026-09-13：源码审查确认 `ServiceAPIClient` 为 `/metrics` 设置 `Accept: application/json`；服务端按 Accept 内容协商，未发现此前容易误报的“Prometheus 文本无法 JSON 解码”问题。
- 2026-09-13：只读核对 profile、catalog、model status、`/health`、`/readyz`、`/v1/models`、`/v1/voices` 和 JSON `/metrics`；未下载/加载/卸载模型，未改服务运行态。
- 2026-09-13 23:01：完成音色创作能力门禁的 fail-closed 修复；进入页面先刷新 health 和 voices，Debug 编译通过。自动化测试与真实 VoiceDesign 请求按用户要求未执行。
- 待补：解除自动化暂停后的人工全矩阵、真实创作链路、模型下载/应用链路、诊断故障注入和更新后的自动化测试。
