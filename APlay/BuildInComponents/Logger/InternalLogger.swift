//
//  InternalLogger.swift
//  APlay
//
//  Created by Lincoln Law on 2017/2/22.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import Foundation

extension APlay {
    final class InternalLogger {
        var currentFile: String { return _filePath }
        var isLoggedToConsole: Bool = true
        private let _policy: Logger.Policy
        private lazy var _filePath: String = ""

        private var _date = ""
        private var _fileHandler: FileHandle?
        private var _logQueue = DispatchQueue(concurrentName: "Logger")
        private var _openTime = ""
        private var _lastRead: UInt64 = 0
        private var _totalSize: UInt64 = 0

        deinit {
            guard let fileHandle = _fileHandler else { return }
            _logQueue.sync { fileHandle.closeFile() }
        }

        init(policy: Logger.Policy) {
            _policy = policy
            guard let dir = _policy.folder else { return }
            let total = dateTime()
            _date = total.0
            _openTime = total.1
            _filePath = "\(dir)/\(_date).log"

            let u = URL(fileURLWithPath: _filePath)
            if access(_filePath.withCString({ $0 }), F_OK) == -1 { // file not exists
                FileManager.default.createFile(atPath: _filePath, contents: nil, attributes: nil)
            }
            _fileHandler = try? FileHandle(forWritingTo: u)
            if let fileHandle = _fileHandler {
                _lastRead = fileHandle.seekToEndOfFile()
            }
            _totalSize = _lastRead
            reset()
        }

        private func dateTime() -> (String, String) {
            var rawTime = time_t()
            time(&rawTime)
            var timeinfo = tm()
            localtime_r(&rawTime, &timeinfo)

            var curTime = timeval()
            gettimeofday(&curTime, nil)
            let milliseconds = curTime.tv_usec / 1000
            return ("\(Int(timeinfo.tm_year) + 1900)-\(Int(timeinfo.tm_mon + 1))-\(Int(timeinfo.tm_mday))", "\(Int(timeinfo.tm_hour)):\(Int(timeinfo.tm_min)):\(Int(milliseconds))")
        }
    }
}

extension APlay.InternalLogger: LoggerCompatible {
    func reset() {
        _openTime = dateTime().1
        let msg = "🎹:APlay[\(APlay.version)]@\(_openTime)\(Logger.lineSeperator)"
        log(msg, to: .audioDecoder)
    }

    func cleanAllLogs() {
        guard let dir = _policy.folder else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        if fm.fileExists(atPath: dir) == false {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: nil)
        }
    }

    func log(_ msg: String, to channel: Logger.Channel, method: String) {
        guard let fileHandler = _fileHandler else { return }
        let total = "\(channel.symbole)\(method):\(msg)\(Logger.lineSeperator)"

        if isLoggedToConsole { print(total) }

        _logQueue.async(flags: .barrier) {
            guard let data = total.data(using: .utf8) else { return }
            self._totalSize += UInt64(data.count)
            fileHandler.write(data)
        }
    }
}
