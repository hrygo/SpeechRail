# SpeechRail「会议助手」模块端到端体验优化：竞品调研、用户旅途、UI 盘点与落地验收方案

> **制定日期**: 2026-10-17
> **目标模块**: 会议助手（`MeetingView.swift`、`MeetingViewStatusBar.swift`、`MeetingViewSourceSetup.swift`、`MeetingViewLiveTranscript.swift`、`MeetingViewPostMeeting.swift`、`MeetingViewRecordLibrary.swift`、`MeetingViewInspector.swift`、`MeetingViewSpeakerLabeling.swift`、`SpeakerLabelingView.swift`、`InnerOSDrawer.swift`）
> **状态**: `completed`（调研、用户旅途、UI 盘点、代码改造与 144 项会议单测 + Swift 6 类型检查已全部验证通过）
> **红线约束**: 严格保留工作区所有既有与旁支改动，不顺带修改语音助手、AI 提词器或有声书模块；不得改变音频是否落盘（原始音频纯内存流转、绝不留存）、保存时机、权限要求、会议数据持久化或网络行为；不引入真实音频、云请求、模型下载或运行态变更。

---

## 1. 主流会议助手 / 会议转录竞品深度调研（核实日期：2026-10-17）

### 1.1 四款代表性竞品官方事实与观察记录

> **说明**：以下每条事实均标注官方来源链接、页面发布/更新时间（可得时）与核实日期（2026-10-17），并严格区分「官方事实（Official Fact）」「产品观察（Observation）」与「架构推断（Inference）」。

#### （1）Granola（macOS / Windows / iOS 无机器人 AI 会议笔记）
- **来源链接**：
  - [How transcription works - Granola Docs & Help Center](https://docs.granola.ai/help-center/taking-notes/transcription)（官方文档，2026 年在线版本，核实日期：2026-10-17）
  - [Security at Granola](https://www.granola.ai/security)（官方安全与隐私说明，© 2026 Granola, Inc.，核实日期：2026-10-17）
  - [When to Use AI Notetaking: A Guide for Your Team](https://docs.granola.ai/help-center/consent-security-privacy/getting-consent)（官方帮助中心，核实日期：2026-10-17）
- **官方事实（Official Facts）**：
  1. **会前准备与启动**：Granola 不向 Zoom/Teams/Meet 派驻会议机器人（Bot-free），也不会未经点击自动开始录音；仅在用户点击通知、打开已到点的日历会议笔记或点击右上角 `➕ New Note` 时启动采集。
  2. **音源与不存原始录音**：桌面端直接采集本机系统音频（System Audio）与麦克风；官方明确声明 *"Granola doesn't store the audio from meetings - it transcribes in real time on macOS/Windows... It only stores the transcript and any notes you provide from a call"*（不保存会议原始音频，仅保留转写文本与笔记）。但官方同时说明其本机音频采集的是系统混合输出流，无法按单个 App 隔离音频（播放音乐也会被混入）。
  3. **进行中转写与暂停/恢复**：底部显示绿色动态音量条表示正在收音；点击波形图标展开实时转写抽屉，支持 `Show/hide`、`Stop/Resume`（暂停/继续转写而不结束整场会议）、`Copy all`（复制全文）、点击单段 `Copy/delete chunks`（复制或删除单段）以及会中 `Search`（搜索转写内容）。
  4. **说话人识别**：在未启用会议软件参会者标签时，按音频通道区分 `Me`（麦克风，右侧绿底）与 `Them`（系统音频，左侧灰底），支持在笔记或对话中修正姓名。
  5. **停止、休眠中断与恢复续录**：用户可随时手动点击 `Stop`；系统进入睡眠（Sleep）或连续 15 分钟无音频时自动停止；会议结束并生成纪要后，用户仍可在同一篇笔记的转写面板点击 `Resume` 接着往同一场记录里续录并重新生成纪要。
- **观察与推断（Observation & Inference）**：
  - **观察**：Granola 将实时转写设为可随时查看、复制单句和搜索的轻量工作流，避免用户在会议中被冗长的设置表单打断。
  - **推断**：Granola 虽不落盘原始音频，但其转写依赖 Deepgram/AssemblyAI 等云端 API 且笔记存储在 AWS VPC；而 SpeechRail 的 ASR 在本机运行、SQLite 记录库完全保存在本机磁盘，并且支持按指定 App 抓取本机音频，在本地隐私边界与音源隔离度上比 Granola 更严格。

#### （2）MacWhisper（macOS 原生本地模型转录与会议录音，v12–v15）
- **来源链接**：
  - [MacWhisper Official Product Page](https://www.macwhisper.com/)（官方产品主页，© 2026 Good Snooze，核实日期：2026-10-17）
  - [Automatic Speaker Recognition in MacWhisper](https://docs.macwhisper.com/article/32-automatic-speaker-recognition-in-macwhisper)（官方支持文档，更新时间：2025-07-20，核实日期：2026-10-17）
- **官方事实（Official Facts）**：
  1. **会前准备与采集**：支持录制 Mac 麦克风及任意指定 App 的系统音频（`Capture and transcribe audio from any app on your Mac`），无需会议机器人加入。
  2. **本地隐私与模型支持**：支持使用 WhisperKit / Parakeet 等本机离线模型在 Mac 本地完成识别，也支持连接 Ollama / LM Studio 等本地大模型或自带 API Key 生成摘要与对话。
  3. **说话人分离与标注交互（MacWhisper 12+）**：识别完成后分配默认标签（`Speaker 1`, `Speaker 2`）；支持在侧栏直接点击改名（回车或失焦即保存）、右键点击说话人选择 `Merge Speaker To..`（合并两个被拆散的同一说话人）、输入名字时自动补全常用说话人（`⌘ + Return` 确认），以及悬停段落按数字键 `1/2/3` 快速改归属。
  4. **会后查找、编辑与导出**：内置关键词搜索、高亮复制、段落编辑，支持导出 `.srt`、`.vtt` 及结构化文本/文档。
- **观察与推断（Observation & Inference）**：
  - **观察**：MacWhisper 的说话人「点击即改名 + 一键合并到另一位 + 历史说话人建议」交互非常契合 macOS 原生效率习惯。
  - **推断**：MacWhisper 以「先录存音频文件、再离线转写」为主路径，会长期占用磁盘存储原始录音文件；SpeechRail 坚持「边听边转写、原始音频纯内存流转不落盘」，因此需要在会中与会后更清晰地向用户传达「已存下多少句文字、说话人改名只改归属列而不改动原始转写正文」。

#### （3）Krisp（macOS / Windows 无机器人 AI 会议助手）
- **来源链接**：
  - [AI Note Taker | Meeting Notes, Transcripts & Summaries - Krisp](https://krisp.ai/ai-note-taker/)（官方产品页，© 2026 Krisp Technologies, Inc.，核实日期：2026-10-17）
  - [Record your meetings with Krisp AI Note Taker](https://help.krisp.ai/hc/en-us/articles/30146816045980-Record-your-meetings-with-Krisp-AI-Note-Taker)（官方帮助中心，核实日期：2026-10-17）
- **官方事实（Official Facts）**：
  1. **会前音源选择**：通过系统级音频通路（无需插件或会议机器人）采集线上会议（Zoom / Meet / Teams）与线下会议音频。
  2. **会后纪要与行动项**：会后自动提炼结构化纪要（支持简短/详细格式）、讨论要点（Discussion points）与行动项（Action items），支持跨会议搜索、标签与项目归类，以及基于会议记录的 AI 问答。
- **观察与推断（Observation & Inference）**：
  - **观察**：Krisp 将「讨论要点 / 决议 / 待办行动项」与原始转写并列呈现，并提供基于本场/跨场上下文的 AI 问答。
  - **推断**：Krisp 需要登录云端账号管理工作区；SpeechRail 在本机通过 `MeetingKnowledgeLibraryView` 与 `InnerOSDrawer`（会中私聊）提供了本地跨会议检索、项目分类、未完成事项演进追踪与本场证据问答，完全无需云端账号体系。

#### （4）Otter.ai（云端实时会议转写、说话人标注与摘要）
- **来源链接**：
  - [Tagging speaker names in a conversation - Otter.ai Help](https://help.otter.ai/hc/en-us/articles/360048465453-Tagging-speaker-names-in-a-conversation)（官方帮助中心，更新时间：2026-04-01，核实日期：2026-10-17）
  - [How to Use AI to Summarize Transcripts | Otter.ai](https://otter.ai/blog/ai-to-summarize-transcripts)（官方指南，发布时间：2026-06-24，核实日期：2026-10-17）
  - [Transcription processing time FAQ - Otter.ai Help](https://help.otter.ai/hc/en-us/articles/360048322493-Transcription-processing-time-FAQ)（官方帮助中心，更新时间：2026-05-27，核实日期：2026-10-17）
- **官方事实（Official Facts）**：
  1. **会中与会后说话人标注**：支持在实时录制中或会后点击未知说话人手动标注姓名。
  2. **摘要与时间戳联动**：会后生成带主题章节、要点与行动项的摘要，点击摘要条目可对照原转写时间戳核对上下文；官方明确提醒 AI 摘要存在五大常见偏差（幻觉 Hallucination、丢失限定词 Dropping qualifiers、遗漏反对意见、张冠李戴负责人/日期、抹平条件细节），强烈建议在正式分发前对照原始转写复核。
  3. **导出与问答**：支持打开会话后导出摘要或转写文本，并通过 Otter AI Chat 针对单场或多场会议提问并附带说话人与时间戳引用。

---

### 1.2 四款竞品与 SpeechRail 交互取舍横向对比矩阵

| 流程维度 | Granola | MacWhisper (v12–15) | Krisp AI Note Taker | Otter.ai | **SpeechRail「会议助手」定位与取舍** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **会前准备与加入** | 手动点通知或 `New Note` 启动，无 Bot；系统音频全混流不可选单个 App | 选麦克风 + 指定 App 系统音频；无 Bot | 选麦克风/扬声器设备；无 Bot | 日历 Bot 自动入会或手动启动录音 | **默认勾选麦克风一键开会（`⌘⇧N`）**；可选展开勾选任意正在发声的本机 App 自动合流；无 Bot、不装虚拟声卡；会前即明确提示纪要模型是否就绪 |
| **录音授权与隐私边界** | 不存原始录音，但音频发往云端 ASR 且笔记存 AWS | 本地模型离线识别，但通常将原始录音文件保存在磁盘 | 云端账户同步录音与转写 | 云端保存录音、转写与声纹学习数据 | **原始音频纯内存流转、绝不落盘**；本机 ASR 实时转写，仅文字记录与纪要写入本机 SQLite 记录库 |
| **实时转写与跟随** | 底部波形入口展开转写流；支持复制全文、复制单段、搜索 | 录制后或实时转写列表；支持搜索与单段复制 | 实时转写流 + 会后结构化卡片 | 实时滚动转写流，离开底部可跳回最新 | **粘底实时转写流（`TranscriptFollowState`）**：上滚回看时新句子绝不抢滚动，底部浮现 `下面有 N 条新的 · 回到最新`；支持全文复制与单段右键复制 |
| **说话人区分与标注** | 默认仅分 `Me` / `Them`，或读会议软件参会者名 | WhisperKit 本地分离 `Speaker 1/2`；侧栏点按改名、右键合并 | 自动区分说话人并允许会后改名 | 会中/会后点按标签手动标注姓名 | **本机声纹区分 + 会中/会后双通道标注**：行内胶囊一键标记为「我」、改名或与他人在会中/会后无损合并（正文只读不改） |
| **暂停、恢复与异常中断** | 支持 `Stop/Resume` 暂停转写；系统休眠自动停；会后可 `Resume` | 支持暂停/继续录制 | 支持暂停/继续记录 | 支持暂停/继续录音 | **严格区分「静音麦克风」（本机音频照录）与「暂停录制」（整条上行暂停，前后句不误拼）**；四类中断（服务断开/系统睡眠/音源断开/意外退出）显式记录断点时间码并提供 `继续录制` 或 `结束并整理` |
| **会后整理、查找与导出** | 生成 AI 笔记；转写面板内搜索与复制 | 导出 `.srt`/`.vtt`/文本；关键词搜索；连接本地/云端 LLM 总结 | 自动摘要 + 待办提取 + 跨会议搜索 | 摘要与转写双页签；警告 AI 幻觉需对照转写复核；支持导出 | **多版本纪要 + 引用证据核对（`MA-21 审阅轴`）+ 纪要/文字记录双页签**：整理中即可 `先导出文字记录…`（仅导转写不等纪要），归档后支持复制/导出、关键词与说话人筛选、旧会议一键回看 |

---

## 2. 端到端用户旅途（User Journey Map）

| 阶段 | 用户目标 | 核心疑虑 | 界面触点 | 情绪与当前摩擦点 | 关键决策与 UX/UI 改进机会点 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **阶段 1：会前准备与权限** | 3 秒内确认收音来源并开始记录；线上会议想顺带录腾讯会议/Zoom 声音 | “会不会偷偷存录音占硬盘？”“线上会议对方说话能录进去吗？”“结束时能自动出纪要吗？” | 顶栏 `⌘⇧N` / `会议设置…`、首屏结论条 `开始会议`、`主题` 输入框、`音频拾音环境` 折叠组、右栏 `本次会议` 卡片 | **摩擦 1**：右栏 `本次会议` 未显示纪要大模型是否已配置，用户开完 1 小时会才发现没配模型出不了纪要；<br>**摩擦 2**：`音频来源` 卡片说明含“这条链路上分不出来”等内部管线黑话 | 1. 在会前右栏 `本次会议` 增加 **`纪要整理`** 状态行（`结束后自动生成` vs `未配置模型（仅存文字）`）；<br>2. 精炼 `音频来源` 说明文案；<br>3. 为 `主题` 行内 `开始` 按钮补齐无障碍标签与快捷键提示 |
| **阶段 2：开始会议与连接** | 按下 `开始会议` 后立即确认系统已进入收音状态 | “点开始后怎么还没字？是不是卡住了或没权限？” | 状态带（`正在准备…` → `正在录音`）、受阻横幅 `blockedCard`、实时记录区空状态 | **摩擦 3**：`MeetingViewLiveTranscript` 在 `.preparing`（正在连接）和 `.recording`（已连接等待第一句发言）及 `isPaused`（已暂停）下，空状态全都只显示同一句冷冰冰的 `这一场还没有说到能定稿的句子。`，新手分不清是“正在连接”还是“已暂停”还是“正在听” | 按真实状态分层展示空状态：<br>- `.preparing`：带 `ProgressView` 显示 `正在连接音频与识别服务，请稍候…`；<br>- `isPaused`：显示 `录制已暂停。点击上方「继续录制」恢复收音。`；<br>- `.recording`：显示 `正在聆听会议发言，定稿句子会实时显示在这里。` |
| **阶段 3：进行中阅读、跟随与标注说话人** | 边开会边看实时转写；回看前文时不丢失位置；顺手把 `说话人 A` 标成同事名字或「我」；复制关键句 | “我往上滚看刚才那句话，新出来的话会不会把我拽回底部？”“点了『复制全部文字』到底复制成功没有？” | `liveTranscript` 列表、粘底浮条 `下面有 N 条新的 · 回到最新`、表头 `复制全部文字` / `标注说话人`、行内说话人胶囊菜单、底部 `会中私聊（⌘⇧I）` | **摩擦 4**：点击表头 `复制全部文字` 后没有任何成功反馈（无图标变化、无回执文字），且 `lines` 为空时按钮仍可点；<br>**摩擦 5**：实时转写单行与会后转写单行不支持右键复制单句；<br>**摩擦 6**：`SpeakerLabelingView` 空提示仍写着“点击「未指定」”（而胶囊已改为「未标说话人」），合并建议写着内部词“服务端认为它可能是…” | 1. 为 `复制全部文字` 增加即时对勾回执（`已复制全文`）并在无记录时禁用；<br>2. 为实时转写行与会后转写行增加右键菜单 `复制这一句`（及带时间码复制）；<br>3. 修复 `SpeakerLabelingView` 中过期的「未指定」引导词与「服务端」内部术语 |
| **阶段 4：暂停 / 恢复 / 异常中断** | 中途接私人电话或茶歇时暂停录制；自己不说话时仅静音麦克风；睡眠/拔耳机中断后安全接回 | “静音麦克风和暂停录制有什么区别？会不会把对面声音也掐了？”“电脑合盖睡了一觉，前面录的还在吗？” | 顶栏 `静音麦克风`、状态带 `暂停录制 / 继续录制`、中断行 `XX:XX 起中断`、右栏 `录制中断` 卡片 | 现有状态机严格区分 `静音麦克风` 与 `暂停录制`，且四类中断都有明确说明，但当转写为空且处于暂停态时主区缺乏醒目提示 | 在实时转写空态与表头副标题同步反映暂停状态，保持中断卡片 `继续录制` 与 `结束并整理` 双出口 |
| **阶段 5：结束与保存 / 收尾恢复** | 结束会议，确保文字记录 100% 落库，并等待或跳过纪要生成 | “纪要生成很慢，我现在急着发文字记录怎么办？”“收尾中断时点导出，会不会导出一份带空纪要的残缺文件？” | 结束确认弹窗、整理中顶栏 `先导出文字记录…` / `停止整理`、收尾异常卡片 `导出已保存文字…`、保存恢复面板 `TranscriptSaveRecoveryPanel` | **摩擦 7（代码缺陷）**：`MeetingViewPostMeeting.swift:421` 的 `exportMenu` 硬编码了 `exportCurrentSession(includeMinutes: true)`，违背了其第 439 行注释“整理中那一颗叫『先导出转录』，此时纪要还没生成——`includeMinutes` 只有归档后才为真”的设计契约！ | 为 `exportMenu` 增加 `includeMinutes: Bool = true` 参数，在整理中（`先导出文字记录…`）与收尾未完成恢复卡片（`导出已保存文字…`）传入 `includeMinutes: false`，严格兑现“仅导出已存文字记录”的承诺 |
| **阶段 6：会后回看、搜索、核对与导出** | 查看结构化纪要（含证据核对提示）、切换看文字记录并按关键词/说话人搜索、在首页快速回看最近 8 场历史会议 | “卡片标题旁边那串 `8f3a1c90 · 12 段` 是什么乱码？”“在首页点开上一场历史会议后，为什么点顶部的『文字记录』页签切换不了？” | `postMeeting` 卡片（`纪要 / 文字记录` 分段、`复制全文`、搜索框）、右栏 `说话人` 与 `纪要版本`、历史回看视图 `reviewBody` | **摩擦 8（暴露内部 ID）**：`postDetail` 直接把 `sessionID.prefix(8)`（8 位内部 UUID 前缀）展示给用户；<br>**摩擦 9（交互断路 + 残留旧文案）**：从首页「会议记录库」点开历史会议（`reviewRecord != nil`）时，`postDetail` 和 `reviewBody` 仍残留 `点「回到这一场」回来`（与右栏 `返回当前会议` 不一致），且 `reviewBody` 忽略了顶部的 `postTab`（`纪要 / 文字记录`）切换，导致有纪要的历史会议无法切换到 `文字记录` 搜索和查看原句！ | 1. 去除 `postDetail` 中的内部 UUID 前缀，改为展示真实发言段数与说话人数（如 `共 12 段发言 · 3 位说话人`）；<br>2. 统一历史回看提示与按钮为 `正在查看历史会议` / `返回当前会议`；<br>3. 修复 `reviewBody` 使其完整响应 `postTab`（支持在历史回看中自由切换「纪要」与「文字记录」并使用关键词筛选），同时在 `postTab == .transcript` 时也在表头提供一键 `复制文字记录` 按钮 |
| **阶段 7：特殊人群与边界场景（新手/熟练/窄窗/键盘/VoiceOver）** | 新手零配置开会；熟练用户全键盘操作（`⌘⇧N` 开会、`⌘⇧.` 结束、`⌘⇧I` 私聊）；窄窗口下不挤压主内容；VoiceOver 完整读出每项控件 | 窄窗口下右栏是否自动收起？VoiceOver 下会中私聊输入框、历史问答行、转写筛选框是否可读？ | 响应式右栏收起（`syncInspectorWithLayoutContract`）、快捷键键帽、`InnerOSDrawer`、转写行无障碍属性 | **摩擦 10（无障碍缺口）**：`InnerOSDrawer` 提问输入框缺少 `.accessibilityLabel`，左侧提问历史行缺少选中态 `.accessibilityValue`；会后转写筛选框缺少 `.accessibilityLabel`；会后转写行缺少整体合并读屏标签 | 为 `InnerOSDrawer` 输入框与历史问答行、会后转写搜索框及转写行补齐 `.accessibilityLabel` 与 `.accessibilityValue` |

---

## 3. 会议助手全量 UI 盘点与问题分级清单

### 3.1 导航与页头动作（`MeetingView.swift:148-254`）
- **已核实状态**：
  - 历史回看态：`返回会议主页`（`arrow.uturn.backward`）
  - 待机无受阻态：键帽 `⌘⇧N` + `会议设置…`（`slider.horizontal.3`）
  - 录制中（`.recording`）：键帽 `⌘⇧.` + `静音麦克风` / `取消静音`（仅当勾选麦克风时显示）+ `结束会议`（触发 `confirmationDialog`）
  - 录制中断（`.interrupted`）：键帽 `⌘⇧.` + `打开数据目录` + `继续录制`
  - 纪要整理中（`minutes.isBusy`）：`先导出文字记录…` + `停止整理`
  - 已归档（`.archived`）：`开启新会议` + `导出…` + `重新生成纪要`
  - 共有尾部：`SessionPanelToggle`（待机态名 `本次会议`，其余态名 `会议信息`，窄窗口自动收起 `syncInspectorWithLayoutContract`）
- **发现问题与优先级**：
  - **[P0 功能/契约修复]** `MeetingView.swift:126` 与 `:218` 调用的 `exportMenu` 未区分 `includeMinutes: false`，导致整理中点「先导出文字记录…」仍会尝试读取纪要。

### 3.2 状态带与六轴投影（`MeetingViewStatusBar.swift`、`MeetingSourcePresentation.swift`、`MeetingAxisProjection.swift`）
- **已核实状态**：
  - 标题随相位切换：`还没有开始会议` / `这一场没有开始` / `正在准备…` / `正在录音` / `正在录音 · 麦克风已静音` / `已暂停` / `录制中断` / `正在整理会议…` / `会议收尾未完成` / `这一场已经结束`。
  - 右侧动作：录制中提供 `暂停录制` / `继续录制`（含 `.accessibilityLabel` 与 `.accessibilityValue`）。
  - 六条状态轴（`就绪 / 采集 / 识别 / 保存 / 索引 / 审阅`）按需渐进式披露异常或降级。
- **发现问题与优先级**：
  - 底层测试契约完备（`MeetingSourcePresentationTests`、`MeetingAxisProjectionTests` 覆盖），保持模型层字符串 100% 原样不动。

### 3.3 会前准备与音源设置（`MeetingViewSourceSetup.swift`、`MeetingViewRecordLibrary.swift`）
- **已核实状态**：
  - 首屏结论条 `直接开始就能记` + 主按钮 `开始会议`；
  - `主题` 单行输入框 + 行内 `开始 ⏎` 按钮；
  - `音频拾音环境（可选配置）` 折叠面板（含 `麦克风`、运行中 App 列表、`自动混音` 状态行、`检查麦克风音量…`、`刷新列表` 及 `来源不可用时` 引导卡）；
  - `会议记录库` 快捷卡（展示最近 8 场 + `打开会议知识库` / `查看全部 N 场会议`）；
  - 右栏 `本次会议` 卡片（`识别精度`、`音频来源`、`发言人区分`、`保存位置`）。
- **发现问题与优先级**：
  - **[P1 体验与信息架构优化]** 右栏 `本次会议` 缺少 **`纪要整理`** 预期状态行（用户会前无法得知当前是否已配置纪要大模型）；
  - **[P1 文案去黑话]** `sourcesCard` 头部说明含“哪一句出在哪一路，这条链路上分不出来，也就不猜”等内部实现口吻，需优化为清晰直白的多音源混音说明；
  - **[P2 无障碍与快捷键提示]** `titleField` 内联 `开始` 按钮补齐 `.accessibilityLabel("立即开始会议")`，首屏 `开始会议` 主按钮 `.help` 补齐 `（⌘⇧N）` 提示。

### 3.4 实时转写与说话人标注（`MeetingViewLiveTranscript.swift`、`MeetingViewSpeakerLabeling.swift`、`SpeakerLabelingView.swift`）
- **已核实状态**：
  - 表头：`实时记录` + 副标题 + `复制全部文字` + `标注说话人`；
  - 正文流：历史分页加载 `载入更早记录`、断点提示行、带时间码与说话人胶囊的 `liveLine`、流式识别中的 `partialLine`、离开底部时的浮条 `下面有 N 条新的 · 回到最新`、底部 `TranscriptRecoveryMaterialSection`。
- **发现问题与优先级**：
  - **[P1 状态反馈优化]** `liveTranscript` 空状态未区分 `.preparing`（正在连接）、`isPaused`（已暂停）与 `.recording`（正在聆听）；
  - **[P1 交互反馈补齐]** `复制全部文字` 点击后无成功回执，且在无内容时未禁用；
  - **[P1 高频效率操作]** 实时转写单行 `liveLine` 缺少右键上下文菜单（`复制这一句` / `复制这一句（含时间与说话人）`）；
  - **[P1 引导词与去内部术语]** `SpeakerLabelingView.swift:104, 126, 192` 存在三处不一致或内部术语：① 把「会议设置… → 发言人区分」写成「实时字幕 / 会议 → 说话人标签」；② 把行内「未标说话人」胶囊写成「未指定」；③ 把声纹合并建议写成「服务端认为它可能是…」。

### 3.5 会后整理、历史回看与导出（`MeetingViewPostMeeting.swift`、`MeetingViewInspector.swift`）
- **已核实状态**：
  - 表头：`纪要 / 文字记录` 分段切换 + `复制全文`（仅 `纪要` 页签显示）；
  - 筛选栏：切换到 `文字记录` 时显示关键词/说话人过滤框与命中段数统计；
  - 右栏：已归档时显示 `SpeakerLabelingPanel` + `纪要版本` 卡片；历史回看时显示 `历史会议信息` 卡片。
- **发现问题与优先级**：
  - **[P0 去除内部 ID 暴露]** `postDetail`（`MeetingViewPostMeeting.swift:64`）将 `\(id.prefix(8)) · \(count) 段`（内部 UUID 前 8 位）直接显示在卡片副标题，必须改为面向用户的 `共 \(count) 段发言`（及说话人数）；
  - **[P0 历史回看页签切换修复与文案统一]** `reviewBody`（`MeetingViewPostMeeting.swift:343-363`）在 `reviewRecord != nil` 时未响应 `postTab`（导致有纪要的历史会议点「文字记录」页签无效，且無法搜索文字记录），且第 61 行与第 350 行仍残留 `回到这一场`，需统一为 `返回当前会议` 并让 `reviewBody` 完整支持 `纪要 / 文字记录` 切换；
  - **[P1 会后文字记录复制与单行菜单]** 当 `postTab == .transcript` 且有转写内容时，表头也应提供一键复制按钮（`复制全文`），且每行支持右键复制单句；
  - **[P2 无障碍补齐]** 会后转写筛选框 `TextField` 补齐 `.accessibilityLabel("按关键词或说话人筛选文字记录")`。

### 3.6 会中私聊抽屉（`InnerOSDrawer.swift`）
- **已核实状态**：
  - 贴底可展开抽屉（`⌘⇧I`），左侧本场提问历史与输入框，右侧证据引用、回答正文、可直接念的措辞、限制说明及 `写进纪要` / `改选句子` / `撤回` 操作。
- **发现问题与优先级**：
  - **[P2 无障碍补齐]** 提问输入框 `TextField`（`:133`）补齐 `.accessibilityLabel("会中私聊提问输入框")`；左侧历史行 `historyRow`（`:156`）补齐 `.accessibilityValue(exchange.id == selectedExchangeID ? "已选中" : "未选中")`。

---

## 4. 设计方案、边界约束与风险控制

### 4.1 核心设计决策（契合本地单人、隐私优先产品边界）
1. **会前“零门槛开始 + 透明预期”**：保持默认勾选麦克风、一键 `开始会议`（`⌘⇧N`）的极简主路径；在右栏 `本次会议` 卡片补充 `纪要整理` 状态行，会前即透明告知结束时会自动生成纪要还是仅保存文字记录，绝不因未配大模型而阻断录音与实时转写。
2. **会中“诚实状态反馈 + 随手复制/标注”**：
   - 实时转写空态按 `.preparing`、`isPaused`、`.recording` 三种真实状态分别给出准确反馈；
   - 表头 `复制全部文字` 提供 2 秒 `已复制全文` 视觉回执，并为实时转写与会后转写的每一行提供右键菜单（`复制这一句`、`复制这一句（含时间与说话人）`），对齐 Granola 与 MacWhisper 的高频笔记流；
   - 说话人面板清除 `服务端`、`未指定` 等过期或内部词汇，显示名优先。
3. **会后“无内部 ID、全功能回看、严格兑现只导转写”**：
   - 将 `postDetail` 中的内部 Session UUID 前缀替换为 `共 N 段发言（· M 位说话人）`；
   - 修复 `exportMenu(includeMinutes:)`，确保整理中点击 `先导出文字记录…` 与收尾未完成点击 `导出已保存文字…` 时严格只导出已落库文字记录（`includeMinutes: false`）；
   - 修复首页快速回看历史会议（`reviewRecord`）时的 `纪要 / 文字记录` 页签切换与关键词搜索能力，并将返回出口文案统一为 `返回当前会议`。

### 4.2 风险控制与不变性承诺
- **音频不落盘与隐私不变**：不触碰 `AudioSourceCoordinator`、`MicrophoneCapture`、`CoreAudioTapCapture` 的内存流转策略，原始音频依然绝不写入磁盘。
- **状态机与持久化契约不变**：不修改 `MeetingSession`、`SessionCoordinator`、`SessionStore` 的状态机转移、SQLite 表结构或落库时机；保留 `MeetingSourcePresentation`、`MeetingAxisProjection`、`TranscriptFollowState` 的全部公开属性与既有单测契约。

---

## 5. 可验证验收标准（Acceptance Criteria）

- [x] **AC-MA-1（竞品调研与用户旅途完整性）**：方案文档包含至少 4 个主流竞品（Granola、MacWhisper、Krisp、Otter.ai）的官方来源链接、页面/版本时间与核实日期（2026-10-17），明确区分官方事实、观察与推断，并完成 7 阶段端到端用户旅途（含新手/熟练、窄窗/键盘/VoiceOver）与全量 UI 盘点。（证据：本方案 §1～§3）
- [x] **AC-MA-2（会前准备透明度与音源说明优化）**：`MeetingViewSourceSetup.swift` 右栏 `本次会议` 卡片新增 `纪要整理` 状态行（区分 `结束后自动生成` 与 `未配置模型（仅存文字）`）；`音频来源` 卡片说明去除“这条链路上分不出来”等内部管线表述；`开始会议` 主按钮与主题行内 `开始` 按钮补齐快捷键提示与 `.accessibilityLabel("立即开始会议")`。（证据：`MeetingViewSourceSetup.swift:59, 124, 214, 297`）
- [x] **AC-MA-3（会中实时转写状态分层、复制回执与单句复制）**：`MeetingViewLiveTranscript.swift` 空态按 `.preparing`（`正在连接音频与识别服务，请稍候…`）、`isPaused`（`录制已暂停。点击上方「继续录制」恢复收音。`）与 `.recording`（`正在聆听会议发言，识别出的句子会实时显示在这里。`）分层呈现；表头 `复制全部文字` 在无记录时禁用、点击成功后显示 `已复制全文` 回执；转写行支持右键菜单复制单句文本及带时间码/说话人文本。（证据：`MeetingViewLiveTranscript.swift:23-41, 65-67, 279-316`）
- [x] **AC-MA-4（说话人标注面板术语对齐与去内部化）**：`SpeakerLabelingView.swift` 修复过期的 `点击「未指定」` 引导为 `点击「未标说话人」`，将设置路径统一为 `「会议设置…」中开启「发言人区分」`，并将合并建议中的 `服务端认为它可能是…` 改为面向用户的 `声纹相近，可能与 … 是同一人`。（证据：`SpeakerLabelingView.swift:104, 126, 192`）
- [x] **AC-MA-5（会后去内部 UUID、历史回看双页签打通与导出契约修复）**：`MeetingViewPostMeeting.swift` 去除 `postDetail` 中的 8 位内部 Session ID 前缀（改为展示发言段数与说话人数）；统一历史回看提示与按钮为 `返回当前会议`，并支持在历史回看中自由切换 `纪要 / 文字记录` 页签及使用关键词筛选；`postTab == .transcript` 时表头同样支持一键 `复制全文`；修复 `exportMenu(includeMinutes:)` 使整理中 `先导出文字记录…` 与收尾恢复 `导出已保存文字…` 严格传入 `includeMinutes: false`。（证据：`MeetingView.swift:126, 218`、`MeetingViewPostMeeting.swift:23-51, 74-85, 369-415, 471-479`）
- [x] **AC-MA-6（会后筛选与会中私聊无障碍补齐）**：为 `MeetingViewPostMeeting.swift` 转写筛选输入框与转写行、以及 `InnerOSDrawer.swift` 提问输入框与左侧提问历史行补齐 `.accessibilityLabel` 与 `.accessibilityValue`。（证据：`MeetingViewPostMeeting.swift:229, 353-354`、`InnerOSDrawer.swift:136, 182`）
- [x] **AC-MA-7（确定性验证与回归测试全量通过）**：
  1. `python3 scripts/check_macos_test_target_coverage.py`：`macos-test-target-coverage: OK`（退出码 `0`）；
  2. 会议助手全部 10 个视图文件（`MeetingView.swift`、`MeetingViewStatusBar.swift`、`MeetingViewSourceSetup.swift`、`MeetingViewLiveTranscript.swift`、`MeetingViewSpeakerLabeling.swift`、`MeetingViewPostMeeting.swift`、`MeetingViewInspector.swift`、`MeetingViewRecordLibrary.swift`、`SpeakerLabelingView.swift`、`InnerOSDrawer.swift`）Swift 6 类型检查：`SWIFT6_MEETING_VIEWS_TYPECHECK_EXIT=0`（耗时 `1.08s`，零错误）；
  3. 会议助手 10 个确定性单元测试套件（`MeetingSourcePresentationTests`、`MeetingAxisProjectionTests`、`MeetingOpenItemsTests`、`MeetingAcousticTimingTests`、`MeetingActionLifecycleTests`、`MeetingBackupRestoreTests`、`MeetingCrossMeetingTests`、`InnerOSSupplementTests`、`MinutesReviewModelTests`、`TranscriptFollowStateTests`）：`MEETING_UNIT_TESTS_PASSED: 144/144`（退出码 `0`）。
