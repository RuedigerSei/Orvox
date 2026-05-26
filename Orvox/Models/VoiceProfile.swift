import Foundation

struct VoiceProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sampleAudioFilename: String?   // filename relative to Voices dir
    var durationSeconds: Double?
    var createdAt: Date

    init(name: String, sampleAudioFilename: String? = nil, durationSeconds: Double? = nil) {
        self.id                  = UUID()
        self.name                = name
        self.sampleAudioFilename = sampleAudioFilename
        self.durationSeconds     = durationSeconds
        self.createdAt           = Date()
    }
}
