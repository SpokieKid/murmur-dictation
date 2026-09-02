import Foundation

/// Sends recorded audio to a user-configured ASR API and returns the transcript.
/// Two wire formats are supported so users can bring almost any provider:
///   • `openai`     — multipart `/audio/transcriptions` (OpenAI, Groq, whisper.cpp, …)
///   • `dashscope`  — Alibaba DashScope multimodal-generation (qwen3-asr-flash)
enum Transcriber {
    struct Config {
        var provider: String
        var endpoint: String
        var apiKey: String
        var model: String
        var language: String   // ISO code or "auto"
        var vocabulary: [String] = []
    }

    enum TranscribeError: LocalizedError {
        case http(Int, String)
        case badResponse(String)
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return L10n.format("error.server_returned", code, body)
            case .badResponse(let s): return L10n.format("error.unexpected_response", s)
            case .notConfigured: return L10n.tr("error.api_key_required")
            }
        }
    }

    static func transcribe(wav: Data, config: Config) async throws -> String {
        guard !config.apiKey.isEmpty else { throw TranscribeError.notConfigured }
        switch config.provider {
        case Defaults.providerDashScope:
            return try await dashScope(wav: wav, config: config)
        default:
            return try await openAICompatible(wav: wav, config: config)
        }
    }

    /// How long to wait on a single ASR request before treating the connection
    /// as dead. Audio is small and (once routed directly) transcription is a few
    /// seconds, so a stall past this is almost always a stale pooled connection
    /// after the app sat idle — fail fast and let `send` retry on a fresh one.
    private static let requestTimeout: TimeInterval = 25

    /// Sends a request, retrying once on a brand-new connection if the first
    /// attempt fails. After a long idle (or a system sleep), the connection
    /// `URLSession.shared` kept pooled is often dead; reusing it hangs or errors
    /// and, before this, left the app stuck needing a restart. The retry uses a
    /// throwaway `.ephemeral` session so it can't reuse that dead socket.
    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            // The user cancelled (Escape) — that's not a dead connection, so don't
            // burn a retry re-sending audio they've already thrown away.
            if Task.isCancelled { throw error }
            let fresh = URLSession(configuration: .ephemeral)
            defer { fresh.finishTasksAndInvalidate() }
            return try await fresh.data(for: req)
        }
    }

    /// Best-effort: opens (or resumes) a TCP/TLS connection to the ASR host so
    /// the handshake happens while the user is still talking instead of after
    /// they release the hotkey. Fire-and-forget — the response is discarded.
    static func prewarm(config: Config) {
        guard !config.apiKey.isEmpty, let url = URL(string: config.endpoint) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - OpenAI-compatible multipart

    private static func openAICompatible(wav: Data, config: Config) async throws -> String {
        guard let url = URL(string: config.endpoint) else {
            throw TranscribeError.badResponse(L10n.tr("error.invalid_endpoint"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        field("model", config.model)
        if config.language != "auto", !config.language.isEmpty { field("language", config.language) }
        // Whisper-style APIs accept a `prompt` that biases recognition toward
        // these spellings — exactly what a custom vocabulary needs.
        if !config.vocabulary.isEmpty { field("prompt", config.vocabulary.joined(separator: ", ")) }
        field("response_format", "json")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.appendString("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await send(req)
        try checkStatus(resp, data)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = String(data: data, encoding: .utf8) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        throw TranscribeError.badResponse(L10n.tr("error.parse_transcript"))
    }

    // MARK: - DashScope (Qwen3-ASR)

    private static func dashScope(wav: Data, config: Config) async throws -> String {
        guard let url = URL(string: config.endpoint) else {
            throw TranscribeError.badResponse(L10n.tr("error.invalid_endpoint"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let dataURI = "data:audio/wav;base64,\(wav.base64EncodedString())"
        var asrOptions: [String: Any] = ["enable_lid": true, "enable_itn": false]
        if config.language != "auto", !config.language.isEmpty { asrOptions["language"] = config.language }

        // Qwen3-ASR biases toward terms supplied as text in the system message.
        let contextText = config.vocabulary.isEmpty ? "" : config.vocabulary.joined(separator: "、")

        // fun-asr-* models reject data-URI audio unless the container format is
        // spelled out (400 UNSUPPORTED_FORMAT "format is empty"); qwen3-asr
        // infers it, so keep the extra key scoped to fun-asr.
        var parameters: [String: Any] = ["asr_options": asrOptions]
        if config.model.hasPrefix("fun-asr") { parameters["format"] = "wav" }

        let payload: [String: Any] = [
            "model": config.model,
            "input": ["messages": [
                ["role": "system", "content": [["text": contextText]]],
                ["role": "user", "content": [["audio": dataURI]]],
            ]],
            "parameters": parameters,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await send(req)
        try checkStatus(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError.badResponse(L10n.tr("error.non_json_response"))
        }
        if let text = extractDashScopeText(obj) { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw TranscribeError.badResponse(raw)
    }

    /// Digs the transcript text out of DashScope's nested choices/content shape.
    private static func extractDashScopeText(_ obj: [String: Any]) -> String? {
        guard let output = obj["output"] as? [String: Any] else { return nil }
        if let choices = output["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let str = message["content"] as? String { return str }
            if let arr = message["content"] as? [[String: Any]] {
                let parts = arr.compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined() }
            }
        }
        // fun-asr-* models skip the choices/message nesting and put the
        // transcript directly at output.text.
        if let text = output["text"] as? String, !text.isEmpty { return text }
        return nil
    }

    // MARK: - Helpers

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscribeError.http(http.statusCode, String(body.prefix(500)))
        }
    }
}

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
}
