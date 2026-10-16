---
title: "会议与字幕识别能力准备和验收"
status: active
version: "0.1.0"
date: 2026-10-16
---

# 会议与字幕识别能力准备和验收

会议窗口优先完整音频复核，字幕窗口优先显示并修订近期文字。两者复用一个 ASR worker；
窗口解码、对齐与原生分人受共享资源准入控制。能力准备、实验验证、生产启用是分开的操作。
以下命令只在操作者已获得相应准备、安装或运行授权后执行。

## 制品与策略

安装支持动态分人的 wheel 后，显式准备锁定的本地制品：

```bash
speechrail model prepare-diarization --backend meeting_dynamic \
  --app-home "$APP_HOME" --yes --json
```

该操作沿用已验证 staging 与原子发布链，保留已存在的制品；只下载、校验，不改 active selection、
私有配置、profile 或服务状态。必要文件的相对路径、大小与 SHA-256 定义于
`service/diarization_assets.py`。请求路径和 preflight 只读取本地字节。
模型 snapshot 与 SDK revision 固定；更新它们须重新校准与验收。

`SPEECHRAIL_DIARIZATION_DYNAMIC_MODEL_DIR` 指向已验证目录，
`SPEECHRAIL_DIARIZATION_DYNAMIC_POLICY_PATH` 指向仓库外的策略文件。
策略包含 `version/prototype_policy/match_distance_max/match_margin_min/update_distance_max/`
`minimum_new_voice_ms/minimum_update_voice_ms/candidate_retention_ms/model_snapshot/calibration_digest`。
距离使用归一化 cosine distance，不能套用其他聚类算法的阈值；本项目不提供未经校准的生产默认值。
唯一支持的原型规则是 `anchor_farthest_v1`。新身份至少 1500 ms、更新至少 2000 ms 独占语音，
两个支持时长上限为 60000 ms，候选保留 60000 ms；重复窗口不重复累计支持。

独立验收成功后，策略还需有效的 `certified_max_speakers`（5–32）与 `validation_digest`。
这些字段代表操作者冻结的验收证据，不能用开发集调参、系统 cap 或单次 smoke 伪造。
未认证时 `max_speakers=null`、生产 not-ready；失败的候选保持关闭。
`SPEECHRAIL_DIARIZATION_DYNAMIC_RESIDENT_BYTES=0` 表示尚无驻留峰值声明，准入按串行处理。

## 独立开关与恢复

服务 `SPEECHRAIL_ASR_REVISION_WINDOWS_ENABLED` 与 `SPEECHRAIL_DIARIZATION_DYNAMIC_ENABLED`
均默认 false。App 的 `speechrail.meetingRevisionWindowEnabled`、
`speechrail.captionRevisionWindowEnabled`、`speechrail.meetingDynamicDiarizationEnabled`
分别控制会议文字、字幕文字和会议多人路径，默认 false，在捕获开始前读取并冻结。
未开启实验时仍使用现有标准转写与既有分人能力；显式多人请求失败后只记录文字，必须向用户说明。

回退先停止当前捕获并完成保存，再关闭对应 App/服务开关；需要替换 runtime 时按
[发布流程](../../.agents/skills/speechrail-release/SKILL.md)恢复上一 release。
SQLite 保持 schema v13，不用旧数据库覆盖新记录；服务和 App 分别保留回退点。

## 诊断

`speechrail_diarization_phase_seconds` 分别记录 wait/load/infer/close；
`speechrail_diarization_failures_total` 使用 load/infer/protocol/close 有限阶段。
`speechrail_diarization_watermark_lag_samples`、`speechrail_diarization_retained_pcm_bytes` 与
`speechrail_diarization_retained_state{kind="identities|prototypes|candidates"}` 只提供匿名资源数据。
原生失败包包含有限 `diagnostic_stage`，不输出原文、路径或向量。
活动 unknown 原因与对齐故障分别记录，不能把身份不确定等同于模型未加载。
精确 child 回收未确认时，服务保持分人占用与引用并拒绝后续准入；须由操作者恢复服务。

本机音频由独立 XPC helper 采集。启动等待上限为 45 秒，设备清理上限为 8 秒；
CoreAudio 同步调用无法取消时，仅退出持有私有 tap 的 helper，由系统回收资源。
不会重启系统音频服务。App 的取消、连接失效、回复和超时只完成一次启动结果；
旧连接失效只清理它持有的采集，不停止后来连接的采集。
有效连接仍持有采集时，其他连接的启动被明确拒绝；原连接须先停止或失效，
避免多个会话因自动重连而互相抢占。
失败 NSError 保留 `com.speechrail.capture` domain、原始 OSStatus 和有限 `stage`；
helper 日志仅记录 `speechrail_capture_failed stage/status` 或
`speechrail_capture_timeout stage`。未成功开始采集的等待时间不计入运行稳定性验收。

本机 ad hoc 构建的代码签名可能与已有系统录音授权记录不再匹配。
“仅系统录音”开关显示开启不能单独证明当前代码已获授权；应核对当前请求的 TCC 结果、
代码匹配失败日志和实际 PCM。需要刷新已有授权时，由用户完成系统验证后在系统设置中操作，
不要重置全部 TCC、写权限数据库或自动扩大到录屏权限。

## 证据工具与启用门

`examples/perf/prepare_meeting_corpus.py` 只处理仓库外、已获授权的公开数据与独立人工标注。
AISHELL-4 使用固定通道、完整语句边界裁剪、显式事件标记过滤；原始标注仍保留在外部目录。
会话内匿名编号不能证明跨会话人的身份；缺全局参与人映射时，人互斥与独立人数门保持 unset。
重叠语音的线性 CER 只作探索比较，不冒充官方多流评分。

`calibrate_meeting_diarization.py` 在一次原生声学推理中比较多组 session 匹配策略，
其 `evidence_mode=native_development`，不能替代安装态公共 API 验收。向量仅留在该原生进程 RAM。
先在开发集选择候选，开发门失败就停止认证，不能反复查看 holdout 调参。
独立 `pyannote.metrics==4.1` 使用整场一次身份匹配；主 DER/JER 为 collar=0、包含 overlap，
另报 collar=0.25、跳过 overlap 的可比结果。unknown、短插话与失败输入保留在分母。

公共 ASR 回放使用 `bench_realtime_json.py --asr-manifest`；manifest 的 `window_request`
显式选择新审计器，其 `schema_version=1, tool=speechrail-asr-window-benchmark`。
掉预览不能删掉封存文字，终态镜像不能重复计数。原文与规范化 CER 分别报告；
空参考报告插入错误、CER=null。manifest 可提供 `human_annotations`，以 fixture ID 为键、
每项 `kind="independent_human_annotation"`。`english_spans` 与 `facts` 的 `start/end`
为原始参考正文的 Unicode codepoint 半开区间，不得重叠或切开词；英文区间不包含中文。
英文按 NFKC/casefold、去标点、空白分词；整场混合 token 编辑对齐后只评分人工英文区间，
区间边界插入保守计错，相邻区间不重复计数。中文上下文以单字对齐，不能作为一个英文 word。
`facts` 必须由人工指定 `category`：`number/amount/date/negation/proper_name`，分别统计
数字、金额、日期、否定词、专名的完全正确与错误数，并保留总计。
`vocabulary_negative_controls` 必须在参考中不存在，按连续规范化 token 匹配并另报假阳性数；
英文匹配整词，中文匹配连续字元，因此 `cat` 不会命中 `concatenate`。
输出只含指标及标注摘要，不复制原文、事实词或负对照词。
无独立事实词、词时间或 App UI 时钟证据的指标保持 not_observed。
公共 API 测量失败另外报告有限 `failure_code/failure_stage`，不输出供应商正文或模型路径。
`compare_asr_windows.py` 对相同音频和参考摘要、profile、会话及重复次数的两份结果生成配对统计：
重复运行先在同一会议内平均，再以整场会议为单位、固定 seed=1717 生成 95% bootstrap 区间；
只有一个独立会议时不生成置信区间。该比较仍不能自行证明语料的人互斥、事实准确率或 UI 延迟达标。
新采样结果记录 `wire_pcm_sha256/reference_text_sha256`；缺这些摘要的历史结果不得自动加入配对计算。

`asr_revision_trace.py` 对仓库外保存的同一有限文本片段的完整显示快照评分；
输入 JSON 包含 `reference/observations/annotation/clock`。每个 observation 必须含
`at_seconds/text/sealed`，时间递增，只有最后一条可以且必须封存。
纯尾部追加不算回溯重写，回溯重写量与文字年龄可以从快照本身观察。
“正确变错误”则必须有独立人工对应关系：
`annotation.kind="independent_human_annotation"`、
`annotation.correspondence_provenance="human_reviewed_trace"`，以及每条快照的
`reference_token_map`（每个规范化显示 token 对应一个递增参考 token 索引；插入为 null）。
工具不会靠重复词的编辑对齐猜测它属于参考的哪一次出现。

词级显示时延还要求 `clock="app_ui_submission"`、
`annotation.timing_provenance="human_reviewed_audio"`，以及覆盖每个规范化参考 token 的
`token_timings`；其 `start/end` 为原文 codepoint 区间，
`audio_start_seconds/audio_end_seconds` 为人工核验的音频时钟。
自动强制对齐时间不能充当人工真值；缺证据的指标保持 not_observed。
该工具不采集或认证 UI 时钟，输出明确保留 `clock_provenance="caller_declared_unverified"`
与 `production_gate="unset"`。原始快照须留在仓库外；结果仅输出汇总，不复制原文。

```bash
python examples/perf/asr_revision_trace.py --trace "$ASR_UI_TRACE" --output "$ASR_TRACE_RESULT"
```

```bash
python examples/perf/compare_asr_windows.py --baseline "$ASR_BASELINE" --candidate "$ASR_CANDIDATE" --output "$ASR_COMPARISON"
```

启用门仍要求自然语料、场景质量与延迟、零边界违规、保存恢复和 30–60 分钟资源实测，
不以 ready、代码测试或模型 smoke 代替质量结论。
