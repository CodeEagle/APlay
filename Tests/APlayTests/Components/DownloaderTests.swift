import Foundation

final class DownloaderTests: XCTestCase {
    
    func testDownlaoder() {
        let conf: APlay.Configuration = .init()
        let downloader = Downloader(configuration: conf)
        let resource = URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!
        let path = "/var/tmp/aplay.download.test.tmp"
        FileManager.createFileIfNeeded(at: URL(fileURLWithPath: path))
        let readWritePipe: ReadWritePipe = try! .init(localPath: path)
        
        asyncTest(timeout: 300) { (e) in
            
            _ = downloader.eventPipeline.sink { (event) in
                switch event {
                case .onTotalByte(let len):
                    print("schedule read")
                    self.scheduleRead(readWritePipe, total: Int(len), read: 0, completion: { e.fulfill() })
                    
                case let .onData(d, _):
                    print("write")
                    readWritePipe.write(d)
                    
                case let .completed(er):
                    print(String.init(describing: er))
                    
                default: break
                }
            }
            downloader.download(StreamProvider.URLInfo(url: resource, position: 1200))
        }
    }
    
    private func scheduleRead(_ readHandle: ReadWritePipe, total: Int, read: Int, completion: @escaping () -> Void) {
        let fixedLength = 8192
        var totalRead = read
        
        if totalRead < total {
            let count = readHandle.readData(ofLength: fixedLength).count
            totalRead += count
            print("read :\(count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + DispatchTimeInterval.milliseconds(15)) {
                self.scheduleRead(readHandle, total: total, read: totalRead, completion: completion)
            }
        } else {
            completion()
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
