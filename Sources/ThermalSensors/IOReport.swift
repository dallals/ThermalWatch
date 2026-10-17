import Foundation

public struct IOReportChannelReading: Equatable, Sendable {
    public let group: String
    public let subgroup: String
    public let channel: String
    public let unit: String
    /// State residencies for state channels (format 2); empty otherwise.
    public let states: [StateResidency]
    /// Integer value for simple channels (format 1); 0 otherwise.
    public let value: Int64

    public init(group: String, subgroup: String, channel: String, unit: String, states: [StateResidency], value: Int64) {
        self.group = group
        self.subgroup = subgroup
        self.channel = channel
        self.unit = unit
        self.states = states
        self.value = value
    }
}

/// dlopen wrapper over the private libIOReport (it lives in the dyld shared cache).
final class IOReportLib {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelFormat = @convention(c) (CFDictionary) -> UInt8
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    typealias SimpleInteger = @convention(c) (CFDictionary, Int32) -> Int64

    static let shared: IOReportLib? = IOReportLib()

    let copyChannelsInGroup: CopyChannelsInGroup
    let mergeChannels: MergeChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let getGroup: ChannelString
    let getSubGroup: ChannelString
    let getChannelName: ChannelString
    let getUnitLabel: ChannelString
    let getFormat: ChannelFormat
    let stateGetCount: StateCount
    let stateGetName: StateName
    let stateGetResidency: StateResidencyFn
    let simpleGetInteger: SimpleInteger

    private init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: type) }
        }
        guard let a = load("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let b = load("IOReportMergeChannels", MergeChannels.self),
              let c = load("IOReportCreateSubscription", CreateSubscription.self),
              let d = load("IOReportCreateSamples", CreateSamples.self),
              let e = load("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let f = load("IOReportChannelGetGroup", ChannelString.self),
              let g = load("IOReportChannelGetSubGroup", ChannelString.self),
              let i = load("IOReportChannelGetChannelName", ChannelString.self),
              let j = load("IOReportChannelGetUnitLabel", ChannelString.self),
              let k = load("IOReportChannelGetFormat", ChannelFormat.self),
              let l = load("IOReportStateGetCount", StateCount.self),
              let m = load("IOReportStateGetNameForIndex", StateName.self),
              let n = load("IOReportStateGetResidency", StateResidencyFn.self),
              let o = load("IOReportSimpleGetIntegerValue", SimpleInteger.self)
        else { return nil }
        copyChannelsInGroup = a; mergeChannels = b; createSubscription = c
        createSamples = d; createSamplesDelta = e
        getGroup = f; getSubGroup = g; getChannelName = i; getUnitLabel = j; getFormat = k
        stateGetCount = l; stateGetName = m; stateGetResidency = n; simpleGetInteger = o
    }

    func reading(_ channel: NSDictionary) -> IOReportChannelReading {
        let cf = channel as CFDictionary
        func text(_ fn: ChannelString) -> String { fn(cf).map { $0.takeUnretainedValue() as String } ?? "" }
        var states: [StateResidency] = []
        var value: Int64 = 0
        switch getFormat(cf) {
        case 2:
            for idx in 0..<stateGetCount(cf) {
                let name = stateGetName(cf, idx).map { $0.takeUnretainedValue() as String } ?? ""
                states.append(StateResidency(name: name, ticks: stateGetResidency(cf, idx)))
            }
        case 1:
            value = simpleGetInteger(cf, 0)
        default:
            break
        }
        return IOReportChannelReading(
            group: text(getGroup), subgroup: text(getSubGroup), channel: text(getChannelName),
            unit: text(getUnitLabel), states: states, value: value
        )
    }
}

/// Subscribes to IOReport groups once and returns per-interval deltas.
public final class IOReportSampler {
    private let lib: IOReportLib
    private let subscription: OpaquePointer
    private let subscribed: CFMutableDictionary
    private var previous: CFDictionary?
    private var previousTime: Double?

    public init?(groups: [(group: String, subgroup: String?)]) {
        guard let lib = IOReportLib.shared else { return nil }
        var merged: CFMutableDictionary?
        for g in groups {
            guard let chans = lib.copyChannelsInGroup(g.group as CFString, g.subgroup.map { $0 as CFString }, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let m = merged { lib.mergeChannels(m, chans, nil) } else { merged = chans }
        }
        guard let merged else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = lib.createSubscription(nil, merged, &out, 0, nil), let subscribed = out?.takeRetainedValue() else { return nil }
        self.lib = lib
        self.subscription = sub
        self.subscribed = subscribed
    }

    /// Readings for the interval since the previous call and its length in seconds; nil on the first call.
    public func next(now: Double) -> (readings: [IOReportChannelReading], seconds: Double)? {
        guard let current = lib.createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let prev = previous, let prevTime = previousTime, now > prevTime,
              let delta = lib.createSamplesDelta(prev, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        return (channels.map(lib.reading), now - prevTime)
    }
}
