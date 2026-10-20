// Draws the ThermalWatch app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swiftc -parse-as-library -o .build/make-icon scripts/make-icon.swift && .build/make-icon
// The icon: a chip whose die shows a temperature line climbing from cool blue to hot red, with heat
// glowing off the chip. Colors follow the app's status palette.
import AppKit
import SwiftUI

private let canvas: CGFloat = 1024
/// macOS icon grid: an 824 pt rounded square centered on the 1024 canvas.
private let tile: CGFloat = 824

private func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: alpha)
}

/// Temperature trace in die coordinates (0...1, y up): idle, a climb under load, then running hot.
private struct Trace: Shape {
    static let points: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.22), CGPoint(x: 0.18, y: 0.24), CGPoint(x: 0.30, y: 0.21),
        CGPoint(x: 0.42, y: 0.30), CGPoint(x: 0.55, y: 0.58), CGPoint(x: 0.68, y: 0.74),
        CGPoint(x: 0.82, y: 0.80), CGPoint(x: 1.00, y: 0.84),
    ]

    func path(in rect: CGRect) -> Path {
        let pts = Self.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.maxY - $0.y * rect.height) }
        var path = Path()
        path.move(to: pts[0])
        // Smooth curve through the points (Catmull-Rom converted to cubic Béziers).
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

private struct Icon: View {
    var body: some View {
        Canvas { ctx, _ in
            let center = CGPoint(x: canvas / 2, y: canvas / 2)
            func square(_ side: CGFloat) -> CGRect {
                CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            }
            func rounded(_ rect: CGRect, _ radius: CGFloat) -> Path {
                Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            }

            // Tile: deep slate, lit from the top.
            let tileRect = square(tile)
            let tilePath = rounded(tileRect, tile * 0.225)
            ctx.fill(tilePath, with: .linearGradient(Gradient(colors: [hex(0x2A3A50), hex(0x0C1219)]),
                                                     startPoint: CGPoint(x: center.x, y: tileRect.minY), endPoint: CGPoint(x: center.x, y: tileRect.maxY)))

            // Heat coming off the chip.
            ctx.drawLayer { glow in
                glow.clip(to: tilePath)
                glow.fill(Path(ellipseIn: square(860)), with: .radialGradient(
                    Gradient(stops: [.init(color: hex(0xFF6A2A, 0.75), location: 0), .init(color: hex(0xFF3B30, 0.32), location: 0.45),
                                     .init(color: hex(0xFF3B30, 0), location: 1)]),
                    center: center, startRadius: 120, endRadius: 430))
            }
            ctx.stroke(rounded(tileRect.insetBy(dx: 1.5, dy: 1.5), tile * 0.225 - 1.5),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0.02)]),
                                             startPoint: CGPoint(x: center.x, y: tileRect.minY), endPoint: CGPoint(x: center.x, y: tileRect.maxY)),
                       lineWidth: 3)

            // Pins: five per side, reaching out from under the package.
            let chip: CGFloat = 470, pinWidth: CGFloat = 38, pinReach: CGFloat = 72, span = chip * 0.72
            let gap = (span - 5 * pinWidth) / 4
            for side in 0..<4 {
                for i in 0..<5 {
                    let along = center.x - span / 2 + CGFloat(i) * (pinWidth + gap)
                    var pin = CGRect(x: along, y: center.y - chip / 2 - pinReach, width: pinWidth, height: pinReach + 40)
                    pin = pin.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
                        .concatenating(CGAffineTransform(rotationAngle: CGFloat(side) * .pi / 2))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                    ctx.fill(rounded(pin, 9), with: .linearGradient(Gradient(colors: [hex(0xD5DCE4), hex(0x8A95A3)]),
                                                                    startPoint: CGPoint(x: pin.minX, y: pin.minY), endPoint: CGPoint(x: pin.maxX, y: pin.maxY)))
                }
            }

            // Package, with a soft shadow.
            let chipRect = square(chip)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 14))
                layer.fill(rounded(chipRect, 66), with: .linearGradient(Gradient(colors: [hex(0x55606F), hex(0x29313C)]),
                                                                        startPoint: CGPoint(x: chipRect.minX, y: chipRect.minY),
                                                                        endPoint: CGPoint(x: chipRect.maxX, y: chipRect.maxY)))
            }
            ctx.stroke(rounded(chipRect.insetBy(dx: 2.5, dy: 2.5), 64), with: .color(hex(0x9AA5B4, 0.55)), lineWidth: 5)

            // Die: a small chart with two gridlines and the temperature trace.
            let dieRect = square(360)
            ctx.fill(rounded(dieRect, 42), with: .linearGradient(Gradient(colors: [hex(0x19222D), hex(0x0D131A)]),
                                                                 startPoint: CGPoint(x: center.x, y: dieRect.minY), endPoint: CGPoint(x: center.x, y: dieRect.maxY)))
            ctx.stroke(rounded(dieRect.insetBy(dx: 2, dy: 2), 40), with: .color(.black.opacity(0.55)), lineWidth: 4)
            for f in [0.38, 0.66] as [CGFloat] {
                let y = dieRect.minY + dieRect.height * f
                ctx.fill(Path(CGRect(x: dieRect.minX + 32, y: y - 2, width: dieRect.width - 64, height: 4)), with: .color(.white.opacity(0.09)))
            }
            let plot = dieRect.insetBy(dx: 52, dy: 66)
            let trace = Trace().path(in: plot)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: hex(0x3A8DFF), location: 0), .init(color: hex(0x3A8DFF), location: 0.3),
                                 .init(color: hex(0xFFC43A), location: 0.58), .init(color: hex(0xFF7A2A), location: 0.8),
                                 .init(color: hex(0xFF3B30), location: 1)]),
                startPoint: CGPoint(x: plot.minX, y: center.y), endPoint: CGPoint(x: plot.maxX, y: center.y))
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 16))
                layer.stroke(trace, with: shading, style: StrokeStyle(lineWidth: 42, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(trace, with: shading, style: StrokeStyle(lineWidth: 32, lineCap: .round, lineJoin: .round))

            // Live reading at the end of the trace.
            let endPoint = Trace.points.last!
            let end = CGPoint(x: plot.minX + endPoint.x * plot.width, y: plot.maxY - endPoint.y * plot.height)
            func dot(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)) }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 14))
                layer.fill(dot(40), with: .color(hex(0xFF3B30, 0.9)))
            }
            ctx.fill(dot(28), with: .color(hex(0xFF3B30)))
            ctx.fill(dot(14), with: .color(.white))
        }
        .frame(width: canvas, height: canvas)
    }
}

@main
struct MakeIcon {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ThermalWatch-\(UUID().uuidString)")
        let iconset = work.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: Icon())
                renderer.scale = CGFloat(size * scale) / canvas
                guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try png.write(to: iconset.appendingPathComponent(name))
                if size == 512 && scale == 2 { try png.write(to: root.appendingPathComponent("docs/images/app-icon.png")) }
            }
        }
        let out = root.appendingPathComponent("Resources/AppIcon.icns")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        print("wrote \(out.path)")
    }
}
