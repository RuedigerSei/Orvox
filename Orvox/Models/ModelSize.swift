import Foundation

enum ModelSize: String, CaseIterable, Sendable {
    case quality = "1.7b"
    case fast    = "0.6b"

    var displayName: String {
        switch self {
        case .quality: "Quality (1.7B)"
        case .fast:    "Fast Preview (0.6B)"
        }
    }

    var huggingFaceID: String {
        switch self {
        case .quality: "Qwen/Qwen3-TTS-12Hz-1.7B-Base"
        case .fast:    "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
        }
    }
}
