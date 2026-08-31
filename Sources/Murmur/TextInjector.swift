import Cocoa
import ApplicationServices

/// Pastes text into whatever app currently has focus by putting it on the
/// pasteboard and synthesising ⌘V (requires Accessibility access).
enum TextInjector {
    private static let cmdKey: CGKeyCode = 0x37 // kVK_Command
    private static let vKey: CGKeyCode = 0x09   // kVK_ANSI_V

    /// Returns true if the keystroke was synthesised. When false, the text is
    /// still on the clipboard so the user can paste manually.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let previous = Defaults.restoreClipboard ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else { return false }

        // Post explicit Command-down → V-down → V-up → Command-up. Setting the
        // flag on the V events alone is ignored by some apps; sending the real
        // modifier key events is far more compatible.
        let source = CGEventSource(stateID: .combinedSessionState)
        let tap: CGEventTapLocation = .cgAnnotatedSessionEventTap

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)

        cmdDown?.post(tap: tap)
        vDown?.post(tap: tap)
        vUp?.post(tap: tap)
        cmdUp?.post(tap: tap)

        if let previous = previous {
            // Give the target app time to consume the paste before restoring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }
}
