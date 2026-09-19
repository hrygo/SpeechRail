---
title: "SpeechRail Figma 稿优化 · 独立团队交接文档"
status: active
audience: "接手 Figma 稿优化的独立设计团队（含其执行代理）"
version: "1.0.0"
date: 2026-09-18
---

# SpeechRail Figma 稿优化 · 独立团队交接文档

**本文件只登记事实、出处、操作步骤与未决项，不含设计倾向意见。** 凡涉及「该不该做」「选哪个值」
这类判断，都在第 9 节里指向它的出处与决策人，由本文件之外的决策产生。

下文所有数字与状态都标注了**核实时间**。本文件的核实时间为 **2026-09-18**；若与 `docs/` 其他
文档冲突，以第 3 节的冲突顺序为准。

---

## 1. 交接范围

**接手范围**：Figma 稿本身的继续优化——改生成器、重出插件产物、在 Figma 桌面版重跑、按需导出、
以及稿上的文档同步。

**不在接手范围**（各有归属，本文只做指针）：

| 事项 | 归属与出处 |
|---|---|
| macOS App（SwiftUI）实现 | `macos/SpeechRailApp/`、`docs/developers/macos-app-*.md` |
| 本机 ASR/TTS 服务与契约 | `src/speechrail/`、`contracts/` |
| 会话数据模型（SQLite）与落地阶段 | `docs/design/2026-09-17-live-sessions/SESSIONS-SPEC.md` §15、`docs/design/2026-09-18-session-layer/TECHNICAL-DESIGN.md` |
| 用户旅程与验收判据 | `docs/design/2026-09-17-live-sessions/SESSIONS-SPEC.md` §16、`docs/design/2026-09-17-session-closures/USER-JOURNEYS.md` |

**决策人**：用户（本仓库的所有者）。接手的团队是执行方；稿上的产品与视觉取舍由用户裁决。

---

## 2. 现状速览（核实时间 2026-09-18）

稿是「生成器路线」：Figma 文档是**产物**，`main.js` 是**源码**（见第 4 节）。

| 稿 | Figma 文件 key | 分页 | 画板 | Development 菜单里的插件名 | 与生成器是否同步 |
|---|---|---|---|---|---|
| **会话闭环稿**（当前主线） | `sAPdzrT2zsxqLtJhUx4iVC`（桌面标签名被用户改为 `Sona2Speech`） | `01 闭环` | Figma 里 **53 块**；生成器已是 **59 块** | `SpeechRail Closure Kit` | **否**：第八/九/十轮已改生成器并通过离线门禁，未在桌面端重跑 |
| **全量稿**（已交付过一版） | `x5Ke0tKe9adeov4NG5baxP`（标签名 `SpeechRail`） | `01 Kit` + `02 Screens` | **48 块** | `SpeechRail Design Kit` | **否**：两稿共用的屏（语音助手、会议页、设置面板）内容已变，未重跑 |
| 上一代界面稿（历史） | `7wZpCvjTTdfn4hMDMdcmRk` | — | 26 块 | 同 kit 的早期版本 | 历史文件，不再维护 |

上表的证据分级：闭环稿的「Figma 里 53 块」是 **2026-09-18 12:38 实跑报告的读数**；全量稿的
「48 块」来自它 **2026-09-17 的实跑记录**（2026-09-18 只读复核了它的分页结构，确认仍是
`01 Kit` + `02 Screens`、没有出现 `01 闭环` 页，未逐块点数）。

账号与环境事实：

- 三个文件都在**用户的个人 Figma 账号**里（免费版 Starter）。**团队需要用户授予编辑权限**，
  或由用户另定文件的所有权/共享方式——这一步在交接之外，由用户决定。
- Starter 版限制：**每个文件最多 3 页**。当前闭环稿占 1 页（`2 free pages left`），全量稿占 2 页。
  生成器会违反这条限制时会在运行中报 `The Starter plan only comes with 3 pages`。
- 生成器与产物**都在仓库外**：稿的源码在仓库里（`docs/design/2026-09-15-macos-uiux-redesign/figma-kit/`），
  插件产物落在 `~/Downloads/`（见第 4 节）。

---

## 3. 权威来源与冲突顺序

1. **当前代码、测试与实际运行结果**（含 `figma-kit/` 的生成器与门禁实测输出）；
2. `main.js` ——**稿的唯一源码**。改稿改它，Figma 文档是它的产物；
3. `contracts/`（公共接口）与标 `active` 的 `docs/` 文档；
4. `docs/archive/`：仅供历史追溯，**不能**证明当前能力。

报告与文档里的每条结论都要区分**契约声明 / 当前实测 / 历史记录 / 推断**，时效性结论带核实日期。
本仓库既有文档已按这个口径写，接手后请沿用。

---

## 4. 稿是怎么生成的（改稿前必读）

### 4.1 一条硬规矩

**不在 Figma 里手改任何节点。** 稿由生成器重建：生成器每次运行会**清空并重建**目标页的画板，
在 Figma 里手工补的东西下一轮就消失，而且无法评审、无法回退。改稿的正确路径是
「改 `main.js` → 跑门禁 → 重出产物 → 在 Figma 桌面版重跑插件」。

### 4.2 目录与文件

| 路径 | 责任 |
|---|---|
| `docs/design/2026-09-15-macos-uiux-redesign/figma-kit/main.js` | 稿的源码（~400 KB，含全部画板与文案） |
| `…/figma-kit/icons.js` | 图标几何（内联 SVG，来源 Lucide 1.17.0，ISC 许可） |
| `…/figma-kit/build.js` | 合成**全量稿**的 `code.js` → `~/Downloads/SpeechRail-figma-kit/` |
| `…/figma-kit/build-closures.js` | 合成**闭环稿**的 `code.js` → `~/Downloads/SpeechRail-closure-kit/` |
| `…/figma-kit/audit.js` | 静态自检：颜色 / 文本样式 / 图标 / 图标描边色的引用是否悬空 |
| `…/figma-kit/smoke.js` | 在**替身 API** 上跑一遍：页面预算、导出设置、深色改绑、游离节点、结构断言 |
| `…/figma-kit/check-links.js` | 闭环稿专用：按文案找回连线源控件，改名会**静默**少一条连线 |
| `…/figma-kit/stub-figma.js` | `smoke.js` 用的替身（**没有布局引擎**，几何不可信） |
| `…/figma-kit/README.md` | 生成器约定、页面与排布、容易踩的点（改稿前读一遍） |
| `…/figma-kit/manifest.json` | 全量稿插件的 manifest（`name` = `SpeechRail Design Kit`） |

两个 kit 共用同一个 `main.js`：`SPEECHRAIL_SCOPE = "closures"` 时只生成闭环那一段。

### 4.3 生成里已经固定下来的几件事

- **页预算、组件集归属、每块画板的导出设置（PNG@4x + 保留文字的 SVG）**都写在生成器里并断言，
  不靠人在 Figma 里补。
- **深色**不是第二套变量：同一个变量集合的两个 mode，每块画板的深色克隆逐帧显式指向 Dark mode。
- **连线**只能建在「同一页的顶层 frame」之间；跨页导航无法自动生成，所以闭环稿把三组内容压在
  同一页上（第 2 节的页数与这条有关）。
- **字体**：正文用 `Inter` 表达 SF Pro 的层级关系，CJK 走 `PingFang SC`（回退链写在 `main.js` 里）。
- **数值收敛在少数声明点**：同一语义的数值只在一处声明（例如会话侧栏列宽只有一个常量，
  搜索框宽度、列表折行宽都跟着它走）。改宽度先找那个声明点。

### 4.4 当前产物指纹（核实时间 2026-09-18）

| 产物 | md5 | 大小 |
|---|---|---|
| `~/Downloads/SpeechRail-closure-kit/code.js` | `05fd71d3fbf5392cedeee8a4fd9f147d` | 352,564 字节（第九轮版，对应 59 块） |
| `~/Downloads/SpeechRail-figma-kit/code.js` | `7ee741ce27ff8d10d5375248601b6259` | 352,529 字节（全量稿，对应 48 块） |

重跑 `build*.js` 即可再生；**md5 变了就说明源码变了**，交接与复核都以 md5 为准。

---

## 5. 离线门禁（不需要 Figma；每次改稿后必跑）

```bash
cd docs/design/2026-09-15-macos-uiux-redesign/figma-kit
node --check main.js                 # 语法
node audit.js                        # 必须打印 audit: clean
node smoke.js closures               # 闭环稿：结构断言全过 → SMOKE OK
node smoke.js full                   # 全量稿：结构断言全过 → SMOKE OK
node check-links.js                  # 闭环稿：声明连线源全部解析到 → CHECK OK
node build-closures.js               # 合成产物；会打印 built -> <目录>/code.js
md5 -q ~/Downloads/SpeechRail-closure-kit/code.js
```

**判据**：前五条必须全过，任一条失败不要打开 Figma——在客户端里试错比在这里改脚本贵。
**注意**：`smoke.js` 不检查几何（替身没有布局引擎），所以它报的 overflow 计数没有意义；
「摆位对不对」只能由一次真实实跑证明（第 6 节）。

**当前实测（2026-09-18，第九轮）**：`node --check` 通过；`audit: clean`（颜色 23 / 图标 41 引用
45 定义 / 文本样式 11）；`smoke.js closures` → 59 板 / 29 深色 / 233 连线 / 48 块屏动作无重复；
`smoke.js full` → 48 板 / 478 连线 / 21 深色；`check-links.js` → 52 条声明连线源全解析。

---

## 6. 在 Figma 桌面版重跑（**需要当次授权**）

### 6.1 授权边界（硬约束，不改）

接管 Figma 窗口、焦点、菜单与输入属于**按次授权**的动作：必须由用户**当次明确要求**才可以执行。
skill、SOP、README、CI 文档或交接包里的「必须运行」都不构成授权。未获授权时，工作停在第 5 节
（离线门禁 + 产物），并在结果里写明「未实跑」。

### 6.2 前置

- **Figma 桌面版**（网页版没有 `Plugins → Development`）。
- 插件目录第一次要在每个文件里经 `Import plugin from manifest…` 指到 `manifest.json`；
  之后 Development 子菜单里就能直接看到。**两个插件名必须保持唯一**（辅助函数按名字匹配菜单项，
  同名会跑错 kit）。

### 6.3 步骤

1. `node build-closures.js`（或 `build.js`）重出产物；
2. 打开目标文件，**按 file key 核对**（不要按标签名匹配——见 6.5 的第 1 条）：
   闭环稿 `sAPdzrT2zsxqLtJhUx4iVC`，全量稿 `x5Ke0tKe9adeov4NG5baxP`；
3. 确认分页与板数（第 2 节）；
4. `Plugins → Development → Hot reload plugin`（改了源码之后每轮都先热重载）；
5. `Plugins → Development → <插件名>` 运行；
6. 报告面板出现后**立刻把关键行抄进交接包**——报告既在面板里也会弹成一条通知，两处都会被
   后续动作覆盖。

### 6.4 报告怎么读

| 行 | 含义 | 不合格时 |
|---|---|---|
| `AUDIT VERDICT` | 总判定（`all clean` / 非零计数） | 逐行找非零项，每条要么修生成器，要么登记为已知偏差 |
| `bind errors` / `export errors` | paint 绑定失败 / 导出设置写入失败 | >0 时会出现占位灰或导出为 `0 of 0 selected` |
| `stray top-level` | 顶层游离节点 | >0 说明有节点漏 `add()`，导出会缺内容 |
| `root overflow` / `inner overflow` | 根溢出 / 内部溢出 | >0 就是摆位问题，改 `main.js` 重跑 |
| `boards` / `dark boards` | 画板总数 / 其中深色克隆 | 深色应为总数减去不成对的板（总览等） |
| `prototype links` | 连线成功数 | 失败原因写在括号里（`failed 1: <源> -> <目标>: <原因>`） |
| `cjk runs` | 套用的 CJK 家族 | 显示 `none` 说明本机没有可用 CJK 字体，中文会空白 |

### 6.5 已经踩过的坑（实测，交接前必读）

1. **别按标签名找文件**：同一账号里存在两个标签名相近的文件（`Sona2Speech` 与 `SpeechRail`），
   按标签名匹配曾经把插件跑进了另一个文件。**用 file key 核对**。
2. **改了源码但报告一模一样**：Figma 没有重新读 `code.js`。先 `Hot reload plugin` 再运行。
3. **切页要点页名按钮，不要点行**：点行的落点常在行内空白上，不切页也不报错。判据也不能用
   「页名出现在无障碍文本里」——Pages 面板本来就列着所有页名，那个检查恒真。
4. **不要凭坐标点画布**；一律走无障碍索引，且每次动作后索引会漂移，取状态与点击要写在同一批
   调用里。
5. **报告里出现 `err` 步骤**：只重跑插件，不要在 Figma 里手工补。

### 6.6 可脚本化的宿主

本机此前用 computer-use 插件的 `cua_repl`（`getAXState` / `click` / `pressKey` / `setValue`）。
换宿主需要改的是这些接口调用，步骤与判据不变。现成辅助函数在
`~/.agents/skills/figma-to-macos/assets/figma-ops/repl-helpers.js`
（`axLines` / `clickByText` / `runDevPlugin` / `readPluginReport` / `closePluginPanel` 等）。
**该 skill 目录只读参考，不要修改。**

---

## 7. 导出

### 7.1 现状：用户明确「先不导出」

2026-09-17 起用户的指示是「先不导出，进一步核查设计稿与文档」。因此**当前 53 板 / 57 板都没有
对应导出物**；第 6 节的实跑与第 7 节无关。要不要导出、什么时候导出，由用户决定（见第 9 节）。

### 7.2 已有的导出物（历史，可作对照与回退点）

| 目录 | 内容 | 核实时间 |
|---|---|---|
| `~/Downloads/speechrail-sessions-export/` | 48 块画板 × (PNG@4x + SVG) = 96 个文件 | 2026-09-17 |
| `~/Downloads/speechrail-closure-export-v1/` | 35 块画板 × 2 = 70 个文件（第一次交付审查用，保留作回退点） | 2026-09-17 |
| `~/Downloads/speechrail-figma-export/` | 52 个文件 | 更早批次 |
| `~/Downloads/speechrail-closure-export/` | **空目录**（一次导出在保存面板未起来时被锁屏打断） | — |

### 7.3 导出与核验

SOP：`~/.agents/skills/figma-to-macos/references/figma-app-export-sop.md`。
核验脚本：`~/.agents/skills/figma-to-macos/scripts/verify-exports.sh <目录> <画板数> 4`
（判据：成对、尺寸为画板整数倍、无 `<image>`、无 0 字节、整批 SVG 含 `<text>`）。

两条实测注意：

- 生成器**幂等但每次都是清空重建**，画板会拿到新 node id，而 Figma 把 node id 写进 SVG 的
  `id="…_9_59291"`，所以 **SVG 的 md5 每次都会变**。判「是不是同一版」用 `boards=` + PNG md5 +
  `verify-exports.sh`，不要用 SVG md5。
- 保存面板要先确认它在前台，再发前往文件夹的快捷键；否则按键会落到画布上。

---

## 8. 稿里现在有什么（资产清单）

### 8.1 闭环稿（`01 闭环`，Figma 里 53 块 / 生成器 57 块）

- **屏幕 23 块**：语音助手（未开始 / 对话中 / 对话中·右栏收起 / 未配置模型 / 实时对讲 /
  换音色 / 记忆 / 记录库）、会议助手（空态 / 录制中 / 内心 OS / 整理中 / 中断 / 已归档 /
  会话占用）、实时字幕（未开始 / 回看中 / 刚结束）、设置·会话、菜单栏、分人共用链路、
  换音色 vs 换人设（对比板）、非主框体·收起规则（规则板）。
- **浮层 5 块**：字幕带的跟随中 / 回看 / 大字 / 受阻 / 贴在画面上（在用时）。
- **总览 1 块**：三条泳道 + 状态演进 + 固定/可变划分 + 「旅程还会走到这里」。
- 除总览外，屏幕与浮层各有一份**深色克隆**（生成器 57 块里含 28 块深色）。

### 8.2 全量稿（`01 Kit` + `02 Screens`，48 块）

`01 Kit` 3 块（Cover / Foundations / Components）+ `02 Screens` 45 块，21 块带深色克隆，
478 条原型连线。

### 8.3 文档地图

| 想查什么 | 去哪 |
|---|---|
| 会话三能力的逐面规格、状态矩阵、SQLite 数据模型、用户旅程 | [`SESSIONS-SPEC.md`](../2026-09-17-live-sessions/SESSIONS-SPEC.md) |
| 稿的交付口径、逐轮 delta、已知偏差、走查清单 | [`HANDOFF.md`](../2026-09-17-session-closures/HANDOFF.md) |
| 实现就绪度、离线门禁记录、实现侧要求 | [`IMPLEMENTATION-READINESS.md`](../2026-09-17-session-closures/IMPLEMENTATION-READINESS.md) |
| 角色与情境、缺口表、可测判据 | [`USER-JOURNEYS.md`](../2026-09-17-session-closures/USER-JOURNEYS.md) |
| 视觉基线（token、窗口、工具栏、控件规范） | [`REDESIGN-SPEC.md`](../2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md) |
| 生成器约定与踩坑 | [`figma-kit/README.md`](../2026-09-15-macos-uiux-redesign/figma-kit/README.md) |
| 服务与 App 的技术归属（哪些归原生、哪些归 Python） | [`TECHNICAL-DESIGN.md`](../2026-09-18-session-layer/TECHNICAL-DESIGN.md) |

---

## 9. 未决项（只登记，不给意见）

下表是当前**没有结论**的事项。每行的「已记录的说法」只是文档里已有的文本，不代表本文档的
推荐；决定权在用户（除注明「实现阶段」的两条，它们归实现侧验证）。

| # | 事项 | 已记录的说法与出处 | 状态 | 决策人 |
|---|---|---|---|---|
| 1 | 目录列宽度是否归一（会议 260 / 字幕记录库 240 / 助手记录库 232 / 开发者文档 272） | 第九轮已统一声明 `SESSION_LIST_W = 280`，搜索框（248）、折行（196）、脚注（248）同心对齐 | 已落地 | 产品经理 + 用户 |
| 2 | 目录列是否也支持收起 | 第九轮已纳入非主框体清单（`⌘⌥S` / 系统内侧栏规范，按屏记忆）并提升为 `Ready` | 已落地 | 产品经理 + 用户 |
| 3 | `⌘⌃I`（面板收起）的真机快捷键冲突 | `SESSIONS-SPEC.md` §18.5 标为未验证；`⌥⌘I` 已被「显示开发者详情」占用 | 待实现阶段验证 | 实现侧 |
| 4 | 会话页首次启动是否补一块独立空态板 | 第九轮已补齐出板 `会话 · 首次使用 · 空态引导（三能力起点）` 及 1:1 深色克隆，板数 57 → 59 | 已落地 | 产品经理 + 用户 |
| 5 | 全量稿（48 板）是否重跑对齐 | 两稿共用屏（语音助手、会议页、设置面板）已随闭环稿改动而变化 | 待裁决 | 用户 |
| 6 | 第八轮 / 第七轮改动后的几何复核 | 生成器已改、离线门禁全过，但**未在 Figma 实跑**（`HANDOFF.md` 第八轮 delta） | 待执行（需当次授权） | 执行方 + 用户 |
| 7 | 导出批次、格式与命名 | 当前指令是「先不导出」；导出时应核对项写在 `HANDOFF.md` | 待裁决 | 用户 |
| 8 | 系统音频取音（process tap）的真机验证 | `HANDOFF.md` 已知偏差 6：只做了 SDK 取证，没跑过真机 tap | 待实现阶段验证 | 实现侧 |
| 9 | 面板收起态的按屏记忆 vs 现有全局开关 | `IMPLEMENTATION-READINESS.md` §8.4 要求拆成两个（面板按路由、开发者详情全局） | 待实现阶段落地 | 实现侧 |

---

## 10. 不可协商的约束

这些是项目既有的工作约定，接手后继续有效：

1. **UI 自动化按次授权**：任何会接管前台窗口、焦点、输入或屏幕的操作，必须由用户当次明确要求。
2. **稿只在生成器里改**；不在 Figma 里手工补节点。
3. **只读参考目录不要改**：`~/.agents/skills/**`、`native/diarization/.build/checkouts/**`。
4. **不进仓库**：模型、音频、日志、导出物、构建产物、`.env`、密钥、benchmark 原始数据。
   凭据写入钥匙串，不接受明文进配置文件。
5. **秘密不进日志/报告/命令参数**：日志与报告不记录密钥、完整转写、实名 speaker、绝对模型路径。
6. **改动范围最小化**：只改完成任务必需的文件；保留其他人的未提交改动；遇到同一处的并行改动
   先只读核实来源与范围，不要覆盖或「还原」。
7. **一个 commit 一个逻辑主题**，消息用 `<type>: <why>`；提交前检查 staged diff 与
   `git diff --staged --check`；不 force-push，不覆盖他人分支。
8. **结论必须与证据一致**：区分契约声明 / 当前实测 / 历史记录 / 推断；时效性结论带核实日期；
   文档与实测冲突时报告差异，不静默按文档改配置。
9. **文档 front matter 的 `version` / `date` 只在正文实质变化时更新**。

---

## 11. 交接核对清单（接手第一天可逐条走）

- [ ] 能打开第 2 节的两个 file key，且分页与板数与表里一致；
- [ ] 跑完第 5 节的五条离线门禁，把输出（含 md5）记进你方的工作记录；
- [ ] `~/Downloads/SpeechRail-closure-kit/` 与 `~/Downloads/SpeechRail-figma-kit/` 存在，
      且 Development 菜单里两个插件名都能看到；
- [ ] 读一遍最近一次 Figma 实跑报告（`HANDOFF.md` 的「Figma 实跑报告（2026-09-18 12:38）」）
      与第 6.4 节的报告字段表；
- [ ] 与用户确认**授权方式**（谁在什么时候说「跑」）与**文件访问权限**（是否已授予编辑权）；
- [ ] 确认仓库当前未提交改动（第 12 节），不要把它们当成自己的改动提交或回退。

---

## 12. 当前工作区状态（核实时间 2026-09-18）

仓库：`/Users/hrygo/Documents/SpeechRail`，分支 `main`，本地领先 `origin/main` **3 个 commit**
（`e37e986a` chore(figma)…、`01ca5d0a` docs(ops)…、`5a7dd307` docs(sessions)…），**未推送**。

**未提交的改动**（属于本次交接前的工作，接手的团队请当作既有改动保留）：

| 文件 | 内容 |
|---|---|
| `docs/design/2026-09-15-macos-uiux-redesign/figma-kit/main.js` | 第八轮：`sideToggle` 构件 + 16 块画板挂载 + 两块新板 + 总览第 5 行 |
| `…/figma-kit/icons.js` | 新增 `sidebar-right` 图标（Lucide `panel-right` 几何） |
| `docs/design/2026-09-17-live-sessions/SESSIONS-SPEC.md` | 新增 §18「非主框体：可以收起的面板」；版本 → v1.9.0 |
| `docs/design/2026-09-17-session-closures/HANDOFF.md` | 第八轮 delta + 实跑报告 |
| `docs/design/2026-09-17-session-closures/IMPLEMENTATION-READINESS.md` | §8.4 第八轮实现要求；版本 → v1.4.1 |
| `docs/design/2026-09-17-session-closures/README.md` | 状态与板数；版本 → v1.7.0 |

**未跟踪**：`macos/SpeechRailApp/SpeechRailApp.xcodeproj/xcuserdata/`（用户的 Xcode 状态。
`.gitignore` 第 29 行的 `*.xcodeproj/xcuserdata/` 带斜杠被锚定到仓库根，匹配不到子目录，
所以它没被挡住——这是已知的一条忽略规则缺口，改动它属于仓库维护，不在稿的范围内）。

---

## 13. 回退与恢复

| 对象 | 回退方式 |
|---|---|
| 稿（生成器） | `main.js` 的改动都在 git 里；`git diff` 可见，重跑 build + 插件即回到上一版（生成器是幂等的：重跑清空并重建目标页的画板） |
| Figma 文档 | 文件菜单 → `Show Version History`（云端文档，可回到运行前的版本） |
| 导出物 | 上一批目录即回退点（第 7.2 节）；导出物是生成物，可整目录删除后重导 |
| 插件包 | `~/Downloads/**-kit/` 全部可再生：`node build.js` / `node build-closures.js` |

---

## 附：常见故障速查（摘自 Figma 运行 SOP）

| 症状 | 处置 |
|---|---|
| 菜单/面板没反应 | 先 `Escape`，再重读无障碍状态；菜单开着时不要点画布，否则会落到别的画板 |
| 误关掉文件标签 | 文件是云文档、插件改动已保存：Home → Recents 重新打开，选页继续，**不要重新导入插件** |
| 报告里有 `err` 步骤 | 只重跑插件，不在 Figma 里手工补 |
| `The Starter plan only comes with 3 pages` | 生成器超页预算：把内容平铺到更少的真实页，**不要删用户页面、也不要升级席位**（除非用户决定） |
| 改了 `main.js` 也跑了 build，报告却与上一轮一模一样 | Figma 没重新读 `code.js`：`Plugins → Development → Hot reload plugin`，再运行 |
| 通知里是 `BUILD FAILED: 没有可用页位…` | 生成器在动手前就停了，稿没被改坏：腾一张空页或删掉不再需要的页再重跑 |
| Development 里报 `Plugin missing` | 插件目录被清理或 manifest 路径变了：重新 `Import plugin from manifest…` |
| 画布上中文空白（拉丁文正常） | 生成器要显式加载并套用 CJK 字体（`main.js` 的字体一节）；不要指望缺字回退 |
| 画板里内容少了/叠在一起 | 生成器缺陷：改 `main.js` 重跑，**不要**在 Figma 里挪 |
