import Cocoa
import SwiftUI
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyManager()
    private let escape = EscapeMonitor()
    private let hud = WaveformHUD()
    private let historyMenu = NSMenu()
    private let micMenu = NSMenu()
    private let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Accessibility: …", action: nil, keyEquivalent: "")
    private var settingsWindow: NSWindow?
    private var warnedNoAccessibility = false

    private enum State { case idle, recording, working }
    private var state: State = .idle
    private var minDuration = 0.4
    private var playedLimitWarning = false

    /// Bumped whenever a dictation's processing starts or ends. A background
    /// transcription Task captures the value at launch and only delivers if it's
    /// still current, so a result arriving after a stall-watchdog reset (or a
    /// newer dictation) is discarded instead of pasting late.
    private var workID = 0
    /// Stage timing for diagnosing perceived latency. Read with:
    /// `log show --predicate 'subsystem == "com.murmur.dictation"' --style compact --last 10m`
    private let perfLog = Logger(subsystem: "com.murmur.dictation", category: "timing")
    /// The in-flight transcribe/polish work, held so Escape can cancel it.
    private var workTask: Task<Void, Never>?
    /// Fires if a dictation stays in `.working` far longer than the network
    /// timeouts allow, so the app can never be left permanently frozen needing a
    /// restart — the historical failure mode after the app sat idle.
    private var stallWatchdog: DispatchWorkItem?

    /// Set only when streaming ASR successfully connects for the current
    /// recording; nil means "use the batch WAV path", which also covers the
    /// realtime connection failing to start.
    private var realtimeTranscriber: RealtimeTranscriber?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.registerDefaults()
        Defaults.migrate()
        setupStatusItem()

        hotkey.keyCode = Defaults.hotkeyCode()
        hotkey.onPress = { [weak self] in
            guard let self = self else { return }
            if Defaults.triggerMode == "hold" {
                self.beginDictation()
            } else {
                self.toggleDictation() // press once to start, again to stop
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self = self else { return }
            if Defaults.triggerMode == "hold" { self.endDictation() }
        }
        hotkey.start()
        escape.onEscape = { [weak self] in self?.cancelDictation() }

        NotificationCenter.default.addObserver(self, selector: #selector(hotkeyChanged),
                                               name: .hotkeyChanged, object: nil)

        Permissions.requestMicrophone()
        if !Permissions.isAccessibilityTrusted() {
            // First launch: nudge the user toward granting permissions.
            openSettings(nil)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render(.idle)
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        historyMenu.delegate = self
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        // Mic picker lives in the menu bar (not just Settings) so switching
        // headsets is one click. Devices are re-enumerated each time it opens.
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)
        menu.addItem(.separator())
        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        menu.addItem(withTitle: "Grant Permissions…", action: #selector(grantPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? nil : self
        }
        statusItem.menu = menu
    }

    private func render(_ state: State) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .working: symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = (state != .recording)
        button.image = image
        button.contentTintColor = state == .recording ? .systemRed : nil
    }

    // MARK: - Dictation flow

    @objc private func toggleDictation() {
        if state == .recording { endDictation() } else { beginDictation() }
    }

    private func beginDictation() {
        guard state == .idle else { return }
        Permissions.requestMicrophone { [weak self] granted in
            guard let self = self else { return }
            guard granted else { self.notify("Microphone access denied"); return }
            do {
                self.recorder.deviceUID = Defaults.micUID
                self.recorder.onLevel = { [weak self] level in self?.hud.update(level: level) }
                self.playedLimitWarning = false
                self.recorder.maxDuration = Defaults.maxRecordingSeconds()
                self.recorder.warnLeadSeconds = Defaults.recordingWarnLeadSeconds
                self.recorder.onApproachingLimit = { [weak self] remaining in
                    self?.handleApproachingLimit(remaining)
                }
                self.recorder.onLimitReached = { [weak self] in self?.handleRecordingLimitReached() }
                try self.recorder.start()
                self.state = .recording
                self.render(.recording)
                // Escape aborts the take; live only for the duration of a dictation
                // so the key keeps working normally everywhere else.
                self.escape.start()
                if Defaults.showWaveform { self.hud.show(status: "Listening… ⎋ 取消") }
                if Defaults.playSounds { NSSound(named: "Tink")?.play() }
                // Warm the ASR/LLM connections while the user is still
                // speaking, so the TCP/TLS handshake doesn't land on the
                // critical path after they release the hotkey.
                let asrConfig = Defaults.config()
                Transcriber.prewarm(config: asrConfig)
                if let llmConfig = Defaults.llmConfig() { LLMRefiner.prewarm(config: llmConfig) }

                if Defaults.useRealtimeASR {
                    self.startRealtimeASR(config: asrConfig)
                }
            } catch {
                self.notify("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    /// Best-effort: wires the recorder to a realtime transcriber immediately —
    /// before the WebSocket has even connected — so audio captured the instant
    /// the HUD appears isn't lost while the connection is still handshaking.
    /// `RealtimeTranscriber` buffers internally until it's actually ready. If
    /// the connection never comes up, `finish()` reports that and
    /// `endDictation` falls back to the batch WAV path that was recording anyway.
    private func startRealtimeASR(config: Transcriber.Config) {
        let rt = RealtimeTranscriber()
        realtimeTranscriber = rt
        recorder.onPCMChunk = { [weak rt] chunk in rt?.append(chunk) }
        Task {
            let vocabId = await VocabularyManager.vocabularyId(for: Defaults.vocabularyTerms, apiKey: config.apiKey)
            rt.beginConnecting(config: .init(apiKey: config.apiKey, language: config.language, vocabularyId: vocabId))
        }
    }

    private func endDictation() {
        guard state == .recording else { return }
        recorder.onLevel = nil
        recorder.onApproachingLimit = nil
        recorder.onLimitReached = nil
        recorder.onPCMChunk = nil
        let wav = recorder.stop()
        let seconds = recorder.duration
        let buffers = recorder.bufferCount
        let peak = recorder.peakLevel
        // Deliberately left set: Escape must still be able to tear the socket
        // down mid-transcription. `finishWorking` clears it on every exit path.
        let realtime = realtimeTranscriber
        state = .working
        render(.working)
        if Defaults.playSounds { NSSound(named: "Pop")?.play() }

        // Empty / silent / too-short capture → quietly cancel with a brief HUD
        // hint. No modal alert, and don't waste an ASR call on silence.
        if buffers == 0 {
            finishWorking(flash: "未检测到麦克风输入")
            return
        }
        if seconds < minDuration || peak < 0.006 {
            finishWorking(flash: "未检测到语音")
            return
        }

        hud.setProcessing("Transcribing…")
        let config = Defaults.config()
        let llmConfig = Defaults.llmConfig()
        workID &+= 1
        let currentWork = workID
        scheduleStallWatchdog(for: currentWork)
        workTask = Task { [self] in
            let t0 = Date()
            let result: Result<String, Error>
            do {
                var text: String
                let path: String
                if let realtime, let realtimeText = await realtime.finish() {
                    text = realtimeText
                    path = "stream"
                } else {
                    text = try await Transcriber.transcribe(wav: wav, config: config)
                    path = realtime == nil ? "batch" : "batch(stream-fell-back)"
                }
                let tAsr = Date()
                perfLog.notice("asr path=\(path, privacy: .public) dt=\(tAsr.timeIntervalSince(t0), format: .fixed(precision: 2))s chars=\(text.count)")
                if let llmConfig = llmConfig, !text.isEmpty {
                    let isLongDictation = seconds >= 60 || text.count >= 600
                    await MainActor.run {
                        self.hud.setProcessing(
                            isLongDictation ? "Polishing long dictation…" : "Polishing…"
                        )
                    }
                    if let polished = await LLMRefiner.refine(
                        text,
                        config: llmConfig,
                        recordingDuration: seconds
                    ) {
                        text = polished
                    }
                    perfLog.notice("polish dt=\(Date().timeIntervalSince(tAsr), format: .fixed(precision: 2))s")
                }
                perfLog.notice("pipeline total dt=\(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                // Discard if a stall-watchdog reset or a newer dictation already
                // superseded this one (otherwise a late result would paste itself).
                guard self.workID == currentWork else { return }
                switch result {
                case .success(let text):
                    self.deliver(text)
                case .failure(let error):
                    self.notify(error.localizedDescription)
                    self.finishWorking()
                }
            }
        }
    }

    /// Escape pressed mid-dictation: throw this take away.
    ///
    /// While recording we stop capture and never call the ASR at all. While
    /// transcribing/polishing we cancel the in-flight request — and even if it
    /// has already completed, the `workID` guard stops its result from being
    /// pasted after the fact.
    private func cancelDictation() {
        switch state {
        case .idle:
            return
        case .recording:
            recorder.onLevel = nil
            recorder.onApproachingLimit = nil
            recorder.onLimitReached = nil
            recorder.onPCMChunk = nil
            _ = recorder.stop() // audio is dropped on the floor; no ASR call at all
            if Defaults.playSounds { NSSound(named: "Bottle")?.play() }
            finishWorking(flash: "✗ 已取消")
        case .working:
            workTask?.cancel()
            if Defaults.playSounds { NSSound(named: "Bottle")?.play() }
            finishWorking(flash: "✗ 已取消")
        }
    }

    /// The recording is nearing the provider's per-request audio limit. Show a
    /// live countdown on the HUD (and a one-time chime) so the user can wrap up
    /// before capture auto-stops.
    private func handleApproachingLimit(_ remaining: Int) {
        guard state == .recording else { return }
        if Defaults.showWaveform {
            hud.warn("⚠️ \(remaining) 秒后自动停止录音")
        }
        if !playedLimitWarning {
            playedLimitWarning = true
            if Defaults.playSounds { NSSound(named: "Funk")?.play() }
        }
    }

    /// The cap was hit — stop capture and transcribe what we have, rather than
    /// letting an over-length take fail the ASR request.
    private func handleRecordingLimitReached() {
        guard state == .recording else { return }
        endDictation()
    }

    /// Saves the transcript to history, pastes it (or falls back to clipboard),
    /// and flashes a confirmation on the HUD.
    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finishWorking()
            return
        }
        TranscriptHistory.add(trimmed)
        let pasted = TextInjector.insert(trimmed)
        finishWorking(flash: pasted ? "✓ 已粘贴" : "✓ 已复制 · ⌘V")

        if !pasted, !warnedNoAccessibility {
            warnedNoAccessibility = true
            notify("结果已复制到剪贴板，按 ⌘V 即可粘贴。\n\n要让 Murmur 自动粘贴到光标处，请在 系统设置 → 隐私与安全性 → 辅助功能 里勾选 Murmur（菜单「Grant Permissions…」可直达），然后重启 App。\n\n所有转录都能在菜单「Recent Transcripts」里查看。")
        }
    }

    private func finishWorking(flash: String? = nil) {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        workTask = nil
        // Close the streaming socket on every exit path — normal finish already
        // closed it, but a cancelled/aborted take would otherwise leave it open.
        realtimeTranscriber?.cancel()
        realtimeTranscriber = nil
        escape.stop()  // Escape goes back to being the app's own key
        workID &+= 1  // invalidate any in-flight processing so a late result is ignored
        state = .idle
        render(.idle)
        if let flash = flash { hud.finish(flash) } else { hud.hide() }
    }

    /// Arms a fallback that force-recovers this dictation if it never completes.
    /// The per-request network timeouts should always make the Task finish first;
    /// this only trips on a true hang so the UI can't get wedged in `.working`.
    private func scheduleStallWatchdog(for work: Int) {
        stallWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.recoverFromStall(work) }
        stallWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func recoverFromStall(_ work: Int) {
        guard state == .working, workID == work else { return }
        finishWorking(flash: "转录超时，请重试")
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            rebuildHistoryMenu(menu)
        } else if menu === micMenu {
            rebuildMicMenu(menu)
        } else {
            // Main menu: reflect live Accessibility (auto-paste) status and the
            // currently selected input device.
            let trusted = AXIsProcessTrusted()
            accessibilityItem.title = trusted
                ? "自动粘贴：✓ 已授权"
                : "自动粘贴：✗ 未授权（点 Grant Permissions）"
            micItem.title = "Microphone: \(currentMicLabel())"
        }
    }

    // MARK: - Microphone menu

    /// Label for the active input device: its live name, or the remembered name
    /// flagged as unplugged when the saved device is gone (macOS then falls back
    /// to the system default for the next take).
    private func currentMicLabel() -> String {
        let uid = Defaults.micUID
        guard !uid.isEmpty else { return "System default" }
        if let name = AudioDevices.name(forUID: uid) { return truncated(name) }
        let remembered = Defaults.micName
        return remembered.isEmpty ? "未连接的设备" : "\(truncated(remembered))（未连接）"
    }

    private func truncated(_ name: String, limit: Int = 32) -> String {
        name.count > limit ? String(name.prefix(limit)) + "…" : name
    }

    private func rebuildMicMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = AudioDevices.inputDevices()
        let selected = Defaults.micUID

        let systemDefault = NSMenuItem(title: "System default", action: #selector(selectMic(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.representedObject = ""
        systemDefault.state = selected.isEmpty ? .on : .off
        menu.addItem(systemDefault)

        if !devices.isEmpty { menu.addItem(.separator()) }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == selected ? .on : .off
            menu.addItem(item)
        }

        // Chosen device isn't plugged in right now — show it so the checkmark
        // isn't silently missing from the whole list.
        if !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) {
            menu.addItem(.separator())
            let name = Defaults.micName.isEmpty ? "已选设备" : Defaults.micName
            let missing = NSMenuItem(title: "\(name)（未连接）", action: nil, keyEquivalent: "")
            missing.state = .on
            menu.addItem(missing)
        }

        if state != .idle {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "切换将在下一次听写生效", action: nil, keyEquivalent: "")
            menu.addItem(note)
        }
    }

    /// Applies the pick immediately for the next dictation; an in-flight
    /// recording keeps the device it started with.
    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Defaults.setMic(uid: uid, name: sender.title)
        micItem.title = "Microphone: \(currentMicLabel())"
    }

    // MARK: - History menu

    private func rebuildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = TranscriptHistory.all()
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "（暂无转录）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for text in items.prefix(15) {
            let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            let title = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
            let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = "点按复制到剪贴板"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory() {
        TranscriptHistory.clear()
    }

    // MARK: - Menu actions

    @objc private func grantPermissions() {
        Permissions.openSystemSettings()
    }

    @objc private func hotkeyChanged() {
        hotkey.keyCode = Defaults.hotkeyCode()
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Murmur Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        // Become a regular app while a window is on screen so it participates in
        // Stage Manager / ⌘-Tab and hides when you switch away. Reverts to a
        // menu-bar-only accessory when the window closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        // Back to menu-bar-only (no Dock icon) once Settings is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Murmur"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
