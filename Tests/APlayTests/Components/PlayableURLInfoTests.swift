import Foundation

final class PlayableURLInfoTests: XCTestCase {
    func testInitFromURL() {
        let expectation: [URL : PlayableURLInfo] = [
            URL(fileURLWithPath: "/var/tmp/a.mp3") : .local(URL(fileURLWithPath: "/var/tmp/a.mp3"), .mp3),
            URL(fileURLWithPath: "/var/tmp/a.wave") : .local(URL(fileURLWithPath: "/var/tmp/a.wave"), .wave),
            URL(fileURLWithPath: "/var/tmp/a.flac") : .local(URL(fileURLWithPath: "/var/tmp/a.flac"), .flac),
            URL(string: "https:///some.url/a.wave")! : .remote(URL(string: "https:///some.url/a.wave")!, .wave),
            URL(string: "http:///some.url/a.mp3")! : .remote(URL(string: "http:///some.url/a.mp3")!, .mp3),
            URL(string: "http:///some.url/a.flac")! : .remote(URL(string: "http:///some.url/a.flac")!, .flac)
        ]
        
        for (raw, expect) in expectation {
            let result = PlayableURLInfo.init(url: raw)
            assert(result.url == expect.url)
            assert(result.fileHint == expect.fileHint)
            assert(result.isRemote == expect.isRemote)
        }
    }
    
    func testLocalContentLength() {
        let url = URL(fileURLWithPath: "/var/tmp/a.mp3")
        let d = "hello world".data(using: .utf8)!
        FileManager.createFileIfNeeded(at: url)
        try! d.write(to: url)
        let result = PlayableURLInfo.init(url: url)
        assert(result.localContentLength() == d.count)
        assert(result.fileName == "a")
    }
    
    func testFileHintFromFileTypeOrContentType() {
        let expectaion: [AudioFileType : [String]] = [
            .flac : ["flac"],
            .mp3 : ["mp3", "mpg3", "audio/mpeg", "audio/mp3", "unknown"],
            .wave : ["wav", "wave", "audio/x-wav"],
            .aifc : ["aifc", "audio/x-aifc"],
            .aiff : ["aiff", "audio/x-aiff"],
            .m4a : ["m4a", "audio/x-m4a"],
            .mp4 : ["mp4", "mp4f", "mpg4", "audio/mp4", "video/mp4"],
            .caf : ["caf", "caff", "audio/x-caf"],
            .aacADTS : ["aac", "adts", "aacp", "audio/aac", "audio/aacp"],
            .opus : ["opus", "audio/opus"]
        ]
        for (expect, values) in expectaion {
            for val in values {
                let type = PlayableURLInfo.fileHintFromFileTypeOrContentType(val)
                assert(type == expect)
            }
        }
    }
    
    func testLocalFileHit() {
        let localWaveFile = "12345678WAVE".data(using: .utf8)!
        let waveUrl = URL(fileURLWithPath: "/var/tmp/b.wave")
        FileManager.createFileIfNeeded(at: waveUrl)
        try! localWaveFile.write(to: waveUrl)
        let localFlacFile = "fLaC".data(using: .utf8)!
        let flacUrl = URL(fileURLWithPath: "/var/tmp/c.flac")
        FileManager.createFileIfNeeded(at: flacUrl)
        try! localFlacFile.write(to: flacUrl)
        
        assert(PlayableURLInfo.localFileHit(from: waveUrl) == .wave)
        assert(PlayableURLInfo.localFileHit(from: flacUrl) == .flac)
    }
}
