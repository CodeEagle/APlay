State format: capsule-v2
State revision: 88

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD=9be00b6 未推（SF-0088）。
  v2.1.0/v2.1.1/v2.1.2 已 tag/Release。手机在线（iPhone 15 Pro Max / iOS 27.0），
  demo 已装已启动（25 条 matrix）。

## Task
- Goal: fixture 端到端修复 + v2.1.2 发布 → **全部闭环**（release midi 有声已确认）。
- Unit: APlay 仓库。
- Done when: ✓ 全部达成。

## Progress
- Done: demo matrix 15→25（拷 10 样本 + TrackLibrary + pbxproj 批量插入）； README 精简 492→195 行；midi 有声确认。 v2.1.2 已发布（commit a0933c0、tag、Release）。
- Open: 两件待用户定夺:
  ① wv/ogg/spx 入 demo 需在 xcodeproj 新建 4 个 C target（163 源文件）；
  ② ChangeLog.md unreleased 段对的是已发版本，头未改（本次改动也未入）。
- Checks: Release 构建成功；24 样本确认进 bundle；plutil -lint 通过；
  装机启动成功。SF-0086 的 326/326 仍有效。
- Pending: 等用户反馈 demo 上 25 条 matrix 的播放结果（尤其新加的
  ac3/eac3 在 iOS 上的 Dolby 授权表现）。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py；本次未改解码逻辑。
  bash 工具 cwd 每次回 APlay，跨仓库须带 `--package-path`/`git -C`。
  edit oldText 须含 4 空格缩进。改 pbxproj 用 python 脚本批量插入 +
  plutil -lint 校验。可选库 fallback 包装不要套在不需要它的格式上。
- xcodeproj 无 SPM 的 C 库 target（WavPack/Vorbis/Speex/CAPlay*）。

## Next
- Action: HEAD=9be00b6（demo matrix + README）尚未 push；先推送。
  然后等用户: ① 手机上 25 条 matrix 播放反馈 ② wv/ogg/spx 是否值得
  新建 C target ③ ChangeLog 要不要整理。
- Verify: git ls-remote HEAD 与本地一致。
- Refs: SF-0088（matrix 扩展 + README 精简 + midi 确认），SF-0087（v2.1.2），
  SF-0086（修复细节），SF-0085（mp3）。
