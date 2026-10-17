import Foundation
import ThermalCore
import ThermalSensors

struct AppSettings: Codable, Equatable {
    var launchAtLogin = true
    var showTempInMenuBar = false
    var alertHeavy = true
    var alertSustained = true
    var retentionDays = 7
    var omlxURL = "http://127.0.0.1:8901"
    var keyEnvPath = "~/.konaclaw.env"
    /// Empty = send no key (oMLX on localhost does not need one).
    var keyEnvVar = ""

    static let defaultsKey = "settings.v1"

    static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func tokenConfig() -> TokenSource.Config? {
        guard let url = URL(string: omlxURL), url.scheme != nil, url.host != nil else { return nil }
        var bearer: String?
        if !keyEnvVar.isEmpty,
           let text = try? String(contentsOfFile: (keyEnvPath as NSString).expandingTildeInPath, encoding: .utf8) {
            bearer = EnvFile.value(named: keyEnvVar, in: text)
        }
        return TokenSource.Config(baseURL: url, bearer: bearer)
    }
}
