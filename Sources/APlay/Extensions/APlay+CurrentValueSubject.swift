extension CurrentValueSubject {
    func update(_ newValue: Output) {
        value = newValue
        send(newValue)
    }
}
