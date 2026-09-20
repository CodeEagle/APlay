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

## SF-0025
- Revision: 30
- 取代 SF-0024 的"5xx 缺陷待定夺"——用户已批准修复，批次 A 已提交 98363c5。
- 修法（Streamer.swift）:
  ① WatchDogInfo 加 prepareForRetry()=只停 timer+清 isReadedData，不动 reopenTimes。
     原来 401/407 与 500...599 分支调 reset() 把重试预算清零 → 既不重连也不终止。
  ② 两个错误分支改用 prepareForRetry()。
  ③ handle(data:) 对可重试状态码（401/407/5xx，经 static isRetryableStatus +
     currentResponseStatus（_task?.response））直接 return，不投递错误页、不 reset。
  ④ handleEndEncountered 对可重试状态码 return，保住看门狗；只有真正的 EOF 才
     .endEncountered + writeFile。
- 结果: 持续 500 → 3 次 open（maxRemoteStreamOpenRetry=2）→ .reachMaxRetryTime；
  服务器恢复 → 第 2 次请求拿到 200 正常投递。测试改为
  testRemote500RetriesUntilTheBudgetIsExhausted 与 testRemote500RecoversOnTheRetry
  （testRemote500CurrentlyEndsTheStream 删除）。
- 顺带修了 APlayer.state getter 死锁（崩溃报告 xctest-2026-09-19-170238.ips）:
  APlay.deinit 可能落在 APlayer._stateQueue 上（Delegated 的 weak-target 回调返回时
  释放临时强引用，恰为最后一次释放 → deinit 在该队列执行），而 _player.destroy()→
  pause()→state getter 的 _stateQueue.sync 重入死锁（SIGTRAP，约 1/15 概率）。
  修法: _stateQueue setSpecific，getter 在已位于该队列时直接读 _state（barrier 独占，
  无竞争）。修后 20 连跑零崩溃；此前 1/15。
- 验证: swift test 71/71（20 连 clean）；iOS 8 套构建 SUCCEEDED 零编译警告；
  MacPlayback PASS。
- 未竟: ④ gapless（用户批"都可"，采用方案 (a) 自动预加载+Configuration 开关）；
  opus iOS 真机验证。

## SF-0026
- Revision: 31
- ④ gapless 已实现（方案 a，开关默认关），产品代码+测试完成，**尚未提交**。
  MacPlayback 的 gapless 模式有两处编译错误待修（见下"待修"），其余全部验证通过。
- 改动文件:
  PlayList.swift: 拆 `_nextURL` 为纯函数 `_peekNext(pattern:) -> (index,url)?`；
    `nextURL()`=peek 后推进 playingIndex；新增 public `peekNextURL()`（不改 index）。
    `_previousURL(.single)` 改调 `_peekNext(pattern: .single).map { $0.url }`。
  ConfigurationCompatible.swift: 加 `var isGaplessPlaybackEnabled: Bool { get }`（含
    跨格式须 setup 重初始化、预加载丢弃条件的文档）。
  Configuration.swift: `public let isGaplessPlaybackEnabled`；init 参数
    `gaplessPlaybackEnabled: Bool = false`。**init 参数顺序: …autoFillID3InfoToNowPlayingCenter,
    autoHandlingInterruptEvent, gaplessPlaybackEnabled, enableVolumeMixer, sessionBuilder…**
  APlayer.swift: 顶级 `final class RenderReadSlot: @unchecked Sendable`（os_unfair_lock
    保护闭包；read 先 copy-out 再解锁，故渲染线程内重入 set 不死锁）。
    `readClosure` 加 didSet → `_readSlot.set(readClosure)`；setup() 的输入闭包改读
    `_readSlot.read(size, into: sself._buffers)`。destroy() 仍置 readClosure（经 didSet 清槽）。
  Composer.swift: `isPreloadAhead`（private(set)）；`preload(_:)`（=play(autoplay:false)
    但不 setup AU、不布 readClosure、不 resume）；`activate()`（若
    needsAudioUnitReconfiguration 则 player.setup(outputFormat)，再 installReadSource，
    若 state != .running 则 resume——避免 iOS 主线程 API 落在渲染线程）；
    `installReadSource()`（play 与 activate 共用，含 PCM readSize==0→.empty 探测）；
    `outputFormat`(src 线性则 src 否则 dst)、`needsAudioUnitReconfiguration`(
    info.isUpdated 且 != player.asbd)、`isBufferedAhead`(_ringBuffer.availableData>0)。
    decoder 委托 .output 分支: **configuringAllowed 在派发前捕获**（派发期间 isPreloadAhead
    会变，块内读会误配 AU）。
  APlay.swift: `__nextComposer`+`_nextComposer`(propertiesQueue 保护)；私有
    `PendingComposerEvents`(NSLock 数组: append/clear/streamerEnded/failed/takeAll)；
    createComposer 委托改 `[weak com]`（强捕获会循环）+ `isPreloadAhead`→queuePreloadEvent；
    事件 switch 抽为 `handleComposerEvent(_:)`（可重放）；`.streamerEndEncountered` 追加
    `preloadNextTrack()`；`checkPlayEnded` 三处 pauseAll 改 `handlePlayEnded(after:)`；
    handlePlayEnded: 满足条件则 `_isCalledDelayPaused=true`+performGaplessHandoff，否则
    pauseAll；`canTakeOverPreload(_)`=开关开 && isBufferedAhead && 未失败（URL 匹配交给
    调用方：曲终 peek，手动 next() 已推进 index 故用传入 url，否则 peek 会指向下一曲）；
    `performGaplessHandoff`→`playlist.nextURL()` 匹配则 activatePreloadedTrack，否则
    discardPreload+回 pauseAll；`activatePreloadedTrack(_)`: 记 old、置 streamerEnded 标志、
    resetFlag()、再置 streamerEnded（resetFlag 异步清，故重置后再断言）、`next.activate()`、
    `_currentComposer=next`、`old?.destroy()`（换源后再拆旧的）、main async: .playEnded→
    indexChanged→replayPendingEvents→nowPlayingInfo.play→解 _isCalledDelayPaused；
    `replayPendingEvents` 丢弃 .decoderEmptyEncountered（缓冲期噪声会让短曲早结束）；
    `preloadNextTrack`=开关开 && _nextComposer==nil && peek 非空 && != 当前 url；
    `discardPreload` 在 _play/previous/destroy/deinit(直接读 __nextComposer)。
- 关键设计决策:
  换源时机=checkPlayEnded 的 delta<=0.02（老 pauseAll 同一判据）→ 同步原子换源（渲染线程
  也不停 AU）；异格式 activate() 内 player.setup（若在渲染线程触发则整个换源推迟到 main；
  跨格式本就不无缝，已文档化）。
  曲终链: 现行曲 streamer end → 预加载下一曲 → 曲终 decoderEmpty → 换源+replay 事件；
  重放 `.streamerEndEncountered` 会再触发 preloadNextTrack → 播放链式预加载（_nextComposer
  已存在则跳过）。.stopWhenAllPlayed 末轨 peek=nil 自然不预加载；single 循环 peek==当前
  url 跳过。
- 验证（已过）:
  swift test 85/85（71→85；+9 gapless 编排测试 +5 RenderReadSlot 测试），连跑 5 次 clean。
  变异: handlePlayEnded 条件改 `if false, let pre…` →
    testEndOfTrackHandsOverToThePreloadedTrack 立刻失败"output unit must never be paused"。
  iOS 8 套构建（APlay/APlayDemo × iphoneos/iphonesimulator × Debug/Release，
    CODE_SIGNING_ALLOWED=NO）全 BUILD SUCCEEDED；仅工具链噪声 warning（xcodebuild
    "Using the first of multiple matching destinations"），swift build -c release 零警告。
  swift run APlayMacPlayback（单轨，默认配置 gapless 关）PASS：137s→.playing→推进 2.0s
  （渲染回调经 RenderReadSlot 的实时路径已验证）。
- 待修（MacPlayback/main.swift 编译错误，2 处）:
  ① 行 ~128 `APlay.Configuration(gaplessPlaybackEnabled: true, logPolicy: .disable, …)`
    → 参数顺序错，改为 `logPolicy: .disable, gaplessPlaybackEnabled: true,
    autoHandlingInterruptEvent: false`。
  ② 行 197 `print("playing \(urls.map(\ $0.lastPathComponent )) …")` → 转义 $0 非法，
    改 `urls.map { $0.lastPathComponent }`。
  修后跑 `swift run APlayMacPlayback gapless`（播 MacTests/Fixtures/tone.m4a +
    tone-alac.m4a，loopPattern=.stopWhenAllPlayed(.order)，配置 gaplessPlaybackEnabled:true），
    期望 PASS: 未见 .paused 即切到第 2 轨，且第 2 轨 playback 时间推进。
- 未竟: 修上面两处+跑 gapless 端到端；ChangeLog.md/README.md 记 gapless 开关与跨格式限制；
  提交（提交信息如 "Preload the next track for a gapless handoff"）；opus iOS 真机验证。

## SF-0027
- Revision: 32
- 取代: SF-0026 的"待修/未竟"两段——MacPlayback 编译错已修，gapless 端到端已过，文档已写，
  本批已提交。
- 修复 MacPlayback/main.swift 两处编译错:
  ① Configuration 参数顺序按声明序 logPolicy → autoHandlingInterruptEvent →
    gaplessPlaybackEnabled（Swift 要求带默认值参数按声明顺序）；
  ② `urls.map(\ $0.lastPathComponent)` → `urls.map { $0.lastPathComponent }`
    （字符串插值里 `\ $0` 闭包占位非法）。
- 验证（全过）:
  swift run APlayMacPlayback gapless → PASS: 未见 .paused 切到第 2 轨（tone→tone-alac），
    第 2 轨推进至 2.0s（证明 AU 未停、换源原子）。
  swift run APlayMacPlayback（单轨回归）→ PASS: 137s 轨推进 2.0s。
  swift test 85/85 passed、0 failed。
  iOS 8 套构建（APlay/APlayDemo × iphoneos/iphonesimulator × Debug/Release，
    CODE_SIGNING_ALLOWED=NO）全 BUILD SUCCEEDED；唯一 warning 为
    appintentsmetadataprocessor "Metadata extraction skipped, no AppIntents.framework
    dependency found"（工具链噪声，非本仓代码）。
  swift build -c release（含 APlayMacPlayback）零警告。
- 文档: ChangeLog.md 新增 v2.1.0 段（gapless 特性 + 同格式无缝/跨格式不无缝的限制 +
  ALAC/WAVE/format-hint/5xx 重连四项 2.0 后修复）；README.md 特性清单加 gapless 条目并
  新增 "Gapless playback" 用法节（Configuration(gaplessPlaybackEnabled: true) +
  loopPattern .stopWhenAllPlayed(.order) + play([urls])）。
- 提交: 本批一并提交源码、测试、MacPlayback、ChangeLog、README、笔记；
  排除 xcuserstate（Xcode 界面噪声）。
- 剩余: opus 注入式解码仍须 iOS 真机验证（不阻塞本批）。

## SF-0028
- Revision: 33
- 取代: SF-0027 的"剩余: opus 须 iOS 真机验证"——已验证（真机原生解码，无需注入），
  并连带修复三个 iOS 真实缺陷。
- 任务（用户）: "把支持的音乐文件放到测试，然后直接打包发我手机测 opus"。
- 做了什么:
  1. APlayDemo 改造为真机格式试机: APlayDemo/Samples/ 放 11 个格式 fixture
     （pbxproj 手工注入资源引用，已验 8 套构建）; ViewController 改为顺序播放
     12 个本地文件（opus 首位）、屏幕逐行显示结果、日志同步写 Documents/result.log
     （devicectl device copy from appDataContainer 取回）; Info.plist 加
     UIApplicationSceneManifest + AppDelegate 提供 configurationForConnecting
     与 SceneDelegate（iOS 17+ 必需，否则启动即 EXC_BREAKPOINT NoSceneLifecycle）。
  2. 真机签名: 命令行覆盖对 GatherProvisioningInputs 无效; 最终用 Xcode 库内
     team 77SXM8HYXF 的 wildcard profile "iOS Team Provisioning Profile: *"
     (UUID 82de0928…) + 工程命令行 DEVELOPMENT_TEAM/CODE_SIGN_STYLE=Automatic
     + -allowProvisioningUpdates 由 Xcode 签名栈完成（devicectl install/process
     launch/pasteboard/copy from/systemCrashLogs 均可用; xcuserstate 与
     .DS_Store 不入提交）。
  3. 三个框架修复（均已提交 d61b53e）:
     a. Configuration.startBackgroundTask/endBackgroundTask 的
        MainActor.assumeIsolated 在后台队列被 Composer.preload 调用时 SIGTRAP;
        改为非主线程时 DispatchQueue.main.async 派发。
     b. 曲终检测 checkPlayEnded 依赖 composer.duration; opus-in-ogg 无可用时长
        （估算甚至 NaN），delta 死局; 改为: streamerEnd 后 currentTime 连续停驻
        （NSLock 同步的 _lastFrozenTime/_frozenHitCount，阈值 >=2）即判曲终，
        并在 APlay 的 .playback 事件处补触发（opus 曲 decoderEmpty 停报）。
        去掉 lastDelta 回退分支的 `<= lastDeltaThreshold` 死约束并补 hitCount 重置。
     c. Demo 的 Scene 生命周期（见上）。
- 验证: swift test 86/86（新增 testFrozenPlaybackTimeEndsTrackWithoutDuration;
  FakePlayer.currentTimeValue 可编程）; iOS 8 套构建 SUCCEEDED（仅
  appintentsmetadataprocessor 工具链噪声）; swift build -c release 零警告;
  MacPlayback 单轨 + gapless 双 PASS; 真机 12 格式全部播放并逐轨推进
  （opus 第 2 轨 play ended; 仅 wav→aifc 跨格式 paused 一次，符合文档）。
- 教训: ⑳㉗ 之后——⑱ 命令行 build setting 覆盖对 Xcode 27 的签名解析无效，
  用工程内/Xcode 库内 wildcard profile 才能过 GatherProvisioningInputs;
  ㉘ iOS 17+ 无 SceneManifest 启动即 trap（bug_type 309/EXC_BREAKPOINT），
  旧 AppDelegate 生命周期 Demo 必须补 SceneDelegate; ㉙ 真机诊断链:
  devicectl copy from systemCrashLogs + appDataContainer，比 console 可靠;
  ㉚ 跨属性异步 barrier set 在同步连发事件下读不到新值，停驻计数改 NSLock。
- 剩余: 无（本批闭环; ⑤ 未启动）。

## SF-0029
- Revision: 34
- 任务（用户四项改造，进行中，goal 3b94daf6）:
  1. README 写格式支持表;
  2. 不支持的格式加"可选子库"实现;
  3. 改为只用 SPM 安装（去 Carthage/CocoaPods）;
  4. Todo 的 AirPlay2 支持也要实现。
- 已调查事实:
  * 安装方式现状: 仅 APlay.podspec（无 Cartfile/xcworkspace）; Package.swift 已存在
    （products: APlay library; targets: APlay、APlayMacPlayback executable、
    APlayTests(MacTests, resources Fixtures)）; README Installation 段列
    Carthage/CocoaPods/SPM 三种;"Known issue (fixed)"段还提 `pod 'APlay'`。
  * 格式矩阵（MacTests/FormatCompatibilityTests.swift 已验）:
    解码成功: m4a(AAC/MP4)、aac(ADTS)、mp3 CBR/VBR、flac、opus-in-ogg、wav PCM、
    ALAC-in-MP4。
    解码失败（parse 成功但 decode 失败）: caf(ALAC-in-CAF, packet table 在数据后
    'optm', 流式不可, seekable 可)、aiff/aifc(AudioFileStream 报 dsc! 间断)。
  * AudioFileType 全集（AudioDecoderCompatible.swift 159-178）: aiff aifc wave rf64
    soundDesigner2 next mp3 mp2 mp1 ac3 aacADTS mp4 m4a m4b caf k3gp k3gp2 amr flac
    opus。扩展映射（StreamProviderCompatible.swift 156-178）含 m4b/ac3/amr/3gp/au/
    rf64/sd2，default → mp3。
  * AirPlay2: origin/airplay2 分支仅空壳 AirPlayer2.swift（方法全空，v0.0.3 时代,
    1051 文件差异，不可合，仅供思路）。APlay 现状已具备: Configuration
    startBackgroundTask 设 `.playback` + `RouteSharingPolicy.longFormAudio`
    （AirPlay2 长音频基础）。缺口待查: MPRemoteCommandCenter 接线（锁屏/控制中心
    遥控 play/pause/next/previous/seek）、AVRoutePickerView 接入点、
    routeChangeNotification 处理。
- 未做: 四项改造的代码与文档均未开始; 未提交。
- Next: 先写格式支持表（据已验矩阵）+ SPM-only 改造（删 podspec、改 README）;
  再定可选子库范围（针对 Core Audio 不支持格式，待定 ogg/vorbis 等）; AirPlay2
  做最小自研（MPRemoteCommandCenter 接线 + 路由选择接入点 + 文档）。

## SF-0030
- Revision: 35
- 取代：SF-0029 的"四项均未开始"——①③ 已完成并验证，本文记其实况。
- 任务①（README 格式支持表）: 新增 "Supported formats" 段（Gapless 段后、Known
  issue 段前）。表据 FormatCompatibilityTests 已验矩阵: 解码成功 7 行（AAC-MP4、
  AAC-ADTS、MP3 CBR/VBR、FLAC、Opus-in-OGG、WAVE-PCM、ALAC-MP4）；parse-only 2 行
  （ALAC-in-CAF 'optm' 流式不可/AIFF-AIFF-C 'dsc!'）。另列 hint 表已映射但无 fixture
  的扩展（m4b/ac3/amr/3gp/3g2/mp2/mp1/au/rf64/sd2），明标"未含测试矩阵"。
- 任务③（SPM-only）: git rm APlay.podspec; README Installation 仅留 SPM 并说明无
  CocoaPods/Carthage; 删 Known issue 段的 `pod 'APlay'` post_install 句;
  fastlane/Fastfile 去 pod_lib_lint/version_bump_podspec/pod_push，新增
  `test` lane（swift test）与 `bump_swift_version_constant`（gsub 改 APlay.swift 的
  `APlay.version` 常量，bump 在 test 之前跑——APlaySmokeTests:19 断言版本号，
  测试只在常量与断言同步时才绿）。ChangeLog v2.1.0 加第 9、10 条。
- 验证（本批）: swift test 86/86 零失败; iOS 8 套构建（APlay/APlayDemo ×
  iphoneos/iphonesimulator × Debug/Release，CODE_SIGNING_ALLOWED=NO）全 BUILD
  SUCCEEDED、零业务警告（仅工具链噪声）; swift run -c release APlayMacPlayback 播
  APlayDemo/a.m4a PASS（137s→.playing→推进 2.0s），即 README "Known issue (fixed)"
  所指的 -O 优化路径又跑过一次实证。
- 已知漂移（未改，非本批范围）: APlay.version 常量与 APlaySmokeTests 断言仍 2.0.0，
  而 ChangeLog 头已 v2.1.0; README SPM `from: "2.0.0"`。发版时由
  bump_swift_version_constant 统一。
- 未做: ②可选子库（范围待定: Core Audio 不支持的容器/编码，候选 ogg/vorbis、
  非 OGG 的 opus）；④AirPlay2（MPRemoteCommandCenter 锁屏遥控、AVRoutePickerView
  接入点、routeChange 处理）。
- Next: ② 先定范围——查 APlay 现有 audioDecoderBuilder 注入缝能吞哪些自定义解码器，
  定一个最小可选 target（如 APlayVorbis），不污染主库; 再做 ④ 最小自研。
## SF-0057
- Revision: 57
- 取代: SF-0056 的「批 D 未提交」。

### 批 D 已提交，推送被拒
- 提交 28180ce「Fix gapless cross-format handoff deadlock; repair demo
  matrix badges and EQ slider」（7 文件：Composer/APlayer/EqualizerView/
  TrackLibrary/VerticalEQSlider/pbxproj/ChangeLog 25-27 条）。
- ChangeLog 加 25（跨格式 reconfig 死锁修复）、26（matrix resourceName 徽章）、
  27（EQ 滑杆+远程地址）三条。
- 推送失败两种错误交替：GH013 Repository rule violations；Connection closed
  by remote host / sideband disconnect（网络抖动）。

### 根因：build/ 构建产物被 git 跟踪
- .gitignore 只有 .vscode/ 与 .build/（SPM 目录），**漏了 Xcode 的 build/**。
- 从 76da439 起 build/ 被加入跟踪，之后 40 个未推送提交各拖 955 个构建产物
  （.pcm 二进制，最大 10MB），共 172MB blob / 73MB pack → GitHub 拒绝。
- 修复：.gitignore 加 build/；commit 017f651；brew install git-filter-repo；
  `git filter-repo --path build/ --invert-paths --force` 彻底清除历史。
  （pip3 装 git-filter-repo 被 PEP 668 拒，brew 可装。）
- filter-repo 副作用：删除 remote 配置与 origin/* 引用 → 需
  `git remote add origin git@github.com:CodeEagle/APlay.git` 重建。
- 清理后 HEAD=f3969fe；前溯 28180ce（批D）、93f3f79（批C，原 cbae808）。
  哈希被重写，旧 cbae808 已不存在。
- remote 重建后全量 fetch 仍 sideband 断开（远端仓库大+网络抖）；
  `git fetch --depth=1 origin master` 成功，origin/master 已恢复。
- 待推送：FETCH_HEAD..HEAD = 75 commits，6.6MB blob（清理后瘦身成功）。

### matrix 真机验证
- 用户确认「可以了提交推送」= matrix 12 行全亮（aifc/caf 已 done），验收通过。

### 回归（批 D 最终代码）
- swift test 226/226；iOS 6 套 BUILD SUCCEEDED；MacPlayback 单曲+gapless 双 PASS。

### 遗留
- **推送未完成**：需 `git push origin master`。因历史被 filter-repo 重写，
  若 push 被拒（non-fast-forward）可能需 `--force`（本地 75 提交均未推送，
  强推安全；但 origin/master 是浅取的 depth=1，先 fetch 全程或直接强推）。
  推送前注意：镜像仓库规则「未经允许不 push」——用户已明示「提交推送」=授权。

### AirPlay 测试问题（用户提问，未答）
- 用户问「airplay 的功能怎么测试」。代码现状：ChangeLog 第 12 条 =
  AirPlay 2/远程控制已接入（MPRemoteCommandCenter，默认开，gated by
  Configuration(enableRemoteCommandHandling:)）；音频会话已是长音频路由
  共享策略；now-playing 元数据已发 MPNowPlayingInfoCenter；
  但**路由选择 UI 是 app 级**——需自带 AVRoutePickerView。

## SF-0058
- Revision: 58
- 取代 SF-0057 的「推送未竟」与「AirPlay 问题未答」两条遗留。

### 推送完成
- `git push --force origin master`：`e37afb6...f3969fe master -> master (forced update)`。
- 验证 `git log origin/master -1` == `f3969feb13130ce4e383f7f82bd44530527f9317` == 本地 HEAD。
  推送前 origin/master 为浅取旧 tip e37afb6（rev-list left-right = 1/75），
  因历史被 filter-repo 重写故强推；本地 75 提交均已推送到远端。
- 仓库推送任务收尾：master 远端现已与本地一致，瘦身结果（无 build/、6.6MB）生效。

### AirPlay 测试方法（答用户）
代码现状（已核对源码）：
- `Configuration.isEnabledRemoteCommandHandling` 默认开；音频会话已设为
  长音频路由共享策略（AirPlay 2 要求），见 Configuration.swift:62-70 注释。
- `NowPlayingInfo` 发 MPNowPlayingInfoCenter：title/artist/album/artwork/
  duration/elapsedPlaybackTime/playbackRate（NowPlayingInfo.swift）。
- `RemoteCommandController` 接 MPRemoteCommandCenter（播放/暂停/上下曲/拖动）。
- APlayDemo **未**自带 AVRoutePickerView——路由选择走系统控制中心/锁屏的 AirPlay 按钮。

可操作测试步骤（真机，模拟器无法测 AirPlay 路由）：
1. 前置：AirPlay 接收端（Apple TV 4K / HomePod / Mac「设置→通用→隔空播放
   接收器」开启，或 AirPlay 2 第三方音箱）；真机与接收端同一 Wi-Fi。
2. 路由切换：APlayDemo 播放任一曲目 → 下拉控制中心 → 点右上 AirPlay 图标 →
   选接收端。验证音频切到接收端后播放连续、进度不跳。
3. 远程控制（在接收端/锁屏/控制中心操作）：播放、暂停、上一曲、下一曲、
   拖动进度条——全部应由 RemoteCommandController 响应；锁屏应显示标题/艺术家/
   专辑/封面/进度（NowPlayingInfo 上报）。
4. 路由中断：拨掉接收端（关 AirPlay 或断 Wi-Fi）→ 播放应自动回到 iPhone 内置
   喇叭且不卡死（音频会话中断/路由变化自动处理，isAutoHandlingInterruptEvent）。
5. 回归：AirPlay 路由无法单测，靠真机手测；`swift test` 226/226 保证引擎不退化
   （Tests 目录目前无 NowPlaying/RemoteCommand 专用单测，可后续补）。

## SF-0059
- Revision: 59
- 取代 SF-0058 的「无待办」。

### APlayDemo 加 AirPlay 路由选择按钮（用户同意后实现）
- 新文件 APlayDemo/AirPlayRoutePicker.swift：
  - `AirPlayRoutePicker: UIViewRepresentable` 包装 AVRoutePickerView
    （prioritizesVideoDevices=false，tint/activeTintColor 跟随 demo 白色）。
  - `AirPlayRouteLabel`：读 AVAudioSession.currentRoute.outputs.first，
    AirPlay 端口显示 "AirPlay · <portName>"；监听
    AVAudioSession.routeChangeNotification 实时刷新。
- NowPlayingView：transport 与 loopChips 之间插入 airPlay 行（按钮+路由名）。
- pbxproj 注册新文件：手动 4 处插入，ID 沿用现有规律
  fileRef=A5E0A500000000000000110C、buildFile=A5E0A500000000000000120C；
  plutil -lint OK。教训：传统 xcodeproj 目标，新建 swift 文件必须登记进
  pbxproj（PBXBuildFile/PBXFileReference/Group/Sources 四处），否则
  xcodebuild 报 "cannot find ... in scope"。
- 回归：iOS 模拟器 + 真机(00008130-000E7959262B803A) APlayDemo 均
  BUILD SUCCEEDED；swift test --enable-code-coverage 226/226。
  （注：裸 `swift test` 跑 0 tests——测试目录是 MacTests/ 非 Tests/，
   需 --enable-code-coverage 才进入完整套件；非本次回归问题。）
- 提交 4f3e1d6 并已 push：f3969fe..4f3e1d6 master -> master（fast-forward）。

## SF-0060
- Revision: 60
- 取代 SF-0059 的「无待办」。

### 发布收尾：tag + 关 issue
- `git tag -a v2.1.0 -m "v2.1.0 — gapless playback, ALAC/WAVE fixes, AirPlay 2
  remote control"`，指向 HEAD 24ca563；已 push（new tag），远端
  refs/tags/v2.1.0 = 3b4b2d7（tag 对象）。
- 关闭 4 个旧 issue（均附英文说明，依据指向 v2.1.0/公开 API）：
  - #19 iOS14 高 CPU：版本太老，当前基线 iOS17+ 真机验证正常。
  - #10 m4a 无法播放：v2.1.0 修 ALAC magic cookie + .m4a/.m4b 格式提示映射。
  - #14 预加载请求：已提供 `APlay.prepare(_:)`（APlay.swift:184）
    + gapless 下一曲预加载（preloadNextTrack，APlay.swift:521）。
  - #3 HTTP 流：streaming decoder 边下边播 + HTTP 5xx 重连重试。
- **保留 #17**（opus 无法播放）：iOS 原生 ExtAudioFile 不支持 opus 解码，
  需自研解码器，未解决，不关闭。
- GitHub Release 尚未创建（gh 已认证 CodeEagle，keyring ssh）；用户此前
  问「要不要发 Release」后改令「关闭issue」，Release 待定。

## SF-0061
- Revision: 61
- 取代 SF-0060 的「#17 保留 / Release 待定」。

### 更正：opus 实际已支持，#17 已关
- 之前判断「iOS 原生不支持 opus 解码，需自研」有误：APlay 不经 ExtAudioFile
  处理 ogg/opus，走自家 streaming decoder。标准 `.opus`（OGG 封装）
  parses+decodes 全绿。
- 证据：README.md:65 format matrix「Opus | in OGG (.opus) | ✅」；
  MacTests/FormatCompatibilityTests.swift:46 `tone.opus` parses:true decodes:true，
  formatID=kAudioFormatOpus；APlayDemo/Samples/tone.opus 真机可直接播；
  ChangeLog v2.1.0 第 7/10 条亦列 Opus-in-OGG 为已解码格式。
- 唯不支持：**裸 Opus（非 OGG 容器）与 Vorbis**——需经 audioDecoderBuilder
  注入自定义解码器（README.md:74）。
- #17（2019 年报「can't play opus file」）已附更正说明关闭。Open issues = 0。

### GitHub Release 已发布
- `gh release create v2.1.0`：非 draft 非 prerelease，已发布。
  https://github.com/CodeEagle/APlay/releases/tag/v2.1.0
- 正文由 ChangeLog v2.1.0 全 27 条整理为分组摘要（What's new / Stability /
  Platforms & demo / Quality），草稿存 /tmp/aplay_v210_notes.md。
- 发布收尾全部完成：master 已推、tag v2.1.0 已推、5 个 open issue 全关、
  Release 已发。

## SF-0062
- Revision: 62
- 取代 SF-0061 的「发布收尾完毕」。

### README 全格式对照表
- 用户要求：列出市面所有音频格式 + 本库支持情况，一个表放 README。
- 做法：把「Supported formats」段从 9 行 verified 小表升级为分组大表
  （Lossy / Lossless / Uncompressed & block PCM / Containers & audiobooks /
  Not audio streams），约 40 行，覆盖 MP3/MP2/MP1、AAC 全家族、Opus-in-OGG、
  AC-3/E-AC-3、AMR、Vorbis、WMA、Musepack、ATRAC、Speex、AC-4、FLAC、ALAC
  (MP4/CAF)、WavPack、APE、TTA、TrueHD、DSD、OptimFROG、Shorten、WAVE/AIFF、
  ADPCM、AU/RF64/SD2/W64、raw PCM、MP4/M4B/CAF/3GP/MKA/MPEG-TS、MIDI/SF2。
- 状态四档：✅ verified（FormatCompatibilityTests 钉死）/ ✔ routed
  （fileHint 映射 Core Audio 但无 fixture）/ ⚠️ stream-only（本地走 APlayExtras）
  / 🔌 inject（Core Audio 无解码器，须 audioDecoderBuilder）。MIDI/SF2 标 —。
- 表下注明：未识别扩展名回退 .mp3 靠 AudioFileStream 嗅探。

### 顺带修源码与文档不符
- ChangeLog v2.1.0 第 4 条宣称映射 .ac3/.eac3，但源码只有 case "ac3"；
  已补为 `case "ac3","eac3","audio/ac3": return .ac3`
  （StreamProviderCompatible.swift:172），并给 FormatHintTests 加 "eac3": .ac3
  断言；同时更新该测试里过时的 opus/#17 注释（#17 已关，opus 已支持）。
- 回归：swift test --enable-code-coverage 226/226（断言并入已有表驱动测试，
  测试数不变）；APlayDemo iOS 模拟器 BUILD SUCCEEDED。
- 提交 ded1bf4 已推：README + hint + 测试。

## SF-0063
- Revision: 63
- 取代 SF-0062 的 README 四档状态表。

### 三类划分（用户要求）+ 实测补齐 routed 格式
- 用户要求：README 格式表改为「流式支持 / 本地播放支持 / 不支持」三类，
  并补必要格式测试。
- 本机 ffmpeg 8.0.1 + afconvert 生成 fixture（MacTests/Fixtures/）：
  tone-mp2.mp2、tone.ac3、tone.eac3、tone-mp4.mp4、tone.m4b（复制 m4a 改后缀）、
  tone-ima4.wav（ffmpeg adpcm_ima_wav）、tone.3gp/tone.3g2（AAC 装 3gp 容器）、
  tone.au（afconvert NeXT ulaw）。本机无 mp1/amr 编码器。
- 全部加入 FormatCompatibilityTests 表驱动测试，实测结论：
  - 新晋流式 verified：MP2 ✅、AAC-in-MP4 ✅、M4B ✅、IMA4-in-WAVE ✅
    （formatID 报 lpcm）、AC-3 ✅、E-AC-3 ✅（formatID='ec-3' 0x65632D33，
    非预期 'ac-3'）。
  - AIFF-C：streaming **完全无属性**（sampleRate=0），parses:false；
    本地经 APlayExtras 可解（SeekableFileDecoderTests 已有）。
  - **AU/µ-law：parses 但 decodes 失败**（6 errors，0 PCM），且 APlayExtras
    handledHints 不含 .next → 实际不支持。
  - **3GP/3G2：streaming 完全不 parse**（sampleRate=0）→ 不支持。
- README 重写为三类表：
  - Streaming playback（默认路径，全部 fixture 钉死，12 行）
  - Local file playback via APlayExtras（caf/aiff/aifc，含失败原因 optm/dsc!/无属性）
  - Not supported（AU、3GPP、RF64、SD2、MP1/AMR 未验证、Vorbis、裸Opus、WMA、
    WavPack、APE、TTA、TrueHD、AC-4、DSD、Musepack、ATRAC、Speex、Wave64、
    MKA、MPEG-TS、raw PCM）；MIDI/SF2 注明非音频流。
  - AC-3/E-AC-3 注明 iOS 解码受 Dolby 授权、设备/系统而异。
- ChangeLog 加「unreleased」第 1 条记录上述（含 eac3 曾漏映射的更正）。
- 回归：swift test --enable-code-coverage 226/226（断言并入表驱动测试，
  测试方法数不变）；APlayDemo iOS 模拟器 BUILD SUCCEEDED。
- 提交 f474864 已推。
- 教训：hint 表映射 ≠ 能播放；AudioFileStream 支持的容器子集远小于 AudioFile。
  旧四档措辞「stream only」易误导读作"只支持流式"，三类划分已消除该歧义。

## SF-0064
- Revision: 64
- 取代 SF-0063 的「不支持类无方案」。

### 不支持格式的「加上支持」方案——容器层先落地
- 根源二分：(a) 容器解析不了（AudioFileStream 不收，但 AudioFile/ExtAudioFile
  收）；(b) Core Audio 无解码器（codec 层，需注入第三方 C 库）。
- (a) 已落地：afinfo 确认 3gpp/3gp2/NeXT 在 AudioFile 层可开；扩
  `SeekableFileDecoder.handledHints` = [.caf,.aiff,.aifc,.next,.k3gp,.k3gp2,
  .rf64,.soundDesigner2,.w64]，新增 `AudioFileType.w64`("W64 ")
  + fileHint case "w64"（FormatHintTests 已加断言）。
- 实测（SeekableFileDecoderTests +4 用例，fixture tone.au/tone.3gp/tone.3g2/
  tone.w64）：AU/3GP/3G2/W64 经 APlayExtras 全部解码成功零错误。
  RF64/SD2 无 muxer 造样本，按 ExtAudioFile 原生支持标「本地播放（无 fixture）」。
- README：AU、3GPP/3GPP2、Wave64、RF64、SD2 从「不支持」移到「本地播放」。
- 更新 SeekableFileDecoder/FileFallbackDecoder 文档注释（旧文案只提 CAF/AIFF）。
- ChangeLog「unreleased」加第 2 条。
- (b) 仍未做：Vorbis/裸Opus/WMA/WavPack/APE/TTA/TrueHD/AC-4/DSD/Musepack/
  ATRAC/Speex/MP1/AMR——需经 audioDecoderBuilder 注入 libvorbis/opus/wavpack
  等 C 库 wrapper（AudioDecoderCompatible），工作量在引依赖；MIDI/SF2 需合成器
  非解码，定位不同。
- 回归：swift test --enable-code-coverage 230/230（+4）；APlayDemo iOS 模拟器
  BUILD SUCCEEDED。提交 c004a8d 已推。

## SF-0065
- Revision: 65
- 取代 SF-0064。任务进行中，**未提交**。

### 任务：每个 codec 一个独立子库（SPM product，按需加载，配文件测试）
- 已 clone 源码在 /tmp/codec_probe/：ogg(1.4M) vorbis(7.7M) wavpack(7.0M)
  opus(26M) speex(5.8M)，**许可全 BSD-3**。样板 = WavPack（纯 C、无 config.h）。

### WavPack 子库已跑通（编译通过 + 解码测试通过）
- Sources/CAPlayWavPack/：vendored C（26 个 .c + 头；**排除 .asm/.S**）；
  内部头 wavpack_local.h/wavpack_version.h/decorr_tables.h/unpack3.h 放源码根
  （供相对 include），公共头 include/wavpack/wavpack.h；
  cSettings headerSearchPath [".","include","include/wavpack"]。
- Sources/APlayWavPack/WavPackDecoder.swift：实现 AudioDecoderCompatible；
  APlayWavPack.decoder(fallback:) 返回 AudioDecoderBuilder（接入点
  = Configuration(audioDecoderBuilder:)，**不是 streamerBuilder**）；
  本地 .wv 全读进 Data，WavpackOpenFileInputEx64 + 全部 reader 回调；
  int32→canonical 16bit 立体声 44.1k（重采样+混声道）；DispatchSourceTimer
  20ms 驱动 decodeTick；convenience init(config:) 用内部 UnhandledDecoder 兜底。
- Package.swift：+target CAPlayWavPack(publicHeadersPath:"include")、
  +target APlayWavPack(dep APlay,CAPlayWavPack)、+product APlayWavPack、
  APlayTests 依赖 +APlayWavPack。
- APlay 改动：AudioFileType 加 .wavpack("wvpk")（在 .w64 之后）；
  fileHint 表加 case "wv"→.wavpack；FormatHintTests 加 "wv":.wavpack。
- MacTests/Fixtures/tone.wv（ffmpeg -c:a wavpack，44.1k 立体声；afinfo 打不开
  =Core Audio 不认，正因如此才需本库）。
- MacTests/WavPackDecoderTests.swift：
  - testDecodesWavPack **已通过**（≥1000 PCM、0 错误、dstFormat 44100/2ch、
    seekable）。
  - testMp3ReachesTheFallback **失败**，原因已查明：FakeStreamProvider 不发
    数据事件，DefaultAudioDecoder 拿不到字节。应改为只验证路由（仿
    SeekableFileDecoderTests.testLocalMp3ReachesTheFallback）：用 FakeDecoder
    （定义在 ComposerCoordinationTests.swift:51；API：prepareCalls/
    [StreamProvider.Position]、prepareFileHints/[AudioFileType]、
    setAttached(streamer)），断言 prepareCalls.count==1、prepareFileHints==[.mp3]。

### 关键经验（C 库 wrapper 模式，其余 codec 照抄）
1. WavpackUnpackSamples(wpc, buf, samples)：**samples=每声道帧数**，库写
   frames*channels 个 int32 → buffer 必须开 _unpackChunk*channels；返回值
   =交错总样本数（count/channels 得帧数）。
2. reader 回调**不能留 nil**：set_pos_rel/push_back_byte 被调到 nil 函数指针
   → signal 11 段错误。全部实现（set_pos_rel 按 fseek 语义 mode 0/1/2 相对
   头/当前/尾；push_back_byte 回退一字节返回该字节；truncate_here/close 返回 0）。
3. C 函数指针只能由**文件级全局 func**或字面闭包生成，不能是静态/实例方法
   → trampoline 全局函数 + Unmanaged.passUnretained/self 恢复。
4. WavpackStreamReader64 memberwise init 全 nil（9 个函数指针字段，无 temp_buff）；
   返回类型须与 C 头一致（set_pos_abs/can_seek→Int32，get_pos/get_length→Int64）。
5. 协议要求 init(config:)：便利 init + UnhandledDecoder（prepare 抛
   kAudioFileUnsupportedDataFormatError）。
6. resume 在 prepare 之前 → _context==nil 走 fallback，timer 不启动；需
   _pendingResume 标志，openFile 成功后 startTimer。
7. 同文件全局 trampoline 访问类成员须 **fileprivate**（private 报
   inaccessible）；import AudioToolbox 才有 kAudioFileUnsupportedDataFormatError。
8. print 的 stdout 崩溃时不 flush → 调试用 FileHandle.standardError.write。

### 待办（按序）
1. 修 testMp3ReachesTheFallback 为 FakeDecoder 路由验证。
2. 删 WavPackDecoder.swift 里 7 处 dbg(...) + dbg 函数（stderr 调试残留）。
3. 全量回归 swift test --enable-code-coverage（目标 232 = 230+2）。
4. README 三类表加 WavPack 行（归「本地播放」类，注明经 APlayWavPack；
   WavPack 非流式）；ChangeLog「unreleased」加第 3 条。
5. iOS 构建（APlayDemo xcodeproj 不含 APlayWavPack，无需改；仅验库不回归）。
6. 提交推送（改动多：Package.swift、Sources 新两目录、APlay 两协议、
   MacTests 测试+fixture tone.wv+tone.w64 等）。
7. 其余 codec 按同模式复制：Vorbis（+libogg 双库，可能需 config.h）、
   Opus 裸流、Speex 较简单；APE/TTA/Musepack/Shorten/OptimFROG 源码待找；
   MP1(mpg123,LGPL)、AMR(libopencore_amrnb)；
   **不可做**：AC-4/TrueHD/WMA/ATRAC/DSD 无开源解码器；MIDI/SF2 需合成器。

## SF-0066
- Revision: 66
- 取代 SF-0065。WavPack 子库**已完成并提交** e4f039b（40 文件，+20266 行）。

### 完成项（相对 SF-0065 的待办清单）
1. testMp3ReachesTheFallback 改为 FakeDecoder 路由验证：prepareCalls==1、
   prepareFileHints==[.mp3]，先 fake.setAttached(streamer)，
   decoder = APlayWavPack.decoder(fallback:{ _ in fake })(config)。
   原写法失败原因：FakeStreamProvider 不发数据事件，DefaultAudioDecoder
   无数据可解；路由本身是对的，只验路由即可。
2. 删尽 7 处 dbg(...) + dbg 函数（readBytes/tick/openFile 各处）。
3. swift test **232/232 全绿**（230+2），swift build 通过。
4. README：新增「Lossless codecs (via the optional APlayWavPack library)」
   一节（第四类 bucket，含 APlayWavPack.decoder(fallback:) 代码示例 +
   BSD-3 许可注明），WavPack 行从「Not supported」表删除。
   ChangeLog unreleased 加第 1 条（原第 1 条顺延为第 2 条）。
5. iOS 构建：APlayDemo BUILD SUCCEEDED；xcodeproj 用本地 framework target
   镜像 SPM，不含 APlayWavPack，故无需改工程。
6. 提交 e4f039b「Add optional WavPack playback through a vendored codec
   library」；notes 按惯例另起提交。
7. lint：新文件 swiftlint 从 8 违规降到 1（file_length 401>400，无害；
   仓库无 .swiftlint.yml、CI 无 lint 步骤，既有代码已有 218 违规）。

### 下一 codec 选型（照此样板复制）
- 样板结构：CAPlayXxx（vendored C，publicHeadersPath + headerSearchPath）
  + APlayXxx（wrapper 实现 AudioDecoderCompatible）+ Package product
  + AudioFileType/fileHint 表登记 + 2 测试（解码 + 路由）。
- 优先 Opus 裸流 / Speex（单库、结构简）；Vorbis-in-Ogg 需 ogg+vorbis
  双库且可能需 config.h，较重。/tmp/codec_probe 源码全 BSD-3。
- 不可做：AC-4/TrueHD/WMA/ATRAC/DSD 无开源解码器。
