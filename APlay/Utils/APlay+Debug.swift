//
//  APlay+Debug.swift
//  APlay
//
//  Created by lincoln on 2018/6/13.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

#if DEBUG
    let runProfile = false
#endif

func debug_log(_ msg: String) {
    #if DEBUG || ((arch(i386) || arch(x86_64)) && os(iOS))
    var message = msg
    if message.contains("deinit") { message = "❌ \(msg)" }
    print("🐛 [Debug]", message)
    #endif
}
