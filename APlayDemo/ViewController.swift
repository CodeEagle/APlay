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

    private lazy var config: APlay.Configuration = {
        let c = APlay.Configuration(cachePolicy: .disable)
        return c
    }()
    private lazy var player: APlay = {
       return APlay(configuration: self.config)
    }()

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
        player.play(URL(string: "https://s1.vocaroo.com/media/download_temp/Vocaroo_s1tpYgEhVDS6.mp3")!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.player.seek(to: 60)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.player.seek(to: 180)
        }
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


