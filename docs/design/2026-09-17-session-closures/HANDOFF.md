# SpeechRail · 会话闭环稿 · 设计交付交接包

**最近一次改动：第九轮（2026-09-18）**——「产品经理面向用户旅程的 UI/UX 优化」：
1. 归一化目录列宽度至 `SESSION_LIST_W = 280`（会议 / 记录库 / 助手 / 文档全部收敛至 280pt，搜索框 248 / 折行 196 / 脚注 248 一并对齐，消除切页中栏抖动，结清 D10 / 未决项 1 & 2）；
2. 补齐 J0 首次使用独立空态引导板 `会话 · 首次使用 · 空态引导（三能力起点）` 及 1:1 深色克隆，板数 57 → 59（结清未决项 4 与 G6 缺口）；
3. 非主框体清单中目录列收起规范正式晋升为 `Ready`（`⌘⌥S` / 系统内侧栏规范，按屏记忆）。
离线门禁全过，**Figma 尚未重跑**（重跑插件需当次授权）：现在 Figma 里仍是 53 块（12:38 那一版），`main.js` 已经是 59 块。规范位置见 `SESSIONS-SPEC.md` §19。

生成时间：2026-09-18。
本次轨道：**B（代理 / 自定义 provider）**——本会话可用工具里没有 `mcp__codex_apps__figma_*`，
也没有 `tool_search` 出口，所以写稿只能走「生成器 + Figma 桌面版」（判定时间 2026-09-17 22:00；
沿用 2026-09-17 20:05 的同一条判定）。

## 权威来源

| 层 | 位置 | 说明 |
|---|---|---|
| 稿的源码 | `../2026-09-15-macos-uiux-redesign/figma-kit/main.js`（`build-closures.js` 合成 `code.js`） | 改稿改这里，不在 Figma 里手改 |
| 稿的产物 | 新 Figma 文件（URL `figma.com/design/sAPdzrT2zsxqLtJhUx4iVC/…`，桌面版标签名被用户改为 **`Sona2Speech`**），页 `01 闭环`。**Figma 里是 53 块**（2026-09-18 12:38 实跑那一版）；**生成器已经是 59 块**（第九轮 +2 板：J0 空态引导浅色 + 深色克隆），等下一次实跑对齐 | 插件包在 `~/Downloads/SpeechRail-closure-kit/`（`code.js` md5 `05fd71d3fbf5392cedeee8a4fd9f147d`，352,564 字节，2026-09-18 第九轮版） |

## 第九轮 delta：产品经理面向用户旅程的 UI/UX 优化（2026-09-18）

| # | 优化项 | 旅程触点 | 代码落点 |
|---|---|---|---|
| 1 | **目录列宽度归一化至 280pt**：消除切页中栏抖动（会议 260 / 字幕 240 / 助手 232 / 文档 272 全部统领至 280pt） | J1/J2/J3 记录库与文档阅读旅程 | `main.js:82` 声明 `SESSION_LIST_W = 280`，`screenCaptions`、`screenClosureAssistantClosed`、`screenDeveloperDocs` 统一切换，搜索框（248pt）、折行（196pt）、页脚（248pt）同心对齐 |
| 2 | **补齐 J0 首次使用独立空态引导画板**：三能力起手入口与本地安全声明（音频不留存、SQLite 长期资产） | J0 首次使用旅程（结清 G6 与未决项 4） | 新增 `screenClosureFirstRunEmpty` 函数与 `sessionFirstRun` 画板注册，带 1:1 深色克隆，板数 57 → 59 |
| 3 | **目录列收起规范提升为 Ready**：内侧栏支持通过 `⌘⌥S` / 分隔线收起并按屏记忆 | 非主框体规范与阅读专注旅程 | `closurePanelRulesBoard` 清单第 6 项升级为 `Ready` |
| 4 | **旅程对账与连线全闭环**：`CLOSURE_JOURNEY` 补充第 6 项「首次启动 · 空态引导」 | 闭环总览与原型连线 | 原型连线 222 → 233，声明连线源 48 → 52 全部 100% 解析 |

离线门禁实测（第九轮）：
- `node --check main.js`: OK
- `node audit.js`: `audit: clean`
- `node smoke.js closures`: 59 板 / 29 深色 / 233 连线 / 48 闭环屏动作无重复 / SMOKE OK
- `node smoke.js full`: 48 板 / 478 连线 / 21 深色 / SMOKE OK
- `node check-links.js closures`: 52 条声明连线源全解析通过


## 第八轮 delta：非主框体都要能收起（2026-09-18）

用户原话：「语音助手，『本次对话』面板需要可收起，举一反三，其他非主框体，也通用要求。」
**规范位置是 [`SESSIONS-SPEC.md §18`](../2026-09-17-live-sessions/SESSIONS-SPEC.md)**——
定义、六条判据、清单、两条边界、未验证项都在那里；这一节只记代码落点与证据。

关键判断：这**不是新发明**。项目里已经有这条规则的先例——应用侧 `PageActionButton(systemImage:
"sidebar.right")` 落在 `PageScaffold` 的 `trailing` 槽（内容列首行尾端），由 REDESIGN-SPEC §11.6
第六十二轮的四档窗口离屏实测选定（工具栏里每件动作的落点由系统分配，锚不住面板分界线）。
所以这一轮做的是**把已有先例推广到会话三屏**，并在稿上把它写成可逐条对照的规则。

| # | 改法 | 代码落点 |
|---|---|---|
| 1 | 新增统一构件 `sideToggle(row, panelName)`（内容列首行尾端一枚 `sidebar.right` 图标按钮，28pt，复用 `Control.iconButton`，不新增数值 token） | `main.js` `pageHead` 之后；新图标 `sidebar-right` 写进 `icons.js`（Lucide `panel-right` 几何，图标数 44 → 45） |
| 2 | 16 块带右栏的会话画板全部挂上它：助手 7（未开始 / 对话中 / 未配置模型 / 实时对讲 / 换音色 / 记忆 / 记录库）、会议 7（空态 / 录制中 / 整理中 / 内心 OS / 中断 / 已归档 / 会话占用）、字幕 2（未开始、刚结束） | 12 个 `pageHead` 调用点；会议页 5 块经 `meetingShell` 一处声明（`o.sideName` 区分「会议信息 / 音频来源」） |
| 3 | 新增 `语音助手 · 对话页 · 对话中（本次对话收起）`：**收起态是同一屏的另一个状态**，不是另画一屏——`screenAssistant(d, { collapsed: true })` 不建右栏、对话行按新宽度（760 → 1128）重排，状态带与结论条原地不动 | `screenClosureAssistantCollapsed` |
| 4 | 新增 `非主框体 · 收起规则（通用）`：左边六条判据、右边 7 项清单（含「下一轮」与「不在这一版」两类），底部两条边界 + 两个跳转 | `closurePanelRulesBoard` |
| 5 | 总览「旅程还会走到这里」加第 5 行（面板收起），四种情况 → 五种 | `CLOSURE_JOURNEY` + `buildClosureJourneyNotes` |

离线门禁（2026-09-18 第八轮实测）：

| 门禁 | 结果 |
|---|---|
| `node --check main.js` / `icons.js` | 通过 |
| `node audit.js` | `audit: clean`（颜色 23 / 图标 41 / 文本样式 11 引用全解析；新图标 `sidebar-right` 已解析） |
| `node smoke.js closures` | **57 板** / 28 深色 / 222 连线 / SMOKE OK（46 块闭环屏动作无重复） |
| `node smoke.js full` | 48 板 / 478 连线 / 21 深色不变（共用的 5 块屏内容变了，结构不变） |
| `node check-links.js closures` | **48** 条声明连线源全部解析（+3：收起后的对话页 / 回到对话中 / 结束对话） |

**仍未实跑**：`smoke.js` 不检查几何。这一轮动了 16 块画板的首行（各加一枚按钮）与页骨架，
行宽够不够只是算术推断（首行 = 标题列 ≤780 + 动作区 ≤350 ≤ 内容列 1152），要用一次实跑确认
`root / inner overflow` 仍是 0。
| 全量稿（未动） | 另一份 Figma 文件 key `x5Ke0tKe9adeov4NG5baxP`，48 板；同名生成器的 `full` 范围 | 本次改动对它零影响（`smoke.js full` 仍是 48 板 / 478 连线） |
| 产品与逐面规格 | `../2026-09-17-live-sessions/SESSIONS-SPEC.md`（本包补充「记录是资产」「状态演进」「端到端旅程」三条判据） | §4 P8 / §9 / §6.5 / §13-D1 已按用户裁决同步为 SQLite；§16 是第四轮新增的旅程层口径，§15.6 是 schema 的增量 R1 |
| 旅程正文 | `../2026-09-17-live-sessions/SESSIONS-SPEC.md` §16.2.1–§16.2.6 | **方案正文**（第六轮并入）：三条主旅程逐步表 + J0 + X1–X4 + 覆盖对账 |
| 旅程对账与判据 | [`USER-JOURNEYS.md`](USER-JOURNEYS.md) | 角色与情境、缺口表 G1–G9、可测判据、逐轮复核记录；步骤表在这里是副本（同一次改） |
| 视觉语言 | `../2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md` §5 | 本稿未新增 token |
| 运行态事实 | `macos/SpeechRailApp/**` | **本轮未改**（见「未执行项」） |

## 第七轮 delta：产品经理 / 全新用户双视角审查（2026-09-18，已实跑）

用户：「再次从一个产品经理视觉，一个全新用户视觉，审查设计稿」→「执行优化」。十处发现全部改在
生成器里；规范位置 [`SESSIONS-SPEC §17`](../2026-09-17-live-sessions/SESSIONS-SPEC.md)，逐条复核
[`USER-JOURNEYS.md §13`](USER-JOURNEYS.md)。**这一轮已在 Figma 里重跑**（2026-09-18 12:38，用户当次
授权）——稿不再停在 07:36 的第五轮版，生成器、产物包、Figma 文档三者同源。

| # | 发现 | 代码落点 |
|---|---|---|
| 1 | 三条能力互不指路（用户可见文案里「该用哪个」命中 0 处） | `buildShell`：`ROUTE_GROUPS` 循环里给「会话」分组加一行常驻定位语（`groupNote`，Caption / `text/tertiary`） |
| 2 | 同一动作一屏画两遍（审查时 7 处；离线核对又查出 2 处） | `screenClosureAssistantReady` / `CaptionsIdle` / `MeetingSources`：结论条 `actions` 去掉重复主动作；`meetingInterrupted` / `assistantMemory` / `assistantVoice`：删掉右栏里与页头、状态带重复的动作对；`assistantClosed`、`CaptionsSaved`：结论条/检查器里的「复制全文」只留记录卡页脚那一处；`screenAssistant`：状态带里的「静音麦克风」删掉（只留合成器那一行），右栏「新开一轮以换人设」降为次要按钮 |
| 3 | 四套叫法指向同一批资产 | 全会话屏：`记录窗` → `记录库`；`会话记录` → `对话记录`；`本次会话` → `本次对话 / 本次会议 / 本次字幕`；`CLOSURE_LANES` / `CLOSURE_STATES` / `CLOSURE_FIXED_VARIABLE` 与 3 块画板标题同步 |
| 4 | 首次启动未定义 | `screenClosureCaptionsIdle`：`打开上一次记录` → `打开记录库`（首次也有意义）；说明里补「记录库空着的时候，这里只有『开始字幕』」 |
| 5 | 空态信息密度过高 | `screenClosureMeetingSources`：移出「为什么按 App 抓，而不是抓整机」整段，压成结论条里的一句「按 App 抓不需要装虚拟声卡」；字幕未开始板的 4 行检查项合成 3 行 |
| 6 | 规格语言进界面 | `prompt` / `系统提示词` / `Bundle ID` / `服务端 VAD` / `首个 PCM` / `EOF 屏障` / `全双工` / `AEC` / `tap` / `preset` / `数据库` 逐处改写（清单见 §16.8） |
| 7 | 实现细节当解释 | 「已经写进数据库」「问答与转录分开存」「记忆与对话分开存」改成用户关心的事：会不会丢、能不能搜、导出是什么 |
| 8 | 先讲限制再讲能力 | `screenClosureAssistantReady`：结论条改「现在就能开始」；检查器里「为什么人设不能中途换」整段移出（限制只在对比板与真去改人设时出现） |
| 9 | 打字输入入口不可发现 | 未开始板页头副标题 + 「本次对话」检查器各加一行「语音或打字」 |
| 10 | 「分人」是生造词 | 用户可见处统一为「说话人标签 / 标出说话人」；`分人` 只留规格与代码 |

新增离线门禁 `figma-kit/check-links.js`：闭环稿的连线按文案找回源控件，改名会**静默**少一条连线
（报告里只体现为 attempts 变小），所以改名之后必须显式核对一遍。本轮 45 条声明连线全部解析通过。

离线门禁（2026-09-18，第七轮跑完的实测值）与产物：

| 门禁 | 结果 |
|---|---|
| `node --check main.js` | 通过 |
| `node audit.js` | `audit: clean`（23 颜色 / 40 图标 / 11 文本样式引用全部解析；未用图标 4 个） |
| `node smoke.js full` | 48 板 / 478 连线 / 21 深色，结构断言全过（**与第六轮一致，说明共用的全量稿没被改动波及**） |
| `node smoke.js closures` | 53 板 / 210 连线 / 26 深色，结构断言全过（含本轮新增的「42 块闭环屏的动作没有重复」） |
| `node check-links.js closures` | 45 条声明连线源全部解析到 |
| 产物 | `~/Downloads/SpeechRail-closure-kit/code.js` md5 `c72bf2e9b8077a8ba98a21366e649861`；`~/Downloads/SpeechRail-figma-kit/code.js` md5 `f680c5e41d539294738f4fc4d6f73a06`（341,457 / 341,422 字符） |

**几何**：两个 smoke 都不检查几何（替身没有布局引擎），所以这一项只能由实跑证明——2026-09-18 12:38
在 `Sona2Speech` 里跑到 `root overflow=0 · inner overflow=0`，见下面「Figma 实跑报告（2026-09-18
12:38）」。本轮对结论条、检查器、状态带的增删都按「净减少行数」设计（去重 7 处、瘦身 2 处、
新增 1 行检查器 kv 由删掉的 3 行说明抵掉），这一意图在真实布局里成立。

## Figma 实跑报告（2026-09-18 12:38 · 第七轮源码的首次实跑 · 已收敛）

此前稿停在 07:36 的第五轮版（第七轮只改了生成器）。用户 2026-09-18 当次授权「在 `Sona2Speech`
这里跑」后按 SOP 执行，全程无障碍索引驱动、不点画布：

1. 离线门禁先跑一遍（`node --check` / `audit.js` / `check-links.js` / `smoke.js closures`），全过。
2. `node build-closures.js` 重出产物包 → md5 `c72bf2e9b8077a8ba98a21366e649861`、411,924 字节，
   **与 12:27 那一版逐字节相同**（同源可复现）。
3. 目标文件按 **file key `sAPdzrT2zsxqLtJhUx4iVC`** 核对（标签名 `Sona2Speech`），不按标签名猜——
   上一轮就是按标签名匹配、错点进了 `SpeechRail` 标签。
4. `Plugins → Development → Hot reload plugin` → 运行 `SpeechRail Closure Kit`（报告面板在触发后
   **16 秒内**出现）。

| 报告行 | 2026-09-18 12:38（第七轮版） | 2026-09-18 07:36（第五轮版） |
|---|---|---|
| `AUDIT VERDICT` | `53 frames · all clean` | `53 frames · all clean` |
| `boards` / `dark boards` | 53 / 26 | 53 / 26 |
| `bind errors` / `export errors` | 0 / 0 | 0 / 0 |
| `stray top-level` | 0 | 0 |
| `root overflow` / `inner overflow` | 0 / 0 | 0 / 0 |
| `placeholder fill` | 0 | 0 |
| `prototype links` | 248/248 | 248/248 |
| `cjk runs` | `PingFang SC` | `PingFang SC` |

两条这一轮才有的结论：

1. **第七轮改动没有丢连线、也没有引入几何问题**：连线数与第五轮版同为 248（第七轮第 2 条删的是
   重复动作，没有吃掉声明连线），`root / inner overflow` 都是 0，改稿的两个风险点都排除。
2. **替身 `smoke.js` 的连线计数是低估的**：它报 210 条，真实 Figma 报 **248** 条，两次源码版本都是
   这个对应关系。所以连线总数以实跑报告为准；替身只用来判结构，语义层面看 `check-links.js`
   （45 条声明连线源全解析）。

目视：关掉报告面板后截图一张（34% 缩放）——总览与各泳道都有内容、中文无空白、无叠字、无占位灰；
Pages 面板仍是 1 页 `01 闭环`（`2 free pages left`）。

## 第五轮 delta：用户审查提出的 9 条（2026-09-18）

改动全在 `figma-kit/main.js`（+1 个图标进 `icons.js`），逐条对应如下。9 条的内容与判据见
[`README.md`](README.md) 的「第五轮」表，这里只记**改了什么代码**，便于以后按条目回查。

| # | 用户要求 | 代码落点 |
|---|---|---|
| 1 | 语音助手支持输入文字 | `screenAssistant`：底部 `controls` 由一行改两行（新 `compose` 行 + 原 `controlsRow`）；Inspector 的 kv 加 `输入：语音或打字` 与「打字提问时不朗读」说明 |
| 2 | 换音色与换人设深入分析、重新绘制 | 新增 `closureVoicePersonaBoard()`（7 行对比 + 时间线 + 为什么 + 两个出口）并登记为 `CLOSURE_BOARDS.voicePersona`（`full:` 类型）；`screenClosureAssistantVoice` 整块重画为「音色路径」（对话里显式给出口、右栏人设说明改用户语言）；`screenAssistant` 页头按钮改名 `音色与风格`、侧栏动作改 `换音色` + `新开一轮以换人设`，四条连线同步 |
| 3 | 旅程端到端闭环审查 | `USER-JOURNEYS.md` 新增第 12 节（逐条回旅程 + 新缺口 G7–G9 + 两处留给实现）；覆盖表同步 |
| 4 | 面向终端用户 | 全会话屏的用户可见文案：`SQLite` / `封存` / `落盘` / `元数据` / `水位` / `system prompt` / `前缀缓存` / `capability` / `recording` 逐处改写（机制留在代码注释与本包规格里） |
| 5 | 内心 OS 不完整 | `meetingOSPanel()`：左栏由「示例问题」改为**本场问答历史**（3 条 + 状态）+ 输入框 + 追问提示 |
| 6 | 会议布局重新构思 + OS 做成可展开可关闭的组件 | 新增 `meetingShell()` / `meetingOSBar()` / `meetingOSPanel()` / `meetingInfoSide()`；`screenClosureMeetingProcessing`、`screenClosureMeetingInnerOS` 改为骨架版；`screenMeetingRecording` / `screenMeetingMinutes` 用新骨架**替换原实现**（两稿共用），删掉闭环稿里那两份重复定义 |
| 7 | 说话人会中 / 会后人工标注 | `turnRow` 增加可选 `src`（来源标签）；`screenMeetingRecording` 转录表头加 `标注说话人`；`screenMeetingMinutes` 右栏改为说话人编辑面板（状态行 + 改名输入 + 既有名字 chip + 标记为「我」/ 合并 / 拆出 / 保存 + 纪要版本） |
| 8 | 配置 LLM 不提 oMLX、讲清 Responses API | `screenAssistantBlocked`（结论条 + 能力表行）、`closureSettingsBoard`（新增「接口」行 +「检查连接」第四种结论 +「对接要求」卡）、`CLOSURE_SPINE` 第 2 格、设置面板的「服务地址 / 连接」说明与页脚注、组件状态 `State=未配置` 的文案 |
| 9 | 没有看到字幕带的 UI | `buildFloatBoards()` 内新增 `浮层 · 字幕带 · 贴在画面上（在用时）`（画面 300pt + 带子）；`CANVAS_NAMES["12 会话浮层"]` 登记；`CLOSURE_BANDS` 登记 `bandOnScreen`；记录窗的 `打开字幕带` 改指它 |

顺带修掉的一处**静默失效**：新板的 `frame` 名与 `CLOSURE_BOARDS.title` 一开始不一致（一个带
「语音助手 · 」前缀、一个没有），而连线的落点是按 title 反查的——对不上就**静默不成线**，
`smoke.js` 仍报 `205/205` 全通。改名后连线数从 205 涨到 208，才是三条新连线真正接上的证据。
记在这里是因为这类错只有对比两次运行的**尝试数**才看得见。

## 生成器 delta（这一版相对 2026-09-17 20:36 那一次）

| # | 改动 | 判据来源 |
|---|---|---|
| 1 | 范围开关 `SPEECHRAIL_SCOPE`（默认 `"full"`，`build-closures.js` 声明 `"closures"`）；`PAGE_NAMES` / `PAGE_LAYOUT` / `SCREEN_GROUPS` 按范围分支 | 两份稿共用一个生成器，全量稿行为一字不变 |
| 2 | 新增闭环稿构件：`CLOSURE_BOARDS`(13) / `CLOSURE_BANDS`(4) / `CLOSURE_BAND_LINKS` / `CLOSURE_LANES` / `CLOSURE_SPINE` / `buildClosureOverview` / `buildClosureScreens` / `closureDarkVariants` | 按路径组织而不是按页面组织 |
| 3 | 新屏幕 `screenClosureCaptionsIdle` / `screenClosureCaptionsSaved` / `screenClosureMeetingProcessing` / `screenClosureAssistantClosed` / `closureSettingsBoard` / `closureMenuBoard` | 三条闭环各自的第 ①②④⑤ 步与共用脊柱 |
| 4 | **记录库改造**：三个产物页都是「列表（含搜索）+ 选中 + 详情 + 继续/重命名/导出/移除」；设置与空态文案改成本机 SQLite 库 + 备份方式 | 用户 2026-09-17：记录是长期资产，用 SQLite |
| 5 | **状态模型**：`CLOSURE_STATES`（3 条 × 4 态，每态写「这一态换掉什么」）+ `CLOSURE_FIXED_VARIABLE`（6 条固定/可变），落成总览页的「状态演进」与「改这一页之前」两段；13 块画板全部改名成「页 · 状态」 | 用户 2026-09-17：会改变一些页面设计的交互方式，现在的设计有些是一次性的 |
| 6 | **几何修复**：共用脊柱那一行是 **4 格**，宽度却按 3 格写成 490 → 第 4 格越界 444px（实测报告 `root overflow=4 · spine/3+444`）。改为 `CLOSURE_SPINE_W = 367`（367×4 + 12×3 = 1504）+ 格高 112 | 2026-09-17 22:00 实跑报告 |
| 7 | 状态胶囊格宽 96 → 116（`closureCheckRow` / `closureSettingsBoard`） | 2026-09-17 实跑：`inner overflow ▸ cell ▸ Status Pill +7R [103 in 96]` |
| 8 | **第三批五条能力**：新增 4 块画板 + 会议空态换成闭环专用屏（`screenClosureMeetingSources`），共 17 屏；泳道、状态演进、固定/可变三张表按下表改写 | 用户 2026-09-17 追加的 5 条需求（见 README 的「第三批需求」表） |
| 9 | 共用脊柱从 4 格加到 5 格（新增「分人 · 会议与字幕共用」），格宽 367 → 291、格高 112 → 140 | 第 3 条需求：会议与字幕共用一条链路 |
| 10 | 审计报告的结论区改成「一处一行」、并挪到计数行之前 | 面板文字在无障碍层按行截断，改之前 8 处问题只能读到 2 处；改之后 4 处全读到 |

## 第四轮 delta：端到端旅程（用户 2026-09-18）

用户要求「从用户故事旅程出发，补齐三个功能的端到端全流程」。做法是按**路径**重走一遍
（而不是按格子对）：8 条旅程逐格核对「这一步之后人去了哪、写进哪张表、失败退到哪」。
结论是**两处路径断了**，其余 6 条完全落在已有画板上——所以这一轮不是把稿画得更全，是补断点。

| # | 约束 / 裁决 | 改动 | 判据来源 |
|---|---|---|---|
| 20 | **端到端旅程层** | 新增 [`USER-JOURNEYS.md`](USER-JOURNEYS.md)：3 条主旅程 + J0 首次使用 + 4 条跨模块衔接，含覆盖表、缺口表（G1–G6）与可测判据 | 用户 2026-09-18：「进一步补充完善三个功能模块的端到端全流程，以用户故事旅程出发」 |
| 21 | **新增 2 块画板**（45 → 49 板；连线 178 → 205） | `语音助手 · 对话页 · 记忆（跨会话 · 下一轮生效）`（anchor `assistantMemory`）、`会议助手 · 会议页 · 录制中断（服务或来源断了）`（anchor `meetingInterrupted`）；两块都不挂来源连线——记忆与中断都不是点出来的，由总览那一节进入 | 缺口 G1 / G2 |
| 22 | **状态演进补到每页 5 态** | 助手 +`刚结束`（→ `assistantClosed`）、会议 +`会后`（→ `meetingMinutes`）、字幕 +`受阻`（→ `bandBlocked`）；`CLOSURE_STATE_W` 322 → **255**（255 × 5 + 168 + 12 × 5 = 1503 ≤ 1504 内容宽） | 三条闭环的终点原先不在表里：README 写着「未开始 → 进行中 → 刚结束 → 归档」，表里却没有最后那一态 |
| 23 | **总览新增一节**「旅程还会走到这里」 | `CLOSURE_JOURNEY`（4 行）+ `buildClosureJourneyNotes()`，前三行可点（中断 / 记忆 / 抢麦克风），第四行（移除与清空）标注「实现阶段按既有形状补」；`closureCheckRow` 增加可选 `nodeName`，`wirePrototype` 增加对应的连线圈 | 这四种不属于「一条闭环的五个阶段」，但按用户故事走一遍一定会遇到 |
| 24 | **规格补口径**（6 处） | `SESSIONS-SPEC.md`：§16.1–§16.8（旅程层、抢麦克风 X1、导出命名与检索、记忆规则、破坏性确认、中断四类断法）、§15.6 增量 R1（`session_interruption` + `session.end_reason`）、§13.2 的 D11/D12、§6.1「四种态」→「五种态」、§6.2 表加「录制中断」行、§7.1 加两行 | 这些原先没有说法，实现时一定会变成隐性约定 |

**没有新增颜色、没有新增图标、没有新增数值 token**：两块新板全部由既有构件拼成
（`pageHead` / `sessionStatusBar` / `conclusionBand` / `card` / `turnRow` / `kvRow` /
`segmented` / `closureCheckRow`），用到的图标（`bot`、`triangle-alert`、`play`、`ellipsis`）都在
原来那 43 个里。

## 第三轮 delta：D7 = 360、D2–D9 全部采纳（用户 2026-09-18）

**本轮只改了一个数值（列宽）和跟着它走的派生宽度、加了一行常量，其余是把裁决写进文档**——稿的结构没动。

| # | 约束 / 裁决 | 改动 | 判据来源 |
|---|---|---|---|
| 15 | **列宽归一：会话侧栏 = 360**（D7） | 稿侧新增 `const SESSION_SIDE_W = 360`（15 个引用点）与 `NUMBER_TOKENS` 的 `size/inspector`(360)；原来在用的 **320 / 420 / 300** 三处归一，依赖它的内宽同步收窄：`268 → 308`、内心 OS 卡里的 `340 / 360 / 380 → 300`、内层答案卡 `388 → 328`、音色行 `220 → 176`、音色库 Inspector 的描述行 `268 → SESSION_SIDE_W − 32`（= 328，原值正好是 300 列的内宽，收尾复核时发现的最后一处） | 用户 2026-09-18：「360」 |
| 16 | D2 / D3 / D5 / D6 按建议采纳 | 文档侧：`SESSIONS-SPEC.md` §13 结清 D1–D9、§12 的阶段 0 关闭、§15 由「草案 · 待裁决」改为「已采纳」；新开 **D10**（目录列 260 / 240 / 232 / 272 未归一，建议 280，不阻塞阶段 1/2） | 用户 2026-09-18：「采纳所有建议」 |
| 17 | D10 行补上**跟随列宽的那一串数值**（复核 D7 时的实测落点） | 搜索框 `228 / 208 / 200`（`main.js:3412 / :3606 / :4561`）、列表行副标题折行宽 `156 / 148`（`:3616 / :4572`，未传时回落 `200`，`meetingRow:2089`）、列表脚注 `208 / 200`（`:3623 / :4581`），都随目录列一起改 | 做 D10 的人不必再找一遍；`main.js:2089` 的 200 是**行内文本宽**不是列宽，本轮**不动** |
| 18 | 全量扫了一遍还剩哪些固定列宽写在视图里 | 只剩 `screenDiagnostics` 的详情列 `size(side, 340)`（`main.js:2994`）。**不算 D7 那类冲突**：应用侧这一列没有固定宽度声明（`PreflightDiagnosticsView.swift` 里没有 `inspectorColumnWidth`），340 是唯一一处说法；但同是 Inspector 角色却差 20pt，记进 §13.1 留 D10 一轮看齐到 360（会动已交付的 48 板，本轮不动） | 复核 D7 时顺带核实 |
| 19 | `figma-kit/README.md` 补一条生成器约定 | 「同一个视觉角色只允许一个数字」：会话侧栏现在只改 `main.js:81` 的 `SESSION_SIDE_W`；目录列（D10）与它关联的一串数值本轮不动，指向 §13.1 | 稿的源码是唯一入口，约定写在入口文档里才拦得住下一次裸值 |

```js
const SESSION_SIDE_W = 360;   // 会话三页的右栏唯一宽度（= Layout.inspectorColumnWidth）
```

原来散在 15 个调用点上的 320 / 420 / 300 三个值现在都引用它；`NUMBER_TOKENS` 里补了
`size/inspector`(360)，让这件事在 kit 的变量表里也有一条。

## 第二轮 delta：用户 2026-09-17 追加的两条约束

| # | 约束 | 改动 | 判据来源 |
|---|---|---|---|
| 11 | **新会话开启后不允许换人设**（避免大模型前缀缓存失效） | 新增屏幕 `screenClosureAssistantReady`（`语音助手 · 对话页 · 未开始（先定人设与音色）`）并登记为 `assistantReady`；`screenClosureAssistantVoice` 改为「人设已锁定」，人设区从三枚可点 chip 变成「锁 + 只读值 + 新开一轮的出口」；`CLOSURE_BOARDS` 的 `assistant` / `assistantDuplex` / `assistantClosed` / `assistantVoice` 四条连线与标题同步；`CLOSURE_LANES` 的助手①④格、`CLOSURE_STATES` 的助手①②④格、`CLOSURE_FIXED_VARIABLE` 的「可变 · 会话配置」一行同步改写；`paneSession`（共用设置面板）新增「语音助手」一组，`closureSettingsBoard` 新增一张说明卡 | 用户 2026-09-17；`SESSIONS-SPEC.md` §14.4 |
| 12 | **确保采用统一的设计 token** | 新增 `lock` 图标（`icons.js`，几何取自同一份 lucide）；**不新增颜色**；新板全部由既有构件（`pageHead` / `conclusionBand` / `closureCheckRow` / 既有卡片）拼成（唯一的数值 token 新增是第三轮的 `size/inspector`，见第 15 行——那不是新数字，是把已经在用的 360 声明出来） | 用户 2026-09-17；§11.1 |
| 13 | 审计误报（副产物） | `audit.js` 的文本样式扫描补一条 `style:` 字面量，修掉「已经在用的 `Caption Band / 大字` 被报成 unused」 | 本轮核查发现 |
| 14 | 共用屏 `screenAssistant` / `screenAssistantBlocked` 底部的 `免持 / 按住说话` 改成 `一问一答（外放） / 实时对讲（耳机）`，状态带标题同步 | 与 §6.1 的收口打架：规格说这一行只有一条对讲模式分段控件。顺带多一条闭环连线：`对话中` 上点「实时对讲（耳机）」直接进 `实时对讲（耳机 · 可打断）`（166 → 178 条） |
## 第六轮 delta：旅程并进方案正文（用户 2026-09-18）

用户：「用户旅程也需要落到方案里。」（下一条消息只补了一个词：`markdown`。）

原先的状态是：**旅程正文只存在于 `USER-JOURNEYS.md`**，而方案（`SESSIONS-SPEC.md`）的 §16 只钉
「这次复核新定下来的口径」，把读者引到旁边那个文件。于是照着方案编码的人，看不到
「这一步落在哪块板、写进哪张表、失败退到哪」——那正是端到端最需要的东西。

| 改动 | 位置 |
|---|---|
| 三条主旅程的逐步表（J1 / J2 / J3）并进方案正文 | `SESSIONS-SPEC.md` §16.2.1–§16.2.3 |
| J0 首次使用、X1–X4 四条衔接、覆盖对账表 | 同文件 §16.2.4–§16.2.6 |
| §16 开头改成「§16.2.x 是正文；`USER-JOURNEYS.md` 留角色 / 缺口 / 判据 / 复核」 | 同文件 §16 |
| 每个落地阶段「结束时应该能走通哪条旅程」 | 同文件 §12（新表：阶段 3 先通 J3、阶段 5 通 J1、阶段 6 通 J2） |
| 顺手补的一处口径 | J1 的 E4 多了一行「**打字**问一句」——它是第五轮 G7 补上的入口，原先只在缺口表里，没进步骤表 |
| 文档同步 | `SESSIONS-SPEC.md` v1.2.0 → **v1.3.0**；`USER-JOURNEYS.md` v1.1.0 → **v1.2.0**（标出规范位置、修正两处「未实跑」） |

**一处取舍要你知道**：步骤表的**规范位置在方案里**，`USER-JOURNEYS.md` 保留的是副本
（它让缺口表与验收判据有上下文）。两份同时存在就有漂移风险，所以两边都写明了
「改一处就要在同一次里改另一处」。如果更想要单一来源，可以把旅程文档里的表收成指针——说一声就改。

**稿本身零改动**：这一轮只动 markdown，`main.js`、`icons.js` 与 Figma 文件都没变，
所以没有重跑插件（末次实跑仍是 2026-09-18 07:36 的 `all clean`，53 板）。

## Figma 实跑报告（2026-09-18 07:36 · 53 板这一版 · 已收敛）

```
SpeechRail design kit closures · 53 frames · 26 深色 · 248/248 连线
bind errors=0   export errors=0   stray top-level=0
root overflow=0   inner overflow=0   placeholder fill=0
cjk runs=PingFang SC
AUDIT VERDICT · 53 frames · all clean (overflow / inner / unbound-gray / dark-binding / stray)
```

这一版是 **4 次实跑**收敛出来的（10 块 → 6 块 → 4 块 → 0 块待修）。全部靠改生成器，
**没有在 Figma 里手改任何节点**；每次都是「改 `main.js` → 离线门禁 → `build-closures.js`
→ 热重载 → 运行 `SpeechRail Closure Kit` → 读面板」。

| 次 | 待修板数 | 定位到的缺陷 | 修法 |
|---|---|---|---|
| 1 | 10 | ① 右栏被 `stretch` 到行高压短（`detail ▸ side ▸ sideBody +50B`）② 对比板 `note` 比可用宽多 24px ③ 会后 OS 那一行说明整页多占 21px ④ 对比板右栏同样被压短 | ① `meetingShell` 与对比板的右栏都去掉 `stretch` ② `note` 宽 520 → 496 ③ 会后说明并入收起态那一行 ④ 对比表列宽 132/300 → 150/290、第三列文本 640 → 420 |
| 2 | 6 | ① 同一块对比板的 `timeline ▸ foot +10B` ② 会议「录制中 · 内心 OS」右栏 `sideBody +50B` ③ 字幕带浮层 `Caption Band +2R [1040 in 1038]` | ① 见第 3 次（第 1 次那处修法没治好）② 报告通道打通后按新的定位信息处理 ③ 场景内宽改按 1038 算（描边占 2px） |
| 3 | 4 | ① 对比板两个撑高卡片 `timeline ▸ foot +10B`、`exits ▸ foot +10B`（深色克隆同样）② 会议「内心 OS」态 `sideBody +50B h275/302` + 同栏 `spacer +51B` | ① 两个 `spacer()` 换 `hairline()`（并删掉对比表里多余的 `spacer(table)`）② 该态右栏从 7 行收到 5 行、说明收短（右栏的高度是「这一行剩下的高度」，展开的 OS 抽屉吃掉一截） |
| 4 | **all clean** | — | — |

顺带修掉的是**报告本身**：结论区原先「一处一行、但把一处里的多处问题挤在一行、再切成 60 字符」，
于是 6 块板的 12 处问题在面板里只读得到 6 处 + 下一处的开头 11 个字符（实测）——第 1 次运行
「10 块待修」也只读得到前 4 块。现在每处一行、上限 150 字符，且每处都带上「从被审画板到溢出节点的
完整路径 + 每一层的大小定位模式」。这一条是两次实跑之间最大的效率差别：`+10B` 只说了多少，
`row{V:AF|S}/notes{V:AF|S}/timeline{V:AF|S}/foot{T:H}` 才说得出是谁被写死的。

### 这一轮学到的四条（已写回 `main.js` 的注释）

1. **撑高卡片里不能放 `spacer()`**：卡片是 height=AUTO 时，`spacer` 的 `layoutGrow` 会让 Figma 在
   撑高计算里把它连同**它前面那个 gap** 一起略过，排在它后面的节点就整段溢出——gap 10 就正好
   `+10B`。实测两处（`timeline/foot`、`exits/foot`）。反证是同一块板上 `gap: 0` 的对比表：同样结构
   只差 1px，低于审计阈值（>1）所以一直没报。要分隔就用 `hairline()`——这与 2026-09-17 那条
   经验是同一条（那张分人表上方留着注释）。
2. **`stretch()` 会把竖排容器的「高」写死**：`layoutAlign = STRETCH` 落在**横排**父级里时，
   `applyLayout` 把子级的**主轴**（竖排=高）设成 FIXED，冻结在那一刻的高度；之后再往里加内容就从
   底部溢出。`card()` 内部会 `stretch()`，所以「右栏不 stretch」这个修法必须绕过 `card()` 才生效
   ——第 1 次只改了 `add(split, side)` 而没绕过 `card()`，所以第 2 次它又出现了。
3. **1px 描边会把内容盒各收进 1px**：1040 的容器里，`STRETCH` 的子节点只拿到 1038
   （实测 `scene/bandWrap/Caption Band +2R w1040/1038`）。场景里的画面与字幕带都按 1038 画；
   子节点比父级窄不会溢出，所以 1038 在两种解释下都成立。
4. **报告读不全是我们自己的切片，不是无障碍层的限制**：单个 `<div>` 的文本不会被截断（被截断的是
   装计数行的那个 `<pre>`，约 250 字符）。所以结论行现在按 150 字符切，且**只切尾**——每处一行。

## 离线门禁（2026-09-18 · 53 板这一版 · 第五轮）

第五轮（9 条）改完重跑，数字如下。板数 49 → 53（+2 屏幕 +2 深色克隆），
连线 205 → **210**（三条新连线：对比板 2 条 + 助手侧栏 3 条，其中 A5 的 1 条与对比板的 2 条
原先因板名不一致而静默失效），数值变量仍是 21、颜色变量仍是 23（本轮 0 新增，只补 1 个图标）。

```bash
node --check figma-kit/main.js      # 通过
node figma-kit/audit.js             # audit: clean（colour 23/23 · icons 40/44 · text styles 11/11）
node figma-kit/smoke.js full        # 48 板 · 21 深色 · 478 连线 · 无自连 · SMOKE OK
node figma-kit/smoke.js closures    # 53 板 · 26 深色 · 210 连线 · 无自连 · SMOKE OK
node figma-kit/build-closures.js    # code.js 341,751 字符 / 412,091 字节
md5 -q ~/Downloads/SpeechRail-closure-kit/code.js   # 7b1bca6e074d26c2ec4ab7b9a7759da7
```

**注意**：这些是**离线**证据。`smoke.js` 的替身没有布局引擎（报告里的 root / inner overflow 在
替身上是假的），几何只能由实跑证明——这一版已在 Figma 里跑到 `all clean`（见上面那一节，
2026-09-18 07:36）。

## 离线门禁（2026-09-18 01:05 复查 · 49 板那一版 · 历史）

板数 45 → 49（+2 屏幕 +2 深色克隆），连线 178 → 205，数值变量仍是 21（`size/inspector` 之后没有再加）。

```bash
node --check figma-kit/main.js      # 通过
node figma-kit/audit.js             # audit: clean（colour 23/23 · icons 39/43 · text styles 11/11）
node figma-kit/smoke.js full        # 48 板 · 21 深色 · 478 连线 · 无自连 · SMOKE OK
node figma-kit/smoke.js closures    # 49 板 · 24 深色 · 205 连线 · 无自连 · SMOKE OK
node figma-kit/build-closures.js    # code.js 324,604 字符 / 385,897 字节
md5 ~/Downloads/SpeechRail-closure-kit/code.js   # 95e64e3b1333d26548d3ff659ef8829c
```

**注意**：上面这些是**离线**证据。这一版比上一版多了 2 块屏幕（+2 深色克隆）与总览的一节，
`smoke.js` 的替身没有布局引擎，所以**几何在 Figma 实跑前不算通过**。上一版的
`AUDIT VERDICT · all clean` 属于 43 板那一版，不能当作这一版的证据。

## 离线门禁（2026-09-17 23:00，43 板那一版 · 历史）

```bash
node --check figma-kit/main.js      # 通过
node figma-kit/audit.js             # audit: clean（colour 23/23 · icons 38/42 · text styles 10/11）
node figma-kit/smoke.js full        # 48 板 · 21 深色 · 478 连线 · 无自连 · SMOKE OK
node figma-kit/smoke.js closures    # 43 板 · 21 深色 · 166 连线 · 无自连 · SMOKE OK
node figma-kit/build-closures.js    # code.js 304,678 bytes
md5 code.js                         # d1bd01744c556e0ed5672d501b75c4ee
```

替身没有布局引擎，所以 `smoke.js` 的 overflow 计数不可信；几何结论只取下一节的 Figma 实跑。

## Figma 实跑报告（2026-09-17 23:00，`SpeechRail Closure Kit`，热重载后运行）

```
SpeechRail design kit closures · 10.5s · 17 screens + 4 overlays · 43 frames (闭环 43) · modes: Light
boards=43   dark boards=21   frames audited=43
bind errors=0   export errors=0   stray top-level=0
root overflow=0   inner overflow=0
prototype links=190/190
cjk runs=PingFang SC
AUDIT VERDICT · 43 frames · all clean (overflow / inner / unbound-gray / dark-binding / stray)
```

这一版是 6 次实跑收敛出来的，过程本身就是证据（全部靠改生成器，**没有在 Figma 里手改任何节点**）：

| 次 | 报告 | 定位到的缺陷 | 修法 |
|---|---|---|---|
| 1 | `root overflow=4 · inner overflow=1` | 脊柱行 4 格按 3 格算宽（+444px）；状态胶囊格 96 宽装不下 103 | 格宽改 367、胶囊格改 116 |
| 2 | `1 need attention`（同 1） | 同上，确认修好 | — |
| 3 | `root overflow=4 · inner overflow=30` | 分人板把内层 `row` 当画板返回（`add()` 返回的是子节点）→ 游离节点 + 少一个深色克隆；撑高卡片里用了 `spacer()`；表格三列按画板宽而不是可用宽算 | 返回 `board`、去掉撑高卡片里的 `spacer()`、列宽 570 → 550 |
| 4 | `inner overflow=4` | 会议空态与内心 OS 的胶囊格装了句子（122/123px）；`osBody` 里同样有 `spacer()` | 胶囊只放短名（句子进说明栏）；去掉 `spacer()` |
| 5 | `inner overflow=2` | 内心 OS 面板竖向差 11px | 收 gap/pad，并把「可以直接念」并入一行 |
| 6 | **all clean** | — | — |

顺带修了报告本身：结论区改成「一处一行、板名一行」并排在计数行之前——改之前 8 处问题在插件面板里只能读到 2 处
（无障碍层按行截断），改之后 4 处全部读到。

## 导出物

**上一批（35 板，2026-09-17 22:04）**：`~/Downloads/speechrail-closure-export-v1/`，70 个文件，
`verify-exports.sh` 通过。这一批是第一次交付时用户审查用的，保留作回退点。

**当前这一批（53 板）：按用户 2026-09-17 的指示不导出。** 用户的要求是「先不导出，进一步核查
设计稿与文档」，第四、五轮又追加了端到端旅程与 9 条审查意见，所以这几轮都只做核查与改稿。
Figma 实跑已在 2026-09-18 07:36 与 12:38 做完并收敛（两次「授权」都只覆盖运行插件，未覆盖导出）；
**导出仍留到用户下一次开口**。
（上一批 43 板曾在 Figma 里点过 `Export 43 layers`，但保存面板未起来时机器锁屏，没有落盘；
`~/Downloads/speechrail-closure-export/` 目前为空。要补时按
`~/.agents/skills/figma-to-macos/references/figma-app-export-sop.md` 走。）

导出时应核对：**这一版应导出 53 板 / 106 个文件**、`verify-exports.sh <dir> 53 4` 通过、
`闭环总览` 与 9 块新板（会议空态、内心 OS、实时对讲、分人共用、语音助手未开始、跨会话记忆、
录制中断、换音色 vs 换人设、字幕带在用时）目视抽查一遍。
**注意**：Figma 文件里现在是 **53 块**，`code.js` md5 `c72bf2e9b8077a8ba98a21366e649861`
（2026-09-18 12:38 实跑，第七轮版）。**稿与插件包已经一致**——07:36 那一版（`7b1bca6e…`，第五轮）
已被这次运行取代，导出时按这一版核对。

### 上一批（35 板）的导出表，供对照

来源：上面同一次运行的稿。目标目录 `~/Downloads/speechrail-closure-export/`，**70 个文件**
（35 块画板 × PNG@4x + SVG），`verify-exports.sh ~/Downloads/speechrail-closure-export 35 4`
→ `verdict: 结构与尺寸检查通过`（成对、尺寸为画板整数倍、无 `<image>`、无 0 字节、整批 SVG 含 `<text>`）。

| 类别 | 帧数 | 实测尺寸（PNG / 画板） |
|---|---|---|
| 屏幕画板（含深色克隆） | 30 | 5760×3600 / 1440×900 |
| `▸ 设置 · 会话（配置大模型）`（含深色克隆） | 2 | 5760×4464 / 1440×1116 |
| `▸ 菜单栏 · 三个入口`（含深色克隆） | 2 | 5760×3636 / 1440×909 |
| 字幕带浮层 4 条（含深色克隆） | 8 | 跟随 4352×952 / 1088×238；回看 4352×1144 / 1088×286；大字 4592×856 / 1148×214；受阻 4352×820 / 1088×205 |
| `闭环总览 · 三条闭环`（图，无深色孪生） | 1 | 6400×6908 / 1600×1727 |

**没有**导出的：PDF；深色以外外观；最小窗口 1120×720 与宽屏；多屏位置。

## 已核对

- 本包列出的四道离线门禁 + **三次** Figma 实跑的 `AUDIT VERDICT · all clean`：43 板那一版
  2026-09-17 22:02、53 板第五轮版 2026-09-18 07:36、53 板第七轮版 2026-09-18 12:38
  （每次的运行过程记在各自的「Figma 实跑报告」一节）。
- 导出的结构核验（2026-09-17 22:04，`verify-exports.sh` 通过）。
- 目视抽查 3 处（4x 裁切放大，2026-09-17 22:05）：总览的脊柱行（4 格等宽、无越界）、总览的状态演进 +
  固定/可变两段（中文正常、无叠字）、`▸ 会议助手 · 会议页 · 整理中` 页头（新画板名生效）。
- 全量稿未受影响：`smoke.js full` 仍是 48 板 / 478 连线 / 21 深色。
- 误跑目标的核查（2026-09-18 12:38，只读）：上一轮误按标签名匹配、点进了 `SpeechRail` 标签，担心
  闭环 kit 跑进全量稿——实测该文件 key `x5Ke0tKe9adeov4NG5baxP` 的 Pages 面板仍是 `01 Kit` +
  `02 Screens` 两页，图层里还有 `Archive` / `Menu & Settings` / `Flows`，**没有 `01 闭环` 页**。
  闭环生成器若落在这份文件上只会剩一页 `01 闭环`，所以它没有被重建过，误跑没有造成损失。
- 目视（2026-09-18 12:38）：34% 缩放截图，总览与各泳道有内容、中文无空白、无叠字、无占位灰。
- 文档同步：`SESSIONS-SPEC.md` 的 P8 / §3.2-S6 / §6.5 / §9 / §13-D1、该包 `HANDOFF.md` 的 D1 段落
  已按用户裁决改成 SQLite；旧的 48 板导出物保持原样（见「已知偏差」）。

## 未执行项与原因

- **没有改 `macos/SpeechRailApp` 一行**：本轮范围是「先把 Figma 稿设计出来，完成后找用户审查」。
- **Figma 实跑已完成**（2026-09-18 07:36 第五轮版、12:38 第七轮版，两次都是
  `AUDIT VERDICT · 53 frames · all clean`）。
  更早一次（2026-09-17 深夜）曾被系统锁屏挡住（`cua` 报 `The Mac is locked and automatic unlock
  could not unlock it`），按项目规则不自动解锁、也不在锁屏下驱动 UI；用户 2026-09-18 回「授权」
  之后补跑，共 4 次运行收敛。
- **没有导出**：用户明确「先不导出」，本轮只做核查、改稿与实跑。
- **没有跑任何自动化验收**：`pytest`、`ruff`、`mypy`、Redocly、`macos_app_build.sh`、XCUITest /
  UI test 均未执行——本轮没有代码变更，且项目规则要求自动化验收需当次明确授权。
- **没有做实现侧的验证**：稿里的交互（字幕带位置记忆、EOF 屏障、记录库检索）都还没有实现。

## 已知偏差

| # | 偏差 | 影响 | 处置 |
|---|---|---|---|
| 1 | 旧 48 板导出物（`~/Downloads/speechrail-sessions-export/`）里仍有「本机文件」字样 | 两份稿的同一处文案不一致 | 以本稿为准；旧导出物留作历史，不与本稿混用 |
| 2 | 全量稿（48 板）没有状态演进 / 固定可变两张表，也没有「页 · 状态」命名 | 两份稿对同一批页面的组织方式不同 | 有意为之：全量稿按页画全，闭环稿按状态画；改交互以本稿为判据 |
| 3 | 插件只能写「同页 + 顶层 frame」的连线 | 跨页导航无法自动生成 | 闭环稿把 3 组内容压在一页上；只有跨页时才需手工补 |
| 4 | 总览页是图，不是界面 | 不参与深色孪生 | 审计已按命名规则排除，不需要处置 |
| 5 | ~~「内心 OS」的入口画在了它自己那块板上~~ **已作废**（2026-09-18 第五轮） | — | 第五轮把 OS 从独立版面改成页骨架里的抽屉组件：入口（贴底那一行的 chevron + `⌘⇧I`）随骨架一起落在共用屏上，不再有需要手工补的按钮 |
| 6 | macOS 侧的系统音频取音路径只做了 SDK 取证（`AudioHardwareCreateProcessTap` / `CATapDescription.bundleIDs` / `processRestoreEnabled`，macOS 14.2 / 26.0），**没有在真机上跑过一次 tap** | 稿上的授权态、来源列表、中断与接回三句话都是设计意图，不是实测行为 | 实现阶段先做一个最小取音验证（含 TCC 授权的确切服务名与 Info.plist 键），再按结果回改文案 |
| 7 | **全量稿不再是「零影响」**：`paneSession` 新增了「语音助手」一组，两稿共用的同一块设置面板会变高；2026-09-18 第五轮又加了会议页两块主屏（`screenMeetingRecording` / `screenMeetingMinutes` 换成新骨架） | 结构没变（48 板 / 478 连线不变），但内容变了：全量稿的会议页现在也是「页头 → 状态带 → 转录 + 会议信息 → 贴底 OS 抽屉」 | 有意为之：设置面板与会议页各只有一份实现，两稿共用（与 `figma-kit/README.md` 同一条口径）。若要让两稿各自冻结，就得把它复制成两份——那才是真的分叉 |
| 10 | ~~第五轮新增/重画的 5 处（打字输入、对比板、会议新骨架三块、标注面板、字幕带「在用时」浮层板）未在 Figma 实跑~~ **已消除** | 2026-09-18 07:36 实跑 `all clean`；新骨架、对比板、字幕带浮层都在这一版里 | 对比板列宽最终是 150 / 290 / 420（按 1440 − 24×2 − 420 − 16 = 956 的可用宽算），右栏三张卡按内容撑高 |
| 8 | ~~新板 `语音助手 · 对话页 · 未开始（先定人设与音色）` 与三处文案改动未在 Figma 实跑~~ **已消除** | 同一次实跑（几何只能由实跑证明） | 见「Figma 实跑报告（53 板这一版）」 |
| 9 | ~~第四轮的 2 块新板（跨会话记忆、录制中断）、状态格收窄到 255、总览新增的「旅程还会走到这里」一节未在 Figma 实跑~~ **已消除** | 同一次实跑；这三处都是按内容撑高、最容易竖向溢出的形状，都在这一版里被审过 | 同上 |

## 未验证 / 待验证

- **几何已由实跑证明**（2026-09-18 12:38，第七轮版：`root overflow=0 · inner overflow=0`）：
  板数与连线数先由离线替身确认，连线总数以实跑报告为准（替身低估 210 vs 248，见 12:38 那一节）。
  第四轮的 2 块新板刻意对齐了已收敛的骨架（页头 + 状态带 + 两栏，
  底部一张 3 行的表 + 一行说明，与「内心 OS」那块板同形；侧栏 kv 不超过 6 行），但那是推断。
  第五轮改动最大的三块（会议页三态、对比板、展开态 OS 抽屉）都用固定宽度的列（对比板 150/290/420、
  OS 抽屉左栏 460、答卡文字 560），这些数字是按 1440 宽窗口算的，**换窗口宽度不在本轮画板范围内**。
  另外**状态格从 322 收到 255**（三条闭环都变成 5 态）：宽度算术成立（255 × 5 + 168 + 12 × 5
  = 1503 ≤ 1504），折行之后的观感已由这两次实跑看过截图，**换窗口宽度仍未验**。
- **编码前的三处断点**（用户的第二项约束「统一设计 token」把第一处逼了出来）：
  D7 会话页列宽（稿里 320 / 420，应用只有 `inspectorColumnWidth = 360`）、
  D8 SQLite schema 与库文件位置、D9「全局」快捷键的实现方式。逐条写在
  [`IMPLEMENTATION-READINESS.md`](IMPLEMENTATION-READINESS.md) 与 `SESSIONS-SPEC.md` §13。
- **材质与层级**：设置窗与菜单栏面板的 `hudWindow` 材质在真实桌面叠放下的可读性——上机才能验。
- **字幕带位置记忆**：每块屏幕一套位置、字号三档的持久化行为；稿上只有声明。
- **大模型错误分支**：未配置 / 不可达 / 模型不存在三种结论的画法与文案已画，真实错误码与超时表现要等实现。
- **SQLite 落点的实现细节**：库文件位置、schema（§15 与 §15.6 的增量 R1）、迁移与备份流程都已在
  `SESSIONS-SPEC.md` 里定到可施工，但**没有写过一行 Swift**；FTS5 是否可用仍未实测。
- **本机音频取音**：process tap 的授权提示、来源列表、（App 退出后的）自动接回都还没在真机上验证；
  采样格式与两路混音（麦克风 + 本机音频）后的时钟对齐也要实现阶段实测。
- **内心 OS 的上下文窗口**：问「多久之前的事」能答到什么程度、超长会议怎么截断，需要实现阶段定阈值。
- **换设备的会话重建**：服务端在首个 PCM 后不接受改采样格式——App 侧怎么把「重开 session」做得不打断用户，
  稿上只画了结论（记录不丢、标「换设备」），实现时要验。
- **键盘路径**：稿里画了 ⌘⇧L / ⌘⇧N / ⌘⇧. 与侧边栏快捷键，真机冲突检测未做。

## 走查清单（给用户审查用）

- [ ] 总览 `闭环总览 · 三条闭环`：三条泳道的每一格是否指向正确画板（248 条连线已全通，点是能跳的）
- [ ] 总览底部「状态演进」+「改这一页之前」：这一次要解决的「页面不是一次性」是否答在点子上；
      `CLOSURE_FIXED_VARIABLE` 里那 6 条固定/可变的划分是否同意
- [ ] 三条闭环各自的 ② 受阻：麦克风未授权 / 服务未就绪 / 麦克风被占用，出口是否只有一条且都不弹框
- [ ] 记录库（`语音助手 · 记录库 · 刚结束`、`会议助手 · 会议页 · 已归档`、`实时字幕 · 记录窗`）：
     列表 + 选中 + 详情 + 继续/重命名/导出/移除，是否是你要的「资产」形态
- [ ] `设置 · 会话`：大模型四件套（地址 / 模型 / 密钥 / 检查连接）+ 三种结论 + 记录库位置与备份
- [ ] 命名：`<能力> · <页> · <状态>` 这套画板名读起来是否顺；要不要把 Figma 文件改名成 `SpeechRail · 会话闭环`
- [ ] **第三批五条**：会议空态里的音频来源三选一（含三种受阻）、内心 OS 的「不进音频 / 不进转录 / 默认不进纪要」
     三条边界、分人共用链路的三种状态、换音色与人设的两条生效边界、两种对讲模式与打断的呈现
- [ ] **本机音频的产品口径**：按 App 抓（而不是抓整机）、默认不静音原输出、来源标进记录——是否同意
- [ ] **内心 OS 是否进纪要**：默认不进、「写进纪要」是显式动作——这是产品判断，要你确认
- [ ] **人设的锁**（2026-09-17 新增）：`语音助手 · 对话页 · 未开始（先定人设与音色）` 是不是
      你要的「定人设」那一步；以及 `… · 换音色（人设已锁定）` 上那句解释
      （前缀缓存会整段失效）读起来对不对——这条要落在界面文案里，所以措辞值得当场改
- [ ] **本轮实跑时改掉的两处观感**（都是几何逼出来的，看一眼即可）：
      `换音色 vs 换人设（影响面）` 右栏两张卡的脚注上方现在是**分隔线**（原来是一段空白，
      `spacer()` 在撑高卡片里会制造溢出）；`会议助手 · 会议页 · 录制中 · 内心 OS` 的右栏
      只剩 5 行（「分人」「整理」让给状态条与其它态）——展开的 OS 抽屉吃掉一截高度，
      右栏是「这一行剩下的高度」，不是按内容撑
- [ ] **第七轮那十处改写**（`SESSIONS-SPEC.md` §17、下面「第七轮 delta」表）：去重了 9 处重复动作、
      把规格语言改写成用户话（`分人` → `标出说话人` 等）、给三条能力各加一句互指路。重点看
      `语音助手 · 对话页 · 未开始`、`实时字幕 · 未开始`、`会议助手 · 来源选择`、`换音色 vs 换人设` 四块
- [ ] **旅程正文**（`SESSIONS-SPEC.md` §16.2.1–§16.2.6）：三条主旅程 + J0 + 四条衔接的逐步路径
      （每一步：做什么 → 落在哪块板 → 写进哪张表 → 失败退到哪）是否符合你心里的走法；
      以及 §12 新增的「阶段 ↔ 旅程」验收顺序（阶段 3 先通 J3、阶段 5 通 J1、阶段 6 通 J2）是否同意

## 回退

- 稿可直接重生成：改回 `main.js` 的对应段 → `node build-closures.js` → 热重载 → 重跑插件，稿回到上一版；
  生成器是幂等的（重跑清空并重建这一页的 35 块画板）。
- 导出物是只读产物：旧的一批在 `/tmp/` 或原目录，重新导出即在。
- 全量稿不在本次改动范围内，无需回退；`smoke.js full` 可作为它未被影响的证据。
