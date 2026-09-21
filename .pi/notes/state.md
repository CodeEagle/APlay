State format: capsule-v2
State revision: 85

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD 待提交（SF-0085 修复）。
  v2.1.0 已 tag/Release（含 2.1.0 那处 decode-loop 修复）。
  真机 lincoln-phone = 00008130-000E7959262B803A 仍 unavailable（装机待命挂起）。

## Task
- Goal: 修 kumone-tca 报的「release -O 打包后播放不了」→ **已修复**。
  现在打新 tag 2.1.1 并发布，让 kumone-tca 的 SPM 依赖能升上来。
- Unit: APlay 仓库 master；tag + push + GitHub Release。
- Done when: tag v2.1.1 推上远端，kumone-tca 可指向新版本。

## Progress
- Done: 定位并修复 **release-only 无声**（SF-0085，第二处指针生存期 bug）:
  AVAudioEngine manual rendering 的 inputBlock 原用
  `withUnsafePointer(to: &lazyVar)` 返回 AudioBufferList，指针只在调用
  期间有效、engine 返回后才读，-O 下拿到临时拷贝地址 → 静音。
  改为稳定堆分配 `_inputBufferList`（deinit 释放），删废弃 lazy var。
  README「Known issue (fixed)」重写为两处修复并列。
- 验证: release APlayMacPlayback 播用户给的真实 mp3（210s）+ a.m4a
  （AAC 137s）+ afconvert 造的 aac m4a 全 PASS，用户亲耳确认**有声音**；
  swift test 326/326 passed 0 failures。
- Open: 打 tag v2.1.1、推送、发 Release。
- Checks: swift test 326/326；release 端到端有声（用户确认）。
- Pending: kumone-tca 端把依赖升到 2.1.1 后回归其 release 打包。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（7 产品 swift 模块）。
  改完源要重取覆盖率；本次纯指针生存期修复，未改逻辑，未重跑 coverage。
  edit oldText 须含 4 空格缩进；同文件多 edit 分开发。
  工程文件 tab/0 缩进混用，批量改 pbxproj 用 Python 按唯一锚点插入最稳。
- 事实: release-only bug 的复现靠 APlayMacPlayback（swift build -c
  release --product APlayMacPlayback），它用 AVAudioEngine manual
  rendering + DefaultOutput AU；xctest 进程里 AudioOutputUnitStart
  返回 -10867，故端到端只在可执行文件里验。
- 残留（非 bug）: 合成 fixture（tone-alac/tone-mp4/tone-opus/melody.mid）
  缺 bitrate → .duration 事件不发 → APlayMacPlayback 超时 FAIL，但音频
  实际在播；真实文件与 afconvert 转的 m4a 全 PASS。备忘勿误判为回归。

## Next
- Action: git add README.md APlay/APlay/BuildInComponents/Players/APlayer.swift
  + notes，commit；git tag v2.1.1；git push && git push --tags；
  然后gh release create v2.1.1（或 GitHub 网页）。
- Verify: git ls-remote --tags 含 v2.1.1；kumone-tca 端
  .build/checkouts/APlay 可升到新 revision。
- Refs: SF-0085（release 无声根因与修复），SF-0084（装机待命，挂起），
  SF-0083（goal 审计结单）。
