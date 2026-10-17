import Foundation
import Metal

/// A Metal compute kernel doing fused multiply-adds over a 64 MB buffer, dispatched back to back
/// with a short pause between command buffers so the UI stays responsive.
public final class GPULoad {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float4 *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float4 v = data[id];
        for (int i = 0; i < 512; i++) {
            v = fma(v, float4(1.0001f), float4(0.0001f));
            v = fma(v, float4(0.9999f), float4(-0.0001f));
        }
        data[id] = v;
    }
    """

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private var flag = StopFlag()
    private var done = DispatchSemaphore(value: 0)
    public private(set) var isRunning = false

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: 64 << 20, options: .storageModePrivate)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        flag = StopFlag()
        done = DispatchSemaphore(value: 0)
        let flag = flag
        let done = done
        let queue = queue
        let pipeline = pipeline
        let buffer = buffer
        let thread = Thread {
            let count = buffer.length / MemoryLayout<SIMD4<Float>>.stride
            let group = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
            while !flag.isStopped {
                autoreleasepool {
                    guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(buffer, offset: 0, index: 0)
                    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: group)
                    encoder.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                }
                usleep(500)
            }
            done.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    @discardableResult
    public func stop(timeout: Double = 1.0) -> Bool {
        guard isRunning else { return true }
        flag.stop()
        isRunning = false
        return done.wait(timeout: .now() + timeout) == .success
    }
}
