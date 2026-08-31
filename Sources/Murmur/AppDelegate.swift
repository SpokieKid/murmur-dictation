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

    /// A single microphone capture. Murmur only records one take at a time, but
    /// once this context is handed to a `ProcessingJob` the recorder is free to
    /// start the next take while the previous one transcribes in parallel.
    private struct RecordingContext {
        let id: Int
        let sequence: Int
        let chainID: Int
        let realtime: RealtimeTranscriber?
    }

    private enum JobOutcome {
        case success(String)
        case failure(String)
        case cancelled
    }

    private final class ProcessingJob {
        let id: Int
        let sequence: Int
        let chainID: Int
        let realtime: RealtimeTranscriber?
        var outcome: JobOutcome?
        var task: Task<Void, Never>?
        var watchdog: DispatchWorkItem?

        init(id: Int, sequence: Int, chainID: Int, realtime: RealtimeTranscriber?) {
            self.id = id
            self.sequence = sequence
            self.chainID = chainID
            self.realtime = realtime
        }
    }

    private var currentRecording: RecordingContext?
    private var isRequestingMicrophone = false
    private var nextJobID = 0
    private var nextChainID = 0
    private var latestChainID = 0
    private var chainsWithDeliveredText: Set<Int> = []
    private var processingJobs: [Int: ProcessingJob] = [:]
    /// Valid takes in capture order. A later result can finish first, but it is
    /// held here until every earlier entry has been delivered or skipped.
    private var deliveryOrder: [Int] = []
    private var deliveryBusy = false

    private var state: State {
        if currentRecording != nil || recorder.isRecording { return .recording }
        if !processingJobs.isEmpty || deliveryBusy { return .working }
        return .idle
    }
    private var minDuration = 0.4
    private var playedLimitWarning = false
    /// Stage timing for diagnosing perceived latency. Read with:
    /// `log show --predicate 'subsystem == "com.murmur.dictation"' --style compact --last 10m`
    private let perfLog = Logger(subsystem: "com.murmur.dictation", category: "timing")

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
        if currentRecording != nil || recorder.isRecording {
            endDictation()
        } else {
            beginDictation()
        }
    }

    private func beginDictation() {
        // Processing jobs no longer block the microphone. The only invalid
        // overlap is a second capture (or a second permission callback) while a
        // recording is already being started.
        guard currentRecording == nil, !recorder.isRecording, !isRequestingMicrophone else { return }
        let chainID: Int
        if state == .working, latestChainID != 0 {
            chainID = latestChainID
        } else {
            nextChainID &+= 1
            latestChainID = nextChainID
            chainID = latestChainID
            chainsWithDeliveredText.removeAll()
        }
        isRequestingMicrophone = true
        Permissions.requestMicrophone { [weak self] granted in
            guard let self = self else { return }
            self.isRequestingMicrophone = false
            guard granted else { self.notify("Microphone access denied"); return }
            guard self.currentRecording == nil, !self.recorder.isRecording else { return }

            self.nextJobID &+= 1
            let id = self.nextJobID
            let sequence = id
            let asrConfig = Defaults.config()
            var realtime: RealtimeTranscriber?
            do {
                self.recorder.deviceUID = Defaults.micUID
                self.recorder.onLevel = { [weak self] level in self?.hud.update(id: id, level: level) }
                self.playedLimitWarning = false
                self.recorder.maxDuration = Defaults.maxRecordingSeconds()
                self.recorder.warnLeadSeconds = Defaults.recordingWarnLeadSeconds
                self.recorder.onApproachingLimit = { [weak self] remaining in
                    self?.handleApproachingLimit(remaining)
                }
                self.recorder.onLimitReached = { [weak self] in self?.handleRecordingLimitReached() }

                if Defaults.useRealtimeASR {
                    realtime = self.startRealtimeASR(config: asrConfig)
                }
                try self.recorder.start()
                self.currentRecording = RecordingContext(
                    id: id,
                    sequence: sequence,
                    chainID: chainID,
                    realtime: realtime
                )
                self.refreshActivity()
                // Escape aborts the take; live only for the duration of a dictation
                // so the key keeps working normally everywhere else.
                if Defaults.showWaveform {
                    self.hud.start(id: id, sequence: sequence, status: "Listening… ⎋ 取消")
                }
                if Defaults.playSounds { NSSound(named: "Tink")?.play() }
                // Warm the ASR/LLM connections while the user is still
                // speaking, so the TCP/TLS handshake doesn't land on the
                // critical path after they release the hotkey.
                Transcriber.prewarm(config: asrConfig)
                if let llmConfig = Defaults.llmConfig() { LLMRefiner.prewarm(config: llmConfig) }
            } catch {
                realtime?.cancel()
                self.clearRecorderCallbacks()
                self.refreshActivity()
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
    private func startRealtimeASR(config: Transcriber.Config) -> RealtimeTranscriber {
        let rt = RealtimeTranscriber()
        recorder.onPCMChunk = { [weak rt] chunk in rt?.append(chunk) }
        Task {
            let vocabId = await VocabularyManager.vocabularyId(for: Defaults.vocabularyTerms, apiKey: config.apiKey)
            rt.beginConnecting(config: .init(apiKey: config.apiKey, language: config.language, vocabularyId: vocabId))
        }
        return rt
    }

    private func endDictation() {
        guard let recording = currentRecording else { return }
        clearRecorderCallbacks()
        let wav = recorder.stop()
        let seconds = recorder.duration
        let buffers = recorder.bufferCount
        let peak = recorder.peakLevel
        currentRecording = nil
        if Defaults.playSounds { NSSound(named: "Pop")?.play() }

        // Empty / silent / too-short capture → quietly cancel with a brief HUD
        // hint. No modal alert, and don't waste an ASR call on silence.
        if buffers == 0 {
            recording.realtime?.cancel()
            hud.finish(id: recording.id, message: "未检测到麦克风输入", style: .failure)
            refreshActivity()
            return
        }
        if seconds < minDuration || peak < 0.006 {
            recording.realtime?.cancel()
            hud.finish(id: recording.id, message: "未检测到语音", style: .failure)
            refreshActivity()
            return
        }

        let job = ProcessingJob(
            id: recording.id,
            sequence: recording.sequence,
            chainID: recording.chainID,
            realtime: recording.realtime
        )
        processingJobs[job.id] = job
        deliveryOrder.append(job.id)
        hud.setProcessing(id: job.id, status: "Transcribing…")
        refreshActivity()

        let config = Defaults.config()
        let llmConfig = Defaults.llmConfig()
        scheduleStallWatchdog(for: job)
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            let t0 = Date()
            do {
                var text: String
                let path: String
                if let realtime = job.realtime, let realtimeText = await realtime.finish() {
                    text = realtimeText
                    path = "stream"
                } else {
                    text = try await Transcriber.transcribe(wav: wav, config: config)
                    path = job.realtime == nil ? "batch" : "batch(stream-fell-back)"
                }
                try Task.checkCancellation()
                let tAsr = Date()
                self.perfLog.notice("asr job=\(job.sequence) path=\(path, privacy: .public) dt=\(tAsr.timeIntervalSince(t0), format: .fixed(precision: 2))s chars=\(text.count)")
                if let llmConfig = llmConfig, !text.isEmpty {
                    let isLongDictation = seconds >= 60 || text.count >= 600
                    await MainActor.run {
                        self.updateJobStage(
                            job.id,
                            status: isLongDictation ? "Polishing long dictation…" : "Polishing…"
                        )
                    }
                    if let polished = await LLMRefiner.refine(
                        text,
                        config: llmConfig,
                        recordingDuration: seconds
                    ) {
                        text = polished
                    }
                    try Task.checkCancellation()
                    self.perfLog.notice("polish job=\(job.sequence) dt=\(Date().timeIntervalSince(tAsr), format: .fixed(precision: 2))s")
                }
                self.perfLog.notice("pipeline job=\(job.sequence) total dt=\(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
                try Task.checkCancellation()
                let completedText = text
                await MainActor.run { self.completeJob(job.id, outcome: .success(completedText)) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.completeJob(job.id, outcome: .failure(error.localizedDescription))
                }
            }
        }
    }

    /// Escape pressed mid-dictation: throw this take away.
    ///
    /// While recording we stop capture and never call the ASR at all. With only
    /// processing cards visible, Escape cancels the newest undelivered job; its
    /// outcome marker ensures a late network response cannot paste afterward.
    private func cancelDictation() {
        if let recording = currentRecording {
            clearRecorderCallbacks()
            _ = recorder.stop() // audio is dropped on the floor; no ASR call at all
            recording.realtime?.cancel()
            currentRecording = nil
            if Defaults.playSounds { NSSound(named: "Bottle")?.play() }
            hud.finish(id: recording.id, message: "✗ 已取消", style: .cancelled)
            refreshActivity()
            return
        }

        // With a stack of in-flight jobs, Escape cancels the newest undelivered
        // one. Earlier jobs continue, preserving the visible stack/order model.
        for id in deliveryOrder.reversed() {
            guard let job = processingJobs[id] else { continue }
            switch job.outcome {
            case nil, .success?:
                job.task?.cancel()
                job.task = nil
                job.watchdog?.cancel()
                job.watchdog = nil
                job.realtime?.cancel()
                job.outcome = .cancelled
                if Defaults.playSounds { NSSound(named: "Bottle")?.play() }
                hud.finish(id: id, message: "✗ 已取消", style: .cancelled)
                drainDeliveryQueue()
                return
            case .failure?, .cancelled?:
                continue
            }
        }
    }

    /// The recording is nearing the provider's per-request audio limit. Show a
    /// live countdown on the HUD (and a one-time chime) so the user can wrap up
    /// before capture auto-stops.
    private func handleApproachingLimit(_ remaining: Int) {
        guard let recording = currentRecording else { return }
        if Defaults.showWaveform {
            hud.warn(id: recording.id, status: "⚠️ \(remaining) 秒后自动停止录音")
        }
        if !playedLimitWarning {
            playedLimitWarning = true
            if Defaults.playSounds { NSSound(named: "Funk")?.play() }
        }
    }

    /// The cap was hit — stop capture and transcribe what we have, rather than
    /// letting an over-length take fail the ASR request.
    private func handleRecordingLimitReached() {
        guard currentRecording != nil else { return }
        endDictation()
    }

    private func clearRecorderCallbacks() {
        recorder.onLevel = nil
        recorder.onApproachingLimit = nil
        recorder.onLimitReached = nil
        recorder.onPCMChunk = nil
    }

    private func updateJobStage(_ id: Int, status: String) {
        guard let job = processingJobs[id], job.outcome == nil else { return }
        hud.setProcessing(id: id, status: status)
    }

    private func completeJob(_ id: Int, outcome: JobOutcome) {
        guard let job = processingJobs[id], job.outcome == nil else { return }
        job.watchdog?.cancel()
        job.watchdog = nil
        job.task = nil
        job.outcome = outcome

        switch outcome {
        case .success:
            // `drainDeliveryQueue` either pastes this immediately or marks it as
            // waiting when an earlier parallel request is still in flight.
            break
        case .failure(let message):
            let oneLine = message.replacingOccurrences(of: "\n", with: " ")
            let short = oneLine.count > 34 ? String(oneLine.prefix(34)) + "…" : oneLine
            hud.finish(id: id, message: "✗ \(short)", style: .failure)
        case .cancelled:
            hud.finish(id: id, message: "✗ 已取消", style: .cancelled)
        }

        drainDeliveryQueue()
    }

    /// Delivers every completed head-of-line job, while holding later results
    /// until their predecessors finish. A short gap keeps consecutive synthetic
    /// paste events from racing each other in the target app.
    private func drainDeliveryQueue() {
        guard !deliveryBusy else {
            markCompletedJobsWaiting()
            return
        }

        while let id = deliveryOrder.first {
            guard let job = processingJobs[id] else {
                deliveryOrder.removeFirst()
                continue
            }
            guard let outcome = job.outcome else {
                markCompletedJobsWaiting()
                refreshActivity()
                return
            }

            deliveryOrder.removeFirst()
            switch outcome {
            case .success(let text):
                processingJobs.removeValue(forKey: id)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    hud.finish(id: id, message: "未识别到文字", style: .failure)
                    continue
                }

                deliveryBusy = true
                let isContinuation = chainsWithDeliveredText.contains(job.chainID)
                let insertionText = isContinuation ? textWithContinuationSeparator(trimmed) : trimmed
                let pasted = deliver(transcript: trimmed, insertionText: insertionText)
                chainsWithDeliveredText.insert(job.chainID)
                hud.finish(
                    id: id,
                    message: pasted ? "✓ 已粘贴" : "✓ 已复制 · ⌘V",
                    style: .success
                )
                refreshActivity()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.deliveryBusy = false
                    self.drainDeliveryQueue()
                }
                return

            case .failure, .cancelled:
                processingJobs.removeValue(forKey: id)
            }
        }

        refreshActivity()
    }

    private func markCompletedJobsWaiting() {
        for id in deliveryOrder {
            guard case .success? = processingJobs[id]?.outcome else { continue }
            hud.setWaiting(id: id, status: "等待前序任务…")
        }
    }

    /// Saves the transcript to history and pastes it (or falls back to the
    /// clipboard). HUD completion is per-job and handled by the ordered drain.
    @discardableResult
    private func deliver(transcript: String, insertionText: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        TranscriptHistory.add(trimmed)
        let pasted = TextInjector.insert(insertionText)

        if !pasted, !warnedNoAccessibility {
            warnedNoAccessibility = true
            notify("结果已复制到剪贴板，按 ⌘V 即可粘贴。\n\n要让 Murmur 自动粘贴到光标处，请在 系统设置 → 隐私与安全性 → 辅助功能 里勾选 Murmur（菜单「Grant Permissions…」可直达），然后重启 App。\n\n所有转录都能在菜单「Recent Transcripts」里查看。")
        }
        return pasted
    }

    /// Separate consecutive English/ASCII additions with one space while
    /// leaving CJK text and leading closing punctuation naturally adjacent.
    private func textWithContinuationSeparator(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }
        let attachesToPrevious = ",.!?;:)]}，。！？；：、".contains(first)
        guard first.isASCII, !attachesToPrevious else { return text }
        return " " + text
    }

    private func refreshActivity() {
        render(state)
        if currentRecording != nil || !processingJobs.isEmpty {
            escape.start()
        } else {
            escape.stop()
        }
    }

    /// Arms an independent fallback for each parallel request. One stalled job
    /// can time out without cancelling newer jobs that are still making progress.
    private func scheduleStallWatchdog(for job: ProcessingJob) {
        let id = job.id
        let item = DispatchWorkItem { [weak self] in self?.recoverFromStall(id) }
        job.watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func recoverFromStall(_ id: Int) {
        guard let job = processingJobs[id], job.outcome == nil else { return }
        job.task?.cancel()
        job.task = nil
        job.watchdog = nil
        job.realtime?.cancel()
        job.outcome = .failure("转录超时，请重试")
        hud.finish(id: id, message: "转录超时，请重试", style: .failure)
        drainDeliveryQueue()
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
