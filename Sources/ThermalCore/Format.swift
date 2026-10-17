import Foundation

public enum Format {
    public static let dash = "—"

    public static func ghz(_ mhz: Double?) -> String {
        guard let mhz else { return dash }
        return String(format: "%.2f GHz", mhz / 1000)
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return dash }
        return "\(Int((fraction * 100).rounded()))%"
    }

    public static func temp(_ c: Double?) -> String {
        c.map { "\(Int($0.rounded()))°" } ?? dash
    }

    public static func watts(_ w: Double?) -> String {
        w.map { "\(Int($0.rounded())) W" } ?? dash
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
        guard let top = fans.max() else { return dash }
        return "\(grouped(Int(top.rounded()))) rpm"
    }

    public static func tokens(_ tps: Double?) -> String {
        tps.map { "\(Int($0.rounded())) tok/s" } ?? "idle"
    }

    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    /// "41 → 29 tok/s, −29%" or nil when either side is missing.
    public static func tokenChange(before: Double?, during: Double?) -> String? {
        guard let before, let during, before > 0 else { return nil }
        let pct = Int(((during - before) / before * 100).rounded())
        let sign = pct < 0 ? "−" : "+"
        return "\(Int(before.rounded())) → \(Int(during.rounded())) tok/s, \(sign)\(abs(pct))%"
    }
}
