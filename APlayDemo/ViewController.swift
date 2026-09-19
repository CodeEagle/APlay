//
//  ViewController.swift
//  APlayDemo
//
//  Created by Lincoln on 2019/1/21.
//  Copyright © 2019 SelfStudio. All rights reserved.
//

import UIKit
import APlay

/// Plays every bundled sample in order and shows the result on screen, so a
/// real device answers one question at a glance: which formats this platform
/// actually decodes. Opus goes first — Core Audio supports it on some
/// platforms and not others, and that is exactly what needs a device to tell.
class ViewController: UIViewController {

    private lazy var config: APlay.Configuration = {
        APlay.Configuration(cachePolicy: .disable, gaplessPlaybackEnabled: true)
    }()
    private lazy var player: APlay = {
        APlay(configuration: self.config)
    }()

    private let logView = UITextView()
    private var _log = ""
    private var rowIndex = -1
    private var rowPlayed = false
    private let rows: [String] = [
        "tone.m4a", "tone.opus", "tone-alac.m4a", "tone-cbr.mp3", "tone-vbr.mp3",
        "tone.aac", "tone.flac", "tone.wav", "tone.aiff", "tone.aifc", "tone.caf", "a.m4a",
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        logView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        logView.isEditable = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logView)
        NSLayoutConstraint.activate([
            logView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            logView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            logView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            logView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        let urls = rows.compactMap { name -> URL? in
            let parts = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let path = Bundle.main.path(forResource: parts, ofType: ext) else {
                log("missing \(name) in the app bundle")
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            logURL = dir.appendingPathComponent("result.log")
        }
        log("device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        guard !urls.isEmpty else {
            log("no bundled samples found")
            return
        }

        player.loopPattern = .stopWhenAllPlayed(.order)
        player.eventPipeline.delegate(to: self) { [weak self] _, event in
            self?.handle(event)
        }
        log("playing \(urls.count) samples, gapless on — listen for gaps and watch the log")
        player.play(urls, at: 0)
    }

    private func handle(_ event: APlay.Event) {
        switch event {
        case let .state(state):
            switch state {
            case .playing:
                if rowIndex >= 0 { log("✔ \(rows[rowIndex]) — playing") }
            case .paused:
                if rowIndex >= 0 { log("— \(rows[rowIndex]) — paused (expected across formats)") }
            default:
                break
            }
        case let .playingIndexChanged(index):
            rowIndex = index
            rowPlayed = false
            if index < rows.count { log("\n[\(index + 1)/\(rows.count)] \(rows[index])") }
        case let .duration(seconds):
            log("  duration = \(seconds)s")
        case let .playback(time):
            // A few samples per track show whether time actually approaches the
            // duration — the end-of-track check depends on that.
            rowPlayed = true
            if rowIndex >= 0 { log("  t = \(time)s") }
        case let .error(error):
            if rowIndex >= 0 { log("✘ \(rows[rowIndex]) — FAILED: \(error)") }
        case .streamerEndEncountered:
            if rowIndex >= 0 { log("  streamer reached end of \(rows[rowIndex])") }
        case .playEnded:
            if rowIndex >= 0 { log("  play ended for \(rows[rowIndex])") }
        default:
            break
        }
    }

    private let logLock = NSLock()
    private var logURL: URL?

    private func log(_ line: String) {
        print(line)
        logLock.lock()
        _log.append(line + "\n")
        let text = _log
        logLock.unlock()
        if let url = logURL {
            try? text.data(using: .utf8)?.write(to: url)
        }
        if Thread.isMainThread {
            applyLog(text)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyLog(text) }
        }
    }

    private func applyLog(_ text: String) {
        logView.text = text
        let end = (text as NSString).length
        logView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

class ViewControllerB: UIViewController {

    private let player = APlay()

    override func viewDidLoad() {
        super.viewDidLoad()
        player.loopPattern = .stopWhenAllPlayed(.order)
        player.eventPipeline.delegate(to: self) { (target, event) in
            switch event {
            case .playEnded: print("end")
            default: break
            }
        }
        player.play(URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!)
    }
}
