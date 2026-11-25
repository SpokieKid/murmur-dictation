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
    private let startStopItem = NSMenuItem(
        title: "",
        action: #selector(toggleDictation),
        keyEquivalent: ""
    )
    private let historyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let micItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let systemAudioItem = NSMenuItem(
        title: "",
        action: #selector(toggleSystemAudio(_:)),
        keyEquivalent: ""
    )
    private let accessibilityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(
        title: "",
        action: #selector(openSettings(_:)),
        keyEquivalent: ","
    )
    private let permissionsItem = NSMenuItem(
        title: "",
        action: #selector(grantPermissions),
        keyEquivalent: ""
    )
    private let quitItem = NSMenuItem(
        title: "",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
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
        let target: TextInjector.Target?
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
        let target: TextInjector.Target?
        let realtime: RealtimeTranscriber?
        var outcome: JobOutcome?
        var task: Task<Void, Never>?
        var watchdog: DispatchWorkItem?

        init(
            id: Int,
            sequence: Int,
            chainID: Int,
            target: TextInjector.Target?,
            realtime: RealtimeTranscriber?
        ) {
            self.id = id
            self.sequence = sequence
            self.chainID = chainID
            self.target = target
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
        NotificationCenter.default.addObserver(self, selector: #selector(appLanguageChanged),
                                               name: .appLanguageChanged, object: nil)

        Permissions.requestMicrophone()
        if Defaults.captureSystemAudio, !Permissions.hasScreenCaptureAccess {
            // The user explicitly enabled meeting audio. Ask once shortly after
            // launch so the first dictation does not begin behind a permission
            // sheet and miss the start of the conversation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                _ = Permissions.requestScreenCapture()
            }
        }
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
        menu.addItem(startStopItem)
        menu.addItem(.separator())
        historyMenu.delegate = self
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        // Mic picker lives in the menu bar (not just Settings) so switching
        // headsets is one click. Devices are re-enumerated each time it opens.
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)
        systemAudioItem.target = self
        menu.addItem(systemAudioItem)
        menu.addItem(.separator())
        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)
        menu.addItem(settingsItem)
        menu.addItem(permissionsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        for item in menu.items where item.action != nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? nil : self
        }
        statusItem.menu = menu
        localizeMainMenu()
    }

    private func render(_ state: State) {
        guard let button = statusItem.button else { return }
        let label: String
        switch state {
        case .idle:
            button.image = Momo.glyph
            label = "Murmur"
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            label = L10n.tr("status.recording")
        case .working:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            label = L10n.tr("status.working")
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label
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

    /// Chooses an insertion chain based on the field under the hotkey, not just
    /// on whether some unrelated transcription is still running. This lets jobs
    /// for different windows complete independently while preserving order and
    /// spacing for consecutive takes aimed at the same input control.
    private func insertionDestinationForNewRecording() -> (
        chainID: Int,
        target: TextInjector.Target?
    ) {
        let target = Defaults.lockInsertionTarget ? TextInjector.captureTarget() : nil

        if state == .working {
            if let target,
               let existing = processingJobs.values
                   .filter({ $0.target?.matches(target) == true })
                   .max(by: { $0.sequence < $1.sequence }) {
                return (existing.chainID, existing.target)
            }

            // Preserve the pre-target-lock behavior when the option is disabled.
            if !Defaults.lockInsertionTarget, latestChainID != 0 {
                return (latestChainID, nil)
            }
        }

        nextChainID &+= 1
        latestChainID = nextChainID
        return (latestChainID, target)
    }

    private func beginDictation() {
        // Processing jobs no longer block the microphone. The only invalid
        // overlap is a second capture (or a second permission callback) while a
        // recording is already being started.
        guard currentRecording == nil, !recorder.isRecording, !isRequestingMicrophone else { return }
        // Capture the destination before a permission sheet or any Murmur UI
        // can disturb focus. Jobs started in the same field share one mutable
        // target session, so ordered insertions advance the same caret state.
        let destination = insertionDestinationForNewRecording()
        let chainID = destination.chainID
        let insertionTarget = destination.target
        isRequestingMicrophone = true
        Permissions.requestMicrophone { [weak self] granted in
            guard let self = self else { return }
            self.isRequestingMicrophone = false
            guard granted else { self.notify(L10n.tr("alert.microphone_denied")); return }
            guard self.currentRecording == nil, !self.recorder.isRecording else { return }

            self.nextJobID &+= 1
            let id = self.nextJobID
            let sequence = id
            let asrConfig = Defaults.config()
            let wantsSystemAudio = Defaults.captureSystemAudio
            let systemAudioGranted = wantsSystemAudio && Permissions.requestScreenCapture()
            var realtime: RealtimeTranscriber?
            do {
                self.recorder.deviceUID = Defaults.micUID
                self.recorder.captureSystemAudio = systemAudioGranted
                self.recorder.onLevel = { [weak self] level in self?.hud.update(id: id, level: level) }
                self.recorder.onSystemAudioError = { [weak self] message in
                    self?.handleSystemAudioFailure(for: id, message: message)
                }
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
                    target: insertionTarget,
                    realtime: realtime
                )
                self.refreshActivity()
                // Escape aborts the take; live only for the duration of a dictation
                // so the key keeps working normally everywhere else.
                if Defaults.showWaveform {
                    let status = systemAudioGranted
                        ? L10n.tr("hud.listening_both")
                        : L10n.tr("hud.listening")
                    self.hud.start(id: id, sequence: sequence, status: status)
                    if wantsSystemAudio, !systemAudioGranted {
                        self.hud.warn(id: id, status: L10n.tr("hud.microphone_only_permission"))
                    }
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
                self.notify(L10n.format("alert.recording_failed", error.localizedDescription))
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
        let wav = recorder.stop()
        // `stop()` drains the mixer's short jitter buffer. Keep realtime ASR's
        // PCM callback attached until that final audio has been emitted.
        clearRecorderCallbacks()
        let seconds = recorder.duration
        let buffers = recorder.bufferCount
        let peak = recorder.peakLevel
        currentRecording = nil
        if Defaults.playSounds { NSSound(named: "Pop")?.play() }

        // Empty / silent / too-short capture → quietly cancel with a brief HUD
        // hint. No modal alert, and don't waste an ASR call on silence.
        if buffers == 0 {
            recording.realtime?.cancel()
            hud.finish(id: recording.id, message: L10n.tr("hud.no_microphone_input"), style: .failure)
            refreshActivity()
            return
        }
        if seconds < minDuration || peak < 0.006 {
            recording.realtime?.cancel()
            hud.finish(id: recording.id, message: L10n.tr("hud.no_speech"), style: .failure)
            refreshActivity()
            return
        }

        let job = ProcessingJob(
            id: recording.id,
            sequence: recording.sequence,
            chainID: recording.chainID,
            target: recording.target,
            realtime: recording.realtime
        )
        processingJobs[job.id] = job
        deliveryOrder.append(job.id)
        hud.setProcessing(id: job.id, status: L10n.tr("hud.transcribing"))
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
                            status: L10n.tr(isLongDictation ? "hud.polishing_long" : "hud.polishing")
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
            hud.finish(id: recording.id, message: L10n.tr("hud.cancelled"), style: .cancelled)
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
                hud.finish(id: id, message: L10n.tr("hud.cancelled"), style: .cancelled)
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
            hud.warn(id: recording.id, status: L10n.format("hud.limit_warning", remaining))
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
        recorder.onSystemAudioError = nil
        recorder.onApproachingLimit = nil
        recorder.onLimitReached = nil
        recorder.onPCMChunk = nil
    }

    private func handleSystemAudioFailure(for id: Int, message: String) {
        guard currentRecording?.id == id else { return }
        perfLog.error("system audio job=\(id) error=\(message, privacy: .public)")
        if Defaults.showWaveform {
            hud.warn(id: id, status: L10n.tr("hud.computer_audio_unavailable"))
        }
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
            hud.finish(id: id, message: L10n.tr("hud.cancelled"), style: .cancelled)
        }

        drainDeliveryQueue()
    }

    /// Delivers completed jobs as soon as their own input target is ready. An
    /// earlier job blocks later jobs for the same field, but never blocks a job
    /// aimed at another window. A short global gap still protects the shared
    /// clipboard when an editor needs the synthetic-paste fallback.
    private func drainDeliveryQueue() {
        guard !deliveryBusy else {
            markCompletedJobsWaiting()
            return
        }

        deliveryOrder.removeAll { processingJobs[$0] == nil }
        while let id = nextDeliverableJobID() {
            guard let job = processingJobs[id] else {
                deliveryOrder.removeAll { $0 == id }
                continue
            }
            guard let outcome = job.outcome else { break }

            deliveryOrder.removeAll { $0 == id }
            switch outcome {
            case .success(let text):
                processingJobs.removeValue(forKey: id)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    hud.finish(id: id, message: L10n.tr("hud.no_text"), style: .failure)
                    continue
                }

                deliveryBusy = true
                let isContinuation = chainsWithDeliveredText.contains(job.chainID)
                let insertionText = isContinuation ? textWithContinuationSeparator(trimmed) : trimmed
                let insertion = deliver(
                    transcript: trimmed,
                    insertionText: insertionText,
                    target: job.target
                )
                if insertion.didInsert {
                    chainsWithDeliveredText.insert(job.chainID)
                }
                let messageKey: String
                switch insertion {
                case .inserted:
                    messageKey = "hud.pasted"
                case .copiedAccessibilityRequired:
                    messageKey = "hud.copied"
                case .copiedTargetUnavailable:
                    messageKey = "hud.target_unavailable_copied"
                }
                hud.finish(
                    id: id,
                    message: L10n.tr(messageKey),
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

        markCompletedJobsWaiting()
        refreshActivity()
    }

    /// Finds the earliest completed job whose own target has no older pending
    /// job. Nil targets are grouped by chain so fallback copies also retain their
    /// spoken order without blocking unrelated fields.
    private func nextDeliverableJobID() -> Int? {
        for (index, id) in deliveryOrder.enumerated() {
            guard let candidate = processingJobs[id], candidate.outcome != nil else { continue }
            let blocked = deliveryOrder[..<index].contains { earlierID in
                guard let earlier = processingJobs[earlierID] else { return false }
                return sharesDeliveryTarget(earlier, candidate)
            }
            if !blocked { return id }
        }
        return nil
    }

    private func sharesDeliveryTarget(_ lhs: ProcessingJob, _ rhs: ProcessingJob) -> Bool {
        switch (lhs.target, rhs.target) {
        case let (left?, right?):
            return left.id == right.id
        case (nil, nil):
            return lhs.chainID == rhs.chainID
        default:
            return false
        }
    }

    private func markCompletedJobsWaiting() {
        for id in deliveryOrder {
            guard case .success? = processingJobs[id]?.outcome else { continue }
            hud.setWaiting(id: id, status: L10n.tr("hud.waiting"))
        }
    }

    /// Saves the transcript to history and pastes it (or falls back to the
    /// clipboard). HUD completion is per-job and handled by the ordered drain.
    @discardableResult
    private func deliver(
        transcript: String,
        insertionText: String,
        target: TextInjector.Target?
    ) -> TextInjector.InsertionResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .copiedTargetUnavailable }
        TranscriptHistory.add(trimmed)
        let insertion = TextInjector.insert(insertionText, into: target)

        if case .copiedAccessibilityRequired = insertion, !warnedNoAccessibility {
            warnedNoAccessibility = true
            notify(L10n.tr("alert.clipboard_fallback"))
        }
        return insertion
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
        let message = L10n.tr("hud.timeout")
        job.outcome = .failure(message)
        hud.finish(id: id, message: message, style: .failure)
        drainDeliveryQueue()
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            rebuildHistoryMenu(menu)
        } else if menu === micMenu {
            rebuildMicMenu(menu)
        } else {
            // Main menu: refresh both its active language and live state.
            localizeMainMenu()
        }
    }

    private func localizeMainMenu() {
        startStopItem.title = L10n.tr("menu.start_stop")
        historyItem.title = L10n.tr("menu.recent_transcripts")
        settingsItem.title = L10n.tr("menu.settings")
        permissionsItem.title = L10n.tr("menu.grant_permissions")
        quitItem.title = L10n.tr("menu.quit")
        accessibilityItem.title = AXIsProcessTrusted()
            ? L10n.tr("menu.auto_paste_authorized")
            : L10n.tr("menu.auto_paste_unauthorized")
        micItem.title = "\(L10n.tr("menu.microphone")): \(currentMicLabel())"
        refreshSystemAudioMenuItem()
    }

    private func refreshSystemAudioMenuItem() {
        let appliesNextTime = currentRecording != nil || recorder.isRecording
        systemAudioItem.title = appliesNextTime
            ? L10n.tr("menu.include_computer_audio_next")
            : L10n.tr("menu.include_computer_audio")
        systemAudioItem.state = Defaults.captureSystemAudio ? .on : .off
        systemAudioItem.toolTip = Defaults.captureSystemAudio
            ? L10n.tr("menu.computer_audio_on_hint")
            : L10n.tr("menu.computer_audio_off_hint")
    }

    // MARK: - Microphone menu

    /// Label for the active input device: its live name, or the remembered name
    /// flagged as unplugged when the saved device is gone (macOS then falls back
    /// to the system default for the next take).
    private func currentMicLabel() -> String {
        let uid = Defaults.micUID
        guard !uid.isEmpty else { return L10n.tr("menu.system_default") }
        if let name = AudioDevices.name(forUID: uid) { return truncated(name) }
        let remembered = Defaults.micName
        return remembered.isEmpty
            ? L10n.tr("menu.disconnected_generic")
            : L10n.format("menu.disconnected_device", truncated(remembered))
    }

    private func truncated(_ name: String, limit: Int = 32) -> String {
        name.count > limit ? String(name.prefix(limit)) + "…" : name
    }

    private func rebuildMicMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let devices = AudioDevices.inputDevices()
        let selected = Defaults.micUID

        let systemDefault = NSMenuItem(
            title: L10n.tr("menu.system_default"),
            action: #selector(selectMic(_:)),
            keyEquivalent: ""
        )
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
            let name = Defaults.micName.isEmpty ? L10n.tr("menu.selected_device") : Defaults.micName
            let missing = NSMenuItem(
                title: L10n.format("menu.disconnected_device", name),
                action: nil,
                keyEquivalent: ""
            )
            missing.state = .on
            menu.addItem(missing)
        }

        if state != .idle {
            menu.addItem(.separator())
            let note = NSMenuItem(
                title: L10n.tr("menu.change_next_dictation"),
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(note)
        }
    }

    /// Applies the pick immediately for the next dictation; an in-flight
    /// recording keeps the device it started with.
    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Defaults.setMic(uid: uid, name: sender.title)
        micItem.title = "\(L10n.tr("menu.microphone")): \(currentMicLabel())"
    }

    // MARK: - History menu

    private func rebuildHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = TranscriptHistory.all()
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: L10n.tr("menu.no_transcripts"), action: nil, keyEquivalent: "")
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
            item.toolTip = L10n.tr("menu.copy_hint")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(
            title: L10n.tr("menu.clear_history"),
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
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

    /// Quick meeting-audio switch in the status-bar menu. The recorder snapshots
    /// this preference at the beginning of each take, so an active take remains
    /// internally consistent and the new value applies to the next one.
    @objc private func toggleSystemAudio(_ sender: NSMenuItem) {
        let enabled = !Defaults.captureSystemAudio
        UserDefaults.standard.set(enabled, forKey: "captureSystemAudio")
        refreshSystemAudioMenuItem()

        if enabled, !Permissions.hasScreenCaptureAccess {
            let granted = Permissions.requestScreenCapture()
            if !granted {
                notify(L10n.tr("alert.computer_audio_permission"))
            }
        }
    }

    @objc private func grantPermissions() {
        Permissions.openSystemSettings()
    }

    @objc private func hotkeyChanged() {
        hotkey.keyCode = Defaults.hotkeyCode()
    }

    @objc private func appLanguageChanged() {
        render(state)
        localizeMainMenu()
        settingsWindow?.title = L10n.tr("app.settings_title")
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = L10n.tr("app.settings_title")
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
