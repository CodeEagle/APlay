State format: capsule-v2
State revision: 64

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD c004a8d == origin/master；tag v2.1.0 已推且 Release 已发。

## Task
- Goal: 给不支持格式加支持方案——容器层已落地，codec 层待定。
- Unit: APlayExtras + hint 表 + 测试 + README。
- Done when: 容器类全部可播并钉测试（已达成）。

## Progress
- Done: v2.1.0 发布全套（tag/Release/5 issue 全关）。
- Done: README 三类表 + routed 格式实测（SF-0063）。
- Done: 容器层支持——handledHints 扩为 [.caf,.aiff,.aifc,.next,.k3gp,.k3gp2,
  .rf64,.soundDesigner2,.w64]；新增 AudioFileType.w64 + fileHint "w64"；
  SeekableFileDecoderTests +4 用例实测 AU/3GP/3G2/W64 经 APlayExtras 全部
  可播零错误；RF64/SD2 无 muxer 造样本，按原生支持标「无 fixture」。
  README 相应行移到「本地播放」类。
- Open: codec 层（Vorbis/裸Opus/WMA/WavPack/APE/TTA/TrueHD/AC-4/DSD/
  Musepack/ATRAC/Speex/MP1/AMR）需经 audioDecoderBuilder 注入第三方 C 库
  wrapper，未做；MIDI/SF2 需合成器，非解码。
- Checks: swift test --enable-code-coverage 230/230（+4）；APlayDemo iOS
  模拟器 BUILD SUCCEEDED。
- Pending: none（codec 层等用户指定格式再做）。

## Rules
- Constraints: 支持与否须实测；无 fixture 的诚实标注。
- 事实: AudioFileStream 支持的容器子集远小于 ExtAudioFile；ExtAudioFile
  原生开 NeXT/3gpp/3gp2/RF64/Sd2f/W64；RF64 无 ffmpeg muxer（'Invalid
  argument'），SD2 无编码器；AC-3/E-AC-3 在 iOS 解码受 Dolby 授权限制。

## Next
- Action: 无待办；codec 层方案已备（audioDecoderBuilder + C 库 wrapper），
  等用户指定具体格式。
- Verify: —
- Refs: SF-0064（容器层支持），SF-0063（三类表+实测）。
