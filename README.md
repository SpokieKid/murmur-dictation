# Murmur 🎙️

A tiny macOS menu-bar dictation app in the spirit of **Wispr Flow** and **Typeless** —
but you bring your **own ASR API**. Hold a key, speak, release, and your words are
transcribed and pasted at the cursor in whatever app is focused.

No subscription, no vendor lock-in. Point it at OpenAI Whisper, Groq, a local
`whisper.cpp` server, or Alibaba's **Qwen3-ASR (`qwen3-asr-flash`)**.

**Ships working out of the box** — pre-configured for DashScope `qwen3-asr-flash`
(ASR) + `qwen3.8-flash` (LLM polish) with a bundled API key. Just grant permissions
and start talking.

## Features

- 🎙️ **Push-to-talk dictation** — hold a key, speak, release; text appears at the cursor.
- 🌊 **Live waveform** — a floating pill near the bottom of the screen reacts to your
  voice while recording, then shows "Transcribing…" / "Polishing…".
- ⎋ **Esc to cancel** — press Esc while recording (or while it's still transcribing /
  polishing) to throw the take away: no ASR call, nothing pasted. Esc is swallowed
  *only* for the duration of a dictation, so it keeps working normally everywhere else.
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

1. **Hold** the push-to-talk key (default: **Right ⌥ Option**) and speak — a waveform
   pill appears and reacts to your voice.
2. **Release** — Murmur captures 16 kHz mono audio, sends it to your ASR endpoint,
   optionally polishes the transcript with an LLM, and pastes it at the cursor (⌘V).

It lives in the menu bar (🎙️). No Dock icon, no window unless you open Settings.

## Build & run

```bash
./build.sh            # compiles + assembles build/Murmur.app (ad-hoc signed)
open build/Murmur.app
```

Requires Xcode / Swift 6 toolchain (tested on Swift 6.3, macOS 26).

## First-run permissions

macOS gates everything Murmur needs behind privacy permissions. Use **menu →
"Grant Permissions…"**, then enable Murmur under each in System Settings:

| Permission         | Why                                          |
|--------------------|----------------------------------------------|
| **Microphone**     | record your voice                            |
| **Accessibility**  | synthesise ⌘V to paste at the cursor         |
| **Input Monitoring** | detect the push-to-talk key in other apps  |

After granting, quit and relaunch Murmur once so the permissions take effect.

> Tip: while testing permissions, you can also trigger recording from
> **menu → "Start / Stop Dictation"** without the global hotkey.

## Settings tabs

Open **menu → Settings…** — four tabs:

- **ASR** — speech-to-text provider, endpoint, key, model, language.
- **Polish** — toggle LLM cleanup, its endpoint/key/model, the instruction prompt, and
  **voice self-edit** (apply spoken corrections like "scratch that" / "change X to Y").
- **Vocabulary** — one term per line; biases ASR and is passed to the polish step.
- **General** — microphone device, trigger mode + key, waveform toggle, clipboard, sounds.

### Trigger modes

- **Press once to start, again to stop** (default) — tap the trigger key to begin
  dictation, tap again to finish. Hands-free.
- **Hold to talk** — classic push-to-talk; record only while the key is held.

> In toggle mode, prefer a trigger key you don't use for typing (Right ⌃ Control or
> Fn) — Right ⌥ Option doubles as the accent/special-character modifier.

### Microphone

Pick any CoreAudio input device under **General → Microphone**, or leave it on
"System default". The choice is remembered by device UID across replug/reboot.

The bundled defaults (DashScope qwen3-asr-flash + qwen3.8-flash) are filled in already;
override any of them per the formats below.

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
