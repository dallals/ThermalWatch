import AppKit
import os

/// ThermalWatch is a menu-bar (UIElement) app, and an accessory app has no menu bar of its own:
/// while it is frontmost, the previous app's menus vanish. So while any real window is open
/// (history, load test, settings) the app runs as a regular app with a Dock icon and menu bar,
/// and when the last one closes it drops back to accessory and hands focus to the app the user
/// was in before.
@MainActor
final class DockPresence {
    private let log = Logger(subsystem: "com.sammydallal.thermalwatch", category: "dock")
    private var observers: [NSObjectProtocol] = []
    /// The most recent other app the user had in front, to return focus to.
    private var previousApp: NSRunningApplication?

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(closing: nil) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.update(closing: window) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != NSRunningApplication.current { self?.previousApp = app }
            }
        })
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
    }

    /// A window the user opened: titled, not the menu-bar popover panel, and on screen or in the Dock.
    static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && (w.isVisible || w.isMiniaturized)
    }

    private func update(closing: NSWindow?) {
        let hasWindows = NSApp.windows.contains { $0 !== closing && Self.isAppWindow($0) }
        let current = NSApp.activationPolicy()
        if hasWindows, current != .regular {
            log.info("window open: switching to regular")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        } else if !hasWindows, current != .accessory {
            log.info("last window closed: switching to accessory")
            NSApp.setActivationPolicy(.accessory)
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate()
            } else {
                NSApp.hide(nil)
            }
        }
    }
}
