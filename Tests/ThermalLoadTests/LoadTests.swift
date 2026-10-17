import Foundation
import Testing
@testable import ThermalLoad

@Test func cpuLoadStartsAndStopsQuickly() {
    let load = CPULoad(threadCount: 2)
    load.start()
    #expect(load.isRunning)
    Thread.sleep(forTimeInterval: 0.2)
    #expect(load.stop(timeout: 1.0))
    #expect(load.isRunning == false)
    #expect(load.stop(timeout: 1.0)) // stopping twice is harmless
}

@Test func gpuLoadStartsAndStopsQuickly() throws {
    let load = try #require(GPULoad())
    load.start()
    Thread.sleep(forTimeInterval: 0.3)
    #expect(load.stop(timeout: 1.0))
    #expect(load.isRunning == false)
}
