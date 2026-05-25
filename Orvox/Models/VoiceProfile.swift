import Foundation

struct VoiceProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sampleAudioFilename: String?   // filename relative to Voices dir
    var isBuiltIn: Bool
    var durationSeconds: Double?
    var createdAt: Date

    init(name: String, sampleAudioFilename: String? = nil, isBuiltIn: Bool = false, durationSeconds: Double? = nil) {
        self.id                  = UUID()
        self.name                = name
        self.sampleAudioFilename = sampleAudioFilename
        self.isBuiltIn           = isBuiltIn
        self.durationSeconds     = durationSeconds
        self.createdAt           = Date()
    }

    static let builtIn = VoiceProfile(name: "Neural Default", isBuiltIn: true)
}
