## SF-0101
- Revision: 1
- Date: 2026-09-24
- Task: 内存泄漏修复（快速切歌导致旧 Composer 未销毁）

### 现场证据（用户报告）
- 1 个 APlay，23 个 Composer / 23 个 Streamer / 23 个 DataTask
- Network 缓冲约 604 MB；Composer 固定缓冲至少 184 MB
- 传统 leaks 仅 63 KB → 「仍可达对象滞留」，非普通 retain cycle
- 根因链：每次切歌/预加载创建新 Composer+Streamer+DataTask；
  `_currentComposer`/`_nextComposer` 用异步 barrier setter，并发事件覆盖引用
  导致中间 Composer 未 destroy；孤立 Composer 的解码线程卡在已满 PCM ring
  buffer 写入循环（5ms 轮询），被线程栈引用，ARC 无法回收；网络任务/下载缓冲
  /临时音频文件随之存活。

### 复现
- MacTests/ComposerLeakReproTests.swift：两队列同时调 play() 或同时发
  .endEncountered。未修复时稳定得到 32 个存活 Composer（同量级）。
- 关键：单队列串行调 play() 不复现；必须真正并发。

### 已完成改动
1. Composer.swift
   - DEBUG `liveCount`（static _liveCount + NSLock），init+1，destroy-1。
   - `destroy()` 幂等：`guard alive.exchange(0) == 1 else { return }`，
     计数与真实工作只做一次。
   - destroy 顺序：先 `_ringBuffer.clear()`（释放在满 buffer 上 park 的解码
     线程）→ unobserve/bufferedAhead/pendingResume → eventPipeline.toggle(false)
     → _decoder.destroy() → _streamer.destroy()。
   - ComposerPCMBuffer：write 去掉 `.milliseconds(5)` 轮询，改
     `writerWake.wait()` 无限等；read 消费后 `writerWake.signal()`；
     clear 仍 signal。
2. APlay.swift
   - `_composerQueue`（DispatchQueue）→ `_composerLock`（NSRecursiveLock）。
     递归锁是必需的：destroy 会触发 event delegate 回调重入读槽位。
   - `_withComposerLock` 封装；槽位读写全部走锁。
   - `_play` 原子化：createComposer 在锁外（构造会触发 self/锁），retiredNext
     与 retired 先置空再 destroy，再装新，`com.play()` 在锁内。
   - `next()` 的 check+接管合并进单一临界区，拆
     `_activatePreloadedTrackLocked` / `_activatePreloadedTrackBody`；
     body 内直接写存储（不重入锁）。
   - `_swapCurrentComposer`/`_setNextComposer`/`_detachNextComposer`/
     `_installNextComposerIfVacant` 全部单临界区（清空→destroy→装新）。
   - `_composerPair()` 读双槽（供一致性检查，目前未使用）。
3. NowPlayingInfo.swift
   - `_config` 由 unowned 改强引用：APlay 独占持有该对象，无泄漏；
     `remove()` 内 `_queue.async(flags:.barrier)` 改 `sync`。
   - 根因：unowned 前提是 config 存活久于 NowPlayingInfo，但
     Composer.eventPipeline delegate 强持有 APlay → 持有 config，异步 barrier
     块在 APlay 释放后才跑，读 `_config` 悬垂。这是泄漏修复改变析构时序后
     才暴露的先前不可见 bug。崩溃栈符号化：`closure #1 in APlay.NowPlayingInfo.remove()`
     → `swift_unknownObjectUnownedLoadStrong` → `swift_abortRetainUnowned`。
4. 测试 harness
   - APlayOrchestrationTests.swift / ComposerLeakReproTests.swift 的
     `[unowned box]` 改 `[weak box]`（Recorder 是存储属性，但闭包捕获的是
     init 局部名；weak 在 harness 释放时返回 nil 而非悬垂）。

### 剩余失败（当前唯一阻塞）
- 全量 331 passed / 0 崩溃，仍 3 失败：
  - APlayOrchestrationTests.testSkipReusesThePreloadedTrack：报 3 个 streamer
    （preload 应被复用而非重建）。next() 原子化改变了接管分支与 discardPreload
    的交互，需对齐「跳到已缓冲轨直接接管、不重建」。
  - ComposerLeakReproTests 两个用例仍报 32。空槽窗口未完全闭合：
    createComposer 在锁外构建时另一线程可抢先装 next；next()/preloadNextTrack
    与 _play 之间仍有空槽窗口。
- 崩溃调试方法：xcrun xctest -XCTest <Class> <xctest bundle> 直跑；
  ~/Library/Logs/DiagnosticReports/xctest-*.ips 解 JSON 取 triggered thread
  frames 符号化。lldb 无调试权限（non-interactive session）。

## SF-0102
- Revision: 3（取代 SF-0101 的「剩余失败」一节；其余 SF-0101 内容仍有效）

### 本轮结论：三个失败全部闭合，全量 6 连绿（334 tests / 0 失败 / 0 崩溃）

1. testSkipReusesThePreloadedTrack（3 streamer 而非 2）
   - 根因不是槽位语义，而是 URL 可见性时序：Composer.preload(_:) 把
     _streamer.open 派发到全局队列，开流落地前 _streamer.info.url 仍是
     占位址 https://example.com/a.mp3。next() 的接管守卫
     `pre.url == url` 因此判否 → discardPreload + _play 重建 → 第 3 个
     streamer。单跑测试时全局队列恰好抢在 next() 前落地，故此前单独跑
     通过、整套跑才红。
   - 修：Composer 新增 urlLock 保护的 recordedURL；play(_:) 与 preload(_:)
     在动 streamer 之前先记下 URL，`var url` 返回 recordedURL ??
     _streamer.info.url。接管判据不再与异步开流竞争。真实 streamer 的
     open() 本就在同线程先写 info 再派发 _open，故生产行为不变。

2. 泄漏测试「报 32」的真相：不是泄漏，是跨套件污染
   - 临时加了按创建点记账的 liveOrigins（事后已移除）：整套跑时泄漏测试
     自身结束时只剩 `_play: 1`——一个都不漏。31 个存活作曲家的 origin 全
     是 "init"，来自 ComposerCoordinationTests 直接 `Composer(player:config:)`
     构造且多数不 destroy（该文件全文只有 2 处 destroy()）。
   - 修：两个泄漏用例改为相对基线断言（进入时记 baseline，断言
     liveCount - baseline <= 2），只量本竞态自身的增量。隔离跑与整套跑
     均通过。

3. 加压下偶发 SIGABRT（_SwiftURL deallocated with non-zero retain count 2）
   - 复现条件：8 倍 CPU 饱和（while : 自旋）下跑 APlayOrchestrationTests，
     命中 testPreloadEventsAreWithheldUntilTheHandoff。正常负载 40+ 轮不见。
   - 机制：preload() 异步开流写 FakeStreamProvider.info，测试线程同步
     emit(.hasBytesAvailable) 让 Composer 的事件代理读 info.fileHint——
     对承载 URL 的枚举的撕裂读，产生悬垂 _SwiftURL。真实 streamer 无此问题
     （open 同线程先写 info、事件晚于 _open 在 _stateQueue 派发，读写在
     事件维度上有 happens-before），故只在 fake 上发生。
   - 修：FakeStreamProvider.info 改为 NSLock 保护的计算属性，匹配真实
     组件的「info 在事件前稳定」契约。加压 15 轮 orchestration + 6 轮全量
     不再复现。
   - 与 HEAD 对照：HEAD 同等加压下该套件表现为交接断言失败（未崩）——
     同一 preload 异步开流竞争的更温和表现，并非本次引入。

### 既有、非本次范围的问题（已验证 HEAD 同样复现）
- MetadataParserTests|MidiDecoderTests 在 8 倍饱和加压下偶发 SIGTRAP
  （signal 5）：HEAD 8 轮中第 5 轮复现，与作曲家/泄漏/NowPlayingInfo 改动
  无关（不碰这些文件）。正常负载从未出现。未处理。
- TSan 另报 InternalLogger.reset() 对 _openTime 的竞争（barrier 写与行内
  读），既有问题，未处理。

### 验收
- swift test 全量：334 tests，0 failures，0 crashes，连续 6 轮（3 轮正常
  + 3 轮正常；另加压 6 轮全量中 5 轮全绿，1 轮为上述无关既有 SIGTRAP）。
- 泄漏断言（基线增量）隔离与整套均通过。

## SF-0103
- Revision: 5（交付完成：提交、推送、合并 PR、打 tag）

### 交付动作
- 提交 e92a44e：泄漏修复本体（槽位锁化 + destroy 幂等 + ring buffer 去轮询
  + Composer.url 同步可见 + fake streamer info 加锁 + 泄漏测试基线增量断言）。
- 本地合并 PR #20（feat(nowplaying): accept track metadata on play/prepare）
  为 merge commit 2f9add8。冲突两处，解决方式：
  - APlay.swift `_play`：保留 HEAD 的锁临界区（泄漏修复），把 PR 的
    `if let metadata { _nowPlayingInfo.apply(metadata) }` 挪到锁块之后、
    `_nowPlayingInfo.play` 之前——保住 PR 想要的 clear→apply→publish 顺序。
  - NowPlayingInfo.swift `remove()`：两侧都改成了 sync barrier，取 PR 侧
    的注释（解释为何不能 async）。
- 推送 master：a31cbe9..2f9add8。GitHub 自动将 PR #20 识别为 MERGED
  （b15da8b 已在 master 历史中），open PR 清空。
- 打 annotated tag v2.1.8 并推送，指向 2f9add8。
  注：v2.1.7 原本就指向 PR #20 的 commit b15da8b（此前一直未合并），
  故本次 merge 同时把 v2.1.7 的内容纳入 master；v2.1.8 = metadata 特性 +
  泄漏修复。GitHub Releases 的 "Latest" 仍停在 v2.1.2（v2.1.3 起均为纯
  tag 未建 Release）——未创建 Release，因用户只要求打 tag。

### 验收（合并后）
- swift test 全量：336 tests，0 failures，0 crashes（23s）。比合并前 334
  多 2 个，正是 PR #20 新增的 NowPlayingInfo 测试。
- 远程 master=2f9add8；refs/tags/v2.1.8=c7b5ce9；无 open PR。

## SF-0104
- Revision: 6（新需求：网络流断点续传缓存；设计阶段）

### 需求
网络歌曲支持断点续传：先在本地建好容器（按 Content-Length 预分配），
数据填充到对应绝对位置；即使没下完，下次播放/seek 到已下载区间可直接
复用本地数据。核心难点是用户点明的：**需要一个本地表记录哪些块已下载**。

### 两个已定决策
1. 缓存清理：启动时（首次打开远程流时，per-process once）按
   maxDiskCacheSize（256MB）清理最旧的 .part+.meta。理由：maxDiskCacheSize
   目前**从未被读取**，无任何 LRU；选"启动时一次扫描"是为写路径零开销。
   预分配是稀疏文件，清理按**实际占用**（fileAllocatedSize）而非逻辑大小。
2. 校验强度：存 ETag + Last-Modified，用 HTTP 标准的 **If-Range** 头让
   服务器判断内容是否变更——比自己比对干净。206=未变可续传；
   200=变了或服务器不支持 → 丢弃 .part 从头重来。默认配置是
   .notValidate（keys 为空），故 ETag/Last-Modified 必须显式收集
   （registerHeader 只收 validator.keys）。

### 关键事实（已核查，带行号）
- CacheInfo（Streamer.swift:767-852）：tmp 顺序 fwrite，仅当
  _fileWritten == targetLength 才 move 到最终路径（812）→ 现在完全
  不支持续传。
- handle(response:)（391-441）：206 时 contentLength = len + position（437）；
  200 时 contentLength = len。ETag/Last-Modified 未收集。
- localReadLoop（280-300）：靠"读到 0 字节"判 EOF。稀疏容器的空洞区
  fread 也返回 0 字节 → 混合模式必须改为主动查 bitmap，不能靠 EOF。
- seek 也是重建 streamer（APlay.seek → 新 Composer → open(at:p)），
  故"会话内 seek 复用"与"下次播放复用"统一为 reset(url:) 里的
  asCachedFileInfo() 一个入口。
- ICY 流（handle(data:) 467-477 的 isIcyStream 分支）不写缓存且通常无
  Content-Length → 天然降级为现有顺序行为。
- CachePolicy（Configuration.swift:332-345）：.enable([String]) 的
  cachedFolder 是额外可复用目录；CacheFileNamingPolicy 默认用
  url.path 的 base64（305-323）。
- pause/destroy 通过 _isRunningLocal 打断 localReadLoop（127-153，
  230-248）；resume → startLocalReadLoopIfNeeded 恢复——空洞挂起/恢复
  可复用这套，但挂起时不能误报 EOF。

### 设计骨架
- 文件对：`<name>.part`（预分配容器，ftruncate）+ `<name>.meta`
  （定长二进制 sidecar：magic+version+blockSize+contentLength+url+
  etag+lastModified+bitmap+lastAccess；原子写：.meta.tmp 再 rename）。
- bitmap：block 8KB（对齐 localReadLoop 的 8192 读取）；10MB 歌 = 160 字节。
- 打开：reset(url:) 先查完整缓存（现有），再查 .part+.meta 且 url 匹配 →
  info 换成本地 .part 走 openLocal，contentLength 用 meta 的；首次网络
  请求带 If-Range 做内容验证。
- 写入：handle(data:) 按 position+_bytesRead 的绝对 offset fseek 落盘 +
  bitmap 置位。
- 读：localReadLoop 每块查 bitmap；空洞挂起 → _fillGap 发 Range 补齐 →
  恢复。info 已换成本地，故补齐需记 _originURL。
- 转正：bitmap 全绿 → move .part 到最终路径（沿用 saveFile）。
- 降级：无 contentLength / 非 206 / ICY → 现有顺序 tmp 行为。

### 委派故障
- atria2 的 runner 进程启动时缺模块
  （@earendil-works/pi-ai/dist/compat.js/providers/radius-config），
  属 lane 基础设施阻塞，不重试同配置。调查由主会话本地完成。
  实现阶段拟用 codex-spark/atria（external-cli），尚未验证其 runner。

### 分工
- 主会话：CacheMeta（新）+ CacheInfo/Streamer 全部改造（耦合最高）。
- 待派：DiskCacheCleaner（新文件）+ MacTests/ResumeCacheTests（测试）。

## SF-0105
- Revision: 7

### 阶段：断点续传实现（CacheMeta 修复 → DiskCacheCleaner 交付 → Streamer 集成近完成）

#### 已完成
- ResumeCacheMeta 两个真 bug：
  1. `append(uint32:)` 用 `UInt8(value >> 8)`（陷阱初始化器），contentLength
     低 32 位有字节即 SIGTRAP（"Not enough bits to represent the passed
     value"）。改 `UInt8((value >> 8) & 0xFF)`；uint16 版一并加掩码。
  2. bitmap 语义自相矛盾：mark "触及即置位"（松）而 downloadedBytes 按块大小
     记账；更要命的是松标记让 localReadLoop 把稀疏空洞当音频读。改为**严格
     整块语义**：块完整写入（末块按 containerLength 截断）才置位；`mark` 内
     置 `partial:[Int:UInt64]` 跨 chunk 累积（URLSession 分片任意大小）；已置
     位块重复 mark 不重复记账。bitmap 加 `containerLength` 与
     `firstMissingOffset`。
- decode 加 `storage.count==期望块字节数` 校验（修好 truncated-payload 测试）。
- ResumeCacheMetaTests 按严格语义重写，15/15 绿；全量 354 曾全绿（23s）。
- DiskCacheCleaner.swift + DiskCacheCleanerTests.swift 由 **codex-spark** 交付
  （9 测试本地 9/9 绿）：fileAllocatedSize 记账、`.part`+`.part.meta`+
  `.part.meta.tmp` 成组、孤儿 `.meta`、残留 `.tmp` 无条件删。
- ResumeCache.swift（新，写入侧）：预分配容器 + FILE* + writeOffset 游标 +
  NSLock（读循环与网络回调跨队列）；create（ftruncate "w+"）/open（"r+b"，
  校验 meta.originURL==url）/write（fseeko+fwrite+fflush→再 mark，reader 独立
  fd 可见）/restart（软重建：不截断、只重建空表）/flushMeta（0.5s 节流）/
  promote（完整后 move 到最终缓存路径并删 meta）。
- Streamer.swift 集成**已全部写入、尚未编译**：
  - `_resume:ResumeCache?`+`_resumeLock`+`resumeCache()/setResume()`；
    `_resumeDownloadStart`；静态 `_hasSweptDiskCache` 一次性清理。
  - `reset(url:)`：远程先 `sweepDiskCacheOnce(protecting:)`；完整缓存命中优先，
    否则 `openResumeCache`→info 换 `.local(.part)`、contentLength 取 meta。
  - `_open` 的 `.local` 分支：openLocal 后 `startResumeDownload(at:position)`。
  - `openRemote`：Range 起点改 `max(position, firstMissingOffset)`；有验证器带
    `If-Range`。
  - `localReadLoop`：读前 `resumeReaderShouldWait(at:handle.offsetInFile)`→未
    置位则 `Thread.sleep(0.01)` 轮询。承重前提已验证：**seek 重建 Composer→
    新 Streamer**（APlay.swift seek(to:)），单 Streamer 内 position 固定，
    空洞只需轮询+单个开放式 Range 任务（start..EOF）覆盖，无唤醒/取消机制。
  - `handle(response:)`：resume→`handleResumeResponse`（206 须 Content-Range.
    start==请求起点且 total==meta.contentLength；200 或长度变→软重建 restart；
    异常→fallBackToSequential）；fresh 且有长度→`beginResumeDownload`（建容器、
    info 换 local、`openResumeReader`，readyForRead 由读循环发）；无长度/ICY→
    旧顺序 tmp 路径。
  - `handle(data:)`：resume 分支**只** `resume.write(...)`——不 post、不喂
    tagParser（读循环 deliverLocalData 负责解析，否则双重喂入）。
  - `handleEndEncountered`：resume 以 `resume.writeOffset` 判完成；未完
    `cancelDownload()`（只取消 task、保 reader）+看门狗；完则 promote。
  - `handleStreamError`/`startReconnectWatchDog` 回调按 resume 分流到
    `reconnectResumeDownload()`（从 writeOffset 续、不动 reader）。
  - `bufferingProgress` resume 取 downloadedBytes/contentLength。
  - 管道方法集：responseContentLength/contentRangeStart/contentRange、
    beginResumeDownload、handleResumeResponse、openResumeReader、
    reconnectResumeDownload、fallBackToSequential、promoteResumeCache。
- 测试 fixture：`MacTests/Fixtures/github-silence.mp3`（真实 GitHub 音频：
  raw.githubusercontent.com/anars/blank-audio/master/1-second-of-silence.mp3，
  37206 字节=5 个 8KB 块，ETag
  "d7f6bc433679dab5d4df76c2b48307a05d44f018faccc2a088c555e8f04afc55"，
  accept-ranges:bytes，已验证 206+Content-Range）。本机可访问外网。

#### 未完成（Next）
1. 编译缺口：Keys 枚举缺 `ifRange`/`contentRange`/`etag`/`lastModified` 四个
   case；CacheInfo 缺 `var cacheName:String?` 访问器（Streamer 已引用
   `_cacheInfo.cacheName`）；DiskCacheCleaner 需加 `excluding:Set<String>=[]`
   （sweepDiskCacheOnce 传排除当前曲名）。
2. 编译修复后跑全量。
3. 写 MacTests/ResumeCacheTests.swift：URLProtocol 拦截真实 GitHub URL，
   fixture 字节做确定性 Range 服务器（206/Content-Range/ETag/Last-Modified，
   可控分片）。覆盖：首次落容器；中断→重开复用、Range 从
   firstMissingOffset；seek 已下区域纯本地；seek 空洞触发补齐；ETag 变→200
   软重建；完成→promote（下次 asCachedFileInfo 命中）。可选 live 测试（真 URL，
   离线跳过）。

#### 委派结论
- atria 与 atria2 runner 均崩（缺 radius-config / `_piAi.toolKey is not a
  function`）——Atria 基础设施级故障，不重试同配置。
- codex-spark（external-cli）可用，已交付 DiskCacheCleaner。后续委派用它
  或 codex-luna。spark 报的全量崩溃是其沙箱缺音频组件（
  AudioComponentFindNext nil），非回归——本机 354 全绿。

#### 设计红线（防遗忘）
- 严格整块 bitmap 是核心：reader 只信完整块，续传最多重请 ≤8KB。
- 单 Streamer 内 position 固定 → 空洞轮询 + 单个开放式 Range 任务；并发写者
  只可能在 watchdog 重连（串行，先 cancelDownload）。
- 软重建避免截断正被读的容器；旧字节留原地被新下载覆盖，新表使旧尾部对
  reader 与 promote 不可见。
- handle(data:) resume 分支绝不 post、绝不喂解析器；字节流为
  网络→容器→读循环→解码器。

## SF-0106
- Revision: 8
- 取代 SF-0105 的"未完成（Next）第 1、2 项"——编译缺口已合、全量已转绿。

#### 已完成
1. 编译三缺口补齐：Keys 加 `ifRange="If-Range"`/`contentRange="Content-Range"`/
   `etag="ETag"`/`lastModified="Last-Modified"`；CacheInfo 加
   `var cacheName: String? { _cacheName }`；DiskCacheCleaner.sweepIfNeeded
   加 `excluding:[String]=[]`，据此建 protected 名单（`name`/`name.part`/
   `name.part.meta`/`name.part.meta.tmp`），两条分组循环均跳过受保护文件——
   正在打开的曲子不被自己的清扫踢掉。
2. `swift build` 过。
3. 修 `_sweepLock` 实例误用 static（改 `Self._sweepLock`）。
4. 206 长度语义两处修正（StreamerCoverageTests 2 个回归用例，共 5 条断言）：
   - `responseContentLength`：206 有 Content-Range 取 `/total`；**无**
     Content-Range 时 `Content-Length` 只是分片长度，须
     `+ _resumeDownloadStart` 才是全长（此前裸返 4096）。
   - `handleResumeResponse` 206 分支：Content-Range 缺失时以所请求起点
     `_resumeDownloadStart` 兜底（`contentRangeStart(http) ?? _resumeDownloadStart`），
     不再误降级 sequential。
   - 根因另有一处：`openRemote` 算了 `start` 却从未赋
     `_resumeDownloadStart`（只有重连路径 startResumeDownload 赋值），
     首开时该值为 0 → 补 `_resumeDownloadStart = start`。
5. 全量 `swift test`（约束见 state.md）363 用例 0 失败（基线 354 + 新增
   DiskCacheCleaner 9）。ResumeCacheMeta 15/15、DiskCacheCleaner 9/9 仍绿。

#### 未完成（Next）
- 写 MacTests/ResumeCacheTests.swift（SF-0105 第 3 项的覆盖清单不变）：
  URLProtocol 拦截真实 GitHub URL，fixture 做确定性 Range 服务器。先用
  MacTests 现有 FakeServerProtocol 基础设施对齐风格。

## SF-0107
- Revision: 9
- 取代 SF-0106 的"未完成（Next）"——ResumeCacheTests 已写完全绿。

#### 已完成
1. codex-spark 交付 `MacTests/ResumeCacheTests.swift`：自带确定性 Range
   `URLProtocol`（解析 Range，回 206+Content-Range/ETag/Last-Modified，
   支持 truncateNext 截断与 delayNext 延迟；ID3v1 探针单独应答不计数），
   每测独立 scratch 缓存目录，fixture 用 `Fixtures/github-silence.mp3`
   （37206 字节）。
2. 六场景 6/6 绿，全量 369/369（363 + 新 6）：首次落容器、中断重开自
   firstMissingOffset(8192) 续传、seek 已下块先本地读、seek 空洞触发
   bytes=8192- 补齐、ETag 变→200 软重建无残留旧尾、完成后 promote 再开零网络。

#### 关键设计判定（修正我给 spark 的规格错误）
- 场景 3 spark 报"请求数 1 期望变 2"，审查后**判定生产正确、测试断言错误**：
  部分容器（8192/37206）seek 到已下块内 1024 时，空洞在 8192，**必须**发
  补齐请求，否则播放到空洞永久卡死。真正契约是"不重下已下载字节"——
  `startResumeDownload` 取 `max(position, firstMissingOffset())` = 8192，
  故 Range 是 `bytes=8192-` 而非 `bytes=1024-`；且首批字节来自磁盘
  （延迟 0.65s 之前已交付 7168 字节）。只有**完整**容器（已 promote）
  才零网络（场景 6 已覆盖）。已改测试名与断言，未动生产代码。

#### 状态
- 续传功能 Done-when 各项均有测试覆盖。余下可选项：真实 URL 的 live
  测试（离线跳过，SF-0105 即标为可选）。是否提交工作区改动由用户定夺。

## SF-0108
- Revision: 10
- 取代 SF-0107 的"余下可选项"——seek 留空洞的补齐已实现并覆盖。

#### 背景（用户提问"seek 导致下载数据不连续"）
- 读码确认 seek 路径：`APlay.seek(to:)` → 新建 Composer（新 Streamer）
  → 旧的 destroy（容器 flushMeta 留盘）→ 在新 position 打开部分容器。
- 打开部分容器：本地读循环从 position 起，遇空洞轮询等待
  （`resumeReaderShouldWait` 查 bitmap，不喂稀疏零字节）；补齐下载起点
  = `max(position, firstMissingOffset())`。故 seek 到空洞后方时
  firstMissing..position 之间留下永久空洞，下载到末尾后 `promote()` 因
  `isComplete==false` 失败，容器无法提升。安全性有底线（isComplete 闸门
  不会把稀疏文件当完整缓存），但歌曲永远无法 promote。

#### 已完成
1. `Streamer.handleEndEncountered` 的 resume 分支新增 else if：下载到达
   末尾但 `isComplete==false` 且 `firstMissingOffset < contentLength` 时，
   从 `firstMissingOffset()` 回头补齐（`startResumeDownload(at: hole)`），
   下一轮 end-of-download 再 promote。约 6 行，复用作用域内 `resume`。
2. `MacTests/ResumeCacheTests.swift` 新增
   `testSeekPastTheGapRefillsTheHoleAndPromotes`：下好开头(8192)后 seek 到
   30000，断言最终 promote 出完整文件、播放点交付尾段、两个 Range 请求
   依次为 `bytes=30000-` 与 `bytes=8192-`、重开零网络命中。
3. 前置安全确认（改动前已验）：StreamerBridge 经 `_enqueue` 把所有
   URLSession 回调转发到 `_stateQueue`，故 handleEndEncountered 在
   `_stateQueue`，可直接调 startResumeDownload；`ResumeCache` 的
   firstMissingOffset/isComplete/writeOffset 均有锁。
4. codex-spark 按主会话精确规格执行（改码+加测试），主会话审 diff 通过；
   ResumeCacheTests 7/7 绿，**全量 370/370 绿**（369 + 新 1），无回归。

#### 状态
- 续传功能 Done-when 各项齐备，且 seek 空洞也能最终补齐提升。工作区改动
  未提交，是否提交由用户定夺。

## SF-0109
- Revision: 11
- 取代 SF-0108 的下一项——真实场景测试扩展完成。

#### 已完成（用户要求"多加点真实使用场景的测试"）
1. 基建重构：新建 `MacTests/ResumeCacheTestSupport.swift`，抽出共享
   `RangeServerProtocol`（确定性 HTTP fake，支持 validators/truncate/delay/
   ignoreRange/omitContentLength/failNextWithError/statusOverride）+
   `ResumeCacheTestHarness`（每测独立 scratch 缓存目录、streamer 生命周期、
   fixture=Fixtures/github-silence.mp3 37206 字节）。`interruptedDownload(validators:)`
   支持指定首下验证器。原 7 个 ResumeCacheTests 迁移到 harness。
2. 新增 12 个端到端测试，三个文件：
   - ResumeCacheErrorRecoveryTests（4）：中途断网从 writeCursor 续传、500 重试
     保容器、seek 越界 416 报错不无限重连、补齐途中再断网仍收敛
   - ResumeCacheDegradationTests（4）：无 Content-Length 降级顺序播放、
     服务器忽略 Range 回 200 后容器从零重建、Last-Modified-only 验证、
     无验证器裸 Range
   - ResumeCacheSeekTests（4）：多次 seek 多空洞逐个补齐、seek 回 0 复用开头、
     损坏 sidecar 降级全量重下、seek 进末块播放到终点
3. **修复测试基建的关键缺陷（GPT-6 high 只读根因分析结论）**：
   `didLoad(prefix) → 立即 didFailWithError` 的故障注入会让 Foundation
   **完全不交付 body**（delegate 收到 response 确认与 error 之间无数据）。
   改为门控两阶段：发 prefix 后挂起（DispatchSemaphore），测试确认
   Streamer 收到数据（audio>=阈值）后调 `releasePendingFailure()` 才注入错误。
   这不是生产 bug——生产重连起点=writeOffset 是正确契约。
4. 断言按 writeCursor 契约修正：中途断网（10000 字节已收）重连请求
   `bytes=10000-`（非块边界、非 0）；补齐 8192 字节后再断，重连
   `bytes=16384-`。GPT-6 警告勿把重连起点改 firstMissingOffset——bitmap
   partial 计数会因区间重叠误标记完整块，保留 writeOffset 方案。
5. 修 testSeekPastTheGap 的 flaky：音频断言由同步读改为 waitUntil
  （reader 在 _readQueue 异步交付，promote 成立时可能尚未交付）。
6. ResumeCacheDegradation 两测试的规格缺陷（我最初写错）：首下用
   validators=.both 存了 ETag 后再改服务器 validators 无法改变已持久化
   的 meta，改用 `interruptedDownload(validators: .lastModifiedOnly/.none)`
   让首下就用对应验证器。
7. **全量 382/382 绿**（370 + 12 新），连跑 4 轮 ResumeCacheTests 稳定。

#### 结论
- ID3 探针污染主响应的假设被排除（探针用 config.session，主请求用独立
  session，不共享 delegate）。
