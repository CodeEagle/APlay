State format: capsule-v2
State revision: 62

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD ded1bf4 == origin/master；tag v2.1.0 已推且 Release 已发。

## Task
- Goal: README 全格式对照表（市面所有音频格式 × 本库支持）——已完成。
- Unit: README 文档 + hint 表。
- Done when: README 含分组全格式表且源码/测试/文档一致（已达成）。

## Progress
- Done: v2.1.0 发布全套（tag/Release/5 issue 全关）。
- Done: README「Supported formats」升级为分组大表（Lossy/Lossless/
  Uncompressed/Containers/Not audio streams），状态四档：
  ✅ verified / ✔ routed（无 fixture）/ ⚠️ stream-only（APlayExtras）
  / 🔌 inject（Core Audio 无解码器）；MIDI/SF2 标 —。
- Done: 修文档与源码不符——ChangeLog 称已映射 .eac3 实则无；
  StreamProviderCompatible.swift:172 补 eac3→.ac3，FormatHintTests 加断言，
  并更新过时 opus/#17 注释。
- Open: 无。
- Checks: swift test --enable-code-coverage 226/226；
  APlayDemo iOS 模拟器 BUILD SUCCEEDED；README 表已渲染。
- Pending: none。

## Rules
- Constraints: README 状态口径须与 FormatCompatibilityTests 一致；
  文档宣称的能力须在源码兑现（eac3 教训）。
- 事实: hint 表 default 回退 .mp3 靠内容嗅探；APlayExtras handledHints
  = [.caf,.aiff,.aifc]；Core Audio 无 Vorbis/裸Opus/WMA/WavPack/APE/TTA/
  TrueHD/DSD/Musepack/ATRAC/Speex/AC-4 解码器。

## Next
- Action: 无待办；等用户下一步指令。
- Verify: —
- Refs: SF-0062（README 全格式表+eac3 补映射），SF-0061（Release+opus 更正）。
