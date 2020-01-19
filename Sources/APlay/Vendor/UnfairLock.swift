import os

public final class UnfairLock {
    private var _lock: os_unfair_lock = .init()
    public init() {}

    public final func lock(_ action: () -> Void) {
        os_unfair_lock_lock(&_lock)
        action()
        os_unfair_lock_unlock(&_lock)
    }

    public final func lock(_ action: () throws -> Void) rethrows {
        os_unfair_lock_lock(&_lock)
        try action()
        os_unfair_lock_unlock(&_lock)
    }

    public final func lock<T>(_ action: () -> T) -> T {
        let val: T
        os_unfair_lock_lock(&_lock)
        val = action()
        os_unfair_lock_unlock(&_lock)
        return val
    }
}
