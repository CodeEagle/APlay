State format: capsule-v2
State revision: 75

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD ddd3640（本地领先
  origin 2 提交未推）。v2.1.0 已 tag/Release。
- 真机: lincoln-phone = 00008130-000E7959262B803A (iPhone 15 Pro Max)。
  签名只能用本机已登录团队 L5W9FHSX92 的通配 profile（2X9CSZ37SU 未
  登录 Xcode）。构建须带 -allowProvisioningUpdates。
- Goal d867b7b7 仍 active: 三 codec 库已提交；MIDI+SF2 已做成，README 已
  写（SF-0074），**demo 已接 MIDI 并双端构建通过（SF-0075）**；覆盖率 90.20%。

## Task
- Goal: 收尾 d867b7b7——新格式元数据、ICY stop 延迟、Opus 裸流、推送。
- Unit: 框架 tagParser 扩分支；ICY/Opus 代码项；最后推送。
- Done when: 新格式能出 Now Playing 元数据；余项同 Goal d867b7b7。

## Progress
- Done: SF-0073 MIDI+SF2；SF-0074 README；SF-0075 demo 接 MIDI
  （xcodeproj 本地 APlayMidi.framework target、夹具入 Samples、
  TrackLibrary .midi route、DemoPlayer builder 链。详见 full SF-0075）。
- 提交: efce7eb（MIDI 库+README）、ddd3640（demo 接入），均未推。
- 覆盖率: 6 模块 6109/6773 = **90.20%** 达标；swift test 287/287。
- Open: 新格式元数据空分支；Opus 裸流、ICY stop 延迟。
- Checks: 模拟器+真机 xcodebuild APlayDemo Debug 均 BUILD SUCCEEDED；
  APlayMidi.framework 与 melody.mid/APlayTestSine.sf2 已入 app 包。
- Pending: none。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（6 个产品 swift 模块）。
  任一测试失败会使 SwiftPM 不合并 profdata。session 是 let，注入用
  sessionBuilder。ID3Parser 远端 v1 探测闭包持 config unowned。
- 事实: **APlay.xcodeproj 无任何 SPM 包引用——三个 target（APlay/
  APlayExtras/APlayDemo）都是编译本地源的 PBXNativeTarget，与 SPM 包
  平行。**加新可选库的 xcodeproj 镜像须照 APlayExtras 模板建本地
  framework target；三 codec 依赖 vendored C target 故不可镜像。
  ID 段: A5E0A5000000000000002 已用于 APlayMidi（段 0=APlayExtras、
  段 1=demo 新文件、段 3=demo 资源）；空段 4-9 备用。**edit 工具 oldText
  须与 tab 缩进完全一致，用 section 结束标记作锚点最稳。**
  AVAudioUnitSampler loadSoundBankInstrument bankMSB=121(0x79) 才选中
  SF2 bank 0；SF2 sampleID(gen 53) 必须是 zone 内最后一个 generator。
  离线渲染 enableManualRenderingMode(.offline)，结束检测用
  currentPositionInSeconds >= duration + tail。wrapper 须自带 canonical
  ASBD（CoreAudio. 前缀限定 kAudioFormat* 常量）。
  CFNetwork 对 `ICY 200 OK` 剥全部响应头→本机流必须答
  `HTTP/1.1 200 OK`。pbxproj buildFile ID 不可与 fileRef ID 重复。
  tagParser 只接 .mp3(ID3)/.flac；.mid/.ogg/.spx/.wv 元数据空分支。

## Next
- Action: 推送两个本地提交；随后做 ICY stop 延迟（最小项）。
- Verify: git status 与 origin 对齐；swift test 仍 287/287。
- Refs: SF-0075（demo），SF-0074（README），SF-0073（MIDI）。
