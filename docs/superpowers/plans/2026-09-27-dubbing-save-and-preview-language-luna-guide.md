---
title: "配音显式保存入库与音色试听语种匹配 Luna 实施指导"
status: draft
version: "1.0"
date: 2026-09-27
baseline: "codex/app-service-integration@54e5ec39"
design: "../specs/2026-09-26-app-service-integration-design.md"
---

# 1. 问题结论

本次处理用户反馈的两个独立问题，均在 App 端，服务端无需改动：

| # | 现象 | 根因 | 修复面 |
|---|---|---|---|
| 1 | 配音台点「生成语音」后作品自动进入作品库 | `AppModel.synthesizeAndSave` 生成成功即 `workStore.save`，没有任何用户确认环节 | AppModel + DubbingDeskView：拆分为「生成试听（内存）」与「显式保存入库」两步 |
| 2 | 动感英语男声（ryan）用中文试听文案试听，内容完全不对 | 音色库试听默认文案是中文，App 以 `language=auto` 送给英语音色；服务端按 auto 解析后用英语音色硬读中文，输出怪异 | CreatorSurfaceViews + ServiceAPIClient/AppModel：按音色语种给默认试听文案，并透传匹配的 `language` |

两个问题互不依赖，可分别实施、分别验证。

# 2. 当前实现与根因

## 2.1 问题 1：配音自动入库

- 文件：`macos/SpeechRailApp/SpeechRailApp/AppModel.swift`（`startSynthesisAndSave` 约 2690 行，`synthesizeAndSave` 约 2709 行）、`macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`（`DubbingDeskView.startSynthesis` 约 661 行，`resultBar` 约 500 行）。
- 当前逻辑：`startSynthesis` → `startSynthesisAndSave` → `synthesizeAndSave` 内 `createSpeechRender` 成功后直接构造 `CreativeWork` 并 `workStore.save(work, audioData:)`，随后 `works = try workStore.list()`。`lastCreatedWork` 被用于结果条展示。
- 设计文档 §4 已声明「配音台 `/v1/audio/speech`」「作品重放与导出读取已保存音频」，§7.2 要求「作品重放/导出已保存音频；重新生成才用 `/v1/audio/speech`」，但没有明确「生成后是否自动保存」。用户本次明确：必须显式保存才入库。
- 深层原因：生成（render）与持久化（save）在同一个 async 函数内耦合，没有中间态承载「已生成、未保存」的试听结果。

## 2.2 问题 2：英语音色中文试听内容不对

- 服务端事实（2026-09-27 实测）：`ryan`（动感英语男声）与 `eric` 在 9-26 数据清理后 `name` 已恢复中文（此前英文名 `Energetic English Male` 是旧脏数据问题，已解决）。`GET /v1/voices/ryan` 返回 `description` 与 `instruction` 相同（均为「富有活力和节奏感的英语男声…」），`supports_instruction=false`。服务端 `VoiceProfile` 无 `language` 字段；`description = instruction or ref_text`（`src/speechrail/domain/tts.py` 约 69 行）。
- App 侧事实：音色库详情 `sampleText` 默认 `"这是 SpeechRail 的音色试听。清晰、自然的声音，让每一句表达都恰到好处。"`（`CreatorSurfaceViews.swift` 约 2124 行）；`createSpeech` 固定 `language="auto"`（`ServiceAPIClient.swift` 约 210 行）；`normalize_tts_language` 支持 `en/english` 等别名（`src/speechrail/domain/tts_request.py`）。
- 服务端实测：`eric` + 中文文案 + auto → HTTP 200 7.3s 音频（能出声）；`eric` + 英文文案 → 200 7.0s；`language=english` + 中文 → 200 但内容为空波形感。结论：服务端不拒绝跨语种，但英语音色读中文输出质量怪异——用户所说的「内容完全不对」即此。
- 深层原因：App 没有音色语种概念，试听文案与 `language` 参数都与音色语种脱节。服务端是多语模型但按音色 instruction 语种优化，跨语种试听不在验收口径内。

# 3. 目标行为

1. 配音台点「生成语音」后：音频在配音台结果条可试听，可导出，但**不进入**「我的作品」列表；结果条出现「保存到作品库」按钮，用户点击后才 `workStore.save` 并刷新列表。
2. 生成失败、取消、离开页面：未保存的内存音频丢弃，不留任何作品记录。
3. 音色库试听：英语音色（ryan/aiden）默认试听文案为英文，日语音色（ono_anna）为日文，韩语（sohee）为韩文，中文音色保持当前中文文案；用户仍可手动改写（不强制）。
4. 试听请求携带与文案语种匹配的 `language`（或沿用 auto 但文案已匹配）；至少默认路径不再出现「英语音色读中文」。

# 4. 推荐解决方案

## 问题 1：生成与保存分离（推荐 A）

- A（推荐）：`synthesizeAndSave` 拆为 `synthesizePreview`（返回内存音频 + render 身份，不写盘）与 `savePreviewToLibrary`（显式保存）。`lastCreatedWork` 改为承载「未保存试听结果」或新增 `PendingWork` 状态。改动集中在 AppModel + 配音台结果条。
- B（备选）：生成后自动保存但加「撤销」按钮。不选：违背用户「显式保存才入库」的明确要求，且删除已落盘音频增加失败路径。

## 问题 2：按音色语种默认文案 + 透传 language（推荐 A）

- A（推荐）：App 端按音色 ID 映射默认语种与默认试听文案；`createSpeech` 新增可选 `language` 参数，试听路径传入匹配值。纯 App 改动，服务端不动。
- B（备选）：服务端给每个 system voice 加 `language` 字段。优点是单一事实源，但涉及契约变更、回归测试，本次反馈的修复成本过高；可作为后续优化项记入风险节。

# 5. 详细实施步骤

## 步骤 1：配音生成与保存分离（AppModel.swift）

- 修改文件：`macos/SpeechRailApp/SpeechRailApp/AppModel.swift`。
- 当前逻辑：`synthesizeAndSave(text:voice:speed:)` 内聚生成+落盘+播放。
- 目标逻辑：
  - 新增内存态：`pendingDubbingAudio: Data?`、`pendingDubbingMeta`（voiceID/voiceName/voiceRevision/planID/scriptText/speed/duration），或复用 `lastCreatedWork` 语义改为「待保存」。
  - `synthesizeAndSave` 改名为 `synthesizePreview`（保留旧名做 deprecated 转发，避免其他调用方编译失败；经查仅 `startSynthesisAndSave` 调用），内部去掉 `workStore.save` / `works.list` / `nextRenderRevision`，保留 `createSpeechRender` + 内存播放 + 包络缓存。
  - 新增 `savePendingWork() -> CreativeWork?`：构造 `CreativeWork`（含 `nextRenderRevision`）、`workStore.save`、`works = list()`，清空 pending 态。失败时 `creatorMessage` 或独立 `worksMessage` 提示。
  - `cancelSynthesis` 取消时丢弃 pending 音频；`onDisappear` 已有 `stopAudio`，追加清空 pending（或保留由用户决定——推荐清空，避免内存音频与列表不一致）。
- 边界：保存时 voice 已被删除 → 按现有 `creatorMessage` 口径报错，不写盘；重复点击保存 → 第二次为 no-op（pending 已空）。

## 步骤 2：配音台结果条加保存按钮（CreatorSurfaceViews.swift）

- 修改文件：`macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`（`DubbingDeskView.resultBar`，约 500–600 行）。
- 当前逻辑：结果条只有播放 / Finder / 导出 / 查看我的作品。
- 目标逻辑：pending 态结果条增加「保存到作品库」主按钮（`buttonStyle(.borderedProminent)` 或与生成同级），点击调用 `model.savePendingWork()`；保存成功后结果条转为已入库态（保留现有展示 + 「查看我的作品」）。
- `canGenerate` 不变；生成中已有「停止」语义，保存按钮在 `isCreatingSpeech` 时禁用。
- 文案：「保存到作品库」；成功提示沿用现有 `worksMessage` 口径。

## 步骤 3：音色语种默认试听文案（CreatorSurfaceViews.swift）

- 修改位置：`VoiceLibraryView.sampleText` 默认值（约 2124 行）、配音台音色选择器试听（约 347 行 `model.startVoicePreview(voice)` 未传 text，走 `previewVoice` 默认 `"你好，这是我的声音。"` 中文）。
- 目标逻辑：新增纯函数，如 `defaultSampleText(for voiceID: String) -> String`：
  - `ryan`、`aiden` → 英文：`"This is a SpeechRail voice preview. Clear, natural, and just right for every line."`
  - `ono_anna` → 日文：`"こちらは SpeechRail の音声プレビューです。クリアで自然な声をお届けします。"`
  - `sohee` → 韩文：`"SpeechRail 음성 미리듣기입니다.清晰하고 자연스러운 목소리를 들어보세요."`（需母语者润色，见 §9）
  - 其余（含中文系、clone、instruction）→ 保持现有中文默认。
- `sampleText` 初始化及切换音色时：仅当用户未手动改过（用 `@State var sampleTextEdited = false` 或对比默认值）才跟随切换，避免覆盖用户输入。
- 配音台选择器内联试听同样按选中音色取默认文案，而非硬编码中文。

## 步骤 4：试听 language 透传（ServiceAPIClient.swift + AppModel.swift）

- `ServiceAPIClient.createSpeech` 新增参数 `language: String? = nil`，nil 时保持 `"auto"`（兼容现有调用）。
- `AppModel.previewVoice` / `createSpeech` 透传按步骤 3 语种映射出的 language 值（`zh→"chinese"`，`en→"english"`，`ja→"japanese"`，`ko→"korean"`；映射表与服务端 `_LANGUAGE_ALIASES` 对齐）。
- 配音台正式制作 `createSpeechRender` 保持 `auto`（用户文稿语种未知，不猜）。
- `previewVoice` 缓存 key 追加 language：`"\(voice.id):\(speed):\(language):\(previewText)"`，避免同文案不同语种命中错缓存。

## 步骤 5：设计文档补丁（docs/superpowers/specs/2026-09-26-app-service-integration-design.md）

- §4 配音台行追加：「生成后仅内存试听，用户显式保存才入库」。
- §7.2 作品重放/导出行追加禁止项：「禁止生成成功后未经用户确认自动入库」。
- §11 状态呈现追加保存按钮的可用/禁用文案（可选，若改动大可只记行为）。
- 版本号 1.4 → 1.5，date 更新，变更记入 §18 或新增 §19（按文档既有追加方式）。

# 6. 关键实现说明

- 语种映射表（App 端，ID 精确匹配 + 后缀兜底）：
  ```swift
  enum VoicePreviewLanguage: String {
      case chinese = "chinese", english = "english"
      case japanese = "japanese", korean = "korean"
  }
  func previewLanguage(for voiceID: String) -> VoicePreviewLanguage {
      switch voiceID {
      case "ryan", "aiden": return .english
      case "ono_anna": return .japanese
      case "sohee": return .korean
      default: return .chinese
      }
  }
  ```
  自定义 clone/instruction 音色走 default 中文（其 instruction 多为中文；若首字符非 CJK 可后续优化，不在本轮）。
- 缓存 key 变更导致旧缓存失效是预期行为（内存缓存，重启即空）。
- `lastCreatedWork` 若被其他页面（作品列表跳转、`.onChange` 监听约 69 行）依赖，优先新增 `pendingDubbing` 独立状态，避免改动作品列表逻辑。

# 7. 测试方案

| 文件 | 新增用例 | 证明目标 |
|---|---|---|
| `SpeechRailMacControlTests/AppModelTests.swift` | 生成成功后 `works` 数量不变、`savePendingWork` 后 +1；取消后 pending 为空 | 生成≠入库，显式保存才入库 |
| 同上 | `defaultSampleText(ryan)` 为英文、`previewLanguage(ono_anna)==.japanese` | 语种映射正确 |
| `SpeechRailMacControlTests/ServiceContractTests.swift` | `createSpeech` 传 language 时 request body 含该值；nil 时为 auto | language 透传与兼容 |
| `tests/` | 无（纯 App 改动；若改动服务端则需补，但本方案不动服务端） | — |

# 8. 验收标准

- [ ] 配音台生成后「我的作品」数量不变，结果条有「保存到作品库」按钮
- [ ] 点击保存后作品出现，音频可播放，与试听一致
- [ ] 取消/离开后无残留作品
- [ ] ryan/aiden 详情默认试听文案为英文，播放内容为英文
- [ ] 中文音色默认文案不变；用户手改文案不被切换音色覆盖
- [ ] `swift test --package-path macos/SpeechRailApp` 相关 suite 通过（fake transport）
- [ ] 真实 App 手工验收（需用户逐次授权 UI 操作；未授权则标 `not_run`）

验证命令（仓库根）：
```bash
git diff --check
swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
```

# 9. 风险与注意事项

- 日/韩默认文案需母语者润色；当前版本为占位可懂文案，Luna 不得虚构「已请母语者确认」。
- 用户手改试听文案后切换音色不覆盖：用 edited 标记实现，不要用文案内容反推。
- 本方案不动服务端契约、不动作品持久化格式；`CreativeWorkStore` 读写逻辑保留。
- 配音台 `createSpeechRender` 的 receipt/plan 身份在保存时重用 pending 期拿到的值，不重新生成。
- UI 自动化测试需用户逐次明确授权（AGENTS.md 硬约束），方案中不安排自动执行。

# 10. Luna 执行清单

- [ ] 步骤 1：AppModel 生成与保存分离；完成条件：生成后 works 不变，save 后 +1，可独立单测
- [ ] 步骤 2：配音台结果条保存按钮；完成条件：按钮可见、可点、禁用态正确
- [ ] 步骤 3：语种默认试听文案；完成条件：四语种默认值正确，手改不被覆盖
- [ ] 步骤 4：language 透传 + 缓存 key；完成条件：request body 正确，旧调用编译通过
- [ ] 步骤 5：设计文档补丁至 1.5；完成条件：§4/§7.2 行为有文字记录
- [ ] 执行 §8 验证命令并记录结果；未授权 UI 验收标 `not_run`
