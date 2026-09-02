import SwiftUI
import AppKit

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
    @AppStorage("lockInsertionTarget") private var lockInsertionTarget = true
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("showWaveform") private var showWaveform = true
    @AppStorage("captureSystemAudio") private var captureSystemAudio = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    @AppStorage("llmEnabled") private var llmEnabled = true
    @AppStorage("llmEndpoint") private var llmEndpoint = ""
    @AppStorage("llmApiKey") private var llmApiKey = ""
    @AppStorage("llmModel") private var llmModel = ""
    @AppStorage("llmPrompt") private var llmPrompt = ""
    @AppStorage("voiceEdit") private var voiceEdit = true

    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("useRealtimeASR") private var useRealtimeASR = true

    @State private var devices: [AudioInputDevice] = []
    @State private var screenCaptureGranted = false

    var body: some View {
        TabView {
            asrTab.tabItem { Label(L10n.tr("tab.asr"), systemImage: "waveform") }
            polishTab.tabItem { Label(L10n.tr("tab.polish"), systemImage: "wand.and.stars") }
            vocabTab.tabItem { Label(L10n.tr("tab.vocabulary"), systemImage: "text.book.closed") }
            generalTab.tabItem { Label(L10n.tr("tab.general"), systemImage: "gearshape") }
        }
        .id(appLanguage)
        .frame(width: 520, height: 600)
        .padding()
        .onAppear {
            devices = AudioDevices.inputDevices()
            screenCaptureGranted = Permissions.hasScreenCaptureAccess
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenCaptureGranted = Permissions.hasScreenCaptureAccess
        }
    }

    // MARK: - ASR

    private var asrTab: some View {
        Form {
            Section(L10n.tr("settings.asr_provider")) {
                Picker(L10n.tr("settings.format"), selection: $provider) {
                    Text(L10n.tr("settings.dashscope_provider")).tag(Defaults.providerDashScope)
                    Text(L10n.tr("settings.openai_provider")).tag(Defaults.providerOpenAI)
                }
                .onChange(of: provider) { newValue in
                    endpoint = Defaults.presetEndpoint(for: newValue)
                    model = Defaults.presetModel(for: newValue)
                }
                TextField(L10n.tr("settings.endpoint"), text: $endpoint)
                SecureField(L10n.tr("settings.api_key"), text: $apiKey)
                TextField(L10n.tr("settings.model"), text: $model)
                TextField(L10n.tr("settings.asr_language"), text: $language)
            }
            Section {
                Text(L10n.tr("settings.dashscope_endpoint_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider == Defaults.providerDashScope {
                Section(L10n.tr("settings.streaming")) {
                    Toggle(L10n.tr("settings.streaming_toggle"), isOn: $useRealtimeASR)
                    Text(L10n.tr("settings.streaming_hint"))
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
            Section(L10n.tr("settings.llm_polish")) {
                Toggle(L10n.tr("settings.llm_polish_toggle"), isOn: $llmEnabled)
                Text(L10n.tr("settings.llm_polish_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.tr("settings.voice_edit_toggle"), isOn: $voiceEdit)
                    .disabled(!llmEnabled)
                Text(L10n.tr("settings.voice_edit_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("settings.model")) {
                TextField(L10n.tr("settings.endpoint"), text: $llmEndpoint)
                SecureField(L10n.tr("settings.api_key"), text: $llmApiKey)
                TextField(L10n.tr("settings.model"), text: $llmModel)
                Text(L10n.tr("settings.llm_model_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!llmEnabled)
            Section(L10n.tr("settings.instruction")) {
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
            Section(L10n.tr("settings.custom_vocabulary")) {
                Text(L10n.tr("settings.vocabulary_hint"))
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
            Section(L10n.tr("settings.language_section")) {
                Picker(L10n.tr("settings.app_language"), selection: $appLanguage) {
                    Text(L10n.tr("settings.language_system")).tag(AppLanguage.system.rawValue)
                    Text(L10n.tr("settings.language_chinese")).tag(AppLanguage.simplifiedChinese.rawValue)
                    Text(L10n.tr("settings.language_english")).tag(AppLanguage.english.rawValue)
                }
                .onChange(of: appLanguage) { _ in
                    NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
                }
                Text(L10n.tr("settings.language_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.tr("settings.microphone")) {
                Picker(L10n.tr("settings.input_device"), selection: $micUID) {
                    Text(L10n.tr("menu.system_default")).tag("")
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
                Button(L10n.tr("settings.refresh_devices")) { devices = AudioDevices.inputDevices() }
                Text(L10n.tr("settings.microphone_menu_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.tr("settings.meeting_audio")) {
                Toggle(L10n.tr("settings.include_computer_audio"), isOn: $captureSystemAudio)
                    .onChange(of: captureSystemAudio) { enabled in
                        guard enabled else { return }
                        screenCaptureGranted = Permissions.requestScreenCapture()
                    }
                HStack {
                    Text(L10n.tr(screenCaptureGranted
                        ? "settings.screen_audio_authorized"
                        : "settings.screen_audio_required"))
                        .font(.caption)
                        .foregroundStyle(screenCaptureGranted ? .green : .secondary)
                    Spacer()
                    Button(L10n.tr("settings.open_system_settings")) {
                        Permissions.openScreenCaptureSettings()
                    }
                }
                Text(L10n.tr("settings.computer_audio_hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.tr("settings.dictation")) {
                Picker(L10n.tr("settings.trigger"), selection: $triggerMode) {
                    Text(L10n.tr("settings.trigger_toggle")).tag("toggle")
                    Text(L10n.tr("settings.trigger_hold")).tag("hold")
                }
                Picker(L10n.tr("settings.trigger_key"), selection: $hotkey) {
                    Text("Right ⌥ Option").tag("rightOption")
                    Text("Right ⌘ Command").tag("rightCommand")
                    Text("Right ⌃ Control").tag("rightControl")
                    Text("Fn").tag("fn")
                }
                .onChange(of: hotkey) { _ in
                    NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                }
            }
            Section(L10n.tr("settings.feedback")) {
                Toggle(L10n.tr("settings.show_waveform"), isOn: $showWaveform)
                Toggle(L10n.tr("settings.lock_input_target"), isOn: $lockInsertionTarget)
                Toggle(L10n.tr("settings.restore_clipboard"), isOn: $restoreClipboard)
                Toggle(L10n.tr("settings.play_sounds"), isOn: $playSounds)
                Text(L10n.tr("settings.lock_input_target_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text(L10n.tr("settings.parallel_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
