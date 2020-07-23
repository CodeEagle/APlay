//
//  ViewController.swift
//  APlayDemo
//
//  Created by Lincoln on 2020/1/22.
//  Copyright © 2020 fly. All rights reserved.
//

import AVKit
import UIKit

class ViewController: UIViewController {
    let player = APlay(configuration: APlay.Configuration(seekPolicy: .enable))
    let player2 = Manager(configuration: APlay.Configuration(seekPolicy: .enable))
    let mp3s: [URL] = [
        URL(string: "https://raw.githubusercontent.com/CodeEagle/FreePlayer/master/FPDemo/%E4%B9%85%E8%BF%9C-%E5%85%89%E3%81%A8%E6%B3%A2%E3%81%AE%E8%AE%B0%E5%BF%86.mp3")!,
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_700KB.mp3")!,
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_1MG.mp3")!,
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_2MG.mp3")!,
        URL(string: "https://raw.githubusercontent.com/CodeEagle/FreePlayer/master/FPDemo/%E7%BA%A2%E8%8E%B2%E3%81%AE%E5%BC%93%E7%9F%A2.wav")!
    ]

    let wavs: [URL] = [
        URL(string: "https://www.audiocheck.net/download.php?filename=Audio/audiocheck.net_hdsweep_1Hz_44000Hz_-3dBFS_30s.wav")!,
        URL(string: "https://www.kozco.com/tech/piano2.wav")!,
    ]

    private lazy var _cancellableBag: Set<AnyCancellable> = []
    override func viewDidLoad() {
        super.viewDidLoad()
        let timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.pitch = 1
        timePitchNode.rate = 1
        player.pluginNodes = [
            timePitchNode,
        ]
//        let session = AVAudioSession.sharedInstance()
//        do {
//            try session.setCategory(.playback, mode: .default, policy: .default, options: [.allowBluetoothA2DP, .allowBluetooth, .allowAirPlay, .defaultToSpeaker])
//            try session.setActive(true)
//        } catch {
//            os_log("Failed to activate audio session: %@", log: ViewController.logger, type: .default, #function, #line, error.localizedDescription)
//        }
        let url0 = Bundle.main.url(forResource: "06 VV-ALK", withExtension: "flac")!
        let url = Bundle.main.url(forResource: "testAudio", withExtension: nil)!
        let url2 = Bundle.main.url(forResource: "nameless", withExtension: "m4a")!
        let url3 = Bundle.main.url(forResource: "红莲の弓矢", withExtension: "wav")!
//        let url = Bundle.main.url(forResource: "nameless", withExtension: "m4a")!
//        let url = wavs[0]
        player2.eventPublisher.sink { event in
            print("😄 player event: \(event)")
        }.store(in: &_cancellableBag)
        self.player2.play(url0, url3, url0, url2, self.mp3s[0], url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
//            self.player.seek(at: 30)
//            self.player2.seek(to: 30)
        }
        
        let routePickerView = AVRoutePickerView()
        view.addSubview(routePickerView)
        routePickerView.translatesAutoresizingMaskIntoConstraints = false
        routePickerView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        routePickerView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        // Do any additional setup after loading the view.
    }
}
