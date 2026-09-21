State format: capsule-v2
State revision: 77

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-21；Xcode 27.0 / Swift 6.4。HEAD 84ec805（已与 origin
  对齐）。v2.1.0 已 tag/Release。
- 真机: lincoln-phone = 00008130-000E7959262B803A (iPhone 15 Pro Max)。
  签名只能用本机已登录团队 L5W9FHSX92 的通配 profile；构建须带
  -allowProvisioningUpdates。
- Goal d867b7b7 仍 active: MIDI+SF2、三 codec 库已提交推送；覆盖率
  90.20%。**新格式元数据已全部完成（含 WavPack 崩溃修复）**；余
  Opus 裸流 + 提交推送。

## Task
- Goal: 收尾 d867b7b7——仅剩 Opus 裸流子库（可选、工作量大）与
  本轮提交推送。
- Unit: 元数据项 Done（三库端到端出 Now Playing 元数据，290 测试全绿）。
- Done when: 三库出元数据 + swift test 全绿（已达成）；Opus 裸流另计。

## Progress
- Done: SF-0073 MIDI+SF2；SF-0075 demo；84ec805 ICY stop；SF-0076 元数据
  三库；**SF-0077 修 WavPack 崩溃真因**（startTimer 在 _unpackBuffer
  分配之前 → timer 立即触发 decodeTick 往空数组写 16KB → 堆破坏；
  非工具链 bug。startTimer 移到 openFile 末尾即愈）。
- Done: Speex 元数据缺口补齐——旧 tone.spx 注释包 fieldCount=0
  （ffmpeg libspeex 忽略 -metadata）；新增 Scripts/inject-speex-comment.py
  重写 Ogg 注释页并重算 CRC（8 页 CRC 复算一致、幂等、音频尾字节相同），
  接入 generate-fixtures.sh（libspeex 守护 + 总是注入）。
- Done: 三 decode 测试加 titles 端到端断言；testParsesFixtureTag 改钉
  脚本前 3 项（实为 4 项，多出 ffmpeg 的 ENCODER）。
- Checks: **swift test 290/290 全绿（20.6s）**，首次跑完整套。
- Open: Opus 裸流（需 vendoring libopus+config.h 与自定帧同步，
  /tmp/codec_probe/opus 源码仍在；优先级低、工作量大）。
- Pending: 工作区未提交（本轮元数据 + 崩溃修复 + Speex 注入 + 夹具）。

## Rules
- Constraints: 覆盖率口径=Scripts/coverage.py（6 产品 swift 模块）。
  任一测试失败使 SwiftPM 不合并 profdata。session 是 let，注入用
  sessionBuilder。ID3Parser 闭包持 config unowned。
- 事实: APlay.xcodeproj 无 SPM 包引用——三 target 编译本地源；
  APlayMidi 已按 APlayExtras 模板镜像（ID 段 A5E0A5000000000000002）。
  **WavPack 计时器须在 _unpackBuffer/_info 就绪后启动**（SF-0077 教训）。
  WavpackGetTagItem 不可用（NULL ape_tag_data 解引用）→ APEv2 自解析。
  Speex 注释包无 [3]"vorbis" 前缀；ffmpeg libspeex 不写 -metadata。
  Vorbis comment: [3]"vorbis" 前缀(可省)+LE32 vendorLen+vendor+
  count+每条 LE32 len+bytes；字段名大小写不敏感。
  AVAudioUnitSampler bankMSB=121(0x79) 选中 SF2 bank 0；
  SF2 sampleID(gen 53) 须为 zone 内最后 generator。
  CFNetwork 对 `ICY 200 OK` 剥全部响应头→本机流须答
  `HTTP/1.1 200 OK`。tagParser 只接 .mp3(ID3)/.flac。
  本机 ffmpeg 8.0.1 无 libvorbis/libspeex 编码器；ogg 用
  `-c:a vorbis -strict -2`；speex 旧夹具靠注入器补标签。
  edit 工具 oldText 须与缩进(4 空格)完全一致；同文件多 edit 分开发。

## Next
- Action: 提交本轮（信息如 "Surface Now Playing metadata from the
  optional codec libraries"），推送；然后评估 Opus 裸流可行性
  （能否造裸 opus 夹具 + vendoring 代价），过大则报用户定夺。
- Verify: 提交后 swift test 仍 290/290；git status clean。
- Refs: SF-0077（崩溃真因+Speex 注入），SF-0076（元数据设计）。
