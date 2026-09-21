State format: capsule-v2
State revision: 86

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD 待提交（SF-0086）。
  v2.1.0 + v2.1.1 已 tag/Release。真机装机待命仍挂起（手机不在本网段）。

## Task
- Goal: 修「合成 fixture 端到端 FAIL」→ **已修完，待提交发版**。
- Unit: APlay 仓库；提交 + tag v2.1.2（Composer 改动影响产品库）。
- Done when: 提交推送、tag v2.1.2 发布；release midi 用户确认有声。

## Progress
- Done: 分解三件事（SF-0086）:
  ①真 bug——`.duration` 事件只在 `.bitrate` 事件时广播;Composer 加
  hasAnnouncedDuration，.output 首批数据时若 duration>0 兜底广播一次,
  .bitrate 路径不变（ALAC/AAC 短文件缺 BitRate 且 2s 攒不够 50 包回退）。
  ②MacPlayback 按扩展名装配可选库:.webm/.mka→APlayOpus、
  .mid/.midi/.kar→APlayMidi+Fixtures/APlayTestSine.sf2，其余走默认 builder。
  ③tone-opus.ogg 是假问题——Ogg+Opus 容器本不支持（APlayOpus 只做
  WebM/Matroska），仅 VorbisDecoderTests 用，保持 FAIL 属预期。
- 坑: 统一走复合 builder 会让 mp3/alac 回归（包装层 info 不透明），
  已改回按扩展名装配。
- Open: 提交 + tag v2.1.2 + Release；release midi 待用户确认有声。
- Checks: debug+release 双构建 7 格式端到端全 PASS（mp3/alac/aac/
  ima4wav/webm/mka/midi）；swift test 326/326 passed 0 failures。
- Pending: none。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py。本次未改解码逻辑、
  未重跑 coverage。bash 工具 cwd 每次回 APlay，跨仓库须带
  `--package-path`/`git -C`。edit oldText 须含 4 空格缩进。
- 可选库 fallback 包装不要套在不需要它的格式上（info 不透明致回归）。

## Next
- Action: git add APlay/Composer.swift MacPlayback/main.swift
  Package.swift .pi/notes/*，commit；tag v2.1.2；push + push --tags；
  gh release create v2.1.2。
- Verify: git ls-remote --tags 含 v2.1.2；kumone-tca 可升依赖。
- Refs: SF-0086（fixture FAIL 分解与修复），SF-0085（release 无声已闭环）。
