import Cocoa

/// Watches for the Escape key while a dictation is in flight so the user can
/// abort it.
///
/// This uses a `CGEventTap` rather than the `NSEvent` global monitor that
/// `HotkeyManager` uses, because a tap can *consume* the keystroke. A global
/// monitor only observes, so Escape would still reach whatever app is being
/// dictated into and dismiss its dialog / clear its field. The tap is installed
/// only while a dictation is active, so Escape behaves normally the rest of the
/// time.
final class EscapeMonitor {
    var onEscape: () -> Void = {}

    private static let escKeyCode: Int64 = 53

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallbackMonitor: Any?

    private var isActive: Bool { tap != nil || fallbackMonitor != nil }

    func start() {
        guard !isActive else { return }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EscapeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // not .listenOnly — we need to swallow the key
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            self.tap = tap
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // Creating a tap needs Accessibility trust. Without it, degrade to an
            // observe-only monitor: Escape still cancels, it just also reaches the
            // focused app.
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == UInt16(Self.escKeyCode) else { return }
                self?.onEscape()
            }
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if let m = fallbackMonitor { NSEvent.removeMonitor(m); fallbackMonitor = nil }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond; re-arm it instead
        // of silently going deaf for the rest of the dictation.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.escKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        // Hop off the tap callback before touching app state — `onEscape` tears
        // this monitor down, which must not happen inside its own callback.
        DispatchQueue.main.async { [weak self] in self?.onEscape() }
        return nil // swallow Escape: it was meant for us, not the app underneath
    }
}
