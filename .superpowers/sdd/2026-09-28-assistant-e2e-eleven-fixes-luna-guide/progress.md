# SDD ledger — plan: docs/superpowers/plans/2026-09-28-assistant-e2e-eleven-fixes-luna-guide.md

Baseline: `0f171401`
Branch: `codex/assistant-e2e-fixes`
Worktree: 独立 worktree（分支 `codex/assistant-e2e-fixes`，不写入主工作区）

Pre-flight: the plan is a defect/AC plan rather than a numbered `task-start` brief
format. Tasks below follow its SB0–SB5 service order, then S0–S10 App order.

Shared-interface pre-flight:

- SB0/B01+B03 → SB4/B06: both edit `application/realtime_openai.py` commit and
  reader lifecycle. SB0 first, then SB4; no parallel writers.
- SB2/B04+B07 → SB3/B05: both change TTS terminal/limits ownership. SB2 keeps
  worker transport semantics; SB3 reorders controller/application cleanup.
- App S4/D06+D08 → App S5/D05: both change TTS interruption and playback
  epochs. S4 establishes reply state; S5 adds device invalidation.
- App S4/D06+D08 → S9/D11: both own assistant reply text. S4 stores raw text;
  S9 only decides TTS start/offer boundaries.
- App S1/D01 → S5/D05: coordinator waiters and playback ledger share epoch
  identity; S1 defines it, S5 reuses it.

Ruling: implement the worktree from `0f171401`, excluding the main checkout's
uncommitted parallel work — the user explicitly requested an independent
worktree. Cost if wrong: later upstream integration may need conflict resolution
for the currently modified voice-quality and capability files.

Task SB0: complete (B01+B03 RED→GREEN; tests:
`uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_realtime_admission_commits.py -q`
→ 98 passed; ruff focused → pass)

Ruling: an admission tail produced while `_commit_lock` is already held stays
with the item being finalized instead of recursively committing. The tail is
bounded below one 512-sample frame; deferring it would require inventing a
second commit owner inside the same caller. Cost if wrong: an item can exceed
`max_realtime_buffer_bytes` by less than 1024 bytes on explicit EOF.
Task SB4: complete (B06 RED→GREEN; tests:
`uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_realtime_admission_commits.py -q`
→ 100 passed; focused ruff → pass)
Task SB5: complete (B08 RED→GREEN; tests:
`uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_realtime_admission_commits.py -q`
→ 101 passed; focused ruff → pass)
Task SB2: complete (B04+B07 RED→GREEN; tests:
`uv run --extra dev pytest --no-cov tests/test_tts_stream_state.py tests/test_tts_stream_worker.py tests/test_tts_stream_client.py tests/test_tts_stream_application.py tests/test_qwen3_tts_incremental_bridge.py tests/test_realtime_tts_incremental.py tests/test_tts_incremental_vendor_state.py -q`
→ 113 passed; focused ruff → pass; focused mypy → pass)
Task SB1: complete (B02 RED→GREEN; tests:
`uv run --extra dev pytest --no-cov tests/test_realtime_openai.py tests/test_realtime_admission_commits.py tests/test_realtime_vad_bargein.py -q`
→ 108 passed; focused ruff → pass)
Task SB3: complete (B05 RED→GREEN; tests: the nine service/TTS/Realtime
files listed in §8 → 216 passed; focused ruff → pass)
Task S1: complete (D01 RED→GREEN). Files:
`macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift`,
`macos/SpeechRailMacControlTests/AssistantTTSStreamCoordinatorTests.swift`.
RED on the pre-fix implementation: the four new cases failed and the Swift
runtime printed `SWIFT TASK CONTINUATION MISUSE: wait(for:timeout:) leaked its
continuation` — the single `pendingWait` slot overwrote the ACK waiter with the
playback waiter. GREEN after the fix: 18/18, no MISUSE.
Changes: waiters keyed by `(utteranceEpoch, WaitTarget)` with a per-waiter
UUID so timeouts/cancellation hit exactly one continuation; pre-arrival cache
keyed by the same key and never stores `.playback`; `invalidate()` drains the
whole table before resuming; `releaseWaiters` detaches the table first so a
resumed continuation cannot re-enter the mutation; `begin()` allocates a fresh
physical `utteranceEpoch` (replay of the same logical `generation` no longer
reuses a playback identity); `cancel()`/`reportOutcome` verify the epoch after
every `await` so a late cancel cannot write into the next turn.
Ruling: `generation` stays the logical reply identity reported through
`onOutcome`; the new epoch is internal and is what reaches `enqueuePlayback` /
`notePlaybackCompleted`. Three existing tests encoded the old conflation of the
two and now read the epoch back from the recorder instead of hard-coding it.
Task S0: complete. Files: new
`macos/SpeechRailApp/SpeechRailApp/AssistantSessionDependencies.swift`;
`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`,
`AssistantAudioPlayback.swift`, `SessionCoordinator.swift`, `SessionStore.swift`;
`macos/SpeechRailApp/Package.swift`; new
`macos/SpeechRailMacControlTests/AssistantSessionTests.swift`.
`AssistantSession.swift` (1191 lines) is now compiled into the SwiftPM test
target. Three narrow seams replace the hard-coded constructions:
`AssistantLLM` (production `LLMProvider`), `AssistantRealtimeClient` (production
`RealtimeASRClient`), and `AssistantPlaybackChannel` (production
`PCMStreamPlayer`), plus an injected `now`. Defaults live in
`AssistantSessionDependencies`, so the App composition root is unchanged and
production behaviour is identical. `AssistantAudioSession.swift` and
`AssistantAudioPlayback.swift` were un-excluded so the real audio types compile;
tests inject a fake and never construct `AVAudioEngine`.
Note: `AssistantSessionDependencies` and the playback channel are `public`
because `AssistantSession.init` is public and its default argument cannot
reference internal types.
The harness runs the production path: temp `SessionStore` +
`SessionCoordinator` with an isolated `UserDefaults` suite, the coordinator's
real `starter`/`stopper` wired to `beginCapture`/`stopCapture`, and fakes for
LLM / Realtime / audio / clock. Concurrency is driven by a pausable, cancellable
`Gate` plus `Task.yield()` polling — no sleeps.
Task S2: complete (D02+D03 RED→GREEN). Files as S0 plus `SessionCoordinator.swift`.
D02 RED: `testStoppingWhileConnectingDoesNotReviveTheSession` failed with the
session pulled back to `.listening`, a record created, and the late connection
never closed. Fix: a session-level `startToken` bumped at the top of every start
and at the top of `stopCapture`; device, client and playback are built in a
private scope and published to `self` only after the token validates; every
`await` is followed by `requireLive(token)`. Stale paths close only their own
resources. A superseded start throws `Superseded.start`, which `beginCapture`
swallows without writing a `blocked` conclusion or stealing `phase`.
D03 RED: with `retry()` still calling the old `startPipeline`, the reconnect
test failed 7 assertions — new `sessionID`, `turns` reset to 0, ordinals reset,
2 records in the store instead of 1, and the post-reconnect turn landing in a
different record. Fix: `startPipeline` split into `openVoiceTransport` /
`prepareConversationContext` / `createConversationRecord`, plus a
`reconnectPipeline` that reuses only `openVoiceTransport` and then
`coordinator.resumeAfterInterruption()`. `retry()` is single-flight and bumps
the start token *before* cancelling the previous attempt, so the old attempt is
stale regardless of which one resumes first. Record creation during a cancelled
start is sealed by its own id via the new
`SessionCoordinator.sealSession(id:reason:)` — never deleted, never attached to
a new session.
Ruling: a record that was actually created during a cancelled start is real
user activity, so it is sealed under its own id rather than removed. The test
gate needed an `armed` flag so it can block only the reconnect leg; without it
the fixture's first connect blocked too. Every concurrency assertion is bounded
by `waitUntil` so a regression fails the test instead of hanging the suite.
Also added `SessionStore.sessionCount()` — "same `sessionID`" is not enough to
prove no second row was written; the count is the actual assertion.
GREEN: 7/7 in `AssistantSessionTests`, 331/331 for the whole App test target.
Task S3: done — 见下方「S0 / S2 / S3」小节。
Task S4: done — 见下方「S4」小节。
Task S5: done — 见下方「S5–S7」小节。
Task S6: done — 见下方「S5–S7」小节。
Task S7: done — 见下方「S5–S7」小节。
Task S8: complete (D10 RED→GREEN). Files:
`macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift`,
`macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationPipeline.swift`,
`macos/SpeechRailMacControlTests/LLMProviderTests.swift`.
Pre-fix, the read loop had no success-terminal concept at all: `data: [DONE]`
was `break`, EOF fell out of the loop, and both fell through to
`emitProviderObservation(.providerResponse)` and returned normally.
RED verification: temporarily neutralising the new terminal requirement made
exactly the four "no success terminal ⇒ failure" cases fail, each returning the
partial text as success (`实际拿到 好` / `实际拿到 我不能`). The remaining new
cases (multi-line `data:`, comments/heartbeats, empty `completed`, `response.failed`,
malformed JSON) depend on the new decoder and did not compile against the old
loop. GREEN: 55/55 in `LLMProviderTests`, 318/318 for the whole App test target.
Changes: new `LLMError.streamEndedEarly` and `.malformedStreamEvent`; a
`LLMResponseStreamState` that only accepts `response.completed` as success and
pins `responseID` from the first identified event; and a
`ResponsesEventStreamDecoder` that replaces `URLSession.AsyncBytes.lines`.
Ruling: `AsyncBytes.lines` silently drops empty lines, so SSE event boundaries
were unavailable and a multi-line `data:` event could never be reassembled. The
decoder therefore reads bytes, splits lines itself (CRLF aware), and cuts events
on blank lines. It joins multi-line `data:` first and falls back to per-line
parsing for providers that omit the blank separator; a payload that parses
neither way now fails loudly instead of being skipped. `[DONE]` is still
consumed as a sentinel but no longer implies success.
Shared-surface note: the two new cases are also mapped in
`TeleprompterAIObservability.errorCode(for:)` and in the preparation pipeline's
retry classification, where they are grouped with `.transport` because they are
transport-level stream failures.
Task S9: partial (D11 decision logic complete and wired; the `AssistantSession`
wiring itself is not covered by a test because `AssistantSession.swift` is still
outside every test target — that is S0). Files:
`macos/SpeechRailApp/SpeechRailApp/AssistantSpeechTextBuffer.swift` (new
`AssistantSpeechStartGate`), `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`,
`macos/SpeechRailMacControlTests/AssistantSpeechTextBufferTests.swift`.
Pre-fix, `runReply` did
`guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }`
before `stream.offer(delta)`, so every whitespace-only delta was dropped on the
floor: LLM deltas `"Hello"`, `" "`, `"world"` reached the utterance as
`"Helloworld"`. The plan's test list for D11 requires asserting the pre-clean
concatenation, which is only expressible against a seam, so the policy was
extracted rather than tested through `AssistantSession`.
Changes: `AssistantSpeechStartGate` buffers raw pre-start text under the round
total limit, starts only once the accumulated text contains a non-whitespace
scalar, hands the whole buffer over on the successful start, then echoes every
subsequent delta verbatim (spaces and newlines included) — display, history,
SQLite and the TTS text all keep the raw text and `VoicePrompt.spokenText` is
still the only cleaning layer. `disableStarting()` backs the failed start out
so one failure does not retry `start` in a loop. `runReply` now switches on
`speechGate.offer(delta)`; `streamStarted` moved to mean "begin succeeded".
GREEN: 6 new cases plus the whole App target, 324/324.
Task S10: done — 见下方「S10 — 文档同步」小节。
Final review: 见下方「最终验证」与「AC 审计」小节。

## S0 / S2 / S3 — 真实编排层测试入口、启动与重连、界面投影（2026-09-28）

Task S0: done. `AssistantSessionDependencies.swift` adds the `AssistantLLM`,
`AssistantRealtimeClient` and `AssistantPlaybackChannel` protocols plus
`AssistantSessionDependencies` whose defaults are the production
implementations, and carries an injectable clock. `AssistantSession.swift`
consumes those seams; `PCMStreamPlayer` had to become `public` because
`AssistantSession.init` is `public` and a default argument may not name an
internal type. `Package.swift` un-excludes `AssistantAudioSession.swift` /
`AssistantAudioPlayback.swift` and adds `AssistantSession.swift`,
`AssistantSessionDependencies.swift` and `SessionPreferences.swift`.
`AssistantSessionTests.swift` drives the production class with fake LLM /
Realtime / audio, a pausable-and-cancellable `Gate`, a temp-dir `SessionStore`,
an isolated `UserDefaults` suite and the real coordinator starter/stopper.

Task S2: done. `startPipeline` split into `openVoiceTransport` /
`prepareConversationContext` / `createConversationRecord`, plus
`reconnectPipeline` which swaps device and connection only — it does not
rebuild the record, reset history, turns, ordinal, start time, persona,
memories or voice changes. A session-scoped `startToken` plus
`requireLive(token)` gates every `await`; devices, clients and players are
created in a private scope and only published after the check, so a stale start
can no longer revive capture or publish into a coordinator that has moved on.
`stopCapture` invalidates the token before awaiting. `retry()` is single-flight
and bumps the token before cancelling. `SessionCoordinator` gained
`sealSession(id:reason:)` and `SessionStore.sessionCount()`.
RED evidence: on the pre-fix code the stop case was pulled back to
`.listening`, created a record and left the connection open; the reconnect case
failed 7 assertions (new sessionID, turns cleared, ordinals renumbered, two
records in the store).

Task S3: done. `toggleMute()` no longer touches `phase`. Added
`hasActiveConversation` / `canEndConversation` / `canRetryVoice` /
`statusTitle` / `isActivelyRunning`; `AssistantView` now uses
`hasActiveConversation` for `isLive` and `isActivelyRunning` for
`blockedReason`. The `handleUnexpectedClose` guard is
`!isStoppingIntentionally, client != nil` instead of `phase.isLive`.
`prepareConversationContext` resets `isMuted = false` so a new conversation is
audible again while a reconnect keeps the user’s choice.

### Xcode target registration (the S0/S3 build gate)

`project.pbxproj` uses explicit references — `objectVersion = 56` and zero
`PBXFileSystemSynchronizedRootGroup` entries — so the “just put the file in
the directory” branch of `xcode-project-setup` does not apply. Registered per
plan §6.8: `AssistantSessionDependencies.swift` as fileRef
`A400000000000000000000E3` with App Sources buildFile `…104` and Test Sources
buildFile `…105`; `AssistantSessionTests.swift` as fileRef
`A400000000000000000000E4` with buildFile `…106`. The Unit Test Sources phase
also compiles production sources, and `AssistantSession.swift`,
`SessionPreferences.swift`, `AssistantAudioSession.swift` and
`AssistantAudioPlayback.swift` were in the App phase only, so each got a Test
Sources buildFile (`…107`–`…10A`). `plutil -lint` OK; `git diff` is 13 added
lines against 4 rewritten single-line `children` / `files` entries, no other
existing line touched.

## Verification snapshot (2026-09-28, after S3)

- `swift test --package-path macos/SpeechRailApp` → 334 passed, 0 failed.
- `bash scripts/macos_app_build.sh --configuration Debug --timeout 1500` →
  `** BUILD SUCCEEDED **`, exit 0.
- `bash scripts/macos_app_build.sh --configuration Debug --test-unit
  --timeout 1500` → `** TEST SUCCEEDED **`, `Executed 297 tests, with 0
  failures`; all ten `AssistantSessionTests` cases appear as
  `Test Case '-[SpeechRailAppTests.AssistantSessionTests …]' passed`, so the
  Xcode membership change is proven by execution, not by the exit code.
- `uv run --extra dev pytest --no-cov` over the ten service/TTS/Realtime files
  in §8 → 231 passed.
- `git diff --check` → clean.
- Not run: UI automation, real workers/models, real service smoke.

## Remaining work

Closed: B01–B08, D01–D04, D06, D08, D10, D11, S0–S4, plus Xcode target registration and
the App Debug build.
Open: S5 (D05), S6 (D07), S7 (D09), S10 (docs), §7.2 cross-layer fixtures.

## S4 — 回复身份、落库与幂等终结（D06、D08）

### S4a 持久化层

`SessionStore.finalizeAssistantLine(sessionID:lineID:text:interrupted:)`：按
`id + session_id + role='assistant'` 三重校验更新，只动 `text` / `status` /
`interrupted` 三列；`interrupted` 用 `CASE WHEN interrupted = 1 THEN 1 ELSE ? END`
保证**只能从 false 推向 true**——迟到的"正常完成"可以补全正文，擦不掉打断标记。
`starred` / `created_at` / `ordinal` / `source` / `t_start` 一律不碰。0 行受影响抛
`statementFailed`，不静默当成功。`sealAbandonedSessions` 改为一个事务：封存会话的
同时把该记录里 `role='assistant' AND status='partial'` 的行收成 final + interrupted，
保留已写下的正文；用户行与会议/字幕的说话人 partial 不受影响。
RED：`testSealAbandonedSessionsFinalizesOnlyAssistantPartials` 两条断言失败
（`partial != final`、`interrupted` 为 false）。GREEN：8/8。

### S4b 统一回复收尾

新增 `AssistantReplyState.swift`：一轮回复 = 一个身份，`id` 同时是 `line.id` 和
`Turn.id`。第一段非空正文就按这个 id 建 `partial` 行，之后只 UPDATE。
`finalizeReply(_:reply:)` 是唯一收尾入口，按 `isFinalized` 幂等，接收**值类型快照**
——跨过 await 之后新的一轮接管了也不会写错会话。正常说完 / 用户打断（ESC、
barge-in）/ provider 失败 / 连接断开 / 结束对话全部经它收尾。空回复不留下伪造正文行；
落库失败写 `lastFailure`，不显示"已保存"。`stopSpeaking` 区分两种情况：还在生成 ->
统一收尾；正文已定稿只是朗读没放完 -> `markLastReplyInterruptedAfterPlaybackCut()`
给**同一行**补打断标记。D06 的 provider 失败路径现在会先停本地播放、再取消服务端
这一轮、再落库归位。

### S4c 远端空闲屏障

`AssistantTTSStreamCoordinator.cancel()` 现在返回"服务端是否已确认这一轮终止"，
等的是**匹配 requestID 的终态**，不是"取消命令发出去"。闩挂在 `handleTerminal`
（Realtime 接收层）上解锁，不在业务收尾这一侧——两者同一条任务就是自己等自己。
终态早于等待到达时记进 `terminalSignals`，不让它白等一个完整超时。
`begin()` 在屏障未解除时抛 `RemoteOwnershipUnknown`。`AssistantSession` 侧：确认了
就回聆听态；没确认则 `handleUnconfirmedRemoteIdle()` 关连接、释放设备、记一次
可重试的语音中断——不靠 sleep 或自动重发正文盖住竞态。

顺带修掉一处真实缺陷：`AssistantSession.handle` 原先按 `ttsStream.isActive` 过滤
`.ttsEnded`，而被打断的那一轮已经被 `invalidate()` 作废、`isActive` 为 false，
于是空闲屏障永远等不到解除的终态。现在终态**无条件**转交协调器，活动/已作废的
区分由 `handleTerminal` 自己判断。

### S4 证据

- 新增 `AssistantPersistenceTests.swift`（8 例）与 `AssistantSessionTests`（7 例）。
- 变异验证：把 `finalizeReply` 的打断标记退回"永远按正常完成落库"，5 个新用例中
  4 个失败（6 处断言）——测试确实抓得住 D06/D08；第 5 个走的是独立的
  "朗读中途停止"路径，不在该变异范围内。
- 修掉两处**测试自身**的竞态（不是产品缺陷）：`waitUntil` 只用 `Task.yield()` 时
  600 次在微秒级跑完，条件还没成立就判失败，改为 1ms x 600 的有界等待；假 Realtime
  客户端原先不回 `ttsStarted` / `ttsTextAccepted`，`finishInput()` 会永远等 ACK，
  改为像真服务一样回 started 与累计 ACK。
- `swift test --package-path macos/SpeechRailApp` -> 349 passed, 0 failed。

## S5–S7 — 设备重建通知、文字降级、时间语义（2026-09-28）

Task S5: done (D05). `AssistantAudioSession` 新增 `onPlaybackInvalidated` 协议成员与
`AssistantAudioInvalidation(deviceGeneration:recovered:message:)`。引擎因
`AVAudioEngineConfigurationChangeNotification` 重建时，`pendingBuffers` 归零并回调上层：
`recovered == true` 表示设备恢复了但这一轮缓冲已经丢，所以照样通知；`false` 则同时
走 `onFailure`。**恢复成功也必须通知**——重建成功不等于这一轮会在新引擎上继续播。
`AssistantSession` 收到后作废播放账本、作废 TTS 这一代，按打断收尾当前回复；失败则走
`handleUnconfirmedRemoteIdle`，关连接、释放设备、记一次可重试的语音中断。回调带
`startToken` 校验，结束或重连之后到达的旧设备通知只清理它自己那一份。

Task S6: done (D07)。`ensureTextConversation()` 用 `SessionCoordinator.createSession`
这条**不碰设备占用**的 Store 门面建纯文字记录（不抢 `activeSessionID`，`engineProfile`
记 `unknown` 而不是编一个），`ask(typed:) -> TextSendResult` 走同一条编排且不朗读。
`AssistantView` 去掉「先开麦再忙等 3 秒等 sessionID」，改单飞门闩 `isSending`。
**本轮补齐了一处实现遗漏**：`sendFailure` 当时只写不读，用户根本看不到失败原因；现在
用既有 `NoticeBar`（`warning` + 「重试」）呈现，发送中按钮显示「发送中…」并禁用。
草稿只在未被改动时清空，失败原样保留。

Task S7: done (D09)。`LineDraft.createdAt: Date?` 并在 Store 绑定；`AssistantSession`
用 `itemObservedAt: [String: Date]` 按 itemID 记**首条证据**的时刻，配每个连接建立的
时钟锚点算出 `tStart`，`tEnd` 存 NULL、`timingQuality = .unavailable`。
顺带修掉两处真实缺陷：`LineDraft.init` 漏了 `self.createdAt = createdAt`（误插到
`TranscriptLine.init` 形成重复行），观测时刻一直是 nil；`committedItemIDs` 是**连接内**
去重键而重连未清，新连接上同一 itemID 的一句话被吞。

## §7.2 — App—服务边界共享 fixture（2026-09-28）

新增 `tests/fixtures/assistant_realtime_lifecycle.json`（四组：打断闭环 / 长回复 /
输入分包 / 断线恢复）与两侧消费者。两侧**共用同一份 `server_events`**：

- 服务端 `tests/test_assistant_realtime_lifecycle_fixture.py`：真实 `/v1/realtime`
  WebSocket + fake backend 跑完 `client_script`，把观测事件投影回 fixture 比较。
- App 侧 `AssistantSessionTests` 的 `FixtureRealtime`：用同一份 `server_events` 应答
  生产 `AssistantSession`，断言 App 侧可观察结果。fixture 路径由 `#filePath` 定位，
  不依赖 cwd。

三条设计决定：

1. `speechrail.tts.audio.delta` **不写进 fixture**——项目规则禁止 fixture 记录原始音频/
   Base64。改为在 `omitted_event_types` 里声明，并断言这些类型确实出现过，
   不做静默丢弃。`sequence` 因此保留跳号（long_reply 的 completed 是 9）。
2. App 自选 `request_id`，fixture 记录的是服务端那一轮的身份。`FixtureRealtime` 做
   显式映射：**内容**（准入、ACK 计数、终态）取自 fixture，**身份**用 App 的。
3. D11 的断言落在**落库正文**上，不是 wire 文本。实测确认
   `AssistantSession` 在 `tts.cleanForSpeech` 上挂了 `VoicePrompt.spokenText`：
   五个增量 `Hello`/` `/`world\n`/`  `/`再见` 的原样拼接是 `Hello world\n  再见`
   （落库、显示、历史都保留），送进 TTS 的是清洗后的 `Hello world 再见`。
   初版 fixture 把 wire 文本写成原样拼接，测试红了——那是 fixture 写错，不是产品
   丢空白；已改为同时钉住 `raw_reply_text` 与 `tts_appended_text` 两种形态。

变异验证：把 fixture 里 `long_reply` 某个 `total_codepoints` 改成 999，服务端比较
立刻红并指名 event 6；改回后恢复通过。

## S10 — 文档同步（2026-09-28）

- `contracts/realtime-openai.md` 升到 4.2.0：`session.update` 的原子发布、5.1 的
  「分包方式不改变内容」与「每个 utterance 恰好一个终态」、5.3 的三条时序
  （取消优先于音频准入 / 终态屏障 / pending 预算按实际消费归还）。
- `docs/developers/macos-app-audio-capture.md` §3.7.2：设备重建会丢弃未播完的缓冲
  **并通知上层**，两种 `recovered` 分支各自的处置，以及「不能用伪造 rendered 骗回
  预算」。
- `docs/developers/macos-app-development.md`：新增「语音助手的对话状态、文字降级与
  回复行」小节（hasActiveConversation / 纯文字建档 / 单飞与草稿 / 一轮一个行身份 /
  取消要等服务端确认 / 没有精确时间就不写时间）。
- `docs/developers/macos-app-design-system.md` §6 矩阵新增一行，声明**未新增任何视觉
  Token**，全部复用 `NoticeBar` / `speechRailButton` / `speechRailSingleLineInput`。
- `scripts/check_realtime_contract.py` 与 `scripts/check_user_doc_contract.py` 均 OK。
  根 README 未改。

## 最终验证（2026-09-28）

- `swift test --package-path macos/SpeechRailApp` → **362 passed, 0 failed**。
- `bash scripts/macos_app_build.sh --configuration Debug --timeout 1500` →
  `** BUILD SUCCEEDED **`，exit 0。
- `bash scripts/macos_app_build.sh --configuration Debug --test-unit --timeout 1800` →
  `** TEST SUCCEEDED **`，`Executed 325 tests, with 0 failures`；四个
  `testFixture*` 用例在 Xcode bundle 里**实际执行并通过**（证明 `#filePath` 在
  Xcode 下同样定位到那份 fixture）。
- `uv run --extra dev pytest --no-cov` 覆盖 §8 的 11 个服务/TTS/Realtime 文件 →
  236 passed，exit 0。
- `uv run --extra dev ruff check tests/` → All checks passed；新文件
  `mypy` 0 告警。
- `uv run python scripts/check_realtime_contract.py` /
  `check_user_doc_contract.py` → OK。`git diff --check` → clean。
- 未执行：UI 自动化、真实 worker/模型、真实服务 smoke、性能基准。

## 验收期间修掉的一个真实缺陷：测试泄漏 TTS 文本泵

Xcode `--test-unit` 连续两次挂在同一处（7507 行后不再增长），`sample` 显示
主线程卡在 `XCTWaiter`，同时有一个活着的
`AssistantTTSStreamCoordinator.runPump()` 停在 `AssistantTTSStreamCoordinator.swift:383`
的 `Task.sleep` 重试循环里。

原因在测试侧而不是产品侧：四个 `testFixture*` 用例用 `defer { cleanup(harness) }`
收尾，只删临时目录，**没有结束这一场会话**。文本泵是
`Task { @MainActor … }`，只要 `isActive` 还成立就按 `tickInterval` 一直空转。
SwiftPM 跑完直接退进程，看不见；Xcode test bundle 会等它，于是整轮挂住。

修法：新增 `stopAndCleanUp(_:)` 并用 `addTeardownBlock` 调用，顺序是
「先 `stopCapture()`，再清目录」——删目录不会停泵。`Harness` 因此标为
`@unchecked Sendable`（成员各自已是 MainActor / actor / `@unchecked Sendable`，
只在测试的 MainActor 上下文里传递），收尾闭包刻意不捕获 `self`。
修完 Xcode gate 从挂死变成 `TEST SUCCEEDED`。

这也是 §8.3 第 5 条的正面例子：退出码为 0 的 SwiftPM 全绿**不能**替代 Xcode
target 的实际执行证据；反过来，Xcode 挂住也不等于产品有错——要看栈。

## AC 审计（对照方案 §8.2 逐条）

| 验收项 | 证据 | 判定 |
|---|---|---|
| D01 waiter 恰好释放一次 | S1：18/18，CONTINUATION MISUSE 消失；epoch+WaitTarget+UUID 分槽 | 通过 |
| D02 取消后旧操作不能复活 | S2 RED：会话被拉回 `.listening`、建了记录、连接没关 | 通过 |
| D03 重连同记录 | S2 RED 7 处断言（换 sessionID、清零 turns/ordinal、多一条记录）；fixture `reconnect_recovery` 复核 | 通过 |
| D04 静音仍 active | S3：`hasActiveConversation` / `isActivelyRunning` 分离 | 通过 |
| D05 设备丢弃不伪造 rendered | S5：两种 `recovered` 分支；恢复成功也通知 | 通过 |
| D06 失败后不继续播报 | S4：先停播 → 取消 → 落库；变异验证 4/5 用例失败 | 通过 |
| D07 文字降级 | S6 + 本轮补的 `sendFailure` 呈现 | 通过 |
| D08 稳定行 ID / 幂等终结 | S4 + `AssistantPersistenceTests` 9 例 | 通过 |
| D09 观测时刻 | S7 + fixture `input_packetization`；NULL 时轴 + unavailable | 通过 |
| D10 无成功终态不报完整 | S8：4 例变异验证由绿转红 | 通过 |
| D11 空白保留 | S9 + fixture `long_reply` 同时钉 raw 与 spoken 两种形态 | 通过 |
| B01–B08 | SB0–SB5，各自 RED→GREEN 记录在账本上方 | 通过 |
| §7.2 四组跨层 fixture | 5 个 Python 用例 + 4 个 Swift 用例共用一份 JSON；变异验证服务端会红 | 通过 |
| 生产 AssistantSession 进测试 | SwiftPM 362 与 Xcode 325 都实际执行 | 通过 |
| §2.4 双侧登记 | pbxproj `+18/-4`（4 行是重写的单行 `children`/`files`），`plutil -lint` OK | 通过 |
| §7.3 矩阵 19 行 | 每行都有 §7 用例与本轮证据，无「步骤完成但验收未判定」 | 通过 |
| 旧 SQLite / 星标 / 时间 | `AssistantPersistenceTests` 9 例，含本轮新增的「既有时间轴不许被收尾重算」 | 通过 |
| 文档一致 | 契约 4.2.0 + 三份开发者文档；两个契约检查脚本 OK；根 README 未改 | 通过 |

**未闭合的诚实边界**：真实声学 AEC/双讲收敛/外放距离、真实 worker 与模型的
端到端质量、UI 自动化与视觉走查均**未执行**——本轮没有授权，也不声称通过。
方案 §9 第 1 条与 §8.2 的口径在这些项上保持「未验收」而不是「通过」。
