---
title: "三档模型关系图与 Quality 双 TTS 文档同步设计"
status: proposed
date: 2026-09-13
---

# 三档模型关系图与 Quality 双 TTS 文档同步设计

## 1. 目标

将 SpeechRail 当前三档模型组合、能力路由和生命周期行为统一表达在一张可提交到仓库的 SVG 中，并同步主要 active 文档，使读者能明确回答：

1. 三档如何从同一套 API/Gateway 进入 profile 路由；
2. 每档实际使用哪些 ASR、TTS、aligner 和 diarization 制品；
3. `quality` 的 `VoiceDesign (VD)` 与 `Base` 是两个独立 TTS capability worker，而不是互斥地占用同一个模型槽；
4. 双 worker 何时常驻、何时并发、何时因冷却回收，以及下一次请求如何恢复。

本变更只同步文档和架构图，不改变 PR #46 已实现的运行时代码、公共 API 形状、模型下载策略或模型目录。

## 2. 当前事实基线

以下事实以 PR #46 当前代码、测试和 `src/speechrail/assets/model-catalog.json` 为准：

| Profile | ASR | TTS capability | Aligner / diarization |
|---|---|---|---|
| `light` | `asr-0.6b-q8` | `tts-0.6b-custom-q8`（CustomVoice） | 无 aligner、无 diarization |
| `balanced` | `asr-1.7b-q8` | `tts-0.6b-custom-q8`（CustomVoice） | `aligner-q8` + CoreML Sortformer |
| `quality` | `asr-1.7b-q8` | `tts-1.7b-design-q8`（VoiceDesign）+ `tts-1.7b-base-q8`（Base clone） | `aligner-bf16` + CoreML Sortformer |

三档 ASR/TTS 权重均为 8-bit；只有 `quality` 的 aligner 为 bf16。`balanced` 与 `quality` 共享 1.7B ASR 制品，`light` 与 `balanced` 共享 0.6B CustomVoice 制品。

`quality` 的 TTS 运行语义为：

- `voice_design` lane 由 VoiceDesign worker 处理自然语言音色设计和普通 instruction synthesis；
- `voice_clone` lane 由 Base worker 处理 reference-audio clone；
- 两个 worker 可同时常驻，不需要频繁地在 VD 与 Base 之间加载/卸载；
- 两个不同 lane 可并发，同一 lane 仍由 worker lock 串行；
- `WorkerIdleEvictor` 将两个 TTS worker 作为同一 Quality capability group 管理：warm standby 时 trim，超过冷却时间后关闭；下一次对应请求惰性恢复所需 worker；
- Base 不可用时 clone 显式失败，不回退到 VoiceDesign。

共享运行时仍保持：ASR∥TTS 只有在 Resource Governor 根据物理内存和 `*_RESIDENT_BYTES` 判定安全时才重叠；TTS∥TTS 的跨 lane 并发只适用于 Quality 的 VD/Base；不复制 ASR worker 或服务进程。

## 3. 关系图设计

### 3.1 选定布局

采用已确认的 B 方案：

```text
Clients
   ↓
FastAPI / OpenAI-compatible Gateway
   ↓
Profile + capability Router
   ├── light runtime
   ├── balanced runtime
   └── quality runtime
```

图的视觉重点是“共享入口和路由”以及“Quality 内两条 TTS capability lane”，而不是把三档画成三个完全独立的服务。

### 3.2 SVG 文件

新增 `docs/architecture/diagrams/three-tier-model-architecture.svg`，要求：

- 使用自包含静态 SVG，包含 `viewBox`、`role="img"`、`<title>` 和 `<desc>`；
- 采用宽屏布局，在 GitHub Markdown 中可缩放，不依赖外部字体、图片、脚本或网络资源；
- 以颜色区分 profile，但同时使用文字、分组和线型表达语义，不能只依赖颜色；
- 三个 profile 组内分别列出准确 model key；
- `quality` 组内显式画出 `VoiceDesign / voice_design` 与 `Base / voice_clone` 两个 worker，并标注“跨 lane 可并发、同 lane 串行”；
- 在 Quality 生命周期旁标注“cooldown → trim/close group → lazy restore”；
- 将 `server_vad` 放在共享 Gateway/会话层，避免误解为第三个 ASR/TTS worker；
- 将 aligner 与 CoreML Sortformer 画成 `balanced`/`quality` 的可选分人路径；
- 将 Resource Governor 画成跨档共享的准入边界，标出“ASR∥TTS：预算允许才重叠”“不复制 ASR worker”。

不制作动图。该图描述稳定的组件关系；冷却和恢复使用带方向的生命周期箭头即可表达，动画不会增加架构信息。

## 4. 文档同步范围

只修改 active 入口文档和当前 ADR 摘要，不改 `docs/archive/` 历史材料：

- `README.md`、`README.zh-CN.md`：修正 Quality “按需互斥切换/单 TTS 槽”旧描述，加入 SVG 入口，并把双 capability 常驻、并发和冷却卸载写成用户可理解的摘要；
- `docs/README.md`：替换过时的单 VoiceDesign worker Mermaid 拓扑，引用 SVG，更新当前实现基线日期和 Quality 双 worker 事实；
- `docs/architecture/README.md`：在架构文档入口突出三档模型关系图；
- `docs/architecture/architecture.md`：引用 SVG，并在运行时拓扑/三档组成处补充 Quality capability router 的实际生命周期和并发边界；
- `docs/product/overview.md`：更新三档产品能力和 Quality 设计/克隆的运行语义；
- `docs/users/integrations.md`、`docs/users/README.md`：说明客户端无需感知 worker 切换，Quality 按 capability 路由，VD/Base 可以并发但同一 lane 会排队；
- `docs/operations/runtime-deployment.md`：说明两个 Quality TTS worker 的配置、常驻/回收/惰性恢复关系；
- `docs/decisions/0011-unified-runtime-model-tiers.md`、`docs/decisions/0015-tier-user-positioning-and-precision-policy.md`：只补充当前 amendment/summary，保留历史决策原文和时间线。

不在本次范围内：修改 OpenAPI/WebSocket 契约、重新设计模型 catalog、下载或加载本机模型、修改服务配置、重写历史归档、引入动画运行时。

## 5. 验收标准

1. SVG 可由 XML 解析器无错误解析，且文档引用路径存在；
2. SVG 中能检索到全部三档 model key，以及 `voice_design`、`voice_clone`、`concurrent`、`cooldown`、`lazy restore` 等关键关系语义；
3. active 主要文档不再声称 Quality 的 VD/Base 必须互斥切换或共享单一 TTS 槽；
4. 文档明确区分：不同 Quality lane 可并发、同一 lane 串行、冷却后按组回收；
5. 文档明确区分模型常驻生命周期与公共 API 能力声明，不把“可回收”写成“请求路径下载模型”；
6. `git diff --check` 通过，未修改 PR 之外的用户改动、历史归档或模型制品；
7. 变更保持一个可独立回退的 docs commit，且不会改变 PR #46 的运行时代码。

## 6. 回退

回退只需撤销本次 docs/SVG commit。由于不修改代码、catalog、配置或模型文件，回退不会改变 PR #46 的运行时行为。
