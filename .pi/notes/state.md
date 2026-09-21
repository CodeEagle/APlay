State format: capsule-v2
State revision: 85

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD ce911a3（已推送）。
  v2.1.0 + **v2.1.1** 已 tag/Release。真机 lincoln-phone 仍 unavailable
  （装机待命挂起，手机不在本网段）。

## Task
- Goal: 修 kumone-tca 报的「release -O 打包后播放不了」→ **已修复并闭环**。
- Unit: 无在做的产品任务。
- Done when: （已达成）v2.1.1 发布 + kumone-tca release 打包有声（用户确认）。

## Progress
- Done: **release-only 无声**修复（SF-0085）。AVAudioEngine manual rendering
  的 inputBlock 原用 `withUnsafePointer(to: &lazyVar)` 返回 AudioBufferList，
  指针只在调用期间有效、引擎返回后才读，-O 下拿到临时拷贝地址 → 静音。
  改稳定堆分配 `_inputBufferList`（deinit 释放），删废弃 lazy var；
  README「Known issue (fixed)」重写为两处修复并列。
- 发版: ce911a3 推 master；tag v2.1.1（annotated）+ GitHub Release
  （https://github.com/CodeEagle/APlay/releases/tag/v2.1.1）。
- kumone-tca: Package.resolved 升到 2.1.1/ce911a3；
  Scripts/build-app.sh release 打包成功，.build/app/Kumone.app 里点歌
  **用户亲耳确认有声音** → 闭环。
- Open: none（装机待命仍挂起，等用户插 USB 或指明手机网段）。
- Checks: swift test 326/326 passed 0 failures；release 端到端
  APlayMacPlayback + Kumone.app 双双有声（用户确认）。
- Pending: none。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（7 产品 swift 模块）。
  本次纯指针生存期修复未改逻辑，未重跑 coverage。
  edit oldText 须含 4 空格缩进；同文件多 edit 分开发。
  bash 工具 cwd 每次回 APlay：跨仓库命令须带绝对路径或
  `--package-path`（swift package）/ `git -C`。
- 残留（非 bug）: 合成 fixture（tone-alac/tone-mp4/tone-opus/melody.mid）
  缺 bitrate → .duration 事件不发 → APlayMacPlayback 超时 FAIL，但音频
  实际在播；真实文件与 afconvert 转的 m4a 全 PASS。备忘勿误判为回归。

## Next
- Action: none；等用户下一步指令（或插 USB 线装机）。
- Verify: —
- Refs: SF-0085（release 无声根因、修复、发版、闭环），SF-0084（装机待命）。
