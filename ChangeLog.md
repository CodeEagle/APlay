v2.1.0
---
>2026.09.19

1. New: gapless playback between tracks of a playlist. With
   `Configuration(gaplessPlaybackEnabled: true)` the next track is preloaded while the
   current one is still playing, and at end of track the output audio unit swaps in the
   buffered source atomically — it never stops and restarts, so there is no gap, click
   or state dip to `.paused` at the handoff. Same-format tracks are seamless;
   a transition between different audio formats still needs a re-setup and is not seamless
2. Fix ALAC playback: the magic cookie is now fed to the audio converter, so ALAC files
   decode instead of failing with an unsupported-format error
3. Fix WAVE files that carry extra chunks between the header and the data chunk: parsing
   now skips unknown chunks instead of misreading the stream
4. Map audiobook (.m4b), Dolby (.ac3/.eac3) and speech (.aiff spoken) extensions in the
   format hint table so the right decoder is selected up front
5. Recover from transient server errors (HTTP 5xx) by reconnecting instead of reporting
   end of stream

v2.0.0
---
>2026.09.19

Major release: the pre-iOS-11 legacy stack is gone (deployment target is now iOS 15),
so this is not source/drop-in compatible with the 0.x line — the v1.3.x entries below
are the migration steps that landed in this same modernization.

1. New: `APlay.prepare(_:)` preloads a track without starting the output audio unit (issue #14).
   The streamer and decoder run and fill the ring buffer; a subsequent `play(_:)` of the same URL
   picks up the buffered data and starts instantly instead of reopening the stream
2. Fix a reachable deadlock at teardown: the `deinit` of `APlay`, `InternalLogger` and `GCDTimer`
   hopped to their own property queue via `sync`, which traps when the last release happens on
   that queue itself (all queued work captures `self`, so `deinit` now touches the backing
   storage inline under its exclusive access)
3. Fix the single-open race in `Streamer`: `open()` claims the opened flag synchronously at the
   entry point, so a second `open()` before the async open completes is rejected
4. Opus decode-by-injection (issue #17): `AudioFileType.opus` is delivered to a custom decoder
   through the existing `audioDecoderBuilder` seam — an injected decoder observes the stream's
   file hint at `prepare(for:at:)` and can decode a format Core Audio does not ship
5. Unit test suite added (`swift test`, 35 tests): `Uroboros` ring buffer, `PlayList` ordering,
   ID3/FLAC tag parsers, `Streamer` local paths, and `Composer` coordination covering the event
   flow, preloading and the injected-decoder hint

v1.3.1
---
>2026.09.19

1. Fix local-file playback: the decoder's audio file stream was opened only *after* the streamer
   had already delivered and dropped the leading chunks, so the parser started mid-file and
   failed with "unsupported file type". For local files `.readyForRead` is now posted before
   the read stream is opened, so the parser exists when the first bytes arrive
2. Fix `AudioOutputUnitStart` failing with `-10867` (`kAudioUnitErr_CannotDoInCurrentContext`)
   in the iOS 11+ player: the output audio unit is now explicitly initialized after the render
   callback and stream format are (re)configured
3. Make `APlay.Event`, `APlay.State` and `APlay.Error` public. `eventPipeline` and `state` were
   already public but referenced internal types, which made the primary delegate API unusable
   from a binary framework
4. Cross-platform hygiene: `APlayImage` typealias (`UIImage` on iOS / `NSImage` on macOS),
   audio-session and background-task code guarded to iOS, and the pre-iOS-10 `AVAudioSession`
   workaround dropped (deployment target is iOS 15)
5. Swift Package Manager support, including an end-to-end macOS playback validation target
   (`APlayMacPlayback`) and a non-audio smoke test
6. Network layer: `Streamer` now streams through `URLSession` (inheriting
   `Configuration.session`'s configuration and challenge policy) instead of the deprecated
   `CFReadStreamCreateForHTTPRequest` / `CFHTTPMessage` stack. HTTPS streaming now works
   (it previously failed with `-9824`), reconnect watchdogs run on `DispatchSourceTimer`,
   local files are read through `FileHandle` so seeking works without HTTP range semantics,
   and the `RunloopQueue` shim is gone. Legacy pure-`ICY 200 OK` Shoutcast streams remain
   unsupported (non-standard status line); standard HTTP with `icy-metaint` still parses metadata

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
7. Decode loop: skip the per-tick converter allocation and fill when no packets are queued —
   reports the same `.empty` event while keeping the idle/buffering loop cheap (lower CPU)

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
