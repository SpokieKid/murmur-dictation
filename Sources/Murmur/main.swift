import Cocoa

// Murmur — a tiny menu-bar dictation app in the spirit of Wispr Flow / Typeless.
// Hold a hotkey, speak, and your words are transcribed by *your own* ASR API
// and pasted at the cursor in whatever app is focused.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
