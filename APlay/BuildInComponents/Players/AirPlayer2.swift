//
//  AirPlayer2.swift
//  APlay
//
//  Created by Lincoln on 2018/9/28.
//  Copyright © 2018 SelfStudio. All rights reserved.
//

import Foundation
@available(iOS 11.0, *)
final class AirPlayer2: PlayerCompatible {
    // MARK: PlayerCompatible
    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) }

    var eventPipeline: Delegated<Player.Event, Void> = Delegated<Player.Event, Void>()

    var startTime: Float = 0 {
        didSet {
            _stateQueue.async(flags: .barrier) { self._progress = 0 }
        }
    }

    lazy var asbd: AudioStreamBasicDescription = AudioStreamBasicDescription()

    private(set) var state: Player.State {
        get { return _stateQueue.sync { _state } }
        set {
            _stateQueue.async(flags: .barrier) {
                self._state = newValue
                self.eventPipeline.call(.state(newValue))
            }
        }
    }

    var volume: Float {
        get { return _volume }
        set {
            _volume = newValue
            #if os(iOS)
//            if let unit = _player {
//                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
//            }
            #else
//            if let unit = _player {
//                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
//            }
            #endif
        }
    }

    // MARK: Private vars



    fileprivate lazy var _progress: Float = 0
    private lazy var _volume: Float = 1



    private lazy var _state: Player.State = .idle
    private lazy var _stateQueue = DispatchQueue(concurrentName: "AUPlayer.state")


    // MARK: Life cycle
    init(config: ConfigurationCompatible) {

    }
    
}
// MARK: - PlayerCompatible
@available(iOS 11.0, *)
extension AirPlayer2 {
    func destroy() {

    }

    func pause() {

    }

    func resume() {

    }

    func toggle() {

    }

    func setup(_: AudioStreamBasicDescription) {

    }

    func currentTime() -> Float {
        return 0
    }


}
