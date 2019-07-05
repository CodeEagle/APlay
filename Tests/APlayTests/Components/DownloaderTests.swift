import Foundation

final class DownloaderTests: XCTestCase {
    
    func testDownlaoder() {
        let conf: APlay.Configuration = .init()
        let downloader = Downloader(configuration: conf)
        let resource = URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!
        let path = "/var/tmp/aplay.download.test.tmp"
        FileManager.createFileIfNeeded(at: URL(fileURLWithPath: path))
        let handle = FileHandle(forReadingAtPath: path)
        
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
// MARK: - Test FileHandle sync problem
extension DownloaderTests {
    func testFileHandleSyncProblem() {
        let path = "/var/tmp/testFileHandleSyncProblem.tmp"
        try? FileManager.default.removeItem(atPath: path)
        FileManager.createFileIfNeeded(at: URL(fileURLWithPath: path))
        let writeHandle = FileHandle(forWritingAtPath: path)
        writeHandle?.readabilityHandler = { handle in
            print("can write now")
        }
        let readHandle = FileHandle(forReadingAtPath: path)
        readHandle?.readabilityHandler = { handle in
            print("can read now")
        }
        asyncTest { (e) in
            DispatchQueue.global().async {
                writeHandle?.seekToEndOfFile()
                let text = "hello world"
                writeHandle?.write(text.data(using: .utf8)!)
                
                let d = readHandle?.readData(ofLength: text.count)
                print(String.init(data: d!, encoding: .utf8)!)
                let d2 = readHandle?.readData(ofLength: text.count)
                print(String.init(describing: d2))
                let text2 = "hello world2"
                writeHandle?.seekToEndOfFile()
                writeHandle?.write(text2.data(using: .utf8)!)
                let d3 = readHandle?.readData(ofLength: text2.count)
                print(String.init(data: d3!, encoding: .utf8)!)
                e.fulfill()
            }
        }
        
    }
}
