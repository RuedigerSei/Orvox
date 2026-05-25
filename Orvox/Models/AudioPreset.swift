import AVFoundation

enum AudioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case audiobook
    case podcast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audiobook: "Audiobook"
        case .podcast:   "Podcast / Radio"
        }
    }

    var bitrate: Int {
        switch self {
        case .audiobook: 32_000
        case .podcast:   64_000
        }
    }

    var sampleRate: Double {
        switch self {
        case .audiobook: 16_000
        case .podcast:   22_050
        }
    }

    var channelCount: AVAudioChannelCount {
        switch self {
        case .audiobook: 1
        case .podcast:   2
        }
    }
}
