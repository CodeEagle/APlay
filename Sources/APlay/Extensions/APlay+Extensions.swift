//
//  Extensions.swift
//  APlay
//
//  Created by Lincoln Law on 2017/2/20.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation

/// Add Equatable support for AudioStreamBasicDescription
extension AudioStreamBasicDescription: Equatable {
    public static func == (source: AudioStreamBasicDescription, dst: AudioStreamBasicDescription) -> Bool {
        return dst.mFormatID == source.mFormatID &&
            dst.mSampleRate == source.mSampleRate &&
            dst.mBytesPerPacket == source.mBytesPerPacket &&
            dst.mFormatFlags == source.mFormatFlags &&
            dst.mBytesPerPacket == source.mBytesPerPacket &&
            dst.mBitsPerChannel == source.mBitsPerChannel &&
            dst.mFramesPerPacket == source.mFramesPerPacket &&
            dst.mChannelsPerFrame == source.mChannelsPerFrame &&
            dst.mReserved == source.mReserved
    }
}

extension DispatchQueue {
    convenience init(name: String) {
        self.init(label: "com.SelfStudio.APlay.\(name)")
    }

    convenience init(concurrentName: String) {
        self.init(label: "com.SelfStudio.APlay.\(concurrentName)", attributes: .concurrent)
    }
}

extension URL {
    func asCFunctionString() -> String {
        var name = absoluteString.replacingOccurrences(of: "file://", with: "")
        if let value = name.removingPercentEncoding { name = value }
        return name
    }
}

extension UnsafeMutableRawPointer {
    func to<T: AnyObject>(object _: T.Type) -> T {
        return Unmanaged<T>.fromOpaque(self).takeUnretainedValue()
    }

    static func from<T: AnyObject>(object: T) -> UnsafeMutableRawPointer {
        return Unmanaged<T>.passUnretained(object).toOpaque()
    }
}

extension UnsafeMutablePointer where Pointee == UInt8 {
    static func uint8Pointer(of size: Int) -> UnsafeMutablePointer<UInt8> {
        let alignment = MemoryLayout<UInt8>.alignment
        return UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment).bindMemory(to: UInt8.self, capacity: size)
    }
}

extension AudioFileStreamParseFlags {
    static let continuity = AudioFileStreamParseFlags([])
}

extension OSStatus {
    static let empty: OSStatus = 101
    func readableMessage(from raw: String) -> String {
        var result = ""
        switch raw {
        case "wht?": result = "Audio File Unspecified"
        case "typ?": result = "Audio File Unsupported File Type"
        case "fmt?": result = "Audio File Unsupported Data Format"
        case "pty?": result = "Audio File Unsupported Property"
        case "!siz": result = "Audio File Bad Property Size"
        case "prm?": result = "Audio File Permissions Error"
        case "optm": result = "Audio File Not Optimized"
        case "chk?": result = "Audio File Invalid Chunk"
        case "off?": result = "Audio File Does Not Allow 64Bit Data Size"
        case "pck?": result = "Audio File Invalid Packet Offset"
        case "dta?": result = "Audio File Invalid File"
        case "op??", "0x6F703F3F": result = "Audio File Operation Not Supported"
        case "!pkd": result = "Audio Converter Err Requires Packet Descriptions Error"
        case "-38": result = "Audio File Not Open"
        case "-39": result = "Audio File End Of File Error"
        case "-40": result = "Audio File Position Error"
        case "-43": result = "Audio File File Not Found"
        default: result = ""
        }
        result = "\(result)(\(raw))"
        return result
    }

    @discardableResult func check(operation: String = "", file: String = #file, method: String = #function, line: Int = #line) -> String? {
        guard self != noErr else { return nil }
        var result: String = ""
        var char = Int(bigEndian)

        for _ in 0 ..< 4 {
            guard isprint(Int32(char & 255)) == 1 else {
                result = "\(self)"
                break
            }
            // UnicodeScalar(char&255) will get optional
            let raw = String(describing: UnicodeScalar(UInt8(char & 255)))
            result += raw
            char = char / 256
        }
        let humanMsg = readableMessage(from: result)
        let msg = "\n{\n file: \(file):\(line),\n function: \(method),\n operation: \(operation),\n message: \(humanMsg)\n}"
        #if DEBUG
            debug_log(msg)
        #endif
        return msg
    }

    func throwCheck(file: String = #file, method: String = #function, line: Int = #line) throws {
        guard let msg = check(file: file, method: method, line: line) else { return }
        throw APlay.Error.player(msg)
    }
}
