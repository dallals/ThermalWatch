import Foundation

/// One busy thread per core running a dependent floating-point chain the optimizer cannot remove.
/// No disk I/O; memory use is a few KB per thread.
public final class CPULoad {
    public let threadCount: Int
    private var flag = StopFlag()
    private var group = DispatchGroup()
    public private(set) var isRunning = false

    public init(threadCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.threadCount = max(1, threadCount)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        flag = StopFlag()
        group = DispatchGroup()
        let flag = flag
        let group = group
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread {
                var x = Double(index) + 1
                while !flag.isStopped {
                    for _ in 0..<200_000 { x = x * 1.000_000_1 + 0.000_000_1 }
                    if !x.isFinite { x = 1 }
                }
                CPULoad.sink(x)
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Signals every thread and waits up to `timeout` seconds. Returns true when all exited.
    @discardableResult
    public func stop(timeout: Double = 1.0) -> Bool {
        guard isRunning else { return true }
        flag.stop()
        isRunning = false
        return group.wait(timeout: .now() + timeout) == .success
    }

    @inline(never)
    static func sink(_ x: Double) {
        if x.isNaN { print("CPULoad: unexpected NaN") }
    }
}
