State format: capsule-v2
State revision: 74

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD 3132323（本地领先
  origin 4 提交未推）。v2.1.0 已 tag/Release。
- 真机: lincoln-phone = 00008130-000E7959262B803A (iPhone 15 Pro Max)。
  签名只能用本机已登录团队 L5W9FHSX92 的通配 profile（2X9CSZ37SU 未
  登录 Xcode）。构建须带 -allowProvisioningUpdates。
- Goal d867b7b7 仍 active: 三 codec 库已提交；MIDI+SF2 已做成并已写文档
  （SF-0073/74）；覆盖率已达标 90.20%。

## Task
- Goal: 收尾 d867b7b7——demo format matrix 接四库、新格式元数据、
  ICY stop 延迟、Opus 裸流、提交推送。
- Unit: demo 工程接入（须先加 Xcode target）；框架 tagParser 扩分支；
  ICY/Opus 代码项；最后提交推送。
- Done when: matrix 可播四格式；余项同 Goal d867b7b7。

## Progress
- Done: SF-0073 MIDI+SF2 全部做成（APlayMidi SPM target、夹具、13 例测试、
  coverage.py，详见 full SF-0073）。SF-0074 README 文档: 新增 APlayMidi
  段、改写 Not supported 后排除段为交叉引用、Todo issue #17 标完成。
- 覆盖率: 6 模块 6109/6773 = **90.20%** 达标。
- Open: demo 未接四库（三 codec + Midi 均 SPM target，不在 xcodeproj）；
  新格式元数据空分支；Opus 裸流、ICY stop 延迟；**工作区大批未提交**
  （SF-0071 demo + SF-0073 MIDI + SF-0074 README）。
- Checks: swift build 7 产品通过；swift test 287/287 通过（本轮回归确认）。
  注: 尾部 "Test run with 0 tests" 是 runner 噪音，以 Executed 287 行为准。
- Pending: none。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（6 个产品 swift 模块，
  剔除 vendored C 与测试，文件级 summary lines）。任一测试失败会使
  SwiftPM 不合并 profdata，覆盖率测量直接失败。session 是 let，注入用
  sessionBuilder。ID3Parser 远端 v1 探测闭包持 config unowned。
- 事实: **AVAudioUnitSampler 的 loadSoundBankInstrument bankMSB=121
  (0x79, GM set) 才选中 SF2 bank 0；MSB=0 报 -10851。** SF2 生成器:
  sampleID(gen 53) 必须是 zone 内最后一个 generator，否则 Apple 忽略
  其后的 sampleModes/overridingRootKey → 循环失效。离线渲染:
  enableManualRenderingMode(.offline)；结束检测用
  currentPositionInSeconds >= duration + tail（isPlaying 不可靠）。
  manualRenderingMode 只读；wrapper 须自带 canonical ASBD（用
  CoreAudio. 前缀限定 kAudioFormat* 常量，否则 beta 工具链编译器崩）。
  CFNetwork 对 `ICY 200 OK` 剥全部响应头→本机流必须答
  `HTTP/1.1 200 OK`。三个 codec 库 + APlayMidi 均为 SPM target，完全
  不在 APlay.xcodeproj——进 demo 须先加 Xcode target（pbxproj
  buildFile ID 不可与 fileRef ID 重复，曾致文件被编译丢弃）。
  tagParser 只接 .mp3(ID3)/.flac；.mid/.ogg/.spx/.wv 元数据空分支。
- 不 vendor 第三方合成器: FluidSynth 有 glib 依赖；WildMIDI LGPL 且
  保真低。纯 Swift + AVFoundation 零外部依赖。

## Next
- Action: 提交工作区积压（SF-0071 demo + SF-0073 MIDI + SF-0074 README）
  为一批，使工作区干净；提交后继续 demo 接入。
- Verify: git status --short 干净；git log 含新提交；swift test 仍 287。
- Refs: SF-0074（README），SF-0073（MIDI），SF-0071（demo）。
