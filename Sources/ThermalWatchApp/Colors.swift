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
