import Cocoa
import ApplicationServices

/// Delivers completed transcripts to the text field where dictation began.
///
/// The target is captured on hotkey-down, before any permission sheet or HUD
/// can change focus. Delivery first attempts a direct Accessibility insertion;
/// if the original element is still its app's focused control, a process-scoped
/// synthetic paste is used as a compatibility fallback. We never paste into an
/// unrelated foreground app.
enum TextInjector {
    private static let cmdKey: CGKeyCode = 0x37 // kVK_Command
    private static let vKey: CGKeyCode = 0x09   // kVK_ANSI_V

    enum InsertionResult {
        case inserted
        case copiedAccessibilityRequired
        case copiedTargetUnavailable

        var didInsert: Bool {
            if case .inserted = self { return true }
            return false
        }
    }

    /// A mutable session for one concrete input control. Parallel jobs that
    /// began in the same control share this object, allowing each successful
    /// insertion to advance the expected text/caret state for the next result.
    final class Target {
        let id = UUID()
        let pid: pid_t
        let bundleIdentifier: String?
        fileprivate let element: AXUIElement?
        fileprivate let isSecure: Bool
        fileprivate var expectedValue: String?
        fileprivate var expectedSelection: CFRange?

        fileprivate init(
            pid: pid_t,
            bundleIdentifier: String?,
            element: AXUIElement?,
            isSecure: Bool,
            expectedValue: String?,
            expectedSelection: CFRange?
        ) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.element = element
            self.isSecure = isSecure
            self.expectedValue = expectedValue
            self.expectedSelection = expectedSelection
        }

        /// AXUIElement proxies for the same control compare equal even when they
        /// were obtained by separate accessibility queries.
        func matches(_ other: Target) -> Bool {
            guard pid == other.pid,
                  !isSecure,
                  !other.isSecure,
                  let element,
                  let otherElement = other.element else { return false }
            return CFEqual(element, otherElement)
        }
    }

    /// Consecutive process-scoped paste events share one clipboard-restore
    /// session. Direct AX insertions never touch the clipboard.
    private static var restoreSessionActive = false
    private static var restoreSessionPrevious: String?
    private static var restoreGeneration = 0

    /// Snapshots the app and focused input control under the hotkey. A target
    /// containing only a PID is still useful: it preserves legacy auto-paste if
    /// that same app remains in front, while preventing cross-app mis-pastes.
    static func captureTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        guard AXIsProcessTrusted() else {
            return Target(
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                element: nil,
                isSecure: false,
                expectedValue: nil,
                expectedSelection: nil
            )
        }

        let appElement = AXUIElementCreateApplication(pid)
        let focused = focusedElement(in: appElement)
        let subrole = focused.flatMap { stringAttribute(kAXSubroleAttribute as CFString, from: $0) }
        let secure = subrole == (kAXSecureTextFieldSubrole as String)

        return Target(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            element: focused,
            isSecure: secure,
            expectedValue: secure ? nil : focused.flatMap {
                stringAttribute(kAXValueAttribute as CFString, from: $0)
            },
            expectedSelection: secure ? nil : focused.flatMap {
                rangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: $0)
            }
        )
    }

    /// Inserts into the captured target. With target locking disabled, this
    /// intentionally preserves the original "paste wherever focus is now"
    /// behavior for users who prefer it.
    static func insert(_ text: String, into target: Target?) -> InsertionResult {
        guard !text.isEmpty else { return .copiedTargetUnavailable }

        if !Defaults.lockInsertionTarget {
            preparePasteboard(with: text)
            guard AXIsProcessTrusted(), postPasteEvents(to: nil) else {
                keepTranscriptOnPasteboard()
                return AXIsProcessTrusted() ? .copiedTargetUnavailable : .copiedAccessibilityRequired
            }
            scheduleClipboardRestoreIfNeeded()
            return .inserted
        }

        guard AXIsProcessTrusted() else {
            copyForFallback(text)
            return .copiedAccessibilityRequired
        }
        guard let target, !target.isSecure, isProcessRunning(target.pid) else {
            copyForFallback(text)
            return .copiedTargetUnavailable
        }

        if insertDirectly(text, into: target) {
            return .inserted
        }

        // A targeted ⌘V is safe only while the original control is still that
        // app's focused element. If the user changed fields within the same app,
        // fail closed instead of guessing.
        guard targetIsStillFocused(target) else {
            copyForFallback(text)
            return .copiedTargetUnavailable
        }

        preparePasteboard(with: text)
        guard postPasteEvents(to: target.pid) else {
            keepTranscriptOnPasteboard()
            return .copiedTargetUnavailable
        }
        scheduleClipboardRestoreIfNeeded()
        refreshExpectedState(of: target)
        return .inserted
    }

    private static func insertDirectly(_ text: String, into target: Target) -> Bool {
        guard let element = target.element else { return false }

        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success,
              actualPID == target.pid else { return false }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return false }

        // When the app exposes both value and selection, make sure the field did
        // not change behind our back. A changed field falls through to the
        // process-scoped paste path, but only if this exact element is focused.
        if let expected = target.expectedValue,
           let current = stringAttribute(kAXValueAttribute as CFString, from: element),
           current != expected {
            return false
        }
        if let expected = target.expectedSelection,
           let current = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element),
           !rangesEqual(expected, current) {
            return false
        }

        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard error == .success else { return false }
        refreshExpectedState(of: target)
        return true
    }

    private static func targetIsStillFocused(_ target: Target) -> Bool {
        guard isProcessRunning(target.pid) else { return false }
        guard let element = target.element else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        }
        let appElement = AXUIElementCreateApplication(target.pid)
        guard let focused = focusedElement(in: appElement) else { return false }
        return CFEqual(element, focused)
    }

    private static func refreshExpectedState(of target: Target) {
        guard let element = target.element else { return }
        target.expectedValue = stringAttribute(kAXValueAttribute as CFString, from: element)
        target.expectedSelection = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
    }

    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXFocusedUIElementAttribute as CFString, from: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private static func rangeAttribute(_ name: CFString, from element: AXUIElement) -> CFRange? {
        guard let raw = attribute(name, from: element),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func rangesEqual(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    private static func preparePasteboard(with text: String) {
        let pasteboard = NSPasteboard.general
        let shouldRestore = Defaults.restoreClipboard

        if shouldRestore, !restoreSessionActive {
            restoreSessionPrevious = pasteboard.string(forType: .string)
            restoreSessionActive = true
        } else if !shouldRestore {
            restoreGeneration &+= 1
            restoreSessionActive = false
            restoreSessionPrevious = nil
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func copyForFallback(_ text: String) {
        keepTranscriptOnPasteboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Invalidates an earlier restore because the latest transcript must remain
    /// available for manual paste.
    private static func keepTranscriptOnPasteboard() {
        restoreGeneration &+= 1
        restoreSessionActive = false
        restoreSessionPrevious = nil
    }

    private static func postPasteEvents(to pid: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        if let pid {
            cmdDown.postToPid(pid)
            vDown.postToPid(pid)
            vUp.postToPid(pid)
            cmdUp.postToPid(pid)
        } else {
            let tap: CGEventTapLocation = .cgAnnotatedSessionEventTap
            cmdDown.post(tap: tap)
            vDown.post(tap: tap)
            vUp.post(tap: tap)
            cmdUp.post(tap: tap)
        }
        return true
    }

    private static func scheduleClipboardRestoreIfNeeded() {
        guard Defaults.restoreClipboard else { return }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        let pasteboard = NSPasteboard.general
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
}
