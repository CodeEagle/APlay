State format: capsule-v2
State revision: 33

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；测试真机
  lincoln-phone（iPhone 15 Pro Max，iOS 27.0，UDID 00008130-000E7959262B803A）。
  本地领先 origin 27 commit 未 push（含 d61b53e）。

## Task
- Goal: opus 真机验证（用户: "打包发手机测 opus"）——**已完成**。⑤ 未启动。
- Unit: 无活跃单元。
- Done when: （已完成）真机 12 格式全部播放并逐轨推进 + swift test 86/86 +
  iOS 8 套构建 + MacPlayback 双端到端 + 提交。

## Progress
- Done: opus 真机原生解码确认（无需注入解码器）; Demo 改真机格式试机
  （Samples 资源 + SceneDelegate + result.log 诊断链）; 三个框架 bug 修复
  （startBackgroundTask 主线程派发、无 duration 流的停驻曲终检测、iOS 17+
  Scene 生命周期），均已提交 d61b53e。详见 full SF-0028。
- Open: ⑤ 未启动; origin 未 push（镜像仓库，未经允许不 push）。
- Checks: swift test 86/86; iOS 8 套构建 SUCCEEDED（仅 appintents 工具链噪声）;
  swift build -c release 零警告; MacPlayback 单轨+gapless 双 PASS; 真机 12
  格式逐轨推进（wav→aifc 跨格式 paused 一次，符合文档）。
- Pending: 无。

## Rules
- Constraints: 镜像仓库未经允许不 push; 每批改动须 iOS 四套构建 +
  MacPlayback 端到端验证后才提交; 只测可注入协议接缝; 提交排除 xcuserstate
  与 .DS_Store。
- 真机打包: 命令行 build setting 覆盖对 Xcode 27 签名解析无效; 用 Xcode 库内
  wildcard profile（team 77SXM8HYXF，UUID 82de0928-9338-4e57-80b8-26dc00957e0e）
  + 工程命令行 DEVELOPMENT_TEAM/CODE_SIGN_STYLE=Automatic +
  -allowProvisioningUpdates，由 Xcode 签名栈完成; devicectl 取诊断用
  copy from systemCrashLogs 与 appDataContainer。
- 教训: ①~㉚ 见 full; iOS 17+ 无 SceneManifest 启动即 trap; 异步 barrier
  属性在同步连发事件下读不到新值（停驻计数用 NSLock）。

## Next
- Action: 等待用户指定 ⑤ 或其他任务。
- Verify: 无（本批已闭环）。
- Refs: SF-0026、SF-0027、SF-0028。
