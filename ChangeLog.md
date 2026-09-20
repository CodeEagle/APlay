v2.1.0
---
>2026.09.20

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
6. Fix a crash on device when the gapless preloader reaches the audio-session setup
   from a background queue: `startBackgroundTask`/`endBackgroundTask` were guarded by a
   main-thread assertion that trapped off the main thread; the work is now dispatched
   to the main thread instead of assumed onto it
7. Fix end-of-track detection for streams that report no usable duration (opus in an ogg
   container exposes none that Core Audio honours, and the estimate can even come back
   NaN mid-parse). Playback time that stops advancing after the stream is fully received
   now ends the track, so such files advance through a playlist instead of stalling
8. The demo app adopts the UIScene lifecycle (required to launch on iOS 17+) and ships
   every bundled audio format as a playable sample, so a device run shows at a glance
   which formats this platform decodes
9. Installation is Swift Package Manager only: the CocoaPods spec and the Carthage
   mention are gone, and the release lane bumps the `APlay.version` Swift constant
   instead of a podspec
10. The README documents the supported-format matrix pinned by
   `FormatCompatibilityTests` — what the real decoder both parses and decodes to
   PCM (AAC, MP3, FLAC, Opus-in-OGG, WAVE, ALAC), and what only parses today
   (ALAC-in-CAF, AIFF/AIFF-C); local files in those two formats play through the
   optional library in 11.
11. New: optional `APlayExtras` companion library for the seekable file formats the
   built-in streaming decoder cannot open (ALAC-in-CAF, AIFF/AIFF-C). Local files in
   those containers route through an `ExtAudioFile`-backed decoder injected through the
   same `audioDecoderBuilder` seam; everything else falls through to a builder you supply,
   so an app that already injects a custom decoder wraps it instead. Add the product only
   when you need it — plain `APlay` is unchanged, and the new decoder is covered by
   `SeekableFileDecoderTests` plus an end-to-end macOS playback run
12. New: AirPlay 2 / remote-control support. The audio session already ran the
   long-form-audio route sharing policy AirPlay 2 expects; the lock screen,
   Control Center and AirPlay 2 route commands (play, pause, toggle, next,
   previous, change-position, ±15 s skip) are now wired to the player by
   default through `MPRemoteCommandCenter`, gated by
   `Configuration(enableRemoteCommandHandling:)`. Route picking stays app-level
   UI — add your own `AVRoutePickerView` — and now-playing metadata was already
   published to `MPNowPlayingInfoCenter`
13. tvOS 15+ and visionOS 1+ are now supported platforms (the package already shipped
   for macOS 12+ and iOS 15+). visionOS behaves like iOS — the audio session runs the
   long-form-audio route sharing policy and the lock screen / AirPlay 2 remote commands
   are wired; tvOS has no `AVAudioSession`, `MPNowPlayingInfoCenter` or background-task
   concept, so those stay compiled out there and playback runs on the decoder, ring
   buffer and render path alone. The image typealias, the default user agent and every
   platform branch were widened to match
14. Test coverage: the ID3 and FLAC tag parsers are pinned by byte-level tests —
   ID3v2.2/2.3/2.4 text frames, sync-safe sizes, the extended-header skip, APIC
   covers, the unknown-frame `.other` fallback, ID3v1 and v1.1 local files, plus FLAC
   vorbis comments, padding and undefined block types. ID3Parser line coverage rose
   from 28% to 92%, FlacParser from 37% to 55%, and the package total to 81%
15. Fix ID3v2.3 APIC cover parsing: the picture type is the byte after the mime
   type's terminator (not the terminator itself), the description is skipped past
   its own \0, and the cover slice now spans the rest of the frame body instead of
   `readlength + frameSize`, which mis-sliced every embedded cover. Unknown frames'
   `.other` text is trimmed of its terminator, and ID3v2.2/v2.3 unsynchronisation
   (the $00 inserted after every $FF) is now undone over the whole tag body, so
   frames behind the flag decode instead of reading garbage lengths
16. Harden the FLAC parser against truncated or hostile metadata blocks: vorbis
   comment vendor/comment lengths, picture mime/description/width/height/data
   lengths, CUESheet track and index counts, SeekTable trailing points and
   Application block sizes are all clamped to the bytes actually present, so a bad
   length field fails closed instead of reading out of bounds. Four byte-level
   robustness tests pin the clamps; FlacParser line coverage rose from 55% to 83%
   and the package total to 82.5%
17. The built-in equalizer actually works now, and presets manage it: the
   `AVAudioUnitEQ` node was created with 16 bypassed bands on a generic log scale
   and never wired up, so `setEqualizerBandGain` was a no-op. It is now built from
   `Configuration.equalizerBandFrequencies` with every band unbypassed — low shelf,
   high shelf, parametric in between — and the gains reach the audio unit at
   runtime. `EqualizerPreset` carries a named curve as plain data (ten bundled:
   flat / rock / pop / jazz / classical / bass / treble / vocal / electronic /
   acoustic); `applyEqualizerPreset(_:)` sets every band without restarting
   playback, `equalizerGains` reads the live curve back, and a preset whose band
   count does not match the configuration is ignored and logged rather than
   shifting the wrong frequencies
18. Test coverage: the logic layers that were only exercised through the playback
   stack now have direct tests — the utility extensions and `AudioFileType`
   wrapper, `Configuration` defaults/policies/builder injection, `PlayList`'s loop
   patterns and event publishing, `Uroboros`' semaphore handshake and defensive
   clamps, `APlay`'s player-facing API, the `InternalLogger`, and the
   `APlayExtras` container router's rebuild/pause/destroy bookkeeping. Package
   line coverage rose from 74.8% to 81% (226 tests, was 94)
19. Fix `.stopWhenAllPlayed(.single)`: a playlist in that mode never advanced,
   because `_peekNext(.single)` consulted the outer stop flag without looking at
   the playing position, so `nextURL()`/`previousURL()` returned nil at the first
   track. The stop is now only taken on the last track, matching what the
   `.order` and `.random` branches already did
20. The demo app is rebuilt in SwiftUI as a showcase of every library capability:
   a live format matrix that plays each bundled container and badges the route
   that serves it (native streaming decoder, or `APlayExtras` ExtAudioFile for
   AIFF/AIFF-C/CAF), a Now Playing card with generated cover art injected into
   the lock screen, an 8-band equalizer with the built-in presets, the four loop
   patterns plus a gapless toggle, remote-URL streaming, a read-out of the
   active configuration, and a live view of the event pipeline and the internal
   logger. It also adopts the SwiftUI hosting lifecycle and the `audio`
   background mode so background playback and remote commands work. `APlayExtras`
   is now an Xcode framework target as well as an SPM product, so the Xcode
   project builds the same library set the package does

21. Fix the same class of off-main crash as 6 in a second place: the default
   user-agent string read `UIDevice.current.systemVersion` through a
   `MainActor.assumeIsolated` assertion, and a configuration is constructed
   wherever a decoder builder runs — the documented `APlayExtras` routing
   pattern builds one on background queues, which the gapless preloader hits.
   The OS version now comes from `ProcessInfo` instead, which is safe from any
   thread
22. Fix switching tracks mid-playback going silent: `APlayer.updatePlayerConfig`
   re-initializes the output audio unit (uninitialize, then initialize again so
   a format change does not trip `-10867`), but that pair also *stops* a unit
   that was running, while the cached player state stayed `.running`. The next
   track's `resume()` therefore hit its "already running" guard and skipped
   `AudioOutputUnitStart` altogether — the new track neither made a sound nor
   reported a state change. The cached state now follows the unit: if it was
   running before the re-init, it flips to `.paused` so the takeover resumes it
   properly
23. Fix a stale end-of-track pause clobbering the track the user switched to:
   the delayed pause `APlay` schedules when a track finishes its cooldown ran
   on a main-queue timer with no notion of *which* track it was scheduled for.
   Switch tracks before it fired and the pause stopped the new track's output
   unit on the old track's schedule and then advanced the playlist from the
   wrong position. The pause now captures the composer it belongs to and
   cancels itself (clearing its one-shot flag) if the active composer has moved
   on, so a track change during the cooldown is clean
24. Fix gapless playback hanging a track or two into a playlist (reported as
   gapless AAC-ADTS playback getting stuck, with the UI frozen and the track
   never advancing): the preloader opened the next track's stream from the
   main-queue tail of the end-of-track handoff, so while the very first preload
   ran on a background queue, every subsequent one ran on the main thread. The
   open does synchronous file work and a cross-queue close, which blocked the
   very queue that had to finish the handoff — the end-of-track flag stayed
   set, the next track never took over, and the render loop spun on silence
   indefinitely. The stream is now opened off the main thread, and the
   buffering-ahead flags are set synchronously before the open so a track
   registered as the preload still has its events withheld and the output unit
   left alone until the handoff

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
