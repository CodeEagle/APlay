State format: capsule-v2
State revision: 35

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；真机
  lincoln-phone（iOS 27.0，UDID 00008130-000E7959262B803A）。本地领先 origin
  28 commit 未 push（含 718c466）。

## Task
- Goal: 用户四项改造（goal 3b94daf6）: ① README 格式支持表; ② 不支持格式的可选
  子库; ③ 改 SPM-only 安装; ④ AirPlay2 支持。①③ 已完成，②④ 未开始。
- Unit: ①+③ 已交付并验证; 次 ② 定范围（Core Audio 不支持的编码/容器）;
  最后 ④ AirPlay2 最小自研。
- Done when: 四项代码+文档完成，swift test 全绿 + iOS 构建零业务警告后提交。

## Progress
- Done: ① README "Supported formats" 段（据 FormatCompatibilityTests 已验矩阵:
  7 解码成功 + 2 parse-only + hint 表已映射无 fixture 的扩展）; ③ git rm
  APlay.podspec、Installation 仅 SPM、删 Known-issue 的 pod 句、Fastfile 去
  pod 三动作并加 test lane + bump_swift_version_constant（bump 先于 test，
  靠 APlaySmokeTests:19 断言把关）、ChangeLog v2.1.0 加第 9/10 条。详见 SF-0030。
- Open: ② 可选子库（范围待定: ogg/vorbis、非 OGG 的 opus 等 Core Audio 不支持者，
  须不污染主库、只走 audioDecoderBuilder 注入缝）; ④ AirPlay2 缺
  MPRemoteCommandCenter/AVRoutePickerView/routeChange 处理（待查证）。
- Checks: swift test 86/86 零失败; iOS 8 套构建 SUCCEEDED 零业务警告;
  swift run -c release APlayMacPlayback 播 a.m4a PASS（-O 优化路径实证）。
- Pending: ①③ 的提交（验证已过，待 commit; 排除 xcuserstate 与 .DS_Store）。

## Rules
- Constraints: 镜像仓库未经允许不 push; 每批改动须 iOS 四套构建 + MacPlayback
  端到端验证后才提交; 只测可注入协议接缝; 提交排除 xcuserstate 与 .DS_Store。
- 真机打包: 用 Xcode 库内 wildcard profile（team 77SXM8HYXF，UUID
  82de0928-9338-4e57-80b8-26dc00957e0e）+ 工程命令行 DEVELOPMENT_TEAM/
  CODE_SIGN_STYLE=Automatic + -allowProvisioningUpdates; 诊断取
  devicectl copy from systemCrashLogs/appDataContainer。
- 教训: ①~㉚ 见 full; iOS 17+ 无 SceneManifest 启动即 trap; 异步 barrier 属性
  在同步连发事件下读不到新值（用 NSLock）。

## Next
- Action: 提交 ①③（README.md、ChangeLog.md、APlay.podspec 删除、fastlane/Fastfile
  + 本批 notes），然后开 ②: 查 audioDecoderBuilder 注入缝，定可选子库最小范围。
- Verify: 提交后 git status 无 xcuserstate/.DS_Store; ② 的子库须 swift test 仍 86/86。
- Refs: SF-0029（调查）、SF-0030（①③ 实况）; goal 3b94daf6。
