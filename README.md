# Murmur 🎙️

[简体中文](README.zh-CN.md)

[![CI](https://github.com/SpokieKid/Murmur/actions/workflows/ci.yml/badge.svg)](https://github.com/SpokieKid/Murmur/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](https://www.apple.com/macos/)

A tiny macOS menu-bar dictation app in the spirit of **Wispr Flow** and **Typeless** —
but you bring your **own ASR API**. Hold a key, speak, release, and your words are
transcribed back into the field where dictation began, even if you switch windows
while Murmur is working.

No subscription, no vendor lock-in. Point it at OpenAI Whisper, Groq, a local
`whisper.cpp` server, or Alibaba's **Qwen3-ASR (`qwen3-asr-flash`)**.

Murmur is open source and uses your own API credentials. Configure an OpenAI-compatible
ASR endpoint or Alibaba Cloud Model Studio, grant the macOS permissions, and start talking.

## Features

- 🎙️ **Push-to-talk dictation** — hold a key, speak, release; text appears at the cursor.
- 🖥️ **Meeting / computer audio** — optionally mix macOS playback with the microphone,
  so remote participants in Zoom, Meet, Teams, Feishu, browser calls, and videos are
  transcribed alongside your own voice. Toggle it directly from the menu bar when you
  switch between meetings and music; Murmur's own cue sounds are excluded.
- 🌐 **English + 简体中文 UI** — follow the Mac's language or switch instantly in
  **General → Language**, without relaunching the app.
- ⚡️ **Keep talking while Murmur works** — press the trigger again (including Fn) while
  earlier audio is still transcribing or polishing. Takes run in parallel, then paste in
  order within each destination field.
- 🎯 **Pinned insertion target** — every take remembers the app and input field where it
  started. Switch windows immediately; completed text returns to the original field in
  the background. If that field is gone or unsafe to reach, Murmur copies the result
  instead of pasting it into the wrong window. Secure text fields are never targeted.
- 🗂️ **Stacked task HUD** — every active recording / transcription gets its own animated
  card, stacked above the original floating waveform so parallel progress stays visible.
- 🌊 **Live waveform** — a floating pill near the bottom of the screen reacts to your
  voice while recording, then shows "Transcribing…" / "Polishing…".
- ⎋ **Esc to cancel** — while recording, Esc drops the active take before any ASR call.
  When several cards are processing, Esc cancels the newest undelivered one while earlier
  jobs continue. Esc is swallowed only while Murmur has an active job.
- ✨ **LLM polish** — Qwen3.8 Flash cleans punctuation and removes filler
  words ("um", "嗯", "那个") from the raw transcript.
- 🗣️ **Voice self-edit** — correct yourself out loud and the fix is applied, not typed:
  "…scratch that…", "change Sam to Alex", "把张三改成李四". A "change X to Y" that's part of
  a message you're dictating *for someone else* is kept verbatim. Rides on the polish pass
  (no extra latency); toggle in **Polish** settings.
- 📖 **Custom vocabulary** — bias recognition toward your names, jargon, and brands.
- 🔌 **Bring your own ASR** — OpenAI-compatible *or* DashScope/Qwen3-ASR.
- ⏱️ **Recording cap with warning** — Qwen3-ASR accepts at most ~5 min / 10 MB
  per request, and the 10 MB base64 payload binds first for our PCM audio
  (~3.9 min). Murmur caps a single take at **220 s**, shows a yellow countdown
  ("⚠️ N 秒后自动停止录音") for the final minute, and auto-stops so a long take is
  transcribed instead of erroring out. The cap lives in
  `Defaults.maxRecordingSeconds()` (0 = uncapped; only DashScope is capped by default).

## How it works

1. **Press** the trigger key (default: **Right ⌥ Option**) and speak — a waveform pill
   appears and reacts to your voice. Press again to stop, or choose hold-to-talk in Settings.
2. **Stop** — Murmur captures 16 kHz mono audio and starts ASR / optional LLM polish.
3. **Keep going immediately** — while that card is processing, press the trigger again
   and record another thought. Each take processes concurrently.
4. **Safe return** — each result goes back to the field where that take started. Earlier
   takes block later ones only when they share a destination, so separate windows can
   finish independently. An unavailable target falls back to the clipboard.

It lives in the menu bar (🎙️). No Dock icon, no window unless you open Settings.

## Quick start

```bash
./build.sh            # compiles + assembles build/Murmur.app (ad-hoc signed)
open build/Murmur.app
```

Requires Xcode / Swift 6 toolchain (tested on Swift 6.3, macOS 26).

Then open **menu → Settings…** and enter an API key for your ASR provider. API keys are
stored locally in macOS user defaults and are never committed to this repository.

## First-run permissions

macOS gates everything Murmur needs behind privacy permissions. Use **menu →
"Grant Permissions…"**, then enable Murmur under each in System Settings:

| Permission         | Why                                          |
|--------------------|----------------------------------------------|
| **Microphone**     | record your voice                            |
| **Accessibility**  | remember the original input field and insert the result |
| **Input Monitoring** | detect the push-to-talk key in other apps  |
| **Screen & System Audio Recording** | capture the other side of online meetings |

After granting, quit and relaunch Murmur once so the permissions take effect.

> Tip: while testing permissions, you can also trigger recording from
> **menu → "Start / Stop Dictation"** without the global hotkey.

## Settings tabs

Open **menu → Settings…** — four tabs:

- **ASR** — speech-to-text provider, endpoint, key, model, language.
- **Polish** — toggle LLM cleanup, its endpoint/key/model, the instruction prompt, and
  **voice self-edit** (apply spoken corrections like "scratch that" / "change X to Y").
- **Vocabulary** — one term per line; biases ASR and is passed to the polish step.
- **General** — microphone device, meeting/computer audio, trigger mode + key, pinned
  insertion target, waveform, clipboard, and sounds.

### Trigger modes

- **Press once to start, again to stop** (default) — tap the trigger key to begin
  dictation, tap again to finish. Hands-free.
- **Hold to talk** — classic push-to-talk; record only while the key is held.

> In toggle mode, prefer a trigger key you don't use for typing (Right ⌃ Control or
> Fn) — Right ⌥ Option doubles as the accent/special-character modifier.

### Microphone

Pick any CoreAudio input device under **General → Microphone**, or leave it on
"System default". The choice is remembered by device UID across replug/reboot.

### Meeting / computer audio

Enable **General → Meeting audio → Capture computer audio**. macOS will ask for
**Screen & System Audio Recording** permission because ScreenCaptureKit is the system API
that exposes playback audio. Murmur captures audio only (no screen frames are stored),
mixes it with the selected microphone in real time, and sends the same 16 kHz mono stream
through the existing ASR pipeline. If permission or system capture is unavailable, the
current take falls back to microphone-only recording and marks that state in the HUD.
After setup, use **menu bar → Include Computer Audio / 收录电脑声音** as the everyday shortcut. A checked item
means computer audio is included; clear it while listening to music. If changed during a
recording, the new choice takes effect on the next dictation.

Provider endpoint and model presets are included for convenience; enter your own API key
using one of the formats below.

## Configuring your ASR provider

Two wire formats are supported:

### 1. OpenAI-compatible (default)

Multipart `POST /audio/transcriptions`. Works with OpenAI, Groq, and most local
servers (`whisper.cpp`, `faster-whisper`, LM Studio, …).

| Field    | Example                                             |
|----------|-----------------------------------------------------|
| Endpoint | `https://api.openai.com/v1/audio/transcriptions`    |
| Model    | `whisper-1` (OpenAI) · `whisper-large-v3` (Groq)    |
| API Key  | your key                                            |

Groq example: endpoint `https://api.groq.com/openai/v1/audio/transcriptions`,
model `whisper-large-v3-turbo`.

### 2. DashScope · Qwen3-ASR

For Alibaba's `qwen3-asr-flash`. Selecting this format auto-fills:

| Field    | Value                                                                                  |
|----------|----------------------------------------------------------------------------------------|
| Endpoint | `https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation` |
| Model    | `qwen3-asr-flash`                                                                       |
| API Key  | your DashScope key (`sk-...`)                                                           |

Audio is sent inline as a base64 WAV data-URI. Set **Language** to `zh`, `en`, or
`auto` (auto enables language identification).

## Settings reference

- **Push-to-talk key** — Right Option / Right Command / Right Control / Fn.
- **Restore clipboard after pasting** — puts your previous clipboard back ~1s after paste.
- **Play start/stop sounds** — audible cue when recording begins/ends.

## Project layout

```
Sources/Murmur/
  main.swift          NSApplication bootstrap (accessory / menu-bar app)
  AppDelegate.swift   status item, dictation state machine
  HotkeyManager.swift global push-to-talk (flagsChanged monitor)
  AudioRecorder.swift AVAudioEngine capture → 16 kHz mono WAV
  Transcriber.swift   OpenAI-multipart + DashScope/Qwen3-ASR clients
  TextInjector.swift  clipboard + synthesised ⌘V paste
  Permissions.swift   mic / accessibility / input-monitoring helpers
  SettingsView.swift  SwiftUI settings form
  Defaults.swift      UserDefaults-backed config
Resources/            Info.plist + entitlements
build.sh              compile + bundle + ad-hoc sign
```

## Known limitations

- Streaming ASR (paraformer-realtime) is on by default so audio uploads while you speak;
  it falls back to the batch qwen3-asr-flash upload (transcribe-after-release) if the
  realtime connection fails or you turn it off in Settings → ASR. Note DashScope
  (`aliyuncs.com`) is a China endpoint — if you route through an overseas proxy, add a
  `DOMAIN-SUFFIX,aliyuncs.com,DIRECT` rule so requests don't detour abroad and stall.
- DashScope response parsing targets the documented `output.choices[].message.content`
  shape; if Alibaba changes it, adjust `extractDashScopeText` in `Transcriber.swift`.
- Ad-hoc signed for local use — not notarised for distribution.

## Privacy and contributing

See [PRIVACY.md](PRIVACY.md) for exactly when audio is captured, where it is sent,
and what is stored locally. Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md), and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) first.

Murmur is available under the [MIT License](LICENSE).
