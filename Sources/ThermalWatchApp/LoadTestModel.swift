import Foundation
import Observation
import ThermalCore
import ThermalLoad

@MainActor
@Observable
final class LoadTestModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished(LoadTestResult)
    }

    var kind: LoadKind = .both
    var minutes = 5
    var note = ""
    private(set) var phase: Phase = .idle
    private(set) var run: LoadTestRun?
    private(set) var history: [LoadTestResult] = []
    private(set) var error: String?

    @ObservationIgnored private var cpu: CPULoad?
    @ObservationIgnored private var gpu: GPULoad?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private let peaks: @MainActor () -> [Cluster: Double]

    init(store: HistoryStore?, peaks: @escaping @MainActor () -> [Cluster: Double]) {
        self.store = store
        self.peaks = peaks
        reloadHistory()
    }

    var isRunning: Bool { phase == .running }

    func start(now: Double = Date().timeIntervalSince1970) {
        guard !isRunning else { return }
        error = nil
        var gpuLoad: GPULoad?
        if kind != .cpu {
            guard let load = GPULoad() else {
                error = "Metal is unavailable, so the GPU load cannot run."
                return
            }
            gpuLoad = load
        }
        let planned = Double(minutes * 60)
        run = LoadTestRun(kind: kind, plannedSeconds: planned, startedAt: now)
        if kind != .gpu {
            let load = CPULoad()
            load.start()
            cpu = load
        }
        if let gpuLoad {
            gpuLoad.start()
            gpu = gpuLoad
        }
        phase = .running
        // Backstop: end the burn even if the sampler stalls and no samples arrive.
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((planned + 2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.isRunning == true { self?.stop(.finished) }
        }
    }

    /// Called for every Monitor sample.
    func feed(_ sample: Sample) {
        guard isRunning, var current = run else { return }
        let reason = current.feed(sample)
        run = current
        if let reason { stop(reason, now: sample.timestamp) }
    }

    func stop(_ reason: StopReason, now: Double = Date().timeIntervalSince1970) {
        deadline?.cancel()
        deadline = nil
        cpu?.stop()
        gpu?.stop()
        cpu = nil
        gpu = nil
        guard let current = run else {
            phase = .idle
            return
        }
        var result = current.result(stopReason: reason, endedAt: now, peaks: peaks(), note: note)
        if let store {
            do { result.id = try store.insert(result) } catch { self.error = "Result not saved: \(error)" }
        }
        run = nil
        phase = .finished(result)
        reloadHistory()
    }

    func reset() {
        if !isRunning { phase = .idle }
    }

    private func reloadHistory() {
        history = (try? store?.loadTests()) ?? []
    }
}
