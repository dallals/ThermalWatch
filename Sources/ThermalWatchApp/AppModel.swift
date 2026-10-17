import AppKit
import Foundation
import Observation
import ServiceManagement
import ThermalCore
import ThermalSensors

@MainActor
@Observable
final class AppModel {
    private(set) var settings: AppSettings
    let sensors: LiveSensors
    let store: HistoryStore?
    let storeOpenError: String?
    let monitor: Monitor
    private(set) var todayThrottled: Double = 0
    private(set) var todayLongest: Double = 0
    private(set) var loginItemError: String?

    /// Run first by `shutdown()` (e.g. the load test stops its threads).
    @ObservationIgnored var onShutdown: [() -> Void] = []
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        let settings = AppSettings.load()
        let sensors = LiveSensors(tokenConfig: settings.tokenConfig())
        var store: HistoryStore?
        var openError: String?
        do {
            store = try HistoryStore(path: try HistoryStore.defaultPath())
        } catch {
            openError = "\(error)"
        }
        self.settings = settings
        self.sensors = sensors
        self.store = store
        self.storeOpenError = openError
        self.monitor = Monitor(sensors: sensors, store: store)

        applySettings()
        monitor.start()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshToday()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func update(_ new: AppSettings) {
        settings = new
        new.save()
        applySettings()
    }

    func refreshToday(now: Date = Date()) {
        guard let store else { return }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let end = now.timeIntervalSince1970
        todayThrottled = (try? store.throttledSeconds(from: start, to: end)) ?? 0
        let events = ((try? store.events(from: start, to: end)) ?? []) + [monitor.openEvent].compactMap { $0 }
        todayLongest = events.map(\.duration).max() ?? 0
    }

    func shutdown() {
        onShutdown.forEach { $0() }
        statsTask?.cancel()
        monitor.shutdown()
    }

    private func applySettings() {
        monitor.retentionDays = Double(settings.retentionDays)
        monitor.alertPolicy.heavyEnabled = settings.alertHeavy
        monitor.alertPolicy.sustainedEnabled = settings.alertSustained
        sensors.updateTokenConfig(settings.tokenConfig())
        applyLoginItem()
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin, service.status != .enabled { try service.register() }
            if !settings.launchAtLogin, service.status == .enabled { try service.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Launch at login: \(error.localizedDescription)"
        }
    }
}
