import Foundation

enum JobStatus: String, Codable, Equatable, Sendable {
    case ready      = "Ready"
    case converting = "Converting"
    case done       = "Done"
    case failed     = "Failed"
}

struct Job: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var inputURL: URL
    var outputURL: URL?
    var status: JobStatus
    var progress: Double
    var errorMessage: String?
    var pageCount: Int?
    var chapterMarkers: [ChapterMarker]
    var createdAt: Date
    var preset: AudioPreset
    var voiceProfileID: UUID?
    var chunksCompleted: Int
    var chunksTotal: Int
    var startedAt: Date?
    var finishedAt: Date?

    init(inputURL: URL, preset: AudioPreset = .audiobook, voiceProfileID: UUID? = nil) {
        self.id               = UUID()
        self.inputURL         = inputURL
        self.outputURL        = nil
        self.status           = .ready
        self.progress         = 0
        self.errorMessage     = nil
        self.pageCount        = nil
        self.chapterMarkers   = []
        self.createdAt        = Date()
        self.preset           = preset
        self.voiceProfileID   = voiceProfileID
        self.chunksCompleted  = 0
        self.chunksTotal      = 0
        self.startedAt        = nil
        self.finishedAt       = nil
    }
}

struct ChapterMarker: Codable, Equatable, Sendable {
    var title: String
    var timestamp: TimeInterval
    var chunkIndex: Int
}
