State format: capsule-v2
State revision: 11

## Context
- Root: /Users/lincoln/Develop/GitHub/APlay（CodeEagle/APlay，master）
- Baseline: 2026-10-08；工作区未提交续传四件套（ResumeCacheMeta/ResumeCache/
  DiskCacheCleaner/Streamer 改动）+ 测试文件 + github-silence.mp3 fixture。
  全量 382 测试已转绿（370 + 12 新真实场景测试）。

## Task
- Goal: 网络歌曲断点续传——预分配本地容器、按位置填充、未下完下次也能复用；
  seek/重入能复用缓存，缺块自动 Range 补网，播放无感；真实场景测试覆盖。
- Unit: StreamProvider 层（Streamer/ResumeCache/ResumeCacheMeta/
  DiskCacheCleaner）+ MacTests 续传测试矩阵。
- Done when: 部分缓存可复用；seek 到已下载块走本地读；空洞自动 Range 补齐；
  内容变更自动作废重建；全量测试转绿；含降级路径与真实 GitHub 音频的
  seek/重入/补齐测试；含网络错误/服务器能力差异/多次 seek 场景。

## Progress
- Done: CacheMeta 两 bug 修复，15/15 绿。
- Done: DiskCacheCleaner + 9 测试绿（含 excluding 保护当前曲目）。
- Done: ResumeCache.swift（容器写入侧，锁保护）。
- Done: Streamer.swift 集成并编译通过；handleEndEncountered 末尾有洞则自
  firstMissingOffset 回头补齐。
- Done: 共享测试基建 ResumeCacheTestSupport（RangeServerProtocol 门控故障
  注入 + ResumeCacheTestHarness），原 7 测试迁移。
- Done: 12 个新真实场景测试：ErrorRecovery 4（断网续传/500/416/补齐中断）、
  Degradation 4（无 CL/忽略 Range/Last-Modified/无验证器）、Seek 4
  （多空洞/seek 回 0/坏 sidecar/末块）。
- Done: 全量 382/382 绿，关键测试连跑 4 轮稳定。
- Open: 无功能缺口。
- Checks: 全量 382/382 绿；swift build 过。
- Pending: 工作区改动未提交，是否提交由用户定夺。

## Rules
- Constraints: swift test 需 CLANG_MODULE_CACHE_PATH=/private/tmp/aplay-midi-clang-cache
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/aplay-midi-swift-cache
  --disable-sandbox --scratch-path /private/tmp/aplay-midi-build
  --cache-path /private/tmp/aplay-midi-cache。禁止破坏 ICY/无 Content-Length
  的现有行为（降级而非报错）。
- 委派：atria/atria2 runner 均崩（基础设施级），改用 codex-spark/codex-luna；
  深度根因分析用 codex-gpt6-high（只读），结论交主会话执行。
- 设计红线：bitmap 严格整块；handle(data:) resume 分支不 post 不喂解析器；
  软重建不截断正读容器；单 Streamer 内 position 固定（seek 重建 Composer）；
  206 无 Content-Range 时长度 = Content-Length + _resumeDownloadStart。
- 关键契约：部分容器 seek 到已下块仍须后台补齐（max(position,
  firstMissingOffset()) 起的 Range）；重连起点 = **writeCursor（writeOffset）**
  而非 firstMissingOffset——bitmap partial 计数会因区间重叠误标记完整块。
- 测试基建：中途断网必须门控注入（releasePendingFailure），因 Foundation
  在 response 确认与 error 之间不交付立即跟随的 body。

## Next
- Action: 等用户决定是否提交工作区改动（git commit），或继续其它任务。
- Verify: 若提交，提交后 git status 干净且 swift test 全量仍 382/382 绿。
- Refs: SF-0104（设计）；SF-0105（阶段事实）；SF-0106（编译与 206 修复）；
  SF-0107（ResumeCacheTests 全绿、场景 3 契约判定）；SF-0108（seek 空洞
  回补实现）；SF-0109（12 真实场景测试、门控故障注入、writeCursor 契约）
