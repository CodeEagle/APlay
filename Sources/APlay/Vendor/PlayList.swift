/// A List for APlay
public final class PlayList {
    // MARK: - Properties

    @Published private var _playingIndex: PlayingIndex = .none
    @Published private var _list: [URL] = []
    @Published private var _loopPattern: LoopPattern = .order
    @Published private var _randomList: [URL] = []

    private let _queue = DispatchQueue(concurrentName: "PlayList")

    // MARK: - Life cycle methods

    #if DEBUG
        deinit { debug_log("\(self) \(#function)") }
    #endif

    public init() {}
}

// MARK: - Public Property

public extension PlayList {
    var playingIndexPublisher: AnyPublisher<PlayingIndex, Never> {
        return $_playingIndex.eraseToAnyPublisher()
    }

    var listPublisher: AnyPublisher<[URL], Never> {
        return $_list.eraseToAnyPublisher()
    }

    var loopPatternPublisher: AnyPublisher<LoopPattern, Never> {
        return $_loopPattern.eraseToAnyPublisher()
    }

    var randomListPublisher: AnyPublisher<[URL], Never> {
        return $_randomList.eraseToAnyPublisher()
    }

    private(set) var list: [URL] {
        get { return _queue.sync { _list } }
        set { _queue.async(flags: .barrier) { self._list = newValue } }
    }

    private(set) var playingIndex: PlayingIndex {
        get { return _queue.sync { _playingIndex } }
        set { _queue.async(flags: .barrier) { self._playingIndex = newValue } }
    }

    private(set) var loopPattern: LoopPattern {
        get { return _queue.sync { _loopPattern } }
        set {
            _queue.async(flags: .barrier) {
                self._loopPattern = newValue
                let rList = newValue == .random ? self._list.shuffled() : []
                self._randomList = rList
            }
        }
    }

    private(set) var randomList: [URL] {
        get { return _queue.sync { _randomList } }
        set { _queue.async(flags: .barrier) { self._randomList = newValue } }
    }

    var currentList: [URL] {
        return _queue.sync { _loopPattern == .random ? _randomList : _list }
    }
}

// MARK: - Public Method

public extension PlayList {
    func addPlayingIndexSubscriber(_ sc: AnySubscriber<PlayingIndex, Never>) {
        $_playingIndex.receive(subscriber: sc)
    }

    func addListSubscriber(_ sc: AnySubscriber<[URL], Never>) {
        $_list.receive(subscriber: sc)
    }

    func addLoopPatternSubscriber(_ sc: AnySubscriber<LoopPattern, Never>) {
        $_loopPattern.receive(subscriber: sc)
    }

    func addRandomListSubscriber(_ sc: AnySubscriber<[URL], Never>) {
        $_randomList.receive(subscriber: sc)
    }

    func nextURL() -> URL? {
        guard list.count > 0 else { return nil }
        switch loopPattern {
        case .order: return _nextURL(pattern: .order)
        case .random: return _nextURL(pattern: .random)
        case .single: return _nextURL(pattern: .single)
        case let .stopWhenAllPlayed(mode): return _nextURL(pattern: mode)
        }
    }

    func previousURL() -> URL? {
        guard list.count > 0 else { return nil }
        switch loopPattern {
        case .order: return _previousURL(pattern: .order)
        case .random: return _previousURL(pattern: .random)
        case .single: return _previousURL(pattern: .single)
        case let .stopWhenAllPlayed(mode): return _previousURL(pattern: mode)
        }
    }

    func changeList(to value: [URL], at index: UInt) {
        _queue.async(flags: .barrier) {
            self.syncChange(to: value, at: index)
        }
    }

    private func syncChange(to value: [URL], at index: UInt) {
        /// first list changed, and then the playing index
        _list = value
        _randomList = _loopPattern == .random ? value.shuffled() : []
        _playingIndex = .some(index)
    }

    internal func play(at index: UInt) -> URL? {
        return _queue.sync {
            guard let url = _list[ap_safe: index] else { return nil }
            if _loopPattern == .random {
                if let idx = _randomList.firstIndex(of: url) {
                    _playingIndex = .some(UInt(idx))
                    return url
                }
            }
            _playingIndex = .some(index)
            return url
        }
    }
}

// MARK: - Private

private extension PlayList {
    func _nextURL(pattern: LoopPattern) -> URL? {
        var index: UInt = 0
        switch pattern {
        case .order:
            if let idx = playingIndex.value { index = idx + 1 }
            if index >= list.count {
                if loopPattern.isGonnaStopAtEndOfList { return nil }
                index = 0
            }
            playingIndex = .some(index)
            let url = list[index]
            return url

        case .random:
            if let idx = playingIndex.value { index = idx + 1 }
            if index >= list.count {
                if loopPattern.isGonnaStopAtEndOfList { return nil }
                index = 0
            }
            playingIndex = .some(index)
            let url = randomList[index]
            return url

        case .single:
            if loopPattern.isGonnaStopAtEndOfList { return nil }
            if let idx = playingIndex.value { index = idx }
            playingIndex = .some(index)
            let url = list[index]
            return url

        case let .stopWhenAllPlayed(mode):
            if let idx = playingIndex.value, Int(idx) == list.count - 1 { return nil }
            switch mode {
            case .order: return _nextURL(pattern: .order)
            case .random: return _nextURL(pattern: .random)
            case .single: return _nextURL(pattern: .single)
            case let .stopWhenAllPlayed(mode2): return _nextURL(pattern: mode2)
            }
        }
    }

    func _previousURL(pattern: LoopPattern) -> URL? {
        switch pattern {
        case .order:
            var index: UInt = 0
            if let idx = playingIndex.value { index = idx }
            if list.count > 0 {
                if index == 0 { index = UInt(list.count - 1) }
                else { index -= 1 }
            } else { return nil }
            playingIndex = .some(index)
            return list[ap_safe: index]

        case .random:
            var index: UInt = 0
            if let idx = playingIndex.value { index = idx }
            let listCount = randomList.count
            if listCount > 0 {
                if index == 0 { index = UInt(listCount - 1) }
                else { index -= 1 }
            } else { return nil }

            playingIndex = .some(index)
            return randomList[ap_safe: index]

        case .single: return _nextURL(pattern: .single)

        case let .stopWhenAllPlayed(mode): return _previousURL(pattern: mode)
        }
    }
}
