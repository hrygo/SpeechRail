# Teleprompter Position Following Implementation Plan

**Goal:** 让逐字稿在分次识别、连续朗读、插话和局部重读时持续定位，并让无 AI 的开始流程完整可用。

**Architecture:** 在现有 App 领域层建立带原文坐标的 token 索引，使用有界局部序列对齐；控制器按 ASR item 整理 partial/final，区分候选与确认位置。运行会话固定稿件版本，舞台以阅读位置驱动滚动。AI 只引用本地编号单元做标注，程序负责范围与完整性。

**Tech Stack:** Swift 6、Foundation、SwiftUI、现有 RealtimeASRClient；无新增依赖或模型。

**Spec:** 本会话 2026-09-20 用户批准的八项用户旅程与跟读设计；本文件记录实施边界。

## Global Constraints

- macOS 26.0 / arm64；保留现有稿件持久化格式和用户数据。
- 不改 ASR 服务协议，不启动真实服务、模型、UI 自动化，不安装或发布。
- 已有 UI 文案和设置相关未提交改动保留；只做增量修改，不提交或推送。
- 后续 ASR 换型、声学逐字时间戳、提纲语义定位与全局快捷键不在本轮实施。

## Review Focus

- partial/final 纠正和重复事件不产生重复推进。
- 暂停、手动定位、重连后的迟到事件不能覆盖用户位置。
- 中文、英文、数字及重复句不能因归一化或短公共词误跳。
- AI 返回缺单元、重复单元、越界、长稿中途失败时不可采用半份稿件。
- 草稿切换或修改后到达的 AI 响应不能替换当前版本。

## Execution

- [ ] 1. 在现有 Normalizer/Aligner 测试中加入默认参数的正文匹配、分句、跨段、局部重读、无关内容与坐标测试；先运行失败，再实现索引与局部编辑距离对齐。
- [ ] 2. 在 FollowController 测试中加入 item 增量、final 替换、重复抑制、暂停与恢复边界；实现候选/确认位置和有界内存。
- [ ] 3. Session 固定运行版本、门控编辑和 AI 响应、恢复前排空旧事件；舞台加入原文位置提示、滚动及从指定段落开始，准备流程默认按原文开始。
- [ ] 4. Analysis 改用本地编号单元、分窗口请求、严格全覆盖校验和保留原文的 prompt；测试 Unicode、错误引用和长稿合并。
- [ ] 5. 同步当前开发文档，运行 `swift test --package-path macos/SpeechRailApp --filter Teleprompter` 和不签名的 App 编译验证；检查差异与并行修改。

## Validation and Recovery

确定性测试使用合成文本和 fake completion；不将测试通过等同于真实跟读质量。保留每个修改文件的任务开始快照于仓库外，仅在需要时用差异定位本轮修改，不整文件覆盖现有工作。AI wire schema 更新为 v2，本机版本存储不变，已有稿件仍可使用。回退仅撤回本轮 diff；不回退其他任务的修改。
