# SpeechRail macOS App · 会话模块设计交付交接包

生成时间：2026-09-17 20:45 CST
本次轨道：**B（代理 / 自定义 provider）**
轨道证据：`codex doctor --all`（2026-09-16 16:49，沿用同一条判定）→ `default model provider cliproxyapi`，
feature flags 里 `tool_search_always_defer_mcp_tools` 为开启状态；本会话可用工具里没有
`mcp__codex_apps__figma_*`，也没有 `tool_search` 出口。因此写稿只能走「生成器 + Figma 桌面版」，
判定时间 2026-09-17 20:05（本次会话复核：可用工具列表仍无 Figma 连接器工具）。

## 权威来源

| 层 | 位置 | 说明 |
|---|---|---|
| 稿的源码 | `docs/design/2026-09-15-macos-uiux-redesign/figma-kit/main.js`（`build.js` 合成 `code.js`） | 改稿改这里，不在 Figma 里手改 |
| 稿的产物 | 同一份既有 Figma 文件（Drafts 里唯一的文件，文件 key `x5Ke0tKe9adeov4NG5baxP`，本次显示名 `SpeechRail`，Starter / Free 账号）：`01 Kit` 3 块 + `02 Screens` 45 块 = **48 块画板**，由 agent 在 Figma 桌面版运行插件生成（2026-09-17 20:36，43.4s） | 插件包在 `~/Downloads/SpeechRail-figma-kit/` |
| 页面规格 | `SESSIONS-SPEC.md`（本包）§4–§11；视觉语言仍以 `../2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md` §5 为准 | 本包不重写 token |
| 运行态事实 | `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` + 各页面 View | **本轮未改**（见「未执行项」） |

## Token 表（只登记本轮的 delta）

基础表不重复：数值与颜色的声明点仍是 `SpeechRailDesignTokens.swift`，导出表在
`REDESIGN-SPEC.md` §11.3 与 `docs/developers/macos-app-design-system.md`。本轮新增：

| 语义 | 值 | 声明点 | 消费方 |
|---|---|---|---|
| 字幕正文（标准档） | `Caption Band / 标准` · 20pt / 行高 135% | `figma-kit/main.js` `TEXT_STYLE_DEFS` | 稿：3 块字幕带画板 + `Caption Line` 组件集；实现：`.title` |
| 字幕正文（大字档） | `Caption Band / 大字` · 26pt / 行高 130% | 同上 | 稿：`浮层 · 字幕带 · 大字`；实现：`.largeTitle` |
| 紧凑档 | 复用既有 `Title / Page`（17pt 邻档） | 既有 | 实现：`.title2` |

颜色 **0 新增**、数值 **0 新增**；图标 **+8**（`message-circle` / `users` / `captions` / `pin` /
`mic-off` / `volume-2` / `clock` / `bot`，几何取自 lucide 1.47.0，与本 kit 其余图标同源）。
`audit.js` 报告 `icons 37/42`（37 个被引用，`pin` / `volume-2` / `clock` 是留给实现阶段的预置）。

## 导出物

来源：`~/Downloads/SpeechRail-figma-kit/code.js`，md5 `33f4c07fbff10a03f2d10681f93a369e`，
257,866 字节（JS 源 230,525 字符），构建时间 2026-09-17 20:26:03；运行时间 43.4s；
导出**全部 48 块画板**到 `~/Downloads/speechrail-sessions-export/`：96 个文件（48 PNG + 48 SVG），共 24 MB。
PNG 与 SVG 来自同一次运行、同一份 `code.js`。

| 文件 | 倍率 | 尺寸（PNG 实测 / 画板） | 生成时间 |
|---|---|---|---|
| `01 Kit` 文档画板 3 块：`Cover` / `Foundations` / `Components` | 4x + SVG | 6400×4160 / 1600×1040；6400×9884 / 1600×2471；6400×10368 / 1600×2592 | 20:33 |
| `02 Screens` 创作与引擎 20 帧（10 页 × Light / Dark） | 4x + SVG | 5760×3600 / 1440×900 | 20:37 |
| `02 Screens` 会话屏幕 14 帧（7 块 × Light / Dark） | 4x + SVG | 5760×3600 / 1440×900 | 20:37 |
| `02 Screens` 字幕带浮层 8 帧（4 块 × Light / Dark） | 4x + SVG | 4352×952 / 1088×238（跟随）；4352×1144 / 1088×286（回看）；4592×856 / 1148×214（大字）；4352×820 / 1088×205（受阻） | 20:37 |
| `02 Screens` 辅助画板 3 块：`Flows` / `Menu & Settings` / `Archive` | 4x + SVG | 7360×6644 / 1840×1661；8576×12744 / 2144×3186；6720×3580 / 1680×895 | 20:37 |

合计 27 块浅色 + 21 块 ` · Dark` 克隆 = 48；深色只覆盖屏幕与浮层（21 块），文档画板不生成深色孪生。
画板文件名为 `<画板名>.png` / `<画板名>.svg`（画板名见运行报告与 `SESSIONS-SPEC.md` §11 的清单），
权威清单就是 `verify-exports.sh` 打印的那张逐帧表。

**没有**导出的：PDF；最小窗口 1120 × 720；宽屏（> 1440）与多屏位置；浅/深以外的外观（如「增强对比度」）；
Prototype 面板里需手工补的跨页连线（见「已知偏差」）。

## 已核对

- 静态自检（2026-09-17 20:45）：`node figma-kit/audit.js` → `audit: clean`
  （colour 23/23、icons 37/42、text styles 10/11 全部解析到；kebab-case 字面量扫描无悬空）。
- 离屏冒烟（2026-09-17 20:45）：`node figma-kit/smoke.js` → `SMOKE OK`（16 项断言全过），
  报告 `boards=48 · dark boards=21 · frames audited=48 · bind errors=0 · export errors=0 ·
  stray top-level=0 · placeholder fill=0 · prototype links=478/478 · cjk runs=PingFang SC`。
  替身没有布局引擎，几何结论在它那里不可信（报告里以 `~` 标出）。
- Figma 真跑（2026-09-17 20:36，桌面驱动，用户本轮 `@电脑` 授权）：报告首行
  `17 screens + 4 overlays · 48 frames (Kit 3 · Screens 45) · modes: Light`，
  计数行 `boards=48 / dark boards=21 / frames audited=48 / bind errors=0 / export errors=0 /
  stray top-level=0 / root overflow=0 / inner overflow=0 / placeholder fill=0 /
  prototype links=478/478 / cjk runs=PingFang SC`，
  结论行 **`AUDIT VERDICT · 48 frames · all clean (overflow / inner / unbound-gray / dark-binding / stray)`**。
  18 个步骤全 `ok`，报告末行 `no errors`。
- 导出核验（2026-09-17 20:38）：
  `~/.agents/skills/figma-to-macos/scripts/verify-exports.sh ~/Downloads/speechrail-sessions-export 48 4`
  → `PNG=48 SVG=48 期望=96`、`含 <text> 的 SVG=48/48`、逐帧尺寸都是画板的整数倍、
  无缺 SVG / 空文件 / `<image>` 内嵌位图 → `verdict: 结构与尺寸检查通过`。
- 条带目视（2026-09-17 20:38，`crop.swift`，4x 坐标，输出在 `/tmp/sr-crops/`）：按 0/900/1800/2700
  切了 `▸ 语音助手` 与 `▸ 会议助手 · 录制中` 各 4 条带，实际**逐张看过 4 张**——`▸ 语音助手` 顶部带
  （页头 + 状态带「正在说话 · 第 12 轮 · 免持 / 00:03:42 / 大模型 qwen3-30b · 已连接」）与底部带
  （输入行 + 侧边栏第二行「语音助手进行中 · 00:03:42」与「服务已就绪 · Quality」同级常驻）、
  `▸ 会议助手 · 录制中` 顶部带（状态带「正在录音 · 周会 · 分人 / 已记录 148 段 / 4 位说话人」）与
  转录带（说话人标签、`识别中` 徽标、右对齐时间戳、未定稿文字更淡），外加 `浮层 · 字幕带 · 跟随中`
  与 `回看` 整幅（两行正文 + 电平 + 页脚「跟随中 · ⌘L 暂停 · 上滚回看」）。四张都未见叠字、缺行或
  右对齐元素浮到左边；**其余 44 块画板只做了结构核验（尺寸、导出、audit），没有逐块目视**。
- 接口一致性：`prototype links=478/478` 与替身算出的 478 条完全一致（512 次尝试 − 34 次自连）
  —— 两条独立路径给出同一个数，说明跳自连的判据在真机与替身上是同一件事。
- 重建一致性（2026-09-17 20:51）：导出后又用同一份 `code.js` 重跑了一次生成器（`48 frames`、`all clean`、
  同样的 478/478），然后重导 `Foundations` 与交付批次比对：
  `Foundations.png` 两边 md5 相同（`c6a314128c18daa080a9532509d7ae91`）→ 重建逐像素可复现；
  `Foundations.svg` md5 不同但字节数相同（46,600），差异只在 `id="clip0_9_59291"` 这类**内嵌 Figma
  节点 id**（重跑时画板拿到新 id）。结论：**PNG 可以按 md5 判等，SVG 不能**——本 kit 每次重跑都是清空重建。

本轮在真机上发现并修掉的五处生成器缺陷（离线门禁此前都看不见，记录以备下一手）：

| 现象 | 成因 | 处置 |
|---|---|---|
| 整块「会话占用」画板没生成，报告只在 ERRORS 段留一行 `session screens -> in set_layoutPositioning: …` | `layoutPositioning = "ABSOLUTE"` 写在 `appendChild` **之前**，游离节点上赋值被 Figma 拒绝 | 先挂载再赋值；`stub-figma.js` 复现这条限制 |
| `▸ 会议助手 · 会后纪要` 卡片右侧 59px 溢出 | 两列要点各按 5+8+420 取宽（886 > 卡片内容宽 811） | 两列改 `grow()` 平分，正文宽 420 → 380 |
| `Flows` 画板右缘裁掉半张卡（+30px） | 最长流程 6 步 = 1646pt，超出 1680 画板的内容宽 1552pt（2026-09-16 那批就带这个缺陷） | Flows 画板 1680 → 1840 |
| 34 条侧边栏连线被拒（`Reaction at index 0 was invalid`） | 「你正在这一页」的导航行把反应写向自己所在的画板；旧判据比较的是「行 ≠ frame」，恒不成立 | 改为沿父链判断目的地是否在源节点子树内 |
| 上一批导出的 26 个 SVG 里 0 个含 `<text>` | SVG 导出项没写 `svgOutlineText: false`，Figma 默认把文字轮廓化 | 生成器补上；`smoke.js` 新增断言；本批 48 个 SVG 全部含 `<text>`（中文以数字实体编码可搜） |

## 未执行项与原因

- **App 侧改动：0 行**。本轮只交付设计稿与规格，`macos/SpeechRailApp` 未改（`git status` 里那一条
  `?? macos/SpeechRailApp/SpeechRailApp.xcodeproj/xcuserdata/` 是使用者数据，未动）。
- 单元测试 / UI 自动化 / smoke / benchmark：**按根 `AGENTS.md` 的硬约束未运行**（自动化验收需要当次
  明确要求）。本轮也没有代码变更需要它们。
- `scripts/macos_app_build.sh` / `macos_app_test.sh` / `plutil` 检查：未运行（未改 App 与 plist）。
- 未执行 Prototype 面板里跨页连线的手工补线（插件只能连「同页 + 顶层 frame」：`03 Flows` 的节点指向
  `04 Screens`、字幕带浮层的入口按钮）；稿里已在 Flows 页写了这段说明。
- 未在 Figma 里做任何手工编辑（画板、变量、样式、导出设置全部来自生成器）。
- 未导出 PDF、最小窗口与宽屏变体（原因见「导出物」）。
- 未做真机材质实测：稿画不出 `NSVisualEffectView` / `hudWindow`，见「待验证」。

## 已知偏差

| 位置 | 稿 | 实现 | 处置 |
|---|---|---|---|
| 深色外观的实现方式 | 免费版一个变量集合只允许 1 个 mode，所以深色是「克隆浅色画板 + 逐节点改绑到 `SpeechRail (Dark reference)` 集合」 | 生产实现应用同一集合的 Light / Dark 双 mode | 既有约束，沿用；本轮新增的 11 块画板按同一路径生成，浅/深各 11 块可比对 |
| 字幕带材质 | 以 `surface/panel` + 1px hairline 表示半透明薄片 | `NSPanel`（非激活）+ `NSVisualEffectView` 的 `hudWindow` 材质 | 稿里已注明「材质由系统提供」；真机取值列入「待验证」 |
| 菜单栏面板的「深色」块 | 在**双 mode 路径**（付费版 / 离屏替身）下，`darkReference()` 取不到 `V["dark/*"]` 会静默不改绑，那一块会渲染成浅色 | —— | 当前文件走免费版路径（第二集合），不受影响；若日后升级席位改为双 mode，这一块需要另写改绑分支 |
| `03 Flows` 与字幕带浮层的入口连线 | 只能手工在 Prototype 面板补 | 实现时是真实按钮，不受此限 | 稿内已写明；评审时若要点开原型，先补这一条 |
| 上一批导出物 | `~/Downloads/speechrail-figma-export/`（2026-09-16，26 块）是**上一版**稿，且 SVG 里文字已轮廓化 | 本批 48 块为当前版本；两批不要混用 | 需要旧版文字可读的导出时，按上一版源码重建后重导 |
| 重跑后 SVG 的 md5 会变 | 生成器幂等但**每次都是清空重建**，画板拿到新 node id，而 Figma 把 node id 写进 SVG 的 `id="…_9_59291"` | —— | 判"是不是同一版"用 `boards=` + PNG md5 + `verify-exports.sh`，不要用 SVG md5 |
| 会话浮层画板尺寸 | 画板 1088 × 238 等（含画板内的标注文字与说明） | 字幕带本体 760 / 1100 宽 × 撑高（2–4 行） | `SESSIONS-SPEC.md` §11 的「760 × 撑高」指的是带子本身，不是画板 |

## 未验证 / 待验证

- **材质与层级**：`hudWindow` 材质 + 非激活面板在真实桌面壁纸/窗口叠放下的可读性——必须上机做，
  稿上验不了。
- **字幕带位置记忆**：每块屏幕一套位置、字号三档的持久化行为；规格 §6.3 已定义，实现阶段验证。
- **大模型未配置 / 不可达**：受阻态的画法与文案已画（`▸ 语音助手 · 未配置对话模型`），真实错误码与
  超时表现要等实现接入后才能确认分支是否够用。
- **D1 已裁决（用户 2026-09-17）**：记录落在本机 **SQLite** 库文件，不是本机文件夹、也不是 PostgreSQL。
  本包的 `SESSIONS-SPEC.md` §4 P8 / §9 / §13 已按此改写；稿上的文案在 2026-09-17 的闭环稿里是
  「本机数据库（SQLite）」。本包 48 板的导出物是裁决**之前**生成的，里面仍有旧的「本机文件」字样。
- **按路径组织的那份稿**：`../2026-09-17-session-closures/`（三条闭环 + 状态演进）。板数一路
  43（2026-09-17 23:00 实跑 all clean）→ 45（新增「未开始：先定人设与音色」一态、人设改为会话内只读）
  → 49（端到端旅程）→ **53**（第五轮 9 条审查意见），**最终版已在 Figma 实跑收敛**
  （2026-09-18 07:36 起 4 次运行，末次 `all clean`；仍未导出）。它改的是**稿**，
  本包的 48 板结构不受影响——但**设置面板是两稿共用的**，`paneSession` 新增「语音助手」一组后，
  `▸ 设置 · 会话` 那一块的**内容**会变；本批五条能力的产品与规格结论写在本文件 §14。
- **键盘路径**：稿里画了菜单栏与快捷键（⌘⇧L / ⌘⇧N / ⌘⇧. 与 ⌘6–⌘8），真机冲突检测未做。
- **最小窗口 1120 × 720 / 宽屏**：未出画板，实现时按同一几何收缩。

## 走查清单

- [ ] `▸ 语音助手`：对话中 / 未配置对话模型（受阻）两态，输入行与状态带的层级
- [ ] `▸ 会议助手`：空态 → 录制中 → 会后纪要三态，会议列表与转录流的并排关系
- [ ] `▸ 实时字幕`：搜索 / 说话人筛选 / 字号三档 / 星标 / 导出页脚
- [ ] `▸ 会话占用 · 结束会议并切换`：遮罩 + sheet 的措辞（丢什么、保什么）
- [ ] 四块字幕带浮层：跟随 / 回看 / 大字 / 受阻，含悬停工具条与页脚快捷键
- [ ] 侧边栏第二行「会话所有权」：空闲 / 助手 / 会议 / 字幕四种说法，与「服务是否就绪」是否同级可见
- [ ] 浅色 / 深色（21 对画板已全部生成，成对可比对）
- [ ] 设置第 4 个页签「会话」：模型提供方卡片、未配置态、说明文案
- [ ] 菜单栏面板四块：默认 / 会话进行中 / 控制受限 / 深色
- [ ] 信息密度与渐进式披露：页面是否有「一眼看不完」的区块
- [ ] 待裁决项 D1–D6（`SESSIONS-SPEC.md` §13）

## 回退

- **稿**：生成器幂等（重跑时清空并重建全部 48 块画板），回退不需要在 Figma 里做任何手工操作——
  改 `main.js` 回上一版语义重跑即可。上一版导出物仍在 `~/Downloads/speechrail-figma-export/`（26 块）。
- **代码**：本轮未改 `macos/SpeechRailApp`，无代码回退需求。
- **生成器与文档**：本轮改动集中在 `figma-kit/{main.js,icons.js,audit.js,README.md}`（已跟踪，未提交）与
  新增的 `figma-kit/{smoke.js,stub-figma.js}`、`docs/design/2026-09-17-live-sessions/`（未跟踪）。
  `git diff --stat`：`README.md` 39 行、`audit.js` +35、`icons.js` 12 行、`main.js` 1498 行。
  **不要用整文件 checkout 回退**：`main.js` 里同时叠着本轮的会话模块与真机修复，`git checkout --`
  会把两者一起清掉。
- **导出物**：`~/Downloads/speechrail-sessions-export/` 是生成物，可整目录删除后重导；它不是回退点，
  回退点在上面两条。
