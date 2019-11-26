import Foundation
import Combine

final class DownloaderTests: XCTestCase {
    private var _cancelToken: AnyCancellable?

    func testDownlaoder() {
        let conf: APlay.Configuration = .init()
        let downloader = Downloader(configuration: conf)
        let resource = URL(string: "https://umemore.shaunwill.cn/game/emotion/game_bgmusic.mp3")!
        let path = "/var/tmp/aplay.download.test.tmp"
        try? FileManager.default.removeItem(atPath: path)
        FileManager.createFileIfNeeded(at: path)
        let readWritePipe: ReadWritePipe = try! .init(localPath: path)
        
        asyncTest(timeout: 300) { (e) in
            var start: UInt64 = 0
            _cancelToken = downloader.eventPipeline.sink { (event) in
                switch event {
                case let .onStartPosition(position): start = position
                case .onTotalByte(let len):
                    print("schedule read")
                    let actureLen = len - start
                    readWritePipe.targetFileLength = actureLen
                    self.scheduleRead(readWritePipe, total: Int(actureLen), read: 0, completion: { e.fulfill() })
                    
                case let .onData(d, _):
                    print("write")
                    readWritePipe.write(d)
                    
                case let .completed(er):
                    print(String.init(describing: er))
                    
                default: print(event)
                }
            }
            // 1200 - 6491965
            // 0    - 6493165
            downloader.download(StreamProvider.URLInfo(url: resource, position: 0))
        }
    }
    
    private func scheduleRead(_ readHandle: ReadWritePipe, total: Int, read: Int, completion: @escaping () -> Void) {
        let fixedLength = 8192 * 8
        var totalRead = read
        
        if totalRead < total {
            let result = readHandle.readData(of: fixedLength)
            switch result {
            case let .available(data):
                let count = data.count
                totalRead += count
                print("read :\(count)")
            default: print(result)
            }
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
    func testRead() {
        let path = "/var/tmp/testReadFile.tmp"
        try? FileManager.default.removeItem(atPath: path)
        FileManager.createFileIfNeeded(at: path)
        var string = ""
        for i in 0 ..< 20 {
            string += "\(i)"
        }
        try! string.data(using: .utf8, allowLossyConversion: true)?.write(to: URL(fileURLWithPath: path))
        let readHandle = FileHandle(forReadingAtPath: path)!
        let data = readHandle.readData(ofLength: 10)
        print(String(data: data, encoding: .utf8)!)
        let data2 = readHandle.readData(ofLength: 12)
        print(String(data: data2, encoding: .utf8)!)
        let data3 = readHandle.readData(ofLength: string.count - 22 + 1)
        print(String(data: data3, encoding: .utf8)!)
    }

    func testFileHandleSyncProblem() {
        let path = "/var/tmp/testFileHandleSyncProblem.tmp"
        try? FileManager.default.removeItem(atPath: path)
        FileManager.createFileIfNeeded(at: path)
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
