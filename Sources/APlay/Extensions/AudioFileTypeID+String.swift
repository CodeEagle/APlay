extension String {
    init?(from value: UInt32) {
        var bigEndian = value.bigEndian
        let count = MemoryLayout<UInt32>.size
        let bytePtr = withUnsafePointer(to: &bigEndian) {
            $0.withMemoryRebound(to: UInt8.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
        }
        self.init(data: Data(buffer: bytePtr), encoding: .utf8)
    }

    func audioFileTypeID() -> AudioFileTypeID {
        let offsetSize = 8
        let array: [UInt8] = Array(utf8)
        let total = array.count
        var totalSize: UInt32 = 0
        for i in 0 ..< total {
            totalSize += UInt32(array[i]) << (offsetSize * ((total - 1) - i))
        }
        return totalSize
    }
}
