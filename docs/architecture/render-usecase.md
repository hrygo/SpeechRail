---
title: "语音渲染应用用例与交付所有权"
status: active
audience: "核心开发者、架构评审者"
version: "1.0.0"
date: 2026-10-09
---

# 语音渲染应用用例与交付所有权

`render_preparation.prepare_render` 接收已校验的 `SpeechRequest`、音色、制品身份
及可选发音规则，生成本次请求的合成文本、固定修订、配方、摘要与时间轴坐标。
它不定位存储、不加载后端、不依赖 HTTP 对象。没有观察到的 runtime 和采样
策略保持未知；显示坐标在归一化或发音映射不能证明时标为不可用。

`render_operation.RenderOperation` 拥有一次渲染的执行依赖、绝对 deadline、
资源 lane、回执与时间轴 ID。它只接受合成、执行能力、音色目录、Governor、
结果 registry 和 metrics 的明确依赖。每个 operation 只执行一次；
音色、lane 与结果归属不从后继请求取得。

| 阶段 | 所有者与约束 |
| --- | --- |
| HTTP 前置校验 | adapter 保留鉴权、字段、模型与音色错误优先级、发音规则查询 |
| 准备与结果登记 | 纯函数构造配方与坐标；adapter 登记结果并映射容量错误 |
| 准入与严格验证 | operation 在同一个 deadline 内取得 Governor reservation 并准备验证身份 |
| PCM 执行 | operation 校验块顺序、响应身份、PCM16 与容量；编码前计量摘要与采样数 |
| 编码与响应 | adapter 保留 PCM、WAV 和容器格式、媒体类型、headers 与 ASGI 事实 |
| 消费与收尾 | operation 持有预取 source 和 body；响应包装即使 body 未开始也调用关闭入口 |

后端 iterator 的清理完成前不退出 reservation。清理 task 经 `join_cleanup`
等待，重复取消不会丢失 owner。清理失败隔离对应 lane，回执保留未确认状态。
对外的完成、取消和失败由实际消费、编码与关闭结果决定；ASGI send 失败
不构成后端回收成功。

容器编码消费同一 PCM 执行 owner，并保留独立的编码进程清理。首块预取和后续
消费沿用同一个绝对 deadline；WAV 的缓冲继续受现有 PCM 字节上限约束。
operation 不增加模型进程、后台无限任务、额外缓冲或第二套音色事实源。

回执的完整性边界是编码前 PCM；它不证明朗读内容无遗漏或设备已经播放。
时间轴的采样坐标与显示坐标保持各自事实范围。验证入口参见
[测试与验收](../developers/testing-acceptance.md)，音色引用与清理参见
[音色验证应用用例与执行所有权](voice-validation-usecases.md)。
