//
//  GCDTimer.swift
//  APlay
//
//  Created by lincoln on 2018/5/23.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

final class GCDTimer {
    private static var count = 0
    private(set) var index = 0
    private lazy var _timerQueue = DispatchQueue(label: "GCDTimer", qos: .userInitiated)
    private lazy var _timer: DispatchSourceTimer? = nil
    private lazy var _stateQueue = DispatchQueue(name: "GCDTimer.State")
    private lazy var _isStopped = false
    private lazy var _action: ((GCDTimer) -> Void)? = nil
    private var _name: String

    deinit {
        _timer?.setEventHandler {}
        _timer?.cancel()
        let isStopped = _stateQueue.sync { _isStopped }
        if isStopped { _timer?.resume() }
        debug_log("\(self)[\(_name)] \(#function)")
    }

    init(interval: DispatchTimeInterval, callback: @escaping (GCDTimer) -> Void, name: String = #file) {
        _name = name.components(separatedBy: "/").last ?? name
        GCDTimer.count = GCDTimer.count &+ 1
        index = GCDTimer.count
        _action = callback
        let timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: _timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: { [weak self] in
            guard let sself = self else { return }
            let isStopped = sself._stateQueue.sync { sself._isStopped }
            guard isStopped == false else { return }
            sself._action?(sself)
        })
        _isStopped = true
        _timer = timer
    }

    func invalidate() {
        _action = nil
        _timer?.setEventHandler(handler: nil)
        pause()
    }

    func pause() {
        _stateQueue.sync {
            guard _isStopped == false else { return }
            _timer?.suspend()
            _isStopped = true
        }
    }

    func resume() {
        _stateQueue.sync {
            guard _isStopped == true else { return }
            _timer?.resume()
            _isStopped = false
        }
    }
}

// MARK: - Hashable

extension GCDTimer: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
    }
    
    static func == (lhs: GCDTimer, rhs: GCDTimer) -> Bool {
        return lhs.index == rhs.index
    }
}
