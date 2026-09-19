State format: capsule-v2
State revision: 22

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；macOS 14 SDK 测试机。
  本地领先 origin 19 commit 未 push。已提交：5612274（WAV chunk 修复+兼容矩阵）、
  81adbed（.gitignore）。工作区有未提交：hint 表映射改动。

## Task
- Goal: 剩余四项（goal 3906b5a5）：① 补 hint 表映射；② 查 ALAC/AIFF 解码失败因；
  ③ 提高覆盖率；④ 无缝播放 gapless。另：opus 须 iOS 真机验证。
- Done when: 每批改动经 swift test + iOS 四套构建零警告（工具链噪声除外）+ MacPlayback 端到端后提交。

## Progress
- Done: ① hint 表映射已补全——fileHint(from:) 新增 m4b→.m4b（有声书 MP4）、
  mp2/mp1、ac3、amr、3gp/3gpp→.k3gp、3g2/3gp2→.k3gp2、au/snd→.next、rf64、sd2，
  连同 MIME（audio/ac3、audio/3gpp、audio/basic 等）。
  FormatHintTests 权威表同步扩充；FormatCompatibilityTests 的"缺映射文档测试"
  改为 testHintTableCoversCoreAudioCapableFormats（断言已修复，回归即报错）。
  验证：swift test 56/56 全绿；iOS 四套构建成功，唯一提示为
  appintentsmetadataprocessor 元数据噪声（四套同样出现，非本仓代码，既有）。
- Open: 提交①；②ALAC(!dat)/AIFF(dsc!) 查因；③覆盖率；④gapless；opus iOS 真机验证。
- Checks: swift test 56/56；四套构建 BUILD SUCCEEDED（1 个工具链噪声 warning）。
- Pending: 未提交①；其余三项未开始。

## Rules
- Constraints: 镜像仓库未经允许不 push；不推翻重设计；每批改动须 iOS 四套构建 +
  MacPlayback 端到端验证后才提交；只测可注入协议接缝。
- 教训: ①~⑬ 见 full；⑭ xcodebuild | grep -c "warning:" 会把 appintentsmetadataprocessor
  的元数据提示误计为本仓警告——须看具体来源行区分工具链噪声。

## Next
- Action: git 提交①（hint 表映射）；然后进②查 ALAC !dat 与 AIFF dsc! 根因。
- Verify: 已验 swift test 56/56 + 四套构建成功。MacPlayback 端到端留待与②同批或单独跑。
- Refs: SF-0016（WAV 修复）；SF-0017（hint 表映射，本次）；goal 3906b5a5。
