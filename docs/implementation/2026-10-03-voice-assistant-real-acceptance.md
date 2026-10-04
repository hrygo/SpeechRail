---
title: "语音助手真实评估入口（R：设备 / 模型 / 长时）"
status: not_run
version: "0.1.0"
date: 2026-10-04
---

# 语音助手真实评估入口（R）

- 范围：只覆盖须真实模型、设备、素材的 R 项；离线转写事件不能证明 AEC、双讲或设备尾音。
- 前置授权：真实采集与模型调用须另行明确授权，含操作者同意、素材授权、保留位置与删除方式；本文件不构成执行授权。
- 隐私：素材放仓库外；manifest 必填素材授权、设备/系统/模型/voice revision、policy、标注时间；仓库内仅 schema、合成 fixture 与工具，素材路径/正文不进交付报告。
- 报告口径：每个场景报告 attempts / successes / failures / timeouts 与分层 sampleCount，不剔失败美化延迟；无样本记 `not_run`。

## R56 接话语料（A56 / VA-13）

- 素材：已授权真人互动，覆盖安静停顿、自修正、补一句、短答案；标注语音结束/意图。
- 判定：抢话、漏接、合并错误与新增等待，含失败分母。状态：`not_run`。

## R57 AEC 与双讲（A57 / VA-13）

- 设备：至少耳机、内置扬声器、一组实际外接音频设备；记录设备型号、系统、ASR/TTS/model/voice revision。
- 场景：远端独讲、近端独讲、双讲；分设备记录误插话/回声/截断。录音重放不能冒充 AEC 双讲证据。状态：`not_run`。

## R58 噪声与复述（A58 / VA-13）

- 覆盖键盘/咳嗽/噪声/附和/复述助手原句；非意图不过度打断，真实插话能停，复述不被回声误杀。状态：`not_run`。

## R59 长会话（A59 / VA-14/16）

- 30～60 分钟多轮语音/typed；监控 memory/queue/tasks 无持续增长，budget 有效，结束有设备释放证据。状态：`not_run`。

## R60 失败旅程（A60 / VA-01/03/07）

- 连失败→恢复→休眠→拔设备→结束完整旅程；记录真实、无跨功能误停，不自动录音/重播旧内容。状态：`not_run`。

## 离线回放 runner（VA-17b 评估工具）

- 位置：`macos/SpeechRailApp/SpeechRailApp/AssistantReplayEvaluator.swift`（共享评估逻辑）与
  `macos/SpeechRailApp/AssistantReplayTool/main.swift`（CLI 入口，只读仓库外 manifest，输出脱敏聚合）。
- 形态复用提词器 `teleprompter-replay`（manifest 驱动、schema 版本化、缺素材直接失败、不录音/不联网）。
- 落地条件：获得实施授权后在 `Package.swift` 声明实际 target 与测试依赖；新增 CLI target 只在真实有 runner 时加入，不先造空产品。
- 当前状态：未建（`not_built`）；A59/A60 仍记 `not_run`。
