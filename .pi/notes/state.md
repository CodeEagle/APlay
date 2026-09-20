State format: capsule-v2
State revision: 59

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-20；Xcode 27.0 / Swift 6.4。真机 iPhone 15 Pro Max
  （iOS 27.0，UDID 00008130-000E7959262B803A，Team L5W9FHSX92）。
  HEAD 4f3e1d6 == origin/master（已推送）。

## Task
- Goal: 推送收尾 + AirPlay 测试答复 + demo 内 AirPlay 路由按钮（均已完成）。
- Unit: APlayDemo（AirPlay 演示）。
- Done when: 新按钮已构建通过并推送到远端（已达成）。

## Progress
- Done: 推送批 D（f3969fe，强推一次）。
- Done: 答复 AirPlay 测试方法（真机+接收端、控制中心路由、锁屏/远端远程控制、
  路由中断回退、swift test 回归）。
- Done: APlayDemo 加 AirPlay 路由按钮——新文件 AirPlayRoutePicker.swift
  （AVRoutePickerView 的 UIViewRepresentable 包装 + 路由名实时标签），
  插入 NowPlayingView 的 transport/loopChips 之间；pbxproj 四处登记
  （fileRef ...110C / buildFile ...120C）。
- Done: 提交 4f3e1d6 并 push（fast-forward），远端已更新。
- Open: 无。
- Checks: iOS 模拟器+真机 APlayDemo BUILD SUCCEEDED；
  swift test --enable-code-coverage 226/226；plutil -lint OK。
- Pending: none。

## Rules
- Constraints: 历史已重写，旧哈希失效；推送需以现 HEAD 为准。
- 事实: 传统 xcodeproj 目标新建 swift 文件须登记 pbxproj 四处；
  测试在 MacTests/（非 Tests/），裸 swift test 跑 0 套件，
  需 --enable-code-coverage 才跑全 226。

## Next
- Action: 无待办；等用户下一步指令（真机可按 SF-0058 步骤验 AirPlay）。
- Verify: —
- Refs: SF-0059（AirPlay 路由按钮），SF-0058（推送+AirPlay 测试答复）。
