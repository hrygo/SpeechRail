---
title: "SpeechRail 文档中心"
status: active
version: "4.0.0"
date: 2026-10-24
---

# 📚 SpeechRail 文档中心

<p align="center">
  <strong>面向本地应用的高性能、隐私优先、OpenAI 契约兼容的语音识别 (ASR) 与合成 (TTS) 运行时服务</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Status-Beta-yellow.svg" alt="Status" />
  <img src="https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon-black.svg?logo=apple" alt="macOS" />
  <img src="https://img.shields.io/badge/Protocol-OpenAI%20Compatible-412991.svg?logo=openai" alt="OpenAI" />
  <img src="https://img.shields.io/badge/Architecture-Clean%20%26%20Isolated-blue.svg" alt="Architecture" />
</p>

欢迎查阅 SpeechRail 官方技术文档。本文档中心根据不同读者角色与职责进行模块化组织，助您快速获取所需信息。

## 当前实现基线（2026-10-24）

- 当前源码 release 为 SpeechRail `5.0.0`。受管运行时只能由当前源码构建的 wheel 通过 `speechrail install` 切换，不能直接编辑源码 checkout 或 `runtime/current`。
- Realtime 是无状态 Speech Plane，协议支持范围以 [Realtime ASR/TTS 契约](../contracts/realtime-openai.md)（契约版本 `7.1.0`）为准；调用方拥有 LLM、历史、memory、tools、播放和 barge-in，服务端只交付 ASR/VAD/匿名分人事实与显式 TTS render。
- `/health`、`/readyz` 和 `/v1/models` 只报告当前 profile、worker 和可选能力的实时状态；不得把某一台机器的一组 readiness 值写成所有安装的固定承诺。
- Realtime `server_vad` 只交付端点事实。endpointing 窗口、播放队列和 barge-in 决策由调用方负责，不是 SpeechRail 的全局业务默认值。
- 连续 diarization 的 activity stream 与 endpointing 分离：activity 负责 speaker evidence，完成后以 speaker-only revision 更新，不改写 canonical completed text。
- 匿名分人按任务显式启用，可选 `sortformer` 或 `meeting_dynamic` 后端。`meeting_dynamic` 每场最多确认四位稳定匿名身份（`system_cap` 固定为 4），超额声音保留未识别，不轮换已有身份；该后端要求独立质量认证，原有 5–32 身份配置不再满足其生产准入。
- 转写会话可在音频输入前协商 `revision_window_v1` 修订窗口，显式换取近期文字回溯；它与 `session.speechrail.asr` 策略互斥，默认关闭，前置条件缺失时在采集前拒绝协商。
- clone ICL 路径已加入稳定采样、请求级响度冻结、峰值保护和参考音频信号校验；当前 active clone backend 对非 `1.0` speed 明确返回 `clone_speed_unsupported`。
- 每个 TTS spec 都绑定 `custom_voice` 与 `base`；`voice_design` 是不与档位绑定、只用于设计作业的按需制品。不同 capability lane 可并发，同一 lane 由 worker lock 串行，空闲冷却后按 capability group 回收。`reference` 的 bf16 制品继承同族 8-bit 档位已通过的门禁证据，未在本机逐项复测，也不导出质量排名。

---

## 🧭 按角色快速进入

<div align="center">

| 角色领域 | 关注重点 | 推荐入口文档 |
|:---|:---|:---|
| 🎯 **产品经理 / 业务方** | 业务价值、应用场景、功能矩阵、边界与规划 | [📖 产品白皮书与全景概述](product/overview.md) <br/> [📋 产品边界与职责划分](architecture/product-scope.md) |
| 🏛️ **架构师 / 技术决策** | 架构拓扑、进程隔离、Speech Plane、私有 IPC、状态机、ADR | [🏛️ 总体架构设计](architecture/architecture.md) <br/> [🎙️ 无状态 Speech Plane 设计](superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md) <br/> [📜 架构决策记录 (ADR)](decisions/README.md) <br/> [👥 分人整洁架构](superpowers/specs/2026-09-08-diarization-clean-architecture-design.md) |
| 🔌 **API 用户 / 客户端集成** | REST / WebSocket 契约、SDK 接入、MCP/Agent 集成、音色库、错误码 | [🔌 客户端与 SDK 接入指南](users/integrations.md) <br/> [🤖 MCP 主流 Agent 集成指南](users/mcp-agent-integration.md) <br/> [📡 公共 API 契约手册](users/api-contract.md) <br/> [⚡ OpenAI Realtime 协议规范](../contracts/realtime-openai.md) <br/> [🧾 Realtime 事件 Schema](../contracts/realtime-events.schema.json) |
| 📦 **本机用户 / 自部署** | 发布制品说明、安装顺序、首次验证、升级与卸载 | [📦 SpeechRail 安装与首次使用](users/installing-speechrail.md) |
| 🛠️ **核心开发者 / 贡献者** | 5分钟启动、代码分层、测试金字塔、Worker 扩展 | [🛠️ 开发者开发指南](developers/development-guide.md) <br/> [🧪 测试与质量验收规范](developers/testing-acceptance.md) <br/> [🔍 审计与专项审查记录](audits/README.md) |
| 📦 **运维工程师 / SRE** | LaunchAgent 常驻、Wheel 发布、排障决策树、监控 | [📖 运维操作手册 (Runbook)](operations/operations-runbook.md) <br/> [🚀 运行时部署方案](operations/runtime-deployment.md) <br/> [🔒 安全与可观测性](operations/security-observability.md) |

</div>

---

## 🏗️ 全局系统拓扑

```mermaid
flowchart TD
    Client["📱 客户端生态 (QwenPaw / Sona / Hermes / OpenAI SDK)"]

    subgraph Host ["🚀 SpeechRail 主服务进程 (FastAPI / ASGI :8201)"]
        direction TB
        API["OpenAI 兼容协议层 & Request ID & 统一错误 Envelope"]
        Dec["3-Tier 内存解码器 (WAV Fast-path / ffmpeg 流式解码)"]
        Gov["Resource Governor 资源调度器 & 有界队列与 WorkerLeaseLock"]
        Diar["可选 CoreML 分人 worker<br/>• sortformer / meeting_dynamic 后端<br/>• meeting_dynamic 每场 4 位稳定身份<br/>• 原生 diarized_json<br/>• Realtime 单一 opt-in"]
        Life["RuntimeLifecycle + WorkerIdleEvictor<br/>默认 300 秒，可配置"]
        API --> Dec --> Gov
    end

    subgraph Workers ["🛡️ 独立 Python 隔离推理 Worker (私有长度前缀 IPC)"]
        direction LR
    subgraph ASR_Box ["Qwen3-ASR Worker (MLX / MPS)"]
            ASR["• 批量转写 & 时间戳对齐<br/>• 原生 MLX 流式转写<br/>• Server VAD 事实"]
        end
        subgraph TTS_Box ["Qwen3-TTS capability workers"]
            direction TB
            TTS_Custom["CustomVoice worker<br/>• custom_voice lane<br/>• 0.6B q8 fast / 1.7B q8 quality / bf16 reference"]
            TTS_VD["VoiceDesign worker<br/>• voice_design lane<br/>• 1.7B bf16 reference · 仅设计作业"]
            TTS_Base["Base worker<br/>• voice_clone lane<br/>• 0.6B/1.7B q8 / 1.7B bf16"]
        end
    end

    Client -->|"HTTP REST / WebSocket"| Host
    Gov -->|"私有长度前缀 JSON + binary IPC"| ASR_Box
    Gov -->|"私有长度前缀 JSON + binary IPC"| TTS_Box
    Gov --> Diar
    Gov -. 活动与生命周期 .-> Life
    Life -. 尝试释放常驻权重 .-> ASR_Box
    Life -. TTS capability group 冷却后释放常驻权重 .-> TTS_Box
    Life -. 丢弃常驻引用 / 生命周期 .-> Diar
```

![三档模型与共享 API、能力路由关系图](architecture/diagrams/three-tier-model-architecture.svg)

上图概览当前三档模型组合、spec/capability 路由与共享资源边界。分人按任务显式供给，`reference` 继承同族 8-bit 门禁证据但未单独复测；图示不代表质量排名、机器门槛或正式启用状态。

---

## 📊 当前能力矩阵与就绪状态

| 功能模块 | 运行状态 | 协议与入口 | 核心能力特征 | 验证证据 |
|---|---|---|---|---|
| **批量语音识别 (ASR)** | 契约可用，按 runtime readiness | `POST /v1/audio/transcriptions` | 文档声明的 OpenAI multipart 子集，支持 `verbose_json`、`srt`、`vtt`；分人格式按任务 opt-in 与供给状态启用 | 确定性契约测试；真实质量需按授权单独验收 |
| **语音合成 (TTS)** | 契约可用，按 runtime readiness | `POST /v1/audio/speech` | 24 kHz PCM16 / WAV / MP3 等文档声明格式，按能力快照选择音色 | 确定性契约测试；真实音质与性能需按授权单独验收 |
| **实时流式 (Realtime)** | 契约可用 | `WS /v1/realtime` | 无状态 ASR/TTS 子集与 `speechrail.*` 扩展；服务端提供 VAD 事实，调用方负责 LLM、队列、播放和 barge-in，并显式提交 `speechrail.tts.*` | Python 契约/回归与 Native 纯测试；真实模型/音频质量需单独验收 |
| **说话人分离 (Diarization)** | 可选，需显式供给分人制品/aligner 且资源就绪 | 文件 `diarized_json`；Realtime 显式 opt-in 并选择 `sortformer` 或 `meeting_dynamic` | 私有 CoreML 分人 worker + 独立 aligner；`meeting_dynamic` 每场最多 4 位稳定匿名身份，超额保留未识别；仅输出匿名 session-scoped label | [能力诊断与验收](operations/capability-quality-acceptance.md)；真实质量与长期资源行为需独立实测 |
| **音色包 (Voice bundle)** | 契约可用，按 runtime readiness | `/v1/voices/{voice_id}/bundle`、`/v1/voices/bundles*` | 版本化 `.srvoice` 归档的导出、只读预检、内容预览与导入；导入产生新音色，仍须在当前引擎重新验证 | 确定性契约测试；跨引擎等效性不作承诺 |
| **macOS 全局听写** | App 内可用，按会话占用与服务 readiness | App 内 `⌘⇧D`；底层复用 `POST /v1/audio/transcriptions` | 单段上限 5 分钟、一次一段、写回开始时焦点控件；写入失败降级为复制并说明原因 | Swift 单元测试；真实应用间写入需按授权实测 |
| **macOS 常驻运维服务** | 流程可用，按安装态验收 | `speechrail service` CLI | 用户级 LaunchAgent 管理、状态检查和受控回滚 | 确定性测试与安装态证据分开记录 |

---

## 📝 文档命名规范 (Naming Conventions)

为保证文档中心的高度可预测性与整洁度，所有 Markdown 文件严格统一为以下规范格式（全小写、中划线分隔，禁止大驼峰或下划线混写）：

1. **常态领域规范 (Evergreen)**：`<domain>-<topic>[-<type>].md`
   - 适用目录：`architecture/`、`developers/`、`operations/`、`users/`、`product/` 等常驻规范目录。
   - 代表系统的当前事实与长期规则，**禁止随意添加日期前缀**。
   - 示例：`audiobook-workshop.md`、`testing-acceptance.md`、`security-observability.md`。
2. **时点事件与过程记录 (Point-in-time)**：`YYYY-MM-DD-<domain>-<event-type>.md`
   - 适用目录：`audits/`、`plans/`、`implementation/`、`superpowers/`、`archive/` 等时效/过程目录。
   - 代表特定时点的缺陷排查、审计复盘、执行计划、走查指南或验收凭证，**必须携带标准日期前缀**。
   - 示例：`2026-10-15-audiobook-workshop-review.md`、`2026-10-03-teleprompter-user-journey-plan.md`。
3. **架构决策记录 (ADR)**：`NNNN-<slug>.md`
   - 适用目录：`decisions/`。
   - 四位数字编号序列，用于长期不可逆决策的技术选型追溯。
   - 示例：`0019-stateless-speech-plane-caller-orchestration.md`。
4. **目录入口**：各子目录根统一使用 `README.md` 作为该目录的唯一 Hub 导航。

---

## ⚖️ 事实来源层级 (Hierarchy of Truth)

在查阅或更新文档时，请严格遵守以下事实来源优先级：

1. **第 1 层级（最高事实）**：当前代码实现、自动化测试套件与实际运行验证结果。
2. **第 2 层级（接口规范）**：[`contracts/openapi.yaml`](../contracts/openapi.yaml) 与 [`contracts/realtime-openai.md`](../contracts/realtime-openai.md)。
3. **第 3 层级（正式文档）**：状态为 `active` 的架构、产品、开发、运维文档与 [ADR (架构决策记录)](decisions/README.md)。
4. **第 4 层级（历史材料）**：[`docs/archive/`](archive/README.md) 中的历史设计与过程计划，**仅作追溯参考，不代表当前功能承诺**。

> [!IMPORTANT]
> `/readyz` 返回 200 仅代表模型推理入口已完成配置与预检，真实业务上线前仍需执行对应角色的端到端 Smoke 验证。
