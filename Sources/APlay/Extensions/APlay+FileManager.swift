public extension FileManager {
    static func createDirectoryIfNeeded(at url: URL) {
        let fm = FileManager.default
        let path = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        if fm.fileExists(atPath: path) == false {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    static func createFileIfNeeded(at url: URL) {
        let fm = FileManager.default
        let path = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        if fm.fileExists(atPath: path) == false {
            try? fm.createFile(atPath: path, contents: nil, attributes: nil)
        }
    }
}
