State format: capsule-v2
State revision: 78

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD c12c613（已推送）。
  v2.1.0 已 tag/Release。
- 真机: lincoln-phone = 00008130-000E7959262B803A (iPhone 15 Pro Max)。
  签名只能用本机已登录团队 L5W9FHSX92 的通配 profile；构建须带
  -allowProvisioningUpdates。
- Goal d867b7b7 仍 active: 三 codec 库 + MIDI 已提交；元数据完成；
  **SF-0078 修了三库「装库即坏其他格式」的高危缺陷**。覆盖率 90.47%。
  余: Opus 裸流（前提不成立，待用户定夺）。

## Task
- Goal: 收尾 d867b7b7。Opus 裸流经评估**前提不成立**（无裸 opus 容器/
  夹具/帧同步标准）；真正的缺口是 Opus-in-WebM/Matroska，非 goal 字面项。
- Unit: 三库 fallback 事件流中继已修 + 测；295/295 全绿。
- Done when: 三库出元数据、不回归其他格式、swift test 全绿（已达成）。

## Progress
- Done: c12c613 元数据（含 WavPack 崩溃真因=timer 早于 _unpackBuffer）。
- Done（SF-0078）: 三 wrapper 照 FileFallbackDecoder 模式中继
  fallback 的 outputStream/inputStream，info/seekable 代理到 fallback，
  `_handedOff` 状态切换；Vorbis 对 OggS+OV_ENOTVORBIS（Opus-in-Ogg）
  交还 fallback，垃圾文件仍报错。
- Done: +5 测试（三库事件/字节中继、Vorbis 的 Opus-in-Ogg 移交、
  mp3 端到端解码）；夹具 tone-opus.ogg。
- Checks: swift test 295/295（20.6s）；覆盖率 90.47%（6 模块）。
- Open: Opus 裸流——评估见 SF-0078：**前提不成立**，改做 Opus-in-WebM
  需 EBML demuxer + libopus vendoring，过大且非 goal 字面项。待用户定夺。
- Pending: 工作区未提交（SF-0078 全部改动 + tone-opus.ogg）。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（6 产品 swift 模块）。
  任一测试失败使 SwiftPM 不合并 profdata。session 是 let，注入用
  sessionBuilder。ID3Parser 闭包持 config unowned。
- 事实: APlay.xcodeproj 无 SPM 包引用——三 target 编译本地源；
  APlayMidi 已按 APlayExtras 模板镜像（ID 段 A5E0A5000000000000002）。
  **可选库 wrapper 必须中继 fallback 的 outputStream/inputStream 并代理
  info/seekable**（样板=APlayExtras/FileFallbackDecoder；SF-0078 教训）。
  **WavPack 计时器须在 _unpackBuffer/_info 就绪后启动**（SF-0077）。
  Vorbis hand-off 只认 "OggS" magic + OV_ENOTVORBIS；否则报 parser error。
  WavpackGetTagItem 不可用（NULL ape_tag_data）→ APEv2 自解析。
  Speex 注释包无 [3]"vorbis" 前缀；ffmpeg libspeex 不写 -metadata。
  Vorbis comment: [3]"vorbis" 前缀(可省)+LE32 vendorLen+vendor+
  count+每条 LE32 len+bytes；字段名大小写不敏感。
  AVAudioUnitSampler bankMSB=121(0x79) 选中 SF2 bank 0；
  CFNetwork 对 `ICY 200 OK` 剥全部响应头→本机流须答
  `HTTP/1.1 200 OK`。tagParser 只接 .mp3(ID3)/.flac。
  本机 ffmpeg 8.0.1 无 libvorbis/libspeex 编码器，**也无裸 opus muxer**；
  ogg 用 `-c:a vorbis -strict -2`；speex 旧夹具靠注入器补标签。
  Core Audio 对 Opus: OGG✅ CAF✅ MP4⚠️('pck?') WebM/Matroska❌。
  edit 工具 oldText 须与缩进(4 空格)完全一致；同文件多 edit 分开发
  （批量中一个失败会回滚整批）。

## Next
- Action: 提交第二批（信息如 "Relay the fallback decoder through the
  optional codec wrappers"）并推送；然后向用户报 Opus 裸流评估结论，
  等其定夺是否改做 Opus-in-WebM 或收尾 goal。
- Verify: 提交后 swift test 仍 295/295；git status clean。
- Refs: SF-0078（fallback 中继+Opus 评估），SF-0077（崩溃真因+元数据）。
