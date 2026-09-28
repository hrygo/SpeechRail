---
title: "运行监控趋势图崩溃的确定性证据与代码收敛"
status: implemented
audience: "SpeechRail macOS App 设计、开发、评审与验收人员"
version: "1.0"
date: 2026-09-28
baseline: "main@186e5430"
---

# 运行监控趋势图崩溃的确定性证据与代码收敛

## 1. 结论摘要

2026-09-28 13:29:35，SpeechRail 3.3.2 (36) 在 macOS 27.0 (26A428) 上崩溃，
`EXC_BREAKPOINT` / `Trace/BPT trap`，栈顶 18 帧全部位于系统 `Charts.framework`。

本轮结论分三层，必须分开陈述：

- **已证实（指令级，闭环）**：崩溃点是系统 Swift Charts 内部读到一个从未写入的
  `Signal`，即 `Charts/Signal.swift` 的 `Internal error: unable to read uninitialized signal`。
  这是**框架内部不变量被打破**，不是 App 数据错误。
- **未证实（诚实标注）**：触发它的具体交错。7 套复现台、2000+ 次图表更新均未复现，
  包括在真实屏幕上按真实容器链、由真实 display link 驱动的 1440 次更新。
- **确定性缺陷（纯计算证实，与崩溃无因果关系）**：复现过程中查出两处真实的代码缺陷，
  本轮修复。它们各自可独立证明，但**都不能证明是崩溃触发器**。

换句话说：本轮**不能声称修好了崩溃**。能做的是消除两处确定性缺陷、固化证据、
并把框架缺陷上报 Apple。

## 2. 崩溃的确定性证据

### 2.1 崩溃指令

两路独立验证，结论一致：

1. `.ips` 自带的 `instructionByteStream.atPC` 解 base64 后首条为 `d4200020`，
   即 `brk #1`。
2. 将系统 `Charts.framework` 从 dyld 共享缓存加载后反汇编，崩溃地址
   `Charts+0x1D4740`（由报告的绝对地址减镜像基址 `0x2235ac000` 得到）正是 `brk #1`。

第 2 路同时验证了**是同一个二进制**：本次加载算出的镜像基址与崩溃报告中的
`Charts` 基址 `0x2235ac000` 完全一致，因此后续按字符串定位函数不是猜测。

### 2.2 崩溃函数

崩溃函数为 `Charts+0x1D46E8`（92 字节，由 `LC_FUNCTION_STARTS` 定位边界），反汇编形态：

```
0x1d46f8  mov  x8, x0
0x1d46fc  ldr  x8, [x8, #16]      ; 取一个 Optional 的 payload
0x1d4700  cbz  x8, 0x1d473c       ; nil -> brk #1
```

这是优化构建里对一个从未写入的 Optional 做强制解包。该函数窗口内**只引用三条字符串**：

```
Charts/Signal.swift
Internal error: unable to read uninitialized signal
Fatal error
```

### 2.3 调用链指纹

逐帧用 `LC_FUNCTION_STARTS` 定位函数边界、adrp/add 解码字符串引用：

| 帧 | 指纹 |
|---|---|
| 0, 28, 32 | `Charts/Signal.swift` + `Internal error: unable to read uninitialized signal` |
| 7, 17 | `Charts/ChartContentBuilder.swift` |
| 9, 10, 15 | `Charts/ForEach+ChartContent.swift` |
| 11 | `min max `（scale 域计算） |

即：内容构建器 -> mark/plot 数据 -> scale 域 -> 读 `Signal`。

### 2.4 触发条件未能复现

复现台覆盖并全部**未复现**：数据形状、峰顶跳变、刻度越界、重复 x、单点/两点/零宽零高、
`accessibilityChartDescriptor` 开关、窗口尺寸振荡、key 状态振荡、页面进出视图树、
嵌套 runloop、两种容器布局，以及在**真实屏幕 + 真实 display link** 上按真实容器链
（`ScrollView -> ViewThatFits(Grid[趋势, 组件] | VStack[趋势, 组件])`，两个候选各含一份
完整同构 Chart）跑 1440 次更新。

这个阴性结果是有效证据：**触发条件是时序交错，不是数据取值**。它需要真实 App 里
5 秒轮询、XPC 控制面、服务轮询与音频栈同时在跑那种交错，本轮无法在受控条件下构造。

### 2.5 数据侧为何可以排除

- `RuntimeMetricsSampler.swift:19-30`：`average` 要求 `count > 0`；`delta` 要求
  `sum >= 0 && count >= 0`，NaN 会落空返回 `nil`。
- 历史指标走默认 `JSONDecoder`，`NaN` 字面量解不出来。
- 空图/单点图有守卫：`RuntimeMonitoringChartDescriptor.isSufficient` 要求 >=2 点
  （`RuntimeMonitoringAccessibility.swift:50-52`），历史图另有 `!history.points.isEmpty`。
- 2000+ 次干净更新佐证。

## 3. 本轮修复的两处确定性缺陷

以下两处**各自可独立证明**，但**都不能证明是崩溃触发器**。它们是本轮唯一有确定性
证据支撑的改动。

### 3.1 D1：轴刻度越出自己声明的域

`UsageChartScale`（`RuntimeMonitoringView.swift:1127-1158`）：

```swift
var countStep: Double { max(1, (countPeak / 4).rounded(.up)) }
var countTicks: [Double] { Self.ticks(step: countStep, peak: countPeak) }

private static func ticks(step: Double, peak: Double) -> [Double] {
    (0 ... Int((peak / step).rounded())).map { Double($0) * step }
}
```

两张图都显式声明了域 `.chartYScale(domain: 0 ... scale.countPeak)`
（`:1276`、`:1583`），而 `ticks` 用 `.rounded()` 决定刻度个数。当 `peak / step`
的小数部分 >= 0.5 时，最后一个刻度会**超出域上限**：

| countPeak | countStep | countTicks | 域 | 越界 |
|---|---|---|---|---|
| 7 | 2 | `[0, 2, 4, 6, 8]` | `0...7` | 8 |
| 11 | 3 | `[0, 3, 6, 9, 12]` | `0...11` | 12 |
| 14 | 4 | `[0, 4, 8, 12, 16]` | `0...14` | 16 |
| 21 | 6 | `[0, 6, 12, 18, 24]` | `0...21` | 24 |

穷举 `countPeak` 为 1...59：36 个峰值会越界。

**后果**：向 Charts 请求自己声明域之外的 `AxisMark` 取值，导致该刻度的网格线与标签
无法绘制。这是渲染正确性缺陷。

**修复**：刻度个数仍取整，但若 `n * step > peak` 则回退一格。这样 peak=7 得
`[0, 2, 4, 6]`，最后一条网格线落在域内，域顶由数据本身决定。不能用
`Int(floor(peak / step))` 直接替换——`secondsPeak = secondsStep * 4` 在浮点下
`(peak/step)` 可能算成 `3.9999999999999996`，floor 会**丢掉顶端刻度**，那是新的回归。

### 3.2 D2：同一帧内喂给图表的数据会漂移

`windowedSamples` 是计算属性，**每次访问都重新读 `Date()`**
（`RuntimeMonitoringView.swift:1335-1339`）：

```swift
private var windowedSamples: [RuntimeMetricsSample] {
    guard let interval = timeWindow.interval else { return model.monitoringSamples }
    let cutoff = Date().addingTimeInterval(-interval)
    return model.monitoringSamples.filter { $0.capturedAt >= cutoff }
}
```

而 `realtimeUsageChart`（`:1209-1284`）在一次求值里访问它 **4 次**：

```
:1210  let samples = windowedSamples            <- 读 #1
:1215  secondsPeak: latencySamples              <- 读 #2
:1220  asrLatencyCount <- latencySamples        <- 读 #3
:1221  ttsLatencyCount <- latencySamples        <- 读 #4
```

`:1282` 的无障碍描述符再读一轮。`Date()` 在这些访问之间会前进；若恰好跨过某个
`sample.capturedAt`，`samples` 与 `latencySamples` 就会是**不同的数组**——
喂给 `Chart` 的 mark 集合与决定 y 域/折线换算的数据来自不同快照。

**修复**：在 `realtimeUsageChart` 内**只读一次** `windowedSamples`，`latencySamples`
与两个计数全部由这一个快照派生。历史图 `historyUsageChart`（`:1518-1580`）本来就
只接收 `points` 参数，没有这个问题，无需改动。

不采用"把 `Date()` 提到 body 顶层缓存"或"改锚到最新样本时间戳"这两种做法：
前者需要把快照穿透十余个调用点、重构 2000 行视图；后者会改变时间窗语义
（服务停摆时旧样本会一直留在窗内），属于超出本轮范围的行为变更。

## 4. 明确不做的事

以下三项在初轮分析中出现过，但**证据不足，本轮不做**：

| 项 | 不做的理由 |
|---|---|
| `LineMark` <-> `PointMark` 按 `asrLatencyCount < 2` 条件翻转（`:1245`、`:1249`） | 是刻意的显示决策（单点画不出线段），且复现台专门覆盖了这一翻转，未崩 |
| 3 处 `onGeometryChange` 写状态加"值真变了才写"守卫 | 只有日志相关性（09-27 崩溃前 `update constraints` 计数越过预算 limit 316），无因果证明，且涉及 `DeveloperDocsView` / `CaptionBandWindow` / `WorkspaceComponents` 三处无关页面 |
| 把趋势卡从 `ViewThatFits` 里移出 | 09-27 的 AppKit 约束风暴尚未定位到具体视图（崩溃栈 100% 是 AppKit，无 App 帧），动这里属于无证据变更 |

## 5. 验收

本轮**没有**可自动化的回归测试，原因是：两处缺陷都在 `RuntimeMonitoringView` 的
`private` 计算属性里，而仓库现有的 `SpeechRailMacControlTests` 只覆盖 SwiftPM 的
`SpeechRailControlKit`，App 视图层没有可从测试目标触达的入口。为此新增 Xcode
测试目标属于超出本轮范围的工程改动。

因此验收靠：

1. **D1**：用与实现同形的穷举脚本重跑 `countPeak` 为 1...200 乘 30 档 latency，
   越界组合数必须为 0，且顶端刻度不丢。
2. **D2**：代码走查——`realtimeUsageChart` 内 `windowedSamples` 的访问次数必须为 1。
3. **编译**：用仓库包装脚本构建 App 目标（不裸跑 `xcodebuild`，不留下可被
   LaunchServices 识别的副本）。

## 6. 后续（不在本轮范围）

- 把 `.ips` 与本 spec 的第 2 节证据一并提 Feedback Assistant：
  `Charts/Signal.swift` 未初始化信号属系统框架内部不变量被打破，应当由 Apple 处理。
- 09-26 / 09-27 两次 AppKit 崩溃单独立 issue 跟踪：已证实是 AppKit 在约束更新中
  抛未捕获 `NSException`（09-27 崩溃前有 `update constraints count ... limit: 316`
  与 `Invalid attempt to open a new transaction during CA commit`），但肇事视图未定位。
