public extension FileManager {
    static func createDirectoryIfNeeded(at url: URL) {
        let fm = FileManager.default
        let path = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        if fm.fileExists(atPath: path) == false {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    static func createFileIfNeeded(at path: String) {
        let fm = FileManager.default
//        let path = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        if fm.fileExists(atPath: path) == false {
            _ = fm.createFile(atPath: path, contents: nil, attributes: nil)
        }
    }

    static func copyItemByStripingTmpSuffix(at path: String) {
        let fm = FileManager.default
        let finalPath = path.replacingOccurrences(of: ".tmp", with: "")
        try? fm.copyItem(atPath: path, toPath: finalPath)
    }
}
