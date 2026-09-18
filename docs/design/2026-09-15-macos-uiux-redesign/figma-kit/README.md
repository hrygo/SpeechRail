# SpeechRail Design Kit（Figma 开发插件）

把这套重设计规格生成到 Figma 的**本机开发插件**。它只写 Figma 文档，不接触仓库代码、服务或运行态。

## 文件

| 文件 | 作用 |
|---|---|
| `manifest.json` | 插件清单（`editorType: ["figma"]`，`networkAccess` 仅 `none`） |
| `icons.js` | 44 个 lucide 图标的真实几何（由 lucide 源生成后固化） |
| `main.js` | 生成器：Variables、Text styles、Foundations、Components、10 个创作/引擎屏幕 + 7 块会话屏幕 + 4 块字幕带浮层（各自带深色克隆）、流程页、菜单栏与设置页、归档对照页、原型连线、自检 audit。八组内容排在**两个真实页面**上（见「页面与排布」） |
| `build.js` | 把 `icons.js` + `main.js` 合成 `code.js`，并连同 `manifest.json` 落到 Figma 文件选择器可访问的目录 |
| `audit.js` | 静态自检（不需要 Figma）：颜色变量 / 图标 / 文本样式 / 数值 token 是否都能解析到，**版式单点声明**是否被破坏（见下节「LAYOUT」） |
| `smoke.js` + `stub-figma.js` | 离屏冒烟（不需要 Figma）：在最小 API 替身上把生成器整跑一遍，检查页数预算、画板是否页面顶层 FRAME、导出设置、深色克隆改绑、游离节点、自连。**不检查几何**（替身没有布局引擎） |
| `check-links.js` | 闭环稿的连线源核对：连线是**按文案找回那个控件**的，文案一改，找不到源就静默少一条连线（报告里只体现为 attempts 变小）。所以改任何按钮 / 菜单行文案之后跑它 |

`code.js` 是构建产物，只写在落地目录（仓库外），不写回本目录，也不纳入版本控制。

## LAYOUT：版式数值只有一处声明

`main.js` 顶部有三层 token，规则是**同一语义只声明一次，跟随值由它推导**：

1. `COLOR_TOKENS` → Figma 颜色变量（浅 / 深成对），调用点按变量名引用；
2. `TEXT_STYLE_DEFS` → 文本样式；
3. `NUMBER_TOKENS` → 数值变量；`LAYOUT` 块按语义引用它们（`NT["space/16"]`），并把
   行内宽度推导出来（列表内宽 = 列宽 − 2 × 内边距，空态正文宽 = min(容器内宽, 上限)…）。

行内微间距（2 / 4 / 8 / 12…）仍是就地字面量：它们不构成跨页约束。

`audit.js` 会拦下**同一语义的第二个数值**：`LAYOUT` 已经认领的值（目录列 280、列表内宽 248、
列表行内宽 228、档位卡内宽 196、侧栏内宽 220、设置说明列 260、窗口宽 1440、画布宽 1600、
菜单面板 288）再以字面量出现在宽度位置就是失败。改版式先改 `LAYOUT`，再改调用点——
不要在两处写同一个数。全 App 的统一规则见 [`../../UX-UI-SPEC.md`](../../UX-UI-SPEC.md) §3.3。

会话两列（右栏 / 目录列）的历史裁决 D7 / D10 就是 `LAYOUT.sideW` / `LAYOUT.listW`；
`SESSION_SIDE_W` / `SESSION_LIST_W` 只是它们的别名，不是第二个声明处。

## 使用

```bash
node build.js          # 合成 code.js，并写 code.js + manifest.json 到 ~/Downloads/SpeechRail-figma-kit/
node audit.js          # 静态自检引用的变量 / 图标 / 文本样式，退出码非 0 即有悬空引用
node smoke.js full     # 全量稿：在替身上整跑一遍，退出码非 0 即有拼装层面的问题（约 20 秒）
node build-closures.js # 第二份稿（会话闭环）：合成 code.js 到 ~/Downloads/SpeechRail-closure-kit/
node smoke.js closures # 第二份稿的离屏冒烟
node check-links.js    # 第二份稿的连线源核对（改了文案必须跑；退出码非 0 = 有连线源找不到）
```

`node smoke.js`（不带参数）等同于 `full`，两套命令共用一个替身与同一份 `main.js`。

生成器只有这一份：源码在仓库里，运行产物在仓库外。不要在工作目录之外再留一份源码副本。

然后在 Figma 桌面版：

**Plugins → Development → SpeechRail Design Kit**
（第二份稿是另一个插件：**SpeechRail Closure Kit**，见下节）

首次使用需要先 `Plugins → Development → Import plugin from manifest…`，指向与 `code.js` 同目录的
`manifest.json`（即 `~/Downloads/SpeechRail-figma-kit/manifest.json`）。

## 第二份稿：会话闭环（`SPEECHRAIL_SCOPE = "closures"`）

同一个生成器、同一个替身、同一次 `audit`，多一个范围开关：`main.js` 顶部读 `SPEECHRAIL_SCOPE`，
只有 `"closures"` 才走闭环分支，默认 `"full"`——所以**全量稿的板数与连线数没有变**（`smoke.js full`
仍是 48 板 / 478 连线）。板数是同一个，内容会跟着走的有两处：`paneSession`（设置第 4 页签）里新增的
「语音助手」一组，以及会议页的两块主屏（见下）。设置面板与会议屏都只有一份实现，两稿共用。
`build-closures.js` 只在拼接时先写一行 `var SPEECHRAIL_SCOPE = "closures";`。

它画的是三个能力（语音助手 / 会议助手 / 实时字幕）的**完整闭环**，按**路径**组织而不是按页面组织：
① 入口 → ② 前置与受阻 → ③ 主交互 → ④ 交还与守卫 → ⑤ 产物与回看。判据是两端都在稿里——从哪进、
产物落在哪；三条闭环共用一根脊柱（系统级入口 / 大模型在哪配 / 记录落在哪 / 谁在用麦克风），否则
三条路径会在「麦克风被占」这类交叉点上各说一套。

**21 块屏幕 + 5 条字幕带浮层**（各自带深色克隆 = 52 帧）+ 1 块总览 = **53 块画板**，全部落在**一个真实页面**
`01 闭环` 上（免费版 3 页额度，这里只占 1 页；连线只允许同页顶层 frame，拆页会让三条闭环各自断掉）。

21 块屏幕里，会议与助手两侧各有几块是**闭环稿专有**的（音频来源、内心 OS、实时对讲、换音色、
换音色 vs 换人设对比板、助手未开始态、跨会话记忆、录制中断、分人共用链路）。会议页的两块主屏
（`screenMeetingRecording` / `screenMeetingMinutes`）**两稿共用**：2026-09-18 的布局重构直接改在那两个
函数里，所以 48 板那一批的会议页跟着一起变（这是有意的——「会议助手整体布局需要重新构思」是对
产品说的，不是只对闭环稿说的）。改共用屏之前先跑 `node smoke.js full`，确认全量稿的板数与连线数不变。

总览页上的三张表是这份稿的判据，不只是索引：

| 表 | 回答的问题 |
|---|---|
| 三条泳道 × 五个阶段 | 每条闭环节闭环了没有（每个阶段格都必须有落点） |
| 共用脊柱 × 五条 | 三条路径在系统入口、大模型、记录落点、麦克风所有权、分人链路这五件事上是否只有一种说法 |
| 状态演进 × 三条（`CLOSURE_STATES`） | 同一页怎么换状态——页面不是一次性画面 |

最后一张表是 2026-09-17 用户第二条判据落成的东西：三条闭环各自**只有一个产品页**加一条浮层，
未配置 / 空态 / 未开始 → 进行中 → 刚结束 → 归档（从库里再来一轮）都是**同一页的状态**，产物直接落进
页内那个长期存在的资产区（记录库）。所以画板名字也都是「页 · 状态」（`语音助手 · 对话页 · 未开始（先定人设与音色）`、
`会议助手 · 会议页 · 整理中`、`实时字幕 · 记录窗 · 刚结束（已保存）`），而不是一个个孤立的时刻。
`CLOSURE_FIXED_VARIABLE` 那张表写的是改动面：改交互重画的是状态格，页骨架与资产区不动。
改这块之前先读 `main.js` 里 `CLOSURE_STATES` 上方的注释。

## 行为

- **幂等**：重跑时清空并重建全部 48 个顶层画板，页面本身尽量复用。
  逻辑上有九组内容（`00 Cover` / `01 Foundations` / `02 Components` / `03 Flows` / `04 Screens` /
  `07 会话` / `08 会话浮层` / `05 Menu & Settings` / `06 Archive`），但**只落在两个真实页面**上（见下）。
  早于本方案的页名（例如上一版的 `00 Cover` 独立页）会被改名接管，接管不到的会被清空后删除，
  避免旧页把免费版的三页额度占满。
- **画板必须自己拥有内容**：文档画板（Cover / Foundations / Components）的导出取的是**该画板的子树**，
  页面层的兄弟节点再摆在画板矩形里也不会进图。`componentSet()` 因此把 16 个组件集建成画板的
  `layoutPositioning = "ABSOLUTE"` 子节点（坐标仍按声明值，不用改成内边距坐标系）；
  否则导出 Components 只会得到标题和一段说明——历史上真发生过一次，且画板被解散后内容会散在页面上。
- **自检**：运行结束会弹出报告面板，结论排在前面（`AUDIT VERDICT` → 连线数 → 绑定错误数 → 分步结果 → 逐帧明细）。
  审计按真实页面去重后覆盖全部画板；每帧列出尺寸、绑定归属（dark/light 计数）、字面量与变量解析值、占位灰计数、
  根帧越界与父子级内部越界，另有 stray 顶层节点检查，防止漏 `add()` 的节点掉在画布上无声通过。
  文档画板（Cover / Foundations / Components）同样是单帧，所以一并纳入，不要只审带屏幕的那几页。
- **连线**：34 块带侧边栏的屏幕画板（10 创作 + 7 会话，各含深色克隆）之间的导航、状态行、会话行
  与占用守卫主按钮自动写入原型反应。报告里的 `prototype links` 形如 `478/478`：分母是尝试数，
  分子是写入成功数，两者相等才算全通。**画板不能连到它自己**（Figma 报 `Reaction at index 0 was
  invalid`），所以「你正在这一页」的那条导航行要跳过——判据是目的地不是源节点的祖先，不是
  「行 ≠ frame」。

## 页面与排布

Figma **Starter（免费）版每个文件只允许 3 个页面**，而本套内容有九组。所以生成器把它们平铺在
两个真实页面上（留一页额度给使用者），每组画板之间留 400px 间距、顶端对齐：

| 真实页面 | 承载的逻辑组 |
|---|---|
| `01 Kit` | `00 Cover`、`01 Foundations`、`02 Components` |
| `02 Screens` | `04 Screens`（20 帧）、`07 会话`（14 帧）、`08 会话浮层`（8 帧）、`03 Flows`、`05 Menu & Settings`、`06 Archive` |

页面由 `main.js` 顶部的 `PAGE_LAYOUT` 声明，想换小组、加第三页或改间距都改这一处。
生成器**不会**在额度已满时硬造页面：它先复用同名页，再接管其他遗留页（改名），最后才 `createPage()`。
  插件 API 只允许连**同一页内的顶层 frame**，所以流程页与设置窗口内部的跳转要手动补。
- **描边与投影**：静态容器（卡片 / 列表 / 分组 / 流程步 / 归档面板）不描边、不投影，分离只靠填充层级与
  `hairline()` 分隔线（REDESIGN-SPEC §5.2）。保留描边的只有三类：承载状态的元素（选中档位卡、播放中候选卡、
  焦点字段、结论面板）、系统控件（输入框 / 按钮 / 分段控件 / 键帽）和窗口级浮层（菜单面板）。
- **导出就绪**：每个画板写入两条 `exportSettings` —— `PNG @4x`（`main.js` 顶部 `SCREEN_EXPORT_SCALE`，Figma
  的倍率上限：1440×900 的画板导出为 5760×3600，288 dpi；嫌文件大可改回 `2`）与 `SVG`。SVG 那条**必须带
  `svgOutlineText: false`**：默认 `true` 会把文字全部轮廓化，图与尺寸都正常、稿里的字却再也搜不到
  （2026-09-17 实测：上一批 26 块画板导出后 0 个 SVG 含 `<text>`）。SVG 那条**不能带 `constraint`**，
  否则 Figma 拒绝整个数组，该画板在导出面板里显示 "0 of 0 selected"。导出时逐页 `⌘A`（多页稿要切页）
  或 Main menu ▸ File ▸ Export 一次性导出。
- **可选 PNG 导出**：`main.js` 顶部的 `EXPORT_PNGS` / `EXPORT_PAGES` 决定构建时是否把指定页的顶层 frame 按 0.5x
  导出成 PNG。默认 `false`（构建不该写文件）；需要评审图时再打开，并让 `EXPORT_PAGES` 一次只放一页 ——
  每个文件都会弹一次保存确认，前一个没确认完时后续下载会被丢掉。

## 生成器里几个容易踩的点

改 `main.js` 前值得先知道（都是实测踩出来的，不是 Figma 文档里的说法）：

- **绑定 paint 必须用 `figma.variables.setBoundVariableForPaint`**；`node.setBoundVariable("fills", …)` 对 paint 字段无效，
  异常还会被 `try/catch` 吞掉，表现为所有填充停在占位灰 `#808080`。
- **`resize()` 在 auto-layout 的 AUTO 轴上不生效**（下一次布局会覆盖回去）。所以 `size(node, w, h)` 会顺带把对应轴切成 `FIXED`。
- **`layoutGrow` / `layoutAlign` 必须在节点已有 auto-layout 父级时设置**。`add(d, node)` 之后再 `grow(node)` 不会报错，
  但也不生效；`applyLayout()` 会在挂载后重放这些意图。
- **`layoutPositioning = "ABSOLUTE"` 也一样**，而且会在**游离节点**上直接抛错（`Can only set
  layoutPositioning = ABSOLUTE if …`）。要先 `appendChild` 再赋值：顺序反了，那一整块画板都不会生成
  （2026-09-17 实测：`buildSessionGuardBoard` 因此丢了整块「会话占用」画板，报告里只在 ERRORS 段留一行）。
  `stub-figma.js` 现在会复现这条限制，`smoke.js` 因此能在离屏拦住它。
- **画板不能连到它自己**：`node.reactions = [{ … destinationId: 自己所在的 frame }]` 会被拒
  （`Reaction at index 0 was invalid`）。侧边栏里「你正在这一页」的那条行就是这种情况，跳过它。
- **`text()` 先套 `textStyleId`，再写 `characters`**。反过来的话节点仍按旧字体测量，按钮和表格单元格会按偏小的宽度裁掉自己的标签。
- **`spacer()` 不能放进“按内容撑高”的卡片**：卡片是 `height=AUTO` 时，Figma 在撑高计算里会把
  带 `layoutGrow` 的这个子节点连同**它前面那个 gap** 一起略过，于是排在它后面的节点整段溢出——
  gap 10 就正好 `+10B`（实测 `row/notes/timeline/foot +10B`、`row/notes/exits/foot +10B`）。
  反证是同一块板上 `gap: 0` 的同类卡片：只差 1px，低于审计阈值（`>1`）所以一直没报。
  要分隔就用 `hairline()`。**判断法**：这个 `spacer` 后面还有子节点吗？有就不能用。
- **`stretch()` 会把竖排容器的“高”写死**：`layoutAlign:STRETCH` 落在**横排**父级里时，
  `applyLayout()` 会把子级的**主轴**（竖排＝高）设成 `FIXED`，冻结在那一刻的高度；之后再往里加内容
  就从底部溢出（实测 `body/detail/split/side/sideBody +50B h275/302`）。`card()` 内部会 `stretch()`，
  所以「这一栏不要被行高压短」这类修法**必须绕过 `card()`**，只在 `add()` 那一行去掉 `stretch` 是不够的。
- **1px 描边会把内容盒各收进 1px**：1040 的容器里，`STRETCH` 的子节点只拿到 1038
  （实测 `scene/bandWrap/Caption Band +2R w1040/1038`）。写死宽度的子节点要么按内宽算，
  要么干脆取得比它保守——子节点比父级窄不会溢出。
- **具名宽度落进「带前置兄弟」的固定宽行时，要先扣掉图标与间距**：`MENU_TEXT_W` 是整行内宽
  （`MENU_ROW_W` 278 − 两侧各 10 = 258），直接用在 `padX 10 + gap 7 + 图标 14` 的告警行上就是
  279 > 258，实跑报内溢。同形状的行要用扣除前置节点后的派生值（`MENU_TEXT_W_LEAD` = 237）。
  2026-09-18 静态复核发现：`menuPanel` 的 `warning` 行原先写死 220 时是够的，这一轮并成
  `MENU_TEXT_W` 才越界——**归一化的动作本身会制造溢出**，离线的三道门禁（no layout engine）
  都看不见，只有 Figma 实跑的 `inner overflow` 会报。
- **`frame()` 的 `w` / `h` 没有按轴映射**（只有 `comp()` 修过，见下面那条）：给竖向 frame 传 `w`
  会把**主轴**（高）设成 `FIXED` 并与 `resize(o.w, 40)` 打配合，得到一个 40px 高的框。
  目前没有调用点这么用（尺寸都走 `size()`），但改 `frame()` 的调用时要当心。
- **实跑报告是主要的定位工具，要让它读得全**：结论区一处一行、每行 ≤150 字符，并且每处都带上
  「从被审画板到溢出节点的完整路径 + 每一层的大小定位模式」——`+10B` 只说了多少，
  `row{V:AF|S}/notes{V:AF|S}/timeline{V:AF|S}/foot{T:H}` 才说得出是谁被写死的。
  单个 `<div>` 的文本在无障碍层不会被截断（被截断的是装计数行的那个 `<pre>`，约 250 字符）；
  一处里挤两处问题再切 60 字符，会让人白跑一轮（2026-09-18 实测：6 块板 12 处只读到 6 处半）。
- 越界审计分两层：根帧级 `auditOverflow()` 与父子级 `auditInnerOverflow()`；只做前者时卡片内部的溢出是看不见的。
- **面板与窗口的高度按内容取高**：固定高度在内容刚好合适时看不出问题，长一页就在卡片内部溢出，而根帧级审计看不见。
  同级多个外观（三个菜单面板、三个设置窗口）取最高值对齐，图上并排比较才不会有参差的底边。
- **每个 builder 都要把节点 `add()` 进父级**：漏一次就是画布上一个游离 frame。stray 顶层节点检查就是为这类遗漏加的。
- **`combineAsVariants()` 只重新挂载，不摆位**：变体停在创建时的同一个角上，集合看上去只有最上面那一个状态。
  `componentSet()` 因此自己按 `SET_W = 704` 换行摆放变体，并用 `gridCursor` 把每个集合沿列推下去，避免长高的集合压到下一个。
- **`comp()` 的 `w` / `h` 要按轴落到 `primaryAxis` / `counterAxisSizingMode`**：竖向框的主轴是高，
  把 `w` 当主轴会让变体停在 40px 高，第二行起被裁掉。两个轴每次都写，未指定的轴留 `AUTO` 才能 hug 内容。
- **auto-layout 子行要显式 `stretch()`**：`Candidate Tile/head`、`Code Block/codeHead` 自己 hug 时，
  里面 `spacer()` 推不动右对齐的 `seed` 和复制按钮。
- **CJK 要在生成器里显式套字体**：Inter 不承载中文，Figma 的缺字回退在刚重建的文档里未热时会把中文导出成空白
  （拉丁文照常）。`loadCjkFont()` 从可用字体里挑一个 CJK 家族，`applyCjkFont()` 只给 CJK 区段套上；
  运行报告里的 `CJK runs:` 就是这次选中的家族。
- **同一个视觉角色只允许一个数字**：闭环稿的会话侧栏原来在稿上有三个值（320 / 420 / 300），而应用侧只有
  `Layout.inspectorColumnWidth = 360` 一处声明，几种说法不能同时成立。稿侧现在归一为 `main.js:81` 的
  `const SESSION_SIDE_W = 360`（15 处列宽引用它），并在 `NUMBER_TOKENS` 里登记 `size/inspector`(360)——
  以后改会话侧栏宽度**只改这一行**，跟随它的内宽（`SESSION_SIDE_W - 32` 等）会一起走。
  同一类问题还剩**目录列**没归一（260 / 240 / 232 / 272，应用侧 `Layout.modelProfileListWidth = 280`），
  它连着一串跟随列宽的数值（搜索框 228/208/200、列表行折行宽 156/148、脚注 208/200），
  本轮**不动**，见 `../2026-09-17-live-sessions/SESSIONS-SPEC.md` §13.1 的 D10。
- **导出面板按“上次用过的目录”落盘**：`⌘⇧G` 输入目标目录再 `Return` 只是把面板切到该目录，
  必须等「位置：」显示目标文件夹后再点 `Save`，否则文件会写进上一个目录（曾因此落到 `~/Downloads` 根目录）。
- **多选可以一次导出**：选中若干帧后右侧按钮会变成 `Export N layers`，各帧按自己的 export 设置（4x PNG + SVG）一次落盘，
  比逐帧点省事；目标目录里若已有同名文件，macOS 会弹覆盖确认，先清走旧文件更省事。

键帽、键值行与 Inspector 取值对齐统一走 `kbd()` / `kbdInRow()` / `kvRow()`，不要在页面里手写这几个形状。

## 每条会话屏都要守的三条规矩（2026-09-18 第七轮）

这三条是评审里反复出现的那一类问题的出口，改会话屏之前先读一遍：

1. **同一个动作在屏上只画一次。** 主动作画在页头；`conclusionBand()` 在**就绪态不带主动作**，
   只在受阻与「需要你选一条路」时带按钮。右栏（inspector）也不重复页头与状态带的动作——它是
   当前状态的摘要，不是第二个动作区。这条规矩由 `smoke.js closures` 守（断言「42 块闭环屏的
   动作没有重复」），改文案时它会替你拦住重复。
   - 允许的例外：**同一个重复容器里的行**（断法表逐行给同一个出口是有意的），以及
     **页级动作 + 组件内动作**（会议页的「重新生成纪要」与行内编辑器的「保存」、对话页的
     「结束对话」与合成器的「发送」）——机器分不出这两种与「两个相互竞争的入口」的区别，
     所以前者按容器形状放行、后者只查重复文案。
2. **用户可见文案里不出现实现词。** 词表与替换见
   [`SESSIONS-SPEC §16.8`](../../2026-09-17-live-sessions/SESSIONS-SPEC.md)；`档位`（light / balanced /
   quality）是唯一保留的技术说法，且必须配一句人话说明后果。改完用一条检索兜底，别靠记忆：

   ```bash
   rg -n "prompt|系统提示词|Bundle ID|服务端|PCM|VAD|AEC|EOF|全双工|tap|preset|数据库|记录窗|分人" main.js
   ```

   命中的位置要么改掉，要么确认它在**规格板**（`closureXxxBoard()` 那几块）或**代码注释**里——
   那两处是给设计者与实现者看的，技术说法在那里是对的。
3. **术语只有一套。** 资产是「记录」（对话记录 / 会议记录 / 字幕记录），放记录的地方是「记录库」；
   检查器标题跟着类型走（本次对话 / 本次会议 / 本次字幕）。同一个东西在稿里出现两个名字，编码时
   就会变成两个模型。

侧边栏「会话」分组里那句定位语（`buildShell` 的 `groupNote`）属于第 1 类问题的解法：三个能力是
同级项，用户必须能在原地知道该用哪个。它常驻，不写在某一页的说明卡里。

## 约束

- Figma **免费版每个变量集合只允许 1 个 mode**。因此深色外观不是 mode，而是克隆浅色画板后逐节点改绑到
  `SpeechRail (Dark reference)` 集合。生产实现应使用真正的 Light/Dark 双 mode（见 `../REDESIGN-SPEC.md` §11.6）。
- 插件环境取不到 SF Pro，画板使用 `Inter`；生产 UI 使用系统字体。
- 给 paint 绑定变量必须用 `figma.variables.setBoundVariableForPaint`；`node.setBoundVariable("fills", …)`
  对 paint 字段无效且异常会被静默吞掉，表现为所有填充停在占位灰 `#808080`。
