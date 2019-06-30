public final class APlay {
    
    public private(set) var state: CurrentValueSubject<State, Never> = .init(.idle)
    
    public init(){}
}
