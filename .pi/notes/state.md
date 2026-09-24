State format: capsule-v2
State revision: 3

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-24；HEAD=a31cbe9（origin/master 同步）。泄漏修复全部完成，
  工作区未提交。
- 用户报告根因：切歌/无缝预加载时旧 Composer 未完整销毁。现场 1 个 APlay
  却有 23 个 Composer/Streamer/DataTask，Network 缓冲约 604MB。

## Task
- Goal: 修复快速切歌导致的 Composer/Streamer/DataTask 泄漏，全量测试转绿。
- Unit: APlay.swift 槽位并发模型 + Composer.destroy/ring buffer 唤醒 +
  Composer.url 的异步开流时序。
- Done when: swift test 全量 3 连跑 0 失败 0 崩溃，泄漏测试断言通过。

## Progress
- Done: 复现测试 MacTests/ComposerLeakReproTests.swift（2 用例，基线增量断言）。
- Done: Composer 加 DEBUG `liveCount`；destroy 幂等（`guard alive.exchange(0)==1`）。
- Done: 槽位改 `_composerLock = NSRecursiveLock`；`_withComposerLock` 包裹
  清空→destroy→装新；`_play`、`next()`、`_swapCurrentComposer`、
  `_setNextComposer`、`_installNextComposerIfVacant`、`_composerPair` 全在锁内。
- Done: ring buffer 去掉 5ms 轮询——write 改 `writerWake.wait()`，read 后
  `writerWake.signal()`，clear 仍 signal；write 的 `closed` 检查保证拆毁即退出。
- Done: Composer 新增 urlLock 保护的 `recordedURL`，`play`/`preload` 先记 URL，
  `var url` 返回 `recordedURL ?? _streamer.info.url`——接管判据不再与
  preload 的异步开流竞争（修好 testSkipReusesThePreloadedTrack）。
- Done: NowPlayingInfo `_config` 改强引用；`remove()` 的 barrier 改 sync；
  测试 harness 的 `[unowned box]` 改 `[weak box]`。
- Done: FakeStreamProvider.info 加 NSLock，消除加压下 fake 的 info 撕裂读
  （_SwiftURL 悬垂 SIGABRT）。
- Done: 全量 334 tests / 0 failures / 0 crashes，连续 6 轮。
- Open: none（三个失败已全部闭合）。
- Checks: swift test 全量 6 连绿（334 passed / 0 失败 / 0 崩溃，23s/轮）；
  加压（8× 自旋）orchestration 15 轮 + 全量 6 轮无新增崩溃；泄漏用例
  隔离跑 live=1，整套跑按基线增量断言通过。
- Pending: 提交本地 commit（推送与否待用户确认）。

## Rules
- Constraints: 编辑 oldText 须含 4 空格缩进；用 python 精确替换避免空白不匹配。
  swift test 需 CLANG_MODULE_CACHE_PATH=/private/tmp/aplay-midi-clang-cache
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/aplay-midi-swift-cache
  --disable-sandbox --scratch-path /private/tmp/aplay-midi-build
  --cache-path /private/tmp/aplay-midi-cache。
- 既有非范围问题（HEAD 同样复现，未处理）：MetadataParser/MidiDecoder 套件在
  8 倍饱和加压下偶发 SIGTRAP；TSan 报 InternalLogger.reset() 的 _openTime 竞争。
- 委派现状（2026-09-23）: codex 全系列不可用、atria 未登录。本任务由主会话推进。

## Next
- Action: 提交本次修复（git commit），推送与否待用户确认（镜像仓 origin/master）。
- Verify: 提交后 swift test 再跑 1 轮全量保持 0 失败。
- Refs: SF-0101（泄漏修复全过程）；SF-0102（本轮三失败闭合、SIGABRT 定位）
