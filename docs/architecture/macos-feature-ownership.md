---
title: "macOS 引擎与创作状态所有权"
status: active
audience: "macOS 开发者、架构评审者"
version: "1.0.0"
date: 2026-10-09
---

# macOS 引擎与创作状态所有权

`AppModel` 装配引擎、音色、配音与共享播放对象，提供现有视图所需的只读投影和命令转发。状态修改、请求代际与任务句柄归对应功能 owner；投影直接读取 owner，不建立第二份缓存。所有 owner 保持 `MainActor` 隔离。

| Owner | 状态、任务与副作用 | 依赖 |
| --- | --- | --- |
| `EngineModel` | 健康、控制面、档位、模型、预检、监控、能力发现、各读取与操作代际 | control transport、diagnostics、discovery、registration |
| `VoiceWorkflowModel` | 音色目录、详情、设计候选与发布、克隆注册与回读、音色编辑、输出检查、试听任务与缓存 | 对应窄客户端、`EngineCapabilityReading`、共享播放与生成准入 |
| `DubbingWorkflowModel` | 固定待保存结果、作品库、配音项目、返修任务、采用与导出 | render/receipt 客户端、作品与项目 store、`CreatorVoiceReading`、能力读取与共享播放/准入 |
| `SharedPlaybackOwner` | 唯一播放器、播放 token 与 target、进度、电平、波形缓存 | 可注入播放 driver |
| `SpeechCreationAdmission` | 音色试听与正式配音生成的互斥归属 | 无服务或存储依赖 |
| `CreatorFeedback` | 创作页面共用的一条反馈文案 | 无服务或存储依赖 |

`EngineCapabilityReading` 提供只读能力投影与绑定解析，不暴露引擎控制、诊断客户端或任意状态写入。`CreatorVoiceReading` 只提供已观察的音色目录和加载状态。功能 owner 不持有 `AppModel`。会议、纪要与会话继续使用各自的 owner。

## 身份与收尾

音色设计发布保留 candidate/revision/validation 与固定发布身份；克隆注册保留音频、文本、voice ID、幂等键及不确定提交的回读。重试使用原身份，明确拒绝后才释放重试上下文。取消、旧响应和旧 task 的收尾按功能内的 generation 判定。

待保存配音固定生成时的正文、音色、revision、plan、速度、作品 ID 和 provenance。显式保存使用这份结果，不读取后来改变的 UI 输入。返修代际、项目身份和固定制作条件由配音 owner 判断，旧结果不得写入新项目。

共享播放在开始时捕获 token、target 和对应功能的完成回调。停止或失败撤销 token；完成、进度和电平回调只有持有当前 token 才可落地。设计试听回调携带 candidate/revision/validation，不按当前选中项判断归属。回调弱引用功能 owner，播放 owner 不反向持有组合根。

试听等待能力绑定后重新检查请求代际、取消及生成准入；正式配音和试听只有取得各自准入后才发送渲染请求。释放只接受当前功能归属，另一功能不能撤销在途生成。

## 验证边界

引擎可只用 control/diagnostics/discovery fake 构造；音色与配音可使用窄能力或目录 fake。播放身份回归使用无声、无设备的 fake driver。定向回归覆盖取消、旧响应、幂等回读、固定保存身份与组合投影；App 编译检验 SwiftPM/Xcode 成员与视图接线，视觉和真实音频体验仍需对应专项验收。
