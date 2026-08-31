import Foundation

/// Streaming ASR over Alibaba Cloud DashScope's `paraformer-realtime-v2` model.
/// Audio is uploaded live as it's captured (binary PCM16 frames over a
/// `header`/`payload` task-based WebSocket protocol — distinct from the newer
/// OpenAI-Realtime-style protocol Qwen's realtime models use), so most of the
/// audio has already reached the server by the time the user releases the
/// hotkey, instead of waiting to upload a full WAV afterwards.
final class RealtimeTranscriber {
    struct Config {
        var apiKey: String
        var language: String       // ISO code or "auto"
        var vocabularyId: String?  // see VocabularyManager
    }

    enum RealtimeError: LocalizedError {
        case connectFailed
        case taskFailed(String)
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .connectFailed: return "Could not connect to the realtime ASR service."
            case .taskFailed(let msg): return "Realtime ASR failed: \(msg)"
            case .notConfigured: return "Set your API key in Settings first."
            }
        }
    }

    private static let endpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private let taskId = UUID().uuidString
    private var connectTask: Task<Void, Error>?

    private let lock = NSLock()
    private var sentences: [String] = []
    private var finished = false
    private var ready = false
    private var pending: [Data] = []

    /// Kicks off the connection in the background and returns immediately —
    /// callers should start calling `append` right away. Audio captured before
    /// the connection actually confirms `task-started` is buffered here and
    /// flushed in order once it does, instead of being silently dropped during
    /// the handshake (which, on a flaky connection, can take long enough to
    /// swallow the first sentence of a dictation).
    func beginConnecting(config: Config) {
        connectTask = Task { try await self.connect(config: config) }
    }

    private func connect(config: Config) async throws {
        guard !config.apiKey.isEmpty else { throw RealtimeError.notConfigured }

        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        socket = ws
        ws.resume()

        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            // Keeps the socket alive through brief mid-dictation pauses instead
            // of the default hard 60s-of-silence timeout.
            "heartbeat": true,
        ]
        if config.language != "auto", !config.language.isEmpty {
            parameters["language_hints"] = [config.language]
        }
        if let vocabularyId = config.vocabularyId, !vocabularyId.isEmpty {
            parameters["vocabulary_id"] = vocabularyId
        }

        let runTask: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": "paraformer-realtime-v2",
                "parameters": parameters,
                "input": [String: Any](),
            ],
        ]
        do {
            try await sendJSON(runTask, on: ws)
            guard let first = try? await Self.receiveWithin(8, on: ws), let event = Self.decode(first) else {
                throw RealtimeError.connectFailed
            }
            guard Self.eventName(event) == "task-started" else {
                throw RealtimeError.taskFailed(Self.errorMessage(event) ?? "unexpected response")
            }
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            throw error
        }

        // Flush whatever `append` buffered while we were still connecting, in order.
        let buffered: [Data] = lock.withLock {
            ready = true
            defer { pending = [] }
            return pending
        }
        for chunk in buffered { ws.send(.data(chunk)) { _ in } }

        Task { [weak self] in await self?.receiveLoop() }
    }

    /// Streams (or, before the connection is ready, buffers) one chunk of raw
    /// PCM16LE mono 16kHz audio. Safe to call from any thread.
    func append(_ pcm: Data) {
        let flushNow: Bool = lock.withLock {
            if ready { return true }
            pending.append(pcm)
            return false
        }
        if flushNow { socket?.send(.data(pcm)) { _ in } }
    }

    /// Abandons the session without asking for a transcript — used when the user
    /// cancels a dictation. Safe to call before the connection is even up.
    func cancel() {
        connectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        lock.withLock { finished = true }
    }

    /// Signals end of audio and waits (bounded) for the final transcript,
    /// concatenated from every finalized sentence the server reported. Returns
    /// nil if the connection never came up at all — callers should fall back
    /// to a different transcription path in that case.
    func finish() async -> String? {
        _ = try? await connectTask?.value // make sure connect (success or failure) has resolved
        guard lock.withLock({ ready }), let ws = socket else { return nil }

        let finishMsg: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ]
        try? await sendJSON(finishMsg, on: ws)

        for _ in 0..<50 { // bounded ~5s wait for the server to flush + task-finished
            if lock.withLock({ finished }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        ws.cancel(with: .normalClosure, reason: nil)
        return lock.withLock { sentences.joined() }
    }

    private func receiveLoop() async {
        guard let ws = socket else { return }
        while true {
            guard let message = try? await ws.receive(), let event = Self.decode(message) else {
                lock.withLock { finished = true }
                return
            }
            switch Self.eventName(event) {
            case "result-generated":
                if let payload = event["payload"] as? [String: Any],
                   let output = payload["output"] as? [String: Any],
                   let sentence = output["sentence"] as? [String: Any],
                   sentence["sentence_end"] as? Bool == true,
                   let text = sentence["text"] as? String {
                    lock.withLock { sentences.append(text) }
                }
            case "task-finished", "task-failed":
                lock.withLock { finished = true }
                return
            default:
                break
            }
        }
    }

    /// `ws.receive()` bounded by a timeout. A socket that connects at the TCP
    /// level but never sends `task-started` — which happens after the app wakes
    /// from a long idle and the path is half-dead — would otherwise hang the
    /// handshake forever, stranding the dictation Task in its "working" state
    /// (the bug that used to require an app restart). On timeout we throw, so
    /// `connect` cancels the socket and `finish` falls back to batch ASR.
    private static func receiveWithin(_ seconds: Double,
                                      on ws: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await ws.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RealtimeError.connectFailed
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RealtimeError.connectFailed }
            return first
        }
    }

    private func sendJSON(_ obj: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let string = String(data: data, encoding: .utf8) ?? "{}"
        try await ws.send(.string(string))
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch message {
        case .string(let s):
            return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
        case .data(let d):
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        @unknown default:
            return nil
        }
    }

    private static func eventName(_ obj: [String: Any]) -> String? {
        (obj["header"] as? [String: Any])?["event"] as? String
    }

    private static func errorMessage(_ obj: [String: Any]) -> String? {
        (obj["header"] as? [String: Any])?["error_message"] as? String
    }
}
