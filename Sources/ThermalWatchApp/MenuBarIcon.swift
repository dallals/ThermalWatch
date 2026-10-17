import AppKit
import SwiftUI
import ThermalCore

enum MenuBarIcon {
    /// Chip symbol in the menu bar's text color, a status dot, and a slash when clocks are held down.
    /// Drawn lazily so `labelColor` resolves against the current menu bar appearance.
    static func image(_ status: IconStatus) -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 16), flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let chip = NSImage(systemSymbolName: "cpu", accessibilityDescription: "ThermalWatch")?.withSymbolConfiguration(config) {
                chip.draw(in: NSRect(x: 0, y: 1, width: 15, height: 14))
            }
            status.color.nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 8, height: 8)).fill()
            if status.slashed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 11, y: 0))
                slash.line(to: NSPoint(x: 21, y: 10))
                slash.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                slash.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let sample = model.monitor.latest
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(IconStatus.from(sample)))
            if model.settings.showTempInMenuBar, let t = sample?.cpuTempC {
                Text(Format.temp(t))
            }
        }
    }
}
