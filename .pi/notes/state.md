State format: capsule-v2
State revision: 89

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。v2.1.2 已发；demo 25 条
  matrix 已装真机（iPhone 15 Pro Max / iOS 27.0）。

## Task
- Goal: fixture 修复 + v2.1.2 发布 + demo matrix 扩展 → 全部闭环。
- Unit: APlay 仓库。
- Done when: ✓ 全部达成（含 ac3/eac3 真机实证）。

## Progress
- Done: SF-0089 ac3/eac3 真机实证（failed，iOS 不开放 Dolby 解码器），
  demo 与 README 已按平台事实标注（iosUnsupportedFormats、「iOS ✗」、
  AC-3/E-AC-3 note 改写）。SF-0088 matrix 15→25、README 195 行。
- Open: 两件待用户定夺:
  ① wv/ogg/spx 入 demo 需在 xcodeproj 新建 4 个 C target（163 源文件）；
  ② ChangeLog.md unreleased 段对的是已发版本，头未改。
- Checks: Release 构建成功；装机启动成功；plutil -lint 通过；
  macOS AudioConverterNew('ac-3'/'ec-3')=noErr；326/326 仍有效（SF-0086）。
- Pending: 等用户验收 demo 上「iOS ✗」标记的呈现。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py；本次未改解码逻辑。
  bash cwd 每次回 APlay；edit oldText 须含 4 空格缩进；改 pbxproj 用
  python 批量插 + plutil -lint。可选库 fallback 包装不要套不需要它的格式。
- xcodeproj 无 SPM 的 C 库 target（WavPack/Vorbis/Speex/CAPlay*）。
  AC-3/E-AC-3 在 iOS 上不可解到 PCM，是平台限制非 bug。

## Next
- Action: 提交推送（demo 平台标记 + README 措辞 + state）；等用户验收
  demo「iOS ✗」呈现，并定夺 wv/ogg/spx 与 ChangeLog 两件事。
- Verify: git ls-remote HEAD 与本地一致。
- Refs: SF-0089（Dolby 实证与标注），SF-0088（matrix/README），
  SF-0087（v2.1.2），SF-0086（修复细节）。
