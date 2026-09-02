# Privacy

Murmur is a local menu-bar client. It has no Murmur-operated account, analytics,
telemetry, advertising SDK, or backend service.

## Audio

- Microphone audio is captured only while a dictation is active.
- Computer audio is captured only while a dictation is active and **Include
  Computer Audio** is enabled. ScreenCaptureKit requires macOS's Screen & System
  Audio Recording permission, but Murmur does not consume or save screen frames.
- Murmur's own cue sounds are excluded from computer-audio capture.
- Captured audio is held in memory and sent to the ASR provider configured by the
  user. Realtime mode streams audio while speaking; batch mode sends it after the
  take ends. Murmur does not persist audio recordings after the request.

## Text and credentials

- Up to 50 recent transcripts are stored locally in macOS user defaults and can
  be cleared from the menu at any time.
- Provider settings and API keys are stored locally in macOS user defaults.
- Transcripts may be sent to the user-configured LLM endpoint when LLM Polish is
  enabled.

## Input target

- When pinned insertion is enabled, Murmur uses the macOS Accessibility API at
  the start of each dictation to remember the focused app and text control.
- Murmur may temporarily read that control's current text and selection range in
  memory so it can verify the field has not changed before inserting a result.
  This context is never persisted, logged, or sent to an ASR/LLM provider.
- Secure text fields are excluded. If the original control closes, changes in an
  unsafe way, or does not support background insertion, Murmur leaves the result
  on the clipboard instead of pasting into another field.

The privacy terms and data handling of the ASR and LLM providers selected by the
user apply to requests sent to those services. Review those terms before use,
especially for confidential meetings or regulated data.
