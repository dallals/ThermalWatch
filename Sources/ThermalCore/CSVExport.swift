import Foundation

public enum CSVExport {
    public static let header = "time,pressure,super_mhz,perf_mhz,gpu_mhz,super_busy,perf_busy,gpu_busy,gpu_thermal_capped,cpu_w,gpu_w,system_w,cpu_temp_c,gpu_temp_c,fan_rpm,tokens_per_sec,state,clock_limited"

    public static func csv(_ samples: [Sample]) -> String {
        let iso = ISO8601DateFormatter()
        func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        func f3(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        var lines = [header]
        for s in samples {
            let columns = [
                iso.string(from: Date(timeIntervalSince1970: s.timestamp)),
                s.pressure.map(String.init) ?? "",
                f1(s.superMHz), f1(s.perfMHz), f1(s.gpuMHz),
                f3(s.superBusy), f3(s.perfBusy), f3(s.gpuBusy),
                s.gpuThermalCapped.map { $0 ? "1" : "0" } ?? "",
                f1(s.cpuWatts), f1(s.gpuWatts), f1(s.systemWatts),
                f1(s.cpuTempC), f1(s.gpuTempC),
                s.fanRPM.map { String(Int($0.rounded())) }.joined(separator: ";"),
                f1(s.tokensPerSec),
                String(s.state.rawValue),
                s.clockLimited ? "1" : "0",
            ]
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
