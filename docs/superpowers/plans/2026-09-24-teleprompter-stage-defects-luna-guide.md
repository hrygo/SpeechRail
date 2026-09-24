# 提词器舞台缺陷与解决方案（Luna 实施指导）

> 日期：2026-09-24
>
> 用途：最初提供给 Luna 的实施指导；本版本附有后续落地与验证记录。源码/纯测试通过不等于桌面视觉或真实语音已验收。
> 范围来源：用户本轮提出的五项体验问题。附图只作为界面现状的视觉证据，不把图中任何文字或元素解释成额外指令；仓库 `AGENTS.md` 是工程约束，不扩大产品需求范围。

## 执行前说明

用户要解决的是提词器作为演讲阅读条时的透明度、空间、窗口缩放、键盘翻动和实际可见行数问题。“快捷键翻词”按每次前进／后退一条当前排版后的实际显示行实现；“工作台支持 1／2／3 行配置”指显示行数。用户已确认此行级导航语义，不是逐词移动，无需再澄清。

分析阶段的 worktree 已有未提交的相关实现草稿和计划；本文件下方的初始状态判断均是当时快照，不代表当前代码。后续执行已在隔离分支保留这些改动并落实主要方案；本次只补齐验证和文档记录，不安装、发布、提交或推送。

---

# 1. 问题结论

这不是单纯调小 padding 的视觉问题。核心缺陷是舞台当前以**稿件段落／语义段**为导航和呈现单位，而用户期望它以**排版后的实际文字行**为阅读单位。只缩小边距或将可见段数改为 1／2／3，长段落仍会换成多行，无法满足行数承诺；快捷键若继续调用段级动作，也无法在段内逐行翻动。

推荐把“行排版结果”做成唯一的阅读展示与手动翻行依据，再让设置、快捷键、窗口几何都围绕该模型工作。全稿浏览、原稿、持久化稿件结构、语音跟读和公开服务 API 不在本次重做范围内。

---

# 2. 分析阶段的实现与根因（历史快照）

以下是分析阶段对 `codex/teleprompter-stage-polish` 工作树的只读检查结果；分支当时已有未提交改动，因此该快照不等同于干净 `main` 的基线，也不应当作当前代码状态。

| 现象 | 当前代码证据 | 结论 |
|---|---|---|
| 1／2／3 行可能仍显示超过 3 个物理文字行 | `TeleprompterStagePresentation.visibleSegmentSlots(...)` 接收段索引；`TeleprompterStageView.segmentRow(at:)` 把完整 `segment.text` 交给多行 `Text`。 | 当前设置仍是段落数量语义，不是实际排版行数；长段会继续折行。 |
| 快捷键只按段前进 | `TeleprompterStageView` 的按键 handler 调用 `TeleprompterSession.moveToPrevious()` / `moveToNext()`；`TeleprompterFollowController.manualMove(to: Int, segmentCount:)` 只能定位段首／段号。 | 需新增携带段内 UTF-16 偏移的手动定位，不可只改按键绑定。 |
| 阅读位置已具备偏移基础 | `TeleprompterSession` 暴露 `currentSegmentIndex`、`readingOffset`；同步自 `followController.position.utf16Offset`。 | 复用现有位置状态，不能另造一个只给 UI 使用的持久化游标。 |
| 屏幕利用不足 | 附图显示正文内容集中在舞台中央，左右仍有大块空白；当前变更 diff 已尝试去掉旧正文宽度封顶，但实际可用宽度还受窗口内容区和嵌套 padding 影响。 | 不只验证单个 `.frame(maxWidth:)`；应从 `NSScreen.visibleFrame` 到最终文字布局整体检查。 |
| 透明度端点未充分证实（分析阶段） | 分析阶段工作树已有 `backgroundTransparency` 与 `opacity` 反向映射，并将透明度 token 扩至 100%；`TeleprompterStageView` 对背景、边框等仍有多处独立绘制路径。 | 后续纯测试覆盖 0／100% 数值端点；是否在真实桌面达到预期观感仍需人工确认。源码与单测不等于视觉验收。 |
| 最大化高度行为未验收（分析阶段） | 分析阶段工作树新增 `TeleprompterStageGeometryPolicy` 和 `windowWillUseStandardFrame`，高度上限 token 草案为 360pt。 | 后续纯几何测试已通过；真实多屏缩放/恢复手感仍需人工检查，不能把 macOS 全屏 Space 与窗口 zoom 混为一谈。 |
| 行数默认值曾有草稿差异 | 分析阶段的一份早期 diff 把 `visibleSegmentCount` 的缺省值改成 2；用户没有要求改变默认值。 | 最终实现按基线保留默认 3，旧 UserDefaults key 仍用于读取/保存 1／2／3；StageSettings 测试覆盖该行为。 |
| 定向测试曾处于红灯草稿状态 | 早期草稿的 `TeleprompterFollowControllerTests.swift` 调用了尚未实现的 `manualMove(to: Position, segmentUTF16Lengths:)`，当时测试编译失败。 | 后续实现补齐了位置重载与 Session 接管；本轮提词器全量过滤测试已实测 144 项／15 suites 通过。 |

本表只描述当前检查到的工作树证据。执行前 Luna 应复核最新文件、`Package.swift`、Xcode project source 列表和用户新增改动。

---

# 3. 目标行为

1. **透明度**：范围完整覆盖 0–100%。0% 表示阅读区背景不透明；100% 表示阅读区没有可见底色、材质、卡片边框或大面积底板。此滑块只作用于阅读面背景；文字、语音提示、设置按钮和控制区仍保持可读。不隐含启用鼠标穿透。
2. **空间利用**：普通窗口内正文填满可用阅读宽度；删除无依据的 720pt 固定封顶，并收紧过大的左右／上下留白。布局仍要尊重系统可用屏幕区域和设计 Token，不把多个 padding 叠加回去。
3. **窗口最大化**：使用系统窗口“缩放／最大化”行为，不切入独立 macOS 全屏 Space。横向扩展到当前屏幕 `visibleFrame` 的可用宽度；纵向不超过统一 token（当前草案 360pt），也不得超过屏幕可用高度。最大化期间不得把全屏宽度覆盖成用户普通窗口的偏好宽度；取消缩放后恢复原普通尺寸。
4. **快捷键翻行**：舞台成为 key window 并把焦点置于阅读区时可快捷翻行；命令仅在阅读焦点有效、舞台打开且没有控件／文本输入焦点、菜单或 popover 接管时生效。建议左右／上下方向键前后移一条视觉行，Space 前进一行，PageUp／PageDown 按配置行数移动，Home／End 到稿件两端；另在菜单里提供可见的“上一行／下一行”快捷键提示（例如 Cmd-Option-Left／Right）。所有入口调用同一行级 Session API，不注册影响其他 App 的全局热键。
5. **实际 1／2／3 行**：设置控制排版后的文字行，而不是段数。1 行显示当前行；2 行显示当前行和下一行；3 行按“上一行（已读）／当前行／下一行”显示。三行模式始终将当前行放在中间；稿件首尾缺少上下文时保留空槽，当前行不移位。长句按当前字号和实际可用宽度换行；切字号／宽度后行数仍严格满足 1／2／3。
6. **保留原能力**：全稿浏览仍能浏览、滚动和选择全文，不受 1／2／3 行限制；手动翻行继续立即接管现有语音跟读，并拒绝过期跟读事件回写；原稿与持久化稿件 schema 不变。

---

# 4. 推荐解决方案

## 4.1 建立真实显示行模型

新增一个纯展示布局结果，例如 `TeleprompterStageDisplayLine`：

- `segmentID` / `segmentIndex`：回到现有稿件段落；
- `sourceRange: NSRange`：段内 UTF-16 来源区间，与 `TeleprompterAligner.Position.utf16Offset` 使用同一单位；
- `text`：这一条可见行的显示文本；换行分隔符可不绘出，但来源区间不能使底层可朗读文字遗漏或重复；
- 稳定 `id`：由段 ID 与行起始偏移等确定性值生成，不用每次重排都随机生成。

用一个布局器按**可用文字宽度、与舞台显示一致的字体／字号、行间距**为每个 `TeleprompterSegment.text` 求实际行断点。优先用 TextKit/AppKit 文本布局来取得 line fragment 到 character range 的映射；显示层必须使用同一组字体和换行约束。若仍用 SwiftUI `Text` 渲染每个结果行，必须限制为一行并验证测量引擎与 SwiftUI 不会导致隐藏换行或裁字；不一致时应让测量和渲染共用 TextKit，而不是静默截断。

每次稿件、可用宽度、字体／字号、行间距变化时重排；只翻行时复用布局结果。原文从不被重写或归一化，布局映射只存在于内存。

## 4.2 用同一个行列表驱动展示和导航

`TeleprompterStagePresentation` 新增按 `TeleprompterAligner.Position` 找当前显示行、产生 1／2／3 个上下文槽的纯函数：

- `visibleLineCount == 1`：`[current]`；
- `visibleLineCount == 2`：`[current, next]`；
- `visibleLineCount == 3`：`[previous, current, next]`，不存在的邻行用 `nil` 占位；
- 全稿浏览单独走现有全文路径，不套用行槽限制。

区间使用半开 `[location, location + length)` 语义；跟读偏移在行内时映射到其所在行，恰好命中下一行起点时应归入下一行，段末落在最后一行。手动翻行定位至目标行的 `sourceRange.location`，不向前或向后做隐式文本匹配。

## 4.3 扩展现有手动定位，不复制进度状态

在 `TeleprompterFollowController` 增加接收完整 `TeleprompterAligner.Position` 的 `manualMove`，按段数量和各段 `utf16.count` 夹紧索引／偏移；保留现有只按段号的 API 是否继续使用，以调用点审查结果为准。

在 `TeleprompterSession` 提供一条行级定位入口。它应复用现有 `takeOverAndMove` 语义：同步取消正在启动／跟读的语音推进、让旧 generation 事件失效、重置相应节奏采样、更新 `followController`、同步 `currentSegmentIndex` 与 `readingOffset`、切回 manual phase 并保存进度。前后边界 clamp，不循环、不结束 Session、不丢当前位置。

## 4.4 设置与阅读 UI

- 将用户可见属性／token 命名改为 `visibleLineCount`、`stageMinimumVisibleLineCount`、`stageMaximumVisibleLineCount` 等，不再把“行数”命名成“段数”。
- 为避免用户偏好丢失，复用现有 `UserDefaults` 数字 key；其 1／2／3 值现在恰好仍是有效行数，无须迁移。默认值沿用目标基线，不借此功能顺便更改默认。
- 设置控件使用简洁的 1／2／3 行选项，提供明确辅助标签“显示行数”；同步 VoiceOver label/value。
- 阅读面每个槽是一行，当前行最高强调，上／下文弱化但仍有可读对比度。100% 透明度不能让文本、控制和错误状态跟着淡出。全稿模式保留现有选择与滚动能力。
- 收紧重复的外层 padding 和过高的空占位，但控件隐藏时保持内容几何稳定，不因自动隐藏而让文字上下跳动。

## 4.5 窗口几何与宽度

普通窗口仍允许用户调整宽度，并保存普通窗口宽度。系统缩放框按当前屏 `visibleFrame` 横向尽可能铺满；高度限制用 `stageMaximumHeight` 单一 Token，并兼容屏幕比该上限更矮的情况。上边缘可保持与当前普通框相同，最终 frame 必须 constrain 到目标屏幕。

打开设置、改字号、切 1／2／3 行、重复打开舞台时，仅按必要内容高度更新普通窗口，不把 panel 重置到默认宽度。已 zoom 的窗口暂存待应用布局请求，退出 zoom 后再按用户普通尺寸策略应用。

## 4.6 按键焦点

保留 `TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands(...)` 这类可测试策略，将根容器的按键 handler 全部指向行级 Session API。按钮、菜单、箭头键、Space 使用同一导航函数。菜单项命名从“上一段／下一段”同步改为“上一行／下一行”。读取设置的 slider／picker 时，方向键只操作控件；popover 关闭后恢复阅读焦点但不得抢其他窗口焦点。

---

# 5. 详细实施步骤

## 步骤 1：先核对目标基线和现有未提交改动

**文件／模块：** 整个 worktree，重点为 `TeleprompterStageSettings.swift`、`TeleprompterStageView.swift`、`TeleprompterStageWindow.swift`、`App.swift`、测试和已修改的三份提词器文档。

- 读取 `git status --short --branch`、`git diff`、必要时 `git diff --cached`；确认哪些是已存在的草稿，避免重做或覆盖。
- 以干净基线／当前项目契约确认真实默认行数、透明度范围、当前 padding 和 720pt 限宽，不把工作树中的假设写成历史事实。
- 保留现有项目的隔离分支和本地改动；不提交、不推送、不安装、不发布。
- 分析阶段曾因缺少 Position 重载出现编译红灯；该接口现已实现并有 Session 生命周期回归测试。本轮重跑结果见 §7 的执行记录。

## 步骤 2：先加行布局与行槽测试，再实现纯展示策略

**文件：** `TeleprompterStageSettings.swift`（若新建 `TeleprompterStageLineLayout.swift`，同时登记 `macos/SpeechRailApp/Package.swift` 与 Xcode project）；`TeleprompterStageSettingsTests.swift`。

- 补充行数设置边界与持久化测试；含默认值不变、旧 key 重载、1／2／3 有效以及越界夹紧。
- 补充 TextKit 行布局测试：窄宽度确实产生多条实际行；中文连续文本、英文断行、emoji ZWJ／组合字符、显式换行、空段均不会导致崩溃或拆坏 grapheme。
- 验证来源区间单调、无重叠，覆盖所有有效原文内容；显示文本不重复、不遗漏，换行分隔符处理明确。
- 补充行槽矩阵：0 行、单行、首行、中间行、末行；可见数 1／2／3；三行始终当前居中，缺少上下文用空槽补位；全稿模式不截断。
- 先确认新增测试失败，再实现 `TeleprompterStageDisplayLine`、行布局器和 `visibleLineSlots`。

## 步骤 3：补齐 UTF-16 手动定位和 Session 行级接管

**文件：** `TeleprompterFollowController.swift`、`TeleprompterSession.swift`；`TeleprompterFollowControllerTests.swift`、`TeleprompterSessionLifecycleTests.swift`。

- 增加 `manualMove(to: TeleprompterAligner.Position, segmentUTF16Lengths:)` 或等价明确接口，测试段索引和偏移的上下界夹紧。
- 测同段改变 offset 不回到段首；跨段正确定位；首／末边界不循环；offset 超过段长夹到末尾。
- Session 行级入口必须复用 voice stop、generation 失效、manual phase 和进度保存路径；测试手动翻行后到达的旧跟读事件不回写位置，关闭／未启用语音时也不产生新副作用。
- 保护原有 `moveToSegment`、全文浏览滚动接管和 restart-to-beginning 语义。

## 步骤 4：把舞台阅读显示替换为真实行槽

**文件：** `TeleprompterStageView.swift`、`SpeechRailDesignTokens.swift`；必要时调整 `TeleprompterStageSettings.swift`。

- 普通阅读模式消费当前 Session Position 对应的 display lines 和 `visibleLineSlots`，不再按 `visibleSegmentSlots` 渲染完整段落。
- 设置行数为 1／2／3 时屏幕上实际只出现对应条数；三行上下文语义为已读／当前／下一，当前保持垂直中心。
- 正文按阅读面实际可用宽度排版，移除固定 720pt 限宽及重复大边距；不得因字号／缩放后变成更多视觉行。
- 保留全稿浏览、text selection、段级定位和滚动行为。隐藏控制时空间稳定，显示设置面板后阅读不会跳行。
- 1／2／3 设置调整、窗口变化、字号变化时保留相同原文位置并重排；不得仅靠 `currentSegmentIndex` 恢复，因为段内 `readingOffset` 也必须保留。

## 步骤 5：完成透明度端点与边距整理

**文件：** `SpeechRailDesignTokens.swift`、`TeleprompterStageSettings.swift`、`TeleprompterStageView.swift`；`TeleprompterStageSettingsTests.swift`。

- 以背景透明度 0…1 映射既有 opacity，保留当前持久化 key 和历史值；测试 0%、中间值、100%、非法值夹紧和重载。
- 100% 时不绘制阅读面底色、材质、外框／大面积底板；正文、语音提示和操作控件不受滑块影响。
- 0% 时仍有清晰不透明阅读背景。快速预设与连续 slider 展示一致，百分比 label 不出现 99.99% 等误导值。
- 控制区域与正文留白复用设计 Token；不新增页面散落的裸视觉值，不为了 100% 顺手加鼠标穿透。

## 步骤 6：收敛窗口横向缩放和高度策略

**文件：** `TeleprompterStageWindow.swift`、`TeleprompterStageSettings.swift`、`SpeechRailDesignTokens.swift`；窗口纯几何测试（复用现有测试文件或显式接入新测试文件）。

- `windowWillUseStandardFrame` 返回当前屏幕可用宽度的缩放 frame，并限制高度不超过 `stageMaximumHeight` 和 `visibleFrame.height`。
- 验证 zoom 与 macOS Full Screen 不同；不创建新 Space。
- 普通尺寸宽度只在非 zoom 状态记入偏好；zoom 过程不覆盖它，离开 zoom 恢复普通 frame。
- 覆盖屏幕原点非零／负坐标、副屏、屏幕切换、窄屏、重复打开和设置变化；窗口都被约束在可用屏幕范围。
- 窗口几何计算与系统 window decoration 差值保持一致（content rect 与 frame rect 不要混用）。

## 步骤 7：闭合快捷键和文档契约

**文件：** `TeleprompterStageInteractionPolicy.swift`、`TeleprompterStageView.swift`、`App.swift`、对应测试；`docs/developers/macos-app-teleprompter.md`、`docs/developers/macos-app-design-system.md` 与当前活动提词器 spec。

- 阅读区焦点时按键改变视觉行；control／popover／menu 焦点时不触发行导航。
- 把菜单文案和快捷键提示改为行语义，统一调用行级 Session API；舞台关闭或目标无下一行时禁用。
- 修改文档中的语义段窗口、`visibleSegmentCount`、段级翻动等描述，避免新旧术语矛盾。文档日期／版本只在正文实质变更时更新。
- 文档中的实现说明标注为已决定契约，不把纯策略测试结果写成桌面 UI 已验收。

## 步骤 8：按授权做最小充分验证并报告

- 执行适用的 Teleprompter 定向 Swift Testing；随后可用仓库 `scripts/macos_app_build.sh --configuration Debug` 检查 App target 编译。新增 Xcode 源文件时还需检查 `plutil -lint macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`。
- 不运行 XCUITest、Playwright、录屏或其他会接管前台窗口／焦点／输入的 UI 自动化；没有逐次明确授权就不进行。
- 不安装、启动／停止服务、发布或提交。最终区分测试、构建与人工桌面观感验证，不以编译成功宣称视觉验收。

---

# 6. 关键实现说明

### 行偏移与 Unicode

`TeleprompterAligner.Position.utf16Offset` 是现有进度单位，行模型必须使用同一单位。不要用 `String.count` 或 Swift Character 数量和 UTF-16 偏移直接比较。取子串时通过 `Range(NSRange, in:)` 等安全转换处理；行断点必须落在有效字符边界，不能拆开 emoji surrogate pair、组合附加符号或 ZWJ 序列。布局包括换行符时，显示文本可以裁掉行尾分隔符，但范围映射与行间偏移仍要覆盖来源，不改写 `segment.text`。

### 设置与存储

显示行数语义变化不要求迁移稿件或偏好格式。最终实现使用公开属性 `visibleLineCount`，持久化仍沿用既有 `speechrail.teleprompter.stage.visibleSegmentCount` key，并在代码注释解释这是为保留 1／2／3 用户偏好；用户可见文案使用“显示行数”。最终缺省值保留为 3，早期 draft 曾改为 2 的差异已修正。

### 全稿浏览与阅读模式

1／2／3 约束只用于普通提示阅读模式。用户进入全稿浏览后仍应看到整份原稿，继续支持滚动、选择与段落跳转；退出后再根据保存的 `(segmentIndex, utf16Offset)` 映射回新布局，而不是重置到段首。

### 可见行导航

前／后翻行的逻辑应在 display-line 列表上做 clamp：首行向前仍停留在首行；末行向后仍停留在末行。跨段只改变 position，不拼接或修改稿件文本。按钮、键盘和菜单调用同一 API，避免三套步长行为。

### 最大化和空间

“横向铺满屏幕”定义为填满当前显示器扣除菜单栏／Dock 后的可用 `visibleFrame`，不是物理屏幕像素到边缘，也不是进入 Full Screen。普通窗口可保留用户手动宽度；zoomed frame 不作为该偏好回写。高 360pt 是当前实现草案，应集中为设计 Token；更矮屏幕时再按可用高度缩小。

### 透明度

背景透明度和窗口鼠标穿透是两个不同能力。100% 仅让舞台背景不绘制；不要把 `.opacity(0)` 套到整个 stage 根节点。若保留当前行小型标记，其面积不得形成残留底板，且不应通过颜色单独传达导航状态；辅助功能标签可明确“已读／当前／下一行”。

---

# 7. 测试方案

| 测试文件 | 必测场景 |
|---|---|
| `TeleprompterStageSettingsTests.swift` | 1／2／3 行、越界 clamp、旧设置 key 重载、默认值不变；透明度 0／100／中间值、反向映射、label rounding；行槽首中末边界。 |
| 新增 `TeleprompterStageLineLayoutTests.swift`（如采用新文件） | 中文无空格、英文单词、emoji ZWJ／组合字符、显式换行、空白段、窄宽大字号；行 range 单调完整，无漏字、重字和非法 Unicode 边界；重排后能从原 Position 找回所在行。 |
| `TeleprompterFollowControllerTests.swift` | 同段非零 offset 定位、offset 上下界、段索引夹紧、前后边界、manual 模式与过期事件失效。 |
| `TeleprompterSessionLifecycleTests.swift` | 快捷键行导航触发手动接管、停止跟读、旧 generation 事件无效、进度保存；不启用语音也能翻行。 |
| `TeleprompterStageInteractionPolicyTests.swift` | 仅阅读焦点接受命令；控件／popover／菜单／舞台关闭状态拒绝；Tab 控制显隐不吞掉后续行命令。 |
| 几何纯策略测试 | screen visibleFrame、横向填满、高度上限、屏幕窄于上限、负坐标副屏、zoom/restore 普通宽度。 |

**建议命令**（在仓库根目录运行；实际执行需遵守当轮授权）：

```bash
swift test --package-path macos/SpeechRailApp --filter TeleprompterStageSettingsTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterFollowControllerTests
swift test --package-path macos/SpeechRailApp --filter TeleprompterStageInteractionPolicyTests
swift test --package-path macos/SpeechRailApp --filter Teleprompter
scripts/macos_app_build.sh --configuration Debug
```

本轮已重新运行 `rtk swift test --disable-sandbox --package-path macos/SpeechRailApp --filter Teleprompter`：144 项测试、15 个 suites 全部通过；`rtk scripts/macos_app_build.sh --configuration Debug` 输出 `BUILD SUCCEEDED`。测试运行器与本会话适用日期存在一天差异：运行器及 `rtk date` 报告 2026-09-25 CST，会话日期为 2026-09-24；保留工具原始时间，不据此改写文档日期。`rtk git diff --check` 已于文档更新后执行并退出码为 0；未跟踪计划文档的尾随空格仅用于 Markdown 硬换行。

UI 实际布局、焦点返回、系统 zoom 手感、VoiceOver、外观模式和透明背景与后方内容的对比仍需人工桌面检查；项目规则要求每次 UI 自动化先取得用户明确授权，本方案不安排自动化。

---

# 8. 验收标准

- [ ] 透明度 slider 可准确到 100%；100% 时阅读面背景／材质／边框不留可见底板，文字与控件清晰；0% 完全不透明。
- [ ] 正文使用舞台实际可用横向宽度，不再受任意 720pt 封顶或重复大 padding 挤压；窄窗口和大字号下没有裁字。
- [ ] 系统窗口缩放后横向占满当前屏幕可用宽度；高度不超过统一上限及屏幕可用高度；不进入独立全屏 Space。
- [ ] 取消最大化后普通窗口的用户尺寸恢复；读设置、重复打开或改行数不重置普通宽度。
- [ ] 1 行严格显示 1 条文字行，2 行严格显示 2 条，3 行严格显示上一／当前／下一；超长段落也不会展开成额外显示行或静默丢字。
- [ ] 三行时当前行始终处于中间槽；稿首／稿尾以空槽占位，不跳位。
- [ ] 改宽度、字号或行距会重新布局但保持同一原文位置；按行前后移动无漏字、重字、倒退和跨段错误。
- [ ] 键盘导航只在阅读焦点且舞台可用时生效；设置控件、菜单和 popover 不误翻；按钮／快捷键／菜单步长一致。
- [ ] 手动翻行继续复用语音接管、generation 和进度保存路径；迟到事件不能把当前行拉回旧位置。
- [ ] 全稿浏览、原稿、稿件持久化和已有语音生命周期行为没有回归。
- [ ] 定向 Swift Testing 通过；Debug App 构建通过；未授权的 UI 自动化、安装、服务操作、提交与发布没有发生。

---

# 9. 风险与注意事项

1. **导航粒度已确认。** 用户确认快捷键每次按实际排版后的显示行前进／后退；逐词推进不属于本次需求。
2. **文本测量与渲染不一致会导致裁切。** LayoutManager/CoreText 和 SwiftUI Text 使用不一致的字体属性时，模型的一行可能在 UI 上折为两行。必须共用排版属性并加窄宽回归测试。
3. **行重排不能重置语音位置。** 改窗宽或字号时 display-line 索引会变化，唯一持久位置仍是稿件段索引加 UTF-16 offset；展示索引只派生、不持久化。
4. **可见区不是物理屏幕 bounds。** 菜单栏、Dock、屏幕缩放、外接屏的坐标会影响 zoom frame；纯几何测试不能完全替代实际桌面检查。
5. **全透明并不等同于录屏隐身或鼠标穿透。** 本次不更改录屏边界、窗口捕获属性或事件命中策略。
6. **分析阶段的未提交草稿与红灯已处理。** 最终工作树仍有本任务相关未提交改动；不覆盖或回退，最终交付如实报告未提交状态。
7. **本次不处理** AI 稿件生成、声学跟读准确率、全局热键、外部遥控、鼠标穿透、公开 API、数据库／稿件 schema、服务运行态和发布。

---

# 10. Luna 执行清单

1. **保护工作区**：核对目标分支和脏文件；保留当前未提交改动；确认基线默认值、设置 key、窗口约束和项目文件登记方式。
2. **锁定真实行语义**：将显示单位定义为 TextKit 排版行；用户已确认快捷键按实际显示行前进／后退，无需再次澄清。
3. **测试先行**：完善设置、UTF-16 行映射、Unicode、三行居中、首尾空槽和段内定位的失败测试。
4. **实现显示行布局器**：保存稳定的 `(segmentIndex, utf16Range)` 映射；重排不改原稿、不丢字；新增源文件时同步 Package 与 Xcode project。
5. **接入 Session 行级定位**：复用现有手动接管和跟读取消／generation 语义；覆盖同段、跨段与首尾边界。
6. **改造舞台阅读 UI**：用 1／2／3 实际行槽替代段槽；保留全稿浏览；收紧宽度与边距但不裁字。
7. **完成透明度**：把 100% 定义为无阅读面底板，不影响正文、提示和控制；保留现有持久化数据。
8. **修正窗口缩放**：横向铺满 `visibleFrame`，限制高度，保存并恢复普通窗口宽度；不切独立全屏。
9. **闭合键盘交互和文档**：焦点策略、按钮／菜单使用同一行步进 API；同步活跃契约和文档。
10. **按授权验收并报告**：运行定向测试与项目包装脚本 Debug 构建；清楚报告未做的桌面人工检查；不安装、不操作服务、不运行 UI 自动化、不提交或发布。


# 11. 后续落地与验证记录

- 已将本方案落实到提词器舞台：实际显示行与原稿 UTF-16 偏移映射、1／2／3 行槽、100% 背景透明端点、紧凑内容宽度、横向 zoom 与 360pt 高度策略、行级键盘/按钮/菜单导航及工作台行数设置。
- 测试：`rtk swift test --disable-sandbox --package-path macos/SpeechRailApp --filter Teleprompter`，144 tests / 15 suites 全部通过。
- 构建：`rtk scripts/macos_app_build.sh --configuration Debug`，`BUILD SUCCEEDED`；这是 Debug 配置编译检查，没有启动 App 进入交互调试。
- 用户确认记录（2026-09-24）：快捷键每次移动一条实际显示行；不需要 Debug／前台交互检查。
- 时间证据冲突：本会话适用日期为 2026-09-24；本机 `rtk date` 与 Swift Testing runner 输出 2026-09-25 CST。文档保留工具原始时间，不把其改写为会话日期。
- 未执行 UI 自动化、启动 App、前台/焦点接管、桌面视觉走查、VoiceOver、Reduce Motion、真实采集/服务验证、安装、服务操作、提交或推送。透明度的实际观感、多屏 zoom/restore 与焦点行为仍未做桌面验证；按用户确认，这不是本轮继续调试的要求。
- 当前分支仍有未提交的本任务修改；不要用 reset、整文件覆盖或回退操作清理。
