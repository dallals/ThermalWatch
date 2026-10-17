import os

/// Thread-safe "please stop" flag shared with load threads.
public final class StopFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public var isStopped: Bool { state.withLock { $0 } }
    public func stop() { state.withLock { $0 = true } }
}
