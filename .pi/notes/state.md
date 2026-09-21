State format: capsule-v2
State revision: 83

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD 380f250（已推送）。
  v2.1.0 已 tag/Release。真机 lincoln-phone = 00008130-000E7959262B803A
  (iPhone 15 Pro Max)，当前 unavailable（未插 USB/非同网段）。
  Goal d867b7b7 **已完成**（见 SF-0083 审计）。

## Task
- Goal: 完成所有可行 codec 子库（WavPack 样板）+ 产品 Swift 覆盖率
  80.71%→≥90%，全部提交推送。
- Unit: 全部兑现。
- Done when: swift test 全绿、TOTAL≥90%、提交推送 —— **均已达成本轮可再跑:
  326/326 全绿；Scripts/coverage.py TOTAL 91.14%。

## Progress
- Done: WavPack(基线 e4f039b)、APlayVorbis、APlaySpeex、APlayOpus
  （09876ee；纯 Swift EBML + Core Audio Opus converter，无需 vendoring C；
  SF-0079 决策取代不可行的「Opus 裸流」）、APlayMidi（超额）。
  覆盖率 80.71%→91.14%；测试 232→326。
  Demo 亦接好（380f250: pbxproj 加 APlayOpus framework target、解码链
  Extras→Midi→APlayOpus→默认、Samples 加 tone.webm/tone.mka）；
  xcodebuild generic/platform=iOS BUILD SUCCEEDED，本机团队签名。
- Open: 装机——手机未插 USB，app 已备好。
- Checks: swift test 326/326；coverage TOTAL 91.14%、APlayOpus 100%；
  git status 仅剩 .pi 笔记；origin/master == 本地。
- Pending: 用户插 USB 后装机（命令在 SF-0082/SF-0083）。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（7 产品 swift 模块）。
  任一测试失败使 SwiftPM 不合并 profdata，故改完源要
  swift test --enable-code-coverage 重取再
  python3 Scripts/coverage.py
  .build/out/Products/Debug/codecov/default.profdata
  .build/out/Products/Debug/APlayTests.xctest [--gaps]。
  可选库 wrapper 必须中继 fallback 的 outputStream/inputStream 并代理
  info/seekable（样板=APlayExtras/FileFallbackDecoder；SF-0078 教训）。
  WavPack/MIDI 计时器在 buffer/info 后启动；AudioConverter 的 input proc
  须 class 盒子+Unmanaged，「无包」返 noErr 且 count=0，每包稳定存储。
  OpusHead 在 CodecPrivate，rate/channels 以它为准；非法 rate（0xFFFFFFFF）
  会使 AudioConverterNew 失败。工程文件 tab/0 缩进混用，批量改 pbxproj
  用 Python 按唯一锚点插入最稳。
- edit oldText 须含 4 空格缩进；同文件多 edit 分开发（批量中一个失败会
  回滚整批）。

## Next
- Action: 用户插 USB 后装机（devicectl install app），可选 process
  launch fun.selftsudio.APlayDemo。
- Verify: devicectl 报 "Installation complete"；手机上见 APlayDemo 图标，
  格式矩阵里 Opus·WebM / Opus·Matroska 两行可播。
- Refs: SF-0083（审计结单），SF-0082（Demo 接线+装机命令），
  SF-0081（覆盖率收尾），SF-0080（建库），SF-0078（中继模式）。
