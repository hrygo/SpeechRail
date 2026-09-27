---
title: "SpeechRail OpenAI 契约兼容、试听语言与显式保存 — Luna 实施方案"
status: in_progress
created: 2026-09-27
repository: hrygo/SpeechRail
branch: codex/app-service-integration
pull_request: 99
reviewed_ref: 3763eb01e486cc191921ec5184d466c793df69a4
source_plan: docs/implementation/SpeechRail_OpenAI_Compatibility_Implementation_Plan_2026-09-27.md
runtime_validation: not_run
---

# SpeechRail OpenAI 契约兼容、试听语言与显式保存 — Luna 实施方案

## 0. 证据边界与工作区基线

本方案在 `codex/app-service-integration` 分支、`3763eb01`（与 `origin/` 一致，ahead/behind 均为 0）上核实代码后写成，PR #99 为 OPEN。

## 0.1 实施期间观察到的并行改动（已核实，保留不动）

核实时间 2026-09-27。本方案执行期间，工作区出现了本会话之外的提交：

- `89f54185 fix(app): resolve preview text per voice language on every surface`（作者 黄飞虹，提交时间 2026-09-27 09:07:05 +0800），已推送到 `origin/codex/app-service-integration`。
- 内容与本会话开始时记录到的未提交改动一致，并额外新增了 `AppModelTests.swift` 覆盖。
- 该提交只触及 `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`、`CreatorSurfaceViews.swift`、`SpeechRailMacControlTests/AppModelTests.swift`，与本方案增量的服务端文件**无重叠**。

处置：保留，不回退、不改写。增量 4 在该提交之上继续。后续若再次出现同类并行提交，同样先只读核实来源与范围再写入。

本方案是**设计与实施指引**。实施进度见 §0.2。

## 0.2 实施进度（截至 2026-09-27）

分支 `codex/app-service-integration`，PR #99。已完成并推送的增量：

| 增量 | 提交 | 状态 |
|---|---|---|
| 方案文档 | `e7c2227b` | done |
| 1 — 服务端音色试听元数据 | `47d19cb4` | done |
| 2 — TTS HTTP 请求边界 | `bc7e8a68` | done |
| 3 — Swift 协议层对齐 | `22c09a65` | done |
| 4a — App 消费服务端 preview | `7b5552e6` | done |
| 4b — 版本化缓存 / 迟到回包隔离（§5 步骤 4.3、4.4） | `3986fe2b` | done |
| 4c — 显式保存幂等（§5 步骤 4.5、4.6、4.7 的 W 系列） | `8294fd09` | done |

已执行的验证（2026-09-27）：

- `uv run --extra dev ruff check src tests` — 通过。
- `uv run --extra dev pytest tests/ --no-cov` — 全量通过（`--no-cov` 仅用于定向/全量快速回归；仓库的 80% 覆盖率 gate 属于完整 gate，未在本次运行）。
- `swift test --package-path macos/SpeechRailApp` — 275 XCTest + 145 swift-testing，0 失败。
- `scripts/macos_app_build.sh --configuration Debug` — BUILD SUCCEEDED（覆盖 SPM 包外的 `CreatorSurfaceViews.swift` / `App.swift`；Debug 不安装、不改运行态）。
- `uv run python scripts/check_version_consistency.py` — 通过（3.2.1）。

**未执行**（需单独授权）：真机合成与人工听审、官方 SDK smoke、性能/质量基准、UI 自动化、Release 构建与安装、完整覆盖率 gate。

### 破坏性变更提示

增量 2 是破坏性的：向 `POST /v1/audio/speech` 的 body 发送 `language` / `seed` /
`validation_policy` 或任意未知字段，由「200 且静默忽略」变为 `400`。增量 3 已让
macOS 客户端改走 `SpeechRail-*` 请求头，但 **App 与 service 必须配套发布**，
只升级其中一侧会导致试听/正式制作被拒绝。

---

# 1. 问题结论

本轮收敛四类真实缺陷，它们共享同一个根因：**SpeechRail 的扩展参数与业务元数据被塞进了 OpenAI 标准 DTO 和 App 硬编码里，导致契约边界模糊、试听内容不可控、生成与保存语义混淆。**

1. **契约污染**：`POST /v1/audio/speech` 的 `_SpeechHTTPBody` 混入了三个非标准字段（`language`、`seed`、`validation_policy`），且**没有** `extra="forbid"`。结果是旧客户端传 `language` 会静默“成功但不生效”，而真正需要语言控制的调用方无法通过标准 SDK 表达意图。官方 `/v1/audio/speech` 没有 `language` 参数（证据 O1），SpeechRail 需要它就必须走专有通道，而不是改标准 body。
2. **试听语言靠 App 硬编码**：`AppModel` 用与 `_LANGUAGE_ALIASES` 对齐的本地映射，从音色 ID 反推试听文案语言。服务端的 `VoiceProfile` 才是音色事实源，却不携带任何试听元数据。音色目录、capability snapshot、App 三处各自解释“这个音色默认该读什么”，必然漂移。
3. **缓存身份不完整**：App 试听缓存键是 `voice.id + speed + previewText`，且**命中发生在取得 `speechRequestOptions` 之前**。音色 revision、模型 catalog revision、能力 epoch 全部不在键内，一次撤销或换版后旧音频仍会命中并播放。
4. **生成与保存同名**：`startSynthesisAndSave` / `synthesizeAndSave` 名字承诺入库，基线提交 `3763eb01` 已改为显式保存语义。`89f54185` 尚未把“保存身份”与“UI 当前选项”彻底解耦，仍需按增量 4 完成闭环。

**不解决**（明确排除，避免 scope 膨胀）：ASR 的标准 `language` 参数、Realtime 既有协议、模型替换、全量音色路径迁移到 `/v1/speechrail/*`、OpenAI Custom Voice consent 创建流程、SSE 新能力、全量语言检测、多语言 VoiceDesign。

---

# 2. 当前实现与根因

## 2.1 服务端 TTS HTTP DTO（`src/speechrail/http/routes/audio.py`）

实测 `_SpeechHTTPBody`（约 190–225 行）现状：

```python
class _SpeechHTTPBody(BaseModel):
    """OpenAI-compatible subset for the public sentence TTS endpoint."""
    model: str = Field(min_length=1, max_length=200)
    input: str = Field(min_length=1, max_length=4_096)
    voice: str | _SpeechVoiceID
    response_format: Literal["mp3", "opus", "aac", "flac", "wav", "pcm"] = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    language: str = Field(default="auto", min_length=1, max_length=64)
    instructions: str | None = Field(default=None, max_length=10_000)
    seed: StrictInt | None = Field(default=None, ge=0, le=2**32 - 1)
    validation_policy: Literal["allow_unverified", "require_output_pass"] = "allow_unverified"
    stream_format: str | None = Field(default=None, max_length=16)
```

直接技术原因：

- **没有 `model_config = ConfigDict(extra="forbid")`**。同文件的 `_SpeechVoiceID` 和 `_VoicePreviewHTTPBody` 都有，唯独对外的 `_SpeechHTTPBody` 没有。Pydantic v2 默认 `extra="ignore"`，未知字段被丢弃。
- `instructions` 上限 `10_000`，官方文档为 `4096`（O1）。
- `speech()` 路由（1556 行起）已经用 `Header(alias="SpeechRail-*")` 承载 7 个专有头（`Expected-Voice-Revision`、`Expected-Model-Revision`、`Pronunciation-Set`、`Receipt-Mode`、`Purpose`、`Latency-Budget-Ms`、`Timing-Mode`）。**专有头机制已存在且成熟**，本轮只需沿用，不另造 `X-SpeechRail-*`。

深层设计原因：语言/策略属于“调用意图”，与“合成参数”是不同层。放在同一个 Pydantic model 里，标准 SDK 用户和 SpeechRail 专有调用方被迫共享一个形状。

## 2.2 音色元数据（`src/speechrail/domain/tts.py`）

`VoiceProfile`（47–117 行）字段：`id / instruction / is_default / name / seed / temperature / is_system / created_at / mode / ref_text / audio_path / duration_seconds / quality / creation / revision / revoked`。

**没有任何预览/试听相关字段。** `SYSTEM_VOICE_PROFILES`（130–206 行）定义 9 个系统音色：

| ID | name | 当前 instruction 摘要 |
|---|---|---|
| `serena` | 温柔中文女声 | 中文，默认音色 |
| `vivian` | 明亮中文女声 | 中文 |
| `uncle_fu` | 醇厚中文男声 | 中文 |
| `dylan` | 北京青年男声 | 中文，带北京口音 |
| `eric` | 成都活力男声 | 中文，带四川口音 |
| `ryan` | 动感英语男声 | 英语 |
| `aiden` | 阳光美式男声 | 英语 |
| `ono_anna` | 轻快日语女声 | 日语 |
| `sohee` | 温暖韩语女声 | 韩语 |

`to_dict()`（91–117 行）**同时是持久化形状**：`VoiceRegistry._profile_from_record`（839 行）逐字段显式读取并做类型校验，未知键被忽略。因此新增展示字段必须做到“写出去能被读回来，读不回来也不破坏旧数据”。

已存在的**近似但不等价**的元数据：`src/speechrail/application/capability_snapshot.py` 的 `_SYSTEM_LOCALES`（29–39 行），值为 `zh-CN / en-US / ja-JP / ko-KR`，被 `safe_voice_descriptor()` 用于 `locales: [locale]` 声明。**这是“声明的说话人地区”，与“默认示例文本的语言”是两个概念**：前者是区域标签（`en-US`），后者按源计划只用基础标签（`en`）。不得合并，也不得让一方覆盖另一方。

## 2.3 目录与能力投影

- `src/speechrail/http/routes/system.py` `_voice_entry`（约 313–365 行）构造 detailed 条目；`_safe_voice_entry` 的 `safe_fields` 元组（约 404–420 行）白名单过滤后返回。**新增字段必须同时进 detailed 和 `safe_fields`**，否则列表接口看不到。
- `src/speechrail/application/capability_snapshot.py` `_voice_entry`（271 行起）产出 App 实际消费的有效音色快照。

根因：两处各自组装 dict，没有共享的投影函数，所以“服务端该返回什么”没有单一事实来源。

## 2.4 Swift 客户端

`macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift`：

- `SpeechRequest`（1151–1191 行）含 `language: String?`，并有 `case language` 的 `CodingKeys`。
- `SpeechRailRequestOptions`（1193–1243 行）承载 7 个专有头，`headers` 计算属性逐个写入 `SpeechRail-*`。

`macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`：

- `createSpeech`（210 行）与 `createSpeechRender`（234 行）都硬编码 `language: language ?? "auto"`，并把它塞进**标准 body**。
- `createSpeechRender` 在 250–258 行**手工重建** `SpeechRailRequestOptions`，逐字段复制。这是新增 options 字段最容易漏的地方——漏一个字段，render 路径就静默丢失该扩展。

## 2.5 App 试听（`macos/SpeechRailApp/SpeechRailApp/AppModel.swift`）

提交 `89f54185` 已把 `previewVoice` / `startVoicePreview` 的 `text` 改为 `String? = nil`，并新增：

```swift
public static func resolvedPreviewText(forVoiceID voiceID: String, text: String?) -> String {
    let candidate = text ?? defaultPreviewText(forVoiceID: voiceID)
    return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

`defaultPreviewText(forVoiceID:)` 走 `VoicePreviewLanguage`（`previewLanguage(forVoiceID:)`）枚举，注释明确写着“与服务端 `_LANGUAGE_ALIASES` 对齐；未知/自定义音色默认中文”。

**问题**：这是第三份语言解释（第三份是 `_SYSTEM_LOCALES`）。三份映射表、两处默认值策略，一旦 Qwen speaker 表或服务端别名变化就会漂移。修复方向是让服务端下发 `preview.text`，App 只做“缺失时回退”。

---

# 3. 目标行为

## 3.1 契约层

`POST /v1/audio/speech` 的标准 body **只保留**：`model`、`input`、`voice`、`instructions`、`response_format`、`speed`、`stream_format`。

移出标准 body：

| 移除字段 | 新位置 | 理由 |
|---|---|---|
| `language` | `SpeechRail-Language` 请求头 | 官方 speech 无此参数（O1）；SDK 兼容路径必须能零扩展工作 |
| `validation_policy` | `SpeechRail-Validation-Policy` 请求头 | 调用准入策略，非合成参数 |
| `seed` | 删除（普通 speech 不支持） | 系统/clone 合成当前不支持 seed；不为不支持的能力建无效扩展。`seed` 仍保留在 VoiceDesign 专有流程与内部 domain 层 |

**不误删 ASR**：`/v1/audio/transcriptions` 的 `language` 是官方标准参数（O3），本轮不动。`domain/tts_request.py` 的 `_LANGUAGE_ALIASES` 和内部 `SpeechRequest.language` 语义正确，也不动。

`_SpeechHTTPBody` 增加 `model_config = ConfigDict(extra="forbid")`。对被移除的三个旧字段，返回**稳定**的 400 `unsupported_parameter`，`param` 指向旧字段名并在 message 中给出迁移位置——不做静默 alias。

`instructions` 上限从 `10_000` 收紧到 `4096`，与官方对齐。

## 3.2 语言选择规则

```text
SpeechRail-Language 存在且受支持  →  映射到后端语言参数
否则                                →  auto
```

**禁止**新增“否则取 Voice 推荐试听语言”分支。后端 `auto` 本身受 Qwen 支持（Q1），不需要额外语言检测服务。`SpeechRail-Language` 只表达“这次生成的目标语言选择”，**不表示 speaker 母语，不授权翻译或改写输入文本**。

## 3.3 音色试听元数据

对外投影新增可选字段：

```json
{
  "id": "ryan",
  "name": "动感英语男声",
  "mode": "system",
  "preview": {
    "locale": "en",
    "text": "This is a voice preview. The speech should be clear, natural, and easy to follow."
  }
}
```

约束：

- `preview` 可缺失。**不**新增 `supported_languages`，**不**新增与 `preview.locale` 重复的 `recommended_locale`。
- `preview.locale` 描述默认示例文本的语言，**不表示该音色“只能说这一种语言”**。
- 模板文本与语言共同参与缓存键，所以改模板不需要改声学 `voice_revision`。
- 自定义/clone 音色没有明确来源时 `preview` 为 `null`。**不**根据“名称像英文”、描述首字符、参考文本是否含汉字自动断言语种。

## 3.4 App 试听

两种语义，三种请求形态：

| 场景 | input | 语言头 |
|---|---|---|
| 未修改的服务端示例 | `preview.text` | 能力支持时发送匹配短码，否则不发 |
| 用户手改试听文案 | 用户原文 | 默认不发 |
| 用户显式选择目标语言 | 用户原文 | 校验后发送所选值 |

判断“用户是否改过”靠**显式状态**（`origin = preset | user`），**不靠**比较文本是否等于某个模板。

缓存键必须版本化，且**先查可用性/版本，后查缓存**。

## 3.5 显式保存

```text
Idle → Generating → PendingRender → 用户点击保存 → Saving → SavedWork
                       │
                       ├─ 播放：使用同一份已生成音频
                       ├─ 导出：显式导出，不进作品库
                       └─ 放弃：用户确认后释放
```

生成、播放、切页、能力刷新**都不创建作品记录**。`PendingRender` 在生成结束时冻结 renderID、原稿、voice ID/name/revision、模型身份、语速、格式、时长、音频数据；保存时**不得**读 UI 当前选项重写这份身份。

---

# 4. 推荐解决方案

## 4.1 扩展走请求头，不走 body

**推荐**：新增 `SpeechRail-Language` 与 `SpeechRail-Validation-Policy`，复用现有 `SpeechRail-*` 头机制。

理由：该机制已在生产契约中存在（7 个头），有完整的 `Header(alias=...)` 声明、OpenAPI 参数、错误映射和客户端序列化路径。新增两个头的边际成本远低于新增第二套 JSON options 通道。

备选方案与淘汰理由：

| 备选 | 优点 | 淘汰理由 |
|---|---|---|
| 保留 `language` 在 body | 客户端零改动 | 就是本轮要修的契约污染；官方无此参数，第三方 SDK 不认识 |
| `X-SpeechRail-Language` | 视觉上“更私有” | 仓库已选定 `SpeechRail-*` 前缀（R2/R4），再造第二套前缀制造长期负担 |
| 能力发现后再合成 | 可校验 | 强制每次普通合成前多一次 RTT；普通 OpenAI 兼容请求不应有前置依赖 |

## 4.2 `preview` 由服务端单一投影函数生成

**推荐**：新增 `src/speechrail/domain/voice_preview.py`，持有模板表 + 纯函数 `preview_for_profile(profile)`；`domain/tts.py` 的 `VoiceProfile` 增加 `preview_locale` 字段；`system.py` 与 `capability_snapshot.py` 调用**同一个**函数。

理由：两处投影共用一个函数是“单一事实来源”的最小实现，成本远低于引入新的目录服务或数据库表。

不推荐把模板塞进 `VoiceProfile.to_dict()` 的持久化 body——那是存储形状，派生展示数据写进去会让存储耦合到展示逻辑。新字段以可选形式 round-trip 兼容即可。

## 4.3 契约先行，测试同步

按仓库规则（AGENTS.md「公共行为变更先补充或更新可表达预期的契约/回归测试，再实现」），每个工作包先改契约/测试再改实现。

## 4.4 显式保存不改存储格式

保持既有作品存储格式。不要为了“以后不自动入库”删除历史作品。保存幂等靠稳定 workID，不靠存储格式变更。

---

# 5. 详细实施步骤

按依赖顺序分 4 个可独立验证、可独立推送的增量。**每个增量一个 commit，推送到 PR #99。**

## 增量 1 — 服务端音色试听元数据

**目标**：服务端在音色目录与能力快照中下发 `preview`，App 后续直接消费。本增量不动 HTTP 请求边界，风险最低。

### 步骤 1.1 新增 `src/speechrail/domain/voice_preview.py`

```python
"""Single source for the default voice-preview text shown by API clients."""

from __future__ import annotations

from types import MappingProxyType
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from speechrail.domain.tts import VoiceProfile

# Base language tags only. No region or dialect is implied: the locale
# describes the sample text, never a constraint on what a voice can speak.
PREVIEW_TEMPLATES: Mapping[str, str] = MappingProxyType(
    {
        "zh": "这是一段音色试听。声音清晰自然，每一句表达都恰到好处。",
        "en": (
            "This is a voice preview. The speech should be clear, "
            "natural, and easy to follow."
        ),
        "ja": "これは音声の試聴です。聞き取りやすく、自然な声をお届けします。",
        "ko": "목소리 미리 듣기입니다. 또렷하고 자연스러운 목소리를 들어 보세요.",
    }
)

SUPPORTED_PREVIEW_LOCALES = frozenset(PREVIEW_TEMPLATES)


def preview_text_for_locale(locale: str) -> str | None:
    """Return the maintained sample text for a base language tag."""
    return PREVIEW_TEMPLATES.get(locale.strip().lower()) if locale else None


def preview_for_profile(profile: "VoiceProfile") -> dict[str, Any] | None:
    """Project a voice's default preview, or None when the source is unknown."""
    locale = (profile.preview_locale or "").strip().lower()
    text = PREVIEW_TEMPLATES.get(locale)
    if text is None:
        return None
    return {"locale": locale, "text": text}
```

**硬性要求**：`preview` 不得包含 `supported_languages` 或任何形式的“该音色只支持此语言”的约束字段。

### 步骤 1.2 `VoiceProfile` 增加 `preview_locale`

- 在 `dataclass(frozen=True, slots=True)` 字段列表**末尾**加 `preview_locale: str | None = None`（放末尾，避免破坏任何位置参数调用）。
- `SYSTEM_VOICE_PROFILES` 按下表填写：

  | Voice ID | `preview_locale` |
  |---|---|
  | `serena` / `vivian` / `uncle_fu` | `zh` |
  | `dylan` / `eric` | `zh` |
  | `ryan` / `aiden` | `en` |
  | `ono_anna` | `ja` |
  | `sohee` | `ko` |

  `dylan` / `eric` 虽是方言/口音音色，示例文本仍用 `zh` 基础中文。**不得**把它们标为 `en`。

- `to_dict()`：仅当 `preview_locale is not None` 时写入 `"preview_locale": self.preview_locale`。
- `_profile_from_record()`（839 行）：读 `preview_locale`，缺失时为 `None`；非字符串或不在 `SUPPORTED_PREVIEW_LOCALES` 内时**忽略并置 `None`**（不要为显示元数据抛错打断音色加载）。
- `__all__` 不需要导出本字段（它是 dataclass 字段不是新符号），但 `voice_preview` 模块的新符号要能被导入。

**边界条件**：旧 JSON 记录没有该键 → `None` → 不下发 `preview`。新记录写入再读回 → 值一致。ID / reference / revision / 音频路径一律不变。

### 步骤 1.3 `system.py` 目录投影

- `_voice_entry` 的 `entry` 字典中，在 `"mode": profile.mode` 之后加：

  ```python
  preview = preview_for_profile(profile)
  if preview is not None:
      entry["preview"] = preview
  ```

- `_safe_voice_entry` 的 `safe_fields` 元组中加入 `"preview"`（放在 `"mode"` 之后）。**漏这一处列表接口就看不到该字段。**

### 步骤 1.4 `capability_snapshot.py` 有效快照投影

- `_voice_entry` 返回的 `entry` 中同样加 `preview`（与 1.3 完全一致的调用）。
  **App 实际消费的是能力快照，只改 `/v1/voices` 是不够的。**
- **不要**改 `safe_voice_descriptor()` 和 `_SYSTEM_LOCALES`。两套 locale 语义不同（区域 vs 示例语言），合并会污染既有 `locales` 声明。

### 步骤 1.5 契约

`contracts/openapi.yaml` 为音色条目 schema 增加：

```yaml
preview:
  type: [object, 'null']
  additionalProperties: false
  required: [locale, text]
  properties:
    locale:
      type: string
      enum: [zh, en, ja, ko]
      description: >-
        Language of the default sample text. It does not constrain which
        languages the voice can speak.
    text:
      type: string
      minLength: 1
```

### 步骤 1.6 测试

- `tests/test_capability_snapshot.py`：新增用例，断言 9 个系统音色的 `preview.locale` 分别为预期值；断言 `preview.text` 非空且与 `preview.locale` 的语种一致（用少量特征字符判定，不引入语言检测库）。
- 音色目录路由用例：断言 `/v1/voices` 列表条目含 `preview`，且与 capability snapshot 中同一 voice 的 `preview` **完全相等**（对应验收 M02）。
- 兼容性用例：一条没有 `preview_locale` 的旧格式自定义音色记录可以被 `_profile_from_record` 读取，且不产生 `preview` 键、不抛异常。

### 完成条件

```bash
uv run --extra dev ruff check src tests
uv run --extra dev pytest tests/test_capability_snapshot.py <本增量触及的目录路由测试文件>
```

---

## 增量 2 — TTS HTTP 请求边界

**目标**：标准 body 收敛到 OpenAI 子集，语言与策略迁移到专有头，旧字段给出稳定迁移错误。

### 步骤 2.1 契约先行

`contracts/openapi.yaml`：

1. `SpeechRequest` schema（3779 行起）：
   - **删除** `language`、`seed`、`validation_policy` 三个属性。
   - 加 `additionalProperties: false`（当前缺失，必须补——这是“旧字段不会被静默接受”的契约表达）。
   - `instructions.maxLength` 从 `10000` 改为 `4096`。
2. `/v1/audio/speech` 的 `parameters` 列表（约 1100–1160 行）新增两个头：

   ```yaml
   - in: header
     name: SpeechRail-Language
     required: false
     schema:
       type: string
       minLength: 1
       maxLength: 64
     description: |
       Optional target language for this generation, as an ISO-ish short code
       (for example `en`, `zh`, `ja`, `ko`) or `auto`. Omission means `auto`.
       It selects the output language only: it does not translate or rewrite
       `input`, and it does not assert the speaker's native language.
   - in: header
     name: SpeechRail-Validation-Policy
     required: false
     schema:
       type: string
       enum: [allow_unverified, require_output_pass]
     description: |
       Optional SpeechRail admission policy for the requested voice. Moved
       out of the OpenAI request body.
   ```

3. 写一段兼容矩阵说明（放 `description` 或 `docs/developers/` 既有契约说明中），明确列出：支持的 `response_format`、`speed` 范围、`stream_format` 仅接受 `audio`、`instructions` 仅 clone 支持、clone 非 1.0 speed 的行为。**不得**在未跑过事件契约测试前声明 SSE 支持。

### 步骤 2.2 `_SpeechHTTPBody` 改造

```python
_REMOVED_SPEECH_FIELDS = {
    "language": "SpeechRail-Language",
    "seed": None,  # 普通 speech 不支持确定性 seed
    "validation_policy": "SpeechRail-Validation-Policy",
}


class _SpeechHTTPBody(BaseModel):
    """OpenAI-compatible subset for the public sentence TTS endpoint."""

    model_config = ConfigDict(extra="forbid")

    model: str = Field(min_length=1, max_length=200)
    input: str = Field(min_length=1, max_length=4_096)
    voice: str | _SpeechVoiceID
    response_format: Literal["mp3", "opus", "aac", "flac", "wav", "pcm"] = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    instructions: str | None = Field(default=None, max_length=4_096)
    stream_format: str | None = Field(default=None, max_length=16)

    @model_validator(mode="before")
    @classmethod
    def reject_removed_extensions(cls, value: object) -> object:
        """Refuse silently-ignored legacy extension fields with migration guidance."""
        if not isinstance(value, dict):
            return value
        for field, replacement in _REMOVED_SPEECH_FIELDS.items():
            if field not in value:
                continue
            hint = f" Use the {replacement} header instead." if replacement else ""
            raise ValueError(
                f"{field} is no longer accepted in the OpenAI-compatible TTS body.{hint}"
            )
        return value
```

同时**删除** `normalize_language` 字段校验器（`language` 字段已移除）。

> **注意**：`model_validator(mode="before")` 抛 `ValueError` 后，FastAPI 会返回 422。契约要求 TTS 路由的 schema/参数错误统一为 **400 + 现有错误 envelope**。因此还需要在该路由（或其异常处理器）把 422 映射为 400。**只改 TTS 路由，不改 ASR 等其他路由的状态码**——见步骤 2.5。

### 步骤 2.3 路由签名与内部取值

`speech()` 签名新增：

```python
        language: str | None = Header(default=None, alias="SpeechRail-Language"),
        validation_policy: Literal["allow_unverified", "require_output_pass"] | None = Header(
            default=None,
            alias="SpeechRail-Validation-Policy",
        ),
```

函数体开头归一化：

```python
        effective_language = language.strip() if language and language.strip() else "auto"
        effective_validation_policy = validation_policy or "allow_unverified"
```

把后续所有 `body.language` 替换为 `effective_language`，`body.validation_policy` 替换为 `effective_validation_policy`（当前出现在 1731 行的 `validate_tts_parameters(...)` 与 1958 行的 `SpeechRequest(...)` 构造）。

**不要**改内部 `SpeechRequest.language` / `validation_policy`——那是正确的 domain 层语义。

**不要**加“否则取音色推荐试听语言”的分支。

### 步骤 2.4 全量调用方迁移

删除所有向 `/v1/audio/speech` 发送 `language` / `seed` / `validation_policy` body 字段的调用方。用 `rg` 确认，至少覆盖：

```bash
rg -n '"language"|validation_policy' --glob '!docs/archive/**' --glob '!*.build*' \
   src/ tests/ scripts/ contracts/ macos/
```

逐一判断每个命中是 **speech 路由调用方**（必须迁移）还是 **ASR / VoiceDesign / 内部 domain**（**不得**改动）。`_VoicePreviewHTTPBody`（`/v1/voices/previews`）保留 `language` 与 `seed`——那是 SpeechRail 专有路由，契约不同。

### 步骤 2.5 错误映射

确认 TTS 路由的请求校验错误落到 400 + 公共 envelope。仓库已有 `error_response(status, request_id, code, message, param=...)`。为被移除字段提供：

- `code`: `unsupported_parameter`
- `param`: 旧字段名（`language` / `seed` / `validation_policy`）
- `message`: 含迁移位置（`SpeechRail-Language` 头等）

保持 `409 model_revision_conflict` / `voice_revision_conflict` 不变；排队与后端不可用继续沿用现有 503 契约。

### 步骤 2.6 测试

`tests/test_speech_api.py` 新增：

| 用例 | 断言 |
|---|---|
| 零扩展普通合成 | 不带任何 `SpeechRail-*` 头，body 只含标准字段，返回 200 |
| 旧字段 `language` | 400，`code == "unsupported_parameter"`，`param == "language"`，message 提及 `SpeechRail-Language` |
| 旧字段 `seed` | 400，`param == "seed"` |
| 旧字段 `validation_policy` | 400，`param == "validation_policy"`，message 提及 `SpeechRail-Validation-Policy` |
| 未知 JSON 字段 | 400，不是 200 |
| `SpeechRail-Language: en` | 请求被接受；断言传给 `validate_tts_parameters` 的 language 为映射后值 |
| `SpeechRail-Language: auto` / 缺省 | 等价行为 |
| `SpeechRail-Language: <非法>` | 400 `unsupported_language` |
| `SpeechRail-Validation-Policy: require_output_pass` + clone | 走既有验证状态检查分支 |
| `instructions` 超 4096 | 400 |

`tests/test_openapi_contract.py` 新增：契约中 `SpeechRequest` 无 `language`/`seed`/`validation_policy`，`additionalProperties: false`，两个新头存在。

**ASR 不回归**：`tests/` 中 transcription 相关用例必须保持全绿，不做任何 ASR 改动（对应验收 C07）。

### 完成条件

```bash
uv run --extra dev ruff check src tests
uv run --extra dev pytest tests/test_speech_api.py tests/test_openapi_contract.py
```

---

## 增量 3 — Swift 协议层对齐

**目标**：客户端不再把扩展塞进标准 body，专有头完整透传。

### 步骤 3.1 `ServiceContractTypes.swift`

1. `SpeechRequest`：**删除** `language` 属性、`init` 参数、`CodingKeys` 中的 `case language`。
2. `SpeechRailRequestOptions` 新增两个可选字段并接入 `headers`：

   ```swift
   public let languageOverride: String?
   public let validationPolicy: String?
   ```

   `init` 参数**追加在末尾**并给默认值 `nil`（不破坏现有调用点的位置参数）。

   `headers` 中：

   ```swift
   if let languageOverride {
       result["SpeechRail-Language"] = languageOverride
   }
   if let validationPolicy {
       result["SpeechRail-Validation-Policy"] = validationPolicy
   }
   ```

### 步骤 3.2 `ServiceAPIClient.swift`

1. `createSpeech`：删除 `language: String? = nil` 参数与 `language: language ?? "auto"` 赋值。语言改由 `options.languageOverride` 承载。
2. `createSpeechRender`：**同样删除** `language` 参数。**关键**：250–258 行手工重建 options 时必须补上 `languageOverride: options.languageOverride` 和 `validationPolicy: options.validationPolicy`。漏掉就是 render 路径静默丢扩展——这是本步最主要的回归点。
3. 检查所有重建 `SpeechRailRequestOptions` 的路径（`rg -n "SpeechRailRequestOptions\\(" macos/`），逐个确认新字段被复制。

### 步骤 3.3 调用方编译修复

`rg -n "createSpeech\\(|createSpeechRender\\(|SpeechRequest\\(" macos/` 找出所有调用点，删除 `language:` 实参。**用编译错误驱动，不做全文替换。**

### 步骤 3.4 测试

`SpeechRailMacControlTests/ServiceContractTests.swift`：

- `SpeechRequest` 编码快照：`model/input/voice/instructions/response_format/speed/stream_format`，**不含** `language`。
- `SpeechRailRequestOptions().headers`：含既有 7 个键；设置 `languageOverride` / `validationPolicy` 后分别出现 `SpeechRail-Language` / `SpeechRail-Validation-Policy`。
- 默认 options 的 headers **不含**这两个新键（零扩展兼容，对应验收 C01）。

### 完成条件

```bash
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
```

---

## 增量 4 — App 试听闭环与显式保存

**目标**：两个试听入口同规则、用户草稿不被覆盖、缓存版本化、迟到回包无副作用、显式保存幂等。

### 步骤 4.1 统一请求构建

拟新增 `macos/SpeechRailApp/SpeechRailApp/VoicePreviewRequestBuilder.swift`：

```swift
enum VoicePreviewTextOrigin: Sendable, Equatable {
    case preset      // 服务端下发的 preview.text
    case user        // 用户改写
}

struct VoicePreviewDraft: Sendable, Equatable {
    var text: String
    var origin: VoicePreviewTextOrigin
    var explicitLanguageOverride: String?
}

struct VoicePreviewRequest: Sendable, Equatable {
    var input: String
    var languageOverride: String?
    var voiceID: String
    var speed: Double
}

enum VoicePreviewRequestBuilder {
    /// preset 草稿可被切换音色时重置；user 草稿必须原样保留。
    static func draft(
        forVoiceID voiceID: String,
        previous: VoicePreviewDraft?,
        serverPreview: (locale: String, text: String)?
    ) -> VoicePreviewDraft

    static func request(
        from draft: VoicePreviewDraft,
        voiceID: String,
        speed: Double
    ) -> VoicePreviewRequest
}
```

语义（对应 3.4 表格）：

| draft | input | `languageOverride` |
|---|---|---|
| `origin == .preset` 且有服务端 preview | `serverPreview.text` | `serverPreview.locale`（能力支持时）否则 `nil` |
| `origin == .user` | 用户原文 | `draft.explicitLanguageOverride` |

**切换音色时**：`previous?.origin == .user` → 保留用户文本（`origin` 仍为 `.user`，**不**继承旧 preset 的语言头）；否则换成新音色的 preset。

**恢复默认文案**是唯一主动把 `origin` 重置为 `.preset` 的入口。

### 步骤 4.2 消费服务端 preview

- `AppModel` 从音色目录 / 能力快照读取 `preview`，存入每个 voice 的展示状态。
- 移除 `defaultPreviewText(forVoiceID:)` 与 `VoicePreviewLanguage` 作为**默认来源**的用法（可保留为服务端 preview 缺失时的界面语言回退，但**不得**写回元数据、不得当成强制生成语言）。
- `resolvedPreviewText(forVoiceID:text:)` 保留（`89f54185`），但其默认分支改为优先取服务端 `preview.text`。
- 两个入口（音色库详情、配音台选音色）**都**走 `VoicePreviewRequestBuilder`。`DubbingDeskView` 已改为 `model.startVoicePreview(voice)`，保持。

### 步骤 4.3 版本化缓存

缓存键从 `voice.id + speed + previewText` 改为结构化身份：

```swift
struct VoicePreviewCacheKey: Hashable, Sendable {
    var canonicalVoiceID: String
    var voiceRevision: String?          // 无 revision 的系统音色用目录/能力 epoch
    var catalogEpoch: String?           // 模型 catalog revision
    var runtimeEpoch: String?           // 已知 runtime revision
    var input: String
    var instructions: String?
    var languageOverride: String?       // nil == auto
    var speed: Double
    var responseFormat: String
    var pronunciationRulesVersion: String?
}
```

规则：

- **先**检查音色当前可用/撤销状态与有效版本，**再**查缓存。当前实现的顺序是反的，必须调整。
- 系统/legacy 音色没有 revision 时使用**明确的目录/能力 epoch** 隔离，**不制造假 revision**。
- **不得**把生成之后才拿到的 `planID` 当作前置缓存键。
- 只缓存：解码通过、非空、完整返回、未取消的结果。版本冲突、未知必要身份、空音频、失败、过期响应**一律不缓存**。
- 设置内存字节上限与淘汰规则。**缓存摘要不写入公开日志。**

### 步骤 4.4 迟到回包隔离

每次试听生成单调递增的 request token。成功、失败、`defer` 清理三处都必须确认 token 仍是当前请求，再写状态/缓存/播放句柄。切换或离开功能时取消旧请求并停止播放；取消后返回的音频既不播放也不更新缓存与状态。

对应验收 U03：A 取消 → B 开始 → A 迟到成功/失败/defer，三种情况都不污染 B。

### 步骤 4.5 三条音频路径不混淆

| voice mode | 路径 |
|---|---|
| `system` | 普通合成（CustomVoice） |
| `clone`（已发布） | 普通合成（Base） |
| `instruction`（candidate） | 独立 VoiceDesign 流程；“播放”读取该 revision 已存的参考/复验音频，**不重新调用生成接口** |

普通试听**不触发作品保存**。

### 步骤 4.6 显式保存幂等

- `PendingRender` 在生成结束时冻结全部身份字段（含 `renderID`、原稿、voice ID/name/revision、模型/plan 身份、语速、格式、时长、音频数据）。保存时**不得**读 UI 当前选项重写它。
- `savePendingDubbing` 使用稳定的 `workID` 作为幂等键。**双击、保存重试、“写入成功但列表刷新失败”三种情况都不得创建第二份作品。**
- 写入顺序：先写临时文件并完成存储提交，再转 `SavedWork`。失败保留 pending 允许重试。
- 生成成功、播放、切换页面、能力刷新都**不**调用 `workStore.save`。
- 离开页面：停止播放、取消未完成推理，但**不因为 SwiftUI 普通 `onDisappear` 就静默丢弃已完成结果**。可在 App 内保留 pending；替换结果或关闭时提供“保存 / 放弃 / 取消”选择。
- 作品重放、导出、保存已完成的 pending 都**不重新加载模型或重新合成**。音色在生成后被删除，不应让已得到的本机音频无法保存。
- 保持既有作品存储格式。**不要**为实现“以后不自动入库”删除历史作品。
- UI 比较/动画用轻量 `renderID`，**不**深比较大块音频 `Data`。

> 重命名建议：`startSynthesisAndSave` / `synthesizeAndSave` → `startSynthesis` / `synthesize`（反映真实行为）。**不保留**名为 AndSave 却不保存的包装层。若改名造成大面积调用点变动，可分独立 commit。

### 步骤 4.7 测试

`SpeechRailMacControlTests/AppModelTests.swift`：

| 用例 | 断言 |
|---|---|
| U01 换音色不覆盖用户文案 | `origin == .user` 时切换音色，文本保持；不继承旧 preset 语言头 |
| U01 恢复默认 | 显式恢复后 `origin == .preset`，文本为新音色 preview |
| U02 缓存命中 | 同请求同版本命中 |
| U02 缓存不误命中 | 文本 / 语言 / voice revision / 模型 epoch / 发音规则 任一变化 → 不命中 |
| U02 顺序 | 音色已撤销时，即使键相同也不返回缓存音频 |
| U03 迟到回包 | A 取消、B 开始后，A 的成功 / 失败 / defer 都不改变 B 的状态、播放句柄与缓存 |
| U04 正式 / 候选 | system 与 clone 不走 Design 流程；candidate 播放不发起生成请求 |
| W01 显式保存 | 生成 / 试听 / 导出不增加库条目；点保存只 +1 |
| W02 保存失败重试 | 注入磁盘失败后 pending 仍在；列表刷新失败与双击不重复写入 |
| W03 保存身份 | 保存字节与试听字节一致；元数据取自 pending 而非当前 UI |
| W04 离开页面 | 不自动保存；已完成结果不被静默丢弃；历史作品不被删除 |

`SpeechRailMacControlTests/CreativeWorkStoreTests.swift`：幂等键行为与既有存储格式 round-trip。

### 完成条件

```bash
swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter CreativeWorkStoreTests
```

---

# 6. 关键实现说明

## 6.1 领域语义统一

| 概念 | 唯一定义处 | 禁止 |
|---|---|---|
| 音色“默认示例语言” | `VoiceProfile.preview_locale` + `domain/voice_preview.py` | App 硬编码 ID→语言映射作为默认来源 |
| 音色“声明地区” | `capability_snapshot._SYSTEM_LOCALES` | 与 `preview_locale` 合并 |
| 短码 → 后端语言名 | `domain/tts_request._LANGUAGE_ALIASES` + `normalize_tts_language` | 在 App 或路由里再写一份 |
| 生成时目标语言 | `SpeechRail-Language` 头 → `SpeechRequest.language` | 由音色推荐试听语言推断 |
| 参考音频语言 / 试听语言 / 输出能力 | 三个独立概念 | 互相推断或合并 |

状态/枚举无重复定义：`allow_unverified` / `require_output_pass` 在 `domain/tts_request.py` 是 `ValidationPolicy`，HTTP 头与内部 domain 共用，**不新建第二份**。

## 6.2 `preview` 投影的调用点必须完整

三个投影点，缺一即产生“目录有、快照没有”或反之的不一致：

1. `system.py::_voice_entry`（detailed）
2. `system.py::_safe_voice_entry` 的 `safe_fields` 白名单
3. `capability_snapshot.py::_voice_entry`

## 6.3 错误码稳定性

新增/变更的错误码都是公共契约，必须稳定且带 `request ID`：

| code | HTTP | param |
|---|---|---|
| `unsupported_parameter` | 400 | 被移除的旧字段名 |
| `unsupported_language` | 400 | `language`（复用 `TtsParameterError` 既有码） |
| `stream_format_unsupported` | 400 | `stream_format`（既有，不改） |
| `instructions_unsupported` | 400 | `instructions`（既有，不改） |

## 6.4 日志与隐私

不得记录 API key、`Authorization`、原始音频、Base64、完整 prompt、完整转写、embedding、实名 speaker 或绝对模型路径。新增的 preview 文本是**公开模板常量**，可以出现在响应与测试中；用户改写的试听文案属于用户文稿，**不写公开日志**。缓存摘要不入公开日志。

---

# 7. 测试方案

## 7.1 确定性测试（默认执行范围）

使用 fake backend/transport。不下载模型、不访问云端、不使用真实音频、不做 UI 接管。

```bash
git diff --check
uv run --extra dev ruff check src tests
uv run --extra dev pytest \
  tests/test_speech_api.py \
  tests/test_openapi_contract.py \
  tests/test_capability_snapshot.py \
  tests/test_voice_design_workflow.py
swift test --package-path macos/SpeechRailApp --filter ServiceContractTests
swift test --package-path macos/SpeechRailApp --filter AppModelTests
swift test --package-path macos/SpeechRailApp --filter CreativeWorkStoreTests
uv run python scripts/check_version_consistency.py
```

**禁止**为让检查通过而清空 addopts、屏蔽覆盖率或删除失败断言。定向测试与完整 gate 分别记录，不混为一谈。

## 7.2 官方 SDK 互操作（需真实服务，需单独授权）

在已安装并锁定版本的官方 SDK 环境中，对真实服务跑无扩展 smoke：

```python
import os
from pathlib import Path
from openai import OpenAI

key = os.environ.get("SPEECHRAIL_API_KEY")
if not key:
    raise RuntimeError("请通过环境变量配置本机 SPEECHRAIL_API_KEY；不要写入脚本。")

output = Path("speechrail-openai-sdk-smoke.wav")
if output.exists():
    raise FileExistsError(f"拒绝覆盖已有文件：{output}")

with OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key=key,
    max_retries=0,
    timeout=120.0,
) as client:
    with client.audio.speech.with_streaming_response.create(
        model="speechrail/qwen3-tts",
        voice="ryan",
        input="This is a voice preview. Every word should be clear and natural.",
        response_format="wav",
    ) as response:
        response.stream_to_file(output)

if output.stat().st_size == 0:
    raise RuntimeError("服务返回了空音频；该测试未通过。")
```

凭据只从环境变量读取，**不写入脚本、仓库、日志或命令参数**。另需一个独立用例加 `extra_headers={"SpeechRail-Language": "en"}` 验证新扩展——但它**不是**普通兼容请求的前置条件。

此脚本只证明一次 SDK/HTTP 互操作与非空输出，**不能**代替音频解码、内容或 App 验收。

## 7.3 真实内容根因核验（需授权）

**HTTP 200、字节数、时长都不能证明输出内容正确。** 此前“英语音色读中文”的结论证据不充分，必须同时排查实际 speaker 绑定、旧缓存、异步回包、输入传递、音频拼接。

固定 commit、模型 revision、speaker、输入文本、格式、语速后跑四组对照：

| 组 | 路径 | 输入 | 语言选择 | 缓存 |
|---|---|---|---|---|
| A | 后端/HTTP 基线 | 原始中文文案 | auto | 关闭 |
| B | 后端/HTTP 基线 | 同一中文文案 | 显式 zh | 关闭 |
| C | 后端/HTTP 基线 | 对应英文文案 | auto 与显式 en 分别测 | 关闭 |
| D | App 两个入口 | 与 A/B/C 一致 | 与 A/B/C 一致 | 首次未命中、再次命中 |

每组校验：音频可解码、非空/非纯静音、请求绑定的 speaker、实际朗读内容、输入与结果对应关系。中文用规范化 CER、英文用规范化 WER 辅助定位；日/韩用有明确分词/归一化规则的对齐或 CER，再人工听审。短句、数字、品牌词、方言**不能**只用同一个 ASR 阈值自动判定。

自检 ASR **不得**把预期全文作为 prompt，否则内容一致性证据被污染。使用有区分度、彼此不同的句子测试串音与旧缓存。**仅**把默认文案改成另一种语言，不能证明原来的内容错误已修复。

原始音频与完整文本保留在本机私有验收目录，不提交仓库、不写公开日志。

## 7.4 不适用项

| 层 | 原因 |
|---|---|
| E2E / UI 自动化 | 需用户逐次明确授权（AGENTS.md 硬性要求）；本方案默认 `not_run` |
| 性能 / 质量 benchmark | 需明确要求；不在本轮 |
| 完整测试套件 | 需明确要求；本轮只跑 7.1 的定向集合 |
| 真实发布与安装 | 需 release skill 授权；见 8.5 |

---

# 8. 验收标准

## 8.1 契约与协议

- [ ] `POST /v1/audio/speech` 不带任何 `SpeechRail-*` 头、body 只含标准字段即可合成
- [ ] body 出现 `language` / `seed` / `validation_policy` / 任意未知字段 → 400 + `unsupported_parameter` 或等价稳定码，`param` 指向该字段
- [ ] `SpeechRail-Language` 缺省 ≡ `auto`；合法值准确映射；非法值 400 `unsupported_language`；不启动额外模型
- [ ] `SpeechRail-Validation-Policy` 缺省 ≡ `allow_unverified`
- [ ] `instructions` 长度上限 4096，与官方一致
- [ ] `stream_format` 仅接受 `audio`，其余 `stream_format_unsupported`（**未跑事件契约测试前不得声明 SSE 支持**）
- [ ] `/v1/audio/transcriptions` 的标准 `language` 不受影响（C07）

## 8.2 音色元数据

- [ ] 9 个系统音色返回预期 `preview.locale`（zh×5 / en×2 / ja / ko）
- [ ] `dylan`、`eric` 为中文示例，不标为英语
- [ ] `/v1/voices` 列表、详情、capability snapshot 三处 `preview` 完全一致（M02）
- [ ] 无 `preview_locale` 的旧音色可正常读取，不产生 `preview` 键、不报错
- [ ] 读取旧数据后 ID / revision / reference / 音频路径 / 既有作品**全部不变**
- [ ] 修改展示属性**不**重新生成 `voice_revision`
- [ ] 未知语种不猜测（不按名称/描述/参考文本推断）

## 8.3 App 试听

- [ ] 两个试听入口规则一致
- [ ] 切换音色不覆盖用户已改文案（U01）
- [ ] 用户改写后不继承 preset 的强制语言头
- [ ] 缓存键含 voice/模型/语言/文本/语速/发音规则版本；任一变化不误命中（U02）
- [ ] 音色撤销后即使键相同也不返回缓存
- [ ] A 取消、B 开始后 A 的迟到成功/失败/defer 均不污染 B（U03）
- [ ] system / clone 不误走 Design 流程；candidate 播放不重新生成（U04）

## 8.4 显式保存

- [ ] 生成 / 播放 / 导出 / 切页 / 能力刷新均**不**增加作品条目
- [ ] 点击保存只增加一条；双击、重试、刷新失败均不重复（W01、W02）
- [ ] 保存字节与试听字节一致；元数据取自 pending 而非当前 UI（W03）
- [ ] 离开页面不自动保存、不静默丢弃已完成结果、不删除历史作品（W04）
- [ ] 重播 / 导出 / 保存 pending 不重新加载模型或重新合成

## 8.5 发布

本轮**不是 App-only 发布**。服务端响应元数据与 HTTP 请求边界同时改动，只换 App 不升级服务会导致新 `preview` 或扩展头无对应实现。按 release skill 做 combined 发布：

```bash
scripts/macos_app_build.sh --configuration Release --archive
CANDIDATE="build/SpeechRail.xcarchive/Products/Applications/SpeechRail.app"
scripts/macos_app_verify_local_xpc.sh "$CANDIDATE"
# 安装后：
scripts/macos_app_verify_single_install.sh "$HOME/Applications/SpeechRail.app"
```

保留本机 ad hoc 签名，**不**通过关闭 `CODE_SIGNING_ALLOWED` 绕过 XPC 身份校验。安装遵循 release skill 的 staging、校验、正常退出、同文件系统替换与回滚步骤，**不**提供省略保护的 `mv`/`rm` 脚本。默认正式路径 `~/Applications/SpeechRail.app`。

**必须记录的证据**：source commit、契约快照/哈希、service wheel 哈希、App version/build/签名身份/制品哈希、确定性测试结果、SDK 版本与 smoke 结果、真实样例编号与审听结论、安装路径、单实例/唯一登记/XPC 检查、回滚制品位置，以及所有 `not_run` 项。**不记录** API key、Authorization、完整用户文稿、参考音频、绝对模型路径。

---

# 9. 风险与注意事项

| 风险 | 影响 | 缓解 |
|---|---|---|
| 破坏性契约变更 | 旧客户端传 `language` 从“静默成功”变成 400 | 这是**有意的**（源计划明确不保留旧字段桥接）。App 与服务**同 PR 同步发布**，发布说明写明迁移位置 |
| 手工重建 options 漏字段 | `createSpeechRender` 静默丢失扩展 | 步骤 3.2 显式标注为该步主要回归点；`rg` 复核所有重建点；补单测 |
| `preview` 只加在一处投影 | 目录有、快照没有（或反之），App 拿不到 | 三个投影点全部列出（6.2）；M02 一致性测试 |
| 误改 ASR 的 `language` | ASR 回归 | 步骤 2.4 逐个命中判断；ASR 相关测试保持全绿 |
| 契约与实现不同步 | 契约声明了实现不支持的能力 | 先改契约再实现；兼容矩阵中不确定项标注 `not_run` 而非猜测 |
| 试听缓存仍误命中 | 播放已撤销音色的旧音频 | 调整“先查可用性后查缓存”的顺序；U02 用例覆盖 |
| 显式保存改造触碰用户数据 | 作品丢失 | 保持存储格式；不删历史作品；幂等键防重复；W02/W04 覆盖 |
| 并行会话的改动被覆盖 | 丢失他人工作 | 增量 4 在 `89f54185` 之上继续；禁止 `git checkout --` 与整文件重写；再次出现并行提交先只读核实 |
| 声称“内容正确”但只有 HTTP 200 | 复现“看起来修好了实际没修” | 7.3 四组对照 + 人工听审；无证据不下结论 |
| 提前扩大范围 | 拖慢交付、回归面扩大 | 增量 1–4 边界清晰；SSE / 全量语言 / 路径迁移明确排除 |

**回退**：App 与 service 各有回退点，但契约不匹配时必须**按匹配的一对版本一起回退**。不得直接用旧备份覆盖升级后新增的用户作品或音色——先保全新增数据。回退代码与协议**不等于**授权回滚用户创作数据。

---

# 10. Luna 执行清单

## 前置

- [ ] 确认分支 `codex/app-service-integration`、PR #99 OPEN、工作区状态
- [ ] 确认并行提交 `89f54185`（`AppModel.swift`、`CreatorSurfaceViews.swift`）仍在，未被覆盖
- [ ] 确认 `reviewed_ref` 未漂移；漂移则先核实差异再继续

## 增量 1 — 服务端试听元数据（已完成 `47d19cb4`）

- [ ] 新增 `src/speechrail/domain/voice_preview.py`（模板表 + `preview_for_profile`）
- [ ] `VoiceProfile` 加 `preview_locale` 字段（末尾，默认 `None`）
- [ ] `SYSTEM_VOICE_PROFILES` 9 个音色填 `preview_locale`（zh×5 / en×2 / ja / ko）
- [ ] `to_dict()` 条件写入 `preview_locale`；`_profile_from_record` 容错读取
- [ ] `system.py::_voice_entry` 加 `preview`；`_safe_voice_entry` 的 `safe_fields` 加 `preview`
- [ ] `capability_snapshot.py::_voice_entry` 加 `preview`（同一函数）
- [ ] `contracts/openapi.yaml` 音色条目加 `preview` schema
- [ ] 测试：9 音色 locale、目录与快照一致、旧记录可读
- [ ] `ruff check` + 定向 `pytest` 通过
- [ ] 提交并推送到 PR #99

## 增量 2 — TTS HTTP 边界（已完成 `bc7e8a68`）

- [ ] 契约先行：`SpeechRequest` 删三字段、加 `additionalProperties: false`、`instructions` 改 4096
- [ ] 契约先行：新增 `SpeechRail-Language`、`SpeechRail-Validation-Policy` 两个头参数
- [ ] `_SpeechHTTPBody` 加 `extra="forbid"` + `model_validator(mode="before")` 拒绝旧字段
- [ ] 删除 `normalize_language` 校验器
- [ ] `speech()` 签名加两个 `Header(...)`；归一化为 `effective_language` / `effective_validation_policy`
- [ ] 替换全部 `body.language` / `body.validation_policy` 引用
- [ ] **不**加“否则取音色推荐语言”分支
- [ ] 错误映射到 400 + 公共 envelope，`param` 指向旧字段；只改 TTS 路由
- [ ] `rg` 全量核查调用方迁移；ASR / VoiceDesign / 内部 domain 保持不动
- [ ] 测试：零扩展合成、三旧字段、未知字段、语言头三态、policy 头、instructions 上限
- [ ] `test_openapi_contract.py` 同步
- [ ] ASR 测试保持全绿
- [ ] `ruff check` + 定向 `pytest` 通过
- [ ] 提交并推送到 PR #99

## 增量 3 — Swift 协议层（已完成 `22c09a65`）

- [ ] `SpeechRequest` 删 `language`（属性 / init / CodingKeys）
- [ ] `SpeechRailRequestOptions` 加 `languageOverride` / `validationPolicy`（参数追加在末尾）+ `headers`
- [ ] `createSpeech` 删 `language` 参数与 `language ?? "auto"`
- [ ] `createSpeechRender` 删 `language`，**并补齐手工重建 options 的两个新字段**
- [ ] `rg` 复核所有 `SpeechRailRequestOptions(` 重建点
- [ ] 编译错误驱动修复所有调用点（不做全文替换）
- [ ] `ServiceContractTests` 覆盖编码快照与 headers
- [ ] `swift test --filter ServiceContractTests` 通过
- [ ] 提交并推送到 PR #99

## 增量 4 — App 试听闭环与显式保存（4a/4b/4c 已完成 `7b5552e6`/`3986fe2b`/`8294fd09`）

- [ ] 新增 `VoicePreviewTextOrigin` / `VoicePreviewDraft` / `VoicePreviewRequest` / `VoicePreviewRequestBuilder`
- [ ] `AppModel` 消费服务端 `preview`；`defaultPreviewText` 降级为缺失时的界面回退
- [ ] 两个试听入口都走 builder；`DubbingDeskView` 保持 `startVoicePreview(voice)`
- [ ] 缓存键改为 `VoicePreviewCacheKey`（含版本维度）
- [ ] 调整顺序：先查可用性/版本，后查缓存
- [ ] 缓存只收成功解码的非空完整结果；设字节上限与淘汰
- [ ] request token 隔离迟到回包（成功 / 失败 / defer 三处）
- [ ] system / clone / candidate 三条音频路径不混淆
- [ ] `PendingRender` 冻结身份；保存走稳定 workID 幂等键
- [ ] 生成 / 播放 / 导出 / 切页 / 能力刷新均不写 `workStore`
- [ ] 离开页面不静默丢弃已完成结果；保持既有存储格式
- [ ] `AppModelTests` 覆盖 U01–U04、W01–W04
- [ ] `CreativeWorkStoreTests` 覆盖幂等与 round-trip
- [ ] `swift test --filter AppModelTests / CreativeWorkStoreTests` 通过
- [ ] 提交并推送到 PR #99

## 交付前

- [ ] `git diff --check` 干净
- [ ] `uv run python scripts/check_version_consistency.py` 通过
- [ ] 记录所有 `not_run` 项（真机试听、SDK smoke、benchmark、UI 自动化、发布安装）
- [ ] 报告中区分“契约声明”“当前实测”“历史记录”“推断”

---

## 证据索引

| 编号 | 来源 | 核实日期 |
|---|---|---|
| O1 | OpenAI Create speech：`https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create` | 2026-09-27 |
| O2 | OpenAI Text to speech guide：`https://developers.openai.com/api/docs/guides/text-to-speech` | 2026-09-27 |
| O3 | OpenAI Create transcription：`https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create` | 2026-09-27 |
| O4 | OpenAI Python SDK README（`extra_headers`、`base_url`）：`https://github.com/openai/openai-python` | 2026-09-27 |
| Q1 | Qwen3-TTS README（speaker 表、跨语言、Auto）：`https://github.com/QwenLM/Qwen3-TTS` | 2026-09-27 |
| R1 | 源方案：`docs/implementation/SpeechRail_OpenAI_Compatibility_Implementation_Plan_2026-09-27.md` | 2026-09-27 |
| R2 | PR #99：`https://github.com/hrygo/SpeechRail/pull/99`，head `3763eb01` | 2026-09-27 |
| R3 | `contracts/openapi.yaml` `SpeechRequest`（3779+）与 speech 路径参数（1100–1160） | 2026-09-27 实测 |
| R4 | `src/speechrail/http/routes/audio.py` `_SpeechHTTPBody`（190–225）、`speech()`（1556+） | 2026-09-27 实测 |
| R5 | `src/speechrail/domain/tts.py` `VoiceProfile`（47–117）、`SYSTEM_VOICE_PROFILES`（130–206）、`_profile_from_record`（839+） | 2026-09-27 实测 |
| R6 | `src/speechrail/application/capability_snapshot.py` `_SYSTEM_LOCALES`（29–39）、`safe_voice_descriptor`（68+）、`_voice_entry`（271+） | 2026-09-27 实测 |
| R7 | `src/speechrail/http/routes/system.py` `_voice_entry`（313–365）、`_safe_voice_entry` `safe_fields`（404–420） | 2026-09-27 实测 |
| R8 | `macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift` `SpeechRequest`（1151–1191）、`SpeechRailRequestOptions`（1193–1243） | 2026-09-27 实测 |
| R9 | `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift` `createSpeech`（210–231）、`createSpeechRender`（234–270） | 2026-09-27 实测 |
| R10 | 仓库根 `AGENTS.md`：只读范围、演进策略、UI 自动化授权、发布约束 | 2026-09-27 |
| R11 | `.agents/skills/speechrail-release/SKILL.md` | 实施时读取 |
