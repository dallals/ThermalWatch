import Foundation
import IOKit

/// Mirrors the kernel's SMCKeyData_t (80 bytes). Field order and padding matter.
struct SMCKeyData {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    var key: UInt32 = 0
    var vers: (major: UInt8, minor: UInt8, build: UInt8, reserved: UInt8, release: UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (version: UInt16, length: UInt16, cpu: UInt32, gpu: UInt32, mem: UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (dataSize: UInt32, dataType: UInt32, attributes: UInt8, pad0: UInt8, pad1: UInt8, pad2: UInt8) = (0, 0, 0, 0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

public final class SMCClient {
    private static let selector: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyAtIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.size
        let r = IOConnectCallStructMethod(connection, Self.selector, &input, MemoryLayout<SMCKeyData>.size, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.cmdKeyInfo
        guard let out = call(&input) else { return nil }
        let value = (size: out.keyInfo.dataSize, type: out.keyInfo.dataType)
        infoCache[key] = value
        return value
    }

    public func read(_ key: String) -> Double? {
        let code = SMCValue.fourCC(key)
        guard let inf = info(code) else { return nil }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = inf.size
        input.data8 = Self.cmdReadKey
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(inf.size, 32)))) }
        return SMCValue.decode(type: SMCValue.string(inf.type), bytes: bytes)
    }

    public func allKeys() -> [String] {
        let count = Int(read("#KEY") ?? 0)
        return (0..<count).compactMap { index in
            var input = SMCKeyData()
            input.data8 = Self.cmdKeyAtIndex
            input.data32 = UInt32(index)
            return call(&input).map { SMCValue.string($0.key) }
        }
    }
}

public struct SMCReading: Equatable, Sendable {
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPM: [Double] = []
    public var cpuWatts: Double?
    public var systemWatts: Double?
    public init() {}
}

public final class SMCSource {
    private let client: SMCClient
    private let cpuKeys: [String]
    private let gpuKeys: [String]
    private let fanCount: Int

    public init?(client: SMCClient? = SMCClient()) {
        guard let client else { return nil }
        self.client = client
        let keys = client.allKeys()
        cpuKeys = keys.filter(SMCKeys.isCPUDie)
        gpuKeys = keys.filter(SMCKeys.isGPUDie)
        fanCount = Int(client.read("FNum") ?? 0)
    }

    public var hasTemperatureKeys: Bool { !cpuKeys.isEmpty || !gpuKeys.isEmpty }

    public func read() -> SMCReading {
        func values(_ keys: [String]) -> [String: Double] {
            var out: [String: Double] = [:]
            for k in keys { if let v = client.read(k) { out[k] = v } }
            return out
        }
        var r = SMCReading()
        r.cpuTempC = SMCKeys.hottest(values(cpuKeys), where: SMCKeys.isCPUDie)
        r.gpuTempC = SMCKeys.hottest(values(gpuKeys), where: SMCKeys.isGPUDie)
        r.fanRPM = (0..<fanCount).compactMap { client.read("F\($0)Ac") }
        r.cpuWatts = client.read("PHPC")
        r.systemWatts = client.read("PSTR")
        return r
    }
}
