import Cocoa
import ApplicationServices

/// Pastes text into whatever app currently has focus by putting it on the
/// pasteboard and synthesising ⌘V (requires Accessibility access).
enum TextInjector {
    private static let cmdKey: CGKeyCode = 0x37 // kVK_Command
    private static let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
    /// Consecutive ordered results share one clipboard-restore session. Without
    /// this, result #2 would capture result #1 as the "previous" clipboard and
    /// the two delayed restore callbacks would race, sometimes leaving a
    /// transcript in the clipboard instead of the user's original content.
    private static var restoreSessionActive = false
    private static var restoreSessionPrevious: String?
    private static var restoreGeneration = 0

    /// Returns true if the keystroke was synthesised. When false, the text is
    /// still on the clipboard so the user can paste manually.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let shouldRestore = Defaults.restoreClipboard

        if shouldRestore, !restoreSessionActive {
            restoreSessionPrevious = pasteboard.string(forType: .string)
            restoreSessionActive = true
        } else if !shouldRestore {
            restoreGeneration &+= 1 // invalidate a restore scheduled by an earlier insertion
            restoreSessionActive = false
            restoreSessionPrevious = nil
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            // The transcript intentionally remains available for a manual ⌘V.
            restoreGeneration &+= 1
            restoreSessionActive = false
            restoreSessionPrevious = nil
            return false
        }

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

        if shouldRestore {
            // Every subsequent insertion moves this deadline out while retaining
            // the clipboard value captured before the first result in the burst.
            restoreGeneration &+= 1
            let generation = restoreGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard restoreGeneration == generation else { return }
                let previous = restoreSessionPrevious
                restoreSessionActive = false
                restoreSessionPrevious = nil
                guard let previous else { return }
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }
}
