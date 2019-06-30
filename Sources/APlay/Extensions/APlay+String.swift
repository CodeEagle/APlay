extension String {
    func trimZeroTerminator() -> String { return replacingOccurrences(of: "\0", with: "") }
}
