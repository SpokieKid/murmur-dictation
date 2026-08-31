import SwiftUI

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("MurmurHotkeyChanged")
}

struct SettingsView: View {
    @AppStorage("provider") private var provider = Defaults.providerOpenAI
    @AppStorage("endpoint") private var endpoint = ""
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ""
    @AppStorage("language") private var language = "auto"
    @AppStorage("hotkey") private var hotkey = "rightOption"
    @AppStorage("triggerMode") private var triggerMode = "toggle"
    @AppStorage("micUID") private var micUID = ""
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("showWaveform") private var showWaveform = true

    @AppStorage("llmEnabled") private var llmEnabled = true
    @AppStorage("llmEndpoint") private var llmEndpoint = ""
    @AppStorage("llmApiKey") private var llmApiKey = ""
    @AppStorage("llmModel") private var llmModel = ""
    @AppStorage("llmPrompt") private var llmPrompt = ""
    @AppStorage("voiceEdit") private var voiceEdit = true

    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("useRealtimeASR") private var useRealtimeASR = true

    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        TabView {
            asrTab.tabItem { Label("ASR", systemImage: "waveform") }
            polishTab.tabItem { Label("Polish", systemImage: "wand.and.stars") }
            vocabTab.tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 500, height: 540)
        .padding()
        .onAppear { devices = AudioDevices.inputDevices() }
    }

    // MARK: - ASR

    private var asrTab: some View {
        Form {
            Section("Speech-to-text provider") {
                Picker("Format", selection: $provider) {
                    Text("阿里百炼 · FunASR (fun-asr-flash)").tag(Defaults.providerDashScope)
                    Text("OpenAI 兼容 (Whisper / Groq / 本地)").tag(Defaults.providerOpenAI)
                }
                .onChange(of: provider) { newValue in
                    endpoint = Defaults.presetEndpoint(for: newValue)
                    model = Defaults.presetModel(for: newValue)
                }
                TextField("Endpoint URL", text: $endpoint)
                SecureField("API Key", text: $apiKey)
                TextField("Model", text: $model)
                TextField("Language (ISO code or 'auto')", text: $language)
            }
            Section {
                Text("百炼 qwen3-asr-flash 只在原生 multimodal-generation 端点可用；compatible-mode 不支持语音转录（会返回 404），别填成兼容模式地址。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == Defaults.providerDashScope {
                Section("Streaming (beta)") {
                    Toggle("Use realtime streaming ASR (paraformer-realtime)", isOn: $useRealtimeASR)
                    Text("Uploads audio over a WebSocket as you speak instead of after you release the key — usually faster, but this is a different model from qwen3-asr-flash so accuracy may differ. Falls back to the batch upload above if the realtime connection fails.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - LLM polish

    private var polishTab: some View {
        Form {
            Section("LLM polish") {
                Toggle("Clean up transcript with an LLM", isOn: $llmEnabled)
                Text("After transcription, a small/fast model fixes punctuation, removes filler words, and applies your vocabulary.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Apply spoken corrections (voice self-edit)", isOn: $voiceEdit)
                    .disabled(!llmEnabled)
                Text("Say a correction out loud and it's applied instead of typed — e.g. “…scratch that…”, “change Sam to Alex”, “把张三改成李四”. A “change X to Y” that's part of a message you're dictating for someone else is kept as-is.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Model") {
                TextField("Chat endpoint URL", text: $llmEndpoint)
                SecureField("API Key", text: $llmApiKey)
                TextField("Model", text: $llmModel)
                Text("默认使用百炼的 qwen3.8-flash；兼容模式 base：https://dashscope.aliyuncs.com/compatible-mode/v1 （末尾接 /chat/completions）。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!llmEnabled)
            Section("Instruction") {
                TextEditor(text: $llmPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
            }
            .disabled(!llmEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - Vocabulary

    private var vocabTab: some View {
        Form {
            Section("Custom vocabulary") {
                Text("One term per line. These bias the ASR toward correct spellings (names, jargon, brands) and are passed to the polish step.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $vocabulary)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 280)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: $micUID) {
                    Text("System default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                // Keep the remembered name in step with the UID so the menu-bar
                // picker can still label the device once it's unplugged.
                .onChange(of: micUID) { uid in
                    let name = devices.first(where: { $0.uid == uid })?.name ?? ""
                    Defaults.setMic(uid: uid, name: name)
                }
                Button("Refresh devices") { devices = AudioDevices.inputDevices() }
                Text("也可以直接从菜单栏图标 → Microphone 里切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dictation") {
                Picker("Trigger", selection: $triggerMode) {
                    Text("Press once to start, again to stop").tag("toggle")
                    Text("Hold to talk (push-to-talk)").tag("hold")
                }
                Picker("Trigger key", selection: $hotkey) {
                    Text("Right ⌥ Option").tag("rightOption")
                    Text("Right ⌘ Command").tag("rightCommand")
                    Text("Right ⌃ Control").tag("rightControl")
                    Text("Fn").tag("fn")
                }
                .onChange(of: hotkey) { _ in
                    NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                }
            }
            Section("Feedback") {
                Toggle("Show waveform while recording", isOn: $showWaveform)
                Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
                Toggle("Play start/stop sounds", isOn: $playSounds)
            }
            Section {
                Text("Hold the push-to-talk key, speak, then release. Needs Microphone, Accessibility and Input Monitoring permissions — use “Grant Permissions…” in the menu.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
