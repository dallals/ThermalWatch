import Foundation

public enum Format {
    public static let dash = "—"

    public static func ghz(_ mhz: Double?) -> String {
        guard let mhz, mhz.isFinite else { return dash }
        return String(format: "%.2f GHz", mhz / 1000)
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return dash }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// An event's clock drop: the typical drop beside the worst second, e.g. "GPU −45% typical, −77% worst".
    public static func clockDrop(_ e: ThrottleEvent) -> String {
        guard e.maxClockDrop > 0 else { return "clocks not reduced" }
        let who = e.dropCluster?.label ?? "clocks"
        let worst = "−\(percent(e.maxClockDrop)) worst"
        guard let typical = e.typicalClockDrop else { return "\(who) \(worst)" }
        return "\(who) −\(percent(typical)) typical, \(worst)"
    }

    public static func temp(_ c: Double?) -> String {
        c.flatMap { $0.isFinite ? "\(Int($0.rounded()))°" : nil } ?? dash
    }

    public static func watts(_ w: Double?) -> String {
        w.flatMap { $0.isFinite ? "\(Int($0.rounded())) W" : nil } ?? dash
    }

    /// Thousands separators without depending on the user's locale.
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    public static func rpm(_ fans: [Double]) -> String {
        guard let top = fans.filter(\.isFinite).max() else { return dash }
        return "\(grouped(Int(top.rounded()))) rpm"
    }

    public static func tokens(_ tps: Double?) -> String {
        tps.flatMap { $0.isFinite ? "\(Int($0.rounded())) tok/s" : nil } ?? "idle"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0s" }
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    /// "41 → 29 tok/s, −29%" or nil when either side is missing.
    public static func tokenChange(before: Double?, during: Double?) -> String? {
        guard let before, let during, before.isFinite, during.isFinite, before > 0 else { return nil }
        let pct = Int(((during - before) / before * 100).rounded())
        let sign = pct < 0 ? "−" : "+"
        return "\(Int(before.rounded())) → \(Int(during.rounded())) tok/s, \(sign)\(abs(pct))%"
    }
}
