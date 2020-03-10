//
//  ViewController.swift
//  APlayDemo
//
//  Created by Lincoln on 2020/1/22.
//  Copyright © 2020 fly. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
    let player = APlay(configuration: APlay.Configuration())
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .default, options: [.allowBluetoothA2DP,.defaultToSpeaker])
            try session.setActive(true)
        } catch {
//            os_log("Failed to activate audio session: %@", log: ViewController.logger, type: .default, #function, #line, error.localizedDescription)
        }
        let url = Bundle.main.url(forResource: "testAudio", withExtension: nil)!
        player.play(url)
        // Do any additional setup after loading the view.
    }


}

