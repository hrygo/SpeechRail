# VoiceDesign / Base 与 MCP 可靠性方案记录

日期：2026-09-21
状态：源码方案与本轮 review follow-up 已实施；managed runtime Base clone smoke 已通过；正式质量 benchmark 未执行。

调研结果：[VoiceDesign 与 Base 能力及使用方式调研](../../architecture/voice-design-base-practice-review-2026-09-21.md)。

完整范围与验收基线：[SpeechRail 服务可靠性、完整 MCP 与配套 Skill 方案](../specs/2026-09-21-speechrail-mcp-complete-reliability-design.md)。本文件保留问题演进记录；后续实施范围以完整方案为准。

## 目标与授权范围

记录生成式音色合成失败的已知问题，调研 VoiceDesign、Base 和 MLX 实现的能力边界，再决定服务、MCP 与配套 skill 的改进方案。初始记录阶段只授权文档落盘与调研；后续用户已明确要求按方案实施并执行全面 review 优化。本记录不把测试替代为模型加载、真实质量 benchmark、安装、提交或发布授权。

## 已确认事实

- `src/speechrail/http/routes/voice_designs.py` 注册返回 `synthesis_validation=unevaluated`；参考音频门禁不执行 Base 输出验收。
- `src/speechrail/http/routes/system.py::_voice_entry` 的 `available` 计算没有要求输出质量验收通过；“可路由”和“可用于正式制作”需要区分。
- `system.py::_synthesize_probes` 使用 `SpeechRequest` 默认 `speed=1.0`；`_classify_probe_failure` 却根据 RuntimeError 文本包含 `speed` 判定 `clone_speed_unsupported`。
- `src/speechrail/runtime/worker_process.py::error_frame_message` 使用进程级 stderr tail，忽略错误帧的 message；stderr 非请求级隔离，存在误分类风险。
- `src/speechrail/http/routes/audio.py` 在入口拒绝 clone 非 1.0 语速；另一路把通用 RuntimeError 映射为 502 backend_error，并标记 retryable。
- MCP synthesize 宣告通用 0.25–4.0 语速；create_voice 保存 instruction 音色，不完成生成式 Base clone 注册与输出验收。
- 已有 `src/speechrail/service/skill_installer.py`，当前专用于 video-podcast；不能直接视为通用 MCP skill 安装机制。

## 尚未证明的事项

- 最初未取得失败证据链；后续已在 3.0.2/quality、speed=1.0 下复现，定位 Base 使用 default 系统音色预热而启动失败，见调研报告 §12。修复后的 managed runtime 真实输出已在新 wheel 上通过；正式质量 benchmark 仍未执行。
- 不能据 `backend_error` 证明所有 Base 推理失败，也不能据探针标签证明用户传错语速。
- 进程 stderr 污染是实现风险，尚未证明它就是本次事件的触发因素。
- 模型文件完整、preflight 通过或服务 ready 不等于音色输出质量验收通过。

## 拟议改进顺序与验收条件

### 1. 请求级错误契约

- [x] worker 返回稳定错误 code 与可公开的诊断类别；父进程保留类别、request ID，stderr 仅供内部诊断，不驱动业务分类。
- [x] 质量探针显式使用 speed=1.0；按结构化 code 分类，永久参数错误不得标为可重试。
- [x] 回归覆盖：无关异常含 speed、旧请求 stderr 含 speed、缺失 stderr、真正的语速拒绝、默认语速探针与异常分类。

涉及：worker_process.py、qwen3_tts_worker.py、qwen3_tts.py、system.py、audio.py；相关 worker isolation、clone、quality routes 与 API 契约测试。

### 2. 能力与验收状态

- [x] 明确区分参考已验证、允许试听/验证、输出验收通过、输出失败；避免把所有未验证音色直接禁用而阻断验证自身。
- [x] 输出验收绑定 voice revision 与实际 backend/model/runtime 配置；变更后不能沿用不适用的历史通过结论。
- [x] 验收覆盖合成成功、音频有效性、可懂度与跨文本音色；不得将字节相同直接等同音色稳定。（正式多探针 benchmark 仍待授权。）
- [x] 同步 contracts/openapi.yaml、当前用户文档和相关 fake-backend 回归测试。

涉及：system.py、voice_designs.py、domain/voice_quality.py、domain/tts.py 及 effective capability 投影。

### 3. MCP 闭环

- [x] describe 暴露各音色实际控制能力及验证状态；synthesize 在代理边界校验，同时保留 REST 硬校验。
- [x] 为生成式注册、录音克隆与输出验证提供明确工具或受约束操作；区分 instruction 保存与 Base clone 注册。
- [x] 在 MCP server instructions、参数说明和错误 hint 中给出必要约束；不依赖客户端必定加载 skill。
- [x] 回归覆盖未验收音色、clone 语速、不支持功能、音色/模型 revision 变化与失败恢复。

涉及：mcp/server.py、tools.py、client.py、models.py、tests/mcp/、docs/users/mcp-agent-integration.md。

### 4. 配套用户 skill 与安装

- [x] 提供轻量 speechrail skill：能力发现、创建流程选择、验证后制作、版本固定、有限重试、音频交付。
- [x] 易变能力读取 describe；skill 不固化机器路径、私有配置或模型版本，也不绕过失败门禁。
- [x] 在 Agent 集成安装流程提供 skill 安装；客户端发现/激活能力必须核实，不能仅凭文件复制宣称生效。
- [x] 安装与服务生命周期分离；支持版本标识、原子更新、冲突检测、保留用户修改和可恢复回滚。
- [x] 验收包括没有 skill 时仍安全拒绝错误参数、skill 与工具契约一致、用户修改不被覆盖。

涉及：新增用户 skill、service/skill_installer.py、安装入口、安装测试与用户说明；最终文件布局在调研后确定。

## 调研工作包

- [x] 查阅 Qwen 官方模型卡、仓库、推理 API 与技术报告，区分模型能力、参考实现与营销指标。
- [x] 核实 VoiceDesign → reference → Base 的官方推荐流程与单独使用场景。
- [x] 核实 prompt/ref_text、参考音频、语言、语速、随机性、流式、长文本及 prompt 缓存约束。
- [x] 对照 MLX Audio 实现与 SpeechRail adapter；区分已安装版本、上游主干和项目正式支持版本。
- [x] 形成逐项合规矩阵、优先级、未验证项和后续最小验证方案，调研报告与本方案互链。

## 调研后的方案增补

- [x] P0：按 model_variant 修复预热；Base 无参考时不得以 default 系统音色生成。保留严格 clone binding，补默认启动与首次合法 clone 请求回归，并完成安装态真实输出 smoke。
- [x] 将 speed 能力校验扩大到所有当前 Qwen3-TTS variant；不能只修 clone，也不能接受并静默忽略参数。
- [x] 在 adapter 增加标准语言码到 vendor 语言名的适配，并验证 unknown language 行为；当前 zh 原样透传与官方 chinese 键不匹配。
- [x] 把相同 PCM hash 的确定性指标从声学身份/自然度门中解耦；保留独立工程诊断。
- [ ] 采样对照优先比较 temperature；保留 MLX ICL 自带的 repetition_penalty 下限，避免照搬 PyTorch 参数。
- [ ] 核查 token budget 耗尽、跨段接缝和文件制作的 stream/offline 差异。
- [ ] 保持 prepared-reference 公共接口边界；已有波形缓存及 vendor 私有 ICL 缓存，不以“完全无缓存”为改造理由。私有缓存容量、键冲突和失效另作验证。

## Review follow-up（2026-09-21）

- [x] REST、MCP 和 durable job processor 共用严格的 kind-specific `params` validator，包含 speech `validation_policy`；未知键和非有限数值 fail-closed。
- [x] capabilities、同步 `/v1/audio/speech` 和 durable speech job 共用当前 voice/model/runtime validation binding；cold/unknown runtime 不复用旧 output pass。
- [x] quality probe 显式固定 Base `speed=1.0`；质量回执返回 runtime fingerprint、reference preprocessing、generation recipe 和 policy 绑定。
- [x] Realtime 与 VoiceDesign registration 保留结构化 `TtsBackendError` code，不把已知 initialization/inference/parameter failure 静默降级成泛化 `backend_error`。
- [x] job 的本地 `file://` 输入语义、OpenAPI、MCP server 描述和 skill reference 已对齐；部分卸载保留 receipt 并持续报告 `drifted`。
- [x] 针对性回归、全量 pytest、ruff、mypy 与 `git diff --check` 通过；未执行真实运行态/benchmark。

## 交付与回退

源码、契约、测试、packaged skill、安装器与文档已按完整方案实施；不修改既有 App 并行改动。managed runtime 已按 release 流程完成一次候选 wheel 切换并保留上一 release。真实短句 smoke 已通过，但本记录不把它扩大为正式音质/性能验收；后续质量 benchmark 若获授权，应沿用同一 voice revision、模型/runtime 绑定和独立验证存储。用户客户端配置写入仍需单独授权，不能由服务安装隐式完成。
