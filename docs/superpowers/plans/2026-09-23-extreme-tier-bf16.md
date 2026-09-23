# Extreme（极致）第四档实施计划与验收门禁

> **For agentic workers:** 按 `executing-plans` 逐任务实施和复核。本计划不要求子代理；不得因计划自动执行发布、真实推理、性能测试或 UI 自动化。

**Goal:** 在保持 REST/Realtime 端点形状、worker 协议、调度与分人链路不变的前提下，完成 `extreme` 候选档的服务、App、MCP、契约和文档实现。

**Architecture:** `extreme` 仅更换 ASR、VoiceDesign 与 Base 权重为 bf16，复用 `aligner-bf16` 和现有能力路由。服务端目录及 selection 是档位事实源；App 通过当前目录、健康及能力快照展示；MCP 只代理当前档位的能力，永不切档。

**Tech Stack:** Python 3.12、Pydantic v2、FastAPI、Swift 6.4 / SwiftUI（macOS 26+）、MCP REST 代理、OpenAPI 3.1。

**Spec:** `docs/superpowers/specs/2026-09-23-extreme-tier-bf16-design.md`、[GitHub #80](https://github.com/hrygo/SpeechRail/issues/80)；本计划中的「已确认执行边界」优先于草案中尚未验证的推算及旧发布顺序。

## 已确认执行边界

- 当前在隔离候选 worktree 分支 `codex/extreme-tier-bf16-candidate` 执行；基线 `f60b30e2`。共享 `main` 上的 25 个并行改动保持未修改。G0–G8 候选实现与静态门已通过；本地制品复核、G6 实际视觉/无障碍走查仍为 `UNVERIFIED`，独立全分支复核与 issue 状态记录待完成。
- 用户明确要求**不执行性能测试**。目前也没有可引用的 `extreme` 性能或质量汇总报告；不得把草案的推算、历史 `quality` 数据或“已经验证过”记作 `extreme` 已过门禁。
- 用户选择：可以完成候选代码与静态验收；正式启用 `extreme`、切换受管服务以及界面/文档宣称其“质量最高”，须待相应证据补齐。本计划不安排该补测；候选页面也不以权重精度替代质量结论。
- MCP 永不触发档位切换，不注册切档工具，不调用 profile mutation；只读取活动档位的有效能力，缺失时如实报告。错误提示也不得引导 MCP 自动换档。
- `recommend_profile` 最高仍为 `quality`；`extreme` 只能由 App/CLI 的操作者显式选择。候选实现可以存在于隔离分支；未过发布门禁不得把 `presets.extreme` 目录引用并入正式 release。
- 新增 profile 值属于公共枚举扩展；公共端点、请求与响应结构不变。XPC App 解码边界需要前向兼容。
- 私有 `.env` 的 resident 声明由操作者维护，不把机器常驻数字写进 catalog，不在仓库保存私有配置或原始媒体。

## 文件职责与任务边界

| 责任 | 主要文件 |
|---|---|
| 制品、精度及目录规范化 | `src/speechrail/assets/model-catalog.json`、`tools/model-catalog.metadata.json`、`src/speechrail/config/model_catalog.py`、`tools/build_model_catalog.py` |
| selection、命令与受管供给 | `src/speechrail/service/profile_store.py`、`src/speechrail/service/profile_commands.py`、`src/speechrail/cli.py`、`tools/probe_teleprompter_latency.py`；复核 `model_store.py`、`model_commands.py`、installer 和 `profile_smoke.py` |
| REST 能力与错误 | `src/speechrail/http/routes/voice_designs.py`、`audio.py`、`system.py`，以及 `src/speechrail/backends/qwen3_voice_binding.py` 的错误文案 |
| MCP 当前能力边界 | `src/speechrail/mcp/tools.py`、`server.py`、`client.py`（`client.py` 仅核查，不预设改动） |
| App 契约与展示 | `SpeechRailControlKit/ControlTypes.swift`、`ServiceDiagnosticsTypes.swift`；`SpeechRailApp/ModelManagementView.swift`、`ProfilePickerView.swift`、`WorkspaceComponents.swift`、`CreatorSurfaceViews.swift`、`ServiceOverviewView.swift`、`MeetingView.swift`、必要时 `SpeechRailDesignTokens.swift` |
| 公共契约与文档 | `contracts/openapi.yaml`、`configs/speechrail.example.env`、`configs/speechrail.example.yaml`；用户 API/MCP/有效能力指南；产品概述；架构、边界、VoiceDesign/Base 与 MCP 文档；运行部署、评估和验收指南；`docs/developers/macos-app-design-system.md`、`docs/design/2026-09-15-macos-uiux-redesign/figma-kit/main.js`、`docs/decisions/0021-extreme-bf16-profile.md` 与各目录索引 |
| 定向回归 | `tests/test_model_presets.py`、`test_model_catalog_builder.py`、`test_model_identity.py`、`test_model_commands.py`、`test_profile_commands.py`、`test_profile_store.py`、`test_cli.py`、`test_installer.py`、`test_app_contract.py`、`test_voice_design_registration.py`、`tests/mcp/`、`SpeechRailMacControlTests/` |

## Review Focus

1. `bf16` 的 `bits=null, dtype=bf16` 被目录与构建器一致接受；`bits=8, dtype=bf16` 和 dtype 不匹配被拒绝（任务 2）。
2. `extreme` selection 可落盘、恢复和回滚；未准备完整制品时不切换（任务 3）。
3. `extreme` 的 VoiceDesign/Base 注册与预览可用；`balanced/light` 仍被拒绝（任务 4）。
4. 新服务返回未知 profile 时 App 仍解码健康与列表，未知值不能作为切档请求发出（任务 6）。
5. MCP 面对当前档位能力缺失时返回可核实的失败，不触发或建议自动切档（任务 5）。

---

## Task 0：冻结基线及证据状态

**产物：** 可审查的候选开发起点与门禁记录，不改受管运行态。

- [x] 重新执行 `git status --short --branch` 并核实候选 worktree 与共享 `main` 隔离；保留共享工作区的 25 个重叠改动，不覆盖或还原。候选 diff 统计与文件清单在收尾时复核。
- [x] 记录基线 commit 与 spec revision。运行时 selection 未读取，明确记为 `UNVERIFIED`，不从 issue/历史推断；三个制品的锁定来源、权重 revision、文件数、大小已记录。
- [x] 建立门禁状态表：候选代码/静态按 G0–G8 逐门记录；性能/质量 `UNVERIFIED` 或 `BLOCKED`；managed activation `BLOCKED`。没有报告的项目未记为 PASS。
- [x] 并行工作区的同文件改动归属不明，因此只在已隔离的候选 worktree 写入；共享 `main` 保持原样。

**Gate G0：** 基线与文件归属明确，候选实现和现有未提交工作可清楚区分。

## Task 1：明确制品清单

**产物：** 三个 bf16 制品的不可变来源记录；当前可加载目录暂不改变。

- [x] 在隔离候选分支更新 `tools/model-catalog.metadata.json`，登记 `asr-1.7b-bf16`、`tts-1.7b-design-bf16`、`tts-1.7b-base-bf16`。revision 分别固定为 `ef12a053e8aa5703de3aab0a9f97ddbdab603776`、`8f4e5ac0d3ab7e8aae213b74029d0af9394c8080`、`072137f02bd36b9ed858e93514705a6a4738618a`。
- [x] 按现行文件集规则排除**根级** `.gitattributes` 与 `configuration.json`；保留 `README.md` 和 `speech_tokenizer/configuration.json`。两个 TTS 仓库的 README/权重 revision 不一致，不能把 `fetch_catalog_artifacts.py` 的 `len(revs)==1` 失败当成制品缺失；目录以权重 revision 为准，逐文件清单必须能在该 revision 解析。
- [x] 核对 metadata 中每个制品的 key、逐文件 size/hash 和固定来源；远端 immutable manifest 已独立核对。本轮没有重验仓库外本地下载目录的哈希，记录为 `UNVERIFIED`；不提前改写三档制品身份，不纳入原始下载记录。

**Gate G1：** 三个制品身份与逐文件清单一致；清单不含未锁定 revision、重复或缺失必要 tokenizer/codec 文件。此门仅证明**制品可识别**，不证明性能或质量。

## Task 2：扩展目录精度类型与校验

**Files:** `src/speechrail/config/model_catalog.py`、`tools/build_model_catalog.py`、`src/speechrail/assets/model-catalog.json`、`tests/test_model_presets.py`、`tests/test_model_catalog_builder.py`。

**接口：** `PresetId` 增加 `"extreme"`；`TierPrecision.asr/tts` 接受正整数或 `"bf16"`；每个 policy 字段与制品的 `(bits, dtype)` 精确对应。

- [x] 修改 `ModelPreset.id`、`ModelCatalog.presets` 下限、`expected_ids` 及错误文字为四档。保留 `quality` 与 `balanced` 共用 ASR 的旧约束，另加 `extreme` 的 `voice_design`/`base`/`aligner-bf16` 约束；不要强迫 `extreme` 与 `quality` 共用 ASR。
- [x] 将 `TierPrecision.asr/tts` 和构建器 `_normalise_precision` 同步扩为正整数或 `bf16`。校验规则固定为：整数 policy 要求 `artifact.quantization.bits == policy` 且 `dtype is None`；`bf16` 要求 `bits is None` 且 `dtype == "bf16"`。构建器和运行时解析器都必须校验 preset 的 ASR、TTS、Base clone（按 TTS policy）及 aligner 引用，防止元数据声明和实际制品精度分离。
- [x] 从 G1 的 metadata 生成候选 `model-catalog.json`：加入三份完整 size/SHA-256 制品、`presets.extreme` 的 ASR/设计 TTS/Base clone/`aligner-bf16`/`diarization=true`，以及 ASR/TTS/aligner 全部为 `bf16` 的 precision policy；比较规范化结果与落盘目录，旧三档映射逐项不变。
- [x] 更新构建器 `_PRESET_IDS` 和四档 fixture；增加有效 bf16、错误 dtype、同时填写 bits/dtype、缺 clone、错误 variant、Base clone 与 policy 精度交叉引用、缺/多 preset 的定向用例。原有三档精度断言继续保持。
- [x] 执行定向目录与构建器测试，并确认 catalog 可被 `load_catalog()` 加载且规范化生成结果稳定。

**Gate G2：** 服务解析器和构建器接受同一份四档目录，并对精度不一致 fail closed；旧三档映射逐项未变。

## Task 3：补齐受管 selection、命令与供给

**Files:** `src/speechrail/service/profile_store.py`、`profile_commands.py`、`cli.py`、`src/speechrail/backends/model_identity.py`；定向检查 `model_store.py`、`model_commands.py`、installer、`profile_smoke.py` 与相应测试。

**接口：** `list_profiles()` 返回 `extreme, quality, balanced, light`；`recommend_profile()` 不返回 `extreme`；`apply_profile("extreme")` 继续使用既有准备→VAD→分人→selection 切换事务。

- [x] 扩展 `SelectionRecord.preset`、profile 命令 `PresetId/_ORDER` 和 CLI 的 `setup`、`install`、`profile apply`、`model prepare` choices；更新帮助文字与 `tools/probe_teleprompter_latency.py` 的显式档位 choices（本次不运行探针）。`recommend_profile(16 GiB+) == "quality"`，高内存机器亦同。
- [x] 逐条检查 `model_store` 对 `tts_clone`、prepared identity、可复用已校验制品的处理，`profile_smoke` 对量化 identity 的比较，以及 installer 分人制品先供给后 preflight 的事务；只在发现真实缺口时修改这些模块。
- [x] 目录的 `dtype` 字段必须贯通 snapshot identity 与 `/v1/models` prepared identity。静态检查未量化模型时，从 safetensors 主权重头部确认 BF16；缓存复用仍以锁定 revision、文件集、大小和 SHA-256 为准。旧量化制品的 prepared registry 若缺失新增的 `dtype: null`，可在匹配时规范化该缺项；`extreme` 的 BF16 制品不能用缺失 dtype 的 registry 代替 BF16 声明。
- [x] 加定向用例：四档顺序/下载总字节、`quality → extreme` 的三件语音制品变化与共用 `aligner-bf16`、已校验文件不重下、缺一个 bf16 文件不切换、`extreme` selection 恢复/回滚、CLI 接受 `extreme` 且自动推荐不选它。
- [x] 定向测试使用 fake backend 和仓库外临时目录，不下载模型、不启动真实服务。

**Gate G3：** 候选档能准备、选择、恢复与回滚；任一校验或供给失败保持旧 selection，`quality` 不被静默改变。

## Task 4：REST 能力如实声明

**Files:** `src/speechrail/http/routes/voice_designs.py`、`audio.py`、`system.py`、`src/speechrail/backends/qwen3_voice_binding.py`；`tests/test_voice_design_registration.py` 及相关音色/能力测试。

- [x] 将 `/v1/voices/designs` 的 `active.profile != "quality"` 判断改为实际 `voice_design` 与 `base` 能力齐备的判断，保留鉴权、reference gate、原子发布和幂等语义。
- [x] `/v1/audio/speech`、预览、克隆注册与校验继续按当前模型 variant 和有效能力门控；只修正把 VoiceDesign/Base 误写成“quality 专属”的错误信息，不改成功响应结构或错误码。
- [x] 加 `extreme` 成功、`quality` 原行为、`balanced/light` 拒绝及 `clone` 缺失时拒绝的 fake 测试；断言 `/health.profile`、`/v1/models`、`/v1/voices` 和 effective capability snapshot 均指向同一活动档及制品。

**Gate G4：** 活动档能力与公共声明一致；`extreme` 的 VoiceDesign/Base 路径不因字符串 `"quality"` 被错拒，缺能力时仍稳定拒绝。

## Task 5：MCP 严守“当前档位”边界

**Files:** `src/speechrail/mcp/tools.py`、`server.py`、`tests/mcp/test_tools.py`、`test_server.py`；只读审查 `mcp/client.py`。

- [x] `_derive_tier()` 有活动 profile 时原样返回（包括 `extreme`）；缺失 profile 时返回 `unknown`，不再因 `voice_design` variant 猜成 `quality`。模型、健康、effective snapshot 的 profile 若互相矛盾，不选取某一个伪装成确定结果。
- [x] `describe()` 继续从 `/health`、`/v1/models` 与 effective snapshot 报当前档、readiness、voice `available`、真实能力；快照不一致时标记不一致并避免正向能力结论。`preview_voice`、`synthesize` 等沿用当前有效快照的 variant/availability 门控。修正工具 docstring、注册说明和 `_TIER_MESSAGES`：错误仅陈述当前不可用及 `describe()` 可查询的可用音色，不出现 MCP 切档建议。
- [x] 定向测试四类事实：`extreme` 报告原值；VoiceDesign/Base 可用时通过；无能力时在 REST mutation 前拒绝；工具集合与 HTTP client 不含 profile apply/setup/prepare 等切档入口。禁止新增同义切档工具或隐藏 side effect。
- [x] 确认 MCP 工具 schema 和 15 个现有工具职责不因 `extreme` 改变，Realtime 仍直连服务而不经 MCP。

**Gate G5（硬门）：** MCP 只能使用活动档已经发布的能力；能力缺失如实返回；整个代理没有切档调用路径。

## Task 6：App 前向解码与四档页面

**Files:** `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift`、`ServiceDiagnosticsTypes.swift`、`SpeechRailApp/WorkspaceComponents.swift`、`ModelManagementView.swift`、`ProfilePickerView.swift`、`CreatorSurfaceViews.swift`、`ServiceOverviewView.swift`、`MeetingView.swift`、必要时 `SpeechRailDesignTokens.swift`；ControlKit 与 App 定向测试。

- [x] 先实现 `SpeechRailProfile` 的未知值解码兜底：未知服务器字符串显示“未识别的档位”，不使完整健康/目录响应失败；`allCases` 只列四个可选择档位，未知值不得编码为 `profileApply`/`modelPrepare` 请求。服务仍只有三档时，App 不显示可执行的 `extreme` 选择动作。
- [x] 扩展中文呈现：`extreme` 为“极致”，候选页只说明更高权重精度与效果待验证；`quality` 的“最好/占用最多”去掉未经四档验证的比较语义；`profileSpecs` 对两档的音色创作都写“支持”，不写“分人最准”。
- [x] 用设计 Token 定义卡片最小宽度和断点，模型页可用宽度足够时四列，不足时 2×2；`ProfilePickerView` 用短名并在选中后展示完整说明，或复用同一卡组件。保持焦点顺序、`accessibilityIdentifier`、VoiceOver 标签与键盘动作。
- [x] 将 `download_bytes` 标为“该档模型总大小”；根据已校验制品状态推算尚需下载上限。目录外的 CoreML 分人包必须通过独立 `diarization-coreml` 状态纳入总量校验和剩余量计算，状态不全则显示“需下载量待确认”，不得把总量冒充本次下载量。确认中说明可用磁盘、已校验文件不重下、首次加载可能更久、其他档模型不会删除。
- [x] 切档前只提示更大权重可能增加内存占用，不以当前档 `declared_footprint_bytes` 预测目标档或给出确定的 24/32 GiB 门槛；切换后依据当前 `/metrics.resources.heavy_overlap_allowed` 和 reason 显示实际并发状态。未知时说“尚未确认”，不禁止档位。
- [x] `CreatorSurfaceViews` 与 `ServiceOverviewView` 依据服务声明的 VoiceDesign/Base 能力判断，而非 `.quality`；会议页移除“本机最强”，只显示活动档短名。更新 App 假数据和定向测试。
- [x] 按现有设计系统更新 `docs/developers/macos-app-design-system.md` 和 Figma kit 的四卡规则；UI 自动化、接管窗口的视觉验证仅在实施当次获得用户明确授权后执行。

**Gate G6：** 四档展示逻辑、未知值解码、能力入口、下载及内存提示的确定性检查通过且不夸大运行事实；未经当次授权的宽窄窗口与无障碍实际走查单列 `UNVERIFIED`，不伪装为静态门已实测。

## Task 7：契约、用户文档与 ADR 收口

**Files:** `contracts/openapi.yaml`、`configs/speechrail.example.env`、`configs/speechrail.example.yaml`；`docs/users/README.md`、`api-contract.md`、`integrations.md`、`mcp-agent-integration.md`；`docs/architecture/README.md`、`architecture.md`、`current-boundaries.md`、`quality-voice-capabilities.md`、`voice-cloning-design-and-handoff.md`、`speechrail-mcp-proxy.md`；新建 `docs/architecture/diagrams/four-tier-model-architecture.svg` 并更新 active 引用，保留原三档 SVG 作为历史；`docs/product/overview.md`；`docs/operations/runtime-deployment.md`、`runtime-evaluation.md`、`capability-quality-acceptance.md`；`docs/decisions/0021-extreme-bf16-profile.md`、`docs/decisions/README.md`、`docs/superpowers/README.md`。

- [x] OpenAPI 的 `/health.profile`、`/v1/models` canonical entry profile 枚举加入 `extreme`；effective snapshot 的开放字符串字段保持原形。契约写清“profile 枚举扩展，端点与 payload 结构不变”。
- [x] 全部 active 用户文档把“三档”“仅 quality 有 VoiceDesign/Base/分人”等现行承诺更新为四档；MCP 文档明言它不能切档，`describe()` 只暴露当前档有效能力。历史或 superseded 报告不改写。
- [x] 架构图、产品矩阵、运行组成表、精度表、两个 example 配置中的档位说明、设计系统和 Figma kit 同步。数值区分 catalog 字节、推算 resident、已实测峰值；无证据的 ASR/TTS 优劣、延迟、内存行标 `未验证`，暂不写“质量最高”“分人最准”之类结论。
- [x] ADR-0021 记录 `extreme` 名称、仅显式选择、bf16 制品、精度类型扩展、MCP 禁止切档、机器级私有 resident 声明、未知档位解码及发布证据门。正文实质变化的正式文档才更新 `version/date`。
- [x] 以仓库文字搜索收尾：active 文档与工具提示中不应再有把 VoiceDesign/Base 写成只有 `quality` 可用的现行断言；参考历史数据的段落明确标注历史。

**Gate G7：** 契约、代码和 active 文档四档一致；所有“最高质量”结论仍受证据门控制。

## Task 8：候选实现静态验收

**产物：** 候选分支评审记录；不安装、不发布、不切档、不做性能测试。

- [x] 依 G2–G6 执行受影响的确定性 Python/Swift 测试，全部使用 fake backend；对 OpenAPI 做 schema/lint 检查，对 Swift 控制面做不占前台的构建检查。具体命令、退出码及关键断言记录在实施账本。
- [x] 定向检查涉及三档固定集合的测试与代码：`test_app_contract.py`、`test_installer.py`、`test_model_identity.py`、`test_model_commands.py`、`test_cli.py`、`SpeechRailMacControlTests/ControlKitTests.swift`；候选测试已覆盖四档与旧三档服务。
- [x] 用 `git diff --check`、文件集、敏感字段及正式文档链接审查候选 diff；无私有 `.env`、原始音频、完整转写、token、绝对模型路径或 benchmark 原始 JSON。
- [x] 完成独立全分支复核并按影响重评发现；修复精度引用校验与 CoreML 剩余下载估算，均有 RED→GREEN 回归证据。
- [x] 记录未做项目：真实 ASR/TTS 质量、延迟、RTF、`phys_footprint`、受管切档、前台 UI 自动化。报告中统一为 `UNVERIFIED`，不得写 PASS。

**Gate G8：** 代码与静态契约可评审；不由此推导运行态、模型质量或发布验收通过。

### G1–G8 的核对清单与执行入口

以下命令是**后续实施候选代码时**的定向检查入口，本次规划不运行。实施时先对照当前测试名称与构建脚本 `--help`；若入口已变化，在记录中写明实际使用的入口和原因。所有测试使用 fake backend，且不读取生产密钥或真实音频。

| 门 | 必须逐项看到的结果 | 定向入口 |
|---|---|---|
| G1 | 三个 key 分别为 10/13/13 个锁定文件；revision 与 issue 一致；必要 codec/tokenizer 文件存在；无根级排除项进入清单 | metadata 审查与本地只读逐文件校验记录 |
| G2 | 四个 preset 与四项 policy；catalog 与 metadata 规范化后一致；`extreme` 的 ASR/TTS/Base/aligner 均为 bf16；构建器和运行时解析器都拒绝 ASR/TTS/Base/aligner 精度与 policy 不一致、混填 bit/dtype、漏 Base 或错 variant | `uv run --extra dev pytest tests/test_model_presets.py tests/test_model_catalog_builder.py -q` |
| G3 | `list_profiles` 四档有序；推荐在 16/32/128 GiB 仍为 `quality`；准备失败不改变 selection；`extreme` selection 可恢复/回滚；BF16 身份和旧 q8 registry 缓存复用正确 | `uv run --extra dev pytest tests/test_profile_commands.py tests/test_profile_store.py tests/test_model_commands.py tests/test_model_identity.py tests/test_model_store.py tests/test_installer.py tests/test_cli.py -q` |
| G4 | `extreme` 与 `quality` 在同样的能力条件下可用；`balanced/light` 与缺 Base 时稳定拒绝；能力快照不把未就绪写成可用 | `uv run --extra dev pytest tests/test_voice_design_registration.py tests/test_app_contract.py -q` |
| G5 | MCP `describe().tier/profile` 如实为 `extreme`；能力缺失返回不可用及原因；工具和 client 无档位 mutation | `uv run --extra dev pytest tests/mcp/test_tools.py tests/mcp/test_server.py tests/mcp/test_client.py -q`，并审查实际注册工具及 client 方法 |
| G6 | 旧服务三档响应、新服务四档响应及未知 profile 均可解码；未知值不能发送；剩余下载估算核对 catalog 模型与独立 CoreML 分人状态后才给数值；四卡布局/文案/能力门在许可的验证范围内正确 | `macos/SpeechRailApp/SpeechRailMacControlTests/` 定向测试；`scripts/macos_app_build.sh --configuration Debug` |
| G7 | OpenAPI 两处枚举、活动用户文档、MCP 说明、架构图与 ADR 同步；历史记录不改写 | `npx @redocly/cli lint contracts/openapi.yaml`；对 active 文档和工具文案做定向文字审查 |
| G8 | 所有相关测试与构建结论有实际输出；diff 无空白错误、私有数据及未解释的三档断言；无运行态动作 | `git diff --check`、`git status --short`、定向 diff 审查 |

**G6 的视觉证据界限：** 构建成功只证明可编译；不能证明四卡不截字或焦点正确。若实施当次未明确授权接管前台的 UI 自动化，则把窗口宽窄、VoiceOver、键盘与外观的实际走查标为 `UNVERIFIED`，不能用构建结果代替。

## 发布门、顺序与失败处置

| 门 | 当前证据要求 | 当前状态/处置 |
|---|---|---|
| R0 前向兼容 | 旧服务上新版 App 可读；未知档位不会击穿整份响应 | G6 源码/定向测试完成后仍须先发布并安装兼容 App；本轮未发布 |
| R1 候选代码 | G0–G8 全通过，制品目录和能力映射正确 | **PASS（候选代码与静态验收）**；未提交、未推送、未安装或发布 |
| R2 质量声明 | `extreme` 对 `quality` 的同口径 ASR 0.5pp 门结论及 TTS 质量依据可审查 | **无报告，BLOCKED**；不得宣称“质量最高” |
| R3 资源/延迟声明 | 有身份、采样完整性与条件明确的已有证据，才填写 resident、冷载、首包、RTF | **无报告，UNVERIFIED**；使用“未验证”，不写性能数字为承诺 |
| R4 正式启用 | R0–R3 结论可审查，且获得服务安装、切档与必要 smoke 的明确授权 | **BLOCKED**；现有 `quality` selection 和运行服务保持原状 |

R2/R3 不安排本次测量。将来若取得既有报告，先只读核对其日期、硬件、版本、制品 revision、语料/样本、指标口径及结论；不能补证的项目仍是 `UNVERIFIED`。若以后另行授权真实验收，须按 `speechrail-perf-benchmark`、`speechrail-local-deploy` 和 `speechrail-release` 执行，单服务单 worker，先隔离外部连接；真实签名、公证、外部发布和 UI 自动化分别按当次授权范围处理。

**失败回退：** G1–G8 任一失败只修候选分支，不触碰受管 selection；R2/R3 无证据时不把 `presets.extreme` 目录引用并入正式 release。后续获准启用时如 service/profile 切换失败，按受管 controller 的事务结果核实并恢复上一 release/selection；保留已下载制品、私有配置和用户数据，不用模糊进程匹配或手工修改 LaunchAgent。

## 完成定义

本计划当前授权下的完成状态是：候选代码、定向静态测试、OpenAPI、App/MCP 契约与 active 文档可评审，门禁表如实标出 `R2–R4` 阻塞，受管服务仍在原档。`extreme` 正式可选、已启用、质量最高、性能已验收均**不在当前可宣称的完成状态内**。

## 自审映射

- 规格 §3/§5 制品与目录 → G1/G2；准备、selection、CLI → G3。
- 规格 §6 App 文案、布局、确认、内存、未知值 → G6；新增发现的其他 App 能力门禁同属 G6。
- REST VoiceDesign/Base 漏项 → G4；MCP 当前档且永不切档 → G5。
- 规格 §7/§10 的质量、资源、闭环 → R2–R4；遵循用户“不执行性能测试”且没有现成报告的决定，全部如实标记，不偷换成静态验收。
- 公共枚举、用户文档、架构、ADR 和 Figma kit → G7。
