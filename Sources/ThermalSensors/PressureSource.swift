import Darwin
import notify

/// macOS thermal pressure (0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping), readable without sudo.
public final class PressureSource {
    private var token: Int32 = 0
    private let registered: Bool

    public init() {
        registered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == 0
    }

    deinit { if registered { notify_cancel(token) } }

    public func read() -> Int? {
        guard registered else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == 0, state <= 4 else { return nil }
        return Int(state)
    }
}
