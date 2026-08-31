import Cocoa
import AVFoundation
import ApplicationServices

enum Permissions {
    static func requestMicrophone(_ completion: ((Bool) -> Void)? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion?(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion?(granted) }
            }
        default:
            completion?(false)
        }
    }

    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Opens the relevant System Settings panes so the user can grant access.
    static func openSystemSettings() {
        _ = isAccessibilityTrusted(prompt: true) // triggers the Accessibility prompt
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        if let url = URL(string: urls[0]) { NSWorkspace.shared.open(url) }
    }
}
