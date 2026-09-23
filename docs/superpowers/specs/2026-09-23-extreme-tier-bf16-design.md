---
title: "第四档 extreme（极致）：bf16 精度档与档位界面扩展设计"
status: implemented-candidate
date: 2026-09-23
---

# 第四档 extreme（极致）：bf16 精度档与档位界面扩展设计

## 1. 目标与非目标

在**不改变公共端点及请求/响应结构、worker 协议、调度结构与分人链路**的前提下，增加第四个候选模型档位
`extreme`（用户可见名「极致」）：ASR 与 TTS 权重由 8-bit 换为 bf16；这表示权重数值格式不同，不代表
已证明识别或配音效果更好。`quality` 的制品保持现状。公共 profile 枚举会扩展，因此不是“公共 API 完全不变”。

2026-09-23 当前执行范围：完成候选代码与静态验收；用户明确不要求性能复测，且当前没有
可引用的 `extreme` 质量、资源与延迟汇总报告。正式启用、受管服务切档以及“质量最高”
的产品结论等待证据补齐。本规格的候选目录引用只在隔离实现分支使用，不进入正式 release。

加档方向只能是向上提精度：`light` 的 0.6B 4-bit 方案已在 E1 实测劣化 1.38pp（超 0.5pp
阈值）并回退，向下加档已被否决（ADR-0015、`docs/operations/2026-09-11-tier-repositioning-acceptance.md`）。

非目标：

- 不新增模型族、capability lane 或流式能力；`extreme` 与 `quality` 的差异只在权重精度。
- 不改分人链路：`extreme` 与 `quality` 同样使用 `aligner-bf16`。
- 不改 `light` / `balanced` / `quality` 的制品组成与精度策略，不动 VAD 与内置音色集。
- 不为旧行为、旧配置或旧 App 保留兼容 alias；跨版本差异按 §6.7 的兜底呈现处理。
- MCP 只发现并使用**当前活动档位**已发布的能力；不得提供或触发切档，不得因能力缺失而自动切档。

## 2. 已决前提（2026-09-23 用户决定）

| 事项 | 决定 |
|---|---|
| 内部 preset key | `extreme`（不使用 `ultra`：文档中 "Ultra" 已指 Apple 芯片，同表并存会串） |
| 用户可见名 | 「极致」 |
| 选择方式 | `recommend_profile(total_memory_bytes)` 最高仍只返回 `quality`；`extreme` 仅显式选择 |
| 内存声明 | 沿用现行模式：`SPEECHRAIL_ASR_RESIDENT_BYTES` / `_TTS_` / `_DIARIZATION_` 仍由操作者在私有 `.env` 声明，不引入 catalog 级制品常驻声明 |
| 命名体系 | 现有三档是「取向」名（精准/均衡/轻量），加档引入等级名「极致」；接受这一混合 |
| 当前发布状态 | 候选代码与静态验收可推进；没有可审查的质量/资源证据时不正式启用，不宣称质量最高 |

## 3. 锁定制品来源（2026-09-23）

GitHub issue #80 记录这三个制品已下载到本机目录并通过逐文件 sha256 校验。本次实施只请求 ModelScope
不可变 `repo/files` 清单，并核对 revision、文件数、逐文件 size/hash 与聚合字节；本次没有读取或重哈希
本地已下载目录，也没有重下或加载权重。`aligner-bf16` 与 VAD 按设计复用。

| 制品 key | ModelScope repository | revision（固定用权重 revision） | 文件数 | 体积 |
|---|---|---|---:|---:|
| `asr-1.7b-bf16` | `mlx-community/Qwen3-ASR-1.7B-bf16` | `ef12a053e8aa5703de3aab0a9f97ddbdab603776` | 10 | 4.081 GB |
| `tts-1.7b-design-bf16` | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16` | `8f4e5ac0d3ab7e8aae213b74029d0af9394c8080` | 13 | 4.520 GB |
| `tts-1.7b-base-bf16` | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` | `072137f02bd36b9ed858e93514705a6a4738618a` | 13 | 4.544 GB |

目录写入时必须注意：

1. **两个 TTS 仓库不是单一 revision**：`README.md` 与权重分属不同 commit，而
   `tools/fetch_catalog_artifacts.py` 断言 `len(revs) == 1`，直接对其运行会 `SystemExit`。
   目录条目按上表的**权重 revision** 固定；`README.md` 在该 revision 下仍可解析。
2. **排除项沿用现有约定**：剔除根级 `.gitattributes` 与根级 `configuration.json`，保留
   `README.md` 与 `speech_tokenizer/configuration.json`。落盘文件集已按此约定准备。
3. `quantization` 与 `aligner-bf16` 同形：`{"bits": null, "dtype": "bf16", "format": "none",
   "group_size": null}`；`precision_policy.extreme` 为 `{"aligner": "bf16", "asr": "bf16",
   "tts": "bf16"}`。

## 4. 资源估算与未验证项

安装体积按 catalog 文件字节求和；常驻按权重字节比缩放现有声明值（**推算，非实测**）。
表中常驻和预算占比都不是运行时准入结果，不能作为 App 的精确预切档提示或发布承诺。

| 档位 | 三件套权重 | 安装体积 | 常驻（声明口径：ASR + 双 TTS worker + 分人） | 128 GiB 机器的预算占用 |
|---|---:|---:|---:|---:|
| `quality`（现状） | 8.06 GiB | 10.49 GB | 9.23 GiB | 14% |
| `extreme`（新增） | 12.24 GiB | 14.99 GB | 13.79 GiB | 21.5% |

预算公式是 `max(4 GiB, 物理内存 // 2)`（ADR-0016）。下表仅展示**若推算的
13.79 GiB 恰好等于正确的目标档常驻声明**时的算术结果；当前 `.env` 是机器级单值，
切档不会自动改写，因此实际 `heavy_overlap_allowed` 不能由本表判定。

| 物理内存 | 预算 | 推算占比 | 假设成立时的算术结果 |
|---:|---:|---:|---|
| 16 GiB | 8 GiB | 172% | 高于预算 |
| 24 GiB | 12 GiB | 115% | 高于预算 |
| 32 GiB | 16 GiB | 86% | 低于预算 |
| 64 GiB | 32 GiB | 43% | 低于预算 |
| 128 GiB | 64 GiB | 21.5% | 低于预算 |

磁盘增量约 +4.49 GB（按目录文件字节计算）。目前**不能**由此确定最低内存门槛、
并发能力或推荐机器规格。

正式发布前需要有可审查的证据、不得沿用本表推算值的项；本次按用户决定**不执行补测**：

1. 同 tick `phys_footprint` 包络（采样器与口径同 E4 表，含 idle 与峰值）；
2. 冷加载时长与首包延迟（权重字节 +52%）、ASR RTF；
3. `extreme` 下的私有 `.env` `*_RESIDENT_BYTES` 声明依据；低于真实峰值会偏向放行重叠，
   是 ADR-0016 明确的已知风险方向。无依据时保持 fail-closed，不以 `quality` 声明冒充
   `extreme` 已校准值。

## 5. 目录与代码改动清单

| 位置 | 改动 |
|---|---|
| `src/speechrail/assets/model-catalog.json` | 新增 §3 三个制品；`presets` 增加 `extreme`（`asr` / `tts` / `tts_clone` / `aligner: "aligner-bf16"` / `diarization: true`）；`precision_policy` 增加 `extreme` |
| `tools/model-catalog.metadata.json`、`tools/build_model_catalog.py` | 固定三个制品来源与文件集；构建器的 `_PRESET_IDS`、ASR/TTS 精度校验扩展为四档与 bf16 |
| `src/speechrail/config/model_catalog.py` | `PresetId`、`TierPrecision.asr/tts` 及 bits/dtype 一致性校验；`expected_ids`、VoiceDesign/Base preset 约束改为四档 |
| `src/speechrail/service/profile_store.py` | `SelectionRecord.preset` 接受 `extreme`，支持恢复和回滚 |
| `src/speechrail/service/profile_commands.py` | 第二处 `PresetId`（:36）；`_ORDER`（:42）；`recommend_profile`（:120）**保持最高只到 `quality`** |
| `src/speechrail/cli.py` | 四处 `choices=("quality", "balanced", "light")`（:129 / :144 / :166 / :190） |
| `src/speechrail/http/routes/voice_designs.py`、`audio.py`、`system.py`、`src/speechrail/backends/qwen3_voice_binding.py` | 按实际 VoiceDesign/Base 能力而非 `profile == "quality"` 门控；错误信息不再称该能力只有 quality |
| `src/speechrail/mcp/tools.py`、`server.py` | 如实返回活动档和能力；清除“仅 quality”与 MCP 换档提示；不增加切档入口 |
| `contracts/openapi.yaml` | profile 枚举增加 `extreme`；同步 App 侧契约类型与文档 |
| `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`、`ServiceOverviewView.swift` | 按服务发布的能力开放音色创作与克隆，不把 `.quality` 当作唯一可用档 |
| `tests/`、`SpeechRailMacControlTests/` | 覆盖 catalog builder、selection、CLI、REST、MCP、App 解码与三档假设 |
| `tools/probe_teleprompter_latency.py` | 接受 `extreme` 作为显式 profile 参数；本次不运行探针 |
| `configs/speechrail.example.env`、`configs/speechrail.example.yaml` | 更新档位说明；不写入机器级实测值 |
| `docs/` | 更新 active 用户、MCP、产品、架构、运行与设计系统文档及 Figma kit；新建四档架构 SVG 并更新当前引用，原三档图不再充当当前总览；新增 ADR-0021；历史报告不改写 |

供给与复用：`prepare_models` 对已落盘且 size + sha256 一致的制品不再下载；`profile apply`
的固定顺序（准备模型 → 可选 VAD → 分人制品 → 切换 selection）不变，`extreme` 的分人制品
仍是 `aligner-bf16`。

## 6. UI/UX 规格

### 6.1 文案（`SpeechRailProfilePresentation`，`WorkspaceComponents.swift`）

| 项 | `extreme` | `quality`（改） | `balanced` | `light` |
|---|---|---|---|---|
| `shortTitle` | 极致 | 精准 | 均衡 | 轻量 |
| `title` | 极致 · 更高精度 | 精准 · 更适合创作 | 均衡 · 日常够用 | 轻量 · 最快最省 |
| `purpose` | 使用更高精度的模型，支持音色创作和克隆；实际效果与速度尚未完成对比验收，占用空间更多。 | 支持音色创作和克隆；与新档的实际效果差异尚未完成对比验收。 | 日常识别与配音，支持区分说话人；实际性能按已有证据呈现。 | 使用较小的识别与配音模型；不区分说话人，也不能创作音色。 |
| 「识别与配音」取值 | 效果待验证 | 已有档位 | 已有档位 | 已有档位 |
| 「谁在说话」 | 支持 | 支持 | 支持 | 不支持 |
| 「音色创作」 | 支持（含克隆） | 支持（含克隆） | 不支持 | 不支持 |

候选阶段不得把更高权重精度写成“识别更细、配音更像、质量最好、分人最准”。
正式质量证据补齐后，再单独评审是否使用等级性表述。既有 `quality` 的「最好 / 占用最多」
也不能在四档候选页面原样保留。
`ModelManagementView.profileSpecs` 中现有的两处 `profile == .quality` 硬比较要改为按档位序
或按能力判断，否则 `extreme` 会被写成「不支持音色创作」。

### 6.2 档位卡布局

`ModelManagementView.profileCards` 现在是 `HStack` 并排三张卡（标题 / 用途 / 当前误写为
「要下载」的档位模型总大小 / 三行规格 / 选中描边 / 「当前使用」胶囊）。新档加入后
尺寸文案会更长。
四张卡同排会把每张压窄，规格行与用途句会折行。要求：宽窗一行四张、窄窗自动 2×2，卡内字号、
行高、Token 用法不变，不新增自绘视觉常量。该规则需同步 `docs/developers/macos-app-design-system.md`
的档位卡小节与 Figma kit。

### 6.3 消除重复选择器

`ProfilePickerView` 另有一套 segmented `Picker`，用完整 `title` 作选项；四项长标题必然截断。
要求复用同一套档位卡组件（单一来源），或 Picker 只放 `shortTitle`、选中后在下方展示
`title` 与 `purpose`。避免同一语义在两处呈现不一致。

### 6.4 换档确认

`ProfileSummary.download_bytes` 是档位所需制品的**总安装字节**，包含 aligner 和分人制品，
并非本次下载量；三个新制品约 13.145 GB，整个 `extreme` 目录约 14.99 GB，已校验后
本次下载可为 0。确认文案按档位显示总大小、当前可用磁盘、依据校验状态估出的尚需下载
上限；状态不足时写「需下载量待确认」。说明已校验文件不会重下、首次加载可能更久、
不会删除其他档位模型。不能把未实测的首载延迟写成确定增幅。

### 6.5 机器门槛提示（数据已现成）

诊断响应已有 `physical_memory_bytes`、`memory_budget_bytes`、`declared_footprint_bytes`、
`heavy_overlap_allowed`、`heavy_overlap_reason`，但只描述**当前运行档位**，不能直接预判
目标档。候选阶段切档前只提示较大权重可能增加内存占用，实际并发能力待切换后由
`heavy_overlap_allowed` 与 reason 报告；没有目标档声明依据时不显示确定的机器门槛，
也不禁止应用。

### 6.6 去掉「本机最强」的错误断言

`MeetingView.profileRowText` 现在对任何档位都追加「（本机最强）」。候选阶段直接移除此断言，
只显示当前档位短名；“已准备档位中的最高档”也不能证明实际效果最强。

### 6.7 未知档位兜底（跨版本）

`SpeechRailProfile`（`SpeechRailControlKit/ControlTypes.swift`）是裸 `String` 枚举，诊断里是
`profile: SpeechRailProfile?`。**已安装的旧 App 无法被新代码追溯修复**，新服务返回
`extreme` 可能使整份响应解码失败。要求先发布具有未知值解码兜底的 App，显示
「未识别的档位」且绝不允许把未知值编码成控制命令；再启用服务端新枚举。若缺少此先行
发布，不能宣称“服务先行”对旧 App 兼容。

### 6.8 无障碍与键盘

卡片已有 `accessibilityIdentifier = rawValue`、`accessibilityLabel = title`，新档位自动继承；
焦点顺序按档位由高到低保持一致；无新增动效，不需要 Reduce Motion 例外。

### 6.9 MCP 当前档位边界

MCP 不提供 profile apply、setup、prepare 或其他同义切档入口，也不通过 REST/CLI 隐式触发
切档。`describe()` 以服务的当前有效能力快照为准：有活动 profile 时原样报告 `extreme`
等实际 ID；未读到 profile 或快照互相矛盾时报告未知/不一致，不从 `voice_design` variant
猜测为 `quality`。`preview_voice`、`synthesize` 等只在当前快照声明可用时执行；能力缺失
返回稳定错误和可核实的原因，不建议 Agent 自动切换档位。

## 7. 验收方案

**候选代码与静态门（本次可实施）：**

1. catalog metadata、构建器、schema 和逐文件锁定清单一致；四档 precision policy
   对 `(bits, dtype)` 精确校验，旧三档制品映射不变。
2. selection、CLI、installer、REST、MCP、App 和 OpenAPI 的四档定向 fake 测试通过；
   `recommend_profile` 仍最高返回 `quality`，MCP 无切档入口且能力缺失如实报告。
3. 新 App 能读旧服务、四档服务和未知档位，未知值不能作为切档命令发出；服务的
   VoiceDesign/Base 能力判断与 App/MCP 一致。前台 UI 自动化不属于默认静态门。
4. active 文档、设计系统、Figma kit 和 ADR-0021 与候选行为一致，所有未测性能与质量
   结论明确写「未验证」。

**正式启用与质量声明门（当前 BLOCKED，不安排补测）：**

1. `extreme` 对 `quality` 的公开真人 ASR 集合在同一口径下比较 CER/WER；劣化的
   **绝对百分比点差值**须 ≤ 0.5pp。更高质量的宣传还需要可审查的 TTS 对比证据，
   不能只靠权重精度。
2. `extreme` 的同 tick `phys_footprint`（gateway + 全部受管 worker，含完整 tick、
   idle 和峰值）、冷加载、TTS 首包、ASR RTF、目标机器 resident 声明依据均需有
   版本与模型身份可追溯的证据。当前不存在这样的汇总报告，全部记为 `UNVERIFIED`。
3. 获明确运行态授权后，才执行受管 `profile apply extreme` 的准备 → 供给 → 切换 →
   健康/模型身份 → 公共 API smoke 闭环。仅 `/readyz=200` 不算通过。
4. 门禁未过时，候选分支可保留代码与制品记录，但**正式 release 不引用**
   `presets.extreme`、不切换现有服务 selection、不宣布 `extreme` 可用。

## 8. 落地顺序与当前阻塞

开发顺序见 `docs/superpowers/plans/2026-09-23-extreme-tier-bf16.md`：冻结并行基线 →
候选目录/校验 → selection/CLI → REST → MCP → App → 契约/文档 → 定向静态验收。
当前不发布服务或 App。将来满足发布门后，跨版本风险要求先交付可容忍未知档位的
App 解码更新，再启用四档服务；如采用 combined release，须另外证明旧 App 暴露
新服务期间不会解码失败，不能直接套用“服务先行”而略过该兼容门。

2026-09-23 执行状态：候选实现位于隔离 worktree 分支 `codex/extreme-tier-bf16-candidate`，基线 `f60b30e2`。共享 `main` 上的 25 个并行改动未修改。
G0–G6 已完成；G7 文档实施和 G8 静态验收由计划与进度账本记录。未做性能/质量测试、真实推理、App 安装、
发布或服务切档。

## 9. 风险

1. `.env` 的 `*_RESIDENT_BYTES` 是机器级单值，切档不会自动更新；若切到 `extreme` 仍留
   `quality` 的声明值，可能低估占用并放行重叠。没有目标档证据前不能宣称并发门已过。
2. 磁盘增加 4.49 GB，小容量机器需在确认弹窗讲清。
3. 首次加载可能受较大权重影响；没有延迟证据前不能宣称具体增幅或确定变慢。
4. bf16 与 8-bit 的稳态推理速度关系未知（bf16 无解量化开销、但访存量更大），不得先写结论。
5. 已安装旧 App 无法通过新版本源码获得未知档位解码能力，发布顺序必须处理这一窗口。

## 10. 验收清单

- [ ] `extreme` 三个制品条目进入 catalog，revision 与逐文件 sha256 与下载清单一致
- [ ] `presets` 与 `precision_policy` 增加 `extreme`，catalog schema 校验通过
- [ ] 目录构建器的 bf16 校验、`profile_store`、`PresetId`、`_ORDER`、CLI choices、OpenAPI 枚举同步为四档
- [ ] `recommend_profile` 仍最高返回 `quality`，并有测试固定该行为
- [ ] REST 音色注册、App 创作入口均以 VoiceDesign/Base 能力门控；MCP 无切档路径且能力缺失如实报告
- [ ] App 候选文案不宣称质量最好；`extreme` 不出现「不支持音色创作」
- [ ] 档位卡四张布局在窄窗不截断；重复选择器已消除（实际视觉验证需单独授权）
- [ ] 移除「本机最强」断言；未知档位显示「未识别的档位」，且不能发送为切档命令
- [ ] ADR-0021 与 active 文档同步；`docs/superpowers/README.md` 登记本规格
- [ ] 质量 A/B、资源包络、延迟和 `.env` 声明依据记为 `UNVERIFIED`；正式启用保持 BLOCKED
