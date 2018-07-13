//
//  PlayList.swift
//  APlay
//
//  Created by lincoln on 2018/5/23.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

/// A List for APlay
public final class PlayList {
    public private(set) lazy var playingIndex: Int? = nil
    public private(set) lazy var list: [URL] = []

    var loopPattern: LoopPattern = .order { didSet { updateRandomList() } }

    private lazy var _randomList: [URL] = []

    #if DEBUG
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    public init() {}

    public func changeList(to value: [URL], at index: Int) {
        list = value
        playingIndex = index
        updateRandomList()
    }

    public func nextURL() -> URL? {
        guard list.count > 0 else { return nil }
        switch loopPattern {
        case .order: return _nextURL(pattern: .order)
        case .random: return _nextURL(pattern: .random)
        case .single: return _nextURL(pattern: .single)
        case let .stopWhenAllPlayed(mode): return _nextURL(pattern: mode)
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

    private func _nextURL(pattern: LoopPattern) -> URL? {
        var index = 0
        switch pattern {
        case .order:
            if let idx = playingIndex { index = idx + 1 }
            if index >= list.count { index = 0 }
            playingIndex = index
            let url = list[index]
            return url
        case .random:
            if let idx = playingIndex { index = idx + 1 }
            if index >= list.count { index = 0 }
            playingIndex = index
            let url = _randomList[index]
            return url
        case .single:
            if let idx = playingIndex { index = idx }
            playingIndex = index
            let url = list[index]
            return url
        case let .stopWhenAllPlayed(mode):
            if let idx = playingIndex, idx == list.count - 1 { return nil }
            switch mode {
            case .order: return _nextURL(pattern: .order)
            case .random: return _nextURL(pattern: .random)
            case .single: return _nextURL(pattern: .single)
            case let .stopWhenAllPlayed(mode2): return _nextURL(pattern: mode2)
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
        case .single: return _nextURL(pattern: .single)
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
    }
}
