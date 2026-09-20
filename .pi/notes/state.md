State format: capsule-v2
State revision: 66

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD e4f039b（WavPack 子库已提交，未推送）；v2.1.0 已 tag/Release。

## Task
- Goal: 每个 codec 一个独立 SPM 子库，按需加载，配文件测试。
- Unit: 下一个 codec 子库（照 WavPack 样板复制）。
- Done when: 选定 codec 的样板测试全绿并提交。

## Progress
- Done: WavPack 子库全部完成并提交 e4f039b——CAPlayWavPack（vendored C）
  + APlayWavPack（wrapper）+ Package product；hint 表加 .wv→.wavpack；
  testDecodesWavPack + testMp3ReachesTheFallback（FakeDecoder 路由验证）
  两测试通过；7 处 dbg() 已删；README 加第四类 matrix bucket，WavPack
  从「不支持」移出；ChangeLog unreleased 第 1 条。
- Done: 容器层（SF-0064，c004a8d）AU/3GP/3G2/W64/RF64/SD2。
- Checks: swift test 232/232 全绿；swift build 通过；APlayDemo iOS 构建
  BUILD SUCCEEDED（xcodeproj 不含 APlayWavPack，无需改动）。
- Open: 其余 codec 未开始（源码在 /tmp/codec_probe，见下）。
- Pending: 推送 e4f039b 到 origin/master。

## Rules
- Constraints: C 库 reader 回调不能留 nil（段错误）；samples=每声道帧数，
  buffer 须 frames*channels；trampoline 须文件级全局 func，成员用
  fileprivate；resume 早于 prepare 需 _pendingResume；接入点是
  Configuration(audioDecoderBuilder:)，非 streamerBuilder。
- 事实: /tmp/codec_probe/ 有 ogg/vorbis/wavpack/opus/speex 源码（全 BSD-3）；
  AC-4/TrueHD/WMA/ATRAC/DSD 无开源解码器，做不了；MIDI/SF2 需合成器。
  Vorbis 需 ogg+vorbis 双库且可能要 config.h；Opus 裸流/Speex 较简单。

## Next
- Action: 推送 e4f039b；然后照 WavPack 样板做下一个 codec（优先 Opus 裸流
  或 Speex，结构最简；Vorbis 需双库较重）。
- Verify: swift test 保持 232+（新 codec 各加 2 测试）；iOS 构建不回归。
- Refs: SF-0066（WavPack 完成态+经验），SF-0065（进行中细节），SF-0064。
