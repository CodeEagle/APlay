State format: capsule-v2
State revision: 5

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-24；远程 master=2f9add8（已与 origin 同步），tag
  v2.1.8 已推。泄漏修复与 PR #20 均已交付。

## Task
- Goal: 修复快速切歌导致的 Composer/Streamer/DataTask 泄漏，全量测试转绿，
  提交推送、合并远程 PR、打新 tag。
- Unit: 全仓。
- Done when: swift test 全量 0 失败 0 崩溃；master 已推送；PR 已合并；tag 已打。

## Progress
- Done: 泄漏修复（槽位 NSRecursiveLock 化、destroy 幂等、ring buffer 去轮询、
  Composer.url 同步可见、fake streamer info 加锁）。
- Done: 复现测试 ComposerLeakReproTests（基线增量断言）；修复前稳定 32 个存活
  Composer，修复后 ≤2。
- Done: 合并 PR #20（nowplaying metadata），解决 APlay.swift / NowPlayingInfo.swift
  两处冲突；336 tests 全绿。
- Done: 推送 master（a31cbe9..2f9add8），PR #20 自动 MERGED，打 tag v2.1.8 并推送。
- Open: none。
- Checks: swift test 全量 336 tests / 0 failures / 0 crashes（合并后单跑）；
  远程核验 master=2f9add8、v2.1.8=c7b5ce9、open PR 为空。
- Pending: none。

## Rules
- Constraints: swift test 需 CLANG_MODULE_CACHE_PATH=/private/tmp/aplay-midi-clang-cache
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/aplay-midi-swift-cache
  --disable-sandbox --scratch-path /private/tmp/aplay-midi-build
  --cache-path /private/tmp/aplay-midi-cache。
- 既有非范围问题（HEAD 同样复现，未处理）：MetadataParser/MidiDecoder 套件在
  8 倍饱和加压下偶发 SIGTRAP；TSan 报 InternalLogger.reset() 的 _openTime 竞争。
- GitHub Releases 的 "Latest" 停在 v2.1.2（此后纯 tag 未建 Release）；用户未要求。

## Next
- Action: none（全部交付完成）。
- Verify: none。
- Refs: SF-0101（泄漏修复全过程）；SF-0102（三失败闭合）；SF-0103（交付完成）
