# APlay — 状态明细 (state-full)

## SF-0001
- Revision: 6
- 取代：无（首条）。旧基线见 state.md revision 5（Swift6 升级三轮提交，75b8299/64937a9/427bc32）。

### 本轮事实（2026-09-19，接续会话 01a0b3fa 的 macOS 验证工作）

起因：上一会话想用 XCTest 在 macOS 做端到端播放验证，`AudioOutputUnitStart` 在 xctest 进程必现
-10867，当时误判为"仅测试环境问题"。改用普通可执行进程后 -10867 依旧 → 是真代码 bug，共找到两处：

1. 本地文件解析失败（`Audio File Unsupported File Type` / `typ?`）
   - 根因：`Streamer._open` 对本地文件在 `CFReadStreamOpen` **之后**才发 `.readyForRead`。
     本地文件一旦 open 立刻可读，runloop 线程抢在 composer 的 `prepare()`（内含
     `AudioFileStreamOpen`）之前把数据往外送，解码器因 `_audioFileStream == nil` 把前 N 个
     8KB 块全丢弃，解析器随后从文件中段开始解析 → typ?。
   - 证据：插桩确认首块送到解析器时已是文件偏移 16384/57344（随机的第 N 块），且全部带
     `DROP (fileStream nil)`；修正后首块回到 `00 00 00 1c 66 74 79 70`(ftyp isom)。
   - 修复：本地路径的 `.readyForRead` 移到 `CFReadStreamOpen` 之前（远程路径在
     `parseHttpHeaders` 内同步触发，无此竞争，保持不动）。

2. 输出单元启动失败 -10867
   - 根因：`APlayer.updatePlayerConfig` 只设 StreamFormat/MaximumFramesPerSlice/SetRenderCallback，
     从不 `AudioUnitInitialize`，`AudioOutputUnitStart` 拒绝启动。
   - 佐证：把回调 scope 从 output 改 input 无效；补 `AudioUnitUninitialize`+`AudioUnitInitialize`
     后立即 PASS。故 scope 非根因，已还原保持原貌。
   - 修复：`AudioUnitUninitialize(unit)` 后 `AudioUnitInitialize(unit)`（setup 可能多次调用）。

3. API 缺陷：`APlay.Event`/`State`/`Error` 为 internal，却被 `public var eventPipeline`/
   `public var state` 引用，二进制框架用户无法消费（APlayDemo 的 ViewControllerB 已在用
   `eventPipeline` 订阅 `.playEnded`）。三者已改 public；关联类型（MetadataParser.Item、
   FlacMetadata、PlayList.LoopPattern、Delegated）本就 public，无外泄。

4. 顺带收尾上一会话未提交的跨平台改动：APlayImage 别名、audio-session/后台任务收进 `#if os(iOS)`、
   删除 pre-iOS-10 的 AVAudioSession+Workaround（deployment 已 15.0）。

### 验证
- `swift run APlayMacPlayback`（普通进程，播 APlayDemo/a.m4a）：Debug 与 Release 均
  duration=137s → .playing → 播放推进 → PASS；并验证 `setEqualizerBandGain` 运行时设置不崩。
- `swift test`：1 个非音频冒烟测试通过（`swift run` 才覆盖音频；xctest 起不了输出单元）。
- iOS Xcode 4 套构建（APlay/APlayDemo × Debug/Release，iOS Simulator）全部 BUILD SUCCEEDED。
  （Demo 签名失败是环境问题，`CODE_SIGNING_ALLOWED=NO` 后通过。）
- `pod spec lint --quick --allow-warnings` 通过。

### 产物
- Package.swift（APlay 库 + APlayMacPlayback 可执行 + APlayTests 冒烟）、MacPlayback/main.swift、
  MacTests/APlaySmokeTests.swift。
- 提交：a56ea1d（两处 bug 修复）、a29f445（跨平台+SPM+public API+1.3.1 文档）。
- 版本 1.3.0 → 1.3.1（APlay.swift / podspec / ChangeLog / README SwiftPM）。

### 教训
- 进程级结论不可轻信：上一会话凭"独立复现正常"断定 -10867 是 xctest 环境问题，实际是真 bug；
  忠实复现漏了 `AudioUnitInitialize` 这一关键差异。差距要用最小变量复现，而非大跨度结论。
- 数据驱动定位：解析器收到的字节 hex 与文件比对（偏移 16384）直接锁定"数据早于解析器就绪"。

## SF-0002
- Revision: 7
- 取代：SF-0001 的"下一步"（当时待 push 5 commit）；现 6 commit，新增阶段0。

### 架构升级 阶段0（2026-09-19，已完成并提交 3622018）

用户指示"先升级整体架构，再看 issue"。阶段 0 = 删死代码/去版本分支：
- 删 APlay/BuildInComponents/Players/AUPlayer.swift（552 行 AUGraph 播放器）及
  project.pbxproj 4 处引用；APlay.swift 的 `if #available(iOS 11.0, *)` 分支改为
  直接 `APlayer(config:)`；APlayer.swift 4 处 `@available(iOS 11.0, *)` 去除、
  `_stateQueue` 名 "AUPlayer.state"→"APlayer.state"；PlayerCompatible.canonical 的
  `if #available(iOS 8.0, *)` bytesPerSample 分支简化。
- 依据：deployment 已 iOS 15.0，iOS<11 回退路径恒不执行；macOS 上 `#available(iOS 11.0,*)`
  因 `*` 亦恒真，AUPlayer 从未被创建。
- 验证：iOS APlay/APlayDemo × Debug/Release 全 BUILD SUCCEEDED；swift build OK；
  swift run APlayMacPlayback 本地端到端 PASS（duration 137s→.playing→推进）。

### issue 现状（gh 查 open，共 4 个）
- #3 (2018) Cannot play HTTP Stream — 未修；README 记 TODO（URLSession 迁移）。
- #10 (2019) Can't play m4a — 远程 m4a，报 "reading empty data back, try to reopen"；
  与 #3 同属网络层。证据：SoundHelix mp3 经 CFStream 播放报 OSStatus -9824
  （SSL 证书链，kCFStreamSSLValidatesCertificateChain 老路径），同 URL curl 200。
- #14 (2019) Preloading 特性请求 — 未修，README 记 TODO。
- #17 (2019) can't play opus — iOS 原生不支持 opus 容器，需注入自定义解码器
  （AudioDecoderCompatible 协议已开放，可外部实现）。
- #19 (2020) Failed to play on iOS14（"CPU usage very high"）— 已由 427bc32
  （解码循环空闲优化）针对性处理，缺真机回归。
- 另：#13 random mode 已由旧提交 242eb78 修复（已闭）。

### 剩余
- 阶段1：Streamer→URLSession + 删 RunloopQueue（RunloopQueue 仅 Streamer 使用）。
- 阶段2：并发现代化，消 64 个 Sendable 告警（Release 构建 grep 计数）。
- 未 push（6 commit 领先 origin）。

## SF-0003
- Revision: 8
- 取代：SF-0002 的"下一步"（阶段1 未动工的状态）；阶段1 设计调研完成，尚未写码。

### 阶段1 迁移设计（Streamer: CFReadStream → URLSession）

**关键发现：Configuration 已自带 `session: URLSession` + `SessionDelegate`（处理 challenge），
并有 `sessionBuilder`/`sessionDelegateBuilder` 注入点（Configuration.swift:23,109-159）。
作者早已开了 URLSession 的头，新 Streamer 应直接用 `config.session`，不必自建会话。**

**保持不变的接缝**：`StreamProviderCompatible` 协议 + `outputPipeline: Delegated<Event, Void>`
+ 事件枚举（readyForRead / hasBytesAvailable(UnsafePointer<UInt8>,UInt32,Bool) /
endEncountered / errorOccurred / metadata / metadataSize / flac / unknown）。
Composer 与上层零改动。

**事件映射（URLSessionDataDelegate）**：
- `didReceive(response:)` → 替代 HttpInfo.parseHttpHeaders：状态码 200/206→readyForRead +
  contentLength（206 需 +position）；401/407→challenge；5xx→startReconnectWatchDog；
  其他→errorOccurred(.networkStatusCode)
- `didReceive(data:)` → ICY 流走 IcyCastInfo.parseICYStream；普通流→
  outputPipeline.call(.hasBytesAvailable)（Data.withUnsafeBytes 出指针）
- `didCompleteWithError:` → endEncountered（远端未读完→重连）/ errorOccurred

**替换对照**：
| 旧 | 新 |
|---|---|
| CFReadStreamCreateWithFile（本地） | URLSession dataTask(file://) |
| CFHTTPMessageCreateRequest（远程） | URLRequest + Range/User-Agent/Icy-MetaData 头 |
| kCFStreamSSL* 老设置（-9824 根因） | URLSession 原生 TLS |
| CFHTTPAuthentication（digest/basic） | config.session 的 SessionDelegate challenge |
| CFRunLoopTimer watchdog 重连 | DispatchSourceTimer |
| RunloopQueue | 删除（仅 Streamer 使用；URLSession 自带 delegateQueue） |
| _isRuning/_canOutputData 门控 | task.suspend()/resume() + 状态门 |

**ICY 决策**：标准 HTTP + `icy-metaint` 头 → 保留 IcyCastInfo 元数据解析（URLSession 支持）；
纯 "ICY 200 OK" 状态行的遗留 Shoutcast → URLSession 无法解析（非标准 HTTP 状态行），
记为已知限制（README/ChangeLog 说明）。普通 HTTP 流（#3/#10 实际场景）必须通。

**保留**：CacheInfo（纯文件缓存，与 CFStream 无关）、IcyCastInfo、Keys 枚举、
HttpInfo 的状态码处理语义（实现改为读 HTTPURLResponse）。

**验收**：iOS 四套构建 SUCCEEDED + MacPlayback 本地端到端 PASS（回归基线）+
**远程端到端 PASS**（之前 -9824 失败；测试源 https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3）。

**风险**：850 行重写易出 bug；须以"本地回归 + 远程新通"双端验证为准，不验证不提交。

## SF-0004
- Revision: 9
- 取代：SF-0003 的阶段1 状态（已落地提交 354b0ce）；记录阶段1 实施偏离决策与阶段2 起点。

### 阶段1 实施偏离设计的地方（SF-0003 → 实际）
1. **不自建会话的计划被推翻**：config.session 的 delegate 在 Configuration 初始化时就已绑定
   （SessionDelegate 或用户注入），Streamer 无法插入 URLSessionDataDelegate。
   实际做法：Streamer 自建 `URLSession(configuration: config.session.configuration,
   delegate: bridge, delegateQueue: nil)`——继承代理/TLS 配置，challenge 在
   SessionDataDelegate 里按 proxyPolicy 转发（与 Configuration.SessionDelegate 同逻辑）。
2. **本地文件不用 URLSession dataTask**：file:// 无 Range/seek 语义，改用 FileHandle 读循环
   （_readQueue + NSLock 保护 _isRunningLocal/_fileHandle），readyForRead 在循环开头先发。
3. **引用环打破**：session 强引用 delegate，故 delegate 是独立 SessionDataDelegate 对象、
   weak 指回 Streamer；init 里先建 session 再回填 `bridge.streamer = self`（否则报
   'self used before all stored properties are initialized'）。
4. **串行化模型**：远程全部状态变更（delegate 回调/watchdog/open/pause/resume/destroy）
   走 `_stateQueue`（bridge._enqueue 转发）；reset() 里的 close 用 sync 保证顺序；
   openRemote 里 `if _isSuspended { task.suspend() }` 保留 pause-then-open 语义。
   本地事件投递在 _readQueue（与旧 runloop 线程语义一致）。
5. HttpInfo 类删除（只剩 bytesRead 一个字段，改 `_bytesRead`）；IcyCastInfo/CacheInfo/Keys 保留。

### 阶段2 起点（并发现代化）
- 目标：消 64 个 Sendable 告警；去 GCDTimer（DefaultAudioDecoder._decodeTimer、APlayer._playbackTimer）。
- 现状共享状态模式：Composer/DefaultAudioDecoder/APlay 都用 `DispatchQueue(concurrentName:)` +
  sync 读 / barrier async 写的属性包装；Streamer 用 _stateQueue 串行化。
- 候选：统一为 `@Locker` 属性包装器，或改 actor（但 StreamProviderCompatible 是 AnyObject
  同步接口，改 actor 会破坏协议，须评估 nonisolated 暴露成本）。
- GCDTimer 替换候选：DispatchSourceTimer（与 Streamer watchdog 统一）或 Task+AsyncStream。
- DefaultAudioDecoder 的 AudioFileStream 回调仍用 UnsafeMutableRawPointer.from(object:)
  Unmanaged 上下文——阶段2 一并处理。

## SF-0005
- Revision: 10
- 取代：SF-0004 的阶段2「起点」状态——批次1 已改完待提交（11 文件，未提交）。

### 阶段2 批次1 已落地（告警 91 → 32 类）
- 机械：APlay.swift 3 处 `public enum` 去冗余 public；AudioFileStreamParseFlags.continuity → `[]`
- Sendable 标注（@unchecked，均已有队列保护或单线程使用）：
  Streamer、Streamer.CacheInfo、Streamer.SessionDataDelegate、APlayer、DefaultAudioDecoder、
  ID3Parser、FlacParser、InternalLogger、AudioDecoder.Info
- 值类型 Sendable：Configuration.ProxyPolicy / ProxyPolicy.Info / AuthenticationScheme
- 内存安全：ID3Parser/FlacParser 的 acceptInput 改为同步 `Data(bytes:count:)` 拷贝后再入 barrier，
  裸指针不再跨异步边界；appendTagData 签名改为收 Data（去掉 memcpy 中转，无额外开销）
- APlayer render 回调 totalReadFrame 改 let 捕获；CacheInfo.writeFile header 快照为 [String:String]
- InternalLogger.reset 的 _openTime 写入并入 _logQueue barrier
- NowPlayingInfo 网络权限回调 unowned→weak

### 阶段2 批次2 剩余 32 类告警清单（去重后实际 16 个代码点）
1. APlay.swift:383/384/387 — `playingStateBeforeInterrupte` 局部 var 在 @Sendable 通知闭包里读写
   （3 处：mutation / reference×2）。改实例属性 + _propertiesQueue 保护。
2. APlay.swift:403 — 捕获 `newValue: PlayList`（class，非 Sendable）；:409 捕获 `newValue: APlay.State`
   （enum 关联 Swift.Error，非 Sendable）。→ 两者标 @unchecked Sendable。
3. DefaultAudioDecoder.swift:25/29 — 捕获 `newValue: DefaultAudioDecoder.Packet?`（:436 final class Packet）；
   :36 捕获 `newValue: AudioConverterRef?`（OpaquePointer，无法 Sendable）。
   → Packet: @unchecked Sendable；OpaquePointer 用 nonisolated(unsafe) 局部捕获。
4. Streamer.swift:356 — `_enqueue` 的 `block: (Streamer) -> Void` 非 Sendable。先试 @Sendable；
   若 completionHandler（URLSession.ResponseDisposition 回调）非 Sendable 则改存 nonisolated(unsafe)。
5. Configuration.swift:181/197/221 — MainActor 隔离的 `AVAudioSession.shared`、`UIDevice.current.systemVersion`、
   `UIApplication.shared` 在 nonisolated 上下文引用。→ MainActor.assumeIsolated 包裹（调用方实际都在
   主线程：Configuration() 与 Composer.play→startBackgroundTask 均自主线程发起）；文档注明。
6. Configuration.swift:174 — `.longForm` 弃用 → `.longFormAudio`。
7. NowPlayingInfo.swift:48 — `MPMediaItemArtwork(image:)` 弃用 → `boundsSize:requestHandler:`。
8. NowPlayingInfo.swift:77 — 外层 `DispatchQueue.global().async` 仍隐式强捕获 self，内层已 weak；
   外层补 `[weak self]`。
9. appintentsmetadataprocessor 无关警告 ×1（忽略）。

### 阶段2 尚未做的子项
- GCDTimer 替换（APlayer._playbackTimer、DefaultAudioDecoder._decodeTimer）——GCDTimer 已是
  DispatchSourceTimer 封装，主要是 callback 闭包捕获 self 告警（批次1 的 @unchecked 已覆盖多数），
  是否彻底替换待评估。
- DefaultAudioDecoder 的 AudioFileStream 回调仍用 UnsafeMutableRawPointer.from(object:) Unmanaged 上下文
  （AudioFileStreamOpen 的 userData）——AudioToolbox C API 要求 raw pointer，需用 Unmanaged 保留；
  可行方案是把回调上下文包成一个小 Sendable 容器再用 Unmanaged.passUnretained，但本质仍是 raw pointer，
  收益有限，优先级可降。

## SF-0006
- Revision: 11
- 取代：SF-0005 的批次2 待办清单——**已全部完成并提交（a51fc8a），iOS 四套构建零警告**。

### 阶段2 完结状态
- 提交链：719acfb（批次1，91→32）+ a51fc8a（批次2，32→0）。
- 关键经验：macOS/SPM 与 iOS SDK 的 Sendable 标注不一致——`URLSession` response 的
  completionHandler 在 iOS SDK 侧不是 Sendable，导致 `_enqueue` 的 `@Sendable` 标注只在
  iOS 构建报错（macOS 通过）。解法：回退 @Sendable，改 `nonisolated(unsafe) let captured`
  （block 入串行队列、一次性调用，安全）。**结论：iOS 四套构建是唯一可信验证**。
- nonisolated(unsafe) 的两处合法用途（OpaquePointer 所有权转移、跨 SDK 非 Sendable 回调）：
  DefaultAudioDecoder._audioConverter 的 set；Streamer._enqueue。

### 阶段2 两个「可做可不做」子项的结论（均不改）
- GCDTimer：本身已是 DispatchSourceTimer 的薄封装，状态有 _stateQueue 保护；其 callback
  捕获 self 的告警已由批次1 的 @unchecked Sendable 覆盖。彻底替换为 Task+AsyncStream 会
  改动解码/播放定时节奏，风险 > 收益。**保留**。
- AudioFileStream Unmanaged 上下文：AudioToolbox C API（AudioFileStreamOpen 的 userData）
  硬性要求 raw pointer，Unmanaged.passUnretained 是唯一合法桥接，无法消除。**保留**。

### 阶段3 设计要点（待实施）
- 测试接缝：全部内部组件已通过协议 + builder 注入（Configuration.streamerBuilder /
  audioDecoderBuilder / metadataParserBuilder / sessionBuilder / loggerBuilder），
  单元测试可用假实现替换真实网络/音频组件。
- 建议目录：MacTests/（SPM testTarget APlayTests 已存在，Package.swift 指向 MacTests）。
  注意 iOS 专属代码（AVAudioSession/UIApplication/NowPlayingInfo）在 macOS 测试里不可用，
  需 #if os(iOS) 隔离或只测跨平台核心。
- 优先级：Uroboros（纯逻辑，最好测）→ PlayList（循环模式状态机）→ ID3Parser/FlacParser
  （喂固定字节序列断言元数据）→ Streamer 本地 FileHandle 路径（远程需网络，放 e2e）→
  Composer 协调（fake StreamProviderCompatible 驱动事件序列断言）。
- issue 钩子：#17 opus 注入式解码 → audioDecoderBuilder 注入假解码器，断言协议交互；
  #14 prepare(_:) → 新增 API 后单测「预加载不启动输出单元」。

## SF-0007
- Revision: 12
- 取代：SF-0006 的阶段3 设计要点——已完成两批测试（23 用例）并提交（42326b1, d4a8d44）。

### 阶段3 已落地（23 用例，swift test 全过）
- Uroboros 7 例：空读、roundtrip、部分读保留剩余、绕回保序（memcpy 易错点）、
  首包标志仅一次、clear 恢复全部空间、commitRead:false 的 peek 不推进。
- PlayList 7 例：changeList 设索引与 currentList；order 顺序循环绕回；single 重复**当前**曲
  （注意：不是推进到下一首，初次 nextURL 返回 playingIndex 所指）；stopWhenAllPlayed
  末首后返回 nil；previous 在 index 0 绕到末首；random 保集合不变；play(at:) 越界返回 nil。
- MetadataParserTests 2 例：FlacParser 喂手搓 "fLaC"+STREAMINFO，断言 sampleRate 44100 /
  channels 2 / bps 16 / totalSamples 1000 / md5 hex；ID3Parser 非 ID3 字节不产出不崩。
- ComposerCoordinationTests 7 例：fake 三件套走 Configuration 的 streamerBuilder /
  audioDecoderBuilder 注入；驱动 readyForRead→hasBytesAvailable→endEncountered/error；
  断言 prepare 传入的 provider 身份、packet 字节、buffering 转发、destroy 拆除、
  pause/resume 传播。

### 测试基础设施经验（后续批次复用）
- `@testable import APlay` 可访问 internal（Composer/ID3Parser/FlacParser/PlayList）；
  Package.swift 的 testTarget 依赖 APlay target，无需改。
- **unowned 陷阱**：Composer._config 与 PlayList._pipeline 是 unowned，测试必须让
  Configuration 实例与 Delegated pipeline 的生命周期覆盖被测对象（Harness struct 持有 config；
  每个测试方法内持有 pipeline 局部常量）。否则跨方法延迟调用时悬空崩溃。
- Composer.play() 会先 decoder.resume() 一次（唤醒解码器），断言 resume 计数要 +1 基线。
- Delegated 的 delegate(to:with:) 是 class 方法，协议只需 get outputPipeline 即可被外部接线。
- XCTest 无 XCTAssertSameObject；用 `(x as AnyObject) === y`。APlay.Error 非 Equatable，
  用 guard case 模式匹配。

### 阶段3 剩余与 issue 落地路径
- Streamer 本地单测（未做）：写 tmp 文件 → Configuration(streamerBuilder: 用真实 Streamer)
  → 断言 readyForRead/hasBytesAvailable/endEncountered 序列与 position/bytesRead。
  FileHandle 路径无音频依赖，可直接在 swift test 跑（远程路径仍由 MacPlayback e2e 覆盖）。
- issue #14 prepare(_:)：APlay/Composer 需新增「预加载（缓冲不启动输出单元）」API。
  设计要点：复用 Composer.play 的 streamer open + decoder prepare 链路，但不 _player.resume()，
  也不设 0.5s asyncAfter 唤醒；对外暴露 prepare(url) 后再 play(url) 时复用已缓冲的 ring buffer。
- issue #17 opus 注入式解码：AudioFileType.opus 已定义；DefaultAudioDecoder 走 AudioFileStream
  的 opus hint。注入式解码 = 允许外部传 AudioFileTypeID 与自定义解码器（audioDecoderBuilder
  已具备注入能力，测试可用假解码器断言「hint 透传到 builder」）。

## SF-0008
- Revision: 13
- 取代：SF-0007 的「阶段3 剩余」——Streamer 本地单测已完成（6705019），并修了一个真实竞态。

### 6705019 的两件事
1. **StreamerLocalTests 6 例**（swift test 直接跑，FileHandle 路径无音频依赖）：
   全量按序投递、首包标志仅一次、contentLength/bufferingProgress、mid-file open 跳过前导字节、
   destroy 后可重开并完整投递、连续 open 报 .openedAlready。
2. **修复单开竞态**：新 Streamer 的 _open 在 _stateQueue 上异步执行，open() 的旧 guard
   （_task == nil && _fileHandle == nil）在第二次 open() 到达时仍为 true（异步 _open 尚未
   创建 task）→ 放行两次 open。改为：open() 入口同步置 _isOpened=true；close() 不动该标志
   （reset 内部的 close 与重连路径的 close 都不应释放单开占用）；destroy() 同步清 _isOpened
   （使 destroy 后立即 open 不被拒绝，teardown 本体仍 async）。

### 本轮四条教训（复用）
- hasBytesAvailable 的 UnsafePointer 仅在 outputPipeline.call 同步调用期间有效；事件收集器
  必须在委托闭包内拷贝成 [UInt8]。延迟解引用表现为「垃圾字节 + 后段零填充」。
- 异步状态机的外部入口 guard 不能依赖异步产出的状态（_task/_fileHandle），须用入口同步标志。
- 时序型断言（sleep 一会儿后 destroy 期望数据未读完）在本地 SSD 上不可靠——改确定性断言。
- Composer/PlayList/Streamer 均对 config/pipeline 用 unowned，测试须持有其生命周期。

### issue #14 / #17 落地设计（下一批）
- #14 prepare(_:)：APlay 层加 `func prepare(_ url: URL)`，内部复用 createComposer +
  Composer.play 链路但抑制输出启动——Composer 需要「仅缓冲」模式（不 _player.resume()、
  不安排 0.5s asyncAfter 唤醒、eventPipeline 只投 buffering/seekable/metadata，不投 state）。
  随后 play(url) 命中已缓冲的 ring buffer 直接开播。单测断言：prepare 后 decoder.prepareCalled、
  player.resumeCount==0、ringBuffer 有数据；再 play 后 state==.playing。
- #17 opus 注入式解码：AudioFileType.opus 已存在；外部经 Configuration.audioDecoderBuilder
  注入自定义解码器即可（无需改 DefaultAudioDecoder）。单测：喂 .opus 的 URLInfo，断言
  builder 收到的 fileHint == .opus，且注入的假解码器被实例化并收到数据。

## SF-0009
- Revision: 14
- 取代：SF-0008 的「issue #14 落地设计」——#14 已实现并提交（d3e1226）；顺带修了三类 deinit 死锁。

### d3e1226 内容
1. **issue #14 prepare(_:)**：`APlay.prepare(url)` → `_play(url, autoplay:false)`；`Composer.play`
   增 `autoplay` 参数——为 false 时不安排 0.5s asyncAfter 唤醒、不 resume 输出单元，置
   `isPreloading=true`；新增 `Composer.startPlayback()`（guard isPreloading → 清标志 + resume）。
   `APlay.play(url)` 命中 `_currentComposer.url == u && isPreloading` 时调 startPlayback 复用已缓冲
   的 ring buffer，否则走旧 destroy+重开链路；不同 url 正常重开。
2. **deinit 自锁修复（真实可达 bug，本轮新教训）**：APlay/InternalLogger/GCDTimer 的 deinit 都
   对「自己的属性队列」做 `sync`。当最后一个引用恰在该队列上的 block 里被释放（block 销毁触发
   ARC release → deinit 就在队列线程跑），deinit 里再 sync 同一队列 = GDB 立即 trap
   （EXC_BREAKPOINT/SIGTRAP，`__DISPATCH_WAIT_FOR_QUEUE__`）。现象：单测全过但进程退出时崩。
   正解：deinit 对 self 有独占访问（待执行/执行中的 barrier block 都捕获 self，必使其无法
   deinit），故直接读写后备存储即可，无需也不应再跳队列。三处统一这么改。
   附带：Composer.play 的 0.5s 延迟闭包改 [weak self]（_player 本就 weak，避免拆链后空转持有）。
3. **测试**：新增 APlayPrepareTests（同 url 复用 / 异 url 重开 2 例）+ ComposerCoordinationTests
   3 例（isPreloading 状态、resumeCount==0、startPlayback 精确一次 resume、非预载时 no-op）；
   FakeStreamProvider.open 现在回填 info 使 `composer.url` 与请求 url 一致。
   **swift test 34/34**（连跑 3 次稳定，EXIT=0）；iOS 四套构建零警告；
   MacPlayback 本地 PASS(2.0s/137s) + 远程 PASS(2.0s/372s)。

### 下一步（不变 SF-0008 尾段的设计，仅顺序）
- issue #17 opus 注入式解码（AudioFileType.opus 已存在；经 audioDecoderBuilder 注入假解码器，
  断言 fileHint==.opus 透传）。
- 随后更新 README Todo（删 #14 项）与 ChangeLog。

## SF-0010
- Revision: 15
- 取代：SF-0008/SF-0009 的「下一步」——issue #17 测试已加，README/ChangeLog 已更新（a227187）。

### a227187 内容
1. **issue #17 落地（验证而非新代码）**：AudioDecoderBuilder 只收 config，解码器在
   `prepareParser`/`prepare(for:at:)` 时从 `provider.info.fileHint` 取类型——注入缝对 opus 本就
   完整，框架零改动。单测 `testOpusHintReachesTheInjectedDecoder`：makeHarness 增 `fileHint`
   参数预置 `streamer.info = .remote(url, .opus)`；FakeStreamProvider.open 改为
   `info = .remote(url, info.fileHint)`（回填 url 同时保留测试配的 hint，不再硬编码 .mp3）；
   FakeDecoder 增 `prepareFileHints` 记录 prepare 时观察到的 hint。断言 prepare 后 == [.opus]。
2. **文档**：README 删 #14 todo、Features 增 prepare(_) 条目、#17 重表述为「注入缝已验证，
   缺的是自带参考实现」；ChangeLog 增 v1.4.0 段（prepare_/deinit 死锁/Streamer 单开竞态/
   opus 注入/35 测试套件）。
3. **验证**：swift test 35/35（EXIT=0）；iOS 四套构建零警告；
   MacPlayback 本地 PASS(2.0s/137s) + 远程 PASS(1.7s/372s)。

### 三步任务收尾
- 阶段1（现代架构）→ 阶段2（零警告）→ 阶段3（35 例单测 + #14/#17）全部完成并提交。
- 仓库领先 origin 14 commit，均为本地验证后提交；镜像未经允许不 push（用户未要求）。
- 遗留（非本任务）：AirPlay2（另分支）、EQ 预设管理、opus 参考解码器实现（注入缝已就绪）。

## SF-0011
- Revision: 16
- 取代：SF-0010 的版本一致性描述——podspec/README 已对齐 1.4.0（c445a54）。

### c445a54 内容（一致性收尾）
- ChangeLog 已有 v1.4.0，但 podspec 仍声明 1.3.1、README SPM 示例仍 `from: "1.3.1"`；
  统一为 1.4.0。`pod spec lint APlay.podspec` 通过（podspec 用 `APlay/**/*` 通配，
  阶段0/1 删文件后无失效引用）。swift test 35/35；iOS 四套构建零警告；端到端双 PASS。
- 补验 APlayDemo（Debug/iphonesimulator）：BUILD SUCCEEDED，零错误零警告——此前各轮只构了
  APlay scheme。至此 Unit 全体（framework + Demo + MacTests + Package + podspec + 文档）齐验。
- 遗留不变：opus 参考解码器实现 / EQ 预设 / AirPlay2（另分支）均需用户明示才动。

## SF-0012
- Revision: 17
- 取代：SF-0011 的「版本对齐 1.4.0」——用户改为 **2.0.0**（6a497f2）。

### 6a497f2 内容
- 用户明示改 2.0.0：现代化不与 0.x 线兼容（部署目标 iOS 15、删 pre-iOS-11 AUGraph player 与
  CFStream/RunloopQueue 栈），应为 major 而非 1.4.0。
- 五处全改：`APlay.version` 常量（此前竟仍为 1.3.1，属遗漏）、APlaySmokeTests 的版本断言、
  podspec、README SPM `from:`、ChangeLog 头（v2.0.0 段加一句说明 major 缘由并把 v1.3.x 指为
  同一现代化的迁移步骤）。ChangeLog 保留 v1.3.1/v1.3.0 历史头不动。
- 验证：pod spec lint 通过；swift test 35/35；iOS 四套构建零警告；端到端本地 PASS + 远程 PASS。
- 教训⑧：改版本号须同时查「代码内版本常量 + 其断言 + podspec + 包管理示例 + changelog」，
  本次发现 APlay.version 常量漏更（停在 1.3.1）——grep 静态字符串而非只看 podspec。

## SF-0013
- Revision: 18
- 取代：无（新事实）。用户布置三项任务（goal 91d151ff）：多格式兼容性测试、提高覆盖率、无缝播放。
- 已完成：fixture 矩阵生成。Scripts/generate-fixtures.sh（ffmpeg 8.0.1）产出
  tone-cbr.mp3/tone-vbr.mp3/tone.m4a/tone-alac.m4a/tone.aac/tone.wav/tone.aiff/tone.caf/tone.flac/tone.opus；
  Scripts/generate-aifc.py 造 tone.aifc（ffmpeg 无 aifc muxer，自造 FORM AIFC + FVER + COMM twos + SSND）。
  ffprobe 全部可识别。a.m4a 保留。全部未提交。
- 未竟：兼容性测试、覆盖率提升、gapless 均未动工。
- 关键：gapless 断口在 APlay.checkPlayEnded→pauseAll→next()→重建 Composer（autoplay 0.5s resume）；
  可用已有 prepare(autoplay:false)+startPlayback() 预加载缝 + 2MB Uroboros ringBuffer 消除断口。

## SF-0014
- Revision: 19
- 取代 SF-0013 的进度描述（任务推进：fixture→harness→兼容性测试）。
- 已完成：抽共享测试基础设施 MacTests/DecoderTestHarness.swift（OutputCollector/feed/
  attach/waitForDecodedBytes/fixture 加载，持有 unowned config）；DefaultAudioDecoderTests.swift
  改用 harness（删私有 OutputCollector/config/feed，保留转发包装）。
- 验证：swift build --build-tests 零错误零警告；swift test 53/53 全绿（3.47s）。
- 未竟：FormatCompatibilityTests.swift 未写（harness 就绪）；覆盖率未提升；gapless 未动工。
- 教训新增 ⑩：抽 harness 删私有 feed/fixtureURL 时，测试类内直接调用处编译失败，
  须保留转发包装；fixtureURL 改 throwing 后调用处须 try!。

## SF-0015
- Revision: 20
- 取代 SF-0014 的兼容性"预期"描述——实测数据已出，预期被推翻。
- 实测工具：MacTests/FormatProbeTests.swift（临时诊断，打印 format/sr/decoded/错误码计数）。
  对照件：ffmpeg 生成 + afconvert 生成（区分"文件古怪"与"框架不支持"）。
- 【实测矩阵 @ arm64e-apple-macos14.0（macOS 14 SDK）】
  解析+解码成功：MP3(CBR/VBR)、AAC-in-M4A、AAC-ADTS、FLAC、**Opus-in-OGG**（format=opus
    sr=48000 decoded=8192 errs=0——Core Audio 此平台有 opus 流解析器，issue #17 假设被推翻！）
  解析成功但解码失败：ALAC-in-M4A（!dat=kAudioCodecUnsupportedFormatError×50）、
    ALAC-in-CAF（!dat×50 / optm）、AIFF-PCM（dsc!=DiscontinuityCantRecover×12，0 PCM）、
    AIFC-PCM（afconvert: dsc!×12；自造 AIFC 完全不解析 format=''）
  完全不解析：WAV 带 LIST(ffmpeg)/FLLR(afconvert) 额外 chunk 的真实文件——
    【框架真 bug】parserWaveFile 硬编码 offset 36/38 找 'data'，真实文件 fmt 后插了
    LIST/FLLR 块导致 'data' 位置后移；44/46 假设仅对最简 WAV 成立。
  hint 表缺映射（落回 .mp3→失败）：m4b/ac3/amr/3gp/3g2/mp2/mp1/au/snd/rf64/sd2
    （AudioFileType 已声明但 fileHint(from:) 不映射）。
- 【最小代价分析】
  1) WAV chunk 遍历改 parserWaveFile：零依赖，遍历 RIFF 子块定位 'data'，支持所有 WAV 变体。
  2) hint 表补容器映射（m4b→m4a 等）：一行代码，Core Audio 已能解析。
  3) ALAC/AIFF/AIFC 失败要查因（疑似 parseFlags 首包 .discontinuity 误传 / ALAC magic cookie
     或声道数），属"声明支持但实测坏"，小修可能。
  4) Vorbis/WMA/APE/WV/TTA/DSD：Core Audio 无，须引第三方解码库，代价高，走 issue #17 注入缝。
- 未竟：FormatCompatibilityTests 的断言要按实测真相改写（opus 改支持、WAV/ALAC/AIFF 标真况）；
  删 FormatProbeTests；修 WAV chunk bug。

## SF-0016
- Revision: 21
- 取代 SF-0015 的 WAV 结论（bug 已修，矩阵中 WAV 从"不支持"变为支持）。
- 修复：DefaultAudioDecoder.parserWaveFile 改为遍历 RIFF chunk 定位 'data'。
  旧逻辑硬编码 offset 36/38（subchunk1Size==18 走 38），真实文件在 fmt 后插了
  LIST/INFO(ffmpeg) 或 FLLR(afconvert) 块，'data' 位置后移 → 完全不解析 errs=12。
  新逻辑：从 offset 12 起逐块 [tag(4)][size(4)][body]，非 data 块按 size+奇数对齐跳过；
  dataOffset=命中处+8；size 字段在 dataOffset-4（初版误从 dataOffset 读 size 导致旧测试失败）。
- 验证：swift test 57/57 全绿（新增 4：矩阵 3 方法 + WAV 两种变体）；
  iOS 四套构建（iphoneos/iphonesimulator × Debug/Release）BUILD SUCCEEDED 零警告零错误。
- 教训 ⑫：data chunk 布局 [tag][size][payload]，size 在 payload-4。
  ⑬：本仓库无 xcworkspace，构建用 APlay.xcodeproj -scheme APlay；-quiet 会吞 BUILD 行。
- 未竟：FormatProbeTests 待删；本批待提交；hint 表映射/ALAC/AIFF 查因/覆盖率/gapless 未做。

## SF-0017
- Revision: 22
- 取代 SF-0016 的 hint 表结论（空缺已补全）。
- 修复：StreamProvider.URLInfo.fileHint(from:) 新增映射——m4b→.m4b（有声书 MP4 容器）、
  mp2→.mp2、mp1→.mp1、ac3/audio/ac3→.ac3、amr→.amr、3gp/3gpp/audio/3gpp→.k3gp、
  3g2/3gp2/audio/3gpp2→.k3gp2、au/snd/audio/basic→.next、rf64→.rf64、sd2→.soundDesigner2。
  这些 AudioFileType 早有声明，但扩展名不映射导致落回 .mp3 而 Core Audio 拒绝解析。
- 测试：FormatHintTests 权威表同步扩充；FormatCompatibilityTests 的
  testHintTableGapsForCoreAudioCapableFormats 改为 testHintTableCoversCoreAudioCapableFormats
  （原断言"落回 mp3"是记录空缺，现改为断言已映射）。
- 验证：swift test 56/56 全绿；iOS 四套构建 BUILD SUCCEEDED。
  唯一提示 appintentsmetadataprocessor 元数据 warning，四套同样出现，属 Xcode 工具链
  既有噪声，非本仓代码（教训⑭：grep -c warning 会误计，须看来源）。
- 未竟：本批待提交；②ALAC/AIFF 查因；③覆盖率；④gapless；opus iOS 真机验证。

## SF-0018
- Revision: 23
- 取代 SF-0017 的 ALAC 结论（根因找到并修复）。
- 根因（实测三重证据）:
  1) 属性到达顺序：ffmt→rrap→dfmt→mgic→flst→bcnt→pcnt→psze→doff→redy。
     框架在 dfmt(DataFormat) 时 createConverter 并读 cookie，但 mgic(cookie) 尚未到达
     (size=0)，guard 直接 return；mgic 属性回调落在 switch 的 default: break 从未处理。
     转换器终生无 cookie → 解码 !dat=kAudioCodecUnsupportedFormatError ×170。
  2) 更深：读 cookie 用错属性 ID——拿 kAudioConverterDecompressionMagicCookie 去问
     AudioFileStream，实测返回 1886681407='!prp'(属性不存在)；正确常量是
     kAudioFileStreamProperty_MagicCookieData(实测 size=24)。
  3) 探针直接验证 AudioConverterNew + setCookie 均 status=0，确认转换器本身可建。
- 修复：propertyValueCallback switch 加 case kAudioFileStreamProperty_MagicCookieData
  → magicCookieChanged()；新增 applyMagicCookie(data)（暂存 + 即时注入已有转换器）；
  createConverter 创建新转换器后用 _magicCookie 做种子；createConverter 内的属性读取
  改用正确常量并去掉错误路径下的误报 error 事件。
- 结果：ALAC-in-M4A 从"仅解析"翻转为"完全支持"，56/56 全绿，四套构建零警告。
- CAF/AIFF 判定为容器固有限制（非框架 bug）: CAF 的 pakt 包表在音频数据后→optm；
  AIFF/AIFC-PCM 要求整文件可寻址→dsc!。矩阵按不支持记录并注明原因。
- 教训 ⑮⑯⑰⑱（属性渐进到达/属性常量别混用/OpaquePointer 与 C 回调穿法/先查官方头注释）。
- 未竟：本批待提交；③覆盖率；④gapless；opus iOS 真机验证。

## SF-0019
- Revision: 24
- 取代 SF-0016 的覆盖率旧口径（重新实测，含 Vendor）。
- 实测命令：swift test --enable-code-coverage；
  xcrun llvm-cov report -instr-profile=.build/out/Products/Debug/codecov/default.profdata \
  .build/out/Products/Debug/APlayTests.xctest/Contents/MacOS/APlayTests \
  -ignore-filename-regex=".build|MacTests|MacPlayback"
- 结果 TOTAL 53.00%（行）。缺口排序（未覆盖行数）:
  Streamer 24.98%/751、ID3Parser 24.54%/289、APlay.swift 45.37%/230、
  FlacParser 37.27%/207、Composer 47.68%/169、NowPlayingInfo 31.75%/86、
  APlayer 67.36%/63、Configuration 66.01%/52、Delegated 46.67%/32、
  DefaultAudioDecoder 89.29%/80。
- 教训 ⑲⑳（profdata 位置/静态库用 xctest+ignore-regex；llvm-cov 输出排序用 -t'%' -k1）。
- 未竟：③ 补测试未开始；④gapless 未做；opus iOS 真机验证未做。

## SF-0020
- Revision: 25
- 取代 SF-0019 的③进度（基线已定，现有本地测试已摸清）。
- 已读 StreamerLocalTests（6 例，本地路径覆盖良好）：全量投递+EOF、首包标志仅一次、
  contentLength/bufferingProgress、open(at:) 定位、destroy 后可重开、二次 open 拒绝。
- 结论：Streamer 24.98% 的缺口主要在**远程/缓存/ICY/看门狗**分支，非本地读循环。
- 教训 ⑳：llvm-cov -show-functions 别叠加复杂 awk，先看原始全表。
- 未竟：③ 远程分支测试未动笔；④gapless；opus iOS 真机验证。

## SF-0021
- Revision: 26
- 取代 SF-0020 的③进度（注入路径已定）。
- 摸清 Configuration 接缝：session: public let URLSession；另有 sessionBuilder
  闭包可注入自定义会话。但 Streamer.init 用 URLSession(configuration:config.session.configuration,
  delegate:bridge, delegateQueue:nil) 自建会话——只继承配置，不继承 delegate/协议类实例。
- 结论：远程分支测试不可直接注入 URLSession 实例；官方可行路径是
  URLSessionConfiguration.protocolClasses 挂自定义 URLProtocol 拦截请求（无真实网络），
  networkPolicy.requestPermission 控制权限分支。
- 远程处理落点（待测）: handle(response:) 处理 200/206（contentLength+position）、
  401/407 与 5xx（startReconnectWatchDog）、其他码（networkStatusCode 错误）；
  ICY 识别在 icy-metaint/icy-notice1；缓存落盘在 handleEndEncountered→CacheInfo.writeFile
  （条件 _fileWritten==targetLength，且经 httpFileCompletionValidator 校验）。
- 教训 ㉑：grep 源码路径不要带 APlay/APlay/ 前缀（实际是 APlay/BuildInComponents/...）。
- 未竟：StreamerCoverageTests 未动笔；④gapless；opus iOS 真机验证。

## SF-0022
- Revision: 27
- 取代 SF-0021 的③进度（接口已定位，代码未动笔——预算中断点）。
- 已定位 Configuration 接口行号:
  HttpFileValidationPolicy(246, 默认 .notValidate)、networkPolicy(46, 默认 .noRestrict,
  其 requestPermission 在 313)、CachePolicy(289)、CacheFileNamingPolicy.name(for:)(267)。
- 实现方案（下次直接照写）: Configuration(sessionBuilder: { proxyPolicy in
  URLSession(configuration: 挂自定义 URLProtocol 的 config) })；
  Streamer 继承 config.session.configuration 自建会话，故 protocolClasses 生效。
  URLProtocol.canInit(with:) 过滤目标 URL，startLoading 喂 HTTPURLResponse(url:statusCode:headerFields:)
  + Data，client?.urlProtocoldidLoad... 完成回调。
- 未竟：StreamerCoverageTests 未动笔；④gapless；opus iOS 真机验证。

## SF-0023
- Revision: 28
- ③ 完成：StreamerCoverageTests.swift（8 测试）已提交 82051c0。
  覆盖率实测（swift test --enable-code-coverage + llvm-cov，口径同 SF-0019）:
  TOTAL 行 53.00%→59.81%；Streamer 24.98%→51.75%；ID3Parser 24.54%→27.68%。
- 8 个测试: 200 全 body+contentLength+不重连、Content-Type 覆盖 URL 扩展名、
  206 contentLength+position、404→.networkStatusCode(404)、500 现状钉定、
  icy-name→.metadata(.title)、完整响应落盘缓存、截断流断点续传（200 短 body→
  看门狗 0.5s 后 _open(at:1000) 带 Range bytes=1000-→206 补齐）。
- 关键设计（照此维护）: FakeServerProtocol 按 Range 头分流——ID3Parser 的
  bytes=-128 探测（processingID3V1FromRemote 复用 config.session）单回 128 字节
  不消耗队列；否则队列顺序消费。空 body 不发 didLoad（URLSession 对空 body
  不调 didReceive(data:)，否则 handle(data:) 的 reset() 会中去看门狗）。
  静态计数器全部经 NSLock（协议线程 vs 主线程读）。会话由 sessionBuilder 注入
  挂 protocolClasses 的 ephemeral config；Streamer 重建会话时继承该 configuration。
  Collector 补 .metadata case（StreamerLocalTests.swift +2 行）。
- 验证: swift test 64/64（连跑 8 次 EXIT=0）；iOS 8 套构建（APlay/APlayDemo ×
  iphoneos/iphonesimulator × Debug/Release，CODE_SIGNING_ALLOWED=NO）全 BUILD
  SUCCEEDED，零编译警告（仅 appintentsmetadataprocessor 与 destination 提示，
  属工具链噪声）；swift run APlayMacPlayback 端到端 PASS（137s，.playing，推进）。
- 新发现缺陷（open，未改产品代码）: 首个请求返回 5xx（空 body）时，
  handle(response:) 里 startReconnectWatchDog 挂的看门狗会被随后的
  handleEndEncountered 的 else 分支 _watchDogInfo.reset() 中和 → 不重连，
  直接投递 .endEncountered 并写 0 字节缓存文件（404 亦然：先 .errorOccurred
  再 .endEncountered）。已被 testRemote500CurrentlyEndsTheStream 钉住。
  最小修法（待用户定夺）: handleEndEncountered 的 else 分支与 handle(data:) 的
  reset() 仅在当前响应非 5xx 时执行；5xx 保留看门狗到 maxRemoteStreamOpenRetry
  后报 .reachMaxRetryTime。注意流中途 5xx（contentLength 已建立）走第一个分支，
  能正常重连——只有初始错误路径是死的。
- 未竟: ④gapless；opus iOS 真机验证；上面的 5xx 缺陷。

## SF-0024
- Revision: 29
- ④ gapless 前置已提交 f946759: ① APlay player 注入接缝；② 编排层测试（回归网）；
  ③ 修掉 streamer 测试的 tearDown 野读崩溃。
- 接缝取舍: 原打算像 streamerBuilder 一样在 Configuration 加 public playerBuilder，
  但 PlayerCompatible 是 internal（readClosure 是原始指针闭包，且关联 internal 的
  Player/Player.Event/Player.canonical），public 化会连带暴露一堆内部类型。
  改用 APlay 的 internal 指定初始化器 init(player:configuration:)，public init 降为
  convenience 委派之——公共面零变化，@testable 测试可见。
- APlayOrchestrationTests（6 测试，复用 ComposerCoordinationTests 的三个 fake）:
  播列表开第一轨、prepare→play 复用预加载 composer（不重开流、resume 一次）、
  URL 不同则重建、曲终 pauseAll→.playEnded→next()→重建（老 composer destroy、
  player setup 两次）、next() 重建、seek 重建。
  变异验证: 删 pauseAll 里的 next() 立刻 4 条断言失败——测试敏感。
- 崩溃根因（修了）: tearDown 里 streamer?.destroy() 把 close 派发到 _stateQueue 且
  强捕获 self，close 经 unowned _config 读配置；随后 streamer=nil、config=nil 使
  config 先于该块被释放 → "Attempted to read an unowned reference" 野读（约 1/5 概率）。
  修法: destroy 后 RunLoop 转 50ms 让队列排空，再释放两者（StreamerLocalTests 同构同修）。
  修后 12 连跑零崩溃。
- 覆盖率: TOTAL 行 59.81%→63.66%；APlay.swift 45.37%→67.69%；Composer 47.68%→60.99%。
- 验证: swift test 70/70（12 连 clean）；iOS 8 套构建 SUCCEEDED 零编译警告；
  MacPlayback PASS（137s→.playing→推进）。
- gapless 设计（下一批，待用户定 API 形状）:
  现状断口: checkPlayEnded→pauseAll(after:)→_player.pause()+composer.pause()+
  .playEnded→next()→_play()→新建 Composer→play(autoplay:true)→main asyncAfter 0.5s
  才 resume；且 readClosure 在每次 Composer.play 里重新布设、读该 composer 自己的
  2MB Uroboros。
  方案: 维护一个预加载的"下一曲" composer（prepare(autoplay:false) 语义，但不动当前
  composer）；在当前 composer 的 .decoderEmptyEncountered 且下一曲 ring buffer 有数据时，
  原子切换 player 的取数据源并 startPlayback()，全程不停 AU。
  同采样格式可真无缝；格式不同仍须 setup() 重初始化 AU（不可免，须文档化）。
  取舍: (a) 自动预加载 playlist.nextURL()，Configuration 开关默认关；
        (b) 显式 APlay.prepareNext(_:)。倾向 (a)。
  风险: readClosure 由 AU 实时渲染线程调用，活跃源切换须无锁（os_unfair_lock 非竞争即可），
  需把"每次 play 重布闭包"改为一个稳定闭包读原子源。
- 未竟: ④ gapless 实现（设计已定，待选 API 形状）；opus iOS 真机验证；
  5xx 初始错误不重连缺陷（SF-0023，未改产品）。
