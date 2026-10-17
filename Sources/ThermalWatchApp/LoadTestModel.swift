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
        run = LoadTestRun(kind: kind, plannedSeconds: Double(minutes * 60), startedAt: now)
        if kind != .gpu {
            let load = CPULoad()
            load.start()
            cpu = load
        }
        if kind != .cpu {
            guard let load = GPULoad() else {
                error = "Metal is unavailable, so the GPU load cannot run."
                stop(.userStopped)
                return
            }
            load.start()
            gpu = load
        }
        phase = .running
    }

    /// Called for every Monitor sample.
    func feed(_ sample: Sample) {
        guard isRunning, var current = run else { return }
        let reason = current.feed(sample)
        run = current
        if let reason { stop(reason, now: sample.timestamp) }
    }

    func stop(_ reason: StopReason, now: Double = Date().timeIntervalSince1970) {
        cpu?.stop()
        gpu?.stop()
        cpu = nil
        gpu = nil
        guard let current = run else {
            phase = .idle
            return
        }
        var result = current.result(stopReason: reason, endedAt: now, peaks: peaks(), note: note)
        if let store, let id = try? store.insert(result) { result.id = id }
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
