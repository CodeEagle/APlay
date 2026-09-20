//
//  PlayList.swift
//  APlay
//
//  Created by lincoln on 2018/5/23.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

/// A List for APlay
public final class PlayList: @unchecked Sendable {
    public private(set) lazy var playingIndex: Int? = nil
    public private(set) lazy var list: [URL] = []

    var loopPattern: LoopPattern = .order { didSet { updateRandomList() } }

    private lazy var _randomList: [URL] = []
    public var randomList: [URL] {
        if loopPattern == .random { return _randomList }
        return []
    }

    public var currentList: [URL] {
        if loopPattern == .random { return _randomList }
        return list
    }

    private unowned let _pipeline: Delegated<APlay.Event, Void>

    #if DEBUG
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    init(pipeline: Delegated<APlay.Event, Void>) {
        _pipeline = pipeline
    }

    public func changeList(to value: [URL], at index: Int) {
        list = value
        updateRandomList()
        playingIndex = index
        let list = loopPattern == .random ? _randomList : value
        _pipeline.call(.playlistChanged(list, index))
        _pipeline.call(.playingIndexChanged(index))
    }

    public func nextURL() -> URL? {
        guard let (index, url) = _peekNextFromLoopPattern() else { return nil }
        playingIndex = index
        return url
    }

    /// The URL `nextURL()` would advance to, without moving `playingIndex`.
    /// Gapless playback uses it to start buffering the following track while the
    /// current one is still playing.
    public func peekNextURL() -> URL? {
        return _peekNextFromLoopPattern()?.url
    }

    private func _peekNextFromLoopPattern() -> (index: Int, url: URL)? {
        guard list.count > 0 else { return nil }
        switch loopPattern {
        case .order: return _peekNext(pattern: .order)
        case .random: return _peekNext(pattern: .random)
        case .single: return _peekNext(pattern: .single)
        case let .stopWhenAllPlayed(mode): return _peekNext(pattern: mode)
        }
    }

    public func previousURL() -> URL? {
        guard list.count > 0 else { return nil }
        switch loopPattern {
        case .order: return _previousURL(pattern: .order)
        case .random: return _previousURL(pattern: .random)
        case .single: return _previousURL(pattern: .single)
        case let .stopWhenAllPlayed(mode): return _previousURL(pattern: mode)
        }
    }

    /// Pure variant of `nextURL()`: reports where the list would go next
    /// without touching `playingIndex`, so `nextURL()` and `peekNextURL()` stay
    /// two views of the same decision.
    private func _peekNext(pattern: LoopPattern) -> (index: Int, url: URL)? {
        var index = 0
        switch pattern {
        case .order:
            if let idx = playingIndex { index = idx + 1 }
            if index >= list.count {
                if loopPattern.isGonnaStopAtEndOfList {
                    return nil
                }
                index = 0
            }
            guard let url = list[ap_safe: index] else { return nil }
            return (index, url)
        case .random:
            if let idx = playingIndex { index = idx + 1 }
            if index >= _randomList.count {
                if loopPattern.isGonnaStopAtEndOfList {
                    return nil
                }
                index = 0
            }
            guard let url = _randomList[ap_safe: index] else { return nil }
            return (index, url)
        case .single:
            // A single loop wrapped in stopWhenAllPlayed only stops once the
            // last track is reached; until then it repeats the current one.
            // Checking the flag without the position stops the list at the
            // first track instead of the last.
            if loopPattern.isGonnaStopAtEndOfList, playingIndex == list.count - 1 {
                return nil
            }
            if let idx = playingIndex { index = idx }
            guard let url = list[ap_safe: index] else { return nil }
            return (index, url)
        case let .stopWhenAllPlayed(mode):
            if let idx = playingIndex, idx == list.count - 1 { return nil }
            switch mode {
            case .order: return _peekNext(pattern: .order)
            case .random: return _peekNext(pattern: .random)
            case .single: return _peekNext(pattern: .single)
            case let .stopWhenAllPlayed(mode2): return _peekNext(pattern: mode2)
            }
        }
    }

    private func _previousURL(pattern: LoopPattern) -> URL? {
        switch pattern {
        case .order:
            var index = 0
            if let idx = playingIndex { index = idx }
            if index == 0 { index = list.count - 1 }
            else { index -= 1 }
            playingIndex = index
            return list[ap_safe: index]
        case .random:
            var index = 0
            if let idx = playingIndex { index = idx }
            if index == 0 { index = _randomList.count - 1 }
            else { index -= 1 }
            playingIndex = index
            return _randomList[ap_safe: index]
        case .single: return _peekNext(pattern: .single).map { $0.url }
        case let .stopWhenAllPlayed(mode): return _previousURL(pattern: mode)
        }
    }

    private func updateRandomList() {
        if loopPattern == .random {
            _randomList = list.shuffled()
        } else {
            _randomList = []
        }
    }

    func play(at index: Int) -> URL? {
        guard let url = list[ap_safe: index] else { return nil }
        if loopPattern == .random {
            if let idx = _randomList.firstIndex(of: url) {
                playingIndex = idx
                return url
            }
        }
        playingIndex = index
        _pipeline.call(.playingIndexChanged(index))
        return url
    }
}

// MARK: - Enums

extension PlayList {
    public indirect enum LoopPattern: Equatable {
        case single
        case order
        case random
        case stopWhenAllPlayed(LoopPattern)

        var isGonnaStopAtEndOfList: Bool {
            switch self {
            case .stopWhenAllPlayed: return true
            default: return false
            }
        }
    }
}
