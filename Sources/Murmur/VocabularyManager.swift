import Foundation

/// Manages the DashScope hotword vocabulary list used by `paraformer-realtime-v2`
/// (`RealtimeTranscriber`). Unlike the batch API's vocabulary bias (a plain-text
/// hint stuffed into a prompt), paraformer-realtime takes a server-side
/// `vocabulary_id` created ahead of time via a small REST management API.
///
/// A vocabulary list persists server-side until deleted, so this only needs to
/// (re)create one when the user's terms actually change — the resulting id is
/// cached in UserDefaults alongside the exact term list it was built from.
enum VocabularyManager {
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/customization")!

    /// Returns a vocabulary_id matching the given terms, creating (and
    /// replacing) one server-side if the terms changed since last time.
    /// Returns nil if terms are empty or the call fails — callers should just
    /// proceed without hotword biasing in that case.
    static func vocabularyId(for terms: [String], apiKey: String) async -> String? {
        guard !terms.isEmpty, !apiKey.isEmpty else { return nil }

        let key = terms.joined(separator: "\u{1}")
        let d = UserDefaults.standard
        if d.string(forKey: "vocabTermsKey") == key,
           let cached = d.string(forKey: "vocabularyId"), !cached.isEmpty {
            return cached
        }

        let previousId = d.string(forKey: "vocabularyId")
        guard let created = await create(terms: terms, apiKey: apiKey) else { return previousId }

        d.set(created, forKey: "vocabularyId")
        d.set(key, forKey: "vocabTermsKey")
        if let previousId, previousId != created {
            await delete(id: previousId, apiKey: apiKey) // best-effort cleanup; ignore failures
        }
        return created
    }

    private static func create(terms: [String], apiKey: String) async -> String? {
        let vocabulary = terms.map { term -> [String: Any] in
            let lang = term.unicodeScalars.contains(where: { !$0.isASCII }) ? "zh" : "en"
            return ["text": term, "weight": 4, "lang": lang]
        }
        let body: [String: Any] = [
            "model": "speech-biasing",
            "input": [
                "action": "create_vocabulary",
                "target_model": "paraformer-realtime-v2",
                "prefix": "murmur",
                "vocabulary": vocabulary,
            ],
        ]
        guard let data = try? await post(body, apiKey: apiKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let id = output["vocabulary_id"] as? String else { return nil }
        return id
    }

    private static func delete(id: String, apiKey: String) async {
        let body: [String: Any] = [
            "model": "speech-biasing",
            "input": ["action": "delete_vocabulary", "vocabulary_id": id],
        ]
        _ = try? await post(body, apiKey: apiKey)
    }

    /// POSTs with one retry on outright connection failure — this endpoint sits
    /// behind the same flaky network path as everything else in this app.
    private static func post(_ body: [String: Any], apiKey: String) async throws -> Data? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<2 {
            if let (data, resp) = try? await URLSession.shared.data(for: req) {
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                return data
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        return nil
    }
}
