import SwiftUI
import ThermalCore

struct SettingsView: View {
    let model: AppModel
    @State private var draft = AppSettings()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $draft.launchAtLogin)
                Toggle("Show hottest chip temperature in the menu bar", isOn: $draft.showTempInMenuBar)
                Stepper("Keep history for \(draft.retentionDays) days", value: $draft.retentionDays, in: 1...30)
            }
            Section("Alerts") {
                Toggle("Thermal pressure reaches Heavy", isOn: $draft.alertHeavy)
                Toggle("Clocks held down for 30 seconds", isOn: $draft.alertSustained)
            }
            Section("oMLX token speed") {
                TextField("Server URL", text: $draft.omlxURL)
                TextField("Key file", text: $draft.keyEnvPath)
                TextField("Key variable (leave empty for no key)", text: $draft.keyEnvVar)
                if let error = model.tokenError {
                    Text("Last error: \(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.loginItemError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Save") { model.update(draft) }
                    .disabled(draft == model.settings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { draft = model.settings }
    }
}
