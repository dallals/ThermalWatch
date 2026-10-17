import Foundation

public enum StatusColor: String, Sendable {
    case gray, green, yellow, orange, red

    /// Spec "Menu-bar icon": red = trapping/sleeping; orange = heavy, or clock-limited at lower pressure;
    /// yellow = moderate pressure or warm; green otherwise.
    public static func color(pressure: Int, clockLimited: Bool, warm: Bool) -> StatusColor {
        if pressure >= 3 { return .red }
        if pressure == 2 || clockLimited { return .orange }
        if pressure == 1 || warm { return .yellow }
        return .green
    }
}

public struct IconStatus: Equatable, Sendable {
    public var color: StatusColor
    public var slashed: Bool

    public init(color: StatusColor, slashed: Bool) {
        self.color = color
        self.slashed = slashed
    }

    public static func from(_ sample: Sample?) -> IconStatus {
        guard let s = sample else { return IconStatus(color: .gray, slashed: false) }
        let color = StatusColor.color(pressure: s.pressure ?? 0, clockLimited: s.clockLimited, warm: s.state == .warm)
        return IconStatus(color: color, slashed: s.clockLimited)
    }
}
