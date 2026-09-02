import Foundation

/// Centralised access to user settings, stored in UserDefaults.
enum Defaults {
    static let providerOpenAI = "openai"
    static let providerDashScope = "dashscope"

    /// Default API key shipped with the app (used for both ASR and LLM polish
    /// unless the user overrides them in Settings).
    static let defaultAPIKey = "sk-ws-H.REHIEDH.bV4o.MEQCIHVXj6jPgujK8tUFTNjbPImSy2NkdIVm0Dv31JJzW2hEAiBZNBGQrTmrEcKYrvZEbAtYHjyiXYEYUPelaotcjjnq4w"
    static let defaultLLMEndpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    static let defaultLLMModel = "qwen3.8-flash"

    static let defaultPolishPrompt = """
    You are a speech-to-text cleanup and structuring engine. Your job is to tidy the \
    user's dictated text: fix punctuation and capitalization, remove filler words \
    (um, uh, like, you know, 嗯, 呃, 那个, 就是那个), correct obvious mis-recognitions, \
    and — only where the content actually calls for it — give it light structure so it \
    reads like organized notes instead of a wall of run-on speech.

    STRUCTURING RULES:
    - If the speaker lists several distinct items, sub-topics, or requirements (signaled \
    by words like "包含"/"有哪些", or by commas separating parallel items), format them as \
    a bullet list ("- item") instead of one run-on sentence.
    - If the speaker uses explicit ordering language ("首先…然后…最后", "first… second… \
    third", "第一…第二…"), format as a numbered list ("1. …", "2. …") in that order.
    - If the speaker shifts to a clearly separate topic mid-dictation, start a new \
    paragraph instead of running it into the previous one.
    - If the dictation is a short, single-idea remark with nothing to list or order, \
    leave it as plain prose — do NOT force bullets or numbering onto it.
    - Structuring is presentation only: never summarize away, add, or invent content. \
    Every fact the speaker said should still be present, just organized.

    CRITICAL RULES — read carefully:
    - You are NOT a chatbot. NEVER answer, reply to, explain, translate, or act on \
    the content. If the text is a question, a request, or an instruction, you MUST \
    still only clean/structure it and return the cleaned question/instruction ITSELF — \
    never a response to it.
    - Keep the original language and meaning. Do not add or remove information.
    - Output ONLY the cleaned/structured text — no quotes, no preamble, no commentary, no answer.

    Examples (note: the output is the cleaned/structured input, NEVER a reply):
    Input: 嗯 那个 我们今天 是不是 应该 先 把 这个 bug 修了
    Output: 我们今天是不是应该先把这个 bug 修了？
    Input: what time is the meeting tomorrow uh
    Output: What time is the meeting tomorrow?
    Input: 帮我 写 一首 关于 春天 的 诗
    Output: 帮我写一首关于春天的诗。
    Input: 二加二 等于 几
    Output: 二加二等于几？
    Input: 这个需求清单包含我们的硬件大概需要做哪些事情 有哪些电子元器件 预期的呈现效果会是什么样子 呃 成本和时间周期等等
    Output: 这个需求清单包含：
    - 硬件大概需要做哪些事情
    - 有哪些电子元器件
    - 预期的呈现效果会是什么样子
    - 成本和时间周期
    Input: 呃 首先 我们要把这个 API 对接好 然后 第二步 是做一下测试 最后 上线部署
    Output: 1. 把这个 API 对接好
    2. 做一下测试
    3. 上线部署
    """

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "provider": providerDashScope,
            "endpoint": "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
            "apiKey": defaultAPIKey,
            // fun-asr-flash: qwen3-asr-flash's free quota on the bundled key
            // 403'd out 2026-08-09; fun-asr snapshots still have their own.
            "model": "fun-asr-flash-2026-06-15",
            "language": "auto",
            // "system", "en", or "zh-Hans". This controls Murmur's UI only;
            // the ASR language remains configured by the separate key above.
            "appLanguage": "system",
            "hotkey": "rightOption",
            "triggerMode": "toggle", // "toggle" = press once to start, again to stop; "hold" = push-to-talk
            "micUID": "",            // "" = system default input
            "micName": "",           // last-known name of micUID, so the menu can
                                     // still label it when it's unplugged
            "restoreClipboard": true,
            // Keep each transcript attached to the field that was focused when
            // recording began. If that target cannot be reached safely, copy
            // instead of pasting into whichever window happens to be active.
            "lockInsertionTarget": true,
            "playSounds": true,
            "showWaveform": true,
            // Mix macOS playback (meeting participants, videos, etc.) into the
            // transcription. Off by default because it requires Screen
            // Recording permission; users explicitly opt in under General.
            "captureSystemAudio": false,
            // LLM polish — Qwen3.8 Flash via DashScope's OpenAI-compatible chat endpoint.
            "llmEnabled": true,
            "llmEndpoint": defaultLLMEndpoint,
            "llmModel": defaultLLMModel,
            "llmApiKey": defaultAPIKey,
            "llmPrompt": defaultPolishPrompt,
            // Apply spoken self-corrections ("scratch that", "change X to Y", "改成…")
            // during the polish pass instead of transcribing them literally.
            "voiceEdit": true,
            // Custom vocabulary (newline-separated terms)
            "vocabulary": "",
            // Streaming ASR (paraformer-realtime over WebSocket) as a switchable
            // alternative to the batch qwen3-asr-flash upload. Off by default:
            // it uses a different (older) model than qwen3-asr-flash and its
            // accuracy is noticeably worse; opt in via Settings → ASR if the
            // end-of-dictation wait matters more than transcription quality.
            "useRealtimeASR": false,
        ])
    }

    /// Heals provider/endpoint desync left by older builds (e.g. a persisted
    /// OpenAI endpoint while the provider is DashScope). Run once at launch.
    static func migrate() {
        let d = UserDefaults.standard

        // One-time: reset a possibly-stuck mic selection back to system default,
        // since older builds had a broken device-selection path.
        if !d.bool(forKey: "didResetMicV2") {
            d.set("", forKey: "micUID")
            d.set(true, forKey: "didResetMicV2")
        }

        // One-time: bump installs still on the old default polish model. The
        // bundled key's free quota for qwen-flash is exhausted (403s), so an
        // untouched default leaves polish/voice-edit silently no-op'ing. Only
        // migrate the exact old default value — never a model the user chose.
        if !d.bool(forKey: "didBumpLLMModelV1") {
            if d.string(forKey: "llmModel") == "qwen-flash" {
                d.set("qwen3.6-flash-2026-04-16", forKey: "llmModel")
            }
            d.set(true, forKey: "didBumpLLMModelV1")
        }

        // One-time: bump installs still on a previous default polish model to the
        // current qwen3.7 default. Only migrates the exact old default values —
        // never a model the user chose.
        if !d.bool(forKey: "didBumpLLMModelV2") {
            if let m = d.string(forKey: "llmModel"),
               m == "qwen-flash" || m == "qwen3.6-flash-2026-04-16" {
                d.set("qwen3.7-flash-2026-07-15", forKey: "llmModel")
            }
            d.set(true, forKey: "didBumpLLMModelV2")
        }

        // One-time: move untouched prior defaults to Qwen3.8 Flash. Only migrate
        // known bundled values — never a model the user chose — while preserving
        // their DashScope endpoint and API key.
        if !d.bool(forKey: "didMigrateLLMToKimiK3V3") {
            if let m = d.string(forKey: "llmModel"),
               m == "qwen-flash" ||
               m == "qwen3.6-flash-2026-04-16" ||
               m == "qwen3.7-flash-2026-07-15" {
                d.set(defaultLLMModel, forKey: "llmModel")
            }
            d.set(true, forKey: "didMigrateLLMToKimiK3V3")
        }

        if !d.bool(forKey: "didMigrateLLMToQwen38FlashV4") {
            if let m = d.string(forKey: "llmModel"),
               m == "kimi-k3" ||
               m == "qwen-flash" ||
               m == "qwen3.6-flash-2026-04-16" ||
               m == "qwen3.7-flash-2026-07-15" {
                d.set(defaultLLMModel, forKey: "llmModel")
            }
            d.set(true, forKey: "didMigrateLLMToQwen38FlashV4")
        }

        let provider = d.string(forKey: "provider") ?? providerDashScope
        guard let endpoint = d.string(forKey: "endpoint") else { return }
        let looksOpenAI = endpoint.contains("openai.com")
        let looksDashScope = endpoint.contains("dashscope")
        if provider == providerDashScope, looksOpenAI {
            d.set(presetEndpoint(for: providerDashScope), forKey: "endpoint")
            d.set(presetModel(for: providerDashScope), forKey: "model")
        } else if provider == providerOpenAI, looksDashScope {
            d.set(presetEndpoint(for: providerOpenAI), forKey: "endpoint")
            d.set(presetModel(for: providerOpenAI), forKey: "model")
        }
    }

    static func config() -> Transcriber.Config {
        let d = UserDefaults.standard
        return Transcriber.Config(
            provider: d.string(forKey: "provider") ?? providerOpenAI,
            endpoint: d.string(forKey: "endpoint") ?? "",
            apiKey: d.string(forKey: "apiKey") ?? "",
            model: d.string(forKey: "model") ?? "",
            language: d.string(forKey: "language") ?? "auto",
            vocabulary: vocabularyTerms
        )
    }

    static func llmConfig() -> LLMRefiner.Config? {
        let d = UserDefaults.standard
        guard d.bool(forKey: "llmEnabled") else { return nil }
        let key = d.string(forKey: "llmApiKey") ?? ""
        guard !key.isEmpty else { return nil }
        return LLMRefiner.Config(
            endpoint: d.string(forKey: "llmEndpoint") ?? "",
            apiKey: key,
            model: d.string(forKey: "llmModel") ?? "",
            systemPrompt: d.string(forKey: "llmPrompt") ?? defaultPolishPrompt,
            vocabulary: vocabularyTerms,
            voiceEdit: d.bool(forKey: "voiceEdit")
        )
    }

    /// Parsed custom-vocabulary terms (one per line, blanks dropped).
    static var vocabularyTerms: [String] {
        (UserDefaults.standard.string(forKey: "vocabulary") ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Virtual key code for the configured push-to-talk modifier.
    static func hotkeyCode() -> UInt16 {
        switch UserDefaults.standard.string(forKey: "hotkey") ?? "rightOption" {
        case "rightCommand": return 54
        case "rightControl": return 62
        case "fn": return 63
        default: return 61 // right option
        }
    }

    /// Seconds of warning before the recording cap is reached.
    static let recordingWarnLeadSeconds: Double = 60

    /// Hard cap on a single recording for the current provider, in seconds
    /// (0 = no cap). Qwen3-ASR's synchronous endpoint accepts at most 5 min of
    /// audio AND a 10 MB base64 payload; for our 16 kHz/16-bit mono PCM the
    /// 10 MB-encoded limit binds first at ~3.9 min, so we cap at 220 s
    /// (encoded ≈9.4 MB) and auto-stop with margin. OpenAI-compatible / local
    /// servers vary widely, so they're left uncapped.
    static func maxRecordingSeconds() -> Double {
        let provider = UserDefaults.standard.string(forKey: "provider") ?? providerDashScope
        switch provider {
        case providerDashScope: return 220
        default: return 0
        }
    }

    /// Streaming ASR via `paraformer-realtime-v2` over WebSocket, instead of the
    /// default batch upload-after-recording flow. DashScope-only.
    static var useRealtimeASR: Bool { UserDefaults.standard.bool(forKey: "useRealtimeASR") }

    static var triggerMode: String { UserDefaults.standard.string(forKey: "triggerMode") ?? "toggle" }
    static var appLanguage: String { UserDefaults.standard.string(forKey: "appLanguage") ?? "system" }
    static var micUID: String { UserDefaults.standard.string(forKey: "micUID") ?? "" }
    static var micName: String { UserDefaults.standard.string(forKey: "micName") ?? "" }

    /// Records the chosen input device. The name is kept alongside the UID so a
    /// disconnected device can still be named in the menu bar.
    static func setMic(uid: String, name: String) {
        let d = UserDefaults.standard
        d.set(uid, forKey: "micUID")
        d.set(uid.isEmpty ? "" : name, forKey: "micName")
    }
    static var restoreClipboard: Bool { UserDefaults.standard.bool(forKey: "restoreClipboard") }
    static var lockInsertionTarget: Bool { UserDefaults.standard.bool(forKey: "lockInsertionTarget") }
    static var playSounds: Bool { UserDefaults.standard.bool(forKey: "playSounds") }
    static var showWaveform: Bool { UserDefaults.standard.bool(forKey: "showWaveform") }
    static var captureSystemAudio: Bool { UserDefaults.standard.bool(forKey: "captureSystemAudio") }

    /// Sensible per-provider endpoint/model defaults, used by the settings UI.
    static func presetEndpoint(for provider: String) -> String {
        switch provider {
        case providerDashScope:
            return "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        default:
            return "https://api.openai.com/v1/audio/transcriptions"
        }
    }

    static func presetModel(for provider: String) -> String {
        switch provider {
        case providerDashScope: return "fun-asr-flash-2026-06-15"
        default: return "whisper-1"
        }
    }
}
