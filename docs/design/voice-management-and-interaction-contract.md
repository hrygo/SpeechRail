# 音色管理与全局交互统一设计契约

> 状态：active
> 日期：2026-09-20
> 适用范围：SpeechRail macOS 控制面、SpeechRail REST 音色管理接口

## 背景与已确认事实

本次问题不是单一页面的视觉缺陷，而是控制面、REST 客户端和音色持久化层没有共享同一套交互与能力边界。

以下是 2026-09-14 修复前的基线记录，不代表当前源码状态：

- 当时本机服务 `/health` 为 ready，`GET /v1/voices` 返回成功；旧 App 发出的 `/v1/audio/speech` 与 `/v1/voices/previews` 请求在服务日志中返回 `401 Unauthorized`。
- 当时 `ServiceAPIClient` 未携带 `Authorization`，服务端在配置 API key 时要求 `Bearer`。
- 当时服务端和 `VoiceRegistry` 尚未提供单音色读取与更新闭环。
- 当时 pointing-hand 只覆盖部分自定义控件，左侧导航以及 Picker、Slider、DisclosureGroup 等原生交互控件未统一覆盖。

当前源码已完成对应修复：

- `ServiceAPIClient` 统一从受管凭据来源发现 key，并为请求添加 `Bearer`；音频响应校验 `audio/wav` 和非空 body。
- 服务端、OpenAPI、Swift client、`AppModel` 和音色库已对齐 `GET/PATCH/DELETE` 语义；更新失败保留旧记录。
- 按钮、菜单行、侧栏导航、列表选择行、音色特征标签和 `DisclosureGroup` 均使用共享整块命中区与反馈规则。

以上结论区分了修复前基线、当前源码和运行态验证；不把“配置存在”或“服务 ready”推断成模型推理已经成功。

## 产品目标

1. 用户能分辨“可以操作的控件”和静态内容，操作有 hover、pressed、focus 和 disabled 反馈。
2. 配音台、音色库和音色创作共用同一个本机鉴权入口，服务真实返回的音频才能进入播放链路。
3. 音色库形成可理解的 Create / Read / Update / Delete 闭环，同时保护系统音色和 clone 音频资产的不可变来源。

## 全局交互契约

- `Button`、`NavigationLink`、`Menu`、`Picker`、`Slider`、`Toggle`、`DisclosureGroup` 和可点击列表行等操作/选择控件使用 pointing hand。
- `TextField`、`TextEditor`、代码/日志文本选择区保留 macOS 标准 I-beam 或文本选择行为；它们是编辑区域，不是动作按钮。
- 指针区域必须覆盖控件的真实 hit target，不能依赖一个零尺寸或不参与布局的背景视图。
- enabled 控件提供 hover、pressed、keyboard focus 反馈；disabled 控件不显示 pointing hand，也不伪装成可用。
- 左侧导航行是完整的可点击区域，文字、图标和留白都属于同一个 hit target，并使用统一的选中填充、对比度和 focus ring。

## 鉴权契约

`ServiceAPIClient` 采用与现有 CLI / MCP 一致的凭据发现顺序：

1. `SPEECHRAIL_APP_HOME/config/.env`；未提供 app home 时使用用户 Application Support 下的受管 SpeechRail 目录；
2. 进程环境变量 `SPEECHRAIL_API_KEY`，仅在受管配置不存在时作为 fallback。

受管配置优先是为了避免 GUI 进程继承启动它的旧环境变量，导致 App 使用过期 key 而服务仍使用当前 managed key。

凭据只保存在客户端内存中，禁止写日志、URL、错误文案或 App 持久化状态。所有 REST 请求统一通过 `makeRequest` 添加：

```swift
if let apiKey = apiKey {
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
}
```

未配置 key 时仍允许公开的健康/列表读取请求；服务端返回稳定的 `401` 时，UI 显示“本机服务凭据不可用”类安全文案，不显示响应原文中的路径或 secret。

## 音色 CRUD 与 revision 契约

兼容的 `/v1` surface 保留：

- `GET /v1/voices`：读取当前服务端音色列表；
- `GET /v1/voices/{voice_id}`：返回单个服务端音色的完整安全 metadata；
- `POST /v1/voice-designs`：创建 VoiceDesign 候选；随后通过
  `confirm`、`validate`、`publish` 子资源完成确认、Base 复验、人工听审和发布；
- `PATCH /v1/voices/{voice_id}`：兼容的无条件 metadata 更新；
- `DELETE /v1/voices/{voice_id}`：删除自定义音色，系统音色和 alias 受保护。

需要把写入绑定到已知不可变版本时，以 namespaced API 为权威：

- `GET /v1/speechrail/voices/{voice_id}/revisions`：读取有界 revision 历史；
- `PATCH /v1/speechrail/voices/{voice_id}`：必须提供 `expected_revision` 的 CAS 更新；
- `POST /v1/speechrail/voices/{voice_id}/rollback`：以 `target_revision` + `expected_revision` 回滚；
- `POST /v1/speechrail/voices/{voice_id}/revisions/{revision}/revoke`：撤销指定 revision 的后续使用。

两套入口共享同一 registry。兼容 PATCH 只适用于明确接受普通协商的旧调用方；App 管理面、
需要跨请求一致性的客户端和自动化工具必须使用 namespaced conditional API，不能把无条件 PATCH
当作 revision-safe 写入。

两种 PATCH 请求都只接受下列字段，且至少提供一个；namespaced 入口另需提供
`expected_revision`：

```json
{
  "name": "新的显示名称",
  "instruction": "新的自然语言音色描述",
  "seed": 2026
}
```

更新规则：

- 系统音色、标准 alias、不存在的音色不可更新；
- 所有自定义音色都可更新 `name`；
- `instruction` 与 `seed` 仅对 `mode=instruction` 的自然语言音色开放；
- `mode=clone` 的 reference audio、`ref_text`、provenance、音频质量和 voice ID 不可修改；
- namespaced 更新使用 CAS、同一 registry 锁和原子 metadata commit；冲突时返回
  `409 voice_revision_conflict`，失败时旧记录保持不变；
- API 返回完整更新后的 `VoiceProfile`，不返回绝对音频路径或 secret。

## App 音色库 UX

- 列表顶部提供“新建音色”，进入既有 VoiceDesign 创作流程；创建成功后返回音色库并刷新服务端列表。
- 每个自定义音色列表行直接提供“编辑”入口；详情 inspector 同时提供“编辑音色”入口。保存前显示字段校验，保存后刷新列表并保留当前选择。
- clone 音色的编辑表单允许改名，并明确标注“参考音频与来源不可编辑”；instruction 音色可编辑名称、描述和 seed。
- 试听、保存、编辑、删除均使用真实 REST 请求；成功后更新本地状态，失败后保留用户输入并展示稳定错误。
- 删除继续使用确认对话框；删除成功后清除选中项和详情，不能只修改 App 内存列表。

## 非目标与安全边界

- 本次不下载、加载、卸载或替换模型，不执行真实模型推理验收，不删除现有用户音色。
- 本次不把 API key 迁移到新存储，也不新增网络服务；只复用既有受管配置语义。
- 不为了“所有交互都手指”破坏文本编辑器的 I-beam 与文字选择语义。

## 完成判定

- 左侧导航和所有操作/选择型控件在 enabled 状态显示 pointing hand，在 disabled 状态不显示。
- 配音和两类试听请求带 Bearer；客户端能解析 2xx 音频并保持现有播放控制。
- OpenAPI、服务端路由、注册表、Swift 协议、AppModel 和音色库对 PATCH 语义一致。
- 静态门检查和 macOS App 构建通过；自动化测试按用户要求保持未执行并在交付中明确标注。
