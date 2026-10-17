import SwiftUI

@main
struct ThermalWatchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("ThermalWatch", id: "main") {
            MainWindowView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(model: model)
        }
    }
}
