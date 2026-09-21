State format: capsule-v2
State revision: 87

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD=a0933c0 已推送（SF-0087）。
  v2.1.0/v2.1.1/v2.1.2 已 tag/Release。真机装机待命仍挂起（手机不在本网段）。

## Task
- Goal: 修「合成 fixture 端到端 FAIL」→ **已修完并发布 v2.1.2**。
- Unit: APlay 仓库；提交 + tag v2.1.2（Composer 改动影响产品库）。
- Done when: 提交推送、tag v2.1.2 发布 ✓；release midi 用户确认有声（待）。

## Progress
- Done: v2.1.2 全部交付（SF-0087）:
  commit a0933c0 推送；tag v2.1.2 远端确认；Release 已建。
  修复内容见 SF-0086: Composer 首批解码数据兜底广播 duration；
  MacPlayback 按扩展名装配可选库；tone-opus.ogg 属预期 FAIL。
- Open: 仅剩 release midi 用户确认有声（装机挂起中）。
- Checks: 提交前 swift build 通过；326/326 与 7 格式端到端在
  同一工作树已验（SF-0086）。
- Pending: 用户确认 release midi 有声。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py。本次未改解码逻辑、
  未重跑 coverage。bash 工具 cwd 每次回 APlay，跨仓库须带
  `--package-path`/`git -C`。edit oldText 须含 4 空格缩进。
- 可选库 fallback 包装不要套在不需要它的格式上（info 不透明致回归）。

## Next
- Action: 待用户确认 release midi 有声；有声则本任务彻底关闭。
  无声则回 SF-0086 排查 APlayMidi 装配路径（MacPlayback main.swift）。
- Verify: 用户反馈。
- Refs: SF-0087（v2.1.2 交付闭环），SF-0086（修复细节），SF-0085（mp3）。
