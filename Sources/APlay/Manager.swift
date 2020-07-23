//
//  Manager.swift
//  APlayDemo
//
//  Created by Lincoln on 2020/5/25.
//  Copyright © 2020 fly. All rights reserved.
//

import Foundation
public final class Manager {
    
    public let configuration: ConfigurationCompatible
    public private(set) var playlist: PlayList = .init()
    private var composerCancellableBag: AnyCancellable?
    private var _eventSubject: CurrentValueSubject<Event, Never> = .init(.state(.idle))
    public var eventPublisher: AnyPublisher<Event, Never> { _eventSubject.eraseToAnyPublisher() }
    private var composer: Composer
    
    deinit { composerCancellableBag?.cancel() }

    init(configuration: ConfigurationCompatible) {
        self.configuration = configuration
        composer = .init(configuration: configuration)
    }
}

// MARK: - Public API

public extension Manager {
    /// play with a autoclosure
    ///
    /// - Parameter url: a autoclosure to produce URL
    func play(_ url: @autoclosure () -> URL) {
        let u = url()
        let urls = [u]
        changeList(to: urls, at: 0)
        _play(u)
    }

    /// play whit variable parametric
    ///
    /// - Parameter urls: variable parametric URL input
    @inline(__always)
    func play(_ urls: URL..., at index: Int = 0) { play(urls, at: index) }

    /// play whit URL array
    ///
    /// - Parameter urls: URL array
    func play(_ urls: [URL], at index: Int = 0) {
        changeList(to: urls, at: index)
        guard let url = playlist.currentList[safe: index] else {
            let msg = "Can not found item at \(index) in list \(urls)"
            _eventSubject.send(.error(.playItemNotFound(msg)))
            return
        }
        _play(url)
    }

    func play(at index: Int) {
        guard let url = playlist.play(at: index) else {
            let msg = "Can not found item at \(index) in list \(playlist.list)"
            _eventSubject.send(.error(.playItemNotFound(msg)))
            return
        }
        _play(url)
    }

    /// play next song in list
    func next() {
        guard let url = playlist.nextURL() else { return }
        _play(url)
        indexChanged()
    }

    /// play previous song in list
    func previous() {
        guard let url = playlist.previousURL() else { return }
        _play(url)
        indexChanged()
    }

    private func indexChanged() {
        let index = playlist.playingIndex
        _eventSubject.send(.playingIndexChanged(index))
    }

    func changeList(to value: [URL], at index: Int) {
        playlist.changeList(to: value, at: index)
        let list = playlist.list
        _eventSubject.send(.playlistChanged(list))
        _eventSubject.send(.playingIndexChanged(.some(UInt(index))))
    }

    func seek(to time: TimeInterval) {
        var maybeTime = time
        let p = composer.position(for: &maybeTime)
        _play(composer.urlInfo.originalURL, at: p, time: Float(maybeTime), dataParserInfo: composer.dataParserInfo)
        print("maybe time:\(maybeTime), position:\(p)")
//        _nowPlayingInfo.play(elapsedPlayback: Float(maybeTime))
//        eventPipeline.call(.duration(_nowPlayingInfo.duration))
    }
    
    private func _play(_ url: URL, at position: StreamProvider.Position = 0, time: Float = 0, dataParserInfo: DataParser.Info? = nil) {
        addComposerMonitor()
        composer.play(url, at: position, time: time, dataParserInfo: dataParserInfo)
    }
    
    private func addComposerMonitor() {
        composerCancellableBag?.cancel()
        composer = .init(configuration: configuration)
        composerCancellableBag = composer.eventPublisher.sink { [weak self] e in
            guard let sself = self else { return }
            sself._eventSubject.send(e)
            if case Event.playEnded = e {
                sself.next()
            }
        }
    }
}
