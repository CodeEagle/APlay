State format: capsule-v2
State revision: 60

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD 24ca563 == origin/master；远端 tag v2.1.0 已存在。

## Task
- Goal: 发布收尾——tag 已打已推，4 个旧 issue 已关闭，Release 待定。
- Unit: 仓库发布（tag/issues/release）。
- Done when: v2.1.0 tag 在远端（已达成）；issue 清理按证据执行。

## Progress
- Done: 批 D 推送（f3969fe 强推一次）；AirPlay 路由按钮（4f3e1d6）。
- Done: tag v2.1.0（annotated）指向 24ca563，已 push，远端 3b4b2d7。
- Done: 关闭 #19/#10/#14/#3，各附说明并指向 v2.1.0 或公开 API
  （#14 依据 = APlay.prepare(_:) APlay.swift:184 + preloadNextTrack:521）。
- Open: #17（opus 无法播放）保留——iOS 原生不支持 opus 解码，需自研解码器。
- Open: GitHub Release 尚未创建（gh 已认证，可随时发）。
- Checks: git ls-remote --tags origin v2.1.0 = 3b4b2d7；open issues 仅剩 #17。
- Pending: 用户未定是否发 GitHub Release。

## Rules
- Constraints: 关 issue 须有代码/版本依据；未解决的不关闭（#17）。
- 事实: iOS 原生 ExtAudioFile 不支持 opus；APlay.prepare(_:) 为公开预加载入口。

## Next
- Action: 等用户定是否发 GitHub Release（tag v2.1.0 已就绪）。
- Verify: gh release view v2.1.0。
- Refs: SF-0060（tag+关 issue），SF-0059（AirPlay 按钮），SF-0058（推送+测试）。
