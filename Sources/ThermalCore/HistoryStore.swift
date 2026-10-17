import Foundation
import SQLite3

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): "SQLite: \(m)" }
    }
}

public protocol HistoryWriting: AnyObject {
    func insert(_ samples: [Sample]) throws
    func insert(_ event: ThrottleEvent) throws
    func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double]
    func prune(olderThan cutoff: Double) throws
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Serialized SQLite connection (SQLITE_OPEN_FULLMUTEX), safe to call from any thread.
public final class HistoryStore: HistoryWriting, @unchecked Sendable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            db = nil
            throw StoreError.sqlite(message)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS samples (
              ts REAL PRIMARY KEY, pressure INTEGER,
              super_mhz REAL, perf_mhz REAL, gpu_mhz REAL,
              super_busy REAL, perf_busy REAL, gpu_busy REAL, gpu_capped INTEGER,
              cpu_w REAL, gpu_w REAL, sys_w REAL, cpu_t REAL, gpu_t REAL,
              fans TEXT NOT NULL, tps REAL, state INTEGER NOT NULL, limited INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
              start REAL PRIMARY KEY, end REAL NOT NULL, worst INTEGER NOT NULL, drop_frac REAL NOT NULL,
              tps_before REAL, tps_during REAL);
            CREATE TABLE IF NOT EXISTS load_tests (
              id INTEGER PRIMARY KEY AUTOINCREMENT, started REAL NOT NULL, json TEXT NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    public static func defaultPath() throws -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThermalWatch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite").path
    }

    // MARK: Samples

    public func insert(_ samples: [Sample]) throws {
        guard !samples.isEmpty else { return }
        try transaction {
            let st = try prepare("INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(st) }
            for s in samples {
                sqlite3_reset(st)
                sqlite3_clear_bindings(st)
                bindDouble(st, 1, s.timestamp)
                bindInt(st, 2, s.pressure)
                bindDouble(st, 3, s.superMHz)
                bindDouble(st, 4, s.perfMHz)
                bindDouble(st, 5, s.gpuMHz)
                bindDouble(st, 6, s.superBusy)
                bindDouble(st, 7, s.perfBusy)
                bindDouble(st, 8, s.gpuBusy)
                bindInt(st, 9, s.gpuThermalCapped.map { $0 ? 1 : 0 })
                bindDouble(st, 10, s.cpuWatts)
                bindDouble(st, 11, s.gpuWatts)
                bindDouble(st, 12, s.systemWatts)
                bindDouble(st, 13, s.cpuTempC)
                bindDouble(st, 14, s.gpuTempC)
                bindText(st, 15, s.fanRPM.map { String($0) }.joined(separator: ","))
                bindDouble(st, 16, s.tokensPerSec)
                bindInt(st, 17, s.state.rawValue)
                bindInt(st, 18, s.clockLimited ? 1 : 0)
                try step(st)
            }
        }
    }

    public func samples(from start: Double, to end: Double) throws -> [Sample] {
        let st = try prepare("SELECT * FROM samples WHERE ts >= ? AND ts <= ? ORDER BY ts")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        var out: [Sample] = []
        while try stepRow(st) {
            var s = Sample(timestamp: sqlite3_column_double(st, 0), pressure: int(st, 1))
            s.superMHz = double(st, 2)
            s.perfMHz = double(st, 3)
            s.gpuMHz = double(st, 4)
            s.superBusy = double(st, 5)
            s.perfBusy = double(st, 6)
            s.gpuBusy = double(st, 7)
            s.gpuThermalCapped = int(st, 8).map { $0 != 0 }
            s.cpuWatts = double(st, 9)
            s.gpuWatts = double(st, 10)
            s.systemWatts = double(st, 11)
            s.cpuTempC = double(st, 12)
            s.gpuTempC = double(st, 13)
            s.fanRPM = text(st, 14).split(separator: ",").compactMap { Double($0) }
            s.tokensPerSec = double(st, 15)
            s.state = ThrottleState(rawValue: int(st, 16) ?? 0) ?? .cool
            s.clockLimited = (int(st, 17) ?? 0) != 0
            out.append(s)
        }
        return out
    }

    public func throttledSeconds(from start: Double, to end: Double) throws -> Double {
        let st = try prepare("SELECT COUNT(*) FROM samples WHERE ts >= ? AND ts <= ? AND state = 2")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        return try stepRow(st) ? sqlite3_column_double(st, 0) : 0
    }

    public func maxBusyMHz(since: Double, busyAbove: Double) throws -> [Cluster: Double] {
        let st = try prepare("""
            SELECT MAX(CASE WHEN super_busy > ?2 THEN super_mhz END),
                   MAX(CASE WHEN perf_busy > ?2 THEN perf_mhz END),
                   MAX(CASE WHEN gpu_busy > ?2 THEN gpu_mhz END)
            FROM samples WHERE ts >= ?1
            """)
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, since)
        bindDouble(st, 2, busyAbove)
        var out: [Cluster: Double] = [:]
        if try stepRow(st) {
            if let v = double(st, 0) { out[.superCores] = v }
            if let v = double(st, 1) { out[.performance] = v }
            if let v = double(st, 2) { out[.gpu] = v }
        }
        return out
    }

    // MARK: Events

    public func insert(_ e: ThrottleEvent) throws {
        let st = try prepare("INSERT OR REPLACE INTO events VALUES (?,?,?,?,?,?)")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, e.start)
        bindDouble(st, 2, e.end)
        bindInt(st, 3, e.worstPressure)
        bindDouble(st, 4, e.maxClockDrop)
        bindDouble(st, 5, e.tokensBefore)
        bindDouble(st, 6, e.tokensDuring)
        try step(st)
    }

    public func events(from start: Double, to end: Double) throws -> [ThrottleEvent] {
        let st = try prepare("SELECT * FROM events WHERE end >= ? AND start <= ? ORDER BY start DESC")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, start)
        bindDouble(st, 2, end)
        var out: [ThrottleEvent] = []
        while try stepRow(st) {
            out.append(ThrottleEvent(start: sqlite3_column_double(st, 0), end: sqlite3_column_double(st, 1),
                                     worstPressure: int(st, 2) ?? 0, maxClockDrop: double(st, 3) ?? 0,
                                     tokensBefore: double(st, 4), tokensDuring: double(st, 5)))
        }
        return out
    }

    public func prune(olderThan cutoff: Double) throws {
        try transaction {
            let a = try prepare("DELETE FROM samples WHERE ts < ?")
            defer { sqlite3_finalize(a) }
            bindDouble(a, 1, cutoff)
            try step(a)
            let b = try prepare("DELETE FROM events WHERE end < ?")
            defer { sqlite3_finalize(b) }
            bindDouble(b, 1, cutoff)
            try step(b)
        }
    }

    // MARK: Load tests

    public func insert(_ result: LoadTestResult) throws -> Int64 {
        var copy = result
        copy.id = nil
        let json = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        let st = try prepare("INSERT INTO load_tests (started, json) VALUES (?, ?)")
        defer { sqlite3_finalize(st) }
        bindDouble(st, 1, result.startedAt)
        bindText(st, 2, json)
        try step(st)
        return sqlite3_last_insert_rowid(db)
    }

    public func loadTests() throws -> [LoadTestResult] {
        let st = try prepare("SELECT id, json FROM load_tests ORDER BY started DESC, id DESC")
        defer { sqlite3_finalize(st) }
        var out: [LoadTestResult] = []
        while try stepRow(st) {
            guard var r = try? JSONDecoder().decode(LoadTestResult.self, from: Data(text(st, 1).utf8)) else { continue }
            r.id = sqlite3_column_int64(st, 0)
            out.append(r)
        }
        return out
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return st
    }

    private func step(_ st: OpaquePointer) throws {
        let r = sqlite3_step(st)
        guard r == SQLITE_DONE || r == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    /// True while rows remain.
    private func stepRow(_ st: OpaquePointer) throws -> Bool {
        switch sqlite3_step(st) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindDouble(_ st: OpaquePointer, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    }

    private func bindInt(_ st: OpaquePointer, _ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) }
    }

    private func bindText(_ st: OpaquePointer, _ i: Int32, _ v: String) {
        sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT)
    }

    private func double(_ st: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
    }

    private func int(_ st: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i))
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }
}
