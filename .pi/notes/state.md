State format: capsule-v2
State revision: 63

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD f474864 == origin/master；tag v2.1.0 已推且 Release 已发。

## Task
- Goal: README 格式表改三类（流式/本地/不支持）+ 补 routed 格式实测——已完成。
- Unit: README + MacTests fixtures/测试。
- Done when: 每类有实测依据，测试全绿（已达成）。

## Progress
- Done: v2.1.0 发布全套（tag/Release/5 issue 全关）。
- Done: README 改为三类表——Streaming playback（默认路径，12 行全 fixture
  钉死）/ Local file playback via APlayExtras（caf/aiff/aifc，注明 streaming
  失败原因）/ Not supported（AU/3GPP/RF64/SD2/MP1/AMR/Vorbis/裸Opus/WMA/
  WavPack/APE/TTA/TrueHD/AC-4/DSD/Musepack/ATRAC/Speex/Wave64/MKA/MPEG-TS/
  raw PCM）；MIDI/SF2 标非音频流。
- Done: 新增 fixture（mp2/ac3/eac3/mp4/m4b/ima4-wav/3gp/3g2/au）并实测入表：
  MP2/AAC-MP4/M4B/IMA4-WAVE/AC-3/E-AC-3 新晋流式 verified（E-AC-3 的
  formatID='ec-3'）；AIFF-C streaming 完全无属性；AU 解码失败；3GP/3G2 不 parse。
- Done: ChangeLog 加「unreleased」第 1 条。
- Open: 无（MP1/AMR 本机无编码器，已诚实标「unverified」于不支持类）。
- Checks: swift test --enable-code-coverage 226/226；APlayDemo iOS 模拟器
  BUILD SUCCEEDED。
- Pending: none。

## Rules
- Constraints: 状态分类须以实测为准；hint 映射不等于能播放。
- 事实: AudioFileStream 支持的容器子集远小于 AudioFile（AU/3GP/RF64/SD2
  均不解）；APlayExtras handledHints=[.caf,.aiff,.aifc]；iOS 上 AC-3/E-AC-3
  解码受 Dolby 授权限制。

## Next
- Action: 无待办；等用户下一步指令。
- Verify: —
- Refs: SF-0063（三类表+实测），SF-0062（README 全格式表+eac3 补映射）。
