---
title: "提词器舞台：手动优先、语音辅助工程规格"
status: implemented
version: "1.2.0"
date: 2026-09-24
implementation_status: implemented_pending_ui_and_real_audio_acceptance
last_implementation_review: 2026-09-24
---

# 提词器舞台：手动优先、语音辅助工程规格

## 0. 文档用途、授权与证据

**产品定位：一个随时可手动控制的安静提词舞台：台词始终优先，语音按需协助，用户随时接管。**

用户已确认定位并要求产出可由 Luna 级智能体落实的 spec。本文件把定位细化为可实现、可测试的决定。2026-09-24 已把行为契约落到生产 Session、舞台、应用菜单和无设备测试；`implemented` 表示实现已完成到可编译、可确定性回归的程度，不表示真机视觉、焦点、VoiceOver、Reduce Motion、真实麦克风或真实服务端到端已经验收。

本文只取代 [`AI 提词器终版规格`](2026-09-20-ai-teleprompter-final-spec.md) 中与舞台手动优先、控制显隐、舞台快捷键、语音跟随生命周期和完稿反馈冲突的条款；朗读稿整理、目标时长、MapReduce、审阅、持久化与跟读算法契约不在取代范围内。

实施、构建、UI 自动化、安装、服务操作、提交与推送仍分别遵循当次用户授权和 AGENTS.md；不得因本文件列出验收步骤而自动接管窗口或发布。

本文中的 MUST/必须是验收要求；实际文件名可以在职责不变时调整，行为与验收条件不得自行删减。实现前读仓库及目录内 AGENTS.md、当前设计系统相关章节和提词器开发说明。以下路径均相对仓库根目录。

**实现基线（2026-09-24，源码、全量无设备测试与类型检查，非 UI/真实音频实测）：**

- `TeleprompterView` 的唯一主动作「打开提词器」只准备稿件并 `show()` 舞台，不调用语音启动。
- `TeleprompterSession.openForManualReading()` 不创建 source/client，不请求 coordinator；`enableVoiceAssist()` 必须显式调用，且每次异步启停都受 generation token 约束。
- `TeleprompterVoiceAssistLifecycle` 负责 `off/starting/following/stopping/stopFailed/pausedByUser/unavailable`；手动接管同步换 generation，旧回调不能推进或覆盖新状态。
- `TeleprompterStageInteractionPolicy` 固定 2s 首次展示、250ms 隐藏、4s 错误提示，并让指针、焦点、popover/menu、VoiceOver、键盘请求和常显设置阻止隐藏。
- `TeleprompterStageView` 将阅读层与控制层分开；顶部辅助条和底部控制区固定预留 24pt/64pt，隐藏只撤内容、命中和无障碍子树。
- `TeleprompterStageWindowController` 的用户关闭、系统关闭与程序关闭统一走 `closeStage()`；打开不调用 `makeKey()` 抢焦点。
- `macos/SpeechRailApp/Package.swift` 已把 Session、StageView、StageWindow、FollowController 和两项新增策略编入 `SpeechRailAppSupport.sources`，使用生产实现加 fake seam，不复制测试专用 Session。
- 当前工作区仍有其他任务未提交修改。实施与复核不得覆盖、回退或整文件重写非本功能改动。

## 1. 目标与非目标

### 1.1 必须实现

1. 不启用麦克风、不连接 ASR、不要求 AI 整理，即可打开非空稿件并手动阅读。
2. 所有手动定位都优先于语音结果，连接中、恢复中和服务故障时也有效。
3. 阅读时正文主导；鼠标离开且无其他交互时，非核心控制淡出，不改变正文布局。
4. 语音跟随必须主动开启；手动接管后停止采集并释放本功能占用，只有明确操作才能恢复。
5. 停顿、跳段、重复和即兴发挥不触发训导式提示、强制归位或强制结束。
6. 关键行为有不依赖麦克风、真实模型或 UI 自动化的确定性测试。

### 1.2 不包含

- 不改服务 REST/WebSocket/MCP 公共协议，不改模型、profile 或 ASR 核心算法。
- 不新增定速滚动、全局热键、后台键盘监听、脚踏板驱动、远程遥控、练习评分或新总结系统。
- 不重做稿件编辑/AI 整理工作流，不迁移持久化稿件格式，不删除既有稿件、标注、进度或历史。
- 不重构其他会话功能，不修改其占用规则；不把整个页面统一玻璃化。
- 本期只清理舞台上的评价性内容；现有时间预算、标注等数据与准备页能力保持不变。

## 2. 已确定的产品决定

| ID | 决定 | 验收含义 |
|---|---|---|
| D01 | 默认手动，手动控制权最高 | 打开舞台不触发语音启动，包括上次退出时曾开启语音的情况 |
| D02 | 手动接管后不自动恢复 | 不使用静默超时、读回原稿或“高置信度”自动重新开启采集 |
| D03 | 手动接管立即废弃旧语音推进权限 | 清理尚未结束，也不能让旧结果移动台词 |
| D04 | 手动接管释放麦克风及本功能占用 | 不只是停止上传但继续收音 |
| D05 | 空格执行下一段 | 不随语音状态改变语义，不隐式开启麦克风 |
| D06 | 末段仍是台词 | 到末段/读完末段/反复下一段均不自动展示总结或关闭 |
| D07 | 专注状态保留正文和最小采集状态 | 不常驻节奏评价、进度、段落说明和操作按钮 |
| D08 | 语音失败是辅助失败 | 不遮挡台词、不禁用手动操作、不自动抢回资源 |
| D09 | 不依赖 hover 获得控制 | 键盘与 VoiceOver 均有独立可达路径 |

替代方案记录：本期不采用“手动操作后短暂等待并自动恢复语音”，因为恢复时机不可预测；也不采用“手动时后台继续收音”，因为默认手动不应隐含持续设备占用。后续改变这些决定须另行评审，不由实现者自行优化。

## 3. 用户流程

### 3.1 打开与关闭

- 准备页唯一主动作命名为 **打开提词器**。删除重复的“打开并开始跟读/只打开窗口”入口组合，保留一个确定性入口。
- 非空草稿可复用现有 deterministic fallback 生成阅读版本；不得调用 LLM/ASR，不自动采用尚未确认的 AI 建议。准备失败留在准备页，说明具体可操作原因。
- 已有有效阅读版本按既有保存进度打开，越界进度 clamp 到合法段落；新稿从首段开始。不得因上次 `.ended` 而打开总结页。
- 每次从关闭状态重新打开都处于手动模式。已打开的同一舞台仅前置窗口，不重置阅读位置或主动关闭当前语音。
- 点击关闭按钮、窗口关闭、舞台聚焦时 Esc、应用退出等路径都必须使该舞台采集停止、旧结果失效、资源释放；不弹总结、不弹“是否结束演说”。保存失败不得无限阻止关闭，但须在主界面留下非敏感错误反馈。
- 不关闭其他窗口、不停止共享服务、不释放其他功能所有的资源。窗口前置不能成为抢占麦克风的理由。

### 3.2 手动操作

- 一级控制：**上一段、下一段、语音跟随、显示设置、关闭**。不把“开始/暂停提词”作为入口，因为台词从打开时就已可读。
- 左/上/PageUp：上一段；右/下/PageDown/空格：下一段；Home/End：首段/末段。边界 clamp，无越界、无循环、无自动完成。
- 鼠标点击可见的非当前段：定位该段；点击当前段正文不改变位置、不暂停语音。选择正文文本也不应被整段 Button 劫持为定位。
- 在正文区域直接滚轮/触控板滚动：视为手动接管，停止自动定位，但只滚动视口，不隐式推进段落索引。程序化滚动、惯性尾部重复事件不重复发起停止任务。
- 当前段过长必须允许原生滚动阅读全部内容，不能截断且无入口；切换段落后将新段开头放回稳定阅读锚点。
- 下一段是“按语义段定位”，不是按屏幕高度翻页。保持默认当前段+下一段，不把 ASR 字词切片变成视觉段落。
- 从首段执行上一段/从末段执行下一段同样表达手动意图：若语音正在工作，则停止语音，位置不变。正文选择、鼠标移入移出、字号改变不算手动定位。
- 普通快捷键只作用于聚焦的舞台阅读区域。编辑框、滑杆、菜单、popover 和辅助技术控件保持系统按键语义；不得让空格激活聚焦按钮的同时又翻段。
- 移除舞台中 R“重新跟读”的旧隐式启动语义与 Command-A“查阅全稿”的自定义语义，不覆盖系统全选。查阅全稿保留为“显示设置”内显式动作，进入时按手动接管处理；退出恢复当前索引的阅读锚点，不启动语音。
- 既有字号和背景透光快捷键可保留；菜单栏提供与舞台同源的上一段/下一段/语音跟随/显示设置/关闭命令，不重复实现状态逻辑。

### 3.3 语音辅助

- 点击 **开启语音跟随** 才进行权限检查、占用申请和 ASR 连接，从当前手动位置开始，不能跳回首段。
- `starting` 显示“正在开启…”及可取消操作；正文、翻段始终可用。`stopping` 不接受再次开启；`stopFailed` 提供“重试停止”而非“重试语音跟随”。
- 跟随开启后按钮为 **关闭语音跟随**；暂停后的按钮为 **恢复语音跟随**。错误后的按钮为 **重试语音跟随**。
- 任意手动定位/滚动立即暂停自动推进并请求停止采集。再次开启必须显式操作。
- 本期不添加额外语音快捷键，避免占用新的全局或单字母键；键盘用户通过菜单或 Tab 聚焦按钮开启。
- 不确定匹配时保持位置，可以继续在当前捕获会话内等待附近稿件的新匹配。这与手动接管不同：**只有用户未接管且会话仍为当前有效代次，自动跟随才可继续**。
- 不确定状态不弹横幅、不显示“归队”，不要求用户读指定词。详情中可查看“暂未匹配到当前内容”。
- 权限拒绝、服务离线/繁忙、别的功能占用、连接失败：保留当前位置与全部手动能力，不主动停止别的功能，不自动重试。

## 4. 状态与异步契约

### 4.1 状态职责

不要将稿件准备、窗口显示、语音状态和控件显隐继续混为一个 `Phase`。保留现有稿件状态和持久化结构，新增或抽取下述运行态职责；现有 `Phase` 可保留为内部兼容映射，但不得成为另一份独立可写事实源。

建议定义 `TeleprompterVoiceAssistState`：

- `off`：本次打开尚未开启或用户明确关闭。
- `starting`：正在申请或连接，可取消。
- `following`：可接受当前代次推进；是否匹配不确定由现有 follow state 提供。
- `stopping`：已撤销推进权，等待资源清理。
- `stopFailed(reason)`：推进权仍撤销，但清理失败/资源归属尚未确认；仅允许重试停止、手动阅读或关闭，不允许重新开启。
- `pausedByUser`：手动接管后清理完成，可明确恢复。
- `unavailable(reason)`：清理完成，辅助失败，可明确重试。

阅读位置沿用 FollowController 的唯一位置模型。显隐状态只负责视图，不得暂停语音或改变稿件。新增运行态不写入稿件 JSON。

### 4.2 事件表

| 事件 | 同步动作 | 异步动作/终态 |
|---|---|---|
| 首次打开有效稿件 | 显示保存位置，语音 off | 无采集动作 |
| 开启/恢复/重试 | 新建有效 generation，进入 starting | 获取自己的占用，连接成功后 following |
| following/starting 时手动定位 | 先使旧 generation 失效，更新位置，进入 stopping | 停止并释放自己的资源，进入 pausedByUser |
| off/paused/unavailable 时手动定位 | 更新位置，不新增采集任务 | 无 |
| following 时显式关闭语音 | 使 generation 失效，保留位置 | stopping → off |
| starting 时取消 | 使 generation 失效，保留位置 | stopping → off |
| matching uncertain | 不改变人工位置，不显示训导 | 当前会话继续等待匹配 |
| 当前语音失败 | 立即撤销推进，保留位置 | 清理后 unavailable |
| 任意状态关闭舞台 | 撤销全部推进/启动意图 | 清理、保存进度；重新打开 off |
| 清理中再次开启 | 不排队自动开启，不启动第二条连接 | 控件解释“正在停止…”，完成后由用户重试 |
| 清理失败 | 保持位置、撤销推进权，进入 stopFailed | 显示“停止未完成”及“重试停止”；重试成功进入原定 off/pausedByUser/unavailable |

### 4.3 必须守住的竞争条件

1. 所有阅读状态修改在 MainActor 或既有串行隔离边界内完成。手动事件先递增/替换 generation，再异步清理，不能 await 完再保护位置。
2. partial、final、alignment、连接成功、连接失败、close 回调以及 `drainAndClear` 恢复任务，都校验捕获时的 generation；每次跨 await 后重新校验。过期任务不能改位置、错误状态、运行稿件或新会话资源。
3. 停止流程幂等；关闭旧 client 使用旧引用。不得在 await 返回后将后来创建的新 client/source 清空。
4. 手动连续翻段即时更新，不等待清理；只运行一个停止流程，最后一次手动位置获胜。
5. 连接尚未完成就取消时，晚到的已连接 client 必须关闭，晚取得的本功能资源必须释放，但不得停止其他功能。
6. 禁止同一舞台存在两条采集/ASR pipeline；停止完成前不允许开启。停止失败不能谎称已释放：维持无推进权的停止失败状态、显示可操作错误并阻止第二条启动；关闭窗口仍执行本地 source 停止及幂等清理。
7. 继续复用现有 `captureGeneration`、coordinator 与 drain/clear 机制；可以收敛旧暂停路径，但不能删除晚到事件屏障。新连接也从最新手动位置初始化 controller。
8. 手动接管不是结束演讲，不重置台词、保存进度或已用时；不得通过 `endFollowing()` 的 `.ended` UI 副作用实现普通接管。
9. 正文更新不请求焦点、不调用 `makeKey()`；后台语音不能抢走用户正在操作的应用焦点。

## 5. 舞台显示规范

### 5.1 两层布局

- **阅读层**：当前段正文、下一段预览、既有轻量当前位置标记。保留完整语义段落和自然换行，正文不随控件一起变透明。
- **控制层**：使用固定区域或 overlay 承载按钮、可选进度/计时及状态详情；淡出不改变正文宽度、高度、换行或锚点。预留空间不能覆盖长段落最后一行。
- 专注状态去掉段落小标题、停顿指导、速度提示、恢复匹配横幅、呼吸光效、庆祝动画与自动总结入口。保留标注数据，但舞台默认不显示停顿/强调训练标记。
- 正文以语义字体/现有 token 绘制；不要在语音不确定时给整段加红色或大面积警告底色。
- 文字对比度优先，背景透光与文字透明度分离；下一段只降视觉层级，不得降到不可读。

### 5.2 显隐规则（确定值，不留给实现者猜测）

定义 `controlsVisible` 为以下条件的 OR：

1. 指针在舞台内容区域；
2. 控件区域包含键盘焦点；
3. 由舞台打开的菜单/popover 正在展示；
4. 开启“始终显示控制”；
5. VoiceOver 开启；
6. 首次打开后的 2 秒发现窗口尚未结束；
7. Tab 导航触发的键盘显现请求尚未完成焦点转移。

- 以上全部不成立时，延迟 250ms 后隐藏，复用现有标准动效时长；再次进入立即取消过期隐藏任务并显示。
- 鼠标一直停在舞台内时不做额外 idle 隐藏，本期不增加猜测性超时规则。
- Reduce Motion 开启时不做淡入淡出位移动画，延迟逻辑不变。
- Tab 从阅读层进入控制层时先显示再移动焦点；控件有焦点时持续可见。Esc 优先关闭已打开的菜单/popover，否则关闭舞台。
- 隐藏控件禁用 hit testing，不留下透明可点击区域；不可聚焦于不可见按钮。键盘显现入口、菜单命令及 VoiceOver 路径不依赖隐藏的 Button 是否仍挂载。
- VoiceOver 启用时控制区常显，按阅读内容→翻段→语音→显示→关闭组织顺序；不逐字播报 ASR 更新，不强制移动辅助技术焦点。
- 显隐策略抽为可单测纯状态/策略，使用注入时钟验证延迟，不用测试真实 sleep。

### 5.3 显示设置

保留字号、背景透明度与既有预设。增加布尔设置：

- “始终显示控制”：默认 false，持久化在舞台偏好；
- “显示计时与进度”：默认 false，持久化在舞台偏好。

新增键使用项目既有 UserDefaults 命名规范，缺省值不迁移旧稿件。设置变更即时生效，不重开窗口、不重置位置、不停止语音。始终显示控制不等于开启节奏评价。

计时与进度开启后在固定辅助区域显示，即使控制层淡出也保留，但不改变正文布局。计时从本次舞台打开开始，到关闭结束，手动/语音切换与错误都不中断，不复用“暂停语音即暂停计时”的旧语义。重复前置同一舞台不重置计时。仅显示实际已用时与段落进度，不显示预计完成时间、快慢评分、超时警报或建议语速；不新增持久化统计。

### 5.4 采集与错误反馈

- 实际麦克风 source 活跃时保留低干扰固定角标“麦克风使用中”，不随控制层隐藏；它不是关闭按钮，不制造透明点击区。辅助技术提供完整标签。
- 仅连接、尚未采集时不能显示“正在收音”；停止请求发出但 source 尚未停止时也不能提前隐藏角标。以实际资源状态为准。
- 语音失败可显示一次 4 秒的轻量提示“语音跟随不可用，可手动继续”，在固定反馈层显示、不盖住台词、不抢焦点；详细原因与重试长期保留在语音控件/菜单中。提示支持辅助技术适度宣告，不重复刷屏。
- 稿件保存失败与辅助错误分开：说明“进度未保存”，当前阅读仍可用；不能用语音不可用的提示掩盖保存问题。不得宣称已成功保存。

## 6. 工程落点与接口职责

| 文件/位置 | 变更职责 |
|---|---|
| `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift` | 主入口改为只准备并打开；去掉默认启动语音和重复入口 |
| `.../TeleprompterSession.swift` | 阅读与语音状态分离，显式启停、手动接管、generation 校验、末段与计时行为 |
| `.../TeleprompterFollowController.swift` | 人工定位优先、边界行为、过期推进防护所需最小扩展；不重写匹配算法 |
| `.../TeleprompterStageView.swift` | 阅读/控制层分离、显隐、普通用户文案、按键与滚动分流 |
| `.../TeleprompterStageWindow.swift` | 程序/用户关闭统一生命周期，不制造双重停止或漏停 |
| `.../TeleprompterStageSettings.swift` | 两项偏好及默认值，不改稿件 schema |
| `.../TeleprompterStageInteractionPolicy.swift` | 显隐原因、2s 首次展示、250ms 隐藏、4s 错误提示的唯一声明点 |
| `.../TeleprompterVoiceAssistLifecycle.swift` | 显式启停状态、generation token、停止失败重试与旧回调失效 |
| `.../TeleprompterRealtimeClientProtocol.swift` | 生产 Session 与 fake client 共享的依赖边界 |
| `.../SpeechRailDesignTokens.swift` | 新增固定辅助区 24pt 与控制区 64pt 的布局语义值，复用既有颜色、字体和间距 |
| `.../App.swift` | 增加「提词器」应用菜单命令，不把快捷键绑到零尺寸透明按钮 |
| `macos/SpeechRailApp/Package.swift` | 将生产 Session、Stage、两类策略和 client seam 纳入显式 sources，让 SwiftPM 回归直接测试同一实现 |
| `docs/developers/macos-app-teleprompter.md` | 同步主流程、快捷键、接管、采集与故障语义 |
| `docs/developers/macos-app-design-system.md` | 同步舞台分层、token、显隐和无障碍规范 |

表中 `.../` 均指 `macos/SpeechRailApp/SpeechRailApp/`。实际实现用 `TeleprompterStageInteractionPolicy.swift` 承载纯显隐策略，用 `TeleprompterVoiceAssistLifecycle.swift` 承载语音生命周期，并用 `TeleprompterRealtimeClientProtocol.swift` 提供生产 Session 的 client 测试边界；没有新增空包装层。

**实际对外意图接口（职责不可合并）：**

- `openForManualReading()` / `openForManualReadingIfNeeded()`：确保可读版本和位置，无音频副作用，重复前置不重置；
- `moveToPrevious()` / `moveToNext()` / `moveToSegment(_:)` / `takeOverForManualScroll()`：同步撤销语音推进并处理位置/视口，启动幂等资源清理；
- `enableVoiceAssist() async`：显式启动当前位置的跟随；
- `disableVoiceAssist() async` / `retryStopVoiceAssist() async`：关闭辅助但保留舞台，停止失败保持 fail-closed；
- `closeStage() async`：统一停止、保存及关闭生命周期。

会话旧入口的调用方必须逐一迁移，不能只有新按钮走新路径而翻页笔/菜单/窗口关闭仍走旧路径。避免同时存储 `phase`、`voiceState`、`isFollowing` 三份相互独立的状态；派生值只读。

## 7. 可验证性与验收矩阵

所有单测使用 fake transport/source/coordinator、临时偏好存储与可控时钟；不得访问真实音频、模型或云端。实际新增测试为 `TeleprompterStageInteractionPolicyTests.swift`、`TeleprompterVoiceAssistLifecycleTests.swift` 和 `TeleprompterSessionLifecycleTests.swift`；FollowController/StageSettings 回归继续执行。

| ID | Given / When | 必须验证的 Then |
|---|---|---|
| A01 | 非空草稿、服务离线、麦克风拒绝；打开 | 可读可翻；权限请求、采集、ASR、LLM 调用次数均为 0 |
| A02 | 存在未采用 AI 草稿；打开 | 不自动采用；仍用已采用版本或原稿确定性版本 |
| A03 | 手动到第 N 段；开启语音 | 只开一条 pipeline，从 N 初始化，绝不归零 |
| A04 | following；手动下一段；注入旧 partial/final | 新位置不变，旧 generation 不能推进或覆盖错误状态 |
| A05 | starting；手动定位；延后连接成功 | client 被关闭，最终无本功能占用，不进入 following |
| A06 | 恢复屏障 await 中；手动跳段/关闭；屏障完成 | 不恢复、不抢焦点、不再上传 |
| A07 | following；连续翻 20 次且清理未完 | 每次即时合法定位，只清理一次，末次意图获胜 |
| A08 | following；滚轮浏览长段落 | 自动推进停止，视口可动，段索引不隐式改变；程序滚动不触发接管 |
| A09 | 语音失败/繁忙/他人占用 | 手动正常，不自动重试，不停止他人采集 |
| A10 | 手动接管后静默或朗读原稿 | 不恢复；明确恢复按钮后才可重新启动 |
| A11 | 首段/末段；越界翻段；末段语音完成 | clamp、仍显示正文、无总结、无自动关闭 |
| A12 | 程序关闭/系统关闭/Esc/退出、重复关闭 | 旧事件全部失效，自己的 source/client/占用各自最终释放；无双重副作用 |
| A13 | 指针离开 249ms / 250ms；随后重入 | 正确延迟隐藏；过期任务不能隐藏重新显示的控制 |
| A14 | 焦点/菜单/popover/VoiceOver/常显开启 | 鼠标离开也不隐藏；关闭这些条件后才进入隐藏流程 |
| A15 | 首次打开 2s 到期且指针在外 | 隐藏；重复前置同一窗口不重置会话/采集 |
| A16 | Reduce Motion | 不播放装饰/过渡动画，不改变显隐结果 |
| A17 | 空格/方向键/Home/End；控件或输入框有焦点 | 阅读区按新语义；其他控件保留原生操作，无双重触发 |
| A18 | 改字号/透明度/显隐设置 | 不改变位置、语音状态或启动计数；偏好新实例读取一致 |
| A19 | 手动→语音→失败→手动 | 舞台计时连续，只随本次打开/关闭起止；默认不显示 |
| A20 | 过期失败回调到达新会话 | 不停止新 client/source、不覆盖新状态 |
| A21 | 停止失败、保存失败 | 不宣称资源释放/保存成功；可读、可关闭，错误明确且无敏感内容 |
| A22 | 本次关闭时语音开启；再次打开 | 保存位置保留，语音 off，无隐式权限或连接请求 |

### 7.1 必须包含真实生产逻辑的无设备测试边界

Session 已编入 SwiftPM sources，语音启动/停止/generation 协调由生产 `TeleprompterVoiceAssistLifecycle`、`TeleprompterRealtimeClientProtocol` 和 `TeleprompterSession` 共同承载；测试直接驱动同一生产实现，没有复制“测试用 Session”。

测试要驱动可延迟完成的 fake start/stop/drain，断言资源调用计数、捕获代次与位置；只测试 enum/reducer 不能证明资源实际释放。Session 组装必须直接委托被测组件，不在 UI 层再维护一份生命周期。FollowController 的原有定向回归继续执行。

### 7.2 验证命令与授权边界

在后续实施授权覆盖定向测试后，可从根目录执行（新增 suite 名称与实际一致）：

```bash
swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterStageSettingsTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterStageInteractionPolicyTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterVoiceAssistLifecycleTests
git diff --check
```

SwiftPM 通过不能证明 SwiftUI 舞台已编译。App 构建需按 release skill 和用户授权使用 `scripts/macos_app_build.sh --configuration Debug`，不得裸跑产出 `.app` 的 xcodebuild。依赖不可用时报告，不擅自升级或下载模型。

视觉与焦点验收须另获当前用户明确授权后执行：长段落/窄窗口、淡出前后正文几何一致、透明区域无误点击、Tab 恢复、VoiceOver、Reduce Motion、窗口关闭与其他应用焦点共存。任何 UI 自动化未执行均记为“未验证”，不能以单测或截图推断通过；不默认运行 `scripts/macos_app_test.sh`。

## 8. 实施分解与交付顺序

以下依赖顺序已于 2026-09-24 执行完成；保留用于交付复核、回退定位和后续同类改造。该记录不授权自动提交、安装、发布或改变运行态。

1. **基线与测试 seam**：确认未提交改动归属，定位所有旧入口；抽取生产可测试边界，先补 A04/A05/A06/A20 的失败测试。
2. **手动默认与语音生命周期**：落实 D01–D04、打开/关闭、资源释放；通过 A01–A12/A20–A22，不先用 UI 显隐掩盖状态问题。
3. **手动交互与末段**：统一键盘/菜单/鼠标/滚动意图，清理空格/R/Command-A 旧语义；落实长段落可读和末段不结束。
4. **阅读与控制分层**：纯策略测试先行，再接入 UI；落实显隐、不重排、计时、采集角标和中性错误反馈。
5. **文档与定向验证**：同步两份开发文档和 token 声明，运行已授权最小测试；单独记录 App 编译、视觉、无障碍、真实采集哪些未验证。

每项输出：修改路径、覆盖的验收 ID、实测结果/时间、未验证项、残余风险。不可只写“测试通过”；列出测试 suite 与关键断言。最终提交前检查没有顺手修改其他会话、README 或公共服务协议。

## 9. 完成标准与回退

完成必须满足：

- 本文所有 MUST 对应实现或明确的未完成项；A01–A22 有具名测试/验证证据，UI 项无授权时明确标注未验证，不声称完整验收。
- 打开即读，手动无需语音；辅助主动开启，人工意图不可被旧回调撤销。
- 舞台没有强制归队、催促、自动总结或末段强制结束；控制隐藏不影响文本位置和键盘可达性。
- 实际资源状态与采集提示一致，所有关闭路径不会遗留本功能采集。
- 正式文档与实现一致；不删除/迁移用户稿件，不更改共享服务运行态。

兼容影响须明确说明：空格从开始/暂停语音改为下一段；R 不再隐式重读并开启语音；Command-A 恢复原生语义；默认打开不再自动跟读；舞台不再自动展示节奏总结。这些是有意的产品行为变化，不保留隐藏的旧快捷键兼容分支。

回退只撤销本次应用代码与文档变更，保留全部稿件、历史、标注、保存进度和未知偏好。新增两项偏好使用独立键，旧版本可忽略；不清空 UserDefaults。存在并行修改时不得用整文件还原或硬重置回退。安装/部署回退不在本 spec 授权范围内。

## 10. 2026-09-24 落地与验收记录

### 10.1 已执行证据

| 验证 | 结果 | 时间 |
|---|---|---|
| SwiftPM 全量测试 | `135 tests / 15 suites` 全部通过，包含 `TeleprompterSessionLifecycleTests`、`TeleprompterVoiceAssistLifecycleTests`、`TeleprompterStageInteractionPolicyTests`、FollowController 与 StageSettings 回归；覆盖同段偏移保留、跨段回到段首、键盘请求离开焦点/指针后结束、准备中/关闭中拒绝手动打开、关闭语音后保持手动 | 2026-09-24 21:20 CST |
| App 源集类型检查 | 88 个 `SpeechRailApp` Swift 源文件经 `swiftc -disable-sandbox -typecheck`，退出码 0；仅 1 条既存 `maxTokens` 弃用警告 | 2026-09-24 20:27 CST |
| Xcode 工程接线 | 三项新增生产文件已加入 App target 与 Sources phase；三个新增测试文件及 Session、VoiceAssistLifecycle、StageInteractionPolicy、RealtimeClientProtocol、SessionCoordinator、SessionStore 依赖已加入 `SpeechRailAppTests` Unit Test Sources；`plutil -lint project.pbxproj` 通过 | 2026-09-24 21:20 CST |
| 格式检查 | `git diff --check` 无空白错误 | 2026-09-24 |
| 完整 Xcode App Debug 构建与 Unit Test-only | `scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**；`xcodebuild ... -only-testing:SpeechRailAppTests` **TEST SUCCEEDED**，135 tests / 15 suites | 2026-09-24 21:29 CST |
| UI、VoiceOver、Reduce Motion、真实采集与真实服务端到端 | **未执行**：当前用户未逐次授权 UI 自动化；本记录不推断视觉或音频质量 | 2026-09-24 |

### 10.2 A01–A22 验收映射

| ID | 当前证据 | 状态 |
|---|---|---|
| A01 | `TeleprompterSessionLifecycleTests.manualOpenHasNoAudioSideEffects` 断言 source/client 为 0、coordinator 空闲、可前后翻段 | 已验证 |
| A02 | `manualOpenKeepsAcceptedVersion` 断言未采用 AI 草稿仍在 `pendingVersion`，活动版本保持已确认版本 | 已验证 |
| A03 | `manualTakeoverInvalidatesOldPipeline` 从第 2 段开启语音，断言只启动一个 pipeline 且位置不回零 | 已验证 |
| A04 | `TeleprompterFollowControllerTests.eventsAfterManualTakeoverCannotMovePosition` 与 `manualTakeoverInvalidatesOldPipeline` 的旧失败事件断言 | 已验证 |
| A05 | `lateConnectAfterManualTakeoverIsReleased` 延迟连接后手动跳段，断言晚到 client 被关闭、无占用、无 source | 已验证 |
| A06 | 代码审查：`enableVoiceAssist()` 先检查 `isResuming`/停止态，代次在异步边界失效；尚无独立恢复屏障测试 | 部分证据 |
| A07 | `repeatedManualNavigationIsIdempotent` 连续 60 次定位，断言末次位置获胜、仅一次 drain 与 close | 已验证 |
| A08 | 代码审查：全稿浏览调用 `takeOverForManualScroll()`，滚动只接管不改变段索引；尚无真实滚轮手势测试 | 部分证据 |
| A09 | 代码审查：他人占用返回 `occupiedBy`，语音失败保持 manual 且不调用对方 stop；尚无占用集成测试 | 部分证据 |
| A10 | `failedStartIsUnavailableUntilUserStartsAgain` 与显式状态路径；不存在静默恢复分支 | 已验证 |
| A11 | FollowController `manualMovementClampsAtBothEnds`；舞台末段只 clamp，没有总结或关闭调用 | 已验证 |
| A12 | `repeatedCloseDoesNotDuplicateRelease`、`closeAndReopenPreservesPosition`、`manualOpenRejectsDuringClose`；Esc/系统关闭路径经源码审查与类型检查 | 部分证据，无 UI |
| A13 | `visibilityTimingIsStable` 锁定 2s/250ms/4s；异步过期任务取消由代码审查确认 | 部分证据，无 UI |
| A14 | `visibleReasonsPreventHiding` 覆盖焦点、菜单、VoiceOver、常显；`keyboardRevealEndsWhenFocusLeaves/PointerLeaves` 覆盖键盘请求退出条件；舞台环境接线由类型检查确认 | 部分证据，无 UI |
| A15 | `manualOpenRejectsWhileSessionIsPreparing`、`manualOpenRejectsDuringClose` 与幂等前置共同验证；重复前置仍走同一打开入口 | 已验证状态边界，UI 重前置未测 |
| A16 | 代码审查：Reduce Motion 关闭装饰动画且不改变显隐结果 | 未验证 UI |
| A17 | 空格/方向键/Home/End 处理器已由全源集类型检查；焦点与原生控件双重触发未做 UI 验证 | 部分证据，无 UI |
| A18 | `stageVisibilityPreferencesPersist` 与几何测试；显隐设置不经过会话状态写入路径 | 已验证偏好，无 UI |
| A19 | `runClockSurvivesVoiceTransitions`；进度与计时默认隐藏由设置默认值测试覆盖 | 已验证 |
| A20 | 代码审查：所有回调校验 generation token；尚无跨新会话迟到失败注入测试 | 部分证据 |
| A21 | `stopFailureBlocksASecondPipeline` 与 `failedStopRequiresExplicitRetry`；保存失败文案由类型检查确认 | 已验证停止失败，无 UI |
| A22 | `closeAndReopenPreservesPosition` 断言位置保留、voice `off`、无新权限或连接请求 | 已验证 |

### 10.3 剩余验收边界

发布或宣称完整验收前仍需：在明确授权下走查控件淡出前后正文几何、Tab/焦点恢复、VoiceOver、Reduce Motion、窄窗与长段落；用真实麦克风和真实服务验证显式开启、手动接管、停止失败重试、关闭释放与重新打开。上述任一项没有实测时保持“未验证”，不能用构建、单测或 fake transport 测试替代。

### 10.4 Review 修复落地（第二轮）

| 修复项 | 落地与证据 |
|---|---|
| 同段定位保留阅读偏移，跨段定位回到段首 | `TeleprompterFollowController.manualMove(to:segmentCount:)`；`sameSegmentManualMovePreservesReadingOffset`、`differentSegmentManualMoveStartsAtParagraphBeginning` |
| 键盘显示控制的请求在焦点或指针离开后结束 | `TeleprompterStageInteractionState`；`keyboardRevealEndsWhenFocusLeaves`、`keyboardRevealEndsWhenPointerLeaves` |
| 准备中或关闭中打开舞台给出明确错误，不静默失败 | `TeleprompterStageOpenError.busy/.closing`；`manualOpenRejectsWhileSessionIsPreparing`、`manualOpenRejectsDuringClose` |
| 关闭语音后已打开舞台保持手动语义 | `performVoiceStop` 在舞台未关闭时落 `manual`；`disablingVoiceAssistKeepsStageManual` |
| 舞台打开不再由页面先吞错 | `TeleprompterView.showStage()` 直接调用 `stage.show()`，统一读取 `lastPresentationError` |
| 工作台语音按钮与实际生命周期一致 | `.off` 不显示；`.following` 关闭；`.stopFailed` 重试停止；`.pausedByUser` 恢复；`.unavailable` 重试；`.starting/.stopping` 禁用 |
| 非当前段可定位但不劫持正文选择 | 删除整段 `contentShape` + `onTapGesture`，改为非当前段右侧定位按钮；正文保留 `.textSelection(.enabled)` |
| 舞台默认不呈现训练标注、呼吸光效、脱稿归队、节奏看板或自动复盘 | `styledText` 不再消费 `segment.keywords`；删除对应旧视图、动画和已无引用的舞台 Token |
| 菜单命令不再占用全局方向键，阅读区补 PageUp/PageDown | `App.swift` 舞台命令仅在 `teleprompterStage.isVisible` 时提供；舞台按键注册补充 `.pageUp/.pageDown` |
| 新测试与生产依赖进入 Xcode Unit Test Target | `SpeechRailAppTests` 的 Unit Test Sources 已接线 3 个新增测试文件及 6 个生产依赖；`plutil -lint project.pbxproj` 通过 |

当前测试与构建结果见 §10.1。UI、VoiceOver、Reduce Motion、真实麦克风与真实服务端到端仍未验证；本次 review 修复不改变这一验收边界。
