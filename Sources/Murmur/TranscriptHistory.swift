import Foundation

/// Stores recent transcripts so the user can always see/copy results even when
/// auto-paste isn't available.
enum TranscriptHistory {
    private static let key = "transcriptHistory"
    private static let maxItems = 50

    static func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = all()
        items.insert(trimmed, at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        UserDefaults.standard.set(items, forKey: key)
    }

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
