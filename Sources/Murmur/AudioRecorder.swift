import AVFoundation

/// Captures microphone audio with an **AVCaptureSession** (input only) and
/// produces 16 kHz mono 16-bit PCM WAV.
///
/// Why not AVAudioEngine: the engine spins up an output IO unit too, which
/// briefly interrupts whatever audio is currently playing (music ducks/glitches
/// on record start). A capture session only opens the input device, so playback
/// is left untouched. It also selects a specific device cleanly without having
/// to change the system-wide default input.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16_000, channels: 1, interleaved: false)!
    private let targetSampleRate: Double = 16_000
    private let queue = DispatchQueue(label: "com.murmur.capture")

    private let lock = NSLock()
    private var samples: [Float] = []

    private(set) var isRecording = false

    /// Called on the main thread with a normalised 0...1 level for UI metering.
    var onLevel: ((Float) -> Void)?

    /// Fired on the capture queue with each newly-captured chunk of raw PCM16LE
    /// mono 16kHz audio (no WAV header) — lets a streaming transcriber upload
    /// audio as it's recorded instead of waiting for `stop()`. Independent of
    /// the `samples` accumulation below, which keeps feeding the batch/WAV path.
    var onPCMChunk: ((Data) -> Void)?

    /// UID (AVCaptureDevice.uniqueID) of the mic to record from; nil/empty = default.
    var deviceUID: String?

    /// Hard cap on a single recording, in seconds. 0 disables the cap.
    /// Used to stay under the ASR provider's per-request audio limit (e.g.
    /// Qwen3-ASR's 10 MB / 5-min ceiling) so a long take is auto-stopped and
    /// transcribed instead of failing the API call.
    var maxDuration: Double = 0
    /// How far ahead of `maxDuration` to start warning the user, in seconds.
    var warnLeadSeconds: Double = 60

    /// Fired (on the main thread) once per whole second during the warning
    /// window with the seconds remaining until the cap. Drives the HUD countdown.
    var onApproachingLimit: ((Int) -> Void)?
    /// Fired (on the main thread) once when the cap is hit; the owner should
    /// stop the recording. Capture keeps running until it does.
    var onLimitReached: (() -> Void)?

    private var lastWarnedSecond = -1
    private var limitFired = false

    // Diagnostics for the current/last capture.
    private(set) var bufferCount = 0
    private(set) var peakLevel: Float = 0

    /// Approximate captured duration in seconds (thread-safe snapshot).
    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / targetSampleRate
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()
        bufferCount = 0
        peakLevel = 0
        lastWarnedSecond = -1
        limitFired = false
        converter = nil
        inFormat = nil

        let device = AudioDevices.device(forUID: deviceUID ?? "") ?? AVCaptureDevice.default(for: .audio)
        guard let device = device else { throw err("没有可用的音频输入设备。") }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw err("无法使用该麦克风。") }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw err("无法初始化音频采集。") }
        session.addOutput(output)

        session.startRunning()
        self.session = session
        isRecording = true
    }

    /// Stops capture and returns the recorded audio as WAV data.
    func stop() -> Data {
        guard isRecording, let session = session else { return Data() }
        session.stopRunning()
        self.session = nil
        isRecording = false

        lock.lock(); let captured = samples; lock.unlock()
        return Self.encodeWAV(samples: captured, sampleRate: Int(targetSampleRate))
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = makePCMBuffer(sampleBuffer) else { return }
        process(pcm)
    }

    private func makePCMBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || !(inFormat?.isEqual(buffer.format) ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            inFormat = buffer.format
        }
        guard let converter = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, let channel = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }
        let ptr = channel[0]
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        lock.unlock()

        if let onPCMChunk = onPCMChunk {
            var pcm16 = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let clamped = max(-1.0, min(1.0, ptr[i]))
                pcm16[i] = Int16(clamped * 32_767).littleEndian
            }
            let chunk = pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
            onPCMChunk(chunk)
        }

        bufferCount += 1
        var sum: Float = 0
        for i in 0..<count { let v = ptr[i]; sum += v * v }
        let rms = (sum / Float(count)).squareRoot()
        if rms > peakLevel { peakLevel = rms }

        if let onLevel = onLevel {
            let level = min(1.0, max(0.0, rms * 6.0))
            DispatchQueue.main.async { onLevel(level) }
        }

        checkLimits()
    }

    /// Watches the running duration against `maxDuration` and emits the
    /// approaching-limit countdown / limit-reached callbacks. Runs on the
    /// capture queue after each buffer (buffers arrive every few ms).
    private func checkLimits() {
        guard maxDuration > 0, isRecording else { return }
        let elapsed = duration
        if !limitFired, elapsed >= maxDuration {
            limitFired = true
            DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
            return
        }
        let remaining = maxDuration - elapsed
        guard remaining <= warnLeadSeconds else { return }
        let sec = max(0, Int(remaining.rounded(.up)))
        if sec != lastWarnedSecond {
            lastWarnedSecond = sec
            DispatchQueue.main.async { [weak self] in self?.onApproachingLimit?(sec) }
        }
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "Murmur.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - WAV encoding

    static func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2
        var data = Data(capacity: 44 + dataSize)

        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }

        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)               // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(2); u16(16)                                       // block align, bits/sample
        ascii("data"); u32(UInt32(dataSize))

        // Convert the whole buffer and append it in one shot instead of one
        // Data.append per sample — this ran on the main thread in `stop()` and
        // a per-sample closure call adds up to real, visible latency once a
        // clip runs into the hundreds of thousands of samples (16 kHz × tens
        // of seconds), delaying the upload that follows.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32_767).littleEndian
        }
        pcm.withUnsafeBufferPointer { data.append($0) }

        return data
    }
}
