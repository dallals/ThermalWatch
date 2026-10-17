// swift-tools-version: 6.0
import PackageDescription

let mode5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ThermalWatch",
    platforms: [.macOS("27.0")],
    products: [],
    targets: [
        .target(
            name: "ThermalCore",
            swiftSettings: mode5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore"], swiftSettings: mode5),
    ]
)
