public extension FileManager {
    static func createFileIfNeeded(at url: URL) {
        let fm = FileManager.default
        let path = url.absoluteString
        if fm.fileExists(atPath: path) == false {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
