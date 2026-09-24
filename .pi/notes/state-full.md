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
