import Foundation
import ThermalCore
import UserNotifications

@MainActor
final class Notifier {
    private(set) var authorized = false

    func requestAuthorization() async {
        authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ kind: AlertKind, sample: Sample, peaks: [Cluster: Double]) {
        deliver(id: "\(kind.rawValue)-\(Int(sample.timestamp))", title: AlertText.title(kind),
                body: AlertText.body(kind: kind, sample: sample, peaks: peaks))
    }

    func postTest() {
        deliver(id: "test-\(Int(Date().timeIntervalSince1970))", title: "ThermalWatch", body: "Notifications are working.")
    }

    private func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
