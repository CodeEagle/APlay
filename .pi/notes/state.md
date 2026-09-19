State format: capsule-v2
State revision: 32

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；macOS 14 SDK 测试机。
  本地领先 origin 26 commit 未 push（含本批 gapless 提交）。

## Task
- Goal: ④ gapless（Configuration 开关默认关 + 自动预加载下一曲）——**已完成并提交**。
  ⑤ 尚未启动；opus 注入式解码仍须 iOS 真机验证。
- Unit: 无活跃单元。
- Done when: （已完成）swift test 全绿 + iOS 八套构建零业务警告 + 双 MacPlayback
  端到端通过 + 文档 + 提交。

## Progress
- Done: ④ gapless 全部产品代码与 14 个新测试（SF-0026）；MacPlayback 两处编译错修复、
  gapless 与单轨端到端双 PASS、ChangeLog v2.1.0 段 + README 用法节、本批提交（SF-0027）。
- Open: opus iOS 真机验证（不阻塞）；⑤ 未启动。
- Checks: swift test 85/85（0 failed）；iOS 8 套构建 SUCCEEDED（唯一 warning 为
  appintentsmetadataprocessor 工具链噪声）；swift build -c release 零警告；
  MacPlayback gapless PASS（无 .paused 切轨、第 2 轨推进 2.0s）；单轨回归 PASS。
- Pending: 无。

## Rules
- Constraints: 镜像仓库未经允许不 push；不推翻重设计；每批改动须 iOS 四套构建 +
  MacPlayback 端到端验证后才提交；只测可注入协议接缝；提交排除 xcuserstate。
- gapless 要点: 预加载下一曲 composer（不动当前 composer、不布 readClosure、不 setup AU）；
  曲终 decoderEmpty 且预加载已缓冲时原子换源；异格式仍须 setup（跨格式不无缝，已文档化）；
  事件在 isPreloadAhead 期间暂存、激活时重放；URL 匹配: 曲终用 peekNextURL，手动 next()
  用已传入的 url。Swift 带默认值参数须按声明顺序传。
- 教训: ①~㉖ 见 full；㉗ 字符串插值内不可用 `\ $0` 闭包占位符（用显式闭包）。

## Next
- Action: 等待用户指定 ⑤ 或其他任务；opus 真机验证需真机时再排。
- Verify: 无（本批已闭环）。
- Refs: SF-0026、SF-0027。
