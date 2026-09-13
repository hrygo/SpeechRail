---
title: "SpeechRail macOS App 创作工作台与管理控制面"
status: approved
audience: "普通用户、音色创作者、SpeechRail macOS App 开发者与本机运行维护者"
version: "0.2.0"
date: 2026-09-13
---

# SpeechRail macOS App 创作工作台与管理控制面

## 1. 目标

在现有 SpeechRail macOS App 上保留音色创作作为一级产品能力，并补充一个面向本机
用户与开发者的服务管理区域。整体吸收设计交付包中的浅色原生 macOS、左侧导航、
内容优先和状态分层语言，同时提供：

1. 服务启停、重启、当前档位、回退和预检；
2. `quality`、`balanced`、`light` 模型制品的目录、容量、来源和本机状态；
3. 用户明确触发的模型下载与校验，且允许只下载、不切换当前档位；
4. 服务健康、Worker 生命周期、实时/批量负载和低基数运行指标的监控看板。

本设计把“创作”和“服务”作为同一产品中的两个一级区域：创作区保留配音台、音色创作、
音色库和我的作品的产品框架；服务区负责让本机 SpeechRail 可用、稳定、可诊断。管理区
不替换创作区，也不把服务内部术语强行带入普通用户的创作路径。当前实现能力仍以代码、
契约和测试为准，本轮文字原型不等于已经实现全部创作页面。

## 2. 当前事实与边界

- App 当前是 SwiftUI `MenuBarExtra` + `Settings` 控制面，状态通过 loopback
  `GET /health` 读取，改变运行态的动作通过受签名约束的 XPC control agent
  委托 managed Python CLI。
- XPC 当前支持 `status`、`start`、`stop`、`restart`、`preflight`、profile
  list/status/apply/rollback 和 operation status；profile apply 已经是异步 operation。
- Python 当前已有 `list_profiles()`、`prepare_models()`、ModelScope 固定来源下载器、
  文件大小与 SHA-256 校验、staging、原子发布和注册表；`profile apply` 会复用这些能力。
- `/health` 已发布服务、版本、活动档位、ASR/TTS/分人/VAD readiness、Worker lifecycle
  state 和 job spool 状态；`/metrics` 支持低基数 JSON，包含 active/pending 请求、Worker
  状态、健康 gauge、counter 和 histogram。
- 当前服务默认 loopback、单一 ASGI worker、单一服务实例；App 不加载模型、不采集/播放音频、
  不直接调用 `launchctl`，模型与 runtime 仍位于 App bundle 外部。

## 3. 方案选择

### 3.1 采用：独立管理控制中心 + 保留创作区 + 独立 Settings

使用独立的“管理控制中心”窗口承载服务区，使用 `NavigationSplitView` 组织创作区与服务区。
菜单栏提供状态快照和高频服务动作；macOS `Settings` scene 只承载应用偏好，不承载运行监控
或模型下载。这样既保留音色创作的产品主线，也让运行态操作有足够空间呈现解释层和技术详情。
控制中心继续复用现有 XPC、`URLSession`、菜单栏入口和 UI test fake；模型下载仍由
helper/CLI 执行，符合现有安全边界。

### 3.2 不采用：独立 Web 管理后台

它会引入新的本地 HTTP 管理入口、鉴权和生命周期边界，与单机原生控制面目标重复，且容易
把技术状态带入创作产品的默认体验。

### 3.3 不采用：把下载绑定为切档唯一动作

用户无法提前准备较大的模型，也无法在不影响当前服务的情况下完成下载；同时会把“制品已
准备”和“服务已切换并通过 smoke”混成一个状态。本设计明确分离二者。

## 4. 信息架构与界面

管理控制中心侧栏按产品职责分成两个区域：

**创作**

- **配音台**：进入以文本、角色和音色为核心的创作流程；
- **音色创作**：通过描述、试听和候选管理创建音色；
- **音色库**：管理已保存和已绑定的音色；
- **我的作品**：查看生成、版本和导出结果。

**服务**

- **总览**：服务脉冲、当前档位、最近 operation 和快捷操作；
- **运行监控**：健康矩阵、请求负载、Worker 状态和最近采样；
- **模型管理**：档位模型目录、下载/校验状态和“仅下载”操作；
- **预检与诊断**：受管 runtime 预检结果、失败原因和恢复动作。

侧栏底部固定显示简化的“语音服务状态”，菜单栏保留快速启动、停止、打开控制中心和
跳转音色创作的入口。创作区与服务区共享视觉骨架，但每个页面都必须先说明功能定位和
下一步动作，再提供可展开的技术证据。

### 4.1 视觉语言

- 采用系统窗口背景、`systemBlue` 作为唯一强调色和适量 material；支持系统深色模式。
- 以一个“服务健康脉冲”作为总览页的主视觉，其余内容使用有语义的分组和表格，不铺满
  同质化圆角卡片。
- 状态同时使用图标、文字和形状标记，不能只依赖红/黄/绿颜色。
- 默认显示面向普通用户的解释层；“技术详情”使用渐进式披露，不设置割裂的开发者模式。
- 音色创作页面保留原设计包的描述、试听、候选、保存与绑定语义；模型未就绪时说明依赖和
  下一步，不清空或修改已有音色和作品。
- 不显示绝对模型路径、`.env`、Authorization、原始日志、音频、完整请求或转写内容。
- 只有数据样本足够时才绘制趋势；没有数据时显示“等待采样”，不生成虚假分数或百分比。

完整的文字原型、各状态文案和交互确认见
[`docs/design/speechrail-management-prototypes.md`](../../design/speechrail-management-prototypes.md)。

## 5. 模型管理

### 5.1 用户可见的状态

每个档位展示组成制品：ASR、主 TTS、可选 TTS Base/clone、aligner 和分人制品。每个制品
只展示 catalog 中的安全元数据：artifact key、family/variant、量化方式、估算总容量、
来源 provider/repository 的简化名称和 revision 短标识。

本机状态使用以下互斥值：

- `notDownloaded`：没有通过当前 catalog/revision/hash 验证的快照；
- `downloading`：该档位存在活动准备 operation；
- `verified`：全部所需制品已通过当前 manifest 验证；
- `invalid`：检测到快照或 registry 不匹配，需要重新下载；
- `unknown`：服务/Agent 暂时不可读，不能据此判断模型不存在。

`verified` 只表示制品准备完成，不表示当前服务正在使用，也不表示推理质量已验证。

### 5.2 操作分离

模型管理提供两个明确动作：

1. **下载并校验**：只准备选中档位的 catalog 制品，不停止服务、不写入 active profile、
   不修改服务配置；成功后状态为 `verified`。
2. **应用此档位**：沿用现有 `profile apply` 事务。若缺制品，先复用或补齐准备流程，再停止
   唯一服务、切换 selection、启动并执行 public API smoke；失败按现有 journal/rollback
   语义恢复。

已有的 `profile apply` 仍可自动准备缺失制品，但 UI 必须把下载阶段和应用阶段分开展示。

### 5.3 下载安全与一致性

- App 不直接访问模型源；所有下载由 `SpeechRailControlAgent` 调用 managed Python CLI，
  再由现有 `model_store` 使用 catalog 锁定的来源、revision、文件大小和 SHA-256。
- 不接受用户输入的任意 URL、仓库、revision、路径或 shell 参数；下载目标只能来自仓库
  内发布的 model catalog。
- 使用既有 `.staging`、磁盘空间检查、流式写入、单文件校验、完整快照校验和原子 registry
  发布。失败清理 staging，不覆盖已验证的旧快照。
- 下载和 profile apply 都属于 mutation；control agent 保证同一时刻只有一个 mutation，
  不复制 ASGI worker 或模型进程。
- 本轮不增加删除模型动作，避免把模型回收与运行态切换混在同一次交付中。

### 5.4 下载 operation

新增的模型准备 operation 使用现有 `OperationSnapshot` 轮询链路，阶段至少包括：

`accepted → downloading → verifying → publishing → committed`，失败进入 `failed` 并保留
安全可读的 message/error code。

catalog 提供的估算容量用于确认文案和空间提示；在 CLI/Agent 尚未传递可靠实时字节进度前，
UI 不显示伪造的百分比，只显示阶段、已准备/待准备的制品和可重试动作。已完成的制品由
`model status` 重新核验，而不是信任上一次 operation 结果。

## 6. 运行监控看板

### 6.1 数据来源

- `/health`：服务身份、档位、ready、ASR/TTS/Streaming/diarization/VAD lifecycle 和
  job spool 状态；
- `/metrics` with `Accept: application/json`：active/pending 请求、Worker 状态、健康 gauge、
  counter 和 histogram；
- XPC `operationStatus`：服务控制、档位切换和模型准备的当前阶段与失败信息。

不新增服务端 API，不让 App 读取日志或模型目录。App 只在内存中保留最近 60 个采样点，
窗口离开后停止轮询，进程退出后不持久化。

### 6.2 看板布局

顶部展示“服务健康脉冲”：

```text
+---------------------------------------------------------------+
| SpeechRail  管理控制台                 刷新  自动刷新 5 秒   |
+----------------------+----------------------------------------+
| 侧栏                 | 服务健康脉冲                           |
|  总览                | ready / profile / version              |
|  运行监控            | ASR  TTS  Streaming  分人  VAD       |
|  模型管理            +----------------------------------------+
|  预检与诊断          | 请求负载       Worker 生命周期        |
|                      | realtime/batch  active/pending         |
|  ● 语音服务运行中    +----------------------------------------+
|                      | 最近采样：吞吐/延迟/活跃请求曲线      |
+----------------------+----------------------------------------+
```

看板至少包含：

- 子系统健康：ASR、TTS、streaming、diarization、realtime VAD；展示 ready、lifecycle state
  和诊断 message；
- 请求负载：realtime/batch active 与 pending；队列拒绝累计值；
- Worker 生命周期：`active`、`warm_standby`、`cold_evicted`、`inactive`、`unconfigured`；
- 低基数性能摘要：HTTP 请求累计、ASR/TTS inference histogram avg、TTS TTFA avg、
  realtime active sessions；
- 最近采样曲线：使用相邻 metrics counter 差值计算窗口速率，采样不足时不绘制速率。

任何一个 endpoint 暂时不可用都要在对应区域显示“暂时无法读取”和最近成功读取时间，
不能把服务不可达渲染成“正常”或把缺失指标渲染成零值。

### 6.3 刷新与生命周期

- 首次进入管理区立即刷新；运行监控在页面可见时每 5 秒刷新一次。
- 刷新任务必须可取消、不能重叠；离开页面或 App 进入后台时取消定时任务。
- 总览的手动刷新复用同一刷新入口；XPC operation 轮询与 HTTP metrics 采样分开，互不阻塞。
- 监控采样失败只影响本次采样，不清空最近可信状态；重新成功后更新时间和状态一起更新。

## 7. 数据与代码边界

### 7.1 AppModel

AppModel 增加以下可观察状态，保留已有 `service`、`profiles`、`profile`、`operation` 和
`message` 兼容入口：

- 详细 `HealthSnapshot`；
- `RuntimeMetricsSnapshot`；
- `ModelCatalogSnapshot`/每个制品的安全状态；
- `preflightChecks`；
- `lastHealthRefresh`、`lastMetricsRefresh`、刷新错误状态；
- 最近 60 个内存采样点。

AppModel 负责刷新调度、状态合并和安全的派生摘要；View 不直接持有 URLSession、Process、
文件句柄或 XPC 连接。

### 7.2 ServiceAPIClient

ServiceAPIClient 增加 health 详细字段和 metrics JSON 解码，使用 `decodeIfPresent` 兼容
旧版本服务。未知字段忽略；已知字段类型不符时明确返回客户端错误。

metrics 解码器只保留约定的顶层对象、低基数 gauge/counter/histogram；不把原始 Prometheus
文本或任意 label 内容传入 View。

### 7.3 ControlKit 与 managed CLI

新增模型状态与模型准备所需的固定 command/response 字段；所有字段继续使用
`schema_version=1`、固定 profile enum 和 path-free message。现有 profile list/status/apply/
rollback 的外部行为保持兼容。

Python 侧新增只读模型状态命令和显式模型准备命令，复用 `model_store.prepare_models()`；
模型准备命令只返回 catalog-keyed 安全摘要和 operation 状态，不返回绝对路径、token、完整
异常或原始日志。

## 8. 错误与恢复

| 情况 | UI 行为 | 恢复动作 |
|---|---|---|
| 服务不可达 | 总览/监控显示不可用，保留最近成功时间 | 启动或重启服务 |
| control agent 未注册/需批准 | 管理操作禁用并显示状态 | 引导用户在 Login Items & Extensions 批准后重试 |
| 磁盘空间不足 | 模型下载失败，显示 catalog 估算容量与可读原因 | 释放空间后重试 |
| 来源不可用 | 下载 operation 失败，不影响当前服务 | 稍后重试；不切换 active profile |
| 文件大小/hash 不匹配 | 标记 `invalid`，清理 staging | 重新下载；不信任不完整快照 |
| 模型下载失败 | 当前档位与服务保持不变 | 重试下载或进入预检 |
| profile apply smoke 失败 | 显示 rollback/NOT_READY 与 error code | 使用现有 rollback/preflight 链路 |
| metrics 部分字段缺失 | 只隐藏无法计算的摘要 | 继续展示其他可信指标 |

## 9. 隐私、安全与运行态要求

- 模型下载是用户明确触发的网络动作；启动 App、打开看板、读取 `/health` 或 `/metrics`
  不得隐式下载模型。
- 下载只允许 catalog 锁定来源；App 不允许编辑 provider、repository、revision 或目标路径。
- 保持 loopback-first；不新增远程管理入口，不把 API key 放入 URL 或 UI 文案。
- 日志和测试 fixture 不记录 API key、Authorization、完整模型路径、完整异常、原始音频、
  完整转写或模型内容。
- App 退出不停止已运行的 SpeechRail 服务；模型准备 operation 由 helper/CLI 继续完成，
  App 重开后以 model status 重新核验结果。
- 不下载、不加载、不卸载真实模型作为普通 UI 测试步骤；真实下载只在用户明确授权的本机
  验收中执行。

## 10. 测试与验收

### 10.1 Swift 单元测试

- health payload 完整字段、旧字段缺失和未知字段兼容；
- metrics JSON 顶层解码、gauge/counter/histogram 摘要和缺失值语义；
- counter 相邻采样速率计算、采样不足不显示趋势；
- 模型状态 `notDownloaded/verified/invalid/unknown` 派生；
- model download 与 profile apply mutation 串行；
- operation phase/message/error code 在成功、失败、Agent 不可用时可读。

### 10.2 UI Tests

使用现有 `--ui-test` fake transport 和 fake service diagnostics，不访问真实服务或模型源，
覆盖：

- 管理控制台侧栏与四个入口；
- 服务不可用/部分 readiness 的明确状态；
- 模型管理显示三档、容量和状态；
- “仅下载”确认与 operation 阶段；
- 下载失败保留当前档位且显示恢复动作；
- 运行监控展示 active/pending、Worker 和无样本空状态；
- 菜单栏打开管理控制台以及启动/停止入口。

### 10.3 本机验证

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

若进行真实下载验收，必须单独记录目标 profile、来源和本机磁盘/网络影响；不得把模型、
runtime、日志或下载原始数据写入仓库。

## 11. 回退策略

- UI 变更可通过回退 App release 恢复；不覆盖 Python managed runtime、模型目录或 profile journal。
- 模型准备失败只影响 staging 和该次 operation；已有 verified snapshot 与当前服务保持不变。
- model status/prepare 命令是新增能力；若 helper 或 CLI 版本不匹配，App 显示 unsupported，
  不猜测状态、不执行 profile apply。
