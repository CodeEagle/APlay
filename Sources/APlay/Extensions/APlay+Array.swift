extension Array where Element == UInt8 {
    func unpack(offsetSize: Int = 8, isLittleEndian: Bool = false) -> UInt32 {
        precondition(count <= 4, "Array count can not larger than 4")
        var ret: UInt32 = 0
        for i in 0 ..< count {
            let index = isLittleEndian ? (count - i - 1) : i
            ret = (ret << offsetSize) | UInt32(self[index])
        }
        return ret
    }
    
    func unpackUInt64(isLittleEndian: Bool = false) -> UInt64 {
        precondition(count <= 8, "Array count can not larger than 8")
        var ret: UInt64 = 0
        for i in 0 ..< count {
            let index = isLittleEndian ? (count - i - 1) : i
            ret = (ret << 8) | UInt64(self[index])
        }
        return ret
    }
}


extension Array {
    subscript(ap_safe index: Int) -> Element? {
        return indices ~= index ? self[index] : nil
    }
    
    subscript(ap_safe index: UInt) -> Element? {
        let idx = Int(index)
        return indices ~= idx ? self[idx] : nil
    }
    
    subscript(_ index: UInt) -> Element {
        let idx = Int(index)
        return self[idx]
    }
}
