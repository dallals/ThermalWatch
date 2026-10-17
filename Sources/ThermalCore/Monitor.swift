import Foundation
import Observation

public protocol SensorSuite: AnyObject {
    /// Frequency-table maxima, the fallback reference peaks.
    var tableMax: [Cluster: Double] { get }
    /// Sources that failed on the last read ("pressure", "clocks", "temps", "fans", "power", "tokens").
    var unavailable: Set<String> { get }
    /// True when oMLX reports an active request.
    var omlxBusy: Bool { get }
    func read(now: Double) async -> Sample
}

@MainActor
@Observable
public final class Monitor {
    public static let memorySeconds: Double = 3600
    public static let flushInterval: Double = 10
    public static let maintenanceInterval: Double = 3600

    public private(set) var latest: Sample?
    public private(set) var recent: [Sample] = []
    public private(set) var openEvent: ThrottleEvent?
    public private(set) var currentPeaks: [Cluster: Double] = [:]
    public private(set) var unavailable: Set<String> = []
    public private(set) var storeError: String?
    public var retentionDays: Double = 7
    public var alertPolicy = AlertPolicy()

    @ObservationIgnored public var onAlert: ((AlertKind, Sample) -> Void)?
    @ObservationIgnored public var onSample: ((Sample) -> Void)?
    @ObservationIgnored public var onEventClosed: ((ThrottleEvent) -> Void)?

    @ObservationIgnored private let sensors: SensorSuite
    @ObservationIgnored private let store: HistoryWriting?
    @ObservationIgnored private let detector: ThrottleDetector
    @ObservationIgnored private var peaks: PeakTracker
    @ObservationIgnored private var events = EventBuilder()
    @ObservationIgnored private var pending: [Sample] = []
    @ObservationIgnored private var pendingEvents: [ThrottleEvent] = []
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var lastFlush: Double
    @ObservationIgnored private var lastMaintenance: Double
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(sensors: SensorSuite, store: HistoryWriting?, detector: ThrottleDetector = ThrottleDetector(),
                retentionDays: Double = 7, now: Double = Date().timeIntervalSince1970) {
        self.sensors = sensors
        self.store = store
        self.detector = detector
        self.retentionDays = retentionDays
        self.peaks = PeakTracker(tableMax: sensors.tableMax, busyThreshold: detector.thresholds.busy)
        self.events = EventBuilder(busyThreshold: detector.thresholds.busy)
        self.lastFlush = now
        self.lastMaintenance = now
        maintain(now: now)
        currentPeaks = peaks.peaks()
    }

    public func tick(now: Double) async {
        var s = await sensors.read(now: now)
        if Task.isCancelled || isShutdown { return }
        s.timestamp = now
        let usedPeaks = peaks.peaks()
        let window = Array(recent.suffix(Int(detector.thresholds.busySeconds) + 5))
        let c = detector.classify(current: s, recent: window, peaks: usedPeaks)
        s.state = c.state
        s.clockLimited = c.clockLimited
        peaks.observe(s)
        currentPeaks = peaks.peaks()

        latest = s
        recent.append(s)
        let cutoff = now - Self.memorySeconds
        if let first = recent.first, first.timestamp < cutoff { recent.removeAll { $0.timestamp < cutoff } }
        unavailable = sensors.unavailable

        if let closed = events.feed(s, peaks: usedPeaks) { save(closed) }
        openEvent = events.current
        if let kind = alertPolicy.evaluate(s) { onAlert?(kind, s) }
        onSample?(s)

        pending.append(s)
        if now - lastFlush >= Self.flushInterval { flush(now: now) }
        if now - lastMaintenance >= Self.maintenanceInterval { maintain(now: now) }
    }

    /// Writes pending events, then pending samples. Failed items stay queued (samples up to `memorySeconds`)
    /// and are retried next flush. `storeError` clears only when both writes succeed.
    public func flush(now: Double = Date().timeIntervalSince1970) {
        lastFlush = now
        guard let store else { return }
        var failure: String?
        while let event = pendingEvents.first {
            do { try store.insert(event); pendingEvents.removeFirst() } catch { failure = "\(error)"; break }
        }
        if !pending.isEmpty {
            do { try store.insert(pending); pending.removeAll() } catch {
                failure = "\(error)"
                let cutoff = now - Self.memorySeconds
                pending.removeAll { $0.timestamp < cutoff }
            }
        }
        if let failure { storeError = failure } else if pendingEvents.isEmpty { storeError = nil }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date().timeIntervalSince1970
                await self?.tick(now: started)
                let elapsed = Date().timeIntervalSince1970 - started
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, 1.0 - elapsed) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Stops sampling, closes any open event and writes everything pending (app quit).
    public func shutdown(now: Double = Date().timeIntervalSince1970) {
        isShutdown = true
        stop()
        if let e = events.flush() { save(e) }
        openEvent = nil
        flush(now: now)
    }

    private func save(_ event: ThrottleEvent) {
        onEventClosed?(event)
        guard let store else { return }
        pendingEvents.append(event)
        do {
            // Write in order; anything that fails stays queued for the next flush.
            while let e = pendingEvents.first { try store.insert(e); pendingEvents.removeFirst() }
        } catch { storeError = "\(error)" }
    }

    /// Prunes old history and refreshes reference peaks from the last 7 days plus samples still in memory.
    private func maintain(now: Double) {
        lastMaintenance = now
        guard let store else { return }
        do {
            try store.prune(olderThan: now - retentionDays * 86_400)
            peaks.replaceObserved(try store.maxBusyMHz(since: now - 7 * 86_400, busyAbove: detector.thresholds.busy))
            for s in recent { peaks.observe(s) }
        } catch {
            storeError = "\(error)"
        }
    }
}
