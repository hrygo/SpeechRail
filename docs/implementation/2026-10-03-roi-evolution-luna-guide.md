---
title: "SpeechRail 高 ROI 进化路径 — Luna 实施方案"
status: proposed
created: 2026-10-03
reviewed_ref: be75055cc0a5f7f044ae56c955896812a1d69915
source_conversation: 6ac0df0c-9370-83e8-b512-221b5d97f250
implementation_authorized: false
runtime_validation: not_run
---

# SpeechRail 高 ROI 进化路径 — Luna 实施方案

本方案以引用会话《SpeechRail 进化路径》的完整回复为需求材料，按当前源码复核后形成。会话中的 Markdown 报告、源码 ZIP 与证据 ZIP 未取得文件内容；不声称已审阅这些附件。当前本地 `main` HEAD 与原分析基线一致，版本由 `pyproject.toml` 定义为 `3.5.6`，开始分析时工作区干净。核验日期：2026-10-03，Asia/Shanghai。

**本轮只交付方案。** 下文“实施”“新增”“验收”均是 Luna 获得后续实施授权后的工作。没有修改业务代码、运行测试、构建 App、访问运行服务、操作模型、接管窗口或改变远端状态。

方案沿用仓库 `docs/implementation/` 的交付位置。默认首先实施 A、B、C 三包；D–H 是带进入条件的后续路线，不能因阅读本文件自动启动。A/B/C 的真实模型、麦克风、设备、听审、长稳、安装及 UI 检查同样需要对应授权。

> 🧠 **From Hindsight memory (Conventions and patterns)** — 项目历史强调可复现的失败回归、符合实际边界的测试替身、未知值不伪造，以及持久化失败后不推进状态。本方案将这些作为测试与失败处理的背景；具体授权以当前 AGENTS.md 为准。

> 🧠 **From Hindsight memory (SpeechRail 集成与验收入口)** — 历史决策将正式制作与试听的音色门禁分开，并将调用者编排、真实模型验收和局部确定性证据分开。本轮又从 `ServiceAPIClient.createSpeechRender()`、`AppModel.synthesizeAndSave()`、当前文档核实严格制作与显式保存边界；不复用记忆中的部署状态、测试数量或 Issue 开闭状态。

## 1. 问题结论

优先把已有语音能力变成可靠保存、可追溯、可修改、可交付的成果。推荐依赖顺序：

| 包 | 目标 | 相对改动范围 | 进入条件 |
|---|---|---|---|
| A | 作品库提交、删除和恢复一致性 | Swift 存储与相关状态回归 | 首批 |
| B | 实际制作配方 → REST 回执 → App → 已保存作品 | Python/Swift/契约/文档 | 首批；作品持久化依赖 A |
| C | 生产形态回归与正式事实入口对齐 | 现有测试、检查器与定点文档 | 可先做现状回归；最终覆盖 A/B |
| D | 段落重做、对比、采用与成品导出 | 创作领域、存储和 UI | A/B/C 完成；另行确认产品范围 |
| E | 提词器真实表达、设备与长稳验收 | 现有验证工具与设备证据 | 单独授权真实场景 |
| F | 首次成功与升级恢复引导 | 现有安装控制链与 App 引导 | 明确面向非开发者推广 |
| G | 跨 REST/MCP/App 行为一致性 | 当前入口、适配器及契约 | 面向 Agent 服务时提前 |
| H | 按价值交付提取职责 | 每包实际触及的协调逻辑 | 有可测失败边界或维护收益 |

此表是相对投入判断，不是工期、财务 ROI 或性能承诺。外部推广可提前 F，自用口播可提前 E，以 Agent 集成为主可提前 G。

A 的直接问题是先改音频、后改索引，两个文件分别原子写入不能组成一个事务。B 的直接问题是 REST 回执没有计划身份，App 又只落盘少量身份字段；现有资源计划不足以描述文本、语速、发音版本和实际采样策略。C 的问题是已存在真实异步与生产状态回归，但仍需要补齐跨入口和故障恢复证据；同时 active 文档含明确错误事实。

以上属于源码确认的失败窗口和接线缺口，**不是已观测到用户丢失作品、音质不合格或服务不可用**。原会话提及的 3.5.3 对齐迟到、3.5.4 MCP VoiceDesign 问题已有回归与修复路径，不能再作为待修缺陷。

## 2. 当前实现与根因

### 2.1 作品库与显式保存

| 文件与符号 | 当前事实 | 影响 |
|---|---|---|
| `macos/SpeechRailApp/SpeechRailApp/CreativeWorkStore.swift`：`save` | 写 `<id>.wav`，随后 `list` 并 `writeIndex`；同 ID 会替换索引条目和音频 | 索引损坏/写失败可留下孤立音频；同 ID 重试可能改写原音频 |
| 同文件：`delete` | 删除 WAV，然后移除记录并写索引 | 索引失败后记录指向已删除音频；现有注释对这个失败后果的说明不正确 |
| 同文件：`rename` | 重建 `CreativeWork` 后原子写索引 | B 新字段必须完整传递，否则改名会丢制作信息 |
| `AppModel.swift`：`PendingDubbingRender` | 内存冻结文稿、语速、音色、work/render ID、plan ID 和音频 | 这是用户成果保留边界，应沿用 |
| `AppModel.swift`：`savePendingDubbing` | 保存成功后才清空 pending；刷新列表失败另报信息 | 已有正确方向；不要把列表刷新或清理失败当成生成失败 |
| `AppModel.swift`：`synthesizeAndSave` | 实际生成到 pending，显式保存才入库 | 名字不能作为自动保存行为依据 |
| `CreativeWorkStoreTests.swift`、`AppModelTests.swift` | 已测身份往返、旧记录、显式保存、重复保存、失败保留 pending | 缺少写音频之后索引失败和各个崩溃点的系统性覆盖 |

不换 SQLite 的理由是这轮核心一致性问题可在现有 JSON 索引与文件边界解决，避免额外迁移用户资产。新事务必须解决恢复，不能只在 `catch` 里删除新文件：进程退出时 `catch` 不会运行。

### 2.2 制作身份、回执与实际参数

| 文件与符号 | 当前事实 | 实施含义 |
|---|---|---|
| `src/speechrail/http/routes/audio.py`：`speech` | 调用 `render_receipts.begin()` 时传入音色/制品、格式、text/planner summary，没有 `plan_id` | REST 不能从这条路径产生有效 `plan.plan_id` |
| `src/speechrail/application/render_receipts.py`：`RenderReceiptRegistry` | 有界内存注册表；哈希边界为 `pcm16_pre_transport`；终态可淘汰 | 回执不是长期资产；保存作品必须复制必要快照 |
| `src/speechrail/application/plan_resolver.py`、`domain/task_plan.py` | `ResolvedPlan` 绑定资源、制品、输出与 task；digest 含 task ID，未包含制作文本、语速或词典 | 不可把此 digest 当内容复用键，不因存在该类型就宣称 REST 已接入它 |
| `src/speechrail/compatibility/openai_realtime.py`：`plan_fingerprint` | 只哈希 task/asr_model/voice/voice_revision/catalog_revision | Realtime 已有 plan 语义，也不足以证明完整内容配方；B 不顺带改变 wire |
| `ServiceAPIClient.swift`：`createSpeechRender` | 强制 `require_output_pass`；`try? fetchReceipt` 后只取 plan/voice revision，失败仍返回音频 | 保留音频的方向正确，缺少可观测的追溯状态和结果绑定校验 |
| `CreatorServiceClient.swift`：`SpeechRenderResult` | 仅 audioData、planID、voiceRevision；协议默认实现可仅返回音频 | 默认实现必须标明追溯不完整，不能伪造服务端身份 |
| `SpeechRailControlKit/ServiceContractTypes.swift`：`RenderReceipt` | 多个嵌套字段用 `JSONValue` | 应在协议边界增加严格的制作快照投影，不能让 UI 自行解释自由 JSON |
| `CreativeWork` | 未保存 speed、完整模型执行信息、词典版本或回执快照 | 已保存作品在回执淘汰后无法独立解释制作条件 |
| `backends/qwen3_tts.py`、`backends/qwen3_tts_worker.py` | adapter 固定 profile 快照；worker 执行归一化、clone 派生 seed、CustomVoice 可选 seed 与采样配置 | 请求参数不一定等于实际采样参数；不能把 profile.seed 直接当 CustomVoice 的已用 seed |

REST 成功仍返回音频二进制，SpeechRail 扩展沿已有专用头和 receipt 查询承载。B 不向标准 speech body 塞 `plan_id`、词典、recipe 或内部路径。

### 2.3 现有回归与文档漂移

- `tests/mcp/test_tools.py::test_design_voice_uses_reference_voice_design_capability` 已按独立 `models["voice_design"]` 测准入；`application/capability_snapshot.py::build_capability_snapshot` 确认角色独立。继续构造 `models["tts"].variant=voice_design` 的成功 fixture 会再次制造不可达生产状态。
- `tests/test_realtime_openai.py::test_alignment_result_survives_the_turn_moving_on` 已覆盖清理后的对齐返回，但其中部分验证直接调用内部完成函数；C 应补经过真实调度路径、闸门控制的迟到/乱序场景。
- `docs/architecture/current-boundaries.md` active 正文第 6 项写 release `3.3.0`，第 10 项声称 ASR 原生词级时间戳且 aligner 仅用于分人；第 11 项及限制部分仍把 VoiceDesign 与 reference 档绑定，与同文第 3 项和当前实现冲突。
- `docs/developers/issue-95-certification.md` 保留 2026-09-26 的真实未通过项与人工裁定；它不是当前版本已通过证明。沿用其证据结构，新增当前版本分栏，保留原测量。
- 引用会话中的 #95/#118 作为已有跟踪线索；本轮没有读取 GitHub 现行状态，不宣称其仍 OPEN、已关闭或当前验收结果。

### 2.4 证据可靠性

图谱 generation 为 `2026-10-01T23:35:51Z`，使用 `get_code_snippet` 与 `trace_path` 查客户端，再以 `check_index_coverage` 核验 22 个候选路径。`ServiceAPIClient.swift` 的 271–281、`AppModel.swift` 的 1942–1958 和 `ServiceContractTests.swift` 有部分解析缺口；`audio.py`、`realtime_openai.py`、相关测试/MCP/能力文件显示源码已变化。本轮直接读取相关源码范围补足，不重建索引，不把图谱“0 callers”当无调用证明。跨协议调用由协议声明及 `AppModel` 实际调用交叉核实。

## 3. 目标行为

1. **提交确定**：保存返回成功后，索引和 WAV 完整可读；进程在任意事务步骤中退出，重开后按唯一提交点恢复到旧状态或新状态。恢复失败显式报错，原文件保留。
2. **删除可恢复**：删除前索引失败不影响原作品；删除提交后索引不再列出作品，音频进入受管隔离区。清理失败不逆转已提交状态。
3. **用户控制不变**：生成、试听不自动入作品库；保存失败保留相同 pending/work ID 和字节；重复保存同一结果幂等。
4. **制作身份真实**：计划身份、内容配方 digest、一次执行 ID、PCM hash、文件 hash 分开。未知 runtime、seed、timing 或身份为明确未知，不能填随机 UUID 冒充配方。
5. **结果可独立解释**：已保存作品带制作快照，服务重启或回执淘汰不抹掉它；旧作品可读，不推断或回填历史配方。
6. **音频优先保留**：完整音频已经取得时，回执不可获取/不完整不丢音频；追溯信息显示不完整。严格制作准入失败、响应截断或音频损坏不能成为可交付作品。
7. **恢复可验证**：生产可构造状态、取消、迟到、部分出音失败和资源归还均有确定性反例。真实质量和长稳结论必须来自单独实测。

## 4. 推荐解决方案

### 4.1 A：保留索引格式，增加受管事务

保留 `works.json` 的数组格式与 `<workID>.wav` 文件名；新增同卷事务目录、隔离区及注入式文件操作边界。所有读写通过一个作品库事务协调器执行恢复与锁定。**`works.json` 的原子替换是唯一逻辑提交点**，journal 的 phase 只做辅助，恢复以索引原始字节 digest 判定。

拟新增：

- `CreativeWorkFileOperations.swift`：仅封装任务需要的读写、原子替换、同步、移动、锁和受限目录检查，生产实现与故障替身共用接口。
- `CreativeWorkTransaction.swift`：journal、恢复和事务范围；业务对象与 UI 不处理磁盘步骤。
- `CreativeWorkRecoveryReport`：恢复/孤立资产/隔离区计数和明确失败原因；不记录文稿、音频或私人路径到日志。

同 ID 保存改为**不可变成果幂等**：音频字节及制作内容相同则返回原记录，不重写；不同则返回拟新增 `workConflict`。比较排除重试生成的 `createdAt` 与可变显示名称，包含 work ID、script、voice/recipe 身份、制作 revision 和音频 hash。改名仍通过 `rename`；新制作仍产生新 work ID。此项是存储内部行为收紧，须核查所有 `save` 调用并保留现有重复保存测试。

不自动清空隔离区，不因数量阈值删除用户资产；容量不足时拒绝新写入并保留 pending。隔离数据的恢复或清除需要明确用户动作，A 不扩成回收站 UI 产品。

### 4.2 B：资源计划之外增加内容配方

拟新增 `src/speechrail/domain/render_recipe.py` 和 `src/speechrail/application/render_recipe.py`，分别承载不可变类型/规范化编码与从已验证执行事实装配快照。这里是制作领域内容，不复制资源 Governor 或模型选择机制。

REST `plan.plan_id` 标识请求开始时固定的执行描述；新增 `recipe` 保存实际执行配方和完整程度。建议：

- `plan_id = "plan_" + sha256(canonical_execution_descriptor)[:32]`，完整 digest 一并保留；描述含选定角色/制品、音色 revision、有效请求参数、输出格式、归一化与分段策略版本。
- `recipe_digest = sha256(canonical_actual_recipe)`；绑定原文与实际送入声学模型的文本 hash、采样策略、真实 runtime/engine 身份、词典 revision 和输出条件。缺关键事实则不签发可复用的完整 digest。
- `request_id`/`receipt_id` 是一次执行身份；App 的 render/work ID 是本地用户操作身份，不能替代服务执行身份。

新增字段只用于 negotiated REST receipt；`ResolvedPlan`、Realtime `plan_fingerprint` 和现行 WebSocket wire 在 B 保持各自含义。文件与用户文档明确命名空间差异，禁止跨面仅凭相同 `plan_` 前缀判定可复用。完整跨面执行计划统一放到 G，经单独设计和契约评审。

receipt 不持久化原文、音频、参考文本或 instruction 正文；App 作品已有用户显式保存的 script，配方只保存必要元数据/hash。hash 属关联数据，不放 metrics labels，不进入发现快照。文本 hash 不保证隐私匿名，也不证明音质。

### 4.3 C：扩展已有回归和语义检查

复用已有 fake backend、MockTransport、异步闸门和检查器。补充“由真实 builder 生成状态 → 入口准入 → 结果/终态 → 资源释放 → 客户端恢复”的边界测试；测试依然不运行模型。

正式文档移除“当前 release 为固定版本”的重复事实，改为引用 `pyproject.toml`/版本门禁。正文纠正 aligner 与 VoiceDesign 的职责。定点语义检查以有效契约/显式 assertion 为基础，不靠扫描整个仓库是否含禁词，也不限制历史档案中的旧表述。

### 4.4 D–H 的推荐产品边界

- D 第一版只支持整段完整音频作为制作单元，候选试听、显式采用/撤销和完整 WAV/TXT 导出。已有单文件作品继续可用，不自动从块级 timing 反推可编辑段落；需要用户显式创建段落项目。字幕必须有有效 timing，不提供均分伪时间戳。
- E 复用 `TeleprompterReplayEvaluator`、现有阶段报告和设备生命周期测试；真实样本同时覆盖有效推进、误推进、回稿和手动接管，不新增常驻 LLM。
- F 复用既有安装器和 XPC 委托路径。面向用户呈现准备内容、动作及恢复；联网供给与安装单独确认，终点是第一条真实结果。
- G 首先统一同一操作在不同入口的参数拒绝、门禁、错误和恢复语义，不强迫不同产品面的 plan ID 同值。
- H 只提取这轮真正需要的存储事务/制作协调职责，不按大文件行数开展全量拆分。

## 5. 详细实施步骤

以下每单元包含实现与回归，可独立审阅。**本地提交点仅为建议边界，不是自动提交授权。** 项目 AGENTS.md 明确“未被明确要求时不自动提交、推送或创建发布物”，覆盖技能中的默认自动 commit 习惯。若后续用户明确授权提交，再逐单元检查暂存 diff、空白和敏感字段后提交。

### A1 — 建立可注入故障边界

范围：`CreativeWorkStore.swift`、`CreativeWorkStoreTests.swift`；拟新增上述文件操作类型和事务测试文件。

1. 将 `Data.write/read`、目录建立、移动、原子索引替换与同步纳入小接口；仅注入 `FileManager` 无法拦截所有 `Data.write` 失败。
2. 先写“音频写后索引失败”“删除时索引失败”“同 ID 不同字节”等反例。故障替身按命名步骤计数，精确注入 ENOSPC/EACCES 或中断，不按偶然调用次数和 sleep 判断。
3. 为重启测试保留临时目录，创建第二个 store 做恢复；同一次崩溃模拟不执行异常清理，才能覆盖 journal 而非 catch。
4. 每个新源文件加入 `macos/SpeechRailApp/Package.swift` 的 `SpeechRailAppSupport.sources`；核查 Xcode 当前引用方式，仅按需要改 `project.pbxproj`，测试文件不得进入 App 源码组。

完成条件：旧实现可复现目标失败；不读用户实际 Works 目录。建议提交主题：`test: expose creative work persistence failure windows`。

### A2 — 保存事务与恢复

1. 存储每次操作先取得库级锁并恢复未完成事务；读取也不能绕过恢复。锁使用稳定独立文件与有界等待，避免 `works.json` 原子替换令 inode 锁失效。所有 store 实例共享锁规则；不能只依赖某实例的 `@MainActor`。
2. 在音频写入前读取/校验现有索引；坏 JSON 或未来 journal schema 直接报错且保留原文件。
3. 将 WAV 写入 `.transactions/<txID>/new.wav`，校验非空、hash 与预期文件长度；写 old/new index 快照及 journal，完成同步后发布 journal。
4. 新 work ID 的目标 WAV 不允许覆盖未知文件。若已存在但索引不含它，报告孤立资产冲突，不删除、不覆盖。
5. 原子移动已暂存 WAV 到 `<id>.wav`，然后原子替换 `works.json`；两者目录同步，索引替换后进入 committed。
6. 提交前失败按 journal 回滚本事务已发布的新 WAV到受管隔离区；提交后 journal 清理失败记录待恢复，不向用户谎报保存失败。无法确认提交点时返回明确恢复错误，保留全部事务材料。
7. 将 `save` 改为 `@discardableResult` 返回实际已提交的 `CreativeWork`，现有忽略返回值的调用仍可用；`savePendingDubbing` 的 `lastCreatedWork` 和返回值采用该记录。同 ID 幂等返回原记录，避免调用方后生成的 timestamp 重写制作时间；继续按提交结果保留/清空 pending。

完成条件：A1 反例通过；每个持久化步骤中断后重开，能恢复旧或新完整状态；已有旧记录只读测试不因“恢复检查”改写索引。建议提交主题：`fix: commit creative works with recoverable file transactions`。

### A3 — 删除、改名与孤立核对

1. 删除的 journal 固定索引中的真实记录，不能信任调用者传来的陈旧文件信息。
2. 保留 WAV，先原子提交删后索引，再移动 WAV 到 `.recovery/<txID>/` 并保留相应记录信息。索引提交前失败，原作品不动；提交后中断，恢复时完成隔离。
3. 改名仅更新索引，保持原音频和全部制作快照；操作前同样完成恢复。改名不改 recipe digest。
4. 只核对受管命名的 WAV 与索引/事务关系；未能证明归属的文件保留原位，报告“存在待检查文件”。不要伪造作品把孤立音频强行纳入索引。
5. `audioURL`/`loadAudio` 校验路径不逃出 Works，不跟随未知符号链接；索引引用缺失文件返回具体缺失状态，不能重写成空作品库。
6. 修改现有错误注释，用户信息沿现有 `creatorMessage`/`worksMessage` 展示。无须在 A 重新设计作品页。

完成条件：删除故障矩阵、第二次恢复幂等、改名字段保留和隔离区空间不足用例通过。建议提交主题：`fix: retain recoverable audio across creative work deletion`。

### B1 — 先冻结配方契约与纯函数

范围：拟新增 render recipe 领域/应用模块及测试；`contracts/openapi.yaml`、`tests/test_render_receipts.py`。

1. 定义第 6 节字段、hash 口径、缺失原因和版本；receipt 的 `recipe` 可为空，因为无音频、其他面或不支持的 backend 不能伪造。
2. Canonical JSON 由服务端唯一生成，键排序、UTF-8、无空白、`allow_nan=False`；显式 null 与缺省不能混用。有限数值转换按固定类型，语速用统一十进制字符串参与 digest。
3. 原文只为 hash 计算在请求内存使用，不能加到 `_ReceiptState`。配方参与 digest 的字段由 schema 白名单确定，不包含执行 ID、时间、title、绝对路径或 JSON 字段顺序。
4. 纯函数测试同配方稳定、文本/语速/词典/模型/采样改变失效、缺关键事实不产生可信 digest、metadata 不泄露。

完成条件：契约描述与纯函数反例明确，尚不能据此宣称真实模型配方已完整。建议提交主题：`feat: define versioned render recipe identities`。

### B2 — 接入真实 REST 执行与 worker 事实

范围：`audio.py::speech`、`render_receipts.py`、`qwen3_tts.py`、`qwen3_tts_worker.py`，必要的内部帧/音频数据类型和其回归测试。

1. 在请求校验、音色/制品选择、词典固定后建立不可变执行描述，传 `plan_id` 和初始 recipe 给 `RenderReceiptRegistry.begin`。描述使用实际 preset voice 与 validated speed/language；所有语义来源与待执行 `SpeechRequest` 一致。
2. 在 `prepare_validated_speech` 后获取被准入的 runtime revision；实际 worker 元数据只绑定到本次 response/request，不从全局“上次调用”字段读取。
3. 为 worker 增加拟新增的安全执行元数据投影：归一化版本、实际文本 hash、实际分段版本/配置、采样控制及 engine/runtime 身份。通过首个合法音频帧携带或独立有版本 metadata 帧传递；两种中推荐独立 metadata 帧，adapter 校验后向应用提供一次性不可变快照。实施前核查当前帧解析器和协议版本机制，复用现有 version，不引入第二套 IPC。
4. 元数据必须来自实际 call kwargs 与最终输入边界。CustomVoice 缺 seed 应标 `ambient`，不能记 profile.seed；clone 使用既有派生策略，可记录策略版本/每段实际 seed，不能公开参考文本；MLX seed 调用未成功时不得记作已固定。新元数据路径不改变采样行为。
5. 只支持 metadata 的真实后端才能标完整；其他 backend/fake 没有字段时 recipe 是 partial，不以“模型配置存在”代替观测。必要时增加可注入 metadata fake，覆盖真实 adapter 验证。
6. 所有音频仍经 `iter_validated_audio`；只接受相同请求与 pending receipt 的 metadata，重复同值幂等，冲突/迟到不覆盖。完成音频后封存完整 recipe digest；cancel/error 不产生 completed 可信配方。
7. `RenderReceiptRegistry` 保持原有容量和淘汰规则，metadata 随条目同生命周期。不得另建不受限映射；协议帧只传白名单字段，不含文件系统路径、prompt、音频或 embedding。

完成条件：通过真实路由生成非空 plan ID；completed receipt 的配方描述实际请求和 adapter 观测；未知与冲突用例 fail-closed。建议提交主题：`feat: bind REST render receipts to observed production recipes`。

注意：worker 侧元数据涉及内部公共接口与打包 worker，应在专门逻辑单元内同步帧、adapter、fake 与测试。若无法安全取得实际分段/采样事实，可以交付 partial 配方并报告缺项，**不能把 B 的完整配方验收勾为完成**。

### B3 — App 接收、冻结和持久化

范围：`ServiceContractTypes.swift`、`ServiceAPIClient.swift`、`CreatorServiceClient.swift`、`AppModel.swift`、`CreativeWorkStore.swift` 及相关测试。

1. 拟新增 Codable/Sendable 的 `RenderProvenanceSnapshot` 和 `RenderProvenanceState`；公共 wire 按 snake_case，作品原有字段保留既定编码，勿顺手改变整个 `works.json`。
2. `createSpeechRender` 验证 receipt ID、request ID、status、voice/model expected revision；请求期望 revision 只记 requested，不能因为回执缺失就标 observed。
3. 非流式 WAV 成功后检查合法 RIFF/WAVE、PCM16、采样率、channel、完整 data chunk；不能靠固定 44 字节头提取 PCM。保存 `audio_file_sha256`，再从真实 PCM 计算 hash 与回执 `pcm_sha256` 比对。
4. 追溯分三类：verified（完整且匹配）、incomplete（取不到/缺 metadata/不支持）、mismatch（回执关联或完整性冲突）。incomplete 可保存完整音频，禁作可信缓存；mismatch 保留本地字节，禁止自动标为正式完成和可信复用，给用户明确检查/重新生成动作。
5. receipt 获取使用现有有界请求超时；pending 状态只做明确有限补取，不能无限轮询。请求结束和元数据补取分别处理，取消补取不抹掉已完成完整音频；真正取消尚未完成合成不创建成品。
6. `SpeechRenderResult`、`PendingDubbingRender`、`CreativeWork` 贯通同一快照；保存取 frozen pending，不读取当前 UI。`rename` 复制完整快照。
7. 旧作品缺新字段：`legacyUnknown`，只读不回写，正常试听和导出；无历史 speed/runtime 不能猜成当前默认值。未知未来 snapshot schema 保留原索引，不覆盖降级保存。
8. 可沿用作品详情/反馈区展示“制作信息完整”“制作信息暂不完整，音频已保留”“音频与制作信息不一致，请检查”。实际 UI 修改前读取设计系统相关段落；首屏不出现 recipe/digest 等开发术语。

完成条件：完整快照离线往返，改变 UI/音色目录/服务重启不改变旧作品；receipt 404/timeout/坏 JSON 仍保留音频与 incomplete；错误 hash 和关联不能成为 verified。建议提交主题：`feat: preserve verified render provenance in saved works`。

### C1 — 生产形态回归

1. `tests/mcp/test_tools.py` / `test_capability_snapshot.py`：复用实际 catalog 和 `build_capability_snapshot` 生成状态。系统声音只走 CustomVoice/Base，VoiceDesign 作为独立 peer；有/无设计制品与冷/热态分别验证，测试不以“已 ready”假设替代懒加载可服务状态。
2. `tests/test_realtime_openai.py`：在 aligner await 入口用 `asyncio.Event` 控制；A turn completed 后推进 B turn，再释放 A，断言 A 唯一终态带 A 的 ID/revision，B 不污染。重配 wire epoch、close、timeout 场景按现有契约区分“旧 turn 可归属”与“旧 session 不可送达”，资源均归还。
3. `tests/test_render_receipt_routes.py` / `test_speech_api.py`：合法 PCM 后 vendor error、非法奇数字节、空音频、客户端取消、编码失败，receipt 不得 completed；音频/metadata 到达顺序可控，不用固定 sleep。
4. `tests/mcp/test_client.py` / `test_tools.py`：从真实 REST error envelope 构造响应，断言 code/status/request_id/retryable 与恢复提示不失真；不向成功音频使用 JSON decoder。
5. `ServiceContractTests.swift` / `AppModelTests.swift`：用已有请求捕获机制返回真实形状 receipt，覆盖 A/B 字段；补同一个 pending 在失败后重试，不能只创建另一份新生成证明“可重试”。
6. 检查现有回归覆盖，已充分覆盖的用例复用或强化；只为新时序/边界增加测试，不重复同类成功 fixture。

完成条件：每项新回归在对应错误实现/有针对性的故障注入下确实失败；测试不加载模型、不使用私人音频、不访问运行服务。建议提交主题：`test: cover production capability and asynchronous recovery boundaries`。

### C2 — 文档与定点语义门禁

范围：`current-boundaries.md`、`api-contract.md`、相关生效能力文档、`check_user_doc_contract.py`、`tests/test_user_doc_contract.py`；按变更更新专业文档。

1. 删除当前 release 固定正文值，改链接到版本定义；文档 frontmatter 是文档自身修订版本，不能机械改成产品 release。
2. 删除原生词级时间戳主张：正文冻结后由独立 aligner 求边界，按当前配置与 readiness 披露；无 aligner 不影响允许的纯文字 ASR，但要求时间戳的调用按有效契约失败。
3. 统一 VoiceDesign 独立于三档 TTS spec，清理“reference 另含设计 lane”等冲突句；保留历史 BF16 使用记录的日期和适用范围。
4. 更新 recipe、hash 边界、TTL/淘汰、补取失败、未知值、不可缓存与用户恢复操作的 API 说明；不自动改根双语 README。
5. 扩展现有检查器到限定 active 小节/明确语义锚点；读取 parser 能校验的契约字段，并用坏文档 fixture 证明它会失败。不得只用“文档出现了某词”宣布语义正确。
6. #95 证据只新增当前版本“待执行/确定性/真实/未达”条目，不能改日期把旧 benchmark 变新结果；远端跟踪更新或关闭单独授权。

完成条件：检查器在正确 fixture 通过、反例失败；历史实测不改写；新字段、状态与拒绝/恢复表逐项对应实现。建议提交主题：`docs: align current capability and render recovery semantics`。

### D–H — 后续工作包的落地指引

| 包 | 已知入口 | 下一阶段具体任务与完成条件 |
|---|---|---|
| D | `CreativeWorkStore`、`PendingDubbingRender`、`CreatorSurfaceViews.swift`、`tts_text_planner.py` | 拟新增 `DubbingProject`、`DubbingSegment`、`DubbingCandidate`；项目持有 accepted segment IDs 与完整 recipe；候选保存但不覆盖已采用音频，采用一次事务更新，撤销引用前一版。分段优先段落，超限沿现有 planner。未知依赖全部失效，不截取不可信 timing；导出校验格式一致，重新写 WAV header，TXT 对应被采用文本。先做领域/事务，再经设计系统做渐进 UI。新 schema 与导出覆盖行为必须另行定稿 |
| E | `TeleprompterSession.swift`、`TeleprompterFollowController.swift`、`TeleprompterReplayEvaluator.swift`、既有开发文档/实施报告 | 固定脱敏稿件及 read/pause/improvise/return 标注；真实口播覆盖数字/缩写/重复段、掉线、USB 拔插、蓝牙重连、停止/离开释放与手动接管。有效推进、错误推进、回稿恢复均有触发样本；仅零误推进不通过。先读取现有 §11.6/11.7 阈值，未定义的设备条件先定测量口径；不新增常驻模型 |
| F | `docs/operations/README.md`、既有 local-deploy/release/zero-setup 技能、`ControlAgentRegistration.swift`、`ServiceAPIClient` | 先只读识别安装/配置/能力缺口；列准备内容和影响，再按专项授权调用受管安装器。App 通过受限 XPC 委托 CLI；不直接 launchctl、手改 plist 或下载模型。失败保留旧 runtime/selection，恢复后完成首条真实结果；产品不以 readyz 200 结束 |
| G | REST `audio.py`、MCP `client.py/tools.py`、Swift `ServiceAPIClient`、既有契约 fixtures | 为同一业务操作建立共享有效/拒绝样例，统一严格门禁、expected revision、pronunciation、错误与部分结果政策。MCP 继续无状态，不创建实时会话；jobs 是否启用依实际 capability。若扩展 jobs/Realtime recipe，须单独核查各自执行边界和版本 |
| H | `AppModel.swift` 与 A/B 提取出的存储/制作边界 | 仅在相同业务单元内提取 coordinator，明确 task、取消、pending 与错误状态所有者；以减少跨模块状态联动、改善故障注入为验收。禁止把“文件变短”当验收指标 |

## 6. 关键实现说明

### 6.1 文件事务状态与恢复判定

journal 拟定义为 `schema_version=1`，包含 tx ID、operation、work ID、旧/新索引 digest、受管相对路径、audio hash 与 phase。不含用户正文；旧/新索引快照本身含用户作品数据，因此属于仓库外用户库，按同等权限保护。

| 崩溃位置 | 磁盘事实 | 恢复规则 |
|---|---|---|
| journal 发布前 | 仅 tx 临时材料；索引未变 | 不把它当已提交作品；保留待清理临时材料，不覆盖任何正式文件 |
| 保存 WAV 发布后、索引替换前 | 旧索引 + journal 对应新 WAV | 确认 hash/归属后回滚到隔离区；索引保持旧状态 |
| 索引替换后、phase 更新前 | 当前索引 digest 等于 new | 视为 committed；save 保留新 WAV，delete 完成隔离 |
| 删除索引替换前 | 旧索引 + 原 WAV | 保留作品，移除未提交意图只在可安全恢复后进行 |
| 清理后再次恢复 | 无未完成事务或终态材料 | 幂等，不重复移动、增添作品或改变时间 |
| 当前索引不匹配 old/new | 未知写入或损坏 | fail-closed，保留文件，禁止覆盖未知状态 |

“索引不存在”与“空数组”必须采用不同 digest/状态；恢复不能将坏索引当空列表。每库同时最多一个未归档事务：已提交但未完成归档时允许返回提交结果和安全读取，阻止下一次变更；或先将已完成记录原子转入独立终态区，再开放变更。不能让后续索引修改使旧 journal 的 old/new digest 判定失效。终态区不重新执行事务，只保留恢复资产和清理状态。

移动与替换必须同卷原子，暂存不使用系统临时目录。采用文件/目录同步策略，并测试进程中断；未做电源故障实测前不承诺断电或硬件失效下零损失。

锁、受管路径校验与恢复应覆盖 `list/save/delete/rename/loadAudio/audioURL/nextRenderRevision`；恢复只能变更 journal 精确指向且 hash 相符的本事务文件。未知格式/路径/symlink 不执行恢复动作。journal 不能成为任意文件移动或删除入口。

### 6.2 配方最小字段

以下均为**拟新增 schema**，不是现行 API 字段：

```text
recipe.schema_version = render_recipe_v1
recipe.state = complete | partial
recipe.missing_fields = [枚举字段名]
recipe.content:
  raw_text_sha256
  acoustic_text_sha256
  normalization_revision
  planner_revision / planner_configuration
  pronunciation_set_id / pronunciation_revision
recipe.voice:
  id / revision / mode
recipe.model:
  role / artifact / artifact_revision
  engine_revision / observed_runtime_revision
recipe.parameters:
  effective_speed / effective_language
  seed_policy / observed_sampling_parameters
  output_format / sample_rate / channels
recipe.digest = 完整时的 SHA-256，否则 null
```

没有词典是明确“未使用”，不是未知；采样 `ambient` 是已确认的非固定策略，仍可追溯，但不得据此宣称逐位可重现。recipe complete 表示必要事实完整，不表示 deterministic、可缓存、质量合格或当前音色仍可使用。B 不开启自动缓存；D 的缓存门另验相邻语境、策略、当前门禁与制品。

App 持久化快照至少包含 recipe、plan 完整 digest、request/receipt ID、receipt 终态、观测音色/model revision、PCM hash/边界、实际 WAV 文件 hash、provenance state/reason。源码版本若不是实际 engine/runtime 观测，不填成 engine revision。

### 6.3 两个哈希不可互换

- `pcm_sha256`：服务端回执定义的 PCM16 编码前字节；对完整 WAV 应解析 data chunk，而非哈希 WAV 整体。
- `audio_file_sha256`：实际保存/导出的完整文件字节，包括 container/header。
- 有损编码解码后的 PCM 不等于编码前 PCM；B 的正式创作路径为 WAV，可验证无损对应。通用客户端接到 MP3 不得照搬 WAV 的 verified 判断。
- hash 证明字节对应，不能证明内容读对、音色相似、自然度或制作结果跨设备可重现。

### 6.4 D 的失效与采用规则

后续段落复用键包含 actual recipe、文本/原文映射版本、分段边界、明确上下文依赖、模型/音色 revision、采样策略与输出处理策略。文稿编辑、词典变化、相邻语境改变、采样未固定或 metadata 不完整时保守重做；不得用全文 plan ID 代替段落依赖。

候选属于新资产，采用仅更新项目引用；撤销不修改旧音频。拼接使用真实整段样本、明确停顿规则和统一格式；不得在内容区任意 crossfade 丢字或用静音拉长冒充对齐。响度/韵律收益通过单独听审验证，A/B/C 不宣称已经解决。

## 7. 测试方案

拟新增测试名只表述验收意图，Luna 按最终类型命名。现有文件路径已核实，新文件明确标为“拟新增”。

| 组 | 测试位置 | 必须覆盖的断言 |
|---|---|---|
| A-save | `CreativeWorkStoreTests.swift`；拟新增 `CreativeWorkTransactionTests.swift` | ENOSPC/EACCES 分别发生于 staging、journal、audio publish、index replace；失败保留旧作品和 pending；提交后清理失败仍成功 |
| A-crash | 同上 | 每个持久化步骤后模拟无 catch 中断，再新建 store；old/new digest 判断正确，第二次恢复幂等 |
| A-delete | 同上 | 提交前索引失败原 WAV 可读；提交后隔离失败恢复成功；重复删除幂等；不移动未知文件 |
| A-data | 同上 | 同 ID 同内容幂等且不改时间，不同内容冲突；坏索引/未来 schema/symlink/孤立 WAV 不覆盖；读旧作品不回写 |
| A-App | `AppModelTests.swift` | 失败后同一 pending/work ID 重试；列表刷新失败不重生成、不清除已保存成果；rename 不丢快照 |
| B-domain | 拟新增 `tests/test_render_recipe.py` | canonical hash 固定向量；Unicode、有限数值、null/缺省；参数变更失效；未知 metadata 不伪造 |
| B-route | `test_render_receipt_routes.py`、`test_render_receipts.py` | 真实路由产生 plan/recipe；PCM hash 与格式边界不变；runtime unknown/metadata 冲突/满容量；error/cancel 不 completed |
| B-worker | `tests/test_qwen3_tts.py`、`tests/test_qwen3_tts_worker.py` | metadata 对实际 kwargs；clone 与 CustomVoice seed 差异、归一化、分段；无私密内容；迟到帧不串请求 |
| B-Swift | `ServiceContractTests.swift`、`AppModelTests.swift`、`CreativeWorkStoreTests.swift` | receipt 404/timeout/pending/malformed/mismatch；RIFF 非固定头、截断/错格式；冻结快照、离线可读和 legacyUnknown |
| C-MCP | `tests/mcp/test_tools.py`、`test_client.py`、`test_safe_discovery.py` | 真实 builder 状态；独立设计角色；安全错误字段透传；不泄露 recipe 文本/路径 |
| C-async | `tests/test_realtime_openai.py` | A/B turn 乱序、commit 清理、close、timeout、cancel；一个终态、正确 ID、资源可再次获取 |
| C-doc | `tests/test_user_doc_contract.py`；按需要拟新增 `tests/test_current_boundaries_contract.py` | 正确/错误 active fixture，历史区不误报，检查器不可恒真 |

任何测试替身声明 complete recipe 都必须提供相应合法观测。不得靠修改 production 门槛、放宽 strict policy 或复制虚构 runtime 让测试通过。

真实听审、长稳、设备拔插、首次真实结果和 UI 不属于这些确定性断言。它们有独立证据状态，不替代或被替代。

## 8. 验收标准

### 8.1 本轮已有证据

- [x] 读取引用会话完整回复，核实本地 HEAD 与其基线一致。
- [x] 只读核实关键代码、现有测试、契约和 active 文档。
- [x] 读取相关 Hindsight 页，图谱路径覆盖检查后补源码。
- [ ] A/B/C 实现与回归——未执行。
- [ ] 真实模型、听审、设备、长稳、UI、安装、发布——未执行。

### 8.2 Luna 获得实施授权后的最小验证命令

以下全部是**待执行**。在仓库根目录运行，只选择已修改逻辑对应的命令。`--no-sync` 避免验证时隐式准备依赖；缺开发依赖就报告条件，不擅自下载。新增测试文件创建后再将其加入定向命令。

```bash
git status --short --branch
git rev-parse HEAD

# A：定向 Swift 测试（不是完整测试套件）
swift test --package-path macos/SpeechRailApp --skip-update --filter CreativeWorkStoreTests
swift test --package-path macos/SpeechRailApp --skip-update --filter CreativeWorkTransactionTests
swift test --package-path macos/SpeechRailApp --skip-update --filter 'AppModelTests.test(FailedSave|ExplicitSave|SavedWork)'

# B：已有回执测试 + 新纯函数测试
uv run --no-sync --extra dev pytest \
  tests/test_render_receipts.py tests/test_render_receipt_routes.py \
  tests/test_render_recipe.py -q --no-cov
swift test --package-path macos/SpeechRailApp --skip-update --filter ServiceContractTests

# C：只执行相关生产边界子集
uv run --no-sync --extra dev pytest tests/mcp/test_tools.py \
  -k 'design_voice or synthesize' -q --no-cov
uv run --no-sync --extra dev pytest tests/test_realtime_openai.py \
  -k 'alignment or cancel' -q --no-cov
uv run --no-sync --extra dev pytest tests/test_user_doc_contract.py -q --no-cov

# 按变更运行必要契约与静态检查
uv run --no-sync python scripts/check_openapi_contract.py
uv run --no-sync python scripts/check_user_doc_contract.py
uv run --no-sync python scripts/check_version_consistency.py
git diff --check
```

B2 worker 测试文件和最终新增测试类以实际落地名称补入命令，不运行与本包无关的大集合。Python 变更对所改文件执行 `ruff check <files>`，涉及类型边界时执行 `mypy src/speechrail`；不把全仓格式化作为验收。涉及 MCP 参数或 tool 面时追加 `check_mcp_tool_contract.py`；仅文档修改不要求跑所有 Python 测试。

Swift 仅 SPM 测试不能证明 UI/Xcode 引用正确。触及 App/View 或新源文件挂载且已有构建授权时，先读 release 技能，再使用包装脚本：

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_build.sh --configuration Debug --test-unit -- \
  -only-testing:SpeechRailAppTests/CreativeWorkStoreTests
plutil -lint macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj
```

新增测试类按实际 Xcode target 定向追加。`scripts/macos_app_test.sh` 默认可能包含 UI，不作为默认验收命令。完整 gate、真实签名、Release/安装和 UI 自动化按项目规则另行授权。检查失败只修本包原因，不顺手升级工具链。

### 8.3 行为 Checklist

- [ ] 保存/删除每个关键失败点与重启恢复均覆盖；所有成功作品能从索引找到真实音频。
- [ ] 无事务保护的音频覆盖/删除路径已移除；未知文件不被清理，原作品没有丢失。
- [ ] 原用户库格式可读，旧记录不伪造身份，未来版本不被当前写入器破坏。
- [ ] 真实 REST 生成 plan ID；实际 recipe 与执行参数同源，完整/部分状态有真实依据。
- [ ] 请求、回执、PCM 与保存文件关联已校验；不把 header 字节 hash 当 PCM hash。
- [ ] 回执获取失败仍保留完整 pending 音频，strict 准入失败不会产生成品。
- [ ] 已保存制作快照在重启/淘汰/改名/当前 UI 变化后不变。
- [ ] C 测试覆盖真实可构造状态及迟到/乱序；失败后资源能够重新准入。
- [ ] active 文档不再承诺原生词级时间戳或按档绑定 VoiceDesign，历史测量身份保留。
- [ ] 报告列 SHA、改动文件、实际命令/结果、跳过项与风险；没有实测的质量/性能保持待验。

## 9. 风险与注意事项

1. **资产格式与回退**：A 保留旧索引格式，B 增加 optional 制作快照。旧 App 虽能读未知字段，也可能在改名/写索引时丢字段；写入 B 后不得把运行中的 App 直接降级当安全回退。实施前只在临时库验证迁移；接触真实库先取得授权并做完整库快照。回退程序与用户库分别处理，不用旧备份覆盖新作品。
2. **恢复也是写入**：自动恢复只处理已确认属于本库事务的文件；无 journal 的孤立文件、坏 hash 或未知索引不自动移动/删除。若用户只要求诊断真实库，用只读审计入口，不调用可写恢复。
3. **隔离区增长**：保留删除资产会增加磁盘占用。A 必须显示/报告数量与占用并在空间不足时明确拒绝写入；清除策略或回收站产品单独确认，不设后台自动 purge。
4. **完整配方的成本**：B2 真正取得执行侧分段和采样事实比随机补 UUID 范围更大，涉及 worker IPC。可以先交付标 partial 的快照，但不能缩减验收口径后称“完整贯通”。因此 B1/B2/B3 独立可审阅。
5. **性能**：A 同步 I/O 可能影响 MainActor；B hash 应避免多份音频拷贝。先保持现有有界输入与正确性，必要时把存储 I/O 放专用串行执行边界，await 前后仍由 AppModel 明确管理 pending。没有测量不宣称性能提升，也不做无授权 benchmark。
6. **安全与隐私**：metadata 白名单、相对路径、锁、symlink 和 schema 校验是本轮直接需要的边界；不要输出用户完整正文、音频、参考文本、绝对模型路径或 credentials。诊断用 code/计数，不把高基数 hash 当 Prometheus 标签。
7. **随机与跨文本质量**：实际 seed、runtime identity 与 recipe digest 不保证声学结果逐位相同，不替代输出门禁、听审或拼接自然度。采样事实 unknown/ambient 时禁止确定性复用承诺。
8. **证据时效**：方案基于指定 HEAD；Luna 开始前复核新提交和工作区。#95/#118 状态及真实设备证据需要现行读取，远端更新/关闭不在方案授权内。
9. **scope**：不引入新模型、微服务、第二 ASGI worker、旧平台兼容或通用 Agent 平台；不恢复已移除的提词器逐句事实审阅。D–H 不在 A/B/C 中顺带实现。
10. **运行态回退**：本方案没有执行安装或服务替换。后续若发布，按专项技能保留上一受管 release、配置与 selection；App 唯一正式路径和 LaunchServices 验证按 release 流程，不能手改 runtime/current 或用模糊进程匹配。

## 10. Luna 执行清单

1. **核对授权与基线**：读取当前 AGENTS.md，检查 HEAD/工作区和本方案时效；确定本次包范围、测试/构建、提交及运行态授权。方案生成本身不等于实施授权。
2. **执行 A1**：建注入文件操作边界，先证明跨文件失败窗口；不读真实用户库。
3. **执行 A2**：落实唯一索引提交点、journal、同 ID 幂等/冲突和可重复恢复；跑定向存储回归。
4. **执行 A3**：删除后隔离、改名保留字段、孤立核对与安全路径；测试异常后仍能读原作品。
5. **执行 B1**：冻结 recipe schema、canonical digest 和 plan/执行/hash 区分；先完成纯函数与契约反例。
6. **执行 B2**：从真实请求/adapter/worker 绑定配方，不猜 runtime 或采样；实现后回归未知/错误/取消与 metadata 冲突。
7. **执行 B3**：typed projection → render → frozen pending → CreativeWork；hash/关联检验及 receipt 不完整保留音频；旧作品离线可用。
8. **执行 C1**：复用已有回归补 production builder、受控异步乱序、部分失败和同 pending 重试；不重复修已解决缺陷。
9. **执行 C2**：纠正 active 事实入口并增加坏 fixture；保留历史未通过项与日期，当前实测只登记真正执行内容。
10. **完成静态验收**：执行本次影响范围的 §8 命令和行为检查；涉及 App 构建则用已授权包装脚本，禁止默认 UI。
11. **整理提交边界**：有明确提交授权时逐单元暂存本任务文件，检查 staged diff、空白和敏感字段，创建 `<type>: <why>` 本地 commit；无授权时交付未提交 diff。不得推送、合并、发布或关闭 Issue。
12. **交付**：汇总 A/B/C 实际状态、验证日期/HEAD、测试结果、数据格式影响、回退方式及未验风险；已授权提交时附 commit hash，否则说明未提交。前三包验收满足后，再评审 D–H 的进入条件。

下一阶段成果应是“用户能可靠保存一次制作并解释它的真实来源”，不能以文件已创建、测试退出码为零或计划清单全勾代替这个行为验收。
