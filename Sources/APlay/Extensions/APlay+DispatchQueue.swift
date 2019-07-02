extension DispatchQueue {
    func asyncWrite(_ c: @escaping () -> Void) {
        async(flags: .barrier) { c() }
    }
}
