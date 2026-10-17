import SwiftUI
import ThermalCore

struct EventsList: View {
    let events: [ThrottleEvent]
    let onSelect: (ThrottleEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Throttle events").font(.headline)
            if events.isEmpty {
                Text("None in this range").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(events) { event in
                    Button { onSelect(event) } label: { EventRow(event: event) }
                        .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct EventRow: View {
    let event: ThrottleEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(StatusColor.color(pressure: event.worstPressure, clockLimited: event.maxClockDrop > 0, warm: false).swiftUIColor)
                    .frame(width: 8, height: 8)
                Text(Date(timeIntervalSince1970: event.start), format: .dateTime.month().day().hour().minute().second())
                Spacer()
                Text(Format.duration(event.duration)).monospacedDigit()
            }
            Text("\(PressureLevel(rawValue: event.worstPressure)?.label ?? Format.dash) · clocks −\(Format.percent(event.maxClockDrop))")
                .font(.caption).foregroundStyle(.secondary)
            if let change = Format.tokenChange(before: event.tokensBefore, during: event.tokensDuring) {
                Text(change).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
