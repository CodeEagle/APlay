State format: capsule-v2
State revision: 81

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD ca54cdc（已推送）。
  v2.1.0 已 tag/Release。真机 lincoln-phone = 00008130-000E7959262B803A
  (iPhone 15 Pro Max)；签名只用本机团队 L5W9FHSX92 通配 profile，
  构建带 -allowProvisioningUpdates。
  Goal d867b7b7 仍 active: 三 codec 库+MIDI+元数据已提交；
  **APlayOpus 亦已落地收尾：库+测试全绿，APlayOpus 覆盖 100%、
  TOTAL 91.14%，待提交推送**。

## Task
- Goal: APlayOpus（Opus-in-WebM/Matroska）落地+测试覆盖尽量高。
- Unit: 代码、夹具、测试、覆盖率皆完；最后一步是提交推送。
- Done when: swift test 全绿、Scripts/coverage.py TOTAL≥90%、提交推送。

## Progress
- Done: SF-0080 建库（纯 Swift EBML + AudioConverter 一步出 canonical PCM
  + SF-0078 中继）；SF-0081 覆盖率收尾——新增 MacTests/EBMLTestBuilders
  共享构建器；WebMDemuxerTests +7 测（metadataItem 全 case、opusTrack
  坏头、Lacing.raw 钉 splitBlock 十一守卫、截断元素、空 Title/TagString、
  Duration 无 scale/<8B、双 TrackEntry 取首个 Opus）；OpusDecoderTests
  +5 测（不存在文件、有轨无包、非法采样率致 AudioConverterNew 失败、
  24 包随机垃圾恰 1 decode error 后停止、prepare 前 pause/resume 与
  未中转字节丢弃、destroy 转发 fallback）+2 扩充（结束后 resume no-op、
  UnhandledDecoder 生命周期）。
  326/326 通过；APlayOpus 535/535 = 100.00%、TOTAL 91.14%。
- Open: 仅剩提交推送（工作区全部为本次 APlayOpus 变更，待一次提交）。
- Checks: swift test --enable-code-coverage 326/326；
  Scripts/coverage.py TOTAL 91.14%、APlayOpus 100.00%。
- Pending: none（提交后此 Goal 可结）。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（7 产品 swift 模块）。
  任一测试失败使 SwiftPM 不合并 profdata，故改完源要
  swift test --enable-code-coverage 重取再
  python3 Scripts/coverage.py
  .build/out/Products/Debug/codecov/default.profdata
  .build/out/Products/Debug/APlayTests.xctest [--gaps]。
  可选库 wrapper 必须中继 fallback 的 outputStream/inputStream 并代理
  info/seekable（样板=APlayExtras/FileFallbackDecoder；SF-0078 教训）。
  WavPack/MIDI 计时器在 buffer/info 后启动；AudioConverter 的 input proc
  须 class 盒子+Unmanaged，「无包」返 noErr 且 count=0，每包稳定存储。
  OpusHead 在 CodecPrivate，rate/channels 以它为准；Core Audio 自处理
  Opus 预跳。非法 rate（0xFFFFFFFF）会使 AudioConverterNew 失败，
  可在开文件时钉错。
- 事实（EBML）: 元素 ID=原始字节(含 marker)，size=数据位(去 marker)；
  8 字节全 1 size=unknown→至 scope 末。Segment 内序: SeekHead
  (0x114D9B74)/Void(0xEC) 可按 size 跳；Info(1549A966, 内含 Title
  0x7BA9/TimecodeScale 0x2AD7B1/Duration 0x4489)/Tracks/Cluster/Tags。
  Tags→Tag 0x7373→SimpleTag 0x67C8→TagName 0x45A3/TagString 0x4487
  （名大写，DURATION 带 \x00）。SimpleBlock: trackNumber(VINT)+
  timecode(int16BE)+flags(bit1-2=lacing)+Xiph lacing；末帧=余量-已声明
  之和。Matroska 每层常带 CRC 0xBF，按 size 跳。本机 ffmpeg 8.0.1 无
  AIFC/libvorbis/libspeex 编码器；Core Audio 对 Opus: OGG✅ CAF✅
  MP4⚠️ WebM/Matroska❌（本库补的缺口）。
- edit oldText 须含 4 空格缩进；同文件多 edit 分开发（批量中一个失败会
  回滚整批）。

## Next
- Action: 1) 一次提交全部 APlayOpus 变更（Sources/APlayOpus/ 三文件、
  Package.swift、两 Protocols、FormatHintTests、coverage.py、
  generate-fixtures.sh、tone.webm/tone.mka、EBMLTestBuilders、
  WebMDemuxerTests、OpusDecoderTests、.pi 笔记）并推 origin master；
  2) 推送后把 Goal d867b7b7 标结。
- Verify: git log -1 含 APlayOpus；git status --short 只剩无关项；
  git push 返回成功；远端 master 与本地一致。
- Refs: SF-0081（本轮测试与度量），SF-0080（建库），SF-0078（中继模式）。
