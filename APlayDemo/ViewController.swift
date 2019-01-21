//
//  ViewController.swift
//  APlayDemo
//
//  Created by Lincoln on 2019/1/21.
//  Copyright © 2019 SelfStudio. All rights reserved.
//

import UIKit
import APlay

class ViewController: UIViewController {

    private let player = APlay()

    override func viewDidLoad() {
        super.viewDidLoad()
        player.loopPattern = .stopWhenAllPlayed(.order)
        player.eventPipeline.delegate(to: self) { (target, event) in
            switch event {
            case .playEnded:
                self.player.pause()
                DispatchQueue.main.async {
                    let vc = ViewControllerB()
                    self.show(vc, sender: nil)
                }
            default: break
            }
        }
        player.play(URL(string: "https://umemore.shaunwill.cn/game/emotion/game_little_bgm.mp3")!)
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


