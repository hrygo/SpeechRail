# AI 能力差异化配置设计

**状态：** approved for implementation
**日期：** 2026-09-20
**范围：** macOS 控制面内部 LLM 配置与 AI 模块接线，不改变 SpeechRail 公共 REST/Realtime 契约。

## 1. 目标

SpeechRail 的语音助手、会议纪要和 AI 提词器对模型能力、延迟、结构化输出和隐私边界的要求不同。配置不能继续只表达“一台全局 LLM”，但也不能让每个模块各自复制一套请求、密钥和回退逻辑。

本设计提供：

- 一个全局默认 LLM 配置；
- 每个 AI 模块可选的专用 endpoint、model 与专用 Key；
- 统一、纯值的优先级解析器；
- UI 与运行时采用同一解析结果；
- 兼容已有的会议 `minutesModel` 偏好；
- 专用配置缺失或不合法时的可解释整组回退；
- Key 只进入现有本机加密安全保管库，不进入 UserDefaults、日志、文稿或错误正文。

## 2. 评审后的模块边界

| 模块作用域 | 覆盖对象 | 说明 |
| --- | --- | --- |
| `assistant` | 语音助手、会议中的 Inner OS | 同一类短时对话能力，共用一个作用域，避免无价值的第四套配置 |
| `minutes` | 会议纪要生成 | 结构化长任务，可使用更擅长 JSON schema 或更高质量的模型 |
| `teleprompter` | AI 提词稿整理 | 用户主动触发、严格结构化输出，允许与对话/纪要完全不同的本地或网络端点 |

全局配置不是第四个模块，而是所有作用域的默认值。

## 3. 优先级与回退

解析器的输入是全局配置、模块覆盖、全局 Key 和模块 Key；输出为一次执行所需的不可变 resolved value。

1. 模块覆盖关闭或不存在：使用全局 endpoint、model、Key。
2. 模块覆盖开启且 endpoint 与 model 均完整、endpoint 不含凭据：使用模块 endpoint/model。
3. 模块覆盖的专用 Key 非空：使用专用 Key；为空则只对 Key 回退全局 Key。
4. 模块覆盖 endpoint/model 不完整或含凭据：整组 endpoint/model 回退全局，并返回 `globalFallback` 与原因，UI 必须可见。
5. 请求失败不触发另一个 endpoint 的隐式重试；这既避免重复发送原稿，也避免把“配置错误”伪装成透明成功。

“整组回退”是关键约束：不能拿模块 model 配全局 endpoint，也不能拿模块 endpoint 配全局 model。

## 4. 数据与安全

- `LLMModuleOverride` 是可编码、可比较的值类型，只持久化 `enabled/baseURL/model`。
- 覆盖字典使用 UserDefaults 的 JSON Data 存储，旧键 `speechrail.session.meeting.minutesModel` 保留作为兼容输入，不删除、不覆盖。
- `LLMKeychain` 保持已有 global vault 文件不变；模块 Key 使用同一 master key、同一 0600 目录下的作用域文件。global 旧钥匙串清理逻辑继续保留。
- 不把 Key 放进 `SessionPreferences`、解析结果日志、会话记录、URL、prompt 或错误正文。
- 解析器只做选择，不做网络探测；连接检查由 UI 对当前选择的 resolved endpoint 发起一次显式请求。

## 5. UI 方案

会话设置采用渐进式披露，遵循“开箱即用、约定大于配置”：

1. “大模型（全局默认）”是唯一主路径，保留现有 endpoint/model/global Key/Responses-only/连接检查；所有功能默认继承它，用户无需逐项设置。
2. “高级：按功能自定义”只占一行可展开入口。用户主动探索，或已有模块覆盖需要维护时，才展开助手、会议纪要、AI 提词器的统一设置卡。
3. 展开后的每张卡包含：跟随全局/使用专用配置开关、endpoint、model、专用 Key、当前生效来源和配置状态；专用 Key 留空明确表示继承全局 Key。所有间距、颜色、字体、圆角和控件形态复用 `SpeechRailDesignTokens`，不添加局部 token。

高级入口的摘要明确说明“默认跟随全局”。如果检测到已经启用的模块覆盖不完整或地址不合法，设置页自动展开并显示回退提示，避免已有配置被隐藏；普通用户不会因为存在可选能力而增加初始配置负担。

连接检查可针对全局或当前模块专用配置，展示解析后的实际结果；如果模块覆盖不完整，先显示回退提示，不把全局连接结果冒充模块专用连接结果。

## 6. 运行时接线

- `AssistantSession` 的启动探测、会话快照和每轮回复统一解析 `assistant`。
- `InnerOSDrawer/InnerOSSession` 传递同一份 `assistant` resolved value，避免在 session 内重新读取 global Key。
- `MeetingSession`、`MeetingView` 和启动恢复统一解析 `minutes`，`MinutesGenerator` 接收 resolved value，不在后台任务里自行读取 global Key。
- `App` 的 Teleprompter AI client 解析 `teleprompter`，并把 resolved Key 仅传给一次 `LLMProvider.complete`。
- prompt/context 构建仍属于各功能模块；本次只改变其 LLM transport configuration，不把模块语义 prompt 搬进通用配置层。

## 7. 兼容与迁移

- 旧 global endpoint/model/Key 的行为不变。
- 旧 `minutesModel` 在没有显式 `minutes` 覆盖时继续生效；用户首次编辑模块配置后写入新覆盖字典。
- 没有覆盖时所有模块的 resolved result 与当前全局行为等价。
- 不改变服务端 API、OpenAPI、Responses 请求形状或已有 prompt schema。

## 8. 验证与非目标

必须验证：解析优先级、整组回退、Key 继承、旧 minutes 偏好、三类运行时接线、设置页编译、现有 LLM 请求回归。

本次不处理：

- 多账号/团队密钥管理；
- 自动模型发现、自动路由或请求失败重试；
- Teleprompter 原有并发、偏移校验和 Store 审查项；
- UI 自动化测试（项目规则要求当前用户逐次明确授权，本次未授权）。
