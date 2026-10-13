---
title: TTS 执行端口与组合边界
status: active
version: "1.0.0"
date: 2026-10-09
---

# TTS 执行端口与组合边界

`SpeechSynthesizer.synthesize` 只承诺批量语音合成。增量输入、严格音色准备、
资源调度提示与运行身份读取分别通过窄端口注入；批量实现不需要提供这些能力。
`TtsExecutionPorts` 是组合时的依赖快照，不代表 worker 已协商、模型已就绪或资源充足。

`IncrementalSpeechSynthesizer.open_stream` 接受 `TtsStreamOptions` 与 `TtsStreamLimits`，
返回由应用控制器持有的 `IncrementalSpeechSession`。生产 adapter 委托 worker/router 的
`open_incremental_stream`：该入口负责路由、音色租约与 worker 槽位，再启动底层 vendor
会话。不能绕过此层直接把低层 vendor factory 当作应用入口。

`VoiceLaneResolver` 给出可选 lane；缺失提示使用 Governor 保守 wildcard，
非法名称拒绝准入。`VoicePreparer` 在已持有资源准入时准备严格请求，并返回实际观察的
运行身份；克隆请求缺少此端口时拒绝严格执行。准备取消继续传播，不包装成普通后端失败。
`VoiceRuntimeIdentity` 只读取当前观察，不加载 worker；未知或无效身份不能提升证据等级。
`SamplingObservationReader` 读取实际采样事实，缺失时回执保持部分或未知事实。

主组合根一次绑定可选后端能力，REST、Realtime、文件作业与音色验证使用同一份快照。
独立文件作业构造入口也可以显式注入快照。第三方动态属性发现集中在
`backends/tts_execution_adapter.py`；应用用例直接调用声明的端口。
增量 factory 签名在装配时校验，协商标志在读取时更新，不能冻结成就绪结论。
返回无效会话时无法确认物理回收，隔离对应 lane 并拒绝继续使用，直到运行时恢复。

`TtsStreamService` 只接收其所需 factory、lane 与身份端口。`StreamController` 继续拥有
增量会话、准入、唯一终态、ACK 背压及回执收尾；打开失败和重复取消仍通过有 owner 的
清理任务等待。清理未确认不得完成成功回执或解除隔离。

此边界不改变 REST/Realtime wire、持久化音色格式、worker 数量、模型选择或物理资源预算。
确定性端口测试与传输回归不证明真实模型质量、性能或长时稳定性。
