# SpeechRail「语音助手」「会议助手」「AI 提词器」UI 文案与无障碍体系化优化方案

> **制定日期**: 2026-10-17
> **目标范围**: `AssistantView.swift`、`MeetingView*.swift` + `InnerOSDrawer.swift`、`TeleprompterView.swift` + `TeleprompterStageView.swift` + `TeleprompterTrialReadingSheet.swift` + `TeleprompterReadingAliasSheet.swift`
> **状态**: `completed`（全部 13 个视图文件已落地并通过 Swift 6 类型检查、覆盖门禁及 62 项确定性单测核验）
> **前置基线**: 延续 [有声书制作模块 UX/UI 现代化重构方案 §6](2026-10-16-audiobook-ux-ui-redesign.md) 的文案与无障碍走查方法，保留工作树中所有既有改动（尤其 [AI 提词器模块体验优化](2026-10-17-teleprompter-ux-ui-redesign.md) 的本地未提交改动），不覆盖、不回退。

---

## 1. 指导原则与红线约束

1. **动作直白、结果可预期**：按钮与菜单项使用「动词 + 明确对象」（如 `静音麦克风`、`结束对话`、`暂停录制`、`确认采用并开台`），避免只写含糊单字或只写内部概念。
2. **去除内部实现术语与装饰符号**：将界面中残留的提示词/工程实现术语（如 `按设计规范`、`PCM 纯内存流转`、`自动注入提示词上下文`、`口述字符稿`）和菜单按钮中的装饰 Emoji（`🎙️`、`✨`、`📚`、`🎨`、`🔄`）替换为平实、符合 macOS 原生习惯的中文表达与 SF Symbols。
3. **同义词与主次入口收敛**：同一功能在顶栏、主控区、右键菜单、检视器、弹窗中的名称保持一致（如统一为 `静音麦克风` / `取消静音`、`结束对话`、`检查麦克风音量…`、`稿件`、`导入文稿…`、`正文栏宽`、`常显底部控制栏`、`关闭`）。
4. **严格保护既有语义与产品决定**：
   - 不改变任何确认弹窗、隐私提示、文件保存、录音采集、中断恢复与快捷键语义；
   - 不改动既有单元测试契约断言所依赖的底层状态投影文案（如 `MeetingSourcePresentation` 的 `正在录：麦克风 + N 个 App 的系统声音` / `已存下 N 句`、`MeetingAxisProjection` 的 `审阅：降级（N 条待核对）`、`MeetingOpenItems` 的 `未完成事项（共 N 条）`）；
   - **AI 提词器**严格保持既有产品决定：原稿在 `.draft` / `.ready` 下可直接点击 `打开提词器`（`⌘⏎`）开台，AI 整理（`整理朗读稿`）为可选路径，候选稿（`.prepared`）采用整篇连续文档流整体阅稿确认，不恢复逐句审阅。
5. **窄窗口与读屏无障碍兼顾**：主控按钮文案控制在精炼字数内并配合 `.lineLimit(1)`；为纯图标按钮、隐藏标签的分段控件（`Picker`）以及状态切换按钮补齐 `.accessibilityLabel`、`.accessibilityValue` 与 `.help`。

---

## 2. 模块一：语音助手（`AssistantView.swift` / `AssistantPresentation.swift`）文案清单

### 2.1 全量审查与优化对照表

| 出现位置 | 用户当前目标 | 现有文案 / 问题 | 建议文案 | 理由及关联状态 / 行为 |
| :--- | :--- | :--- | :--- | :--- |
| `AssistantView.swift:300, 306` 顶栏次级按钮（`.ready` / `.blocked`） | 调整当前语音助手的会话与设备设置 | `.ready` 写 `打开设置`，`.blocked` 写 `设置 · 会话`，同一入口在不同阶段名称不一致 | 统一为 `会话设置…`（保持 `.help("打开设置（语音助手 · 会话）")`） | 明确点击后打开「语音助手 · 会话」设置页，消除状态切换时的按钮名称跳变 |
| `AssistantView.swift:318` vs `1998` 会话中结束按钮（顶栏 vs 底部实时控制条） | 结束本轮实时语音对话并归档 | 顶栏写 `结束对话`，底部控制条 `liveChatEndButton` 仅写 `结束`，而旁侧紧挨着 `停止朗读`，容易混淆“结束当前语音播报”与“结束整场对话” | 底部控制条统一为 `结束对话`，补充 `.accessibilityLabel("结束当前对话")` | 与顶栏主动作同名，和旁侧 `停止朗读`（仅打断本句 TTS）形成清晰边界 |
| `AssistantView.swift:1941` vs `2501` 麦克风静音按钮（对话中 vs 右侧次级控制栏） | 临时关闭或恢复麦克风拾音 | `liveChatMuteButton` 写 `静音` / `取消静音`，`controlsSecondaryRow` 写 `静音麦克风` / `取消静音`；缺少读屏状态值 | 统一为 `静音麦克风` / `取消静音`，补齐 `.accessibilityLabel(assistant.isMuted ? "取消静音麦克风" : "静音麦克风")` 与 `.accessibilityValue(assistant.isMuted ? "已静音" : "正在拾音")` | 避免用户误以为“静音”是关闭扬声器播报声音；读屏可直接播报当前拾音状态 |
| `AssistantView.swift:914, 917, 920` & `2563, 2566, 2569` & `3363, 3369` 音色选择菜单与检视器音色入口 | 在语音助手内快速克隆声音、设计声音或打开音色库 | 菜单带装饰 Emoji 且三种入口叫法不一：`🎙️ 录制专属声音（音色克隆）…` / `🎙️ 录音克隆…`、`✨ 创作新音色（音色创作）…` / `✨ 创作音色…`、`📚 打开音色库管理…` | 菜单统一为 `克隆新声音…`、`设计新声音…`、`管理音色库…`；检视器快捷按钮统一为 `克隆新声音…`、`设计新声音…`（配合原生 SF Symbols 图标） | 与有声书模块音色菜单术语对齐，去掉非原生 Emoji 前缀，窄面板下不截断 |
| `AssistantView.swift:2656-2659` 对话中角色徽章说明与切角色按钮 | 在对话进行中查看当前角色或切换角色 | 说明写 `按设计规范，中途更换风格会导致上下文认知混乱。`（暴露内部“按设计规范”行话）；按钮写 `结束当前对话并换角色` | 说明改为 `为保持对话上下文连贯，本轮对话中角色固定不变。`；按钮改为 `结束本轮并更换角色…` | 用面向用户的自然解释替代内部规范话术，保持先结束当前会话再切角色的安全行为 |
| `AssistantView.swift:2861` 右侧检视器分段切换 `Picker` | 在「准备/实况」「声音」「记忆」三个标签间切换 | `Picker("", selection: $inspectorTab)` 使用 `.labelsHidden()` 且无无障碍名称 | 补充 `.accessibilityLabel("语音助手辅助面板切换")` | 修复 VoiceOver 读屏下分段选择器无名称问题 |
| `AssistantView.swift:2929, 2931` 检视器对话中快捷操作按钮 | 在对话进行中切换播报音色或重开一轮换角色 | 按钮带装饰 Emoji：`🎨 换音色`、`🔄 新开一轮换角色` | 改为原生图标 `Label("切换音色", systemImage: "waveform.badge.magnifyingglass")` 与 `Label("新开对话并换角色", systemImage: "arrow.triangle.2.circlepath")` | 去除 Emoji 噪音，与 macOS 工具栏/检视器视觉风格统一 |
| `AssistantView.swift:2971` 检视器「音频链路」说明文案 | 了解当前语音对话的隐私与本机处理方式 | 写 `实时麦克风电平动态感应，音频 PCM 纯内存流转、绝不落盘；识别与合成均由 Apple Silicon 独立单元驱动。`（含 `PCM` 等底层编码术语） | 改为 `实时感应麦克风音量，原始音频仅在内存处理、不写盘；语音识别与合成均在本机完成。` | 保留“仅在内存、不落盘、本机处理”的完整隐私承诺，去除 `PCM` 等工程术语 |
| `AssistantView.swift:3592, 3595, 3717` 检视器「记忆」标签页标题与底栏 | 查看和管理跨会话保留的偏好记忆 | 写 `长期记忆资产`、`自动注入提示词上下文，下一轮起效`、`\(memories.count) 条记忆资产`（含“记忆资产”“注入提示词上下文”等内部术语） | 改为 `长期记忆`、`自动带入后续对话，下一轮生效`、`已保存 \(memories.count) 条记忆` | 让普通用户直观理解记忆的作用时机，不暴露 Prompt 注入概念 |
| `AssistantView.swift:4464` 麦克风输入电平测试弹窗 (`InputLevelSheet`) 底部按钮 | 测完麦克风输入电平后关闭弹窗 | 按钮写 `完成`，而该弹窗仅用于实时查看与测试麦克风音量，无保存提交动作 | 改为 `关闭` | 与纯浏览/检测类 Sheet 的语义对齐 |

---

## 3. 模块二：会议助手（`MeetingView*.swift` / `InnerOSDrawer.swift`）文案清单

### 3.1 全量审查与优化对照表

| 出现位置 | 用户当前目标 | 现有文案 / 问题 | 建议文案 | 理由及关联状态 / 行为 |
| :--- | :--- | :--- | :--- | :--- |
| `MeetingView.swift:164` 顶栏待机状态次级按钮 | 进入会议录制相关的偏好设置 | 写 `查看设置`，过于笼统且与语音助手的设置入口命名不统一 | 改为 `会议设置…`（保持 `.help("打开设置（会议助手 · 录音与整理）")`） | 明确指向会议录音与整理设置 |
| `MeetingView.swift:198` & `MeetingViewInspector.swift:149` 录音异常中断后的恢复按钮 | 在设备断开或采样率变化导致录音中断后接着本场继续录 | 写 `继续这一段`，“这一段”指代不清 | 改为 `继续录制`（保持 `.help("重新连接音频来源并接着本场继续录制；中断期间未录到的内容无法补回")`） | 明确动作是重新连接音频源并继续本场会议录制 |
| `MeetingViewStatusBar.swift:74` 录制中顶部状态条暂停/恢复按钮 | 会议中途暂停录音或恢复录音 | 写 `暂停一下` / `继续录`（口语化过重，且未配备状态无障碍标签） | 改为 `暂停录制` / `继续录制`，补充 `.accessibilityLabel(meeting.isPaused ? "继续录制会议" : "暂停录制会议")` 与 `.accessibilityValue(meeting.isPaused ? "已暂停" : "正在录制")` | 录制控制是核心高风险操作，需使用清晰、稳重的动词短语 |
| `MeetingViewStatusBar.swift:95` 收尾处理非忙碌态标题 | 了解会议收尾中断或待继续处理的状态 | 写 `会议收尾需要处理`，含义模糊 | 改为 `会议收尾未完成` | 与下方 `重试纪要生成` / `仅保存转写并完成` 恢复动作直接呼应 |
| `MeetingViewSourceSetup.swift:165` vs `222` 准备态「声音来源」与「本场摘要」中的电平检测按钮 | 开会前检查麦克风是否有正常音量输入 | 左卡写 `测试输入电平`，右卡写 `检查输入电平`，指向同一个 `InputLevelSheet` 却用两套文案，且“电平”偏专业 | 两处统一为 `检查麦克风音量…`（`.help("查看当前麦克风的实时音量反应")`） | 消除同屏同功能按钮名称不一致，用“麦克风音量”替代专业术语“输入电平” |
| `MeetingViewSourceSetup.swift:214` 准备态「本场摘要」卡片的说话人区分状态行 | 确认开会前是否开启了多人发言区分 | 写 `SessionKVRow("谁在说话", preferences.meetingDiarizationEnabled ? "已开" : "关着")`，与 `MeetingViewInspector.swift:124` 的 `发言人区分`（`已开启` / `未开启`）不一致 | 统一为 `SessionKVRow("发言人区分", preferences.meetingDiarizationEnabled ? "已开启" : "未开启")` | 开会前与开会中检视器的属性名称和状态值保持完全一致 |
| `MeetingViewLiveTranscript.swift:281, 316` 实时转写行内说话人标签菜单 | 为某段发言标注姓名、重命名或合并说话人 | 已分配时菜单写 `标注与重命名…`，未分配时标签写 `未分配`、菜单写 `标注发言人…`，而顶栏按钮叫 `标注说话人` | 未分配标签改为 `未标说话人`；菜单项统一为 `标注说话人…`（未分配时）与 `重命名或合并说话人…`（已分配时） | 与顶栏 `标注说话人` 及弹窗内的重命名/合并能力精准对应 |
| `MeetingViewSpeakerLabeling.swift:32` 标注说话人弹窗顶部关闭按钮 | 改名或合并说话人（实时生效）后关闭弹窗 | 写 `完成`，而弹窗内每次点击 `改名` / `合并` 已即时生效，右上角按钮仅关闭窗口 | 改为 `关闭` | 符合即时生效型管理弹窗的退出语义 |
| `MeetingViewPostMeeting.swift:14, 210` 会后工作台顶部分段切换与搜索清除按钮 | 在「智能纪要 / 对照转写 / 会中问答」间切换，或清空转写搜索词 | `Picker("", selection: $postTab)` 缺少 `.accessibilityLabel`；搜索框清空按钮（`xmark.circle.fill`）无 `.accessibilityLabel` 与 `.help` | 为 `Picker` 补充 `.accessibilityLabel("会后视图切换")`；为清空按钮补充 `.accessibilityLabel("清除转写筛选")` 与 `.help("清除转写筛选")` | 补齐会后复盘高频控件的读屏与悬停提示 |
| `MeetingViewInspector.swift:40-41, 156` 右侧检视器历史回看卡片与中断说明标题 | 回看历史会议时查看当场信息或返回当前会议；查看中断规则 | 历史回看卡片标题写 `这一场`、按钮写 `回到这一场`（两处“这一场”指代相反：前者指正在看的历史场次，后者指当前活跃场次！）；中断说明标题写 `四种断法` | 历史卡片标题改为 `历史会议信息`，返回按钮改为 `返回当前会议`；中断说明标题改为 `中断处理说明` | 彻底消除“这一场”在同一卡片中同时指代历史会议与当前会议的歧义 |
| `InnerOSDrawer.swift:186-187, 345` 会中私聊抽屉状态芯片与写入纪要挑选弹窗 | 查看会中提问的回答进度，或勾选特定句子写入纪要 | 状态芯片写 `在答…` / `没答出来`（过于随意）；挑选句子弹窗标题写 `写进纪要哪几句`（语序口语化） | 状态芯片改为 `正在回答…` / `未能生成回答`；弹窗标题改为 `选择要写进纪要的句子` | 保持会中辅助工具的专业感与清晰度 |

> **注**：`MeetingSourcePresentation.swift`（`正在录：麦克风 + N 个 App 的系统声音`、`已存下 N 句`）、`MeetingAxisProjection.swift`（`审阅：降级（N 条待核对）`）与 `MeetingOpenItems`（`未完成事项（共 N 条）`）已有专项单元测试覆盖且表达清晰，予以原样保留。

---

## 4. 模块三：AI 提词器（`Teleprompter*.swift`）文案清单

### 4.1 全量审查与优化对照表

| 出现位置 | 用户当前目标 | 现有文案 / 问题 | 建议文案 | 理由及关联状态 / 行为 |
| :--- | :--- | :--- | :--- | :--- |
| `TeleprompterView.swift:156, 292, 723, 728, 921, 975, 1134` 左侧栏、列表、右键菜单与删除确认中的文档称呼 | 管理、新建、切换和删除提词文稿 | 同一界面混用 `稿子`（`我的稿子`、`未命名稿子`、`确定删除这份稿子？`、`删除这份稿子…`）与 `稿件`（`未命名稿件`、`搜索稿件…`、`选择或新建一份稿件`、`复制稿件内容`） | 全部统一为 `稿件`：`我的稿件`、`未命名稿件`、`确定删除这份稿件？`、`删除这份稿件…` | 消除同屏术语分裂，与搜索框 `搜索稿件…` 及空状态文案一致 |
| `TeleprompterView.swift:279, 299, 415, 735, 981` 顶栏、空状态与左栏菜单中的导入入口 | 从本地文件导入文稿内容 | 顶栏写 `导入文件…`，左栏工具条与空状态写 `导入文本文件…` | 统一为 `导入文稿…`（保持 `.help("从本地文本或 Markdown 文件导入内容")`） | 突出导入对象是提词文稿，且在窄窗口工具栏下更紧凑 |
| `TeleprompterView.swift:223, 2422` 顶部状态丸与就绪横幅状态文案（`.prepared`） | 区分“AI 已生成候选稿但尚未确认采用”与“提词稿已就绪” | `.prepared` 状态芯片写 `整理好了`，容易让用户误以为已经替换生效，与 `.ready` 的 `提词稿已就绪` 界限不清 | `.prepared` 状态芯片改为 `候选稿待确认` | 准确提示用户当前处于候选稿整体阅稿确认阶段，需确认后才正式采用 |
| `TeleprompterView.swift:1573` & `2134` 候选稿整篇阅稿区标题与主确认按钮（`.prepared`） | 审阅 AI 整理出的整篇朗读候选稿并确认采用、直接打开提词器舞台 | 标题写 `口述字符稿`（内部实现概念直译，用户难以理解）；底部主动作按钮写 `用这份稿`（绑定了 `⌘⏎` 并会直接执行 `confirmPreparedAndLaunchStage()`，但按钮字面未体现“并开台”） | 标题改为 `AI 朗读候选稿`；底部主确认按钮改为 `确认采用并开台`（保持 `⌘⏎` 快捷键与 `.help("确认采用这份朗读稿并立即打开提词器舞台 (⌘⏎)")`） | 保持既有产品决定（原稿可直接 `打开提词器 ⌘⏎` 开台、AI `整理朗读稿` 为可选路径、候选稿整篇阅稿确认、不恢复逐句审阅），同时让主按钮准确表达“确认采用 + 立即开台”的组合结果 |
| `TeleprompterView.swift:1102-1145, 1182-1194` 文档更多操作菜单与目标时长预设下拉菜单 | 打开当前稿件更多操作，或从预设快速填入目标时长 | 两个纯图标 `Menu`（`ellipsis.circle` 与 `chevron.down`）缺少 `.accessibilityLabel`，且目标时长下拉菜单缺少 `.help` | 为文档菜单补齐 `.accessibilityLabel("更多稿件操作")` 与 `.help("更多稿件操作")`；为目标时长预设菜单补齐 `.accessibilityLabel("快速选择目标时长")` 与 `.help("选择常用目标时长")` | 修复读屏下纯图标菜单无名称问题 |
| `TeleprompterStageView.swift:1196, 1203, 1247` vs `TeleprompterView.swift:2332, 2393, 2402` 舞台外观设置弹窗（舞台内 vs 工作台内） | 调整提词器字号、行距、栏宽、镜像翻转与底栏显示 | 两个弹窗设置同一批 `AppPreferences` 属性，文案却不一致：舞台内写 `正文列宽` / `始终显示控制` / `显示计时与进度`，工作台写 `正文栏宽` / `常显底部控制栏` / `显示时钟与进度` / `提词器硬件水平镜像` | 两处统一为：`正文栏宽`、`常显底部控制栏`、`显示计时与进度`、`水平镜像翻转（分光镜）` | 保证工作台预设与舞台内实时调节的选项名称一一对应 |
| `TeleprompterTrialReadingSheet.swift:207, 326, 415, 424` 试读校准语速弹窗（语音自动校准 / 手动计时校准） | 通过试读校准每分钟朗读字数（CPM）并应用到当前稿件 | 1. 第 207 行提示写 `读完后按「读完了」`，但下方第 220 行实际按钮叫 `结束语音试读`（指引与按钮名不一致）；<br>2. 手动计时第 326 行重置按钮写 `放弃`（易误解为关闭整个弹窗）；<br>3. 第 415 行写 `采用这次试读`、第 424 行写 `采用此校准`（同功能两套文案） | 1. 提示改为 `读完后点击「结束语音试读」`；<br>2. 手动计时重置按钮改为 `重置本次计时`；<br>3. 底部确认按钮统一为 `采用校准语速` | 消除界面提示与实际按钮文字不符的缺陷，统一结果确认按钮 |
| `TeleprompterReadingAliasSheet.swift:269` 专名读音表弹窗底部按钮 | 添加或删除专名读音映射（即时生效）后关闭弹窗 | 底部按钮写 `完成`，而每条读音映射在点击 `添加` 或删除图标时已立即写入，底部按钮仅关闭弹窗 | 改为 `关闭` | 与即时生效型管理弹窗的退出语义一致 |

---

## 5. 可验证验收标准（Acceptance Criteria）

### 5.1 语音助手（AC-VA）
- [x] **AC-VA-1（开始/静音/结束与对话状态一致）**：顶栏与底部实时控制条的结束动作统一为 `结束对话`（与旁侧 `停止朗读` 明确区分），麦克风静音按钮统一为 `静音麦克风` / `取消静音` 且具备 `.accessibilityLabel` 与 `.accessibilityValue`；闲置/阻塞态顶栏设置入口统一为 `会话设置…`。（证据：`AssistantView.swift:300, 306, 1941-1949, 2000-2007, 2503-2508`）
- [x] **AC-VA-2（音色与角色入口去 Emoji 及术语平实化）**：音色菜单与检视器按钮去除 `🎙️`、`✨`、`📚`、`🎨`、`🔄`、`👋`、`💡` 等装饰 Emoji，统一为 `克隆新声音…`、`设计新声音…`、`管理音色库…`、`切换音色`、`新开对话并换角色`、`试听当前朗读音色`；对话中角色锁定提示去除 `按设计规范` 内部话术，改为 `为保持对话上下文连贯，本轮对话中角色固定不变。` 与 `结束本轮并更换角色…`。（证据：`AssistantView.swift:914-922, 1850-1865, 2565-2573, 2657-2661, 2931-2945, 3375-3387`）
- [x] **AC-VA-3（隐私链路与长期记忆去工程术语）**：音频链路说明去除 `PCM 纯内存流转` 等工程缩写，改为 `实时感应麦克风音量，原始音频仅在内存处理、不写盘；语音识别与合成均在本机完成。`；长期记忆面板去除 `记忆资产` 与 `自动注入提示词上下文`，改为 `长期记忆`、`自动带入后续对话，下一轮生效` 与 `已保存 \(memories.count) 条记忆`。（证据：`AssistantView.swift:2839, 2983, 3604-3607, 3729`）
- [x] **AC-VA-4（无障碍与辅助弹窗语义）**：右侧检视器分段 `Picker` 补齐 `.accessibilityLabel("语音助手辅助面板切换")`；麦克风检测按钮统一为 `检查麦克风音量…`；`InputLevelSheet` 关闭按钮由 `完成` 改为 `关闭`。（证据：`AssistantView.swift:2874, 2920, 4476`）

### 5.2 会议助手（AC-MT）
- [x] **AC-MT-1（录制控制与中断恢复文案清晰）**：录制状态栏暂停/继续按钮由 `暂停一下` / `继续录` 统一为 `暂停录制` / `继续录制` 并具备读屏标签与状态值；异常中断恢复按钮由 `继续这一段` 统一为 `继续录制`；待机顶栏设置按钮统一为 `会议设置…`；收尾非忙碌态标题更新为 `会议收尾未完成`。（证据：`MeetingViewStatusBar.swift:74-82, 97`、`MeetingView.swift:164, 198`、`MeetingViewInspector.swift:149`）
- [x] **AC-MT-2（音源准备与说话人标注术语统一）**：准备态两处麦克风检测按钮统一为 `检查麦克风音量…`；多人区分状态行统一为 `发言人区分`（`已开启` / `未开启`）；实时转写说话人芯片与菜单统一为 `未标说话人`、`标注说话人…`、`重命名或合并说话人…`；说话人管理弹窗关闭按钮改为 `关闭`。（证据：`MeetingViewSourceSetup.swift:165, 215, 223`、`MeetingViewLiveTranscript.swift:281, 316, 331`、`MeetingViewSpeakerLabeling.swift:32`）
- [x] **AC-MT-3（会后检视器与会中私聊消歧）**：右侧检视器历史回看卡片标题与返回按钮消除“这一场”自相矛盾指代，改为 `历史会议信息` 与 `返回当前会议`，中断说明标题改为 `中断处理说明`；会中私聊（`InnerOSDrawer`）回答状态改为 `正在回答…` / `未能生成回答`，挑句弹窗标题改为 `选择要写进纪要的句子`。（证据：`MeetingViewInspector.swift:40-41, 156`、`InnerOSDrawer.swift:186-187, 345`）
- [x] **AC-MT-4（会后视图无障碍补齐与既有测试契约保持）**：会后分段 `Picker` 与转写搜索清除按钮补齐 `.accessibilityLabel` 与 `.help`；`MeetingSourcePresentation`、`MeetingAxisProjection`、`MeetingOpenItems` 等既有测试断言字符串保持 100% 兼容。（证据：`MeetingViewPostMeeting.swift:21, 219-220`；`MeetingSourcePresentationTests` / `MeetingAxisProjectionTests` / `MeetingOpenItemsTests` 全部通过）

### 5.3 AI 提词器（AC-TP）
- [x] **AC-TP-1（稿件与导入命名统一，保留本地既有改动）**：在不回退、不覆盖工作树既有改动的条件下，将左栏、列表、右键菜单与删除确认中的 `稿子` 统一为 `稿件`（`我的稿件`、`未命名稿件`、`确定删除这份稿件？`、`删除这份稿件…`），导入入口统一为 `导入文稿…`。（证据：`TeleprompterView.swift:156, 279, 292, 299, 415, 723, 728, 735, 921, 975, 981, 1134`）
- [x] **AC-TP-2（保持原稿直开、AI 可选整理、候选稿整篇确认工作流）**：原稿在 `.draft` / `.ready` 下保持 `打开提词器`（`⌘⏎`）直接开台与 `整理朗读稿` 可选入口；`.prepared` 状态芯片明确为 `候选稿待确认`，整篇阅稿区标题由 `口述字符稿` 改为 `AI 朗读候选稿`，主确认按钮由 `用这份稿` 改为 `确认采用并开台`（`⌘⏎`），不恢复逐句审阅。（证据：`TeleprompterView.swift:223, 1577, 1644, 2138, 2427`）
- [x] **AC-TP-3（工作台与舞台外观设置对齐）**：工作台与舞台内的外观弹窗统一使用 `正文栏宽`、`常显底部控制栏`、`显示计时与进度`、`水平镜像翻转（分光镜）`。（证据：`TeleprompterView.swift:2336, 2388, 2397, 2406`、`TeleprompterStageView.swift:1196, 1203, 1210, 1247, 1251`）
- [x] **AC-TP-4（试读校准、专名读音表与纯图标菜单无障碍修复）**：修复 `TeleprompterTrialReadingSheet` 中“读完后按「读完了」”与实际按钮 `结束语音试读` 不一致的问题，统一确认按钮为 `采用校准语速`，手动计时重置按钮改为 `重置本次计时`；`TeleprompterReadingAliasSheet` 底部按钮改为 `关闭`；补齐文档菜单与目标时长预设菜单的 `.accessibilityLabel` 与 `.help`。（证据：`TeleprompterTrialReadingSheet.swift:207, 326, 415, 424`、`TeleprompterReadingAliasSheet.swift:269`、`TeleprompterView.swift:1145-1146, 1197-1198`）

### 5.4 确定性验证与合规（AC-VERIFY）
- [x] **AC-VERIFY-1（最小充分确定性验证通过）**：
  1. `python3 scripts/check_macos_test_target_coverage.py`：`macos-test-target-coverage: OK`（退出码 `0`）；
  2. `SpeechRailAppSupport` 增量编译（含 `TeleprompterStageView.swift`）：`INCREMENTAL_SUPPORT_BUILD_OK`（退出码 `0`）；
  3. 全部 12 个 App 层修改视图文件（`AssistantView.swift`、`MeetingView*.swift`、`InnerOSDrawer.swift`、`TeleprompterView.swift`、`TeleprompterTrialReadingSheet.swift`、`TeleprompterReadingAliasSheet.swift`）Swift 6 类型检查：`FAST_12_VIEWS_TYPECHECK_EXIT=0`（零错误）；
  4. 三模块确定性单元测试套件（`AssistantPresentationTests`、`AssistantComposerPolicyTests`、`AssistantTurnPolicyTests`、`MeetingSourcePresentationTests`、`MeetingAxisProjectionTests`、`MeetingOpenItemsTests`、`TeleprompterTimingPolicyTests`、`TeleprompterStageInteractionPolicyTests`、`TeleprompterVoiceAssistLifecycleTests`、`TeleprompterPreparationPipelineTests`）：`ALL_UNIT_TESTS_PASSED: 62/62`（退出码 `0`）。
