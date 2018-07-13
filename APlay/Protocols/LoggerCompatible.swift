//
//  LoggerCompatible.swift
//  APlay
//
//  Created by lincoln on 2018/6/13.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

/// Protocol for logger
public protocol LoggerCompatible {
    var currentFile: String { get }
    var isLoggedToConsole: Bool { get }
    func log(_ msg: String, to channel: Logger.Channel, method: String)
    func cleanAllLogs()
    func reset()
    init(policy: Logger.Policy)
}

extension LoggerCompatible {
    func log(_ msg: String, to channel: Logger.Channel, func method: String = #function) {
        log(msg, to: channel, method: method)
    }
}

public struct Logger {
    /// Line seperator
    public static let lineSeperator = "\n\u{FEFF}\u{FEFF}"

    /// Logger Policy
    ///
    /// - disable: disable
    /// - persistentInFolder: log in certain folder
    public enum Policy: Hashable {
        case disable
        case persistentInFolder(String)

        /// Is disabled log
        public var isDisabled: Bool {
            switch self {
            case .disable: return true
            default: return false
            }
        }

        /// Folder to store logs
        public var folder: String? {
            switch self {
            case let .persistentInFolder(path): return path
            default: return nil
            }
        }

        /// Default policy for APlay
        public static var defaultPolicy: Policy {
            let cache = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
            let dir = "\(cache)/APlay/Log"
            let fm = FileManager.default
            if fm.fileExists(atPath: dir) == false {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
            }
            return Logger.Policy.persistentInFolder(dir)
        }
    }

    /// Log channel
    public enum Channel: CaseIterable {
        case audioDecoder, streamProvider, metadataParser
        var symbole: String {
            switch self {
            case .audioDecoder: return "🌈"
            case .streamProvider: return "🌊"
            case .metadataParser: return "⚡️"
            }
        }

        func log(msg: String, method: String = #function) {
            let total = "\(symbole)[\(method)] \(msg)"
            #if DEBUG
                print(total)
            #endif
        }
    }
}
