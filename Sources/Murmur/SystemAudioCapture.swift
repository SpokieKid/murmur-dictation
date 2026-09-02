import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Converts arbitrary CoreMedia audio sample buffers to Murmur's canonical
/// 16 kHz mono Float32 format. Each capture source owns its own converter
/// because `AVAudioConverter` is not safe to drive concurrently.
final class AudioSampleConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func reset() {
        converter = nil
        inputFormat = nil
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let input = makePCMBuffer(sampleBuffer) else { return nil }

        if converter == nil || !(inputFormat?.isEqual(input.format) ?? false) {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            inputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              let channel = output.floatChannelData,
              output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private func makePCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Captures macOS playback audio (meeting participants, browser video, etc.)
/// through ScreenCaptureKit. No pixels are consumed; a tiny/slow screen stream
/// is configured only because ScreenCaptureKit associates system audio with a
/// display content filter.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.murmur.system-audio")
    private let converter = AudioSampleConverter()
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var stopped = true

    func start() {
        stateLock.lock()
        stopped = false
        stateLock.unlock()
        converter.reset()

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in
            guard let self, !self.isStopped else { return }
            if let error {
                self.report(L10n.format("error.system_audio_read", error.localizedDescription))
                return
            }
            guard let display = content?.displays.first else {
                self.report(L10n.tr("error.system_audio_no_display"))
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
            } catch {
                self.report(L10n.format("error.system_audio_init", error.localizedDescription))
                return
            }

            self.stateLock.lock()
            guard !self.stopped else {
                self.stateLock.unlock()
                return
            }
            self.stream = stream
            self.stateLock.unlock()

            stream.startCapture { [weak self, weak stream] error in
                guard let self, !self.isStopped else { return }
                if let error {
                    self.report(L10n.format("error.system_audio_capture", error.localizedDescription))
                    self.clear(stream: stream)
                }
            }
        }
    }

    /// Requests capture shutdown and drains callbacks already queued before
    /// `AudioRecorder.stop()` produces the final WAV. We deliberately avoid
    /// waiting on ScreenCaptureKit's completion from the main thread.
    func stop() {
        stateLock.lock()
        stopped = true
        let activeStream = stream
        stream = nil
        stateLock.unlock()

        guard let activeStream else { return }
        activeStream.stopCapture { _ in }
        sampleQueue.sync {}
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              let converted = converter.convert(sampleBuffer),
              !converted.isEmpty else { return }
        onSamples?(converted)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopped else { return }
        report(L10n.format("error.system_audio_stopped", error.localizedDescription))
        clear(stream: stream)
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func clear(stream stoppedStream: SCStream?) {
        stateLock.lock()
        if stream === stoppedStream { stream = nil }
        stateLock.unlock()
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onError?(message)
        }
    }
}

/// A small real-time jitter buffer that combines microphone and computer audio
/// into ordered 20 ms frames. Starting with a short pre-roll absorbs normal
/// callback jitter; each source can temporarily underrun without blocking the
/// other, which is important when a meeting app pauses playback.
final class LiveAudioMixer {
    enum Source {
        case microphone
        case system
    }

    private let frameSize = 320 // 20 ms at 16 kHz
    private let queue = DispatchQueue(label: "com.murmur.audio-mixer")
    private let output: ([Float]) -> Void
    private var timer: DispatchSourceTimer?
    private var running = false

    private var microphoneSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var microphoneReadIndex = 0
    private var systemReadIndex = 0

    init(output: @escaping ([Float]) -> Void) {
        self.output = output
    }

    func start() {
        queue.sync {
            guard !running else { return }
            running = true
            microphoneSamples.removeAll(keepingCapacity: true)
            systemSamples.removeAll(keepingCapacity: true)
            microphoneReadIndex = 0
            systemReadIndex = 0

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + .milliseconds(80),
                repeating: .milliseconds(20),
                leeway: .milliseconds(2)
            )
            timer.setEventHandler { [weak self] in self?.emitFrame(includeSilence: true) }
            self.timer = timer
            timer.resume()
        }
    }

    func append(_ samples: [Float], from source: Source) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            switch source {
            case .microphone:
                self.microphoneSamples.append(contentsOf: samples)
            case .system:
                self.systemSamples.append(contentsOf: samples)
            }
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil

            while availableMicrophoneSamples > 0 || availableSystemSamples > 0 {
                emitFrame(includeSilence: false)
            }
            running = false
            microphoneSamples.removeAll(keepingCapacity: false)
            systemSamples.removeAll(keepingCapacity: false)
            microphoneReadIndex = 0
            systemReadIndex = 0
        }
    }

    private var availableMicrophoneSamples: Int {
        microphoneSamples.count - microphoneReadIndex
    }

    private var availableSystemSamples: Int {
        systemSamples.count - systemReadIndex
    }

    private func emitFrame(includeSilence: Bool) {
        let microphoneCount = min(frameSize, availableMicrophoneSamples)
        let systemCount = min(frameSize, availableSystemSamples)
        guard includeSilence || microphoneCount > 0 || systemCount > 0 else { return }

        let hasMicrophone = microphoneCount > 0
        let hasSystem = systemCount > 0
        let gain: Float = hasMicrophone && hasSystem ? 0.72 : 1
        var mixed = [Float](repeating: 0, count: frameSize)

        for index in 0..<frameSize {
            let microphone = index < microphoneCount
                ? microphoneSamples[microphoneReadIndex + index]
                : 0
            let system = index < systemCount
                ? systemSamples[systemReadIndex + index]
                : 0
            mixed[index] = max(-1, min(1, (microphone + system) * gain))
        }
        microphoneReadIndex += microphoneCount
        systemReadIndex += systemCount
        compactBuffersIfNeeded()
        output(mixed)
    }

    private func compactBuffersIfNeeded() {
        if microphoneReadIndex >= 4096 {
            microphoneSamples.removeFirst(microphoneReadIndex)
            microphoneReadIndex = 0
        }
        if systemReadIndex >= 4096 {
            systemSamples.removeFirst(systemReadIndex)
            systemReadIndex = 0
        }
    }
}
