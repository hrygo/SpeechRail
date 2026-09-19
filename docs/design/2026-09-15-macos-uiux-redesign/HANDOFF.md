# SpeechRail macOS App · 设计交付交接包

> 后续修订：2026-09-17 的「实时会话模块」在同一份稿与同一个生成器上增补了 22 块画板（会话屏幕 7 ×
> 浅/深 + 字幕带浮层 4 × 浅/深），稿现在是 **48 块画板**；本文件描述的 26 块画板与其导出物是
> 2026-09-16 那一版的状态。当前版本见
> [`../2026-09-17-live-sessions/HANDOFF.md`](../2026-09-17-live-sessions/HANDOFF.md)。
> 本文件里的 `Flows: overflow → step · 试听与使用+30` 已在 2026-09-17 修掉（画板 1680 → 1840）。
> 同一天另开了一份**按路径组织**的第二份稿（只画三个会话能力的闭环，当前 **53 块画板**，页 `01 闭环`）：
> [`../2026-09-17-session-closures/HANDOFF.md`](../2026-09-17-session-closures/HANDOFF.md)。它用同一个
> 生成器加 `SPEECHRAIL_SCOPE = "closures"`，**不影响**本文件描述的全量稿（`smoke.js full` 仍是 48 板 / 478 连线）。

生成时间：2026-09-16 18:10 CST（本节更新：音色克隆与开发者文档两页 + 稿已在 Figma 桌面版真跑）
本次轨道：**B（代理 / 自定义 provider）**
轨道证据：`codex doctor --all`（2026-09-16 16:49）→ `default model provider cliproxyapi`，
且 feature flags 里 `tool_search_always_defer_mcp_tools` 处于开启状态；本会话可用工具里
没有 `mcp__codex_apps__figma_*`，也没有 `tool_search` 出口。判定时间 2026-09-16 16:49。

## 权威来源

| 层 | 位置 | 说明 |
|---|---|---|
| 稿的源码 | `figma-kit/main.js`（`build.js` 合成 `code.js`） | 改稿改这里，不要在 Figma 里手改 |
| 稿的产物 | 用户的 Figma 文件 `Untitled`（Starter / Free 账号，**新建于 2026-09-16 17:54**）：`01 Kit` + `02 Screens` 两个页面、26 块画板，由 agent 在 Figma 桌面版运行插件生成（18:03）。插件包在 `~/Downloads/SpeechRail-figma-kit/`（`code.js` 180,770 字节，sha256 `17d17cf8…`） | 文件里没有更早的稿；`~/Downloads/speechrail-screens-4x/`（2026-09-15 22:04）是**上一代**导出，不含本轮两页 |
| 页面规格 | `REDESIGN-SPEC.md` §5 / §7 / §9 / §11.6 | §11.6 是逐轮实测与结案的账本 |
| 运行态事实 | `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` + 各页面 View | 代码实际使用的值 |

## Token 表

不在此重复：数值的声明点是 `SpeechRailDesignTokens.swift`，导出表在 `REDESIGN-SPEC.md` §11.3 与
`docs/developers/macos-app-design-system.md`（同一语义只允许一处声明）。

## 导出物

本轮 26 块画板全部导出到 `~/Downloads/speechrail-figma-export/`：52 个文件（26 × PNG + 26 × SVG），
共 24 MB。**52 个文件都来自同一次构建**（插件 2026-09-16 19:16 重跑，导出 19:17–19:25）；
18:20–18:38 那批是上一版渲染，已全部被取代。同名的 SVG 是矢量上限（无 `<image>`，文字已转轮廓），
可任意 DPI 重栅格化。

| 文件 | 倍率 | 尺寸 | 生成时间 |
|---|---|---|---|
| `01 Kit` 文档画板 3 块（`Cover` / `Foundations` / `Components`） | 4x + SVG | 6400 × 3600 / 6400 × 9504 / 6400 × 9600 | 19:18 / 19:25 / 19:17 |
| `02 Screens` 屏幕 20 帧（10 页 × Light / Dark，`▸ <页名>`） | 4x + SVG | 5760 × 3600 | 19:24 |
| 辅助画板 3 块（`Flows` / `Menu & Settings` / `Archive`） | 4x + SVG | 6840 × 4244 / 8576 × 5956 / 6720 × 3580 | 19:24 |
| 上一批帧（`~/Downloads/speechrail-screens-4x/`，1440 × 900 画板 → 5760 × 3600） | 4x | 5760 × 3600 | 2026-09-15 22:04 |

尺寸为 macOS `sips -g pixelWidth -g pixelHeight` 实测；画板尺寸各不相同（`Cover` 1600 × 900、
`Foundations` 1600 × 2376、`Components` 1600 × 2400、屏幕帧 1440 × 900、`Menu & Settings` 2144 × 1489），
所以 4x 之后的像素尺寸并不统一。

## 已核对

- 静态自检（2026-09-16 17:45）：`node docs/design/2026-09-15-macos-uiux-redesign/figma-kit/audit.js`
  → `audit: clean`（colour 23/23、icons 31/34、text styles 9/9 全部解析到；未用图标 3 个：
  trash-2 / pencil / x）；`node --check figma-kit/main.js` → 通过。
- 生成器打包可复现（2026-09-16 17:45）：同参数重跑 `node figma-kit/build.js`，`code.js` 哈希不变。
  页面重排后又打包一次（18:02:07）：`~/Downloads/SpeechRail-figma-kit/code.js` 现在 180,770 字节、
  sha256 `17d17cf89112c32a7a3c5f664983ae3eeddb781b49eb4fdcccd3bcf21ab4fef3`，与 `main.js` 同源。
- Figma 真跑（2026-09-16 18:03）：报告面板 `10 screens · 26 frames
  (Kit 3 · Screens 23)`、`prototype links: 198/198`、`bind errors: 0`、14 个步骤全 `ok`；
  目视核对（18:05–18:09）`01 Kit` 三块并排、`02 Screens` 浅/深两列 + Flows / Menu & Settings / Archive。
  **唯一未过项**：`Flows: overflow → step · 试听与使用+30, detail+16`（见「已知偏差」）。
  第一次运行失败的原因与修法见 `REDESIGN-SPEC.md` §13.6 下半张表（Starter 版 3 页上限）。
- 类型 / 编译（2026-09-16 17:38–17:41）：`plutil -lint …project.pbxproj` → OK；
  `scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`；
  `xcodebuild -scheme SpeechRailApp build-for-testing` → `** TEST BUILD SUCCEEDED **`（**只编译，未运行测试**）；
  构建产物 Info.plist 含 `NSMicrophoneUsageDescription`（三处 `INFOPLIST_KEY_` 是唯一声明点）。
- 口径取证（2026-09-16，本机 `quality` 服务）：`curl -H 'Accept: application/json' http://127.0.0.1:8201/metrics`
  → 1188 次累计请求中 1159 次是控制面轮询；`workers = {asr: cold_evicted, tts: cold_evicted,
  streaming: cold_evicted}`；`physical_footprint_complete = false`。运行监控本轮的口径改动以此为准。
- 导出（2026-09-16 18:20–18:38，桌面驱动，用户本轮 `@电脑` 授权）：52 个文件全部落盘，`sips` 实测尺寸
  与上表一致。**一致性核验**：修完生成器重跑插件后，重新导出一份 `Cover` 与 18:29 的文件比对，
  `md5` 完全相同（`Cover.png` `cf7b1102d4105461d4503782833d328e`、`Cover.svg` `1a3e44bc8b17a1efbe6203182d47e818`），
  说明重建前后渲染逐字节一致，18:20 导出的其余 24 帧无需重导。重跑自身的报告：
  `26 frames (Kit 3 · Screens 23)`、`prototype links: 198/198`、`bind errors: 0`，未过项见「已知偏差」。
- 离屏量测：**未覆盖**（理由见下）。
- 第二轮生成器修复与重导（2026-09-16 18:40–19:25，桌面驱动，用户本轮 `@电脑` 授权）：核查 18:38 那版
  `Components` 导出时发现三处生成器缺陷，改 `figma-kit/main.js` 后重跑插件并**重导全部 26 块画板**。
  ① `combineAsVariants` 只重新挂载、不摆位，16 个组件集的状态全叠在同一像素（Status Pill 的 5 个标签
  互相压字、Profile Card 只露出不透明的那一个变体）→ `componentSet()` 自己按 704px 换行摆放，
  并按列游标 `gridCursor` 落位，越界的集合把下一个往下推；② `comp()` 把 `w` 当主轴，竖向变体被固定成
  40px 高，第二行起被裁掉（Profile Card 说明、Empty State 标题与正文都缺）→ 按轴写
  `primaryAxis/counterAxisSizingMode`；③ `Candidate Tile/head` 与 `Code Block/codeHead` 没有拉伸，
  右对齐的 `seed` 与复制按钮浮在左边 → 改为 `add(c, stretch(head))`。另加 `loadCjkFont()` +
  `applyCjkFont()`：Inter 不承载 CJK，而 Figma 的缺字回退在新文档里未热时会把中文导出成空白
  （19:09/19:11/19:13 三次导出实测），现在中文段显式套 PingFang SC。重跑报告：
  `26 frames (Kit 3 · Screens 23)`、`prototype links: 198/198`、`bind errors: 0`、`CJK runs: PingFang SC`，
  未过项只剩既有的 `Flows: overflow → step`。`node --check` / `node build.js` / `node audit.js` 均通过。
  导出：23 个屏幕帧用「选中 23 个 → `Export 23 layers`」一次落盘，`Cover` / `Components` / `Foundations`
  单帧导出；画板尺寸未变（`Components` 仍 1600 × 2400），`sips` 实测与上表一致。
- 装机（2026-09-16 17:09，用户授权「安装，我来测试」，app-only）：`CFBundleVersion` 11 → 12
  （`MARKETING_VERSION` 仍 2.6.4）；`scripts/macos_app_build.sh --configuration Debug` →
  `** BUILD SUCCEEDED **`；`plutil -lint …com.speechrail.desktop.control.plist` → OK；独立
  DerivedData 出的 bundle 通过 `codesign --verify --deep --strict`（ad-hoc），内嵌
  `com.speechrail.desktop.local-control.xpc`。安装路径唯一（`~/Applications/SpeechRail.app`，
  `mdfind` 只有这一条），App pid 61520 + control helper pid 61522 在跑。
  **服务未被触碰**：8201 仍是 pid 99260 唯一 listener、`/readyz` 200、profile `quality`。
  回退点 `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-11-installed-20260916-1709.zip`
  （sha256 `617b592d91aa0b91f8ba3499cc3eaaa9d4893b1edb3bacb7eae7f23a0b394600`）。
- 装机 #2（2026-09-16 17:14，同一授权范围内修第六十四轮的空图）：`CFBundleVersion` 12 → 13，
  当前安装版本 **2.6.4 (13)**；App pid 68738 + control helper pid 68742；服务仍是 8201 上
  唯一 listener（pid 99260）、`/readyz` 200。回退点
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-12-installed-20260916-1714.zip`
  （sha256 `1e38db6ef3aa5e98b3d7b5d6419157c6f6d0a8c808b9b934102b2f7e4f2f634a`）。

## 未执行项与原因

- **PDF 导出**：用户 2026-09-16 18:1x 要求的是「所有页面导出为 SVG 和 4X PNG」，已按该范围完成
  （52 个文件，见「导出物」）；画板上的 export 设置现在只有 PNG 4x 与 SVG 两项，**没有 PDF**，
  需要 PDF 时再单独补。
- **Figma 插件重跑（轨道 B 限制仍在）**：连接器工具依旧不可用，写稿只能走生成器 + 人工/桌面驱动；
  本次是 agent 通过桌面操作代跑（17:54–18:09），之后每次改 `main.js` 都要重新 `node build.js`
  并再跑一次插件。
- **已安装 App 不含本轮两页**：`~/Applications/SpeechRail.app` 是 2026-09-16 17:14 安装的
  2.6.4 (13)，二进制构建于本轮代码之前，Info.plist 里没有 `NSMicrophoneUsageDescription`
  （`plutil -p` 实测）。音色克隆与开发者文档只在 17:40 那次 Debug 构建里编译通过；
  要验收 App 侧页面需要重新构建并安装——那是运行态变更，需当次授权。
- **离屏量测**：仓库里没有离屏渲染 harness（`REDESIGN-SPEC.md` 提到的 `--render` / `--hier` 等开关
  不在仓库代码里），本轮没有新建；因此「渲染出来的排版是否如预期」没有证据。
- **单元测试与 UI 自动化**：AGENTS.md 硬约束——UI 自动化须当次明确授权；单元测试按项目规则
  只在用户明确要求自动化验收时运行。本轮两者都没跑。
- **App 真机目视**：用户自行走查（「我来测试」）。**Figma 桌面版**是例外：用户在 2026-09-16 17:54
  明确要求「在 figma app 里看到设计稿」并 `@电脑`，agent 因此在桌面版里新建文件、运行插件、
  截图核对（17:54–18:09）；除此之外没有接管过任何窗口、焦点或输入。

## 已知偏差

| 位置 | 稿 | 实现 | 处置 |
|---|---|---|---|
| 运行监控首屏指标条 | `screenMonitoring` 没画指标条（只有 pageHead + 折线图卡 + 运行组件表） | 应用有六格：正在处理 / 语音合成 / 语音识别 / 合成耗时 / 识别耗时 / 失败请求 | 条文为准（§7.6）；稿侧尚未补画 |
| 运行监控图表 | 一张静态 SVG 折线（并发） | 两张图：同时处理的请求数 + 每次语音的耗时，值来自真实采样 | 条文为准；稿是示意 |
| 运行监控图表 · 空态 | 稿只画一张折线 | 并发图常驻；时延图只有在真有样本时出现，否则显示一行「这段时间还没有语音耗时数据」（第六十四轮修） | 条文为准（§7.6 / 第六十四轮） |
| 运行监控组件表 | 三行示意（语音识别 / 语音合成 / 实时语音） | 按服务 `/metrics` 的 `workers` 如实渲染，行数随档位与驻留状态变 | 条文为准 |
| 屏上数值 | 静态样张 | 运行时值 | 已登记（§11.6 第十二 / 十五轮） |
| 音色克隆 · 提词稿选项 | 画板用纯文字标签（生成器源码里的 emoji 在补丁通道里被吞） | 显示服务端返回的原文（带 emoji 前缀） | 服务端原文为准；稿侧不回填 emoji |
| 开发者文档 · 代码块字体 | 稿用 Inter（插件环境取不到 SF Pro 与等宽字体） | `Typography.code`（系统等宽、可选中、可复制） | 条文为准 |
| 开发者文档 · 目录列选中态 | 稿用 `surface/railTint` 选中底色 | 系统 `List` 选中态（**不**进 `macos-app-design-system.md` §3.2 第 5 条的例外） | 条文为准 |
| 流程画板 · 音色创作流程某一步 | 内容比步骤卡高 30px（插件自检 `overflow → step · 试听与使用+30, detail+16`） | 不涉及应用实现 | **待修**：本轮两次运行都报同一条，成因未追（可能是新增第 4 条流程行后同一行的排布被挤）；修 `main.js` 的流程 builder |
| 稿的页面组织 | 七组内容排在两个真实页面上（`01 Kit` / `02 Screens`），组间 400px | 与实现无关 | 已按 Starter 三页上限重排，`figma-kit/README.md`「页面与排布」为准 |

## 待验证

- 渲染排版：改写后的首屏文案在最小 / 默认 / 放大三档窗口宽度下是否被截断（`MetricValueView`
  是 `lineLimit(1)` + 尾部截断）——需要离屏量测或真机目视。
- 浅色 / 深色下文案行数变化对卡片高度的影响——同上。
- VoiceOver：两张图的描述符换了词（序列名「实时语音会话 / 单次请求」「语音识别 / 语音合成」），
  实测未做。
- 音色克隆整页流程（2026-09-16 新页，全部未实测）：麦克风未授权时是否给「打开系统设置」；
  录 3 秒是否读作「太短」（服务端下限 2s、本地建议 5s 起）；到 45 秒是否自动停止并说明原因；
  回听波形是否来自这段录音本身、计时是否与音频时长一致；注册成功后是否指向音色库。
- 音色克隆档位门禁：`supports_clone == false` 时是否给「去模型管理切档」，`nil`（还没读到）时不拦。
- 开发者文档（2026-09-16 新页，全部未实测）：目录列方向键、`⌘0` 直达、两处复制是否进剪贴板、
  默认是否只露出当前主题。逐条见 `REDESIGN-SPEC.md` §13.7。

## 走查清单

- [ ] 运行监控 · 空闲（服务在跑但没有语音请求）：结论句是否读作「没有语音请求，服务空闲可用」，
      「正在处理」是否显示 `0 个 / 现在空闲`
- [ ] 运行监控 · 有请求：生成一段配音后回页，「语音合成」是否显示次数与音频时长，「失败请求」是否为「没有」
- [ ] 运行监控 · 时间窗三档（1 分钟 / 5 分钟 / 本次会话）：数字与结论句是否跟着变
- [ ] 运行监控 · 服务停止时：结论是否读作「无法读取服务状态」，各格是否显示「—」而不是 0
- [ ] 「更多细节」折叠区：内存与并行 / 服务能力 / 不同音色类型的合成耗时 / 累计统计（服务启动以来）
- [ ] 浅色 / 深色；窗口最小 / 默认 / 放大
- [ ] 信息密度与渐进式披露：首屏是否只有结论句、六格、趋势、运行组件表
- [ ] 音色克隆 · 四张卡：默认是否只露出（或就绪）走到的那一步，后面的步骤不预先铺开
- [ ] 音色克隆 · 录制：电平是否随说话变化、计时是否正确、到 45 秒是否自动停止并说明原因
- [ ] 音色克隆 · 回听：波形是否来自这段录音本身；「实际朗读的文本」默认是否等于提词稿
- [ ] 音色克隆 · 注册：名称未填时按钮是否说明原因；`先检查参考音频` 的结论是否读得懂
- [ ] 音色克隆 · 权限：拒绝麦克风后是否给「打开系统设置」而不是重试
- [ ] 开发者文档 · 目录列：方向键是否换主题、`⌘0` 是否直达本页、选中态是否是系统那一档
- [ ] 开发者文档 · 正文：默认是否只看到当前主题；代码块复制与「复制接入信息」是否进剪贴板
- [ ] 开发者文档 · 接入信息带：地址 / 鉴权 / 档位 / 能力是否读作当前服务的真实声明

## 回退

- 运行监控本轮改动：视图层六处（`metricStrip` / `monitoringMessage` / `chartHeading` / `workerTitle` /
  `resourceSection` / `histogramRows`）+ 数据层新增字段与新增类型（旧口径一个都没删）。
  详见 `REDESIGN-SPEC.md` §11.6 第六十三轮 ⑤。
- 音色克隆 + 开发者文档这一轮：生成器侧是三处独立新增（`ROUTES`/`SCREEN_DEFS` 两条、
  `screenVoiceClone`/`screenDeveloperDocs` 两个 builder、四个组件集、四个图标、`audit.js` 一段扫描），
  App 侧是五个新文件（`VoiceRecordingController` / `AudioReferenceCheck` / `VoiceCloneView` /
  `DeveloperDocsContent` / `DeveloperDocsView`）加九处改动，`project.pbxproj` 只加五行文件引用、
  五行编译项与三处 `INFOPLIST_KEY_NSMicrophoneUsageDescription`。回退时按块撤：
  一旦撤掉 `NSMicrophoneUsageDescription`，录音会在系统层直接失败（没有该键就没有权限弹窗）。
- 同轮的生成器**页面重排**（2026-09-16 18:0x）：`main.js` 顶部新增 `PAGE_LAYOUT` / `REAL_PAGES` /
  `GROUP_GAP`，`buildPages()` 改成 async 版（复用／接管／清空的顺序），新增 `tileGroups()` 与
  `allowedFrameName()`，`main()` 里加分组采集与 `layout` 步骤，`auditFrames()` 按页面去重。
  这些都是独立块，可逐块撤回；但**不要回到 7 页方案**——Starter 版第二个页面之后 `createPage()`
  必抛，屏幕组会整块丢失（`REDESIGN-SPEC.md` §13.6）。
- App 回退（app-only，不动服务）：退出 App，把
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-11-installed-20260916-1709.zip`
  解到 `~/Applications/SpeechRail.app` 同一路径；服务 `runtime/current`、selection、模型与
  `com.speechrail` 不受影响。
- **本工作区里同时叠着未提交的重设计改动**（`git status` 中 `macos/SpeechRailApp` 与 `docs/` 大面积 M），
  回退必须按 hunk 挑，不能整文件 `git checkout --`。
