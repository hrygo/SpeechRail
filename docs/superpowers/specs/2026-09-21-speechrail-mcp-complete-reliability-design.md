# SpeechRail 服务可靠性、完整 MCP 与配套 Skill 方案

日期：2026-09-21
状态：源码已实施；managed runtime 受控 Base clone smoke 已通过。
范围：后端可靠性、公共能力契约、MCP 全部公共能力、用户 skill、安装升级、测试与运行验收。

## 1. 目标与完成定义

用户需要 Agent 能正确使用 SpeechRail 的全部 MCP 能力，尤其能够完成 VoiceDesign 创造声音、Base 稳定复用、验证后制作的完整流程，并从失败中得到正确诊断。

完成必须同时满足：

1. Base 能启动并处理合法 clone 请求，不再使用 default 系统音色预热。
2. REST、异步 job 和 MCP 使用同一能力校验，参数不能被静默忽略。
3. 可调用、参考合格、输出通过和身份未评估是不同事实，接口和 Agent 均不混淆。
4. MCP 现有全部工具/资源有完整契约，补齐声音创建/验证和异步产物交付缺口。
5. 配套 skill 覆盖全部已发布 MCP 能力及其工作流；未加载 skill 也不能绕过校验。
6. 安装能配套交付 MCP 与 skill，并报告文件安装、客户端发现、会话激活的不同状态。
7. fake-backend 回归、契约一致性、安装隔离测试与经授权的安装态真实验证分别提供证据。

本文件最初只生成方案；当前执行已完成源码、契约、fake-backend 回归、打包 skill、安装隔离实现，以及一次受控 managed runtime 替换/重启和真实 Base clone smoke。旧 release 已保留，质量 profile 未切换，模型未下载。用户客户端配置写入和正式多探针质量基准未执行；既有 App 并行改动不得覆盖。

### 1.1 实施与受控验收记录

- 源码证据：全量 `pytest` 为 `2108 passed, 1 skipped, 1 warning`，覆盖率 `81.15%`；`ruff`、`mypy`、wheel verifier、skill validator 与 `git diff --check` 通过。
- 发布证据：由当前源码构建 `speechrail-3.0.2` wheel，SHA-256 前 12 位为 `c9d3eaebd488`；managed installer 报告 `downloaded_bytes=0`，quality selection 保持不变，旧 release 未删除。
- 运行证据：新 `runtime/current` 经 controller 启动后 `/health` 与 `/readyz` 均为 200；同一已注册 clone `qingfeng_integrity_female_20260920` 的真实 Base 请求使用 `speed=1.0`、无 `instruction/seed`，返回 HTTP 200、`audio/x-pcm`、153600 bytes，request ID 为 `req_747238fb10294d998605c330702240e6`。
- 门禁证据：同一 clone 的非默认 speed 返回 `clone_speed_unsupported`；未完成输出验证时 `require_output_pass` 返回 `voice_not_production_ready`。因此“可试听/可验证”与“正式制作 ready”仍保持分离。
- 未宣称事项：未运行完整正式质量 benchmark，未写入 Codex 用户配置，未下载或更换模型；skill 安装器的客户端发现/会话激活仍按证据状态报告 `unknown`，不伪报成功。

## 2. 事实基线与根因

本机 3.0.2/quality 已于 2026-09-21 00:19:51 +08:00 复现：合法 clone、speed=1.0 返回 HTTP 502 backend_error。request ID 为 `req_331e0454ab754a3bad117ff56c03436e`。

直接原因是 `MlxQwenTtsEngine.__init__` 用 default 系统音色预热 Base，触发 `voice default is not a clone voice for base variant`，worker 在 ready 前返回 worker_load_error。异常堆栈里的 `speed=1.0` 又被探针的字符串分类误判为 clone_speed_unsupported。这不是已证明的参考质量或 vendor 推理失败。

还确认了以下设计缺口：

- 当前 available 不能表达制作验收；注册仅完成参考侧检查。
- MCP speed 描述过宽，MLX 当前非 clone 分支也没有兑现数值语速。
- API 的 zh 与 vendor 的 chinese 需要显式映射。
- 重复 PCM hash 被用于输出拒绝，混淆工程重现性与声学质量。
- MCP create_voice 仅保存 instruction 配方；没有完整生成注册/克隆/验收工具。
- MCP create_job 的 params 注释存在“存储并回显”和“尚未存储”的矛盾；实际服务存储并由 processor 消费部分字段，必须清理过时描述。
- Speech job 使用文本文件 input_ref，不能把同步 synthesize 的 text 直接当成音频路径重试。

证据详见[调研与本机复现报告](../../architecture/voice-design-base-practice-review-2026-09-21.md)及[问题方案记录](../plans/2026-09-21-voice-design-base-mcp-reliability.md)。

## 3. 方案选择与责任边界

| 方案 | 收益 | 不足 | 决策 |
|---|---|---|---|
| 只补 skill/SOP | 低成本改善提示 | 无法修预热、参数忽略、错误分类和缺失工具 | 不采用 |
| 服务硬约束 + MCP 完整工作流 + 轻量 skill | 同时解决正确性和 Agent 使用效率 | 需同步契约、分发和验收 | 采用 |
| MCP 内建有状态制作 Agent | 可隐藏编排 | 违背无状态代理边界，重复调用方会话与任务职责 | 不采用 |

服务拥有模型路由、资源准入、参数校验、音色 revision、验证报告与错误分类；MCP 是无状态 REST 代理，负责工具参数、受约束的本地文件交付和模型可读输出；skill 负责使用方法。调用方仍拥有 LLM、对话、播放、字幕/视频制作与业务状态。

不在本方案新增模型后端、不默认升级 MLX、不承诺身份/韵律解耦、不扩展 Realtime 到 LLM/tool orchestration。不把 REST 的每个运维端点机械变成 MCP 工具。

## 4. 后端可靠性与错误契约

### 4.1 预热

- VoiceDesign/CustomVoice 使用各自合法的默认条件预热。
- Base 初始化只完成模型/codec/身份检查；无合法参考时跳过声学生成预热。
- Base 首次合法 clone 请求执行推理初始化；将初始化可用与已经推理预热分别记录。
- 不选择用户某个音色偷偷预热，不添加虚假系统 clone，不放松 resolve_binding 校验。
- ready 只表达它承诺的初始化事实；不得由 ready 推导某音色或所有输出已验收。

### 4.2 请求级异常

新增内部类型 `TtsBackendError`，包含 `code`、`stage`、`retryable`、可公开的 `diagnostic_class` 与内部 request ID。stage 限于 initialize/validate/infer/decode/deliver；原始 traceback 仅留受控日志。

worker error frame 传稳定 code，不由父进程解析 stderr 字符串。启动错误也分配启动 attempt ID；日志把公共 request ID 与 worker attempt/request ID 关联。stderr ring 可保留排障用途，但不得参与业务分类。

| 条件 | 公共错误类别 | 自动重试 |
|---|---|---|
| 不支持 speed/language/instruction | 稳定参数错误、明确 param | 否；修正参数后形成新调用 |
| worker 初始化失败 | tts_initialization_failed | 默认否；诊断环境/实现后再试 |
| worker 推理异常 | tts_inference_failed | 默认否；明确瞬态子类才可重试 |
| 排队满或资源忙 | 保留 backend_busy/queue_full | 按 retry_after 有界退避 |
| revision 冲突 | 保留现有冲突码 | 刷新后由调用方决定，不自动换音色 |
| 音频非法/预算耗尽 | output_invalid/output_truncated | 否；不能交付部分文件冒充成功 |

这些错误名称已在 OpenAPI、MCP 与测试中落地，不让已知类别被通用 `backend_error` 掩盖；未知异常仍使用稳定兜底类别，不能泄露异常原文。

### 4.3 参数统一校验

把 TTS 能力校验放在共享 application/domain 边界，由 REST、job processor、preview、quality probe 共同调用；MCP 的提前校验只改善反馈，不能成为唯一检查。

- 当前 Qwen3 MLX 未实现数值变速的路径只接受 speed=1.0；如未来加后处理，另行声明控制方式与时间戳语义。
- 标准语言码在 adapter 映射为 vendor 名称；auto 保留自动模式，不支持语言明确拒绝。
- clone 禁止未支持的 instruction/seed；设计注册 seed 与 clone 合成控制分别说明。
- job params 从任意 dict 收敛为按 kind 区分的严格模型；未知字段报错，不能存储后忽略。
- 分段预算耗尽返回明确失败；不能将无 EOS 的截断输出包装为完成。

## 5. 能力与验证状态模型

### 5.1 单一事实源

REST effective capabilities 为权威，MCP describe 和三个资源只投影同一快照。新增字段随 schema 升级同步更新全部消费者；旧 schema 不静默兼容或伪造。

当前每音色增加：

```json
{
  "id": "example_voice",
  "mode": "clone",
  "available": true,
  "availability_reason": null,
  "controls": {
    "speed": {"mode": "fixed", "value": 1.0},
    "instructions": false,
    "seed": false,
    "languages": ["auto", "zh", "en"]
  },
  "validation": {
    "reference": "pass",
    "output": "unevaluated",
    "identity": "unevaluated",
    "stale": false,
    "run_id": null
  }
}
```

languages 仅为结构示例，真实列表来自 active backend。available 明确定义为当前可路由且允许调用，不代表输出或身份通过。新增 `validated_for` 列出已经有证据的用途，不使用一个过度概括的 production_ready 布尔值。

### 5.2 状态与验收规则

- 新生成 clone：reference=pass/warn，output=unevaluated，identity=unevaluated。
- 成功的输出检查：output=pass，但不能自动把 identity 改为 pass。
- 输出失败：output=reject；不自动覆盖参考报告，不删除音色。
- 模型/runtime/参考/预处理/生成配方变化：对应旧报告 stale=true。
- 撤销 revision 或缺失 Base：available=false，给出明确原因。
- 所有验证状态必须能追溯到 voice revision、实际模型制品 revision、runtime 指纹、前处理版本、生成配方和 policy version。

验证报告使用独立、有界的记录存储，原子写入，不在声学 voice revision 内写回验证结果以免形成“验证使被验证 revision 变化”的循环。旧记录保留但无法确定身份绑定的报告标为 unevaluated/stale，禁止自动升级为通过。

普通 synthesize 仍可用于试听和诊断，返回当前验证摘要；未验证不等于无法调用。增加 `validation_policy=allow_unverified|require_output_pass`，普通调用默认 allow_unverified，批量正式制作由 skill 明确选择 require_output_pass。后者在服务端检查当前绑定，避免只靠 agent 检查后的时间窗口。

跨文本身份评价与人工试听单独展示；没有身份评估能力时明确 unevaluated，不阻止用户显式试听，也不宣称同音色稳定性已证明。

### 5.3 质量门调整

硬门检查音频完整性、严重信号异常和内容可懂度；PCM hash 作为独立 reproducibility 指标，不直接触发音色质量拒绝。保留同 seed、同环境重复诊断能力。

短文本、数字、疑问、停顿和跨段文本分别验证；ASR 缺失或失败为 unevaluated。当前中文门不自动扩为多语种。采样、stream/offline、参考长度与量化质量须经实际对照后定值，不把上游默认当作本机最优。

## 6. MCP 完整工具与资源方案

### 6.1 现有九个工具必须全部覆盖

| 工具 | 修订后职责 | Skill 指导重点 |
|---|---|---|
| describe | 返回最新能力、状态、参数、schema/runtime 身份 | 首次使用及状态/版本冲突后刷新 |
| transcribe | 本地音频转写；按能力支持分人和时间戳 | 文件、语种、输出格式、匿名 speaker 含义 |
| synthesize | 合成并交付完整文件，携带 revision 与验证摘要 | 音色选择、能力限制、验证策略、文件交付 |
| preview_voice | 无持久化的 VoiceDesign 试听 | 候选设计与正式音色区别 |
| create_voice | 保存 instruction 设计配方 | 不能称为生成式 Base 注册或稳定身份 |
| delete_voice | 精确删除指定用户音色 | 遵守用户授权、系统音色保护和在用冲突 |
| create_job | 持久化 transcription/speech 任务 | 输入种类、受允许路径、参数、幂等 |
| get_job | 查询任务状态、错误和可用结果引用 | 有界轮询，终态后取结果 |
| cancel_job | 请求取消并报告实际状态 | 取消请求不等于已终止，处理完成竞态 |

保留三个只读资源：speechrail://capabilities、speechrail://voices、speechrail://models。skill 说明它们与 describe 的关系；动态响应不按静态工具清单 TTL 缓存。

### 6.2 本轮必要新增工具

| 已发布工具名 | 对应服务能力 | 返回与约束 |
|---|---|---|
| get_voice | GET /v1/voices/{id} | 精确音色详情及验证摘要，隐藏内部参考路径 |
| design_voice | POST /v1/voices/designs | VoiceDesign 生成并注册 Base clone，明确 output 待验收 |
| clone_voice | POST /v1/voices/clone | 本地 reference 与 transcript，经已有门禁注册 |
| validate_voice | 当前 quality-runs 实现，正式契约统一入口 | 当前 revision 的报告；有计算成本，不自动触发 |
| get_job_result | GET /v1/jobs/{id}/result | 转写结构/结果文件或 AudioArtifact；不只返回不可用的 spool 路径 |
| list_jobs | GET /v1/jobs | 分页查找任务，供恢复与精确定位，不打印输入正文 |

新增工具通过 client 调用 REST，不导入 FastAPI 或加载模型。clone 使用受约束本地文件读取和 multipart，不把音频 base64 放进模型上下文。输入超限或远程 URL 明确拒绝。

音色 revision 的更新、历史、回滚和撤销，以及发音词典目前是 REST 能力，并非本轮全部 MCP 能力覆盖的必需新增工具。本轮在 skill 边界表明确“不由当前 MCP 提供”，不得用 shell/私有 API 绕过；后续若将其公开为 MCP，必须同步扩展 manifest、skill 与验收。这样覆盖的是完整的已发布 MCP 契约，而不是无边界扩张 REST 面。

### 6.3 输出、错误与超时

- 工具输入/输出用明确 Pydantic 模型；未知字段不作为成功的参数承诺。
- 所有失败以 MCP tool error 表达，带稳定 code、request ID、retryable、可行动 hint；不把业务失败变成成功结果里的字符串。
- 采用 SDK 支持的结构化错误载荷，另提供简短文字摘要；不能假定所有 host 都读取结构化字段。
- 合成只在完整接收、容器校验后原子发布文件；失败清理临时半成品，只清理本次创建的精确路径。
- AudioArtifact 包括文件位置所属主机、格式、字节数、可获得的采样率/时长、voice/model revision、request ID。
- 代理与服务不同主机时，不假定本地路径互通；当前单机范围内先明确支持边界，返回路径不可达错误。

### 6.4 异步可靠性

transcription input_ref 是音频文件；speech input_ref 是 UTF-8 文本文件。允许目录、尺寸、格式、kind 支持从能力快照读取。同步超时意味着完成状态未知，不得在未判断是否已完成时自动复制任务。

增加持久化 job 幂等键：相同 owner/key/payload 返回同一 job；同 key 不同 payload 返回冲突。给创建、查询与结果恢复提供同一关联标识。没有幂等保护的调用不自动重试创建。

轮询优先遵循服务 retry_after；没有提示时 skill 建议 1/2/4/8 秒退避、上限 10 秒，达到调用方期限后保留 job ID，不循环到上下文耗尽。参数错误和确定的 worker 初始化失败不得退避重试。

## 7. 配套 Skill：覆盖全能力但按需加载

### 7.1 结构与分发事实源

运行分发 canonical source 放在 Python 包资源，随 wheel 打包：

```text
src/speechrail/assets/skills/speechrail/
  SKILL.md
  skill-manifest.json
  references/
    discovery.md
    transcription.md
    synthesis.md
    voices.md
    jobs.md
    errors.md
    artifacts.md
```

不另维护内容相同的仓库 skill 副本；测试从 wheel 资源提取验证。开发时可显式安装该资源到临时/用户 skill 目录。现有 video-podcast skill 保持独立，作为上层制作流程使用 SpeechRail；不能让它成为使用 MCP 的必要依赖。

### 7.2 入口正文要求

SKILL.md 控制在约 150 行内，包含：

- 触发范围：使用 SpeechRail 进行转写、分人、TTS、音色或异步任务；不触发一般音频知识问答。
- 先 describe；只按实际已提供工具和能力操作。
- 任务路由表和需加载的 reference。
- 原则：参考通过不等于输出通过，instruction 配方不等于 clone，ASR 通过不等于身份通过。
- 动态约束由 describe/工具 schema 获取；不固化机器路径、模型 ID、语速范围或语言列表。
- 文件交付与错误恢复基本规则。
- 权限来自用户任务；安装 skill 不赋予删除、发布、下载、重启或上传权限。

### 7.3 各 reference 的完整职责

| 文件 | 必须覆盖 |
|---|---|
| discovery | 九个现有工具、六个新增工具、三个资源；刷新规则、不可用状态、Realtime 边界 |
| transcription | audio_ref、语言、分人、timestamps、受支持格式、匿名 label、输出核验 |
| synthesis | voice 选择、参数能力、revision pin、验证策略、失败文件处理 |
| voices | preview/create/design/clone/get/validate/delete；三条创建路线、验收状态和破坏性操作 |
| jobs | 输入种类、严格 params、幂等、分页、轮询、取消、结果取回、超时恢复 |
| errors | 错误类别→允许动作；禁止以修改身份或无限重试掩盖失败 |
| artifacts | 路径属于哪台主机、完整文件、转写结果、保留与清理边界 |

skill-manifest.json 声明 skill 版本、MCP contract 范围、覆盖的工具/资源及 reference 路由。工具 manifest 来自注册定义，CI 对比集合，新增公开工具未补 skill 时失败；不能只靠人工记忆维护完整性。

示例仅使用合成的短文本、示例文件名和假的音色 ID，不含真实用户音频或私有配置。示例调用以当前 schema 解析验证，避免文档与工具参数漂移。

## 8. 安装、升级、发现与回滚

### 8.1 用户入口

已新增独立 Agent 集成 CLI 子命令组 `speechrail agents install|status|update|uninstall`。支持明确 client 与 skills-dir；安装向导可安装 MCP 配置和配套 skill，并区分文件安装、客户端发现与会话激活。headless 服务安装不默认改用户 Agent 配置。

用户明确选择安装集成后一次完成，不重复确认每个文件；发现用户修改、名称冲突或未知客户端格式时给出具体差异和处置选择，不覆盖。

### 8.2 事务与生命周期

- canonical 包资源→校验→暂存→原子替换 skill；客户端配置使用对应格式解析、精确修改 SpeechRail 条目，保留其它服务。
- 记录安装 receipt：包/skill 版本、内容 hash、客户端、目标路径与本工具拥有的配置键；receipt 不存凭据。
- 初次安装遇同名非本工具资产时停止该目标写入；更新发现 hash 偏离 receipt 时保留用户版本并报告冲突。
- MCP 配置更新失败时恢复本次变更，不能留下“已安装且可用”的成功状态。
- 旧版本保留一个明确回滚点；卸载只移除 owned 且未被用户修改的资产，修改过的内容保留并说明。
- Agent 安装失败不切换服务 runtime、不重启服务；运行态部署沿用 managed installer。
- 长期运行的 MCP 进程可能仍是旧版本；更新完成报告需重连状态，不自动结束未知客户端进程。

### 8.3 发现验收分层

status 分别报告 packaged、installed、client_configured、client_discovered、session_activated。前三项可用本地非 UI 检查；后两项须来自客户端证据，否则标为 unknown，不用文件存在冒充成功。

跨客户端不假定所有 host 都扫描同一路径。首版对经核实支持的客户端提供 adapter，未知客户端提供显式路径安装和手动配置说明。UI 接管验证仍需用户逐次授权；不把安装流程视为 UI 自动化授权。

## 9. 实施分解、文件与交付物

下表各工作包独立验收；P0 可先发布修复，不等待整个集成完成。不得用“全套方案”要求用户一直承受已知故障。

| 包 | 依赖 | 修改/新增重点 | 独立完成条件 |
|---|---|---|---|
| A：Base 与错误 | 无 | backends/qwen3_tts_worker.py、qwen3_tts.py、runtime/worker_process.py；新增 domain/tts_errors.py；HTTP 映射 | 预热回归和错误分类回归通过；安装态合法 clone 真实验证通过后才宣称恢复 |
| B：共享参数校验 | A | 新增 application/tts_validation.py；domain/ports.py；REST、job processor、worker、MCP | speed/language/instruction/seed 在所有入口一致；未知参数明确拒绝 |
| C：验证模型 | A/B | domain/voice_quality.py；新增 domain/voice_validation.py；system.py、voice_designs.py、effective capability 投影 | 状态独立、报告绑定、stale、require_output_pass 与验证自身不死锁 |
| D：MCP 完整闭环 | B/C | mcp/server.py、tools.py、client.py、models.py；jobs route/repository/processor | 全工具严格 schema、创建/验证与结果交付闭环、幂等恢复 |
| E：Skill 内容 | D 契约 | assets/skills/speechrail 全目录；新增覆盖和示例验证测试 | 全部工具/资源有指导，场景正确，无动态能力硬编码 |
| F：安装分发 | E | service/skill_installer.py、新增 service/agent_integration.py、cli.py、包资源配置、zero-setup 入口 | 安装/更新/冲突/回滚/卸载隔离测试通过，不影响服务 |
| G：集成验收与文档 | A–F | contracts/openapi.yaml、MCP 架构/用户文档、安装说明、错误说明 | 消费者同步、真实验证记录、Agent 场景与缺项如实交付 |

具体目录均相对仓库根。保持现有模块边界，仅为新增共享逻辑拆文件，不顺手重构大路由文件。当前 App 并行改动中涉及 capability schema 的消费者已核对并保留，不能盲改。

## 10. 验收矩阵

| 范围 | 必测情形 | 证据 |
|---|---|---|
| Base 预热 | 默认 Base 启动、VoiceDesign/CustomVoice 预热、首次合法 clone、缺参考 | fake engine 路径断言 + 经授权安装态合成 |
| 错误 | traceback 含 speed、旧 stderr 污染、无 stderr、真实参数拒绝、初始化失败 | tests/test_qwen3_worker_isolation.py、test_voice_quality_routes.py 等精确回归 |
| 参数 | 每个入口的非 1.0 speed、zh/en/auto/unknown、非法 seed/instruction、未知 job params | 公共契约与共享校验回归 |
| 状态 | 未验收试听、正式输出要求、报告过期、撤销、模型变更、ASR 不可用 | fake backend 与并发 revision 冲突测试 |
| MCP 全能力 | 九个现有工具、六个新增工具、三个资源成功/失败；schema 与 manifest 相等 | tests/mcp/ 契约测试，stdio/HTTP 无模型 smoke |
| 任务 | 重复提交、同键异参、取消与完成竞态、超时后恢复、取结果、文件不可达 | job repository/processor 与 MCP 联合测试 |
| 分发 | 新装、幂等重装、版本不匹配、用户改动、symlink、部分失败、回滚、卸载 | 临时目录/伪客户端配置测试，不写真实配置 |
| Skill 效果 | 无 skill 的安全性、有 skill 的正确流程、错误能力快照、失败恢复 | 固定场景的 tool-call 轨迹检查；区分模拟与真实 agent 结果 |

Agent 场景至少包括：简单转写、分人并带时间戳、已有音色合成、一次性设计试听、指令配方保存、生成式 clone、录音 clone、未验收音色正式制作、Base 不可用、长任务取消与恢复、删除音色、Realtime 请求越界、结果路径不可达。每个场景断言工具选择、参数、停止条件和最终陈述，不以“回复看起来合理”作为验收。

真实音频验收先复现本次短句故障并核验修复后的完整 WAV；再根据明确授权做目标范围的跨文本/采样对照。不能把一次短句成功写成跨文本身份、性能或长时稳定性通过。

## 11. 发布影响与回退

- 公共能力 schema、错误码、严格 params 与新增 validation_policy 属显式契约演进，同步更新现有受控客户端；不保留误导性旧字段语义。
- 音色资产不自动迁移或重写。新增验证记录采用独立 schema；旧记录不能证明当前配置时降为未评估。
- MCP 与 skill 一起按 contract version 配套发布；服务/MCP 不匹配时报告明确版本问题，不能由 skill 绕过。
- runtime 发布保留上一 release；skill/客户端配置使用独立 receipt 与备份回退。回退不删除新建用户音色、任务或结果。
- 修复前后记录唯一服务 PID/listener、runtime、profile、真实请求 ID 与音频检查摘要；日志/音频留仓库外。
- 无授权不提交、推送、签名或部署。前置问题记录保留历史，完整设计作为后续实施范围基线。

## 12. 评审结论与建议实施顺序

采用服务硬约束、MCP 完整闭环、轻量全能力 skill 的三层方案。先 A/B 恢复正确运行，再 C/D 明确状态与闭环，最后 E/F/G 完成 Agent 分发和整体验收。工具和 skill 的范围以本方案清单为准；新增能力须同步纳入 manifest 和场景测试。

本方案已按上述工作包实施并完成源码与受控 runtime smoke 验收；后续若扩展正式质量 benchmark 或实际客户端配置写入，仍需沿用现有契约并遵循用户授权范围。
