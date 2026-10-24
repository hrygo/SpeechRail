---
title: "音色包：备份、迁移与重新验证"
status: active
audience: "macOS App 用户、音色库集成开发者"
version: "1.0.0"
date: 2026-10-23
---

# 音色包：备份、迁移与重新验证

音色包（`.srvoice`）把一个自定义音色带走所需的**最小事实**打成一个文件：一段可读的
manifest、参考音频、参考文本、声音描述、生成来源与文件摘要。它解决的是「离开这台机器
的音色库之后还能不能还原」，不解决跨引擎等效克隆。

只导出一段试听 WAV 会丢掉参考文本、生成来源和模型依赖；直接复制内部运行目录又会带走
私有路径、过期验证，还可能覆盖现有音色。音色包是这两者之间的那条路。

## 格式

`.srvoice` 是一个 ZIP，`format_version: 1`：

```
manifest.json            # 必需，UTF-8 JSON
audio/reference.wav      # 可选：clone 音色必需，instruction 音色没有
```

`manifest.json`：

```json
{
  "format": "speechrail.voice-bundle",
  "format_version": 1,
  "source": {
    "voice_id": "custom_1788583825_59b3",
    "revision": "sha256:…",
    "exported_at": "2026-10-23T02:00:00Z",
    "service_version": "4.3.0"
  },
  "voice": {
    "name": "旁白男声",
    "mode": "clone",
    "instruction": "",
    "ref_text": "这是一段用来克隆音色的参考文本。",
    "seed": 42,
    "temperature": 0.1,
    "duration_seconds": 3.2,
    "creation": { "origin": "generated", "method": "voice_design_reference_v1", "…": "…" }
  },
  "assets": [
    { "path": "audio/reference.wav", "media_type": "audio/wav", "sha256": "…", "bytes": 153600 }
  ]
}
```

`source.revision` 只是来源记录。真正决定声学身份的是 `voice` 里的参考素材：导入时服务会
按参考文本与参考音频重新计算 revision，所以同一份参考在不同机器上得到同一个身份。

## 包里**不**包含什么

| 不携带 | 原因 |
|---|---|
| 本机验证与质量结论 | 换一台机器、换一个模型版本，结论就不再成立 |
| 绝对路径与存储位置 | 迁移后无意义，且会泄露本机目录结构 |
| 模型权重与运行配置 | 包只描述声音，不搬运引擎 |
| 会话历史与密钥 | 与音色无关的隐私数据 |
| 本机音色 id | 导入会新建 id，旧 id 不与任何作品绑定关系挂钩 |

`GET /v1/voices/{voice_id}/bundle/preview` 会把这份清单直接返回，用户在下载前就能确认。

## 导出

```bash
curl -sS -o "旁白男声.srvoice" \
  http://127.0.0.1:8201/v1/voices/custom_1788583825_59b3/bundle
```

系统预置的九个音色随服务一起发布，没有可迁移的参考资产，导出会返回
`400 bundle_system_voice_not_exportable`。

## 只读预检

导入前先预检：它**不写任何存储、不加载模型**，因此取消导入后音色目录逐字节不变。

```bash
curl -sS -X POST http://127.0.0.1:8201/v1/voices/bundles/inspect \
  -F "bundle=@旁白男声.srvoice"
```

返回里值得先看的四个字段：

- `format` / `format_version`：未知格式或未来版本会明确失败（`415`），不会被当成损坏包。
- `duration_seconds`：按本机克隆规则从容器**重新测量**，不采信 manifest 的声明。
- `missing_capabilities`：当前档位没有声明的能力，例如 `tts_base`（音色克隆）或
  `voice_design`（音色设计）。缺能力仍然可以导入，只是合成前要先准备对应模型。
- `name_conflict`：同名音色已存在，导入时会被改名。

## 导入

```bash
curl -sS -X POST http://127.0.0.1:8201/v1/voices/bundles \
  -F "bundle=@旁白男声.srvoice" \
  -F "name=备份副本"          # 可选，覆盖包里的名称
```

- 总是**新建**本地 id；已有音色、它的 revision 与作品绑定都不受影响。
- 同名时新音色改名为「原名（导入）」「原名（导入 2）」，`renamed_from` 报告原名称。
- 同一个包导入两次会得到两个独立音色，这是刻意的：重复导入不等于覆盖。
- 导入是单次原子目录提交：失败时既不会留下半个音色，也不会留下残留的参考音频。

## 导入之后必须重新验证

响应里的 `validation` 恒为 `unverified`。包内的任何 ready / validation 声明都不会被采信，
也不会绕过本机准入：新音色要按当前 runtime、模型与音色 revision 重新跑一遍验证，才能
用于正式制作。依赖模型尚未准备时，音色会停在「待准备」状态——服务不会静默下载或启用模型。

## 失败与恢复

预检和导入共用同一套稳定错误码：

| 错误码 | HTTP | 含义与处理 |
|---|---|---|
| `bundle_empty` | 400 | 上传为空 |
| `bundle_invalid_zip` | 400 | 不是可读的 ZIP（含截断包） |
| `bundle_missing_manifest` | 400 | 缺 `manifest.json` |
| `bundle_invalid_manifest` | 400 | manifest 字段不合法 |
| `bundle_unsafe_entry` | 400 | 条目是绝对路径、含 `..`、目录或符号链接 |
| `bundle_unexpected_entry` | 400 | 含未在 `assets` 中声明的条目 |
| `bundle_duplicate_entry` | 400 | 条目重名 |
| `bundle_unsupported_format` | 415 | 不是 SpeechRail 音色包 |
| `bundle_unsupported_version` | 415 | 未来 schema，当前构建读不了 |
| `bundle_too_large` | 413 | 归档超过 32MB，或解压后超过上限 |
| `bundle_missing_asset` | 422 | manifest 声明的资产不在包里 |
| `bundle_digest_mismatch` | 422 | 资产字节数与摘要不符 |
| `bundle_invalid_asset` | 422 | 参考音频不符合本机克隆要求（容器、时长、采样率） |
| `bundle_system_voice_not_exportable` | 400 | 系统预置音色不可导出 |
| `bundle_unsupported_voice_mode` | 400 | 该音色模式没有可移植表示（只有设计与克隆音色能打包） |
| `bundle_asset_unavailable` | 503 | 本机参考音频读不出来（文件被移走或权限变化），可重试 |
| `bundle_import_failed` | 400 | 通过格式与资产校验后，写入仍被 registry 拒绝，响应里带原因 |

这些失败都不会改动音色目录。想撤销一次成功的导入，用
`DELETE /v1/voices/{voice_id}`——它与删除普通自定义音色是同一条路径：音色正被合成使用时
返回可重试的 `409 voice_in_use`，不会删掉正在使用的音频。

## 边界

- 首版只认 SpeechRail 自己的音色包。别家的 `.ovsvoice` 或社区包不做转换：ZIP 能解开不等于
  格式兼容，更不等于不同引擎的声音可以互换。
- 分章音频、作品、配音项目不在音色包里；它们各自有自己的导出路径。
- 音色包不携带验证结论，所以「导入成功」永远不等于「可以用于正式制作」。
