# WillowVoice — research & what Murmur can learn from it

_Research date: 2026-07-11. Sources listed at the bottom._

## 1. What WillowVoice is

A polished, cross-platform (Mac / Windows / iOS) AI dictation product — same category as
Wispr Flow, Superwhisper, Typeless, and our **Murmur**. Hold a hotkey, speak, and
formatted text lands in whatever app is focused. Business context:

- **Funding / traction:** $4.5M seed (Y Combinator, Box Group, Burst Capital; angels incl.
  Dharmesh Shah, Alexis Ohanian, Max Mullen). ~50% MoM user growth. Enterprise logos: Uber,
  Heidi Health, Zego.
- **Pricing:** forever-free tier (2,000 words/week, no card), then ~$12/mo billed annually.
- **Positioning claims:** "4x faster writing", "5 hrs/week reclaimed", text in "as little as
  200ms", "3x more accurate than built-in dictation".

## 2. WillowVoice's actual feature set

| Feature | What it does |
|---|---|
| **Smart formatting** | Removes filler words, fixes punctuation, applies formatting (paragraphs, bullets) automatically — no verbal "comma"/"new line". |
| **Context-aware per-app style** | Detects the frontmost app and matches tone/format: formal for Gmail, casual for Slack/iMessage, code-aware in Cursor. *No manual mode-switching* (their explicit jab at Superwhisper). |
| **Willow Scribe / AI Mode** | Turns a rough spoken description into a fully-composed, polished message in the user's voice — not just cleanup, but drafting. |
| **Auto-learning dictionary** | Automatically remembers names, product terms, abbreviations over time (vs. a static user-typed list). |
| **Shortcuts / snippets** | Saved phrases inserted by voice command. |
| **Whisper Mode** | Robust to background noise, whispering, and rapid speech. |
| **iOS voice keyboard** | Full keyboard + voice, so you can **edit the transcript inline** (tap-fix a word) without switching keyboards or re-dictating. TechCrunch's Nov-2025 highlight. |
| **100+ languages** | Seamless mid-sentence switching. |
| **Privacy** | SOC 2 Type II, HIPAA, "zero data retention + end-to-end encryption", optional offline mode. |

**Tech under the hood (from their own posts):** ASR is treated as commodity; the moat is a
tuned **text-to-text pipeline built on Meta Llama models** for formatting + personalization,
plus latency engineering (~200ms vs Wispr's ~500ms) and low footprint (200–300MB RAM vs
Wispr's ~800MB).

## 3. The key insight for us

**Willow's differentiation is NOT the speech recognition — it's the text layer on top of it,
plus latency and polish.** Every "wow" feature (per-app tone, Scribe, auto-dictionary,
snippets, inline edit) is post-ASR intelligence + UX. The ASR is a swappable commodity.

That is *exactly* Murmur's architecture already: we treat ASR as a pluggable provider
(OpenAI-compatible / DashScope / local whisper.cpp) and do the value-add in `LLMRefiner`.
So we're structurally aligned — we've just under-invested in the text layer and UX relative
to Willow.

## 4. Murmur today vs. Willow — the gap

Murmur **already has**: push-to-talk + toggle, live waveform HUD, LLM polish (filler removal
+ punctuation, with anti-"answering" guardrails), custom vocabulary (biases ASR + fed to
polish), **streaming ASR** (`RealtimeTranscriber`, paraformer-realtime-v2, audio uploads
live), **connection prewarming** for both ASR and LLM, transcript history, clipboard restore.

| Willow capability | Murmur status | Gap size |
|---|---|---|
| Live streaming upload | ✅ have it (`RealtimeTranscriber`) | — |
| Latency prewarm | ✅ have it (`Transcriber.prewarm` / `LLMRefiner.prewarm`) | — |
| Filler/punctuation cleanup | ✅ have it (`LLMRefiner`) | — |
| **Context-aware per-app tone/format** | ❌ single static polish prompt | **High leverage** |
| **AI Mode / Scribe (rough → drafted)** | ❌ | High leverage |
| **Auto-learning dictionary** | ⚠️ static, user-typed only | Medium |
| **Snippets / voice shortcuts** | ❌ | Easy win |
| **Voice self-edit** ("scratch that", "change X to Y") | ❌ | Medium |
| Perceived ~200ms latency | ⚠️ streams audio but pastes only after release + a separate polish round-trip | Medium |
| Robustness (Whisper Mode) | partial (silence/VAD guards) | Provider-dependent |
| Notarized distribution + onboarding | ❌ ad-hoc signed, no onboarding | Medium |
| Privacy story | ⚠️ real but unstated | Easy win (reframe) |

## 5. Where Murmur can *beat* Willow (lean into these)

1. **No subscription, bring-your-own-key.** Willow is $144/yr. Murmur is free + user's own
   API spend (pennies).
2. **Privacy by architecture, not by policy.** Willow's "zero retention" is a promise on
   their servers. Murmur can point at a **local whisper.cpp / local LLM** and be 100% on-device
   — genuinely offline, nothing leaves the Mac. Willow *charges* for offline mode; we can give
   true-local for free. This is our strongest honest differentiator — but it's currently
   invisible. Make it a headline.
3. **Chinese-first.** We're already tuned for zh (DashScope/Qwen, zh filler words 嗯/那个,
   zh polish examples). Willow is English-centric. Chinese dictation quality is a real niche edge.

## 6. Proposed plan (prioritized)

Ordered by leverage ÷ effort. Each tier is independently shippable.

### Tier 1 — Context-aware per-app polish  ⟵ *biggest bang, do first*
Willow's #1 differentiator, and cheap for us because the LLM path already exists.
- Capture `NSWorkspace.shared.frontmostApplication.bundleIdentifier` at record start.
- Add a `ContextProfiles` config: bundle-ID → style directive, e.g.
  - Mail/Outlook/Spark → "formal, greeting+sign-off ok, full sentences, paragraphs"
  - Slack/iMessage/WeChat/Discord → "casual, concise, no greeting, emoji ok"
  - Cursor/VS Code/Terminal/Xcode → "code/technical, keep identifiers verbatim, minimal prose"
  - Notion/Obsidian/Docs → "structured, bullet points when listing"
  - default → current generic prompt.
- Inject the matched directive into `LLMRefiner`'s system prompt. ~1 new file + a few lines.
- Settings: a per-app rules table users can edit (mirror Willow's "writing styles").

### Tier 2 — AI Mode / "Scribe" (a second mode)
- A distinct trigger (second hotkey, or a modifier) flips polish from *clean-only* to
  *compose*: "rough spoken bullet points → a finished email/reply in my tone."
- Reuses the LLM call with a different system prompt and a relaxed length guardrail (the
  current `>2.2x+60` cap must be lifted for this mode, since composing legitimately expands).
- HUD shows "Composing…" instead of "Polishing…".

### Tier 3 — Snippets / voice shortcuts  ⟵ *easy win*
- A `[trigger phrase → expansion]` map applied post-transcription (e.g. "my address" →
  full address; "sig" → email signature). Pure string match, no model needed. Small Settings tab.

### Tier 4 — Perceived latency to "feels instant"
- We already upload audio live. Two moves to close the felt gap after key-release:
  - **Overlap polish with capture:** start polishing finalized sentences as they arrive from
    `RealtimeTranscriber` (it currently only collects `sentence_end` results and waits).
  - **Fast-path short utterances:** skip the polish round-trip (or make it non-blocking) for
    very short takes; paste raw immediately, optionally refine-in-place after.
  - Consider streaming the LLM response so paste can begin before the whole polish completes.

### Tier 5 — Auto-learning dictionary / personalization
- Mine transcript history for repeated out-of-vocabulary proper nouns; suggest (or auto-add)
  them to the vocabulary list. Optional few-shot from the user's own past transcripts to make
  polish match their voice (Willow's "style matching").

### Tier 6 — Voice self-edit
- Recognize trailing edit commands before paste: "scratch that" (drop last sentence),
  "new line/new paragraph", "all caps", "change X to Y", "send". Implement as a post-transcript
  command parser (can be rule-based first, LLM-assisted later).

### Tier 7 — Distribution & trust
- Notarize the app (README already flags it's only ad-hoc signed) so it's shareable.
- First-run onboarding wizard for the 3 permissions (mic / accessibility / input monitoring),
  replacing the current bare nudge.
- **Reframe privacy as a feature:** a "Local / Offline" preset (whisper.cpp + local LLM) with a
  visible "nothing leaves your Mac" badge. Turn our architectural edge into marketing.

## 7. Suggested sequencing

**Sprint 1 (highest ROI):** Tier 1 (per-app polish) + Tier 3 (snippets). Both small, both very
visible, both reuse existing plumbing.
**Sprint 2:** Tier 2 (AI Mode) + Tier 4 (latency overlap).
**Sprint 3:** Tier 5/6 (learning + voice edit), then Tier 7 (notarize + onboarding + local-privacy preset) when heading toward distribution.

---

### Sources
- https://willowvoice.com/ (features, latency, privacy claims)
- https://willowvoice.com/pricing
- https://willowvoice.com/blog/willow-vs-super-whisper-mac-dictation
- https://willowvoice.com/blog/wispr-flow-vs-willow-voice-dictation
- https://techcrunch.com/2025/11/12/willows-voice-keyboard-lets-you-type-across-all-your-ios-apps-and-actually-edit-what-you-said/ (iOS keyboard, funding, Llama-based text pipeline)
- https://www.getvoibe.com/resources/willow-voice-vs-wispr-flow/ (latency/RAM comparison)
- https://speechify.com/blog/wispr-flow-vs-willow-voice-for-voice-typing-and-dictation/
