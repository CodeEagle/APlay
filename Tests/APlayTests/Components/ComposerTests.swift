import Foundation

final class ComposerTests: XCTestCase {
    func testPlay() {
        let conf: APlay.Configuration = .init()
        let resource = URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!
        let composer = Composer(configuration: conf)
        try! composer.play(resource)
        asyncTest { e in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                e.fulfill()
            }
        }
    }
}
