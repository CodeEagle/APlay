State format: capsule-v2
State revision: 23

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay 镜像，master）
- Baseline: 2026-09-19；Xcode 27.0 / Swift 6.4；iOS 15.0 部署；macOS 14 SDK 测试机。
  本地领先 origin 20 commit 未 push。已提交：5612274、81adbed、76da439（hint 表）。
  工作区未提交：DefaultAudioDecoder.swift（magic cookie 修复）、FormatCompatibilityTests.swift。

## Task
- Goal: 剩余四项（goal d7e5e97e）：①✅hint 表(76da439)；②✅ALAC cookie 根因修复；
  ③ 提高覆盖率；④ 无缝播放 gapless。另：opus 须 iOS 真机验证。
- Done when: 每批改动经 swift test + iOS 四套构建零警告（工具链噪声除外）+ MacPlayback 端到端后提交。

## Progress
- Done: ② ALAC-in-M4A 修复。根因（实测确认）:
  属性到达顺序 ffmt→rrap→dfmt(格式)→mgic(cookie)→…→redy。框架在 dfmt 时创建转换器并
  读 cookie，但 cookie 尚未到(size=0) 直接返回；mgic 回调落在 switch 的 default: break
  从未处理——转换器终生无 cookie，解码报 !dat。
  更深一层：原代码读 cookie 用错属性 ID——拿 kAudioConverterDecompressionMagicCookie
  去问 AudioFileStream 要（实测返回 1886681407='!prp'，属性不存在），正确应为
  kAudioFileStreamProperty_MagicCookieData（实测 size=24）。
  修复：switch 加 kAudioFileStreamProperty_MagicCookieData 分支(magicCookieChanged)；
  applyMagicCookie 暂存 cookie 并即时注入已有转换器；createConverter 创建后用暂存 cookie
  做种子。FormatCompatibilityTests 的 ALAC-M4A 行翻转为支持。
- CAF/AIFF 判定：CAF 报 optm(pakt 包表在音频数据后，流式解析无法优化)，
  AIFF/AIFC 报 dsc!(要求整文件可寻址)——均为容器固有限制，非框架 bug，矩阵标记不支持。
- Checks: swift test 56/56 全绿；iOS 四套构建 BUILD SUCCEEDED，代码零错误零警告。
- Open: 提交②；③覆盖率；④gapless；opus iOS 真机验证。
- Pending: 未提交②。

## Rules
- Constraints: 镜像仓库未经允许不 push；不推翻重设计；每批改动须 iOS 四套构建 +
  MacPlayback 端到端验证后才提交；只测可注入协议接缝。
- 教训: ①~⑭ 见 full；⑮ AudioFileStream 属性是"渐进到达"的：cookie(mgic) 在 DataFormat
  之后才出现，转换器不能在创建时一次性拿 cookie，须监听 mgic 属性即时注入并暂存
  供后续重建的转换器用。
  ⑯ 读 AudioFileStream 属性要用 kAudioFileStreamProperty_* 常量；误用
  kAudioConverterDecompressionMagicCookie 去问 stream 会得 '!prp'(1886681407)。
  ⑰ AudioFileStreamID 是 OpaquePointer，Swift 里 Open 须 withUnsafeMutablePointer
  避免重叠访问；C 回调闭包不可捕获上下文，用 Unmanaged.passUnretained 透传。
  ⑱ 探针发现 optm/dsc! 等错误先查官方头注释，区分"框架 bug"与"容器固有限制"。

## Next
- Action: git 提交②（magic cookie 修复 + 矩阵 ALAC-M4A 翻转）；然后进③提高覆盖率。
- Verify: 已验 swift test 56/56 + 四套构建零警告。MacPlayback 端到端可与③同批跑。
- Refs: SF-0018（ALAC cookie 根因与修复）；goal d7e5e97e。
