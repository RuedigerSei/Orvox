import Foundation

enum BuiltInVoice: String, CaseIterable, Codable, Identifiable {
    case vivian   = "Vivian"
    case serena   = "Serena"
    case uncleFu  = "Uncle_Fu"
    case dylan    = "Dylan"
    case eric     = "Eric"
    case ryan     = "Ryan"
    case aiden    = "Aiden"
    case onoAnna  = "Ono_Anna"
    case sohee    = "Sohee"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uncleFu: "Uncle Fu"
        case .onoAnna: "Ono Anna"
        default: rawValue
        }
    }

    var voiceDescription: String {
        switch self {
        case .vivian:  "Bright, slightly edgy young female"
        case .serena:  "Warm, gentle young female"
        case .uncleFu: "Seasoned male, low mellow timbre"
        case .dylan:   "Youthful Beijing male, clear natural timbre"
        case .eric:    "Lively Chengdu male, slightly husky brightness"
        case .ryan:    "Dynamic male with strong rhythmic drive"
        case .aiden:   "Sunny American male, clear midrange"
        case .onoAnna: "Playful Japanese female, light nimble timbre"
        case .sohee:   "Warm Korean female with rich emotion"
        }
    }

    var nativeLanguage: String {
        switch self {
        case .vivian, .serena, .uncleFu: "Chinese"
        case .dylan:   "Chinese · Beijing"
        case .eric:    "Chinese · Sichuan"
        case .ryan, .aiden: "English"
        case .onoAnna: "Japanese"
        case .sohee:   "Korean"
        }
    }
}
