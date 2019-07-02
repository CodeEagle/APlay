import Foundation

final class DownloaderTests: XCTestCase {
    
    func testDownlaoder() {
        let conf: APlay.Configuration = .init()
        let downloader = Downloader(configuration: conf)
        let resource = URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!

        asyncTest { (e) in
            _ = downloader.eventPipeline.sink { (event) in
                print(event)
                switch event {
                case let .completed(er):
                    print(String.init(describing: er))
                    e.fulfill()
                default: break
                }
            }
            downloader.download(resource, at: 1200)
        }
    }
}
