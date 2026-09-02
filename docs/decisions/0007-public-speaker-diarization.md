# ADR-0007：SpeechRail 提供匿名说话人分离

## Status

Accepted — 2026-09-01

## Context

`voice-realtime` 已迁移到 SpeechRail OpenAI Realtime `/v1`。旧会议链路曾依赖
Sortformer 的帧级标签、时序平滑、CAM++ embedding 与会后聚类；迁移后当前
SpeechRail adapter 固定输出 `speaker:0`，因而旧会议端的平滑和声纹代码不能
实现多人分离。

说话人分离是可被字幕、会议和未来客户端复用的声学推理能力；会议中“谁是张三”
则是带权限、人工校正和持久化的业务事实。两者不能由同一组件拥有。

## Decision

SpeechRail 增加可选 `diarization` ASR profile，提供会话内匿名 speaker label、
时间范围、置信度、重叠信息和收尾后的 label remap。未配置该 profile 时明确
拒绝 diarization 请求，绝不伪造单一 speaker label。

`voice-realtime` 仅消费这些匿名结果，并将其映射为会议内的显示名称、人工更正和
数据库事实。它不加载、管理或回退到任何 ASR/diarization 模型。实名声纹识别不在
首发范围；它必须是独立、默认关闭且获得明确授权的未来能力。

实时路径只保留有界环形 PCM 缓冲，收尾路径只接收经 VAD/segment 边界裁剪的短音频。
服务不持久化 PCM、embedding 或真实身份；所有 session-scoped label 在断线后失效。

## Consequences

- OpenAI Realtime transcript segment event 承载 `speaker` / `speakers`，客户端按契约消费
  忽略新增字段。
- `voice-realtime` 的会议表使用 SpeechRail 提供的 label 作为外键，remap 必须以
  原子数据库更新应用，人工名称优先于默认名称。
- 模型实现通过独立端口注入，先以 deterministic fake backend 验证协议和资源边界；
  真实模型仅在本机基准证明实时余量和 DER/JER 后启用。
- 本决策取代 ADR-0005 中“Sortformer 留在会议应用”的部分，其余会议/UI/数据库
  所有权不变。
