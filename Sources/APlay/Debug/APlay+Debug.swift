#if DEBUG
    let runProfile = false
#endif

func debug_log(_ msg: String) {
    #if DEBUG
        var message = msg
        if message.contains("deinit") { message = "\(msg) ✅" }
    print("[Debug]: \(message)")
    #endif
}
