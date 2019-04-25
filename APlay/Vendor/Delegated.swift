//
//  Delegated.swift
//  Delegated
//
//  Created by Oleg Dreyman on 3/11/18.
//  Copyright © 2018 Delegated. All rights reserved.
//

/// [Delegated](https://github.com/dreymonde/Delegated) is a super small package that solves the retain cycle problem when dealing with closure-based delegation
public final class Delegated<Input, Output> {
    private(set) var callback: ((Input) -> Output?)?

    private var _isEnabled = true

    public init() {}

    public func delegate<Target: AnyObject>(to target: Target,
                                            with callback: @escaping (Target, Input) -> Output) {
        self.callback = { [weak target] input in
            guard let target = target else {
                return nil
            }
            return callback(target, input)
        }
    }

    public func call(_ input: Input) -> Output? {
        guard _isEnabled else { return nil }
        return callback?(input)
    }

    public var isDelegateSet: Bool {
        return callback != nil
    }
}

extension Delegated {
    public func stronglyDelegate<Target: AnyObject>(to target: Target,
                                                    with callback: @escaping (Target, Input) -> Output) {
        self.callback = { input in
            callback(target, input)
        }
    }

    public func manuallyDelegate(with callback: @escaping (Input) -> Output) {
        self.callback = callback
    }

    public func removeDelegate() {
        callback = nil
    }

    public func toggle(enable: Bool) {
        _isEnabled = enable
    }
}

extension Delegated where Input == Void {
    public func delegate<Target: AnyObject>(to target: Target,
                                            with callback: @escaping (Target) -> Output) {
        delegate(to: target, with: { target, _ in callback(target) })
    }

    public func stronglyDelegate<Target: AnyObject>(to target: Target,
                                                    with callback: @escaping (Target) -> Output) {
        stronglyDelegate(to: target, with: { target, _ in callback(target) })
    }
}

extension Delegated where Input == Void {
    public func call() -> Output? {
        guard _isEnabled else { return nil }
        return call(())
    }
}

extension Delegated where Output == Void {
    public func call(_ input: Input) {
        guard _isEnabled else { return }
        callback?(input)
    }
}

extension Delegated where Input == Void, Output == Void {
    public func call() {
        guard _isEnabled else { return }
        call(())
    }
}
