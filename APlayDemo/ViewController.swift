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
    let mp3s: [URL] = [
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_700KB.mp3")!,
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_1MG.mp3")!,
        URL(string: "https://file-examples.com/wp-content/uploads/2017/11/file_example_MP3_2MG.mp3")!,
    ]

    let wavs: [URL] = [
        URL(string: "https://www.audiocheck.net/download.php?filename=Audio/audiocheck.net_hdsweep_1Hz_44000Hz_-3dBFS_30s.wav")!,
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        let timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.pitch = 1
        timePitchNode.rate = 1
        player.pluginNodes = [
            timePitchNode,
        ]
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [.allowBluetoothA2DP, .allowBluetooth, .allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
//            os_log("Failed to activate audio session: %@", log: ViewController.logger, type: .default, #function, #line, error.localizedDescription)
        }
//        let url = Bundle.main.url(forResource: "06 VV-ALK", withExtension: "flac")!
        let url = Bundle.main.url(forResource: "testAudio", withExtension: nil)!
//        let url = Bundle.main.url(forResource: "nameless", withExtension: "m4a")!
//        let url = wavs[0]
        player.play(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.player.seek(at: 30)
        }
        let routePickerView = AVRoutePickerView()
        view.addSubview(routePickerView)
        routePickerView.translatesAutoresizingMaskIntoConstraints = false
        routePickerView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        routePickerView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        // Do any additional setup after loading the view.
    }
}
