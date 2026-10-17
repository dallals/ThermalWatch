// swift-tools-version: 6.0
import PackageDescription

let mode5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ThermalWatch",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "thermalwatch-probe", targets: ["ThermalProbe"]),
    ],
    targets: [
        .target(
            name: "ThermalCore",
            swiftSettings: mode5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"], swiftSettings: mode5),
        .target(
            name: "ThermalSensors",
            dependencies: ["ThermalCore"],
            swiftSettings: mode5,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "ThermalSensorsTests", dependencies: ["ThermalSensors"], swiftSettings: mode5),
        .executableTarget(name: "ThermalProbe", dependencies: ["ThermalCore", "ThermalSensors"], swiftSettings: mode5),
    ]
)
