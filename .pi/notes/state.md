State format: capsule-v2
State revision: 61

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD 24ca563 == origin/master；tag v2.1.0 已推且 Release 已发。

## Task
- Goal: v2.1.0 发布收尾——全部完成（代码/Tag/Issues/Release）。
- Unit: 仓库发布。
- Done when: tag 在远端、Release 已发布、open issue 清空（均已达成）。

## Progress
- Done: 批 D 推送（f3969fe 强推）；AirPlay 路由按钮（4f3e1d6）。
- Done: tag v2.1.0（annotated → 24ca563）已推，远端 3b4b2d7。
- Done: 5 个 open issue 全部关闭（#19/#10/#14/#3/#17），各附依据。
  #17 曾误保留，已更正：标准 .opus（OGG 封装）实已支持
  （FormatCompatibilityTests.swift:46 tone.opus 全绿；demo 自带样本）；
  仅裸 opus 与 Vorbis 不支持。
- Done: GitHub Release v2.1.0 已发布（非 draft/prerelease）：
  https://github.com/CodeEagle/APlay/releases/tag/v2.1.0
- Open: 无。
- Checks: gh release view v2.1.0 isDraft=false isPrerelease=false；
  gh issue list --state open 为空。
- Pending: none。

## Rules
- Constraints: 关 issue 须有代码/版本依据；未解决的不关闭。
- 事实: .opus（OGG 封装）已支持，走 streaming decoder 而非 ExtAudioFile；
  裸 opus / Vorbis 需 audioDecoderBuilder 注入。

## Next
- Action: 无待办；发布收尾完毕，等用户下一步指令。
- Verify: —
- Refs: SF-0061（Release+opus 更正），SF-0060（tag+关 issue），
  SF-0059（AirPlay 按钮）。
