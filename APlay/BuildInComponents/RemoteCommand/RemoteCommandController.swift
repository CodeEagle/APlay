//
//  RemoteCommandController.swift
//  APlay
//
//  Lock screen / Control Center / AirPlay 2 remote control.
//
//  The audio session is already configured with the long-form-audio route
//  sharing policy AirPlay 2 expects (see `Configuration.startBackgroundTask`);
//  what is missing for a HomePod, an Apple TV or the iOS lock screen to
//  *control* playback is a set of `MPRemoteCommand` handlers. Without them the
//  controls are present but inert — the command center has no now-playing info
//  sink to talk to. This wires the system commands to the player's own API.
//

#if os(iOS)
    import MediaPlayer

extension APlay {
    /// Hooks `MPRemoteCommandCenter` shared instance commands to this player.
    ///
    /// Created by `APlay` when `Configuration.isEnabledRemoteCommandHandling`
    /// is on. Owned by the player for its lifetime, so the targets stay
    /// installed as long as the player is alive.
    final class RemoteCommandController: @unchecked Sendable {
        private unowned let player: APlay
        /// Skip-forward / skip-backward jump length, in seconds.
        let skipInterval: TimeInterval = 15

        #if DEBUG
            deinit {
                debug_log("\(self) \(#function)")
            }
        #endif

        init(player: APlay) {
            self.player = player
            let center = MPRemoteCommandCenter.shared()

            center.playCommand.addTarget { [weak player] _ in
                guard let player = player else { return .commandFailed }
                player.resume()
                return .success
            }

            center.pauseCommand.addTarget { [weak player] _ in
                guard let player = player else { return .commandFailed }
                player.pause()
                return .success
            }

            center.togglePlayPauseCommand.addTarget { [weak player] _ in
                guard let player = player else { return .commandFailed }
                player.toggle()
                return .success
            }

            center.nextTrackCommand.addTarget { [weak player] _ in
                guard let player = player else { return .commandFailed }
                player.next()
                return .success
            }

            center.previousTrackCommand.addTarget { [weak player] _ in
                guard let player = player else { return .commandFailed }
                player.previous()
                return .success
            }

            center.changePlaybackPositionCommand.addTarget { [weak player] event in
                guard let player = player,
                      let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                guard player.seekable() else { return .commandFailed }
                player.seek(to: event.positionTime)
                return .success
            }

            center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipForwardCommand.addTarget { [weak player] _ in
                guard let player = player, player.seekable() else { return .commandFailed }
                player.seek(to: player.currentTime() + 15)
                return .success
            }

            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipBackwardCommand.addTarget { [weak player] _ in
                guard let player = player, player.seekable() else { return .commandFailed }
                player.seek(to: max(0, player.currentTime() - 15))
                return .success
            }
        }
    }
}
#endif
