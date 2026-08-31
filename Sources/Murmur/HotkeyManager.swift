import Cocoa

/// Push-to-talk: fires `onPress` when the chosen modifier key goes down and
/// `onRelease` when it comes back up. Uses a global flagsChanged monitor, which
/// requires Input Monitoring permission to receive events from other apps.
final class HotkeyManager {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var keyCode: UInt16 = 61 // right option

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        let pressed = isModifierActive(event)
        if pressed, !isDown {
            isDown = true
            onPress()
        } else if !pressed, isDown {
            isDown = false
            onRelease()
        }
    }

    private func isModifierActive(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch keyCode {
        case 54: return flags.contains(.command)
        case 62: return flags.contains(.control)
        case 63: return flags.contains(.function)
        default: return flags.contains(.option) // 61, right option
        }
    }
}
