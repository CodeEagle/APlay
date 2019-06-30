extension AnySubscriber {
    /// Tells the subscriber that the publisher has produced an element.
    ///
    /// - Parameter input: The published element.
    /// - Returns: A `Demand` instance indicating how many more elements the subcriber expects to receive.
    @inline(__always)
    @discardableResult func discardableReceive(_ value: Input) -> Subscribers.Demand {
        return receive(value)
    }
}
