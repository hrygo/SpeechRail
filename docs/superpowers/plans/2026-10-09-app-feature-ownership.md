# App 功能状态所有权拆分

日期：2026-10-09。对应 Issue #230。

## 范围

把引擎读取与控制、音色工作流、配音与作品工作流从 AppModel 移到独立 MainActor owner；保留会议与会话现有边界。仅本地源码、fake 回归和编译，不操作服务、安装、模型或用户内容，不执行 UI 自动化。

| 状态与副作用 | 拆分前 | 拆分后 |
| --- | --- | --- |
| 健康、模型、档位、预检、监控、能力快照 | AppModel | EngineModel |
| 设计、克隆、音色编辑、试听与输出检查 | AppModel | VoiceWorkflowModel |
| 待保存配音、作品、段落返修、采用、导出 | AppModel | DubbingWorkflowModel |
| 播放器、进度、电平、当前播放身份、波形缓存 | AppModel | SharedPlaybackOwner |
| 试听与正式生成互斥 | 共享布尔字段 | SpeechCreationAdmission |
| 跨功能就绪投影与装配 | AppModel | AppModel |

功能持有窄能力读取接口、音色目录读取接口及共享播放 owner，不持有 AppModel。各自保留 task、generation、取消与旧 completion 防线；设计/克隆固定幂等身份与回读流程、配音固定待保存身份原样保留。

## 实施与验证

1. 提取引擎 owner 与唯一能力事实源，验证引擎可独立构造。
2. 提取共享播放 owner，回调捕获播放 token 和归属，验证旧回调不能清新播放。
3. 迁移音色、配音依赖与状态；AppModel 仅装配和只读投影。
4. 同步 SwiftPM 与显式 Xcode 成员，迁移对应功能测试并保留组合回归。
5. 运行 AppModel 定向 fake 测试及包装脚本编译，记录证据和未验证边界。

回退仅恢复这些 owner 与装配源码，不改变持久化格式或用户内容。
