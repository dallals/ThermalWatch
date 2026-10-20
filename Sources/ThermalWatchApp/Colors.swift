import AppKit
import SwiftUI
import ThermalCore

extension StatusColor {
    var nsColor: NSColor {
        switch self {
        case .gray: .systemGray
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}

/// Chart series colors. Each part keeps one color on every chart (GPU is green everywhere), and none of
/// them is yellow/orange/red, which stay reserved for throttle shading. Light and dark steps were checked
/// as a set for color-blind separation and contrast against the chart background.
enum SeriesColor {
    static let superCores = dynamic(light: 0xE87BA4, dark: 0xD55181)
    static let cpu = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let gpu = dynamic(light: 0x008300, dark: 0x1F9A1F)
    static let tokens = dynamic(light: 0x6250D6, dark: 0x9085E9)
    static let neutral = Color(nsColor: .secondaryLabelColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}
