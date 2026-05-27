import Foundation

enum NarrationStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case audiobook         = "audiobook"
    case audiobookDramatic = "audiobook_dramatic"
    case science           = "science"
    case broadcast         = "broadcast"
    case preview           = "preview"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audiobook:         "Audiobook"
        case .audiobookDramatic: "Audiobook — Dramatic"
        case .science:           "Science / Documentary"
        case .broadcast:         "Broadcast"
        case .preview:           "Preview"
        }
    }

    // ── Built-in defaults ────────────────────────────────────────────────────

    var defaultInstruct: String {
        switch self {
        case .audiobook:
            "Slow, calm audiobook narration with purposeful pauses between sentences. Warm, measured delivery with relaxed breath control."
        case .audiobookDramatic:
            "Cinematic storytelling voice, moderately slow pace, deliberate pauses, slightly deeper pitch. Emotionally engaged but composed."
        case .science:
            "Engaging audiobook narration in the style of a thoughtful science documentary. Moderate pace with deliberate pauses between sentences and after key concepts. Warm, curious tone — intellectually animated but calm and unhurried. Slightly lowered pitch. Natural breathing rhythm. Clear articulation on technical terms."
        case .broadcast:
            "Authoritative news broadcast tone, crisp and clear, steady pace."
        case .preview:
            "Clear, neutral reading pace. Natural delivery."
        }
    }

    // ── Resolved (custom override → built-in default) ────────────────────────

    var resolvedInstruct: String {
        let stored = UserDefaults.standard.string(forKey: udKey) ?? ""
        return stored.isEmpty ? defaultInstruct : stored
    }

    var isCustomised: Bool {
        let stored = UserDefaults.standard.string(forKey: udKey) ?? ""
        return !stored.isEmpty && stored != defaultInstruct
    }

    // ── Persistence ──────────────────────────────────────────────────────────

    func saveCustomInstruct(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultInstruct {
            UserDefaults.standard.removeObject(forKey: udKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: udKey)
        }
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    private var udKey: String { "narrationPrompt_\(rawValue)" }
}
