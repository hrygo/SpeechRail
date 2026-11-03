# 实时字幕断句边界与段落组装优化方案

**版本**: 1.0.0
**日期**: 2026-11-04
**状态**: Active Review
**适用范围**: `macos/SpeechRailApp/SpeechRailApp/CaptionParagraph.swift`、段落装配器及相关生命周期测试

---

## 1. 背景与问题定义

在 2026-11-03 23:43:58 的真实字幕会话（`2D30D62C-D2ED-4D0A-9ADB-7729405C0189`，持续 12分28秒）中，系统在 123 行 ASR 识别结果中仅组装出 17 个合并段落，最终形成了 103 个分散段落，**合并率仅 13.8%**。

在这些未合并的相邻行中：
- **间距 Gap ≤ 600ms 的相邻行高达 65 对**；
- **间距 Gap == 0ms（音频声学完全连续、无停顿）的相邻行多达 31 对**；
- 出现了严重的**引述断尾被斩首、履历顺承被腰斩、以及因为引号穿透盲区导致的“反向错误吸附”**。

### 核心典型案例清单

| 案例类型 | 序号与文本 | 实测表现 | 根因分类 |
| :--- | :--- | :--- | :--- |
| **反向错误吸附** | `L22`: 离开 OpenAI。<br>`L23`: 成立了Anthropic。<br>`L24`: Darrell后来谈起这段经历的时候说过一句话：“……愿景。” | `L22` 与 `L23` 没合并，`L23` 反被 `L24` 错误吸附合并为一段 | **标点引号穿透盲区**：`L24` 尾部为 `”`，`endsWithTerminalPunctuation` 误判为未完残句，触发碎片容错合并门禁 |
| **引述语断尾** | `L34`: ……公司为什么存在。他们家的一位前员工说。<br>`L35`: 这感觉就像听牧师布道。 (Gap: 0ms) | 分裂为两段独立字幕 | **静态引述词表死板**：仅支持 `"他说"`, `"她说"`, 无法匹配任意主语修饰的 `[xxx]说/表示/认为` |
| **提示性结论断尾** | `L16`: ……思来想去，他得到一个结论。<br>`L17`: AI太危险了。 (Gap: 0ms) | 分裂为两段独立字幕 | **缺少提示句式识别**：`得到一个结论` 属于下文引出结构，被 ASR 自动补句号阻断 |
| **顺承副词履历割裂** | `L8`: ……他真懂技术。<br>`L9`: 先后在百度、Google、OpenAI干了几年。<br>`L10`: 一直身处AI研发的前沿…… | 3 句全部独立成段 (Gap 0~64ms) | **缺失顺承副词**：`continuationStart` 仅有连词和介词，缺少 `先后/一直/陆续/随之` 等叙事副词 |
| **英文条件复合句拆分** | `L108`: ……now if you match all ten of these.<br>`L109`: You're gonna walk out of here with a thousand dollars. | 0ms 紧邻复合句被拆分 | **从属连词从句悬空**：`if` 引导的从句尾部单词为 `these.`，未被识别为从句未完结 |
| **英文口语连词漏识别** | `L82`: Yeah, pray for us. Pray for us.<br>`L83`: Cause my grandmama. (Gap: 0ms) | `Cause my grandmama.` 作为孤立残句上屏 | **口语连词缺口**：仅识别 `"because "`，漏掉高频口语 `"cause "`, `"'cause "`, `"cuz "` |

---

## 2. 设计原则与边界约束

1. **治愈截断伪影，坚决不贪婪粘合**：段落装配器负责消除 ASR 模型的声学切片断裂、rollover 被动截断和伪标点，**两句各自完整、无语法关联的独立陈述句即使相隔 0ms 也不得合并**；
2. **字符预算严格受控**：中文/CJK 软预算保持 38 字，西文软预算保持 84 字，最大合并行数保持 3 行；
3. **多维安全边界隔离**：
   - 跨说话人（Speaker Label 冲突）绝对不合并；
   - 跨语种（`CaptionLanguageDetector` 识别不一致）绝对不合并；
   - 跨时间窗口（Gap > 1.2s 或段落总时长 > 28s）绝对不合并。

---

## 3. 详细设计（四大优化模块）

### 模块 A：标点与闭合引号/括号穿透探测（Quote-Aware Punctuation Peeling）

- **目标**：消除引号包裹句末标点时的检测盲区，修复反向错误吸附。
- **改动范围**：`CaptionParagraphAssembler.swift`
- **逻辑实现**：
  在 `endsWithTerminalPunctuation(_:)` 和 `endsWithClausePunctuation(_:)` 中，探测标点前穿透右侧全部配对闭合标点（`”`、`’`、`"`、`'`、`」`、`』`、`）`、`]`、`}`、`〉`、`》`）。
  ```swift
  static func endsWithTerminalPunctuation(_ text: String) -> Bool {
      var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = trimmed.last, "”’\"'」』）)]}〉》".contains(last) {
          trimmed.removeLast()
          trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard let last = trimmed.last else { return false }
      return "。！？.!?…".contains(last)
  }
  ```

### 模块 B：中英混排短碎片等效长度校准（Mixed-Script Length Calibration）

- **目标**：杜绝含有英文专有名词的中文句子（如 `成立了Anthropic`）被误判为超短碎片。
- **逻辑实现**：
  在 `isShortFragment(_:)` 中，CJK 字符按 1 个单位计，连续西文字词（Latin Word）按 2 个中文字符单位折算：
  ```swift
  let equivalentUnits = cjkCount + (latinWordCount * 2)
  if equivalentUnits > 0 {
      return equivalentUnits <= 6
  }
  ```

### 模块 C：引述语与提示性引出句动态匹配（Attributive Frames & Cue Continuation）

- **目标**：治愈“某某说。”、“得到一个结论。”后面紧跟具体内容的伪句号腰斩。
- **逻辑实现**：
  在 `strongIncompleteEnding(_:)` 中增强匹配规则：
  1. **引述谓语动态识别**：去句末标点后以 `说`、`道`、`表示`、`认为`、`指出`、`解释`、`强调`、`称` 结尾，但排除自足短语（如 `这么说`、`怎么说`、`也就是说`、`所说`、`听说`）；
  2. **提示性下文引出识别**：去标点后匹配 `(?:得到|得出|提出|产生|发现|说了|留了)(?:一个|几点|一套)?(?:结论|想法|问题|一句话|评价)$`；
  3. **英文 Lead-in**：匹配以 `says that`、`said that`、`stated that` 结尾。

### 模块 D：顺承副词与口语从属连词扩展（Adverbial & Spoken Starters）

- **目标**：支持解说类叙事顺承与英文口语高频从属连词。
- **逻辑实现**：
  1. `continuationStart(_:)` 中文前缀补充高频叙事顺承副词：
     - `"先后"`, `"一直"`, `"陆续"`, `"随之"`, `"进而"`, `"转而"`, `"从而"`, `"以便"`；
  2. `continuationStart(_:)` 英文前缀补充口语高频连词：
     - `"cause "`, `"'cause "`, `"cuz "`；
  3. 英文条件从句悬空检测（Dangling Conditional Subordination）：
     - 若上一句结尾的未闭合子句是以 `if `, `when `, `while `, `after `, `because `, `cause ` 引导且未出现主句，赋予 `strongIncomplete` 判定。

---

## 4. 实施与回归测试矩阵

| 测试项 | 输入数据 | 预期判定 |
| :--- | :--- | :--- |
| **测试 1：引述句引号穿透与防反向吸附** | L1: `成立了Anthropic。`<br>L2: `……说过一句话：“……愿景。”` | **不合并**（两句各自独立，L2 被正确识别为终结句，杜绝反向吸附） |
| **测试 2：动作链顺承合并** | L1: `离开了 OpenAI。`<br>L2: `成立了Anthropic。` (Gap 0ms) | **正确合并**（顺承动词+时态助词自然闭合） |
| **测试 3：动态引述导语断尾缝合** | L1: `……前员工说。`<br>L2: `这感觉就像听牧师布道。` (Gap 0ms) | **正确合并**并去除前句伪句号 |
| **测试 4：提示性结论断尾缝合** | L1: `……他得到一个结论。`<br>L2: `AI太危险了。` (Gap 0ms) | **正确合并** |
| **测试 5：顺承履历副词连贯** | L1: `他真懂技术。`<br>L2: `先后在百度、Google干了几年。` | **正确合并** |
| **测试 6：英文条件从句与口语连词** | L1: `...now if you match all ten of these.`<br>L2: `You're gonna walk out of here with a thousand dollars.` | **正确合并**（从句与主句缝合） |
| **测试 7：两独立完整句防粘连守卫** | L1: `第一条完整字幕。`<br>L2: `第二条完整字幕。` (Gap 50ms) | **绝对不合并**（守卫测试保持绿灯） |
