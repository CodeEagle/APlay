State format: capsule-v2
State revision: 29

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；macOS 14 SDK 测试机。
  本地领先 origin 22 commit 未 push。已提交：…、82051c0（③）、f946759（④前置）。
  工作区干净（.build/ 已 gitignore；xcuserstate 为编辑器噪声）。

## Task
- Goal: 剩余 ④ gapless（设计已定，待选 API 形状）；opus 须 iOS 真机验证。
  另 open: 首个 5xx 不重连的缺陷。
- Unit: 当前边界=④ gapless 的 API 取舍决策（自动 vs 显式）。
- Done when: 每批改动经 swift test + iOS 四套构建零警告（工具链噪声除外）+ MacPlayback
  端到端后提交。

## Progress
- Done: ③ StreamerCoverageTests（82051c0）；④前置——player 注入接缝 +
  APlayOrchestrationTests（6 测试，变异验证敏感）+ tearDown 野读修复（f946759）。
  覆盖率 TOTAL 行 53.00%→63.66%（APlay.swift→67.69%、Streamer→51.75%、Composer→60.99%）。
- Open: ④ gapless 实现（见设计，待选 (a)自动预加载+开关 / (b)显式 prepareNext；
  倾向 (a)）；opus iOS 真机验证；5xx 初始错误不重连（handleEndEncountered else 分支与
  handle(data:) 的 reset() 中和了 handle(response:) 挂的看门狗 → 直接 .endEncountered +
  0 字节缓存；被 testRemote500CurrentlyEndsTheStream 钉住。待用户定夺是否改产品）。
- Checks: swift test 70/70（12 连 clean）；iOS 8 套构建 SUCCEEDED 零警告；
  MacPlayback PASS（137s→.playing→推进）。
- Pending: 用户定 ④ 的 API 形状。

## Rules
- Constraints: 镜像仓库未经允许不 push；不推翻重设计；每批改动须 iOS 四套构建 +
  MacPlayback 端到端验证后才提交；只测可注入协议接缝。
- gapless 要点: 预加载"下一曲" composer（prepare(autoplay:false) 语义但不动当前
  composer）；在当前 .decoderEmptyEncountered 且下一曲 ring buffer 有数据时原子切换
  player 取数据源 + startPlayback()，不停 AU；同格式真无缝，异格式仍须 setup()。
  readClosure 由 AU 实时线程调用，源切换须无锁；须把"每次 play 重布闭包"改为稳定闭包
  读原子源。详见 full SF-0024。
- 教训: ①~㉔ 见 full；㉕ tearDown 释放顺序遇上 unowned config + 异步强捕获 teardown 会
  野读——config 须活过组件的排队 teardown。

## Next
- Action: 向用户呈报 ③④ 前置成果 + 5xx 缺陷 + ④ API 取舍，待选定后实现 gapless。
- Verify: swift test 全绿；iOS 四套构建零警告；MacPlayback 端到端。
- Refs: SF-0023、SF-0024；goal 50d17353。
