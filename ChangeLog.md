v1.3.0
---
>2026.09.18

1. Upgrade to Swift 6 language mode with strict concurrency checking enabled
2. Raise the deployment target to iOS 15.0 (Xcode 26+ toolchain)
3. Fix dangling pointers around `AudioConverter` (packet description pointed at a stack local,
   buffers passed via unscoped `inout`) — this was the root cause of the "can only run in DEBUG"
   optimization-mode stall, so `Release` builds now optimize normally
4. Mark internally-synchronized types `@unchecked Sendable`; constants that were `static var` are
   now `static let`
5. Demo: `@UIApplicationMain` → `@main`
6. Expose built-in `NBandEQ` band gains at runtime via `APlay.setEqualizerBandGain(_:at:)`
   (band frequencies were already configurable via `Configuration.equalizerBandFrequencies`)

v0.0.5
---
>2019.01.14

1. Support `stopWhenAllPlayed` mode
2. Add interruption handler, fixed auto fill `metadata` bug

v0.0.4
---
>2018.10.14

1. Change playlist also triiger event `playingIndexChanged`
2. Alter `PlayList` init method to internal
3. Fixed reconnect not working

v0.0.3
---
>2018.07.20

1. Add support for play a list at certain index
2. Change defaultCoverImage to allow modify on runtime
3. Change Connenct node location to avoid requst permission that using microphone
4. Support to set metadata on the fly
5. Change verbose log at debug level
6. Support to play at certain index and output index changed event
7. Fixed resume/pause Not set the right value in NowPlayingCenter
8. change fraquency of decode timer
9. Fixed glitches, format code, avoid memcpy when output decoded audio


v0.0.2
---
>2018.07.13

0. Changed optimization mode for release, or it will cause a cpu halt bug
1. Remove debug log in release mode
2. Remove repeated reset() function log

v0.0.1
---
>2018.07.09

First Release.
